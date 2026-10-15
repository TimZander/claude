#!/usr/bin/env bash
# Smoke test for handoff.sh: usage errors, the index (create, add, update, set, open),
# note naming, the state facts, the fallback without an index, and commit's refusals and
# push. Uses real git repos with a bare origin, offline.
#
#   bash plugins/handoff/scripts/test_handoff.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
H="$SCRIPT_DIR/handoff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

expect_exit() {
    local want="$1"; shift
    local got=0
    "$@" >"$TMP_ROOT/out" 2>&1 || got=$?
    [ "$got" = "$want" ] || { cat "$TMP_ROOT/out" >&2; fail "expected exit $want, got $got: $*"; }
}

fresh_repo() {
    local d="$TMP_ROOT/repo.$RANDOM$RANDOM" bare="$TMP_ROOT/origin.$RANDOM$RANDOM.git"
    git init -q --bare "$bare"
    git init -q -b main "$d"
    git -C "$d" config user.email test@example.com
    git -C "$d" config user.name Test
    # The team's global pre-push hook blocks pushes to main; this throwaway repo opts out.
    : > "$d/.allow-push-main"
    echo seed > "$d/README.md"
    git -C "$d" add -A && git -C "$d" commit -q -m seed
    git -C "$d" remote add origin "$bare"
    git -C "$d" push -q -u origin main 2>/dev/null
    printf '%s' "$d"
}

# --- usage -----------------------------------------------------------------------------
expect_exit 2 bash "$H"
expect_exit 2 bash "$H" bogus
r="$(fresh_repo)"
expect_exit 2 bash "$H" add -C "$r" only-one
expect_exit 2 bash "$H" set -C "$r" docs/handoffs/x.md bogus
expect_exit 1 bash "$H" state -C "$TMP_ROOT"
pass "usage errors exit 2, outside a repo exits 1"

# --- new: index from the template, free note names ---------------------------------------
today="$(date +%Y-%m-%d)"
note="$(bash "$H" new -C "$r")"
[ "$note" = "docs/handoffs/$today.md" ] || fail "first note path: $note"
[ -f "$r/docs/handoffs/README.md" ] || fail "index not created"
grep -q '^| Date | File | Status | Next action |$' "$r/docs/handoffs/README.md" || fail "index table header"
printf '# Handoff\n' > "$r/$note"
[ "$(bash "$H" new -C "$r")" = "docs/handoffs/$today-2.md" ] || fail "second note path"
pass "new creates the index and picks a free note name"

# --- add, open, set -----------------------------------------------------------------------
expect_exit 1 bash "$H" add -C "$r" "docs/handoffs/$today-9.md" "x"
grep -q 'no such note' "$TMP_ROOT/out" || fail "a missing note was added"
expect_exit 1 bash "$H" add -C "$r" "docs/handoffs/../x.md" "x"
expect_exit 1 bash "$H" add -C "$r" "docs/handoffs/README.md" "x"
bash "$H" add -C "$r" "$note" 'Run the | migration
then \n check' >/dev/null
row="$(grep -F "| $note |" "$r/docs/handoffs/README.md")"
[ "$row" = "| $today | $note | open | Run the / migration then \\n check |" ] || fail "row: $row"
note2="$(bash "$H" new -C "$r")"
printf '# Handoff 2\n' > "$r/$note2"
bash "$H" add -C "$r" "$note2" "Second" >/dev/null
[ "$(bash "$H" open -C "$r" | cut -f 1 | tr '\n' ' ')" = "$note2 $note " ] || fail "open order: $(bash "$H" open -C "$r")"
[ "$(bash "$H" open -C "$r" | head -n 1 | cut -f 2)" = "Second" ] || fail "open next action"
bash "$H" add -C "$r" "$note" "Updated" >/dev/null
[ "$(grep -cF "| $note |" "$r/docs/handoffs/README.md")" = 1 ] || fail "re-adding duplicated the row"
[ "$(bash "$H" open -C "$r" | head -n 1 | cut -f 1)" = "$note" ] || fail "an updated note didn't move to the top"
bash "$H" set -C "$r" "$note" resumed >/dev/null
grep -qxF "| $today | $note | resumed | Updated |" "$r/docs/handoffs/README.md" || fail "set resumed"
[ "$(bash "$H" open -C "$r")" = "$(printf '%s\tSecond' "$note2")" ] || fail "a resumed note is still open"
bash "$H" set -C "$r" "$note2" superseded >/dev/null
[ -z "$(bash "$H" open -C "$r")" ] || fail "nothing should be open"
expect_exit 1 bash "$H" set -C "$r" "docs/handoffs/$today-7.md" resumed
grep -q 'has no row' "$TMP_ROOT/out" || fail "set on a missing row"
long="$(printf 'x%.0s' $(seq 1 300))"
bash "$H" add -C "$r" "$note" "$long" >/dev/null
[ "$(bash "$H" open -C "$r" | cut -f 2 | wc -c | tr -d ' ')" = 121 ] || fail "next action not cut to 120 characters"
pass "add, set and open keep one row per note, newest first, on one line"

# --- open without an index ----------------------------------------------------------------
r2="$(fresh_repo)"
[ -z "$(bash "$H" open -C "$r2")" ] || fail "open in a repo without handoffs"
mkdir -p "$r2/docs/handoffs"
for f in 2026-01-02.md 2026-01-02-2.md 2026-01-02-10.md 2025-12-31.md notes.md; do echo x > "$r2/docs/handoffs/$f"; done
got="$(bash "$H" open -C "$r2" | cut -f 1 | sed 's#docs/handoffs/##' | tr '\n' ' ')"
[ "$got" = "2026-01-02-10.md 2026-01-02-2.md 2026-01-02.md 2025-12-31.md " ] || fail "fallback order: $got"
pass "open without an index lists dated notes, newest first"

# --- state ---------------------------------------------------------------------------------
git -C "$r" checkout -q -b work
echo change >> "$r/README.md"
out="$(CLAUDE_CODE_REMOTE= bash "$H" state -C "$r")"
printf '%s\n' "$out" | grep -qx 'branch: work' || { echo "$out"; fail "state branch"; }
printf '%s\n' "$out" | grep -qx 'upstream: none (this branch exists only here)' || fail "state upstream"
printf '%s\n' "$out" | grep -qx 'cloud: no' || fail "state cloud no"
printf '%s\n' "$out" | grep -q '^uncommitted: [1-9]' || fail "state uncommitted"
out="$(CLAUDE_CODE_REMOTE=true bash "$H" state -C "$r")"
printf '%s\n' "$out" | grep -qx 'cloud: yes' || fail "state cloud yes"
pass "state reports the branch, its upstream, uncommitted files and a cloud session"

# --- commit --------------------------------------------------------------------------------
bash "$H" commit -C "$r" "$note" >/dev/null || { bash "$H" commit -C "$r" "$note"; fail "commit"; }
[ "$(git -C "$r" show --name-only --format= HEAD | sort | tr '\n' ' ')" = "$(printf '%s\n' docs/handoffs/README.md "$note" | sort | tr '\n' ' ')" ] \
    || fail "commit took more than the note and the index"
git -C "$r" diff --quiet -- README.md && fail "commit swept up an unrelated change"
[ "$(git -C "$r" rev-parse origin/work)" = "$(git -C "$r" rev-parse HEAD)" ] || fail "commit did not push"
out="$(CLAUDE_CODE_REMOTE= bash "$H" state -C "$r")"
printf '%s\n' "$out" | grep -qx 'upstream: origin/work' || { echo "$out"; fail "push did not set the upstream"; }
git -C "$r" checkout -q main 2>/dev/null || { git -C "$r" stash -q && git -C "$r" checkout -q main; }
expect_exit 1 bash "$H" commit -C "$r" "$note2"
grep -q "won't commit a handoff on main" "$TMP_ROOT/out" || fail "commit on main not refused"
pass "commit takes only the note and the index, pushes, and refuses main"

# --- remote: open notes on other branches ---------------------------------------------------
git -C "$r" checkout -q work
out="$(bash "$H" remote -C "$r")"
[ "$(printf '%s\n' "$out" | cut -f 1,2)" = "$(printf 'work\t%s' "$note")" ] \
    || { echo "$out"; fail "remote did not find exactly the open note on origin/work (main has no index)"; }
pass "remote lists open notes on remote branches"

echo "all handoff tests passed"
