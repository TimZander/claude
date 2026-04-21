#!/usr/bin/env bash
# Smoke test for create-pr.sh.
# Runs a small set of scenarios and asserts exit code + stderr pattern.
# Invoke: bash scripts/test_create-pr.sh
#
# Coverage: syntax, usage errors, platform detection, branch-safety
# guards, base-branch existence check. NOT covered: push, gh/az API
# calls, or the GitHub/ADO happy paths — those require authenticated
# tooling and network access; test them manually when touching the
# pre-flight or PR-create sections.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/create-pr.sh"

fail=0
pass=0

TEST_TMPDIR=""
trap 'if [ -n "$TEST_TMPDIR" ]; then rm -rf "$TEST_TMPDIR"; fi' EXIT

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

# Create a working repo + bare "origin" pair. The bare path contains a
# platform marker ("github.com" by default; pass "dev.azure.com" to
# exercise the ADO branch) so the script classifies PLATFORM correctly;
# ls-remote works against the local bare repo, letting us exercise the
# base-exists check without network access.
#
# Any git failure during setup is reported to stderr and returns non-zero
# so tests don't silently run against a half-built fixture.
setup_repo() {
    local base="$1"
    local marker="${2:-github.com}"
    local bare="$base/test-${marker}-fake.git"
    local work="$base/work"
    if ! git init --bare --initial-branch=main "$bare" >/dev/null 2>&1; then
        echo "setup_repo: git init --bare failed for $bare" >&2
        return 1
    fi
    if ! git init --initial-branch=main "$work" >/dev/null 2>&1; then
        echo "setup_repo: git init failed for $work" >&2
        return 1
    fi
    if ! (
        set -e
        cd "$work"
        git config user.email "test@example.com"
        git config user.name "Test"
        git config commit.gpgsign false
        git config core.autocrlf false
        # Opt out of the global pre-push hook that blocks pushes to main;
        # this test fixture legitimately pushes main to its own local bare
        # "origin". See ~/.git-hooks/pre-push for the opt-out mechanism.
        touch .allow-push-main
        echo hello > README
        git add README
        git commit -m "init" >/dev/null 2>&1
        git remote add origin "$bare"
        git push -u origin main >/dev/null 2>&1
    ); then
        echo "setup_repo: workdir setup failed for $work" >&2
        return 1
    fi
    echo "$work"
}

# Create a body tmp file inside TEST_TMPDIR so the EXIT trap cleans it
# up even if a test aborts. Using TMPDIR=... keeps the call portable
# across GNU and BSD mktemp (which disagree on the -p flag).
make_body() {
    local f
    f="$(TMPDIR="$TEST_TMPDIR" mktemp)"
    echo "body" > "$f"
    echo "$f"
}

# Guard against a footgun: on Git Bash, `cd ""` silently stays put
# rather than erroring. If setup_repo ever returns empty (e.g., a
# silent git failure), `(cd "$REPO" && git checkout ...)` would then
# run the checkout in the REAL repo containing this test, leaking
# branches into the developer's worktree. require_repo aborts the
# specific test cleanly instead.
require_repo() {
    local repo="$1" label="$2"
    if [ -z "$repo" ]; then
        fail=$((fail + 1))
        echo "  FAIL $label: setup_repo returned empty path (skipping test)"
        return 1
    fi
    return 0
}

TEST_TMPDIR="$(mktemp -d)"

echo "1) script is syntactically valid bash"
if bash -n "$SCRIPT"; then
    pass=$((pass + 1)); echo "  PASS bash -n parses the script"
else
    fail=$((fail + 1)); echo "  FAIL bash -n reported a syntax error"
fi

echo "2) --title is required"
out=$(bash "$SCRIPT" 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when --title missing"
assert_contains "--title is required" "$out" "usage message surfaced"

echo "3) --body-file is required"
out=$(bash "$SCRIPT" --title "t" 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when --body-file missing"
assert_contains "--body-file is required" "$out" "usage message surfaced"

echo "4) body file must exist"
out=$(bash "$SCRIPT" --title "t" --body-file "$TEST_TMPDIR/nonexistent" 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when body file missing"
assert_contains "Body file not found" "$out" "not-found message surfaced"

echo "5) unknown flag rejected"
B=$(make_body)
out=$(bash "$SCRIPT" --title "t" --body-file "$B" --bogus 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 on unknown arg"
assert_contains "Unknown argument" "$out" "unknown-arg message surfaced"
rm -f "$B"

echo "6) no origin remote"
B=$(make_body)
EMPTY_REPO="$TEST_TMPDIR/empty-repo"
git init --initial-branch=main "$EMPTY_REPO" >/dev/null 2>&1
out=$(cd "$EMPTY_REPO" && bash "$SCRIPT" --title "t" --body-file "$B" 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when origin missing"
assert_contains "No 'origin' remote" "$out" "missing-origin message surfaced"
rm -f "$B"

echo "7) unrecognized hosting platform"
B=$(make_body)
PLAIN_REPO="$TEST_TMPDIR/plain-repo"
if ! git init --initial-branch=main "$PLAIN_REPO" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "  FAIL test 7 setup: git init"
elif ! (cd "$PLAIN_REPO" && git remote add origin "$TEST_TMPDIR/not-a-real-host.git"); then
    fail=$((fail + 1)); echo "  FAIL test 7 setup: git remote add"
else
    out=$(cd "$PLAIN_REPO" && bash "$SCRIPT" --title "t" --body-file "$B" 2>&1); rc=$?
    assert_exit 1 "$rc" "exit 1 on unrecognized platform"
    assert_contains "Could not determine hosting platform" "$out" "platform diagnostic surfaced"
fi
rm -f "$B"

echo "8) refuses to push from main"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r8")
if require_repo "$REPO" "test 8"; then
    out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" 2>&1); rc=$?
    assert_exit 1 "$rc" "exit 1 when on main"
    assert_contains "Refusing to push to 'main'" "$out" "refuse-main diagnostic surfaced"
fi
rm -f "$B"

echo "9) refuses when current branch equals base"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r9")
if require_repo "$REPO" "test 9"; then
    (cd "$REPO" && git checkout -b feat/x >/dev/null 2>&1)
    out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" --base feat/x 2>&1); rc=$?
    assert_exit 1 "$rc" "exit 1 when branch equals base"
    assert_contains "same as the base branch" "$out" "same-branch diagnostic surfaced"
fi
rm -f "$B"

echo "10) base branch must exist on origin"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r10")
if require_repo "$REPO" "test 10"; then
    (cd "$REPO" && git checkout -b feat/y >/dev/null 2>&1)
    out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" --base nonexistent-xyz 2>&1); rc=$?
    assert_exit 1 "$rc" "exit 1 when base missing on remote"
    assert_contains "does not exist on 'origin'" "$out" "missing-base diagnostic surfaced"
fi
rm -f "$B"

echo "11) ls-remote network/auth failure distinguished from missing branch"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r11")
if require_repo "$REPO" "test 11"; then
    # Point origin at a nonexistent bare path (keeping "github.com" in the URL
    # so platform detection still classifies as GitHub). ls-remote will exit
    # with code 128 (fatal: not a git repository), exercising the *) branch.
    (cd "$REPO" && git checkout -b feat/z >/dev/null 2>&1 \
        && git remote set-url origin "$TEST_TMPDIR/bogus-github.com-nope.git")
    out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" --base main 2>&1); rc=$?
    assert_exit 1 "$rc" "exit 1 on ls-remote non-2 failure"
    assert_contains "Could not verify base branch" "$out" "network-failure diagnostic surfaced"
    # "fatal:" is how git prefixes its own error messages — presence proves
    # we relayed git's stderr rather than just printing our own wrapper.
    assert_contains "fatal:" "$out" "underlying git stderr surfaced"
fi
rm -f "$B"

echo "12) ADO platform classified from dev.azure.com URL"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r12" "dev.azure.com")
if require_repo "$REPO" "test 12"; then
    (cd "$REPO" && git checkout -b feat/ado >/dev/null 2>&1)
    # Current branch equals base, so we reach the branch-equals-base guard
    # (which fires AFTER platform detection). A success here proves the
    # dev.azure.com URL was recognized and the script didn't bail with
    # "Could not determine hosting platform."
    out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" --base feat/ado 2>&1); rc=$?
    assert_exit 1 "$rc" "exit 1 on ADO path"
    assert_contains "same as the base branch" "$out" "ADO path reaches branch-equals-base guard"
    case "$out" in
        *"Could not determine hosting platform"*)
            fail=$((fail + 1)); echo "  FAIL ADO URL misclassified as unknown platform" ;;
        *)
            pass=$((pass + 1)); echo "  PASS ADO URL classified correctly" ;;
    esac
fi
rm -f "$B"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
