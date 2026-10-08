#!/usr/bin/env bash
# Smoke test for validate-settings.py: the real settings must pass, and a
# crafted mutating entry must fail. Run: bash standards/test-validate-settings.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"
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

# 2. Mutating Bash util (the sort -o pitfall) fails.
cat > "$tmp/bad-sort.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git log:*)", "Bash(sort:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-sort.json" >/dev/null 2>&1
check "sort:* is rejected" 1 $?

# 2b. Bare command-family root fails (git:* would allow git push).
cat > "$tmp/bad-root.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-root.json" >/dev/null 2>&1
check "bare git:* root is rejected" 1 $?

# 2c. Proper prefix of a write command fails (git worktree:* reaches add).
cat > "$tmp/bad-prefix.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git worktree:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-prefix.json" >/dev/null 2>&1
check "git worktree:* (prefix of add) is rejected" 1 $?

# 2d. MCP wildcard grant fails.
cat > "$tmp/bad-wild.json" <<'JSON'
{ "permissions": { "allow": ["mcp__azure-devops__*"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-wild.json" >/dev/null 2>&1
check "mcp wildcard is rejected" 1 $?

# 2e. Interpreter/arbitrary-exec fails.
cat > "$tmp/bad-py.json" <<'JSON'
{ "permissions": { "allow": ["Bash(python:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-py.json" >/dev/null 2>&1
check "python:* is rejected" 1 $?

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

# 4b. Fail-closed: a read-LOOKING MCP tool not on the vetted set is rejected.
cat > "$tmp/bad-unknown-mcp.json" <<'JSON'
{ "permissions": { "allow": ["mcp__azure-devops__wit_get_something_new"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/bad-unknown-mcp.json" >/dev/null 2>&1
check "unlisted read-looking MCP tool is rejected (fail-closed)" 1 $?

# 5. git config read form is allowed through the exception.
cat > "$tmp/good-config.json" <<'JSON'
{ "permissions": { "allow": ["Bash(git config --get:*)", "Bash(git config --list:*)"], "deny": [] } }
JSON
"$PY" "$VALIDATOR" "$tmp/good-config.json" >/dev/null 2>&1
check "git config --get/--list pass" 0 $?

echo "---"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
