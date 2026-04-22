#!/usr/bin/env bash
# Smoke test for resolve_app_insights.sh — missing args + excluded-ID refusal.
# Does NOT hit Azure; stubs the `az` CLI via a temporary PATH override.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/resolve_app_insights.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Missing required args exits with usage.
if bash "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit on missing args"
fi
pass "usage error on missing args"

# 2. Stub az to return a settings JSON with a conn string containing ApplicationId=GOOD-ID.
# Also create an excluded-ids file containing a DIFFERENT id — happy path.
cat > "$TMP_DIR/az" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: echoes a fixed JSON matching `functionapp config appsettings list`.
cat <<'JSON'
[
  {"name": "OTHER_SETTING", "value": "ignored"},
  {"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "InstrumentationKey=abc;IngestionEndpoint=https://eastus-8.in.applicationinsights.azure.com/;ApplicationId=11111111-2222-3333-4444-555555555555"}
]
JSON
STUB
chmod +x "$TMP_DIR/az"

printf '99999999-0000-0000-0000-000000000000\n' > "$TMP_DIR/excluded.txt"

out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" \
    --function-app fa --resource-group rg --excluded-ids "$TMP_DIR/excluded.txt")"
[ "$out" = "APP_INSIGHTS_ID=11111111-2222-3333-4444-555555555555" ] \
    || fail "happy-path output wrong: $out"
pass "happy path extracts ApplicationId"

# 3. Excluded-ID match must hard-refuse.
printf '11111111-2222-3333-4444-555555555555\n' > "$TMP_DIR/excluded.txt"
if PATH="$TMP_DIR:$PATH" bash "$SUT" \
       --function-app fa --resource-group rg --excluded-ids "$TMP_DIR/excluded.txt" >/dev/null 2>&1; then
    fail "expected non-zero exit when App ID is on excluded list"
fi
pass "excluded ID is refused"

# 4. Missing ApplicationId in connection string is a clear error.
cat > "$TMP_DIR/az" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "InstrumentationKey=abc;IngestionEndpoint=https://eastus-8.in.applicationinsights.azure.com/"}
]
JSON
STUB
chmod +x "$TMP_DIR/az"
if PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg >/dev/null 2>&1; then
    fail "expected non-zero exit when ApplicationId is missing from conn string"
fi
pass "missing ApplicationId is a clear failure"

# 5. Missing APPLICATIONINSIGHTS_CONNECTION_STRING entirely is a clear error.
cat > "$TMP_DIR/az" <<'STUB'
#!/usr/bin/env bash
echo '[{"name":"NOT_THE_ONE","value":"x"}]'
STUB
chmod +x "$TMP_DIR/az"
if PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg >/dev/null 2>&1; then
    fail "expected non-zero exit when conn string setting is missing"
fi
pass "missing conn string setting is a clear failure"

# 6. Stub az that writes a warning to stderr and valid JSON to stdout (very common in practice —
#    e.g., "WARNING: This command is from the following extension: application-insights").
#    This must succeed, not silently break the json.load in the next pipeline.
cat > "$TMP_DIR/az" <<'STUB'
#!/usr/bin/env bash
echo "WARNING: This command is from the following extension: application-insights" >&2
echo "WARNING: You have 3 update(s) available." >&2
cat <<'JSON'
[
  {"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "InstrumentationKey=abc;ApplicationId=22222222-0000-0000-0000-000000000000"}
]
JSON
STUB
chmod +x "$TMP_DIR/az"
out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg)"
[ "$out" = "APP_INSIGHTS_ID=22222222-0000-0000-0000-000000000000" ] \
    || fail "expected az stderr warnings to be ignored, got: $out"
pass "az stderr warnings do not pollute JSON parsing"

echo "all smoke tests passed"
