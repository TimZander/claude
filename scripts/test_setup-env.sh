#!/usr/bin/env bash
# Smoke test for setup-env.sh's BSD/macOS diff-preview fallback.
#
# What's covered: the extracted awk program at scripts/diff-preview.awk,
# which is the logic that can diverge between GNU and BSD diff output.
# Fixtures include the regression case (a deleted content line beginning
# with `-- ` that would false-match the unified-diff header regex before
# the NR-based fix).
#
# What's NOT covered: the GNU-vs-BSD detection probe at setup-env.sh:141
# (requires a mock `diff` that rejects --*-line-format flags). Test that
# manually by running the script on each platform.
#
# Invoke: bash scripts/test_setup-env.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_ENV="$REPO_ROOT/setup-env.sh"
AWK_SCRIPT="$SCRIPT_DIR/diff-preview.awk"

fail=0
pass=0

# All fixtures write into a temp dir; clean it up regardless of exit path.
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

assert_equal() {
    local want="$1" got="$2" label="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
        echo "  PASS $label"
    else
        fail=$((fail + 1))
        echo "  FAIL $label"
        printf '    want: %q\n' "$want"
        printf '    got:  %q\n' "$got"
    fi
}

# Run `diff -u OLD NEW` and pipe through the extracted awk preview script.
run_preview() {
    local old="$1" new="$2"
    { diff -u "$old" "$new" || true; } | awk -f "$AWK_SCRIPT"
}

echo "1) setup-env.sh parses as valid bash"
if bash -n "$SETUP_ENV"; then
    pass=$((pass + 1)); echo "  PASS bash -n parses setup-env.sh"
else
    fail=$((fail + 1)); echo "  FAIL bash -n reported a syntax error"
fi

echo "2) happy path: one addition and one deletion"
printf 'alpha\nbeta\ngamma\n' > "$TEST_TMPDIR/old.txt"
printf 'alpha\ndelta\ngamma\n' > "$TEST_TMPDIR/new.txt"
got="$(run_preview "$TEST_TMPDIR/old.txt" "$TEST_TMPDIR/new.txt")"
want="  - beta
  + delta"
assert_equal "$want" "$got" "addition + deletion formatted with   -  /   +  prefixes"

echo "3) regression: deletion of a line starting with '-- ' is not swallowed"
# Before the fix the awk regex /^--- / matched the diff's rendering of this
# deletion (the `-` prefix plus the content `-- comment` yields `--- comment`)
# and silently dropped it — the preview would show nothing for this change.
printf 'keep\n-- comment\ntail\n' > "$TEST_TMPDIR/old.txt"
printf 'keep\ntail\n' > "$TEST_TMPDIR/new.txt"
got="$(run_preview "$TEST_TMPDIR/old.txt" "$TEST_TMPDIR/new.txt")"
want="  - -- comment"
assert_equal "$want" "$got" "deletion of '-- comment' surfaces in preview"

echo "4) regression: addition of a line starting with '++ ' is not swallowed"
# Symmetric case — `/^\+\+\+ /` would false-match a new line whose content
# began with `++ ` (rendered as `+++ ` in the diff).
printf 'keep\ntail\n' > "$TEST_TMPDIR/old.txt"
printf 'keep\n++ addition\ntail\n' > "$TEST_TMPDIR/new.txt"
got="$(run_preview "$TEST_TMPDIR/old.txt" "$TEST_TMPDIR/new.txt")"
want="  + ++ addition"
assert_equal "$want" "$got" "addition of '++ addition' surfaces in preview"

echo "5) context lines are dropped (only +/- lines are emitted)"
# diff -u emits 3 lines of context around each hunk by default. The preview
# must not include those unchanged lines.
printf 'one\ntwo\nthree\nfour\nfive\n' > "$TEST_TMPDIR/old.txt"
printf 'one\ntwo\nTHREE\nfour\nfive\n' > "$TEST_TMPDIR/new.txt"
got="$(run_preview "$TEST_TMPDIR/old.txt" "$TEST_TMPDIR/new.txt")"
want="  - three
  + THREE"
assert_equal "$want" "$got" "unchanged context lines are suppressed"

echo "6) identical files produce empty preview"
printf 'same\ncontent\n' > "$TEST_TMPDIR/old.txt"
printf 'same\ncontent\n' > "$TEST_TMPDIR/new.txt"
got="$(run_preview "$TEST_TMPDIR/old.txt" "$TEST_TMPDIR/new.txt")"
assert_equal "" "$got" "no output when files match"

echo "7) hunk markers (@@) are not emitted"
# Trigger a multi-hunk diff so at least one @@ line is present, then check
# that the preview contains no '@@' substrings.
printf 'a1\na2\na3\na4\na5\na6\na7\na8\na9\nb1\nb2\nb3\nb4\nb5\nb6\nb7\nb8\nb9\n' > "$TEST_TMPDIR/old.txt"
printf 'A1\na2\na3\na4\na5\na6\na7\na8\na9\nb1\nb2\nb3\nb4\nb5\nb6\nb7\nb8\nB9\n' > "$TEST_TMPDIR/new.txt"
got="$(run_preview "$TEST_TMPDIR/old.txt" "$TEST_TMPDIR/new.txt")"
case "$got" in
    *"@@"*) fail=$((fail + 1)); echo "  FAIL preview leaked an @@ hunk marker"; echo "    got: $got" ;;
    *) pass=$((pass + 1)); echo "  PASS no @@ markers in preview" ;;
esac

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
