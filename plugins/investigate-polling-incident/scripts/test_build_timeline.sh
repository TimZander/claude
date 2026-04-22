#!/usr/bin/env bash
# Smoke test for build_timeline.py — usage error + happy path + publish-window annotation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/build_timeline.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# 1. Invalid JSON on stdin exits non-zero.
if printf 'not-json' | python3 "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit on invalid JSON"
fi
pass "invalid JSON rejected"

# 2. Empty inputs produce '(no events)'.
out="$(printf '{"server":[],"device":[]}' | python3 "$SUT")"
echo "$out" | grep -q "(no events)" || fail "expected '(no events)', got: $out"
pass "empty inputs produce '(no events)'"

# 3. Happy path: merged timeline, date header, publish-window annotation for nearby event.
input='{
  "server": [
    {"utc": "2026-04-22T22:34:12Z", "kind": "Poll", "message": "CAIC success"}
  ],
  "device": [
    {"utc": "2026-04-22T22:35:07Z", "kind": "FCM", "message": "notification received"}
  ],
  "publishWindows": [
    {"name": "CAIC", "utcTime": "22:30", "toleranceMinutes": 15}
  ]
}'
out="$(printf '%s' "$input" | python3 "$SUT")"
echo "$out" | grep -q "=== 2026-04-22 (UTC) ===" || fail "missing date header: $out"
echo "$out" | grep -q "22:34:12Z  \[server\] Poll: CAIC success" || fail "missing server line: $out"
echo "$out" | grep -q "22:35:07Z  \[device\] FCM: notification received" || fail "missing device line: $out"
echo "$out" | grep -q "publish-window: CAIC (+4m)" || fail "missing +4m publish-window annotation: $out"
pass "merged timeline + CAIC +4m annotation"

# 4. Event outside tolerance is not annotated.
input_out='{
  "server": [{"utc": "2026-04-22T21:00:00Z", "kind": "Poll", "message": "far before CAIC"}],
  "device": [],
  "publishWindows": [{"name": "CAIC", "utcTime": "22:30", "toleranceMinutes": 15}]
}'
out="$(printf '%s' "$input_out" | python3 "$SUT")"
if echo "$out" | grep -q "publish-window"; then
    fail "expected NO annotation for event outside tolerance: $out"
fi
pass "event outside tolerance not annotated"

echo "all smoke tests passed"
