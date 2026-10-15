#!/usr/bin/env bash
# Smoke test for handoff.sh: usage errors, note naming and the local exclude, open's order
# and next actions, the state facts, commit's refusals and push, remote, and drop for a local
# and a committed note. Uses real git repos with a bare origin, offline.
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
expect_exit 2 bash "$H" drop -C "$r"
expect_exit 2 bash "$H" commit -C "$r" a b
expect_exit 1 bash "$H" state -C "$TMP_ROOT"
expect_exit 1 bash "$H" drop -C "$r" "docs/handoffs/../x.md"
expect_exit 1 bash "$H" drop -C "$r" "notes/x.md"
pass "usage errors exit 2, outside a repo or a bad note path exits 1"

# --- new: free note names, kept out of git ------------------------------------------------
today="$(date +%Y-%m-%d)"
[ -z "$(bash "$H" open -C "$r")" ] || fail "open in a repo without handoffs"
note="$(bash "$H" new -C "$r")"
[ "$note" = "docs/handoffs/$today.md" ] || fail "first note path: $note"
printf '# Handoff\n\n## Current state\nx\n\n## Next action\n\nRun the\tmigration\n\n## Remaining work\nnone\n' > "$r/$note"
note2="$(bash "$H" new -C "$r")"
[ "$note2" = "docs/handoffs/$today-2.md" ] || fail "second note path: $note2"
[ "$(grep -cxF /docs/handoffs/ "$r/.git/info/exclude")" = 1 ] || fail "exclude entry missing or repeated"
[ -z "$(git -C "$r" status --porcelain -- docs)" ] || fail "a note shows up in git status"
git -C "$r" add -A && git -C "$r" diff --cached --quiet -- docs || fail "git add -A picked up a note"
pass "new picks a free note name and keeps notes out of git"

# --- open ----------------------------------------------------------------------------------
printf '# Handoff 2\n\n## Next action\nSecond\n' > "$r/$note2"
mkdir -p "$r/docs/handoffs"
for f in 2026-01-02.md 2026-01-02-10.md 2025-12-31.md notes.md README.md; do echo x > "$r/docs/handoffs/$f"; done
got="$(bash "$H" open -C "$r" | cut -f 1 | sed 's#docs/handoffs/##' | tr '\n' ' ')"
[ "$got" = "$today-2.md $today.md 2026-01-02-10.md 2026-01-02.md 2025-12-31.md " ] || fail "open order: $got"
[ "$(bash "$H" open -C "$r" | sed -n 2p | cut -f 2)" = "Run the migration" ] || fail "next action: $(bash "$H" open -C "$r")"
[ "$(bash "$H" open -C "$r" | sed -n 3p | cut -f 2)" = "(no next action)" ] || fail "missing next action"
for f in 2026-01-02.md 2026-01-02-10.md 2025-12-31.md; do bash "$H" drop -C "$r" "docs/handoffs/$f" >/dev/null; done
[ ! -e "$r/docs/handoffs/2025-12-31.md" ] || fail "drop left a local note"
expect_exit 1 bash "$H" drop -C "$r" "docs/handoffs/2025-12-31.md"
[ "$(bash "$H" open -C "$r" | cut -f 1 | tr '\n' ' ')" = "$note2 $note " ] || fail "open after drop"
pass "open lists dated notes newest first with their next actions; drop deletes a local note"


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
[ "$(git -C "$r" show --name-only --format= HEAD)" = "$note" ] || fail "commit took more than the note"
git -C "$r" diff --quiet -- README.md && fail "commit swept up an unrelated change"
[ "$(git -C "$r" rev-parse origin/work)" = "$(git -C "$r" rev-parse HEAD)" ] || fail "commit did not push"
out="$(CLAUDE_CODE_REMOTE= bash "$H" state -C "$r")"
printf '%s\n' "$out" | grep -qx 'upstream: origin/work' || { echo "$out"; fail "push did not set the upstream"; }
git -C "$r" stash -q && git -C "$r" checkout -q main
expect_exit 1 bash "$H" commit -C "$r" "$note2"
grep -q "won't commit a handoff on main" "$TMP_ROOT/out" || fail "commit on main not refused"
pass "commit takes only the note, pushes, and refuses main"

# --- remote: notes on other branches -------------------------------------------------------
out="$(bash "$H" remote -C "$r")"
[ "$out" = "$(printf 'work\t%s\tRun the migration' "$note")" ] \
    || { echo "$out"; fail "remote did not find exactly the note on origin/work"; }
pass "remote lists notes committed on remote branches"

# --- drop a committed note -----------------------------------------------------------------
git -C "$r" checkout -q work && git -C "$r" stash pop -q
bash "$H" drop -C "$r" "$note" >/dev/null || { bash "$H" drop -C "$r" "$note"; fail "drop"; }
[ ! -e "$r/$note" ] || fail "drop left the committed note"
[ "$(git -C "$r" show --name-status --format= HEAD)" = "$(printf 'D\t%s' "$note")" ] || fail "drop commit holds more than the deletion"
git -C "$r" diff --quiet -- README.md && fail "drop swept up an unrelated change"
[ "$(git -C "$r" rev-parse origin/work)" = "$(git -C "$r" rev-parse HEAD)" ] || fail "drop did not push"
[ -z "$(git -C "$r" diff --name-only main origin/work -- docs)" ] || fail "the note still differs from main"
[ -z "$(bash "$H" remote -C "$r")" ] || fail "remote still lists a dropped note"
pass "drop commits and pushes the deletion of a committed note, so the branch matches main"

echo "all handoff tests passed"
