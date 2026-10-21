#!/usr/bin/env bash
# Smoke test for handoff.sh: usage errors, note naming and the local exclude, open's order
# and next actions, the state facts, commit's refusals and push, remote, and drop for a local
# note, a pushed one, an unpushed one, and one on main; relay's refusals (after a fetch), its clone URL
# and what it reports left behind. Uses real git repos with a bare origin, offline.
#
#   bash plugins/handoff/scripts/test_handoff.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
H="$SCRIPT_DIR/handoff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Resolved, so paths match what git reports (macOS's temp dir is behind a symlink).
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
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

# --- drop: a committed note that was never pushed, and one on main --------------------------
printf '# Local\n' > "$r/docs/handoffs/2026-02-01.md"
git -C "$r" add -f docs/handoffs/2026-02-01.md && git -C "$r" commit -q -m local -- docs/handoffs/2026-02-01.md
before="$(git -C "$r" rev-parse origin/work)"
bash "$H" drop -C "$r" docs/handoffs/2026-02-01.md >/dev/null
[ "$(git -C "$r" rev-parse origin/work)" = "$before" ] || fail "drop pushed a note that was never on the upstream"
git -C "$r" stash -q && git -C "$r" checkout -q main
printf '# Merged\n' > "$r/docs/handoffs/2026-03-01.md"
git -C "$r" add -f docs/handoffs/2026-03-01.md && git -C "$r" commit -q -m merged -- docs/handoffs/2026-03-01.md
head_before="$(git -C "$r" rev-parse HEAD)"
bash "$H" drop -C "$r" docs/handoffs/2026-03-01.md > "$TMP_ROOT/out"
grep -q 'first commit of the next work branch' "$TMP_ROOT/out" || fail "drop on main didn't say where the deletion goes"
[ "$(git -C "$r" rev-parse HEAD)" = "$head_before" ] || fail "drop committed on main"
[ "$(git -C "$r" diff --cached --name-status)" = "$(printf 'D\tdocs/handoffs/2026-03-01.md')" ] || fail "drop on main didn't stage the deletion"
pass "drop pushes only a note the upstream has, and stages the deletion on main"

# --- relay: refusals, then the facts for create_session --------------------------------------
git -C "$r" checkout -q work && git -C "$r" stash pop -q
rn="docs/handoffs/2026-04-01.md"
printf '# Relay\n\n## Next action\nGo\n' > "$r/$rn"
expect_exit 1 env CLAUDE_CODE_REMOTE= bash "$H" relay -C "$r" "$rn"
grep -q 'not a cloud session' "$TMP_ROOT/out" || fail "relay outside a cloud session not refused"
expect_exit 1 env CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn"
grep -q 'is not committed' "$TMP_ROOT/out" || fail "relay with an uncommitted note not refused"
grep -q 'uncommitted changes would be lost' "$TMP_ROOT/out" || fail "relay with uncommitted changes not refused"
git -C "$r" commit -q -am "wip"
git -C "$r" add -f "$rn" && git -C "$r" commit -q -m relay -- "$rn"
expect_exit 1 env CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn"
grep -q '[0-9] commit(s) not pushed' "$TMP_ROOT/out" || fail "relay with unpushed commits not refused"
git -C "$r" push -q
# Someone else pushes to origin/work: relay has to fetch to notice.
other="$TMP_ROOT/other.$RANDOM"
git clone -q "$(git -C "$r" remote get-url origin)" "$other" 2>/dev/null
git -C "$other" checkout -q work && echo more > "$other/more.txt" && git -C "$other" add more.txt \
    && git -C "$other" -c user.email=o@example.com -c user.name=O commit -q -m more && git -C "$other" push -q 2>/dev/null
expect_exit 1 env CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn"
grep -q '1 commit(s) this checkout lacks' "$TMP_ROOT/out" || fail "relay did not fetch before checking for unpulled commits"
git -C "$r" pull -q --no-rebase 2>/dev/null
# A branch tracking another name on origin: the new session would clone the wrong branch.
git -C "$r" branch -q --set-upstream-to=origin/main
expect_exit 1 env CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn"
grep -q 'tracks origin/main, but the new session clones origin/work' "$TMP_ROOT/out" || fail "relay accepted a mismatched upstream"
git -C "$r" branch -q --set-upstream-to=origin/work
echo scratch > "$r/scratch.txt"
wt="$TMP_ROOT/wt.$RANDOM"
git -C "$r" worktree add -q --detach "$wt" HEAD
echo dirty > "$wt/dirty.txt"
out="$(CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn")" || { echo "$out"; fail "relay refused a pushed branch"; }
printf '%s\n' "$out" | grep -qx 'branch: work' || { echo "$out"; fail "relay branch"; }
printf '%s\n' "$out" | grep -qx "head: $(git -C "$r" rev-parse HEAD)" || fail "relay head"
printf '%s\n' "$out" | grep -qx "prompt: /handoff:pickup $rn" || fail "relay prompt"
printf '%s\n' "$out" | grep -qx 'shallow: no' || fail "relay shallow"
printf '%s\n' "$out" | grep -qx 'left behind: 6' || { echo "$out"; fail "relay left-behind count"; }
printf '%s\n' "$out" | grep -qx '  untracked: scratch.txt' || fail "relay did not report an untracked file"
printf '%s\n' "$out" | grep -qx "  ignored: $note2" || { echo "$out"; fail "relay did not report another local note"; }
printf '%s\n' "$out" | grep -qx '  branch: main (1 commit(s) on no remote)' || { echo "$out"; fail "relay did not report unpushed commits on another branch"; }
printf '%s\n' "$out" | grep -qx "  worktree: $wt at $(git -C "$wt" rev-parse --short HEAD), 1 uncommitted" || { echo "$out"; fail "relay did not report a dirty worktree"; }
for i in $(seq 1 25); do echo x > "$r/many.$i"; done
out="$(CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn")"
[ "$(printf '%s\n' "$out" | grep -c '^  ')" = 21 ] || { echo "$out"; fail "relay did not cap the left-behind list at 20"; }
printf '%s\n' "$out" | grep -qx '  ... and 11 more' || { echo "$out"; fail "relay did not say how many more were left behind"; }
rm -f "$r"/many.*
printf '%s\n' "$out" | grep -q "untracked: $rn" && fail "relay reported the note as untracked"
bare="$(git -C "$r" remote get-url origin)"
for pair in "git@github.com:o/r.git|https://github.com/o/r" \
            "ssh://git@github.com/o/r.git|https://github.com/o/r" \
            "https://x-access-token:t@github.com/o/r.git|https://github.com/o/r" \
            "http://local_proxy@127.0.0.1:41234/git/o/r|https://github.com/o/r" \
            "http://localhost:3000/git/team/r|http://localhost:3000/git/team/r" \
            "https://github.com/o/r|https://github.com/o/r"; do
    git -C "$r" remote set-url origin "${pair%%|*}"
    git -C "$r" config "url.$bare.insteadOf" "${pair%%|*}"
    got="$(CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn" | sed -n 's/^source_url: //p')"
    [ "$got" = "${pair##*|}" ] || fail "clone url for ${pair%%|*}: $got"
done
git -C "$r" remote set-url origin "$bare"
# A branch named like a tracked file still gets its unpushed commits counted.
git -C "$r" branch -q README.md main
out="$(CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn" 2>&1)"
printf '%s\n' "$out" | grep -qx '  branch: README.md (1 commit(s) on no remote)' || { echo "$out"; fail "relay miscounted a branch named like a file"; }
git -C "$r" branch -q -D README.md
# A branch that shares its name with a tag still gets its unpushed commits counted.
git -C "$r" branch -q dup main && git -C "$r" tag dup main
out="$(CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn" 2>&1)"
printf '%s\n' "$out" | grep -qx '  branch: dup (1 commit(s) on no remote)' || { echo "$out"; fail "relay miscounted a branch that shares a tag's name"; }
git -C "$r" branch -q -D dup && git -C "$r" tag -d dup >/dev/null
# Run from the linked worktree: the main checkout is the one left behind, not this one.
git -C "$wt" checkout -q -b wt-work && git -C "$wt" push -q -u origin wt-work 2>/dev/null
git -C "$wt" add -f "$rn" 2>/dev/null || true
out="$(CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$wt" "$rn" 2>&1)" || true
printf '%s\n' "$out" | grep -q "worktree: $wt " && { echo "$out"; fail "relay from a linked worktree listed itself as left behind"; }
printf '%s\n' "$out" | grep -q "^  worktree: $r at " || { echo "$out"; fail "relay from a linked worktree did not report the main checkout"; }
git -C "$r" checkout -q main
expect_exit 1 env CLAUDE_CODE_REMOTE=true bash "$H" relay -C "$r" "$rn"
grep -q 'on main' "$TMP_ROOT/out" || fail "relay on main not refused"
grep -q 'cannot fetch' "$TMP_ROOT/out" && fail "relay fetched for a run it had already refused"
# A bare repository with linked worktrees: the bare repository is no worktree to report.
bare2="$TMP_ROOT/bare2.$RANDOM.git"
git clone -q --bare "$bare" "$bare2" 2>/dev/null
git -C "$bare2" worktree add -q "$TMP_ROOT/bw1.$RANDOM" work 2>/dev/null
bw1="$(git -C "$bare2" worktree list --porcelain | awk '/^worktree / { p = substr($0, 10) } END { print p }')"
out="$(CLAUDE_CODE_REMOTE= bash "$H" state -C "$bw1")"
printf '%s\n' "$out" | grep -qx 'other worktrees: 0' || { echo "$out"; fail "state listed a bare repository as a worktree"; }
out="$(CLAUDE_CODE_REMOTE= bash "$H" state -C "$r")"
printf '%s\n' "$out" | grep -qx "  $wt $(git -C "$wt" rev-parse --short HEAD)" || { echo "$out"; fail "state dropped a worktree's sha"; }
# A nested worktree that lost its .git file: no sha borrowed from the checkout around it.
git -C "$r" worktree add -q -b nested "$r/wts/x" HEAD 2>/dev/null && rm -f "$r/wts/x/.git"
out="$(CLAUDE_CODE_REMOTE= bash "$H" state -C "$r")"
printf '%s\n' "$out" | grep -qx "  $r/wts/x ?" || { echo "$out"; fail "state gave a broken worktree the enclosing repository's sha"; }
rm -rf "$r/wts" && git -C "$r" worktree prune
pass "relay refuses outside the cloud, on main, and with unsaved work, and reports what stays behind"

echo "all handoff tests passed"
