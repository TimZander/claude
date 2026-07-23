#!/usr/bin/env bash
# Smoke test for validate-settings.py: the real settings must pass, and a
# crafted mutating entry must fail. Run: bash standards/test-validate-settings.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python}"
VALIDATOR="$HERE/validate-settings.py"
pass=0
fail=0

check() {  # check <description> <expected-exit> <actual-exit>
  if [ "$2" -eq "$3" ]; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 (expected exit $2, got $3)"
    fail=$((fail + 1))
  fi
}

# 1. Happy path: the real committed settings.json passes.
"$PY" "$VALIDATOR" "$HERE/settings.json" >/dev/null 2>&1
check "real settings.json passes validation" 0 $?

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 2. Mutating Bash util (the sort -o footgun) fails.
cat > "$tmp/bad-sort.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git log:*)", "Bash(sort:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-sort.json" >/dev/null 2>&1
check "sort:* is rejected" 1 $?

# 3. git worktree add (the -B branch-reset vector) fails.
cat > "$tmp/bad-wt.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git worktree add:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-wt.json" >/dev/null 2>&1
check "git worktree add:* is rejected" 1 $?

# 4. Mutating MCP tool fails.
cat > "$tmp/bad-mcp.json" <<'JSON'
{ "permissions": { "allow": ["mcp__azure-devops__wit_update_work_item"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-mcp.json" >/dev/null 2>&1
check "mutating MCP tool is rejected" 1 $?

# 5. git config read form is allowed through the exception.
cat > "$tmp/good-config.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git config --get:*)", "Bash(git config --list:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/good-config.json" >/dev/null 2>&1
check "git config --get/--list pass" 0 $?

echo "---"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
