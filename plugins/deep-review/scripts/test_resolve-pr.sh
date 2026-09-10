#!/usr/bin/env bash
# Smoke test for resolve-pr.sh.
# Runs a set of scenarios and asserts exit code + output pattern.
# Invoke: bash scripts/test_resolve-pr.sh
#
# Coverage: syntax, usage errors, host detection (incl. ssh and visualstudio
# dialects), token parsing and precedence, boundary matching, the ADO
# work-item carve-out, ref normalization, CRLF handling, stderr contamination,
# empty/short lookup output, PR-state mapping, BRANCH_MATCH both ways,
# IN_WORKTREE both ways, fork and cross-repo rejection, the PR-vs-issue
# fallback for an ambiguous #<N>, and work-item resolution — all four routes,
# their precedence, the word-boundary and branch-anchoring negatives, the
# cross-repo/cross-host/cross-org guards, ORG emission, and the three-way
# difference between "no story", "the PR's work-item links could not be read"
# and "the PR body could not be read".
#
#   STUB_PR_BODY=<text>      body returned by the description lookup (\n expanded)
#   STUB_BODY_FAIL=1         fail ONLY the body call, not the branch lookup
#   STUB_WI_LINKS=<ids>      work-item ids the PR links (\n expanded, one per
#                            line; the stub emits CRLF per line as real az does)
#   STUB_WI_LINKS_FAIL=1     fail ONLY the work-item link call
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
# INT/TERM exit rather than falling through. Without the explicit exit, bash
# runs the handler and then RESUMES the suite — against a temp dir that no
# longer has the stubs or fixtures in it. Every remaining case then invokes a
# missing script, and every assert_not_contains scores green against the
# resulting error text, so an interrupted run reports a large, confident,
# entirely fictional tally instead of simply stopping. This cost a reviewer a
# false "126 passed / 133 failed" before it was diagnosed.
cleanup_tmpdir() { if [ -n "$TEST_TMPDIR" ]; then rm -rf "$TEST_TMPDIR"; fi; }
trap cleanup_tmpdir EXIT
trap 'cleanup_tmpdir; exit 130' INT
trap 'cleanup_tmpdir; exit 143' TERM

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

# Exact whole-line match. assert_contains is a substring test, so
# `WORKITEM_ID=42` also passes on `WORKITEM_ID=421` — fine for prose, wrong for
# an id. Every KEY=value assertion on a number should use this instead.
assert_line() {
    local needle="$1" out="$2" label="$3"
    case "
$out
" in
        *"
$needle
"*) pass=$((pass + 1)); echo "  PASS $label" ;;
        *) fail=$((fail + 1)); echo "  FAIL $label: no line equal to '$needle'"; echo "    got: $out" ;;
    esac
}

# Exact whole-line negative. assert_not_contains is substring-based and
# therefore OVER-strict on numbers: a correct `WORKITEM_ID=51` fails an
# assert_not_contains "WORKITEM_ID=5". Use this for any numeric negative.
assert_no_line() {
    local needle="$1" out="$2" label="$3"
    case "
$out
" in
        *"
$needle
"*) fail=$((fail + 1)); echo "  FAIL $label: unexpected line '$needle'"; echo "    got: $out" ;;
        *) pass=$((pass + 1)); echo "  PASS $label" ;;
    esac
}

# Self-test, because a broken matcher turns every assertion using it into a
# silent pass — the same blind spot as an untested code path.
assert_line "b" "$(printf 'a\nb\nc')" "assert_line matches an interior line"
assert_line "a" "$(printf 'a\nb')" "assert_line matches the first line"
assert_line "c" "$(printf 'a\nc')" "assert_line matches the last line"
assert_no_line "WORKITEM_ID=4" "WORKITEM_ID=42" "assert_line is not a substring match"
assert_no_line "b" "$(printf 'a\nc')" "assert_no_line passes when absent"

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
# The work-item lookup's SECOND call, asking only for the PR body. Dispatched
# on argv, not on STUB_MODE, so it is reachable in every mode the branch lookup
# survives (including `noisy`, which is a success mode). STUB_BODY_FAIL makes
# only this call fail, which is the one shape the real world produces that the
# mode-based stubs cannot: branch lookup fine, body fetch refused.
# %b so a test can embed \n and model a real multi-line description.
case "$*" in
    *"--json body"*)
        if [ -n "${STUB_BODY_FAIL:-}" ]; then
            echo "error connecting to api.github.com: no such host" >&2
            exit 1
        fi
        printf '%b\n' "${STUB_PR_BODY:-A description with no linked issue.}"; exit 0 ;;
esac
printf 'branches/142-anchor-pr-review-comments-on-changed-lines\tmain\t%s\tfalse\n' "${STUB_STATE:-MERGED}"
STUB

# NOTE the \r\n: real az on Windows emits CRLF, and modelling that is the whole
# point — the LF-only stub this replaces could not see the CRLF bug.
cat > "$STUB_DIR/az" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_ARGS_FILE:-}" ] && echo "$@" >> "$STUB_ARGS_FILE"
# DISPATCH BY ARGUMENT BEFORE STUB_MODE. The STUB_MODE cases below all model
# `az repos pr show` responses; when this block sat after them, `noisy`/`short`/
# `otherrepo` answered the work-item call with branch refs, which the resolver
# reads as unintelligible. That made those modes silently mean something else on
# ADO, and — worse — `noisy` is the only mode that models an az notice on
# stderr, so the new call's stderr redirection could never be exercised by it.
#
# CRLF ON EVERY LINE, not just the last: real az on Windows terminates each line
# with \r\n (verified against a live PR: `8421\r\n`). A `printf '%b\r\n'` over
# the whole list only marked the final id, so the strip-before-numeric-filter
# invariant was tested on one element.
case "$*" in
    *"work-item list"*)
        if [ -n "${STUB_WI_LINKS_FAIL:-}" ]; then
            echo "ERROR: TF400813: The user is not authorized to access this resource." >&2
            exit 1
        fi
        [ -n "${STUB_WI_LINKS:-}" ] || exit 0
        # `|| [ -n "$wi" ]` because `printf '%b'` emits no trailing newline, so
        # a plain `read` loop discards the LAST line — which for a single-value
        # fixture is the whole payload. That silently turned the
        # unintelligible-output test into an empty-output test.
        printf '%b' "$STUB_WI_LINKS" | while IFS= read -r wi || [ -n "$wi" ]; do
            printf '%s\r\n' "$wi"
        done
        exit 0 ;;
esac
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
# CRLF here too: the body path must strip \r exactly like the branch path does.
case "$*" in
    *"--query description"*)
        if [ -n "${STUB_BODY_FAIL:-}" ]; then
            echo "ERROR: TF400813: The user is not authorized to access this resource." >&2
            exit 1
        fi
        printf '%b\r\n' "${STUB_PR_BODY:-A description with no linked work item.}"; exit 0 ;;
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

# A NEGATIVE ASSERTION MUST NOT PASS ON OUTPUT THAT NEVER RAN.
#
# assert_not_contains and assert_no_line are satisfied by ANY text lacking the
# needle — including `bash: .../resolve-pr.sh: No such file or directory`. When
# an interrupted run deleted the fixtures mid-suite, every negative check in the
# file scored green against that error, turning the most safety-critical
# assertions in the suite ("this key must NOT be emitted") into unconditional
# passes. The trap above stops that specific cause; this stops the class.
#
# Every negative assertion below should run its output through this first. HOST
# is emitted by every successful invocation on every host, so its presence is a
# cheap proof that the script actually produced a KEY=value block.
# Split into a silent predicate and a reporting wrapper, so the self-test below
# can exercise the negative case without printing a FAIL it then has to undo.
_ran_ok() {
    case "
$1
" in
        *"
HOST="*) return 0 ;;
    esac
    return 1
}

assert_ran() {
    local out="$1" label="$2"
    if _ran_ok "$out"; then
        return 0
    fi
    fail=$((fail + 1))
    echo "  FAIL $label: script produced no KEY=value output — a negative assertion here would pass vacuously"
    echo "    got: $out"
    return 1
}

# Self-test, same reasoning as the matcher self-tests above: a guard that always
# returned success would silently restore every vacuous pass it exists to catch.
if _ran_ok "$(printf 'HOST=github\nKIND=none')"; then
    pass=$((pass + 1)); echo "  PASS assert_ran accepts real output"
else
    fail=$((fail + 1)); echo "  FAIL assert_ran rejected real output"
fi
if _ran_ok "bash: line 1: resolve-pr.sh: No such file or directory"; then
    fail=$((fail + 1)); echo "  FAIL assert_ran accepted crash output"
else
    pass=$((pass + 1)); echo "  PASS assert_ran rejects crash output"
fi

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
assert_contains "different repository" "$out" "cross-host PR URL explains itself"
assert_contains "origin:" "$out" "cross-host PR URL names the origin it compared against"

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
# The story behind the work, resolved independently of the PR so one
# invocation reports both. Ids are asserted with assert_line, never
# assert_contains: `WORKITEM_ID=42` is a substring of `WORKITEM_ID=421`.

# --- Route 1: explicit reference in the arguments --------------------
# The headline case. Before WORKITEM_* existed the single precedence chain
# resolved the PR and dropped the issue, so Feature Fitness graded against the
# branch name instead of the acceptance criteria.

out=$(run_in "$GH_REPO" --args "pr 170 https://github.com/TimZander/claude/issues/42")
assert_line "REF_ID=170" "$out" "PR + issue URL: the PR is still selected"
assert_line "WORKITEM_KIND=issue" "$out" "PR + issue URL: the issue is resolved too"
assert_line "WORKITEM_ID=42" "$out" "PR + issue URL: the issue id survives"
assert_line "WORKITEM_SOURCE=argument" "$out" "PR + issue URL: route reported as argument"

out=$(run_in "$ADO_REPO" --args "pr 4506 https://dev.azure.com/bgvone/Proj/_workitems/edit/7775")
assert_line "REF_ID=4506" "$out" "ADO PR + work-item URL: the PR is still selected"
assert_line "WORKITEM_KIND=workitem" "$out" "ADO PR + work-item URL: the work item resolves"
assert_line "WORKITEM_ID=7775" "$out" "ADO PR + work-item URL: the work-item id survives"

# A work-item URL outranks an issue URL, matching the main precedence chain.
out=$(run_in "$ADO_REPO" --args "https://dev.azure.com/bgvone/P/_workitems/edit/10 https://github.com/TimZander/claude/issues/20")
assert_line "WORKITEM_ID=10" "$out" "route 1: work-item URL outranks an issue URL"

# Bare #<N>, and the scan that makes it safe. `pr #<N>` is a supported form, so
# the first #<N> in the arguments is frequently the PR itself; an earlier draft
# abandoned the whole route in that case and silently dropped the user's real
# issue reference — the exact bug this feature exists to prevent.
out=$(run_in "$GH_REPO" --args "pr #170 and see #143")
assert_line "REF_ID=170" "$out" "bare #N: the PR is still selected"
assert_line "WORKITEM_ID=143" "$out" "bare #N: scan skips the PR and finds the next reference"
assert_line "WORKITEM_SOURCE=argument" "$out" "bare #N: reported as an explicit argument"

# ...and when the ONLY #<N> is the PR, nothing is invented from it.
out=$(run_in "$GH_REPO" --args "pr #170")
assert_not_contains "WORKITEM_ID=170" "$out" "bare #N: the PR is never its own story"
assert_not_contains "WORKITEM_SOURCE=argument" "$out" "bare #N: PR-only args yield no argument route"

out=$(run_in "$ADO_REPO" --args "#7775 focus on error handling")
assert_line "WORKITEM_KIND=workitem" "$out" "ADO bare #N is a work item"
assert_line "WORKITEM_ID=7775" "$out" "ADO bare #N reports the id"
assert_line "WORKITEM_SOURCE=argument" "$out" "ADO bare #N is an explicit argument"

# Cross-repo and cross-host guards. The number alone is meaningless: the caller
# fetches it against origin, so a foreign id resolves to a DIFFERENT real story
# and grades the diff against it while claiming "authoritative" provenance.
out=$(run_in "$GH_REPO" --args "https://github.com/SOMEONE-ELSE/other/issues/42")
assert_not_contains "WORKITEM_ID=42" "$out" "cross-repo issue URL is refused"
assert_not_contains "WORKITEM_SOURCE=argument" "$out" "cross-repo issue URL claims no provenance"

out=$(run_in "$GH_REPO" --args "https://gitlab.com/someone/thing/issues/99")
assert_not_contains "WORKITEM_ID=99" "$out" "cross-host issue URL is refused"

out=$(run_in "$ADO_REPO" --args "https://dev.azure.com/OTHERORG/P/_workitems/edit/555")
assert_not_contains "WORKITEM_ID=555" "$out" "cross-org ADO work-item URL is refused"

# ── Route 2: the PR's own work-item link (ADO) ───────────────────
# Precedence order is the file's layout order: route 1 (argument) above,
# this block, then route 3 (pr-body) and route 4 (branch-prefix) below.
# The link ADO's UI shows and the REST API returns as a relation. It needs no
# convention from the author — no AB# in the body, no numeric branch prefix —
# which is exactly why it was worth adding: a PR linked the way ADO itself
# links one resolved to NO story at all before this route existed.

out=$(STUB_WI_LINKS="8421" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_KIND=workitem" "$out" "pr-link: a linked work item is a workitem"
assert_line "WORKITEM_ID=8421" "$out" "pr-link: the linked id is discovered with no AB# and no branch prefix"
assert_line "WORKITEM_SOURCE=pr-link" "$out" "pr-link: route reported as pr-link"
assert_ran "$out" "pr-link: single-link run produced output" \
    && assert_not_contains "WORKITEM_OTHER_IDS" "$out" "pr-link: a single link reports no alternatives"

# WORKITEM_OTHER_IDS IS ABSENT WHENEVER THE ROUTE DID NOT RUN, not only when the
# choice was forced — so its absence proves nothing on its own, and the caller
# is told to read only its PRESENCE. A multi-link PR pre-empted by an explicit
# argument is the case most likely to mislead: five links, no alternatives
# reported, because route 2 never executed.
out=$(STUB_WI_LINKS="90\\n8421\\n7" run_in "$ADO_REPO" --args "pr 4506 #777")
assert_line "WORKITEM_ID=777" "$out" "pr-link: an explicit argument pre-empts a multi-link PR"
assert_ran "$out" "pr-link: pre-empted run produced output" \
    && assert_not_contains "WORKITEM_OTHER_IDS" "$out" "pr-link: a pre-empted route reports no alternatives despite several links"

# Precedence. The link is structural; the two text routes are conventions, so
# the link outranks both. The branch here carries 7493- and the body carries an
# AB#, so a regression to either route is visible rather than silent.
out=$(STUB_WI_LINKS="8421" STUB_PR_BODY="Rework the thing. AB#999" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_ID=8421" "$out" "pr-link: outranks AB#<id> in the PR body"
assert_line "WORKITEM_SOURCE=pr-link" "$out" "pr-link: outranks pr-body, and says so"

# …but an explicit argument still wins. The user naming a story is the one
# signal that outranks a structural link.
out=$(STUB_WI_LINKS="8421" run_in "$ADO_REPO" --args "pr 4506 #777")
assert_line "WORKITEM_ID=777" "$out" "pr-link: an explicit argument still outranks the link"
assert_line "WORKITEM_SOURCE=argument" "$out" "pr-link: argument route still reported as argument"

# MULTIPLE LINKS. ADO permits many; grading against an arbitrary one silently
# would be a wrong story wearing the confidence of a resolved one, so the first
# returned is selected and the REST ARE REPORTED — the OTHER_REFS contract.
#
# The order is taken as given and NOT sorted, but that is not the same as
# "ADO's relation order is preserved": `az repos pr work-item list` discards
# the relation refs and re-queries the WIT batch endpoint, whose ordering is
# undocumented. Sorting would layer a second unverified order on an unknown
# one. What makes the pick safe is WORKITEM_OTHER_IDS, not the ordering.
#
# MIXED WIDTHS, deliberately: with 8421/7100/9002 every candidate rule agrees,
# so the assertion cannot tell first-returned from numeric-min from
# lexicographic-min. 90/8421/7/9002 separates all three — first-returned is 90,
# numeric-min is 7, lexicographic-min is 7 as well.
out=$(STUB_WI_LINKS="90\\n8421\\n7\\n9002" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_ID=90" "$out" "pr-link: the first id returned wins — not the lowest, not sorted"
assert_line "WORKITEM_OTHER_IDS=8421,7,9002" "$out" "pr-link: the unselected links are reported in order of appearance"

# Duplicates must not appear as their own alternative, or the caller reports
# "graded against 8421, not against 8421".
out=$(STUB_WI_LINKS="8421\\n8421" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_ID=8421" "$out" "pr-link: duplicate links de-duplicate"
assert_ran "$out" "pr-link: duplicate-link run produced output" \
    && assert_not_contains "WORKITEM_OTHER_IDS" "$out" "pr-link: a duplicate is not reported as an alternative"

# PARTIAL NOISE FAILS CLOSED. This is the case the route got wrong: honouring
# noise only when NOTHING parsed meant a BOM — which attaches to the FIRST
# line — dropped the leading id and published the SECOND as the PR's sole,
# structurally-confirmed story with WORKITEM_LOOKUP=ok. A wrong story wearing
# the highest-confidence label the resolver has.
out=$(STUB_WI_LINKS="\\xef\\xbb\\xbf7493\\n7500" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_LOOKUP=pr-link-unreadable" "$out" "pr-link: a BOM on the first id fails closed"
assert_ran "$out" "pr-link: BOM run produced output" \
    && assert_no_line "WORKITEM_ID=7500" "$out" "pr-link: the second id is not promoted when the first is corrupt"

# The milder variant: a stray notice on stdout alongside perfectly good ids.
# The selection would have been correct here, but reporting `ok` asserts the
# route was fully read when part of its answer was not.
out=$(STUB_WI_LINKS="WARNING: preview\\n7493\\n7500" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_LOOKUP=pr-link-unreadable" "$out" "pr-link: noise alongside valid ids still fails closed"

# The az INVOCATION SHAPE. `--query "[].id"` is the most contract-critical
# string in this route and a typo in it would pass every assertion above, since
# the stub answers on "work-item list" alone. The gh arm asserts its own shape
# the same way further down.
WI_ARGS_LOG="$TEST_TMPDIR/wi-args.txt"
STUB_ARGS_FILE="$WI_ARGS_LOG" STUB_WI_LINKS="8421" run_in "$ADO_REPO" --args "pr 4506" >/dev/null 2>&1
assert_contains "work-item list" "$(cat "$WI_ARGS_LOG")" "pr-link: the work-item list subcommand is invoked"
assert_contains "--query [].id" "$(cat "$WI_ARGS_LOG")" "pr-link: the id-only query is passed verbatim"
assert_contains "--id 4506" "$(cat "$WI_ARGS_LOG")" "pr-link: the PR id is passed"

# A FAILED LOOKUP IS NOT AN EMPTY ONE. An auth or network failure must not let
# the branch-prefix guess below masquerade as proof the strongest route was
# checked and came back empty.
out=$(STUB_WI_LINKS_FAIL=1 run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_LOOKUP=pr-link-unreadable" "$out" "pr-link: a failed link lookup is reported, not swallowed"
STUB_WI_LINKS_FAIL=1 run_in "$ADO_REPO" --args "pr 4506" >/dev/null 2>&1; rc=$?
assert_exit 0 "$rc" "pr-link: a failed link lookup is non-fatal"

# BOTH ROUTES FAILING is the case that actually happens — one bad credential,
# a dead network or a wrong tenant breaks `az repos pr work-item list` and
# `az repos pr show` alike. The weaker route used to overwrite the stronger
# one's failure, so the caller heard only "the description could not be read"
# while presenting a branch-prefix guess.
out=$(STUB_WI_LINKS_FAIL=1 STUB_BODY_FAIL=1 run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_LOOKUP=pr-link-unreadable" "$out" "pr-link: when both routes fail, the stronger failure survives"

# The inverse must still work: a weaker-only failure is still reported.
out=$(STUB_BODY_FAIL=1 run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_LOOKUP=pr-body-unreadable" "$out" "pr-link: a body-only failure is still reported as such"

# The route must not fire without a PR. Unasserted before, and mutation-proved:
# dropping `KIND == "pr"` from the guard passed every test, while in production
# every bare /deep-review in an ADO repo would call the API with --id "".
#
# Its own fixture, on a branch that CARRIES a numeric prefix, so the run proves
# two things at once: the link route stayed silent, and the weaker route below
# it still resolved. $ADO_REPO cannot be used here — it sits on `main`, so
# branch-prefix finds nothing and WORKITEM_ID/WORKITEM_SOURCE are not emitted at
# all. Asserting them beside `WORKITEM_KIND=none` is self-contradictory, which
# is exactly how this block shipped red.
ADO_WI_REPO="$TEST_TMPDIR/ado-branchprefix-repo"
setup_repo "$ADO_WI_REPO" "https://dev.azure.com/bgvone/BGV%20Development/_git/BgvCore" || exit 1
git -C "$ADO_WI_REPO" checkout -q -b "branches/7493-apm-errors-noticeerror-poc" || exit 1
out=$(STUB_WI_LINKS="8421" run_in "$ADO_WI_REPO" --args "focus on error handling")
assert_line "KIND=none" "$out" "pr-link: no PR reference is still no PR"
assert_ran "$out" "pr-link: no-PR run produced output" \
    && assert_no_line "WORKITEM_ID=8421" "$out" "pr-link: the route does not fire without a resolved PR"
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "pr-link: the weaker route below it still resolves"
assert_line "WORKITEM_ID=7493" "$out" "pr-link: and resolves the branch's own id"
assert_line "WORKITEM_LOOKUP=ok" "$out" "pr-link: a route that never ran is not a failure"

# Non-numeric output cannot become a work item. The stub's other modes return
# branch refs from this same call shape, and `refs/heads/...` must not parse as
# an id.
out=$(STUB_WI_LINKS="refs/heads/main" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "pr-link: non-numeric output is ignored, not parsed as an id"
# …and is reported as UNREADABLE, not as "checked and came back empty". Output
# we did not understand is not proof the PR links nothing, and the header
# requires those two states stay distinguishable.
assert_line "WORKITEM_LOOKUP=pr-link-unreadable" "$out" "pr-link: unintelligible output fails closed"

# GitHub has no such relation — its linkage lives in the description, which the
# pr-body route already reads. The route must not fire there at all.
out=$(STUB_WI_LINKS="8421" STUB_PR_BODY="Fixes #318" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_SOURCE=pr-body" "$out" "pr-link: GitHub is unaffected — pr-body still wins there"
assert_line "WORKITEM_ID=318" "$out" "pr-link: GitHub resolves its own way"

# With no links at all, the routes below must behave exactly as before. This is
# the assertion that catches a stub default flipping and silently retiring them.
out=$(run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "pr-link: absent links leave the existing precedence untouched"
assert_ran "$out" "pr-link: absent-links run produced output" \
    && assert_not_contains "WORKITEM_OTHER_IDS" "$out" "pr-link: no alternatives are reported on a weaker route"
assert_line "WORKITEM_LOOKUP=ok" "$out" "pr-link: absent links are a clean result, not a failure"

# --- Route 3: the PR's own description -------------------------------

out=$(STUB_PR_BODY="Rework the thing.\n\nFixes #318" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=318" "$out" "pr-body: 'Fixes #318' on its own line is discovered"
assert_line "WORKITEM_SOURCE=pr-body" "$out" "pr-body: route reported as pr-body"

out=$(STUB_PR_BODY="closed #77 as part of this" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=77" "$out" "pr-body: lowercase past-tense 'closed' matches"

out=$(STUB_PR_BODY="Resolves: #91." run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=91" "$out" "pr-body: 'Resolves:' with trailing punctuation matches"

out=$(STUB_PR_BODY="Closes #12 and Closes #34" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=12" "$out" "pr-body: first closing reference wins"

# Word boundaries. Without them `prefixes`, `unclosed`, `collab#` and a trailing
# `#12abc` all resolve a confident, wrong story — and pr-body is the route the
# output labels "strong: the author asserted the link".
out=$(STUB_PR_BODY="This prefixes #12 in the log" run_in "$GH_REPO" --args "pr 170")
assert_not_contains "WORKITEM_ID=12" "$out" "pr-body: 'prefixes #12' does not match 'fixes'"

out=$(STUB_PR_BODY="left unclosed #5 for now" run_in "$GH_REPO" --args "pr 170")
assert_not_contains "WORKITEM_ID=5" "$out" "pr-body: 'unclosed #5' does not match 'closed'"

out=$(STUB_PR_BODY="Fixes #12abc" run_in "$GH_REPO" --args "pr 170")
assert_not_contains "WORKITEM_ID=12" "$out" "pr-body: a right boundary is required too"

out=$(STUB_PR_BODY="See collab#5 for context" run_in "$ADO_REPO" --args "pr 4506")
assert_not_contains "WORKITEM_ID=5" "$out" "pr-body: 'collab#5' does not match 'AB#'"

# AB#<id> is ADO's own work-item link syntax, so on ADO it outranks a bare
# `#N` — which is not a work-item reference in an ADO description at all.
out=$(STUB_PR_BODY="Linked to AB#9912 for tracking" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_KIND=workitem" "$out" "pr-body: AB#<id> is an ADO work item"
assert_line "WORKITEM_ID=9912" "$out" "pr-body: AB#<id> id is extracted"

out=$(STUB_PR_BODY="Fixes #5 -- tracked as AB#9912" run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_ID=9912" "$out" "pr-body: on ADO, AB#<id> outranks a bare #N"

out=$(STUB_PR_BODY="Fixes #5, also AB#9912" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=5" "$out" "pr-body: on GitHub the precedence is reversed"

# CRLF must not ride along into the id, exactly as for the branch lookup.
out=$(STUB_PR_BODY="Linked to AB#9912" run_in_stdout "$ADO_REPO" --args "pr 4506")
assert_not_contains "$(printf '\r')" "$out" "pr-body: no carriage return survives the ADO body"

# A body that cannot be READ is not a body with no link. Reporting them the
# same way lets a weaker fallback masquerade as a checked-and-empty route.
out=$(STUB_BODY_FAIL=1 run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_LOOKUP=pr-body-unreadable" "$out" "body-fetch failure is reported, not swallowed"
out=$(STUB_BODY_FAIL=1 run_in "$GH_REPO" --args "pr 170"); rc=$?
assert_exit 0 "$rc" "body-fetch failure is non-fatal"

out=$(STUB_PR_BODY="Fixes #318" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_LOOKUP=ok" "$out" "a successful body fetch reports ok"

# Route 1 outranks route 3: an explicit argument is never overridden by a link
# the author happened to write in the description.
out=$(STUB_PR_BODY="Fixes #318" run_in "$GH_REPO" --args "pr 170 https://github.com/TimZander/claude/issues/42")
assert_line "WORKITEM_ID=42" "$out" "precedence: an explicit argument outranks the PR body"

# --- Route 4: the branches/<id>-<slug> convention ---------------------
# The gh stub's PR resolves to branches/142-..., and the default body carries no
# link, so the fall-through to the branch name is what supplies the id.

out=$(run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=142" "$out" "branch-prefix: id read from the PR's source branch"
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "branch-prefix: route reported as branch-prefix"

# Route 3 outranks route 4: the author's assertion beats a naming convention.
out=$(STUB_PR_BODY="Fixes #318" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=318" "$out" "precedence: the PR body outranks the branch name"

WI_REPO="$TEST_TMPDIR/wi-repo"
setup_repo "$WI_REPO" "https://github.com/TimZander/claude.git" || exit 1
git -C "$WI_REPO" checkout -q -b "branches/220-deep-review-read-the-story" || exit 1
out=$(run_in "$WI_REPO" --args "focus on tests")
assert_line "KIND=none" "$out" "branch-prefix: no PR reference is still no PR"
assert_line "WORKITEM_ID=220" "$out" "branch-prefix: id read from the current branch"

# Anchored on the literal `branches/` segment. A looser numeric-prefix match
# read `release/2024-01-hotfix` as story 2024 — a real, unrelated issue in any
# repo with a few thousand of them.
for bad_branch in "release/2024-01-hotfix" "20250101-my-branch" "12-factor-cleanup" "branches/fix-220-thing"; do
    git -C "$WI_REPO" checkout -q -B "$bad_branch" || exit 1
    out=$(run_in "$WI_REPO" --args "focus on tests")
    assert_line "WORKITEM_KIND=none" "$out" "branch-prefix: '$bad_branch' resolves no story"
done

# Detached HEAD leaves CURRENT_BRANCH empty; the route must not match on it.
git -C "$WI_REPO" checkout -q --detach || exit 1
out=$(run_in "$WI_REPO" --args "focus on tests")
assert_line "WORKITEM_KIND=none" "$out" "branch-prefix: detached HEAD resolves no story"

# --- No story, and the shape of that answer ---------------------------
# "No story found" must be explicit and must stay distinguishable from a story
# that was found — a review that skipped fitness-checking should not look
# identical to one that passed it.

out=$(run_in "$GH_REPO" --args "focus on error handling")
assert_line "WORKITEM_KIND=none" "$out" "no reference and no numbered branch reports none"
assert_not_contains "WORKITEM_ID=" "$out" "no work item omits WORKITEM_ID entirely"
assert_not_contains "WORKITEM_SOURCE=" "$out" "no work item omits WORKITEM_SOURCE too"

out=$(run_in "$ODD_REPO" --args "#143")
assert_line "WORKITEM_KIND=none" "$out" "unknown host does not classify a bare #<N>"

# WORKITEM_KIND is documented as ALWAYS present — it is what lets a caller tell
# "no story" apart from "an older script that cannot resolve one at all".
out=$(run_in "$NO_REMOTE_REPO" --args "focus on tests")
assert_line "WORKITEM_KIND=none" "$out" "WORKITEM_KIND is present even with no remote"
out=$(run_in "$ODD_REPO" --args "focus on tests")
assert_line "WORKITEM_KIND=none" "$out" "WORKITEM_KIND is present on an unknown host"

# --- ORG: a work item cannot be fetched without it --------------------

out=$(run_in "$ADO_REPO" --args "#7775")
assert_line "ORG=https://dev.azure.com/bgvone" "$out" "ADO emits the org needed to fetch the work item"
out=$(run_in "$GH_REPO" --args "focus on tests")
assert_not_contains "ORG=" "$out" "GitHub emits no ORG"

# Every work-item key belongs on stdout, in the KEY=value stream.
out=$(run_in_stdout "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "work-item keys land on stdout, not stderr"

out=$(run_in "$GH_REPO" --args "pr 170"); rc=$?
assert_exit 0 "$rc" "work-item resolution never changes the exit code"


# --- Reference locality across dialects ------------------------------
# A mutation study proved these paths were entirely unexercised: every URL the
# suite fed the helpers was https, so the scp normalization, the cross-host
# check and the ADO dialect reconciliation could all be broken at once with the
# suite still green.
#
# Do NOT read this block as covering every helper branch. An earlier version of
# this comment claimed it killed a "short-path guard" mutant; it did not, and a
# coverage claim a test does not back is worse than no claim at all. What is
# covered is asserted below and nothing more.

SCP_REPO="$TEST_TMPDIR/scp-repo"
setup_repo "$SCP_REPO" "git@github.com:TimZander/claude.git" || exit 1
out=$(run_in "$SCP_REPO" --args "https://github.com/TimZander/claude/issues/42")
assert_line "WORKITEM_ID=42" "$out" "scp-style origin accepts its own https issue URL"
assert_line "WORKITEM_SOURCE=argument" "$out" "scp-style origin: reported as an explicit argument"

# Same owner/repo, different host — the only shape that isolates the cross-host
# check. The pre-existing cross-host test used a different owner too, so the
# owner/repo comparison caught it and the host check was never exercised.
out=$(run_in "$GH_REPO" --args "https://gitlab.com/TimZander/claude/issues/99")
assert_no_line "WORKITEM_ID=99" "$out" "same owner/repo on another host is refused"
assert_line "REFERENCE_REFUSED=true" "$out" "cross-host refusal is reported"

ADO_SSH_REPO="$TEST_TMPDIR/ado-ssh-repo"
setup_repo "$ADO_SSH_REPO" "git@ssh.dev.azure.com:v3/bgvone/BGV Development/BgvCore" || exit 1
out=$(run_in "$ADO_SSH_REPO" --args "https://dev.azure.com/bgvone/Proj/_workitems/edit/7775")
assert_line "WORKITEM_ID=7775" "$out" "ADO ssh origin accepts a same-org work-item URL"
assert_line "ORG=https://dev.azure.com/bgvone" "$out" "ADO ssh origin still derives the org"

# An ssh:// clone URL may carry an explicit port. The org sits one path segment
# further along than in the scp-style form, so a port-blind pattern reads the
# port as the org and refuses the repo's own work items.
ADO_PORT_REPO="$TEST_TMPDIR/ado-port-repo"
setup_repo "$ADO_PORT_REPO" "ssh://git@ssh.dev.azure.com:22/v3/bgvone/BGV Development/BgvCore" || exit 1
out=$(run_in "$ADO_PORT_REPO" --args "https://dev.azure.com/bgvone/Proj/_workitems/edit/7775")
assert_line "WORKITEM_ID=7775" "$out" "ADO ssh origin with an explicit port accepts its own work item"
assert_line "REFERENCE_REFUSED=false" "$out" "an explicit port is not mistaken for a different org"
assert_line "ORG=https://dev.azure.com/bgvone" "$out" "ADO ssh with a port still derives the org"

# ADO orgs are case-insensitive too, and the ADO comparison runs through a
# different helper than the owner/repo one above.
out=$(run_in "$ADO_PORT_REPO" --args "https://dev.azure.com/BGVONE/Proj/_workitems/edit/7775")
assert_line "WORKITEM_ID=7775" "$out" "ADO org comparison is case-insensitive"

# The legacy and modern ADO hosts are the same organization spelled two ways.
ADO_VS_REPO="$TEST_TMPDIR/ado-vs-repo"
setup_repo "$ADO_VS_REPO" "https://bgvone.visualstudio.com/BGV/_git/BgvCore" || exit 1
out=$(run_in "$ADO_VS_REPO" --args "https://dev.azure.com/bgvone/Proj/_workitems/edit/7775")
assert_line "WORKITEM_ID=7775" "$out" "visualstudio.com origin accepts a dev.azure.com URL for the same org"

out=$(run_in "$ADO_VS_REPO" --args "https://dev.azure.com/OTHERORG/P/_workitems/edit/555")
assert_no_line "WORKITEM_ID=555" "$out" "a genuinely different ADO org is still refused"

# Owners, repos and orgs are case-insensitive on both platforms; a clone URL
# carries whatever casing was typed, and users paste the browser's canonical form.
out=$(run_in "$GH_REPO" --args "https://github.com/TIMZANDER/Claude/issues/42")
assert_line "WORKITEM_ID=42" "$out" "owner/repo comparison is case-insensitive"

# Host detection accepts *.github.com, so the locality guard must too.
out=$(run_in "$GH_REPO" --args "https://www.github.com/TimZander/claude/issues/42")
assert_line "WORKITEM_ID=42" "$out" "www.github.com matches a github.com origin"

# --- A refusal must never look like an absence ------------------------
# The whole point of the guard is that a wrong story is worse than none. A
# silent refusal that falls through to the branch name produces exactly the
# wrong story, with no signal that the user named a different one.

out=$(run_in "$GH_REPO" --args "https://github.com/SOMEONE-ELSE/other/issues/42")
assert_no_line "WORKITEM_ID=42" "$out" "foreign issue URL: the id is refused"
assert_line "REFERENCE_REFUSED=true" "$out" "foreign issue URL: refusal is reported"
assert_no_line "KIND=issue" "$out" "foreign issue URL: KIND is refused too, not just WORKITEM_*"
assert_no_line "REF_ID=42" "$out" "foreign issue URL: the id does not leak via REF_ID"

# A refused URL must not consume the route. An if/elif chain here discarded a
# perfectly local #<N> sitting beside the foreign one.
#
# `pr 170` pins the review target so the trailing #<N> lands in the STORY slot.
# Without it, GitHub's shared numbering makes #143 the PR itself (see the KIND
# chain test below), and this would be asserting selection rather than routing.
out=$(run_in "$GH_REPO" --args "pr 170 https://github.com/SOMEONE-ELSE/other/issues/42 see also #143")
assert_line "WORKITEM_ID=143" "$out" "a refused URL does not blind the route to a local #<N>"
assert_line "WORKITEM_SOURCE=argument" "$out" "the surviving local reference is still an argument"

# --- Host gating is consistent across every route ---------------------

out=$(run_in "$ODD_REPO" --args "https://gitlab.com/someone/thing/issues/99")
assert_line "WORKITEM_KIND=none" "$out" "unknown host resolves no story even from its own issue URL"

UNKNOWN_BRANCH_REPO="$TEST_TMPDIR/unknown-branch-repo"
setup_repo "$UNKNOWN_BRANCH_REPO" "https://gitlab.com/someone/thing.git" || exit 1
git -C "$UNKNOWN_BRANCH_REPO" checkout -q -b "branches/220-on-an-unknown-host" || exit 1
out=$(run_in "$UNKNOWN_BRANCH_REPO" --args "focus on tests")
assert_line "WORKITEM_KIND=none" "$out" "unknown host resolves no story from a branches/<id>- name"

# --- AB#<id> and host classification ----------------------------------

# On ADO a bare closing keyword is NOT a work-item link; only AB#<id> is. An
# earlier version returned work item 5, a number every ADO project has.
out=$(STUB_PR_BODY="Fixes #5, nothing else here" run_in "$ADO_REPO" --args "pr 4506")
assert_no_line "WORKITEM_ID=5" "$out" "ADO: a bare closing keyword is not a work-item link"
assert_line "WORKITEM_ID=7493" "$out" "ADO: falls through to the branch name instead"

# AB#<id> on a GitHub repo names a work item nobody here can fetch — there is
# no org. Taking it set an unfetchable kind AND suppressed the usable
# branch-name story below it.
out=$(STUB_PR_BODY="Tracked as AB#9912 upstream" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=142" "$out" "GitHub: an unfetchable AB#<id> does not displace the branch story"
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "GitHub: route 4 still runs after an AB#-only body"

# --- The unreadable-body path, on both hosts --------------------------
# Previously only the gh arm was exercised, though az auth failures are the
# more common real-world case.

out=$(STUB_BODY_FAIL=1 run_in "$ADO_REPO" --args "pr 4506")
assert_line "WORKITEM_LOOKUP=pr-body-unreadable" "$out" "ADO body-fetch failure is reported"
assert_line "WORKITEM_ID=7493" "$out" "ADO body-fetch failure still falls back to the branch"

# The combination the caller actually keys on: a fallback result PLUS the
# signal that the stronger route was skipped rather than checked.
out=$(STUB_BODY_FAIL=1 run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "unreadable body: a fallback route supplies the id"
assert_line "WORKITEM_LOOKUP=pr-body-unreadable" "$out" "unreadable body: the caveat travels with it"

# --- The newly-mandated entry point -----------------------------------
# deep-review.md now requires this step to run on EVERY invocation, including
# with no arguments. Nothing exercised that before.

out=$(run_in "$WI_REPO" --args "")
assert_line "WORKITEM_KIND=none" "$out" "empty --args still reports the always-present keys"
assert_line "KIND=none" "$out" "empty --args resolves no PR"
out=$(run_in "$WI_REPO" --args ""); rc=$?
assert_exit 0 "$rc" "empty --args exits 0"


# --- Refusal is orthogonal, and never consumes a slot -----------------
# WORKITEM_LOOKUP used to carry the refusal too, so a refused URL clobbered
# `pr-body-unreadable` and contradicted a perfectly good `argument` result.

out=$(run_in "$GH_REPO" --args "https://github.com/SOMEONE-ELSE/other/issues/42 see also #143")
assert_line "REFERENCE_REFUSED=true" "$out" "a refused URL sets its own key"
assert_line "WORKITEM_LOOKUP=ok" "$out" "a refusal does not masquerade as a lookup failure"

# The KIND chain had the same elif bug one level up: a refused URL swallowed
# the slot, so a following local #<N> never selected anything and the review
# target silently fell back to HEAD. Nothing pins the target here, so GitHub's
# shared numbering resolves #143 as the PR — which is the assertion: the local
# reference was reached and selected something, rather than being discarded.
assert_line "KIND=pr" "$out" "KIND chain: a refused URL does not consume the slot"
assert_no_line "KIND=unknown" "$out" "KIND chain: the refusal does not leave the slot empty"
assert_line "REF_ID=143" "$out" "KIND chain: the local reference is selected"

out=$(run_in "$GH_REPO" --args "focus on tests")
assert_line "REFERENCE_REFUSED=false" "$out" "no reference means no refusal"
assert_line "WORKITEM_LOOKUP=ok" "$out" "and a clean lookup"

# Both conditions at once must both be reported — one key cannot carry two facts.
out=$(STUB_BODY_FAIL=1 run_in "$GH_REPO" --args "pr 170 https://github.com/SOMEONE-ELSE/other/issues/42")
assert_line "REFERENCE_REFUSED=true" "$out" "refusal survives alongside an unreadable body"
assert_line "WORKITEM_LOOKUP=pr-body-unreadable" "$out" "unreadable body survives alongside a refusal"

# --- The PR URL selects a branch, so its guard is the strictest -------
# A same-host, cross-REPOSITORY PR URL used to pass a host-only check and the
# number was then looked up against origin, selecting the wrong branch.

out=$(run_in "$GH_REPO" --args "https://github.com/SOMEONE-ELSE/other/pull/99"); rc=$?
assert_exit 1 "$rc" "cross-repo PR URL exits 1 rather than reviewing the wrong branch"
assert_contains "different repository" "$out" "cross-repo PR URL explains itself"
assert_not_contains "KIND=pr" "$out" "cross-repo PR URL selects nothing"

out=$(run_in "$ADO_REPO" --args "https://dev.azure.com/OTHERORG/P/_git/R/pullrequest/4506"); rc=$?
assert_exit 1 "$rc" "cross-org ADO PR URL exits 1"

# `--repo` is what pins the lookup to origin rather than gh's default remote.
ARGS_LOG="$TEST_TMPDIR/gh-args.txt"
: > "$ARGS_LOG"
STUB_ARGS_FILE="$ARGS_LOG" run_in "$GH_REPO" --args "pr 170" >/dev/null 2>&1
assert_contains "--repo TimZander/claude" "$(cat "$ARGS_LOG")" "gh pr view is scoped with --repo"

# --- ORG is derived, never inherited ---------------------------------

out=$(ORG="https://dev.azure.com/ATTACKER" run_in "$ADO_REPO" --args "focus on tests")
assert_line "ORG=https://dev.azure.com/bgvone" "$out" "ORG is derived, not inherited from the environment"
assert_no_line "ORG=https://dev.azure.com/ATTACKER" "$out" "an exported ORG cannot be published"

# --- AB#<id> on a non-ADO host resolves nothing ----------------------
# The old arm set WORKITEM_KIND=workitem with no ORG to fetch it, and in doing
# so suppressed the usable branch-name story below.

out=$(STUB_PR_BODY="Tracked upstream as AB#9912" run_in "$GH_REPO" --args "pr 170")
assert_line "WORKITEM_ID=142" "$out" "GitHub: AB#<id> does not displace the branch story"
assert_line "WORKITEM_SOURCE=branch-prefix" "$out" "GitHub: route 4 still runs"
assert_no_line "WORKITEM_KIND=workitem" "$out" "GitHub: no unfetchable workitem kind is published"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
