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

# Create a working repo + bare "origin" pair. The bare path contains
# "github.com" so the script classifies PLATFORM=github; ls-remote works
# against the local bare repo, letting us exercise the base-exists check
# without network access.
setup_repo() {
    local base="$1"
    local bare="$base/test-github.com-fake.git"
    local work="$base/work"
    git init --bare --initial-branch=main "$bare" >/dev/null 2>&1
    git init --initial-branch=main "$work" >/dev/null 2>&1
    (
        cd "$work"
        git config user.email "test@example.com"
        git config user.name "Test"
        git config commit.gpgsign false
        git config core.autocrlf false
        echo hello > README
        git add README
        git commit -m "init" >/dev/null 2>&1
        git remote add origin "$bare"
        git push -u origin main >/dev/null 2>&1
    )
    echo "$work"
}

make_body() {
    local f
    f="$(mktemp)"
    echo "body" > "$f"
    echo "$f"
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
git init --initial-branch=main "$PLAIN_REPO" >/dev/null 2>&1
(cd "$PLAIN_REPO" && git remote add origin "$TEST_TMPDIR/not-a-real-host.git")
out=$(cd "$PLAIN_REPO" && bash "$SCRIPT" --title "t" --body-file "$B" 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 on unrecognized platform"
assert_contains "Could not determine hosting platform" "$out" "platform diagnostic surfaced"
rm -f "$B"

echo "8) refuses to push from main"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r8")
out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when on main"
assert_contains "Refusing to push to 'main'" "$out" "refuse-main diagnostic surfaced"
rm -f "$B"

echo "9) refuses when current branch equals base"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r9")
(cd "$REPO" && git checkout -b feat/x >/dev/null 2>&1)
out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" --base feat/x 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when branch equals base"
assert_contains "same as the base branch" "$out" "same-branch diagnostic surfaced"
rm -f "$B"

echo "10) base branch must exist on origin"
B=$(make_body)
REPO=$(setup_repo "$TEST_TMPDIR/r10")
(cd "$REPO" && git checkout -b feat/y >/dev/null 2>&1)
out=$(cd "$REPO" && bash "$SCRIPT" --title "t" --body-file "$B" --base nonexistent-xyz 2>&1); rc=$?
assert_exit 1 "$rc" "exit 1 when base missing on remote"
assert_contains "does not exist on 'origin'" "$out" "missing-base diagnostic surfaced"
rm -f "$B"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
