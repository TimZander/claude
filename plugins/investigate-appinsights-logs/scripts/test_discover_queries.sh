#!/usr/bin/env bash
# Smoke test for discover_queries.py — verifies usage error + happy path + edge cases.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/discover_queries.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# A single top-level TMP_ROOT contains one sub-directory per test so cases stay
# isolated — no leftover fixtures from prior tests silently satisfy later ones.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fresh_case_dir() {
    local d
    d="$(mktemp -d "$TMP_ROOT/case.XXXXXX")"
    printf '%s' "$d"
}

# 1. --cwd pointing at a non-directory exits non-zero.
TMP_FILE="$(mktemp "$TMP_ROOT/nondir.XXXXXX")"
if python3 "$SUT" --cwd "$TMP_FILE" >/dev/null 2>&1; then
    fail "expected non-zero exit when --cwd is a file"
fi
pass "usage error on non-directory --cwd"

# 2. Empty directory emits '[]'.
case_dir="$(fresh_case_dir)"
out="$(python3 "$SUT" --cwd "$case_dir")"
[ "$(printf '%s' "$out" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')" = "0" ] \
    || fail "expected empty array for empty dir, got: $out"
pass "empty dir yields empty array"

# 3. .kql file is discovered, title extracted from leading '// ...' comment.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/polling.kql" <<'KQL'
// Polling cadence check
traces
| where timestamp > ago(6h)
| where message has "Poll"
KQL
out="$(python3 "$SUT" --cwd "$case_dir")"
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
case_dir="$(fresh_case_dir)"
cat > "$case_dir/ops.md" <<'MD'
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
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "markdown discovery failed: $out"
import sys, json
data = json.loads(sys.argv[1])
titles = sorted(e["title"] for e in data)
assert "Exceptions audit" in titles, f"titles={titles}"
assert len(data) == 2, f"expected 2 entries, got {len(data)}"
PY
pass 'markdown fenced kql blocks discovered'

# 5. --include restricts discovery to matching paths.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/polling.kql" <<'KQL'
// P
traces
KQL
cat > "$case_dir/ops.md" <<'MD'
# X

```kql
traces
```
MD
out="$(python3 "$SUT" --cwd "$case_dir" --include '*.kql')"
python3 - "$out" <<'PY' || fail "--include filter failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {len(data)}: {data}"
assert data[0]["source"] == "polling.kql", data
PY
pass '--include glob restricts discovery'

# 6. Multiple --include globs union; empty-match guard (non-vacuous).
case_dir="$(fresh_case_dir)"
cat > "$case_dir/polling.kql" <<'KQL'
// P
traces
KQL
cat > "$case_dir/ops.md" <<'MD'
# X

```kql
traces
```
MD
out="$(python3 "$SUT" --cwd "$case_dir" --include 'nonexistent/*.kql' --include 'ops.md')"
python3 - "$out" <<'PY' || fail "--include union failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) >= 1, f"expected at least one match (vacuous-guard), got {data}"
sources = [e["source"] for e in data]
assert all(s.startswith("ops.md#") for s in sources), f"expected only ops.md entries, got {sources}"
PY
pass '--include globs are unioned'

# 7. --include with a path containing '/' matches fnmatch-style (not shell-glob).
#    fnmatch's '*' crosses '/' boundaries, so 'ops/*.kql' matches nested dirs too.
#    This documents the current (deliberate) behavior.
case_dir="$(fresh_case_dir)"
mkdir -p "$case_dir/ops/nested"
cat > "$case_dir/ops/nested/deep.kql" <<'KQL'
// deep
traces
KQL
cat > "$case_dir/ops/shallow.kql" <<'KQL'
// shallow
traces
KQL
out="$(python3 "$SUT" --cwd "$case_dir" --include 'ops/*.kql')"
python3 - "$out" <<'PY' || fail "--include with '/' failed: $out"
import sys, json
data = json.loads(sys.argv[1])
sources = sorted(e["source"] for e in data)
# Both files match because fnmatch's '*' crosses '/'.
assert sources == ["ops/nested/deep.kql", "ops/shallow.kql"], sources
PY
pass "--include 'ops/*.kql' matches nested paths (fnmatch semantics)"

# 8. --exclude drops matching files.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/keep.kql" <<'KQL'
// keep
traces
KQL
cat > "$case_dir/drop.kql" <<'KQL'
// drop
traces
KQL
out="$(python3 "$SUT" --cwd "$case_dir" --exclude 'drop.kql')"
python3 - "$out" <<'PY' || fail "--exclude filter failed: $out"
import sys, json
data = json.loads(sys.argv[1])
sources = sorted(e["source"] for e in data)
assert sources == ["keep.kql"], sources
PY
pass "--exclude drops matching files"

# 9. Tilde-fenced ```kql``` (using ~~~) is also recognized.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/tilde.md" <<'MD'
## tilde test

~~~kql
traces | take 5
~~~
MD
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "tilde-fence failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
assert "traces" in data[0]["content"]
PY
pass "tilde-fenced kql block recognized"

# 10. 'kusto' language label is accepted (alias for kql).
case_dir="$(fresh_case_dir)"
cat > "$case_dir/kusto.md" <<'MD'
## kusto test

```kusto
exceptions | take 1
```
MD
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "kusto label failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
assert "exceptions" in data[0]["content"]
PY
pass "kusto-labeled fenced block recognized"

# 11. .markdown extension is recognized like .md.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/ops.markdown" <<'MD'
## section

```kql
requests | take 3
```
MD
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail ".markdown extension failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
assert data[0]["source"].startswith("ops.markdown#")
PY
pass ".markdown extension treated like .md"

# 12. Empty .kql file is skipped (no entry emitted).
case_dir="$(fresh_case_dir)"
: > "$case_dir/empty.kql"
cat > "$case_dir/real.kql" <<'KQL'
// real
traces
KQL
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "empty-kql skip failed: $out"
import sys, json
data = json.loads(sys.argv[1])
sources = sorted(e["source"] for e in data)
assert sources == ["real.kql"], sources
PY
pass "empty .kql file is skipped"

# 13. Fenced block with no preceding heading falls back to 'source (block N)' title.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/noheading.md" <<'MD'
Some intro text only.

```kql
traces | count
```
MD
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "no-heading fallback failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
assert data[0]["title"] == "noheading.md (block 1)", data[0]
PY
pass "fenced block without heading uses fallback title"

# 14a. --include glob with zero matches returns an empty array (not an error).
case_dir="$(fresh_case_dir)"
cat > "$case_dir/polling.kql" <<'KQL'
// P
traces
KQL
out="$(python3 "$SUT" --cwd "$case_dir" --include 'nonexistent/*.kql')"
python3 - "$out" <<'PY' || fail "--include no-match failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert data == [], f"expected [] for no-match glob, got {data}"
PY
pass "--include with zero matches returns empty array"

# 14. Skip-dir pruning: .git/, node_modules/, and __pycache__/ contents are not discovered.
case_dir="$(fresh_case_dir)"
mkdir -p "$case_dir/.git" "$case_dir/node_modules" "$case_dir/__pycache__"
cat > "$case_dir/.git/hooks.kql" <<'KQL'
// should be skipped
traces
KQL
cat > "$case_dir/node_modules/lib.kql" <<'KQL'
// should be skipped
traces
KQL
cat > "$case_dir/__pycache__/cached.kql" <<'KQL'
// should be skipped
traces
KQL
cat > "$case_dir/keep.kql" <<'KQL'
// keep
traces
KQL
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "skip-dir pruning failed: $out"
import sys, json
data = json.loads(sys.argv[1])
sources = sorted(e["source"] for e in data)
assert sources == ["keep.kql"], f"expected only keep.kql, got {sources}"
PY
pass "skip-dirs (.git, node_modules, __pycache__) pruned"

# 15. `// @skill-skip` marker with a reason: emitted with skipped + empty content.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/helper.kql" <<'KQL'
// @skill-skip date-pinned analytical helper
let cycleTime = datetime(2026-04-10T23:00:15Z);
traces | where timestamp > cycleTime | take 5
KQL
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "@skill-skip with reason failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
e = data[0]
assert e["source"] == "helper.kql", e
assert e.get("skipped") == "date-pinned analytical helper", e
assert e["content"] == "", f"expected empty content on skipped entry, got {e['content']!r}"
PY
pass "@skill-skip marker with reason is honored"

# 16. `// @skill-skip` with no reason falls back to 'author-marked'.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/noreason.kql" <<'KQL'
// @skill-skip
traces | take 1
KQL
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "@skill-skip no-reason failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
assert data[0].get("skipped") == "author-marked", data[0]
PY
pass "@skill-skip without reason falls back to 'author-marked'"

# 17. `// @skill-skip` inside a markdown fenced block marks only that block as skipped.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/ops.md" <<'MD'
## Active
```kql
traces | take 1
```

## Helper
```kql
// @skill-skip hardcoded date
let t = datetime(2026-04-10T00:00:00Z);
traces | where timestamp > t
```
MD
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "@skill-skip in markdown fence failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 2, f"expected 2 entries, got {data}"
by_title = {e["title"]: e for e in data}
assert "skipped" not in by_title["Active"], by_title["Active"]
assert by_title["Helper"].get("skipped") == "hardcoded date", by_title["Helper"]
assert by_title["Helper"]["content"] == "", by_title["Helper"]
PY
pass "@skill-skip in markdown fence marks only that block"

# 18. `// @skill-skip` must be on the first non-blank line to count — a marker
#     buried mid-query is NOT treated as a skip.
case_dir="$(fresh_case_dir)"
cat > "$case_dir/buried.kql" <<'KQL'
// Real query
traces
// @skill-skip this is a middle-of-query comment, not a skip marker
| take 5
KQL
out="$(python3 "$SUT" --cwd "$case_dir")"
python3 - "$out" <<'PY' || fail "@skill-skip buried-line failed: $out"
import sys, json
data = json.loads(sys.argv[1])
assert len(data) == 1, f"expected 1 entry, got {data}"
assert "skipped" not in data[0], f"marker should only be honored on first non-blank line, got {data[0]}"
assert "traces" in data[0]["content"], data[0]
PY
pass "@skill-skip only on first non-blank line counts as a skip marker"

echo "all smoke tests passed"
