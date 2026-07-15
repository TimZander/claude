#!/usr/bin/env bash
# Smoke test for resolve-pr.sh.
# Runs a small set of scenarios and asserts exit code + output pattern.
# Invoke: bash scripts/test_resolve-pr.sh
#
# Coverage: syntax, usage errors, host detection, token parsing and
# precedence, ADO work-item carve-out, ref normalization, PR-state mapping,
# and the PR-vs-issue fallback for an ambiguous #<N>.
#
# `gh` and `az` are STUBBED on PATH so the lookup paths run offline and
# deterministically. NOT covered: real gh/az authentication, network
# failures, and ADO org derivation against every remote-URL dialect — those
# need live tooling; re-verify manually when touching the lookup sections
# (`bash resolve-pr.sh --args "pr <N>"` inside a real GitHub and ADO repo).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/resolve-pr.sh"

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

assert_not_contains() {
    local needle="$1" out="$2" label="$3"
    case "$out" in
        *"$needle"*) fail=$((fail + 1)); echo "  FAIL $label: output unexpectedly contains '$needle'"; echo "    got: $out" ;;
        *) pass=$((pass + 1)); echo "  PASS $label" ;;
    esac
}

TEST_TMPDIR=$(mktemp -d)

# ── Stubs ────────────────────────────────────────────────────────────
# Fake `gh` / `az` on PATH. Each mimics the real tool's OUTPUT SHAPE, which
# is the thing resolve-pr.sh actually depends on:
#   - gh --jq '... | @tsv'  -> one TAB-separated line, bare branch names
#   - az --query "[a,b,c]" -o tsv -> one element per LINE, fully-qualified refs
# Set STUB_FAIL=1 to make the PR lookup fail (issue / missing PR cases).

STUB_DIR="$TEST_TMPDIR/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_FAIL:-0}" = "1" ]; then
    echo "GraphQL: Could not resolve to a PullRequest with the number of 143." >&2
    exit 1
fi
printf 'branches/142-anchor-pr-review-comments-on-changed-lines\tmain\tMERGED\n'
STUB

cat > "$STUB_DIR/az" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_FAIL:-0}" = "1" ]; then
    echo "ERROR: TF401180: The requested pull request was not found." >&2
    exit 1
fi
# Record args so the test can assert on derived --org.
echo "$@" > "${STUB_ARGS_FILE:-/dev/null}"
printf 'refs/heads/branches/7493-apm-errors-noticeerror-poc\nrefs/heads/main\ncompleted\n'
STUB

chmod +x "$STUB_DIR/gh" "$STUB_DIR/az"
export PATH="$STUB_DIR:$PATH"

# ── Fixture ──────────────────────────────────────────────────────────
# A git repo whose origin remote decides the host. No network: the script
# only ever calls `git remote get-url`.

setup_repo() {
    local dir="$1" remote="${2:-}"
    if ! git init -q --initial-branch=main "$dir" >/dev/null 2>&1; then
        echo "setup_repo: git init failed for $dir" >&2
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
BARE_REPO="$TEST_TMPDIR/no-remote-repo"
ODD_REPO="$TEST_TMPDIR/odd-repo"

setup_repo "$GH_REPO"   "https://github.com/TimZander/claude.git"   || exit 1
setup_repo "$ADO_REPO"  "https://dev.azure.com/bgvone/BGV%20Development/_git/BgvCore" || exit 1
setup_repo "$BARE_REPO" ""                                          || exit 1
setup_repo "$ODD_REPO"  "https://gitlab.com/someone/thing.git"       || exit 1

run_in() {
    local dir="$1"; shift
    ( cd "$dir" && bash "$SCRIPT" "$@" 2>&1 )
}

echo "test_resolve-pr.sh"

# ── Syntax ───────────────────────────────────────────────────────────
bash -n "$SCRIPT" 2>/dev/null
assert_exit 0 $? "script parses"

# ── Usage / pre-flight errors ────────────────────────────────────────
out=$(run_in "$GH_REPO" --bogus 2>&1); rc=$?
assert_exit 1 "$rc" "unknown argument exits 1"
assert_contains "Unknown argument" "$out" "unknown argument names the flag"

out=$(run_in "$BARE_REPO" --args "pr 1" 2>&1); rc=$?
assert_exit 1 "$rc" "missing origin remote exits 1"
assert_contains "No 'origin' remote" "$out" "missing origin explains itself"

out=$(run_in "$ODD_REPO" --args "pr 1" 2>&1); rc=$?
assert_exit 1 "$rc" "unsupported host exits 1"
assert_contains "Could not determine hosting platform" "$out" "unsupported host explains itself"

# ── Host detection ───────────────────────────────────────────────────
out=$(run_in "$GH_REPO" --args "focus on error handling")
assert_contains "HOST=github" "$out" "github remote detected"
assert_contains "KIND=none" "$out" "free-form text resolves to no reference"
assert_exit 0 $? "no reference still exits 0"

out=$(run_in "$ADO_REPO" --args "focus on error handling")
assert_contains "HOST=azdo" "$out" "azdo remote detected"

# ── ADO work-item carve-out ──────────────────────────────────────────
# #<N> on ADO must never select a branch: ADO numbers work items and PRs
# separately, so the number alone cannot disambiguate.
out=$(run_in "$ADO_REPO" --args "#7775")
assert_contains "KIND=workitem" "$out" "ADO #<N> is a work item"
assert_not_contains "SOURCE_BRANCH=" "$out" "ADO #<N> selects no branch"

# ── ADO PR resolution + normalization ────────────────────────────────
export STUB_ARGS_FILE="$TEST_TMPDIR/az-args"
out=$(run_in "$ADO_REPO" --args "pr 4506")
assert_contains "KIND=pr" "$out" "ADO pr <N> resolves to a PR"
# The trap: the branch legitimately contains a `branches/` segment, so only an
# anchored refs/heads/ strip is correct. A greedy strip yields a branch that
# does not exist.
assert_contains "SOURCE_BRANCH=branches/7493-apm-errors-noticeerror-poc" "$out" \
    "ADO ref strips only the anchored refs/heads/ prefix"
assert_contains "TARGET_BRANCH=main" "$out" "ADO target ref normalized"
assert_contains "STATE=merged" "$out" "ADO 'completed' maps to merged"
assert_contains "BRANCH_MATCH=false" "$out" "mismatch against current HEAD reported"
assert_contains "https://dev.azure.com/bgvone" "$(cat "$STUB_ARGS_FILE" 2>/dev/null)" \
    "ADO org URL derived from remote"
unset STUB_ARGS_FILE

out=$(STUB_FAIL=1 run_in "$ADO_REPO" --args "pr 999999"); rc=$?
assert_exit 1 "$rc" "unresolvable ADO PR exits 1"
assert_contains "Could not resolve Azure DevOps PR" "$out" "ADO lookup failure explains itself"

# ── GitHub PR resolution ─────────────────────────────────────────────
out=$(run_in "$GH_REPO" --args "pr 170")
assert_contains "KIND=pr" "$out" "GitHub pr <N> resolves to a PR"
assert_contains "SOURCE_BRANCH=branches/142-anchor-pr-review-comments-on-changed-lines" "$out" \
    "GitHub bare head ref passes through normalization unchanged"
assert_contains "STATE=merged" "$out" "GitHub MERGED maps to merged"

out=$(run_in "$GH_REPO" --args "https://github.com/TimZander/claude/pull/170")
assert_contains "KIND=pr" "$out" "GitHub PR URL resolves to a PR"
assert_contains "REF_ID=170" "$out" "PR URL yields the right number"

# ── GitHub #<N> ambiguity ────────────────────────────────────────────
# Shared issue/PR counter: the PR lookup IS the test. A failure means issue.
out=$(run_in "$GH_REPO" --args "#170")
assert_contains "KIND=pr" "$out" "GitHub #<N> naming a PR selects the branch"

out=$(STUB_FAIL=1 run_in "$GH_REPO" --args "#143"); rc=$?
assert_exit 0 "$rc" "GitHub #<N> naming an issue exits 0"
assert_contains "KIND=issue" "$out" "GitHub #<N> falls back to issue"
assert_not_contains "SOURCE_BRANCH=" "$out" "issue selects no branch"

# An EXPLICIT pr <N> that does not resolve is an error, not an issue fallback.
out=$(STUB_FAIL=1 run_in "$GH_REPO" --args "pr 999999"); rc=$?
assert_exit 1 "$rc" "unresolvable explicit GitHub PR exits 1"
assert_contains "Could not resolve GitHub PR" "$out" "GitHub lookup failure explains itself"

# ── Token precedence + boundaries ────────────────────────────────────
out=$(run_in "$GH_REPO" --args "compr 4 and other words")
assert_contains "KIND=none" "$out" "'compr 4' does not match the pr token"

out=$(run_in "$GH_REPO" --args "https://github.com/TimZander/claude/pull/170 #143")
assert_contains "REF_ID=170" "$out" "PR URL wins over a bare #<N>"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
