#!/usr/bin/env bash
# Smoke test for build_timeline.py — happy path, publish-window edge cases, input validation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/build_timeline.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 1. Invalid JSON on stdin exits non-zero.
if printf 'not-json' | python3 "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit on invalid JSON"
fi
pass "invalid JSON rejected"

# 1b. Top-level JSON array is rejected with a clear error (must be an object).
err_out="$(printf '[1,2,3]' | python3 "$SUT" 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "top-level JSON must be an object" \
    || fail "expected top-level-array rejection, got: $err_out"
pass "top-level JSON array is rejected"

# 1c. Top-level JSON scalar is rejected with a clear error.
err_out="$(printf '"just a string"' | python3 "$SUT" 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "top-level JSON must be an object" \
    || fail "expected top-level-scalar rejection, got: $err_out"
pass "top-level JSON scalar is rejected"

# 1d. server set to a non-list is rejected with a clear error (not an uncaught TypeError).
err_out="$(printf '{"server":"not-a-list","device":[]}' | python3 "$SUT" 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "'server' must be a JSON array" \
    || fail "expected 'server' type rejection, got: $err_out"
pass "non-list server rejected with clear error"

# 1e. device set to a non-list is rejected.
err_out="$(printf '{"server":[],"device":42}' | python3 "$SUT" 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "'device' must be a JSON array" \
    || fail "expected 'device' type rejection, got: $err_out"
pass "non-list device rejected with clear error"

# 1f. publishWindows set to a non-list is rejected.
err_out="$(printf '{"server":[],"device":[],"publishWindows":"not-an-array"}' | python3 "$SUT" 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "'publishWindows' must be a JSON array" \
    || fail "expected 'publishWindows' type rejection, got: $err_out"
pass "non-list publishWindows rejected with clear error"

# 1g. server/device set to null (explicit JSON null) is tolerated — treated as [].
out="$(printf '{"server":null,"device":null}' | python3 "$SUT")"
echo "$out" | grep -q "(no events)" \
    || fail "expected null server/device to render '(no events)', got: $out"
pass "explicit null server/device is tolerated"

# 2. Empty inputs produce '(no events)'.
out="$(printf '{"server":[],"device":[]}' | python3 "$SUT")"
echo "$out" | grep -q "(no events)" || fail "expected '(no events)', got: $out"
pass "empty inputs produce '(no events)'"

# 3. Happy path: merged timeline, date header, publish-window annotation for nearby event.
input='{
  "server": [
    {"utc": "2026-04-22T22:34:12Z", "kind": "Poll", "message": "ProviderA success"}
  ],
  "device": [
    {"utc": "2026-04-22T22:35:07Z", "kind": "FCM", "message": "notification received"}
  ],
  "publishWindows": [
    {"name": "ProviderA", "utcTime": "22:30", "toleranceMinutes": 15}
  ]
}'
out="$(printf '%s' "$input" | python3 "$SUT")"
echo "$out" | grep -q "=== 2026-04-22 (UTC) ===" || fail "missing date header: $out"
echo "$out" | grep -q "22:34:12Z  \[server\] Poll: ProviderA success" || fail "missing server line: $out"
echo "$out" | grep -q "22:35:07Z  \[device\] FCM: notification received" || fail "missing device line: $out"
echo "$out" | grep -q "publish-window: ProviderA (+4m)" || fail "missing +4m publish-window annotation: $out"
pass "merged timeline + ProviderA +4m annotation"

# 4. Event outside tolerance is not annotated.
input_out='{
  "server": [{"utc": "2026-04-22T21:00:00Z", "kind": "Poll", "message": "far before"}],
  "device": [],
  "publishWindows": [{"name": "ProviderA", "utcTime": "22:30", "toleranceMinutes": 15}]
}'
out="$(printf '%s' "$input_out" | python3 "$SUT")"
if echo "$out" | grep -q "publish-window"; then
    fail "expected NO annotation for event outside tolerance: $out"
fi
pass "event outside tolerance not annotated"

# 5. Midnight-crossing: a 23:30 UTC window with 60min tolerance should match an event at 00:05 UTC the NEXT day.
input_mid='{
  "server": [{"utc": "2026-04-23T00:05:00Z", "kind": "Poll", "message": "just past midnight"}],
  "device": [],
  "publishWindows": [{"name": "LateWindow", "utcTime": "23:30", "toleranceMinutes": 60}]
}'
out="$(printf '%s' "$input_mid" | python3 "$SUT")"
echo "$out" | grep -q "publish-window: LateWindow" \
    || fail "expected midnight-crossing event to be annotated, got: $out"
pass "midnight-crossing event matches previous-day window"

# 6. Same bug in the other direction: window at 00:15 UTC, event at 23:55 UTC PREVIOUS day.
input_mid2='{
  "server": [{"utc": "2026-04-22T23:55:00Z", "kind": "Poll", "message": "just before midnight"}],
  "device": [],
  "publishWindows": [{"name": "EarlyWindow", "utcTime": "00:15", "toleranceMinutes": 30}]
}'
out="$(printf '%s' "$input_mid2" | python3 "$SUT")"
echo "$out" | grep -q "publish-window: EarlyWindow" \
    || fail "expected pre-midnight event to match next-day window, got: $out"
pass "pre-midnight event matches next-day window"

# 7. Tz-aware non-UTC input is normalized to UTC before formatting.
input_tz='{
  "server": [{"utc": "2026-04-22T17:04:12-05:30", "kind": "Poll", "message": "negative offset"}],
  "device": [],
  "publishWindows": []
}'
# 17:04 - (-05:30) = 22:34 UTC.
out="$(printf '%s' "$input_tz" | python3 "$SUT")"
echo "$out" | grep -q "22:34:12Z  \[server\] Poll: negative offset" \
    || fail "expected tz-aware input normalized to UTC, got: $out"
pass "tz-aware non-UTC input normalized to UTC"

# 8. Microsecond precision is accepted (rounded down to HH:MM:SS in the output).
input_us='{
  "server": [{"utc": "2026-04-22T22:34:12.987654Z", "kind": "Poll", "message": "micros"}],
  "device": [],
  "publishWindows": []
}'
out="$(printf '%s' "$input_us" | python3 "$SUT")"
echo "$out" | grep -q "22:34:12Z  \[server\] Poll: micros" \
    || fail "expected microsecond input accepted, got: $out"
pass "microsecond-precision timestamps accepted"

# 8b. Non-standard fractional-second precision (4 digits, 7 digits) as returned by live
# App Insights must parse on every supported Python, not just 3.11+. See the
# _FRAC_SECOND_RE normalization in build_timeline.py.
input_frac='{
  "server": [
    {"utc": "2026-04-22T19:55:04.9726Z",     "kind": "T", "message": "four-digit"},
    {"utc": "2026-04-22T19:55:04.9726361Z",  "kind": "T", "message": "seven-digit"},
    {"utc": "2026-04-22T19:55:04.1Z",        "kind": "T", "message": "one-digit"},
    {"utc": "2026-04-22T19:55:04.123456789Z","kind": "T", "message": "nine-digit"}
  ],
  "device": [],
  "publishWindows": []
}'
out="$(printf '%s' "$input_frac" | python3 "$SUT")"
for label in four-digit seven-digit one-digit nine-digit; do
    echo "$out" | grep -q "T: $label" \
        || fail "expected $label fractional-second event to render, got: $out"
done
pass "non-standard fractional-second precision (1, 4, 7, 9 digits) parses correctly"

# 9. Malformed utc on a single event: the event is skipped with a warning, others render.
input_mix='{
  "server": [
    {"utc": "not-a-timestamp", "kind": "Poll", "message": "bad"},
    {"utc": "2026-04-22T22:34:12Z", "kind": "Poll", "message": "good"}
  ],
  "device": [],
  "publishWindows": []
}'
out="$(printf '%s' "$input_mix" | python3 "$SUT" 2>/dev/null)"
if echo "$out" | grep -q "Poll: bad"; then
    fail "expected malformed event to be skipped, got: $out"
fi
echo "$out" | grep -q "Poll: good" || fail "expected good event to render, got: $out"
pass "malformed utc on one event is skipped, others render"

# 10. Missing utc key on an event → event skipped.
input_miss='{
  "server": [
    {"kind": "Poll", "message": "no utc"},
    {"utc": "2026-04-22T22:34:12Z", "kind": "Poll", "message": "with utc"}
  ],
  "device": [],
  "publishWindows": []
}'
out="$(printf '%s' "$input_miss" | python3 "$SUT" 2>/dev/null)"
if echo "$out" | grep -q "Poll: no utc"; then
    fail "expected event without utc key to be skipped, got: $out"
fi
echo "$out" | grep -q "Poll: with utc" || fail "expected valid event to render, got: $out"
pass "event missing utc key is skipped"

# 11. --input <path> reads from a file instead of stdin.
input_file="$TMP_ROOT/ev.json"
cat > "$input_file" <<'JSON'
{
  "server": [{"utc": "2026-04-22T22:34:12Z", "kind": "Poll", "message": "from file"}],
  "device": [],
  "publishWindows": []
}
JSON
out="$(python3 "$SUT" --input "$input_file")"
echo "$out" | grep -q "Poll: from file" \
    || fail "expected --input to read from file, got: $out"
pass "--input reads from file"

# 12. HH:MM:SS utcTime is accepted.
input_hms='{
  "server": [{"utc": "2026-04-22T22:30:30Z", "kind": "Poll", "message": "on the 30"}],
  "device": [],
  "publishWindows": [{"name": "Sec", "utcTime": "22:30:30", "toleranceMinutes": 1}]
}'
out="$(printf '%s' "$input_hms" | python3 "$SUT")"
echo "$out" | grep -q "publish-window: Sec (+0m)" \
    || fail "expected HH:MM:SS utcTime to anchor exactly, got: $out"
pass "HH:MM:SS utcTime form accepted"

# 13. Negative toleranceMinutes is rejected.
input_neg='{
  "server": [],
  "device": [],
  "publishWindows": [{"name": "W", "utcTime": "22:30", "toleranceMinutes": -5}]
}'
if printf '%s' "$input_neg" | python3 "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit for negative toleranceMinutes"
fi
pass "negative toleranceMinutes is rejected"

# 14. Non-integer toleranceMinutes is rejected with a clear error.
input_bad='{
  "server": [],
  "device": [],
  "publishWindows": [{"name": "W", "utcTime": "22:30", "toleranceMinutes": "fifteen"}]
}'
if printf '%s' "$input_bad" | python3 "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit for non-integer toleranceMinutes"
fi
pass "non-integer string toleranceMinutes is rejected"

# 14b. Float toleranceMinutes is rejected (not silently truncated).
input_float='{
  "server": [],
  "device": [],
  "publishWindows": [{"name": "W", "utcTime": "22:30", "toleranceMinutes": 15.7}]
}'
err_out="$(printf '%s' "$input_float" | python3 "$SUT" 2>&1 >/dev/null || true)"
if ! echo "$err_out" | grep -qi "non-integer"; then
    fail "expected float toleranceMinutes to be rejected with 'non-integer' message, got: $err_out"
fi
pass "float toleranceMinutes is rejected (not silently truncated)"

# 14c. Boolean toleranceMinutes is rejected (bool is-subclass-of int in Python).
input_bool='{
  "server": [],
  "device": [],
  "publishWindows": [{"name": "W", "utcTime": "22:30", "toleranceMinutes": true}]
}'
if printf '%s' "$input_bool" | python3 "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit for boolean toleranceMinutes"
fi
pass "boolean toleranceMinutes is rejected"

# 15. 4-segment utcTime is rejected (not HH:MM or HH:MM:SS).
input_4seg='{
  "server": [],
  "device": [],
  "publishWindows": [{"name": "W", "utcTime": "22:30:00:99", "toleranceMinutes": 15}]
}'
if printf '%s' "$input_4seg" | python3 "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit for 4-segment utcTime"
fi
pass "4-segment utcTime is rejected"

# 16. Signed-minute truncation is symmetric: event before window → '-Nm', event after → '+Nm'.
input_before='{
  "server": [{"utc": "2026-04-22T22:25:30Z", "kind": "Poll", "message": "before"}],
  "device": [],
  "publishWindows": [{"name": "W", "utcTime": "22:30", "toleranceMinutes": 10}]
}'
# 22:25:30 is 4.5 min BEFORE 22:30 → truncate-toward-zero gives -4.
out="$(printf '%s' "$input_before" | python3 "$SUT")"
echo "$out" | grep -q "publish-window: W (-4m)" \
    || fail "expected '-4m' truncation-toward-zero, got: $out"
pass "signed-minute truncation is symmetric (-4m for -4.5 min delta)"

# 17. Multiple competing windows: nearest-by-abs-delta wins.
input_compete='{
  "server": [{"utc": "2026-04-22T22:32:00Z", "kind": "Poll", "message": "between"}],
  "device": [],
  "publishWindows": [
    {"name": "Far",  "utcTime": "22:20", "toleranceMinutes": 60},
    {"name": "Near", "utcTime": "22:30", "toleranceMinutes": 60}
  ]
}'
out="$(printf '%s' "$input_compete" | python3 "$SUT")"
echo "$out" | grep -q "publish-window: Near" \
    || fail "expected 'Near' to win over 'Far', got: $out"
if echo "$out" | grep -q "publish-window: Far"; then
    fail "expected 'Far' NOT to appear once 'Near' wins, got: $out"
fi
pass "nearest-by-abs-delta publish window wins over farther candidates"

echo "all smoke tests passed"
