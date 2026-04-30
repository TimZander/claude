#!/usr/bin/env bash
# Smoke test for start-work.sh — usage error, slug validation, clean-tree refusal,
# happy-path branch creation, --no-worktree mode, --base override, idempotency refusal.
#
# Uses a real local git repo as the fixture so we exercise actual `git worktree add`
# and `git checkout -b` behavior. Sets `origin` to a bare repo on the same host.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/start-work.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Build a fresh git repo with a bare `origin` and one base commit on `main`.
fresh_repo() {
    local d="$TMP_ROOT/repo.$$.$RANDOM"
    local bare="$TMP_ROOT/origin.$$.$RANDOM.git"
    git init -q --bare "$bare"
    git init -q -b main "$d"
    (
        cd "$d"
        git config user.email "test@example.com"
        git config user.name "Test"
        # Opt out of the team's global pre-push hook for this throwaway test repo
        # (the hook lives in ~/.git-hooks/pre-push and blocks pushes to main).
        : > .allow-push-main
        git remote add origin "$bare"
        echo "seed" > README.md
        git add README.md .allow-push-main
        git commit -q -m "seed"
        git push -q -u origin main
    )
    printf '%s' "$d"
}

# 1. Missing --slug exits with usage.
if bash "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit on missing --slug"
fi
pass "usage error on missing --slug"

# 2. Non-kebab-case slug is rejected (uppercase, leading hyphen, etc.).
repo="$(fresh_repo)"
if ( cd "$repo" && bash "$SUT" --slug "BadSlug" >/dev/null 2>&1 ); then
    fail "expected rejection of uppercase slug"
fi
if ( cd "$repo" && bash "$SUT" --slug "-leading-hyphen" >/dev/null 2>&1 ); then
    fail "expected rejection of leading-hyphen slug"
fi
if ( cd "$repo" && bash "$SUT" --slug "trailing-" >/dev/null 2>&1 ); then
    fail "expected rejection of trailing-hyphen slug"
fi
pass "non-kebab-case slug rejected"

# 3. Non-alphanumeric --id is rejected.
if ( cd "$repo" && bash "$SUT" --slug "valid-slug" --id "bad/id" >/dev/null 2>&1 ); then
    fail "expected rejection of --id with path separator"
fi
pass "id with path separator rejected"

# 4. Dirty working tree is refused.
repo="$(fresh_repo)"
echo "dirt" > "$repo/uncommitted.txt"
( cd "$repo" && git add uncommitted.txt )
if ( cd "$repo" && bash "$SUT" --slug "anything" --id "1" >/dev/null 2>&1 ); then
    fail "expected refusal on dirty tree"
fi
pass "dirty working tree refused"

# 5. Happy path with --id: creates worktree at .claude/worktrees/<id>-<slug>/, branch
#    branches/<id>-<slug>, prints BRANCH= and WORKTREE_PATH= on the last two stdout lines.
repo="$(fresh_repo)"
out="$( cd "$repo" && bash "$SUT" --slug "my-feature" --id "42" 2>/dev/null )"
last="$(printf '%s\n' "$out" | tail -1)"
prev="$(printf '%s\n' "$out" | tail -2 | head -1)"
[ "$last" = "WORKTREE_PATH=.claude/worktrees/42-my-feature" ] \
    || fail "expected WORKTREE_PATH on last line, got: $last"
[ "$prev" = "BRANCH=branches/42-my-feature" ] \
    || fail "expected BRANCH on second-to-last line, got: $prev"
[ -d "$repo/.claude/worktrees/42-my-feature" ] \
    || fail "expected worktree directory to exist"
( cd "$repo/.claude/worktrees/42-my-feature" && [ "$(git branch --show-current)" = "branches/42-my-feature" ] ) \
    || fail "expected worktree to be on branches/42-my-feature"
pass "worktree-mode happy path with --id creates branches/<id>-<slug> at .claude/worktrees/<id>-<slug>"

# 6. Happy path without --id: branch is branches/<slug>, worktree dir matches.
repo="$(fresh_repo)"
out="$( cd "$repo" && bash "$SUT" --slug "no-id-feature" 2>/dev/null )"
last="$(printf '%s\n' "$out" | tail -1)"
prev="$(printf '%s\n' "$out" | tail -2 | head -1)"
[ "$last" = "WORKTREE_PATH=.claude/worktrees/no-id-feature" ] \
    || fail "expected WORKTREE_PATH no-id-feature, got: $last"
[ "$prev" = "BRANCH=branches/no-id-feature" ] \
    || fail "expected BRANCH branches/no-id-feature, got: $prev"
pass "no-id mode produces branches/<slug>"

# 7. --no-worktree mode: branch in-place, no worktree dir, BRANCH= is the only stdout line.
repo="$(fresh_repo)"
out="$( cd "$repo" && bash "$SUT" --slug "in-place" --id "7" --no-worktree 2>/dev/null )"
[ "$out" = "BRANCH=branches/7-in-place" ] \
    || fail "expected BRANCH-only output in --no-worktree mode, got: $out"
[ ! -d "$repo/.claude/worktrees/7-in-place" ] \
    || fail "expected NO worktree directory in --no-worktree mode"
( cd "$repo" && [ "$(git branch --show-current)" = "branches/7-in-place" ] ) \
    || fail "expected current branch to be branches/7-in-place after --no-worktree"
pass "--no-worktree mode creates branch in place, no worktree dir"

# 8. --base override: create branch from a non-main base.
repo="$(fresh_repo)"
( cd "$repo" \
    && git checkout -q -b feature/long-lived \
    && echo "feature seed" > feature.txt \
    && git add feature.txt \
    && git commit -q -m "feature seed" \
    && git push -q -u origin feature/long-lived \
    && git checkout -q main )
out="$( cd "$repo" && bash "$SUT" --slug "subfeature" --id "99" --base "feature/long-lived" 2>/dev/null )"
last="$(printf '%s\n' "$out" | tail -1)"
[ "$last" = "WORKTREE_PATH=.claude/worktrees/99-subfeature" ] \
    || fail "expected --base override to still produce expected worktree path, got: $last"
# Verify the new branch's parent is the feature branch tip, not main.
( cd "$repo/.claude/worktrees/99-subfeature" \
    && git merge-base --is-ancestor "origin/feature/long-lived" HEAD ) \
    || fail "expected new branch to be rooted at origin/feature/long-lived"
pass "--base <branch> roots the new branch off the specified base"

# 9. Idempotency refusal: re-running with the same slug+id (worktree already exists) errors.
repo="$(fresh_repo)"
( cd "$repo" && bash "$SUT" --slug "idem" --id "11" >/dev/null 2>&1 )
if ( cd "$repo" && bash "$SUT" --slug "idem" --id "11" >/dev/null 2>&1 ); then
    fail "expected refusal on second run with same slug+id"
fi
pass "second run with same slug+id is refused (no silent overwrite)"

# 10. Refusal when branch already exists locally even without a worktree.
repo="$(fresh_repo)"
( cd "$repo" && git branch branches/55-pre-existing )
if ( cd "$repo" && bash "$SUT" --slug "pre-existing" --id "55" --no-worktree >/dev/null 2>&1 ); then
    fail "expected refusal when target branch already exists locally"
fi
pass "refuses to clobber existing local branch"

# 11. --base that doesn't exist on origin → clear error.
repo="$(fresh_repo)"
if ( cd "$repo" && bash "$SUT" --slug "x" --id "1" --base "no-such-branch" >/dev/null 2>&1 ); then
    fail "expected non-zero exit when --base doesn't exist on origin"
fi
pass "non-existent --base is rejected"

# 12. Branch already exists on origin (but not locally) → refuse with a coordination hint.
#     A second clone of the same origin pushes the target branch, then the script tries
#     to create the same branch in the first clone — should refuse rather than silently
#     create a divergent local copy.
repo="$(fresh_repo)"
# Find this repo's bare origin so we can clone a second working copy that pushes the conflict.
bare_origin="$( cd "$repo" && git remote get-url origin )"
collaborator="$TMP_ROOT/collab.$$.$RANDOM"
git clone -q "$bare_origin" "$collaborator"
( cd "$collaborator" \
    && git config user.email "collab@example.com" \
    && git config user.name "Collab" \
    && : > .allow-push-main \
    && git checkout -q -b branches/77-conflicting \
    && echo "collab work" > collab.txt \
    && git add collab.txt \
    && git commit -q -m "collab seed" \
    && git push -q -u origin branches/77-conflicting )
err="$( cd "$repo" && bash "$SUT" --slug "conflicting" --id "77" 2>&1 >/dev/null || true )"
echo "$err" | grep -qi "already exists on origin" \
    || fail "expected origin-side collision error, got: $err"
# And no worktree should have been created locally as a side effect.
[ ! -d "$repo/.claude/worktrees/77-conflicting" ] \
    || fail "expected NO worktree to be created when origin already has the branch"
pass "branch already on origin (but not local) is refused"

echo "all smoke tests passed"
