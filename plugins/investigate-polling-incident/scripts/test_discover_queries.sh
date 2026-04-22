#!/usr/bin/env bash
# Smoke test for discover_queries.py — verifies usage error + happy path.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/discover_queries.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# 1. --cwd pointing at a non-directory exits non-zero.
TMP_FILE="$(mktemp)"
trap 'rm -rf "$TMP_FILE" "${TMP_DIR:-}"' EXIT
if python3 "$SUT" --cwd "$TMP_FILE" >/dev/null 2>&1; then
    fail "expected non-zero exit when --cwd is a file"
fi
pass "usage error on non-directory --cwd"

# 2. Empty directory emits '[]'.
TMP_DIR="$(mktemp -d)"
out="$(python3 "$SUT" --cwd "$TMP_DIR")"
[ "$(printf '%s' "$out" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')" = "0" ] \
    || fail "expected empty array for empty dir, got: $out"
pass "empty dir yields empty array"

# 3. .kql file is discovered, title extracted from leading '// ...' comment.
cat > "$TMP_DIR/polling.kql" <<'KQL'
// Polling cadence check
traces
| where timestamp > ago(6h)
| where message has "Poll"
KQL
out="$(python3 "$SUT" --cwd "$TMP_DIR")"
python3 - "$out" <<'PY' || fail ".kql discovery failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {len(data)}: {data}"
e = data[0]
assert e["source"] == "polling.kql", e
assert e["title"] == "Polling cadence check", e
assert "traces" in e["content"]
PY
pass ".kql file discovered with title from leading comment"

# 4. Markdown fenced ```kql block is discovered under its preceding heading.
cat > "$TMP_DIR/ops.md" <<'MD'
# Operations

## Exceptions audit

```kql
exceptions
| where timestamp > ago(6h)
```

Some other text.

```kql
traces | take 10
```
MD
out="$(python3 "$SUT" --cwd "$TMP_DIR")"
python3 - "$out" <<'PY' || fail "markdown discovery failed: $out"
import sys, json
data = json.loads(sys.argv[1])
titles = sorted(e["title"] for e in data)
assert "Exceptions audit" in titles, f"titles={titles}"
# Two entries from ops.md (2 blocks) + 1 from polling.kql = 3
assert len(data) == 3, f"expected 3 entries, got {len(data)}"
# Second block has no immediate preceding heading — uses the nearest ancestor heading.
# We only assert it exists, title can be either "Exceptions audit" (sticky) or fallback.
PY
pass 'markdown fenced kql blocks discovered'

# 5. --include restricts discovery to matching paths.
# With polling.kql and ops.md from earlier steps, --include '*.kql' should return only the .kql entry.
out="$(python3 "$SUT" --cwd "$TMP_DIR" --include '*.kql')"
python3 - "$out" <<'PY' || fail "--include filter failed: $out"
import sys, json
data = json.loads(sys.argv[1])
sources = sorted(e["source"] for e in data)
assert sources == ["polling.kql"], f"expected only polling.kql, got {sources}"
PY
pass '--include glob restricts discovery'

# 6. Multiple --include globs union.
out="$(python3 "$SUT" --cwd "$TMP_DIR" --include 'nonexistent/*.kql' --include 'ops.md')"
python3 - "$out" <<'PY' || fail "--include union failed: $out"
import sys, json
data = json.loads(sys.argv[1])
sources = sorted(e["source"] for e in data)
# Only ops.md matched (2 blocks).
assert all(s.startswith("ops.md#") for s in sources), f"expected only ops.md entries, got {sources}"
PY
pass '--include globs are unioned'

echo "all smoke tests passed"
