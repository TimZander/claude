#!/usr/bin/env bash
# Tests for scripts/claude-usage-report.py.
#
#   step 0: Python unit tests (logic in isolation — no ccusage required)
#   step 1: --help loads (catches Python syntax / argparse errors)
#   step 2: end-to-end run when ccusage / npx is available — both files
#           appear with expected JSON keys and markdown headers
#   step 3: negative case — inverted window exits non-zero

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-usage-report.py"
UNIT_TEST="$SCRIPT_DIR/test_claude_usage_report_unit.py"
THROTTLE_UNIT_TEST="$SCRIPT_DIR/test_claude_throttle_audit_unit.py"

# Probe python3 then python — Macs and some Linux distros only ship one.
PYTHON="${PYTHON:-$(command -v python3 || command -v python || true)}"
if [ -z "$PYTHON" ]; then
    echo "FAIL: no python3 or python on PATH" >&2
    exit 1
fi

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: script not found at $SCRIPT" >&2
    exit 1
fi

# Step 0: unit tests — pure-Python, no external deps.
if [ -f "$UNIT_TEST" ]; then
    echo "step 0a: cost-report unit tests"
    "$PYTHON" "$UNIT_TEST" -v 2>&1 | tail -3
fi
if [ -f "$THROTTLE_UNIT_TEST" ]; then
    echo "step 0b: throttle-audit unit tests"
    "$PYTHON" "$THROTTLE_UNIT_TEST" -v 2>&1 | tail -3
fi

# Step 1: help text loads.
echo "step 1: --help loads"
"$PYTHON" "$SCRIPT" --help >/dev/null

# Step 2 & 3: only when ccusage or npx is available.
if command -v ccusage >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
    echo "step 2: tight-window run produces both files"
    # Use Python's tempfile so the path works for the Python script on Windows
    # (Git Bash's `mktemp -d` returns `/tmp/...` which Python can't resolve).
    TMPDIR_OUT="$("$PYTHON" -c 'import tempfile; print(tempfile.mkdtemp())')"
    trap 'rm -rf "$TMPDIR_OUT"' EXIT
    YESTERDAY="$("$PYTHON" -c 'from datetime import date,timedelta;print((date.today()-timedelta(days=1)).isoformat())')"
    TODAY="$("$PYTHON" -c 'from datetime import date;print(date.today().isoformat())')"

    "$PYTHON" "$SCRIPT" --since "$YESTERDAY" --until "$TODAY" \
        --user smoketest --out-dir "$TMPDIR_OUT" >/dev/null

    [ -f "$TMPDIR_OUT/smoketest-summary.md" ] || { echo "FAIL: summary missing" >&2; exit 1; }
    [ -f "$TMPDIR_OUT/smoketest-aggregate.json" ] || { echo "FAIL: aggregate missing" >&2; exit 1; }

    # Pass paths as argv to avoid Windows backslash-escape issues.
    "$PYTHON" -c "
import json, sys
agg = json.load(open(sys.argv[1]))
required = ['schema_version', 'user', 'window', 'totals', 'daily_stats',
            'per_model_cost_usd', 'block_stats', 'ccusage_version',
            'cost_mode', 'timezone']
for key in required:
    if key not in agg:
        print('FAIL: aggregate missing key:', key, file=sys.stderr); sys.exit(1)
md = open(sys.argv[2], encoding='utf-8').read()
for header in ('## Summary', '## Per-model split', '## Token totals', '## Daily timeline'):
    if header not in md:
        print('FAIL: summary missing header:', header, file=sys.stderr); sys.exit(1)
print('aggregate has all required keys; summary has all required headers')
" "$TMPDIR_OUT/smoketest-aggregate.json" "$TMPDIR_OUT/smoketest-summary.md"

    echo "step 3: inverted window exits non-zero"
    if "$PYTHON" "$SCRIPT" --since "$TODAY" --until "$YESTERDAY" \
        --user smoketest --out-dir "$TMPDIR_OUT" >/dev/null 2>&1; then
        echo "FAIL: inverted window did not exit non-zero" >&2
        exit 1
    fi
else
    echo "step 2: skipped (no ccusage or npx on PATH)"
    echo "step 3: skipped (depends on step 2)"
fi

echo "PASS"
