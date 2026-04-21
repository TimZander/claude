#!/usr/bin/env bash
# Smoke test for dependency-check.sh.
# Runs a small set of scenarios and asserts exit code + stdout pattern.
# Invoke: bash scripts/test_dependency-check.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/dependency-check.sh"

fail=0
pass=0

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

echo "1) usage error when called with no args"
out="$(bash "$CHECK" 2>&1)"; rc=$?
assert_exit 2 "$rc" "exit 2 on missing args"
assert_stdout_contains "usage:" "$out" "usage message present"

echo "2) usage error with only plugin name"
out="$(bash "$CHECK" myplugin 2>&1)"; rc=$?
assert_exit 2 "$rc" "exit 2 when package list missing"

echo "3) happy path: stdlib module is always importable"
out="$(bash "$CHECK" test-plugin "sys" nonexistent-package-should-not-install 2>&1)"; rc=$?
assert_exit 0 "$rc" "exit 0 when system import satisfies deps"
assert_stdout_contains "PLUGIN_PY=" "$out" "PLUGIN_PY= emitted on success"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
