#!/usr/bin/env bash
# Smoke test for resolve-pr.sh.
# Runs a set of scenarios and asserts exit code + output pattern.
# Invoke: bash scripts/test_resolve-pr.sh
#
# Coverage: syntax, usage errors, host detection (incl. ssh and visualstudio
# dialects), token parsing and precedence, boundary matching, the ADO
# work-item carve-out, ref normalization, CRLF handling, stderr contamination,
# empty/short lookup output, PR-state mapping, BRANCH_MATCH both ways,
# IN_WORKTREE both ways, fork and cross-repo rejection, and the PR-vs-issue
# fallback for an ambiguous #<N>.
#
# `gh` and `az` are STUBBED on PATH so the lookup paths run offline and
# deterministically; a sentinel asserts the stubs — not the live CLIs — are
# actually in use. The stubs mimic the real tools' OUTPUT SHAPE, which is what
# resolve-pr.sh depends on:
#   - gh --jq '... | @tsv'         -> one TAB-separated line, bare branch names
#   - az --query "[a,b,c]" -o tsv  -> one element per LINE, fully-qualified refs,
#                                     CRLF on Windows
#
# NOT covered: real gh/az authentication and live network behavior. The output
# shapes above were verified by hand against real tooling (GitHub PR 170, ADO
# PR 4506); re-verify manually if a lookup section changes.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/resolve-pr.sh"

fail=0
pass=0

TEST_TMPDIR=""
trap 'if [ -n "$TEST_TMPDIR" ]; then rm -rf "$TEST_TMPDIR"; fi' EXIT INT TERM

assert_exit() {
    local want="$1" got="$2" label="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
        echo "  PASS $label"
    else
        fail=$((fail + 1))
        echo "  FAIL $label: want exit $want, got $got"
    fi
}

assert_contains() {
    local needle="$1" out="$2" label="$3"
    case "$out" in
        *"$needle"*) pass=$((pass + 1)); echo "  PASS $label" ;;
        *) fail=$((fail + 1)); echo "  FAIL $label: output missing '$needle'"; echo "    got: $out" ;;
    esac
}

assert_not_contains() {
    local needle="$1" out="$2" label="$3"
    case "$out" in
        *"$needle"*) fail=$((fail + 1)); echo "  FAIL $label: output unexpectedly contains '$needle'"; echo "    got: $out" ;;
        *) pass=$((pass + 1)); echo "  PASS $label" ;;
    esac
}

# mktemp is required: a Windows-style path (C:/...) in PATH does NOT shadow a
# real CLI under Git Bash, which would silently run the live tool instead of
# the stub. mktemp yields a POSIX path.
TEST_TMPDIR=$(mktemp -d) || { echo "mktemp -d failed; cannot run tests" >&2; exit 1; }
[ -n "$TEST_TMPDIR" ] || { echo "mktemp -d returned empty; refusing to continue" >&2; exit 1; }

# ── Stubs ────────────────────────────────────────────────────────────
# Behavior is driven by env vars so each case picks a scenario:
#   STUB_MODE=ok        well-formed success (default)
#   STUB_MODE=notfound  genuine 404 (the only thing that may downgrade #<N>)
#   STUB_MODE=authfail  transport/auth failure — must NOT downgrade to issue
#   STUB_MODE=empty     exit 0 with empty output
#   STUB_MODE=noisy     success, but a notice on stderr
#   STUB_MODE=fork      GitHub PR whose head is in a fork
#   STUB_MODE=otherrepo ADO PR belonging to a different repository
#   STUB_STATE=<raw>    override the raw upstream state
#   STUB_ARGS_FILE=<f>  record argv

STUB_DIR="$TEST_TMPDIR/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_ARGS_FILE:-}" ] && echo "$@" >> "$STUB_ARGS_FILE"
case "${STUB_MODE:-ok}" in
    notfound)
        echo "GraphQL: Could not resolve to a PullRequest with the number of 143. (repository.pullRequest)" >&2
        exit 1 ;;
    authfail)
        echo "error connecting to api.github.com: dial tcp: lookup api.github.com: no such host" >&2
        exit 1 ;;
    empty)
        printf '\n'; exit 0 ;;
    noisy)
        echo "A new release of gh is available: 2.40.0 -> 2.62.0" >&2
        printf 'branches/142-anchor-pr-review-comments-on-changed-lines\tmain\tMERGED\tfalse\n'; exit 0 ;;
    fork)
        printf 'patch-1\tmain\tOPEN\ttrue\n'; exit 0 ;;
esac
# The work-item lookup's second call, asking only for the PR body. Placed after
# the STUB_MODE case so the failure modes still exit first — a body fetch is
# only ever reached once the branch lookup has already succeeded.
case "$*" in
    *"--json body"*) printf '%s\n' "${STUB_PR_BODY:-A description with no linked issue.}"; exit 0 ;;
esac
printf 'branches/142-anchor-pr-review-comments-on-changed-lines\tmain\t%s\tfalse\n' "${STUB_STATE:-MERGED}"
STUB

# NOTE the \r\n: real az on Windows emits CRLF, and modelling that is the whole
# point — the LF-only stub this replaces could not see the CRLF bug.
cat > "$STUB_DIR/az" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_ARGS_FILE:-}" ] && echo "$@" >> "$STUB_ARGS_FILE"
case "${STUB_MODE:-ok}" in
    notfound)
        echo "ERROR: TF401180: The requested pull request was not found." >&2
        exit 1 ;;
    empty)
        printf '\r\n'; exit 0 ;;
    short)
        printf 'refs/heads/branches/7493-apm-errors-noticeerror-poc\r\n'; exit 0 ;;
    noisy)
        echo "Command group 'repos pr' is in preview and under development." >&2
        printf 'refs/heads/branches/7493-apm-errors-noticeerror-poc\r\nrefs/heads/main\r\ncompleted\r\nBgvCore\r\n'; exit 0 ;;
    otherrepo)
        printf 'refs/heads/branches/7493-apm-errors-noticeerror-poc\r\nrefs/heads/main\r\ncompleted\r\nSomeOtherRepo\r\n'; exit 0 ;;
esac
# Work-item lookup's description query — see the note on the gh stub above.
case "$*" in
    *description*) printf '%s\r\n' "${STUB_PR_BODY:-A description with no linked work item.}"; exit 0 ;;
esac
printf 'refs/heads/branches/7493-apm-errors-noticeerror-poc\r\nrefs/heads/main\r\n%s\r\nBgvCore\r\n' "${STUB_STATE:-completed}"
STUB

chmod +x "$STUB_DIR/gh" "$STUB_DIR/az"
export PATH="$STUB_DIR:$PATH"

# ── Fixture ──────────────────────────────────────────────────────────

setup_repo() {
    local dir="$1" remote="${2:-}"
    if ! git init -q --initial-branch=main "$dir" >/dev/null 2>&1; then
        echo "setup_repo: git init failed for $dir" >&2
        return 1
    fi
    # A real commit, so HEAD can detach and a branch can be checked out —
    # without one, BRANCH_MATCH=true and detached HEAD are untestable.
    if ! git -C "$dir" commit -q --allow-empty -m "fixture" >/dev/null 2>&1; then
        echo "setup_repo: fixture commit failed for $dir" >&2
        return 1
    fi
    if [ -n "$remote" ]; then
        if ! git -C "$dir" remote add origin "$remote" >/dev/null 2>&1; then
            echo "setup_repo: git remote add failed for $dir" >&2
            return 1
        fi
    fi
    return 0
}

GH_REPO="$TEST_TMPDIR/gh-repo"
ADO_REPO="$TEST_TMPDIR/ado-repo"
NO_REMOTE_REPO="$TEST_TMPDIR/no-remote-repo"
ODD_REPO="$TEST_TMPDIR/odd-repo"
TRAP_REPO="$TEST_TMPDIR/trap-repo"

setup_repo "$GH_REPO"        "https://github.com/TimZander/claude.git" || exit 1
setup_repo "$ADO_REPO"       "https://dev.azure.com/bgvone/BGV%20Development/_git/BgvCore" || exit 1
setup_repo "$NO_REMOTE_REPO" "" || exit 1
setup_repo "$ODD_REPO"       "https://gitlab.com/someone/thing.git" || exit 1
# Host detection must key on the host component, not a substring of the URL.
setup_repo "$TRAP_REPO"      "https://gitlab.com/me/github.com-mirror.git" || exit 1

run_in() {
    local dir="$1"; shift
    ( cd "$dir" && bash "$SCRIPT" "$@" 2>&1 )
}

# stdout only — proves errors do not pollute the KEY=value stream.
run_in_stdout() {
    local dir="$1"; shift
    ( cd "$dir" && bash "$SCRIPT" "$@" 2>/dev/null )
}

echo "test_resolve-pr.sh"

# ── Stub sentinel ────────────────────────────────────────────────────
# If PATH prepending failed, every lookup test would silently exercise the live
# CLI and the offline guarantee would be void.
assert_contains "$STUB_DIR" "$(command -v gh)" "gh stub is on PATH (not the live CLI)"
assert_contains "$STUB_DIR" "$(command -v az)" "az stub is on PATH (not the live CLI)"

# ── Syntax ───────────────────────────────────────────────────────────
bash -n "$SCRIPT" 2>/dev/null
assert_exit 0 $? "script parses"

# ── Usage / pre-flight errors ────────────────────────────────────────
out=$(run_in "$GH_REPO" --bogus); rc=$?
assert_exit 1 "$rc" "unknown argument exits 1"
assert_contains "Unknown argument" "$out" "unknown argument names the flag"

out=$(run_in "$GH_REPO" --args); rc=$?
assert_exit 1 "$rc" "--args with no value exits 1"
assert_contains "--args requires a value" "$out" "--args with no value explains itself"

out=$(run_in "$GH_REPO" --args "a" --args "b"); rc=$?
assert_exit 1 "$rc" "repeated --args exits 1"

# A PR reference genuinely needs a reachable host — these must fail.
out=$(run_in "$NO_REMOTE_REPO" --args "pr 1"); rc=$?
assert_exit 1 "$rc" "PR reference with no origin remote exits 1"
assert_contains "no 'origin' remote" "$out" "missing origin explains itself"

out=$(run_in "$ODD_REPO" --args "pr 1"); rc=$?
assert_exit 1 "$rc" "PR reference on an unsupported host exits 1"
assert_contains "could not determine hosting platform" "$out" "unsupported host explains itself"

# ── Unsupported/absent hosts must NOT break an ordinary review ───────
# This step runs for ANY non-empty arguments, and most invocations carry no PR
# reference. Failing early here would break `/deep-review focus on X` for every
# GitLab, Bitbucket, self-hosted and remote-less repo — a review that works
# today. Host trouble may only surface when a PR actually has to be resolved.
out=$(run_in "$ODD_REPO" --args "focus on error handling"); rc=$?
assert_exit 0 "$rc" "focus area on an unsupported host still exits 0"
assert_contains "HOST=unknown" "$out" "unsupported host reports HOST=unknown"
assert_contains "KIND=none" "$out" "unsupported host with no PR reference resolves to none"
assert_contains "CURRENT_BRANCH=" "$out" "unsupported host still reports git context"

out=$(run_in "$NO_REMOTE_REPO" --args "focus on error handling"); rc=$?
assert_exit 0 "$rc" "focus area with no origin remote still exits 0"
assert_contains "HOST=unknown" "$out" "no remote reports HOST=unknown"
assert_contains "KIND=none" "$out" "no remote with no PR reference resolves to none"

# `#<N>` cannot be classified without a host (GitHub shares one issue/PR
# counter, ADO does not), so it stays prose rather than becoming a bad guess.
out=$(run_in "$ODD_REPO" --args "see #143 for background"); rc=$?
assert_exit 0 "$rc" "#<N> on an unsupported host exits 0"
assert_contains "KIND=none" "$out" "#<N> on an unsupported host is not classified"
assert_not_contains "REF_ID=" "$out" "#<N> on an unsupported host reports no ref id"

# ── Host detection ───────────────────────────────────────────────────
out=$(run_in "$GH_REPO" --args "focus on error handling"); rc=$?
assert_exit 0 "$rc" "no reference exits 0"
assert_contains "HOST=github" "$out" "github remote detected"
assert_contains "KIND=none" "$out" "free-form text resolves to no reference"

out=$(run_in "$ADO_REPO" --args "focus on error handling"); rc=$?
assert_exit 0 "$rc" "azdo no-reference exits 0"
assert_contains "HOST=azdo" "$out" "azdo remote detected"

out=$(run_in "$TRAP_REPO" --args "pr 1"); rc=$?
assert_exit 1 "$rc" "host detection matches the host component, not a substring"
assert_contains "could not determine hosting platform" "$out" "github.com in a gitlab path is not GitHub"

out=$(run_in "$TRAP_REPO" --args "focus here")
assert_contains "HOST=unknown" "$out" "github.com in a gitlab path reports unknown, not github"

# ── ADO work-item carve-out ──────────────────────────────────────────
out=$(run_in "$ADO_REPO" --args "#7775"); rc=$?
assert_exit 0 "$rc" "ADO #<N> exits 0"
assert_contains "KIND=workitem" "$out" "ADO #<N> is a work item"
assert_contains "REF_ID=7775" "$out" "ADO #<N> reports the id"
assert_not_contains "SOURCE_BRANCH=" "$out" "ADO #<N> selects no branch"

# ── ADO PR resolution, normalization, CRLF ───────────────────────────
export STUB_ARGS_FILE="$TEST_TMPDIR/az-args"
rm -f "$STUB_ARGS_FILE"
out=$(run_in "$ADO_REPO" --args "pr 4506"); rc=$?
assert_exit 0 "$rc" "ADO pr <N> exits 0"
assert_contains "KIND=pr" "$out" "ADO pr <N> resolves to a PR"
# The trap: the branch legitimately contains a `branches/` segment, so only an
# anchored refs/heads/ strip is correct. A greedy strip yields a branch that
# does not exist.
assert_contains "SOURCE_BRANCH=branches/7493-apm-errors-noticeerror-poc" "$out" \
    "ADO ref strips only the anchored refs/heads/ prefix"
assert_contains "TARGET_BRANCH=main" "$out" "ADO target ref normalized"
assert_contains "STATE=merged" "$out" "ADO 'completed' maps to merged"
assert_contains "BRANCH_MATCH=false" "$out" "mismatch against current HEAD reported"
# CRLF: az emits \r\n on Windows. A surviving \r makes git reject the ref.
assert_not_contains "$(printf '\r')" "$out" "no carriage return survives into the output"
assert_contains "--id 4506" "$(cat "$STUB_ARGS_FILE" 2>/dev/null)" "az is called with the parsed REF_ID"
assert_contains "https://dev.azure.com/bgvone" "$(cat "$STUB_ARGS_FILE" 2>/dev/null)" \
    "ADO org URL derived from remote"
unset STUB_ARGS_FILE

out=$(STUB_MODE=noisy run_in "$ADO_REPO" --args "pr 4506"); rc=$?
assert_exit 0 "$rc" "ADO preview notice on stderr still exits 0"
assert_contains "SOURCE_BRANCH=branches/7493-apm-errors-noticeerror-poc" "$out" \
    "az stderr notice does not contaminate SOURCE_BRANCH"
assert_contains "STATE=merged" "$out" "az stderr notice does not shift the fields"

out=$(STUB_MODE=empty run_in "$ADO_REPO" --args "pr 4506"); rc=$?
assert_exit 1 "$rc" "ADO empty lookup output exits 1"
assert_contains "returned no branch names" "$out" "ADO empty lookup explains itself"

out=$(STUB_MODE=short run_in "$ADO_REPO" --args "pr 4506"); rc=$?
assert_exit 1 "$rc" "ADO short lookup output exits 1"

out=$(STUB_MODE=otherrepo run_in "$ADO_REPO" --args "pr 4506"); rc=$?
assert_exit 1 "$rc" "ADO PR from another repo in the org exits 1"
assert_contains "belongs to repository" "$out" "cross-repo ADO PR explains itself"

out=$(STUB_MODE=notfound run_in "$ADO_REPO" --args "pr 999999"); rc=$?
assert_exit 1 "$rc" "unresolvable ADO PR exits 1"
assert_contains "Could not resolve Azure DevOps PR" "$out" "ADO lookup failure explains itself"

out=$(STUB_STATE=active run_in "$ADO_REPO" --args "pr 4506")
assert_contains "STATE=open" "$out" "ADO 'active' maps to open"
out=$(STUB_STATE=abandoned run_in "$ADO_REPO" --args "pr 4506")
assert_contains "STATE=abandoned" "$out" "ADO 'abandoned' maps to abandoned"
out=$(STUB_STATE=notSet run_in "$ADO_REPO" --args "pr 4506")
assert_contains "STATE=notSet" "$out" "unrecognized ADO state passes through"

# ── GitHub PR resolution ─────────────────────────────────────────────
export STUB_ARGS_FILE="$TEST_TMPDIR/gh-args"
rm -f "$STUB_ARGS_FILE"
out=$(run_in "$GH_REPO" --args "pr 170"); rc=$?
assert_exit 0 "$rc" "GitHub pr <N> exits 0"
assert_contains "KIND=pr" "$out" "GitHub pr <N> resolves to a PR"
assert_contains "SOURCE_BRANCH=branches/142-anchor-pr-review-comments-on-changed-lines" "$out" \
    "GitHub bare head ref passes through normalization unchanged"
assert_contains "STATE=merged" "$out" "GitHub MERGED maps to merged"
assert_contains "170" "$(cat "$STUB_ARGS_FILE" 2>/dev/null)" "gh is called with the parsed REF_ID"
unset STUB_ARGS_FILE

out=$(STUB_MODE=noisy run_in "$GH_REPO" --args "pr 170")
assert_contains "SOURCE_BRANCH=branches/142-anchor-pr-review-comments-on-changed-lines" "$out" \
    "gh stderr notice does not contaminate SOURCE_BRANCH"

out=$(STUB_MODE=empty run_in "$GH_REPO" --args "pr 170"); rc=$?
assert_exit 1 "$rc" "GitHub empty lookup output exits 1"

out=$(STUB_MODE=fork run_in "$GH_REPO" --args "pr 170"); rc=$?
assert_exit 1 "$rc" "fork PR exits 1 rather than naming an unfetchable branch"
assert_contains "comes from a fork" "$out" "fork PR explains itself"

out=$(STUB_STATE=OPEN run_in "$GH_REPO" --args "pr 170")
assert_contains "STATE=open" "$out" "GitHub OPEN maps to open"
out=$(STUB_STATE=CLOSED run_in "$GH_REPO" --args "pr 170")
assert_contains "STATE=closed" "$out" "GitHub CLOSED maps to closed"

out=$(run_in "$GH_REPO" --args "https://github.com/TimZander/claude/pull/170"); rc=$?
assert_exit 0 "$rc" "GitHub PR URL exits 0"
assert_contains "KIND=pr" "$out" "GitHub PR URL resolves to a PR"
assert_contains "REF_ID=170" "$out" "PR URL yields the right number"

out=$(run_in "$GH_REPO" --args "https://dev.azure.com/o/p/_git/r/pullrequest/9"); rc=$?
assert_exit 1 "$rc" "PR URL from another host exits 1"
assert_contains "but origin is" "$out" "cross-host PR URL explains itself"

# ── GitHub #<N> ambiguity ────────────────────────────────────────────
out=$(run_in "$GH_REPO" --args "#170"); rc=$?
assert_exit 0 "$rc" "GitHub #<N> naming a PR exits 0"
assert_contains "KIND=pr" "$out" "GitHub #<N> naming a PR selects the branch"

out=$(STUB_MODE=notfound run_in "$GH_REPO" --args "#143"); rc=$?
assert_exit 0 "$rc" "GitHub #<N> naming an issue exits 0"
assert_contains "KIND=issue" "$out" "GitHub #<N> falls back to issue"
assert_contains "REF_ID=143" "$out" "issue fallback still reports the id"
assert_contains "CURRENT_BRANCH=" "$out" "issue fallback still reports git context (run completed)"
assert_not_contains "SOURCE_BRANCH=" "$out" "issue selects no branch"

# A transport/auth failure must NOT be mistaken for "it's an issue" — that would
# silently downgrade to reviewing HEAD.
out=$(STUB_MODE=authfail run_in "$GH_REPO" --args "#143"); rc=$?
assert_exit 1 "$rc" "network/auth failure on #<N> exits 1 rather than downgrading to issue"
assert_not_contains "KIND=issue" "$out" "auth failure is not treated as an issue"

out=$(STUB_MODE=notfound run_in "$GH_REPO" --args "pr 999999"); rc=$?
assert_exit 1 "$rc" "unresolvable explicit GitHub PR exits 1"
assert_contains "Could not resolve GitHub PR" "$out" "GitHub lookup failure explains itself"

# ── BRANCH_MATCH both ways ───────────────────────────────────────────
# Without this, an inverted comparison would pass every other assertion.
MATCH_REPO="$TEST_TMPDIR/match-repo"
setup_repo "$MATCH_REPO" "https://github.com/TimZander/claude.git" || exit 1
git -C "$MATCH_REPO" checkout -q -b "branches/142-anchor-pr-review-comments-on-changed-lines"
out=$(run_in "$MATCH_REPO" --args "pr 170")
assert_contains "BRANCH_MATCH=true" "$out" "BRANCH_MATCH is true when HEAD is the PR branch"

# Detached HEAD: CURRENT_BRANCH is empty and must never compare equal.
DETACHED_REPO="$TEST_TMPDIR/detached-repo"
setup_repo "$DETACHED_REPO" "https://github.com/TimZander/claude.git" || exit 1
git -C "$DETACHED_REPO" checkout -q --detach HEAD
out=$(run_in "$DETACHED_REPO" --args "pr 170")
assert_contains "CURRENT_BRANCH=" "$out" "detached HEAD reports an empty current branch"
assert_contains "BRANCH_MATCH=false" "$out" "empty branch never matches an empty HEAD"

# ── IN_WORKTREE both ways ────────────────────────────────────────────
out=$(run_in "$GH_REPO" --args "focus here")
assert_contains "IN_WORKTREE=false" "$out" "plain checkout is not a worktree"

WT_PARENT="$TEST_TMPDIR/wt-parent"
setup_repo "$WT_PARENT" "https://github.com/TimZander/claude.git" || exit 1
WT_PATH="$TEST_TMPDIR/wt-child"
git -C "$WT_PARENT" worktree add -q -b wt-branch "$WT_PATH" >/dev/null 2>&1
out=$(run_in "$WT_PATH" --args "focus here")
assert_contains "IN_WORKTREE=true" "$out" "worktree is detected"
# cwd-independence: `test -f .git` reported false from any subdirectory.
mkdir -p "$WT_PATH/nested/deeper"
out=$(run_in "$WT_PATH/nested/deeper" --args "focus here")
assert_contains "IN_WORKTREE=true" "$out" "worktree still detected from a subdirectory"

# ── stdout hygiene ───────────────────────────────────────────────────
out=$(run_in_stdout "$ODD_REPO" --args "pr 1")
assert_not_contains "Error" "$out" "errors go to stderr, never into the KEY=value stream"

# ── Token precedence ─────────────────────────────────────────────────
# A dropped PR selector means reviewing the wrong branch; a dropped context URL
# only means less context. So `pr <N>` must outrank the context URLs.
out=$(run_in "$GH_REPO" --args "pr 170 https://github.com/TimZander/claude/issues/42")
assert_contains "KIND=pr" "$out" "pr <N> wins over an issue URL"
assert_contains "REF_ID=170" "$out" "pr <N> + issue URL keeps the PR number"

out=$(run_in "$ADO_REPO" --args "pr 4506 https://dev.azure.com/bgvone/p/_workitems/edit/7775")
assert_contains "KIND=pr" "$out" "pr <N> wins over a work-item URL"
assert_contains "REF_ID=4506" "$out" "pr <N> + work-item URL keeps the PR number"

out=$(run_in "$GH_REPO" --args "https://github.com/TimZander/claude/pull/170 #143")
assert_contains "REF_ID=170" "$out" "PR URL wins over a bare #<N>"

out=$(run_in "$GH_REPO" --args "pr 170 #143")
assert_contains "REF_ID=170" "$out" "pr <N> wins over a bare #<N>"

out=$(run_in "$GH_REPO" --args "https://github.com/TimZander/claude/issues/42")
assert_contains "KIND=issue" "$out" "GitHub issue URL alone resolves to an issue"
assert_contains "REF_ID=42" "$out" "issue URL yields the right number"

out=$(run_in "$ADO_REPO" --args "https://dev.azure.com/bgvone/p/_workitems/edit/7775")
assert_contains "KIND=workitem" "$out" "ADO work-item URL resolves to a work item"

# ── Multiple PR references ───────────────────────────────────────────
# The leftmost reference is selected; the rest are reported, never targeted.
out=$(run_in "$GH_REPO" --args "pr 3, and check specifically against work done in pr 4")
assert_contains "REF_ID=3" "$out" "leftmost pr <N> is the selected target"
assert_contains "OTHER_REFS=4" "$out" "the other PR number is reported, not selected"

# Word order is a guess, not intent — this picks 4. OTHER_REFS is what lets the
# caller surface that so the user can catch it.
out=$(run_in "$GH_REPO" --args "check against work done in pr 4, then review pr 3")
assert_contains "REF_ID=4" "$out" "reversed order selects the leftmost (4)"
assert_contains "OTHER_REFS=3" "$out" "reversed order still reports the other (3)"

out=$(run_in "$GH_REPO" --args "pr 170")
assert_not_contains "OTHER_REFS" "$out" "a single reference reports no OTHER_REFS"

out=$(run_in "$GH_REPO" --args "pr 170 and again pr 170")
assert_not_contains "OTHER_REFS" "$out" "a repeated reference to the same PR is not an 'other'"

out=$(run_in "$GH_REPO" --args "https://github.com/TimZander/claude/pull/170 compare with pr 4")
assert_contains "REF_ID=170" "$out" "PR URL is selected over a later pr <N>"
assert_contains "OTHER_REFS=4" "$out" "pr <N> alongside a PR URL is reported as other"

out=$(run_in "$GH_REPO" --args "pr 3 vs pr 4 vs pr 5")
assert_contains "OTHER_REFS=4,5" "$out" "several other references are reported in order"

out=$(run_in "$GH_REPO" --args "focus on error handling")
assert_not_contains "OTHER_REFS" "$out" "no reference reports no OTHER_REFS"

# ── Token boundaries ─────────────────────────────────────────────────
out=$(run_in "$GH_REPO" --args "compr 4 and other words")
assert_contains "KIND=none" "$out" "'compr 4' does not match the pr token"

out=$(run_in "$GH_REPO" --args "pr 170x")
assert_contains "KIND=none" "$out" "'pr 170x' does not match the pr token"

out=$(run_in "$GH_REPO" --args "abc#143")
assert_contains "KIND=none" "$out" "'abc#143' does not match the bare #<N> token"

# Trailing punctuation used to silently degrade to KIND=none — i.e. to a review
# of the wrong branch — for a very plausible invocation.
out=$(run_in "$GH_REPO" --args "please review PR #170, focus on tests")
assert_contains "REF_ID=170" "$out" "'PR #170,' matches despite the trailing comma"

out=$(run_in "$GH_REPO" --args "review pr 170.")
assert_contains "REF_ID=170" "$out" "'pr 170.' matches despite the trailing period"

out=$(run_in "$GH_REPO" --args "(pr 170)")
assert_contains "REF_ID=170" "$out" "'(pr 170)' matches inside parentheses"

out=$(run_in "$GH_REPO" --args "Pr 170")
assert_contains "REF_ID=170" "$out" "the pr token is case-insensitive"

out=$(run_in "$GH_REPO" --args "pr #170")
assert_contains "REF_ID=170" "$out" "'pr #170' matches with the optional hash"

# ── Work item resolution ─────────────────────────────────────────────
# The headline case: a PR reference and a story reference in one invocation.
# Before WORKITEM_* existed, the single precedence chain resolved the PR and
# silently dropped the issue, so Feature Fitness graded the diff against the
# branch name instead of the acceptance criteria.

out=$(run_in "$GH_REPO" --args "pr 170 https://github.com/TimZander/claude/issues/42")
assert_contains "REF_ID=170" "$out" "PR + issue URL: the PR is still selected"
assert_contains "WORKITEM_KIND=issue" "$out" "PR + issue URL: the issue is resolved too"
assert_contains "WORKITEM_ID=42" "$out" "PR + issue URL: the issue id survives"
assert_contains "WORKITEM_SOURCE=argument" "$out" "PR + issue URL: route reported as argument"

out=$(run_in "$ADO_REPO" --args "pr 4506 https://dev.azure.com/bgvone/Proj/_workitems/edit/7775")
assert_contains "REF_ID=4506" "$out" "ADO PR + work-item URL: the PR is still selected"
assert_contains "WORKITEM_KIND=workitem" "$out" "ADO PR + work-item URL: the work item resolves"
assert_contains "WORKITEM_ID=7775" "$out" "ADO PR + work-item URL: the work-item id survives"

# Route 2 — the PR's own description. The keyword match is case-insensitive and
# tolerates the past-tense forms GitHub accepts.
out=$(STUB_PR_BODY="Rework the thing. Fixes #318" run_in "$GH_REPO" --args "pr 170")
assert_contains "WORKITEM_ID=318" "$out" "pr-body: 'Fixes #318' is discovered"
assert_contains "WORKITEM_SOURCE=pr-body" "$out" "pr-body: route reported as pr-body"

out=$(STUB_PR_BODY="closed #77 as part of this" run_in "$GH_REPO" --args "pr 170")
assert_contains "WORKITEM_ID=77" "$out" "pr-body: lowercase past-tense 'closed' matches"

out=$(STUB_PR_BODY="Linked to AB#9912 for tracking" run_in "$ADO_REPO" --args "pr 4506")
assert_contains "WORKITEM_KIND=workitem" "$out" "pr-body: AB#<id> is an ADO work item"
assert_contains "WORKITEM_ID=9912" "$out" "pr-body: AB#<id> id is extracted"

# Route 3 — our own branches/<id>-<slug> convention. The gh stub's PR resolves
# to branches/142-..., and its default body carries no link, so the fall-through
# to the branch name is what supplies the id.
out=$(run_in "$GH_REPO" --args "pr 170")
assert_contains "WORKITEM_ID=142" "$out" "branch-prefix: id read from the PR's source branch"
assert_contains "WORKITEM_SOURCE=branch-prefix" "$out" "branch-prefix: route reported as branch-prefix"

# With no PR at all the branch under review is the checked-out one.
WI_REPO="$TEST_TMPDIR/wi-repo"
setup_repo "$WI_REPO" "https://github.com/TimZander/claude.git" || exit 1
git -C "$WI_REPO" checkout -q -b "branches/220-deep-review-read-the-story" || exit 1
out=$(run_in "$WI_REPO" --args "focus on tests")
assert_contains "KIND=none" "$out" "branch-prefix: no PR reference is still no PR"
assert_contains "WORKITEM_ID=220" "$out" "branch-prefix: id read from the current branch"

# A number that is not the branch's leading segment must not be mistaken for
# the story id — anchoring is the whole reason this route is safe to trust.
git -C "$WI_REPO" checkout -q -b "branches/fix-220-thing" || exit 1
out=$(run_in "$WI_REPO" --args "focus on tests")
assert_contains "WORKITEM_KIND=none" "$out" "branch-prefix: an embedded number does not match"

# "No story found" must be reported explicitly, and must stay distinguishable
# from a story that was found — a review that skipped fitness-checking should
# not look identical to one that passed it.
out=$(run_in "$GH_REPO" --args "focus on error handling")
assert_contains "WORKITEM_KIND=none" "$out" "no reference and no numbered branch reports none"
assert_not_contains "WORKITEM_ID=" "$out" "no work item omits WORKITEM_ID entirely"

# A host we cannot query cannot classify a bare number either, so the work item
# stays unresolved rather than being reported as a kind we cannot fetch.
out=$(run_in "$ODD_REPO" --args "#143")
assert_contains "WORKITEM_KIND=none" "$out" "unknown host does not classify a bare #<N>"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
