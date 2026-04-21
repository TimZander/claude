#!/usr/bin/env bash
# Smoke test for dependency-check.sh.
# Runs a small set of scenarios and asserts exit code + stdout pattern.
# Invoke: bash scripts/test_dependency-check.sh
#
# Coverage: usage errors, the system-interpreter happy path, the no-python
# error path, and the venv fallback branch. NOT covered: the uv install
# success path (requires uv installed and a reachable package index) — test
# that manually when editing the uv branch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/dependency-check.sh"

fail=0
pass=0

# The venv-fallback test allocates a temp dir; clean up on any exit.
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

assert_stdout_contains() {
    local needle="$1" out="$2" label="$3"
    case "$out" in
        *"$needle"*) pass=$((pass + 1)); echo "  PASS $label" ;;
        *) fail=$((fail + 1)); echo "  FAIL $label: stdout missing '$needle'"; echo "    got: $out" ;;
    esac
}

echo "1) script is syntactically valid bash"
if bash -n "$CHECK"; then
    pass=$((pass + 1)); echo "  PASS bash -n parses the script"
else
    fail=$((fail + 1)); echo "  FAIL bash -n reported a syntax error"
fi

echo "2) usage error when called with no args"
out="$(bash "$CHECK" 2>&1)"; rc=$?
assert_exit 2 "$rc" "exit 2 on missing args"
assert_stdout_contains "usage:" "$out" "usage message present"

echo "3) usage error with only plugin name"
out="$(bash "$CHECK" myplugin 2>&1)"; rc=$?
assert_exit 2 "$rc" "exit 2 when package list missing"

echo "4) happy path: stdlib module is always importable"
out="$(bash "$CHECK" test-plugin "sys" nonexistent-package-should-not-install 2>&1)"; rc=$?
assert_exit 0 "$rc" "exit 0 when system import satisfies deps"
assert_stdout_contains "PLUGIN_PY=" "$out" "PLUGIN_PY= emitted on success"

echo "5) happy-path PLUGIN_PY points to a usable interpreter"
plugin_py="$(printf '%s\n' "$out" | grep '^PLUGIN_PY=' | tail -1 | cut -d= -f2-)"
if [ -n "$plugin_py" ] && [ -x "$plugin_py" ] && "$plugin_py" -c "import sys" >/dev/null 2>&1; then
    pass=$((pass + 1)); echo "  PASS PLUGIN_PY is a working interpreter ($plugin_py)"
else
    fail=$((fail + 1)); echo "  FAIL PLUGIN_PY not usable: '$plugin_py'"
fi

echo "6) no python on PATH"
# Invoke bash by absolute path so the subprocess starts even when PATH is stripped;
# inside the child, command -v python3/python then has no PATH to search.
BASH_ABS="$(command -v bash)"
out="$(PATH=/nonexistent-$$ "$BASH_ABS" "$CHECK" test-plugin "sys" dummy 2>&1)"; rc=$?
assert_exit 1 "$rc" "exit 1 when no python3/python"
assert_stdout_contains "No python3/python on PATH" "$out" "diagnostic message surfaced"

echo "7) venv fallback branch: fake uv fails, pip install fails → venv dir exists"
TEST_TMPDIR="$(mktemp -d)"
FAKE_BIN="$TEST_TMPDIR/fake-bin"
mkdir "$FAKE_BIN"
# Fake uv that always exits non-zero — forces the elif group to fail for both
# the first attempt and the --break-system-packages retry, so the cascade
# falls through to branch 3 (venv).
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_BIN/uv"
chmod +x "$FAKE_BIN/uv"

plugin_name="test-venv-$$"
out="$(TMPDIR="$TEST_TMPDIR" PATH="$FAKE_BIN:$PATH" bash "$CHECK" \
    "$plugin_name" "xyz_nonexistent_module_abc123" "nonexistent-package-xyz987-$$" 2>&1)"; rc=$?

assert_exit 1 "$rc" "exit 1 when pip install fails"
assert_stdout_contains "pip install failed" "$out" "pip failure diagnostic"

# Evidence that branch 3 was reached: the venv dir exists at the expected path.
uid_suffix="$(id -u 2>/dev/null || echo default)"
expected_venv="$TEST_TMPDIR/${plugin_name}-venv-$uid_suffix"
if [ -d "$expected_venv" ]; then
    pass=$((pass + 1)); echo "  PASS venv created at $expected_venv"
else
    fail=$((fail + 1)); echo "  FAIL expected venv dir not found at $expected_venv"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
