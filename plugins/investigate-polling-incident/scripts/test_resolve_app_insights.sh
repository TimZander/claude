#!/usr/bin/env bash
# Smoke test for resolve_app_insights.sh — arg handling, parsing, safety rail, edge cases.
# Does NOT hit Azure; stubs the `az` CLI via a temporary PATH override.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/resolve_app_insights.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Install a baseline az-stub factory so each test can regenerate the stub on demand.
write_stub() {
    # Usage: write_stub <conn-string-value>
    # Emits a stub that prints a settings JSON containing the given conn-string.
    local conn="$1"
    cat > "$TMP_DIR/az" <<STUB
#!/usr/bin/env bash
cat <<'JSON'
[
  {"name": "OTHER", "value": "ignored"},
  {"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "${conn}"}
]
JSON
STUB
    chmod +x "$TMP_DIR/az"
}

# 1. Missing required args exits with usage.
if bash "$SUT" >/dev/null 2>&1; then
    fail "expected non-zero exit on missing args"
fi
pass "usage error on missing args"

# 2. Happy path: conn string contains ApplicationId; excluded file lists a different ID.
write_stub "InstrumentationKey=abc;ApplicationId=11111111-2222-3333-4444-555555555555"
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
write_stub "InstrumentationKey=abc;IngestionEndpoint=https://eastus-8.in.applicationinsights.azure.com/"
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

# 6. az stderr warnings do not pollute JSON parsing.
cat > "$TMP_DIR/az" <<'STUB'
#!/usr/bin/env bash
echo "WARNING: This command is from the following extension: application-insights" >&2
echo "WARNING: You have 3 update(s) available." >&2
cat <<'JSON'
[{"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "InstrumentationKey=abc;ApplicationId=22222222-0000-0000-0000-000000000000"}]
JSON
STUB
chmod +x "$TMP_DIR/az"
out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg)"
[ "$out" = "APP_INSIGHTS_ID=22222222-0000-0000-0000-000000000000" ] \
    || fail "expected az stderr warnings to be ignored, got: $out"
pass "az stderr warnings do not pollute JSON parsing"

# 7. Case-insensitive GUID safety-rail match: excluded uppercase vs resolved lowercase.
write_stub "InstrumentationKey=abc;ApplicationId=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
printf 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n' > "$TMP_DIR/excluded.txt"
if PATH="$TMP_DIR:$PATH" bash "$SUT" \
       --function-app fa --resource-group rg --excluded-ids "$TMP_DIR/excluded.txt" >/dev/null 2>&1; then
    fail "expected non-zero exit on case-insensitive excluded-ID match"
fi
pass "excluded-ID match is case-insensitive"

# 8. Case-insensitive ApplicationId key in the connection string is extracted correctly.
write_stub "InstrumentationKey=abc;applicationid=33333333-0000-0000-0000-000000000000"
out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg)"
[ "$out" = "APP_INSIGHTS_ID=33333333-0000-0000-0000-000000000000" ] \
    || fail "expected lowercase 'applicationid' key to be parsed, got: $out"
pass "case-insensitive ApplicationId key is parsed"

# 9. Whitespace around the ApplicationId value is stripped.
write_stub "InstrumentationKey=abc;ApplicationId=  44444444-0000-0000-0000-000000000000  "
out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg)"
[ "$out" = "APP_INSIGHTS_ID=44444444-0000-0000-0000-000000000000" ] \
    || fail "expected whitespace-padded ApplicationId to be stripped, got: $out"
pass "whitespace around ApplicationId is stripped"

# 10. Key Vault reference connection string triggers a distinct, helpful error.
write_stub "@Microsoft.KeyVault(SecretUri=https://my-vault.vault.azure.net/secrets/ai-conn/abc)"
err_out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "Key Vault reference" \
    || fail "expected Key Vault-specific error message, got: $err_out"
pass "Key Vault reference is detected with a clear error"

# 11. Malformed (non-GUID) ApplicationId value is rejected with a clear error.
write_stub "InstrumentationKey=abc;ApplicationId=not-a-guid"
err_out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg 2>&1 >/dev/null || true)"
echo "$err_out" | grep -qi "not a well-formed GUID" \
    || fail "expected malformed GUID to be flagged, got: $err_out"
pass "malformed GUID is rejected"

# 12. CRLF line endings in excluded-ids file are handled (tr strips \r).
write_stub "InstrumentationKey=abc;ApplicationId=55555555-0000-0000-0000-000000000000"
printf '55555555-0000-0000-0000-000000000000\r\n' > "$TMP_DIR/excluded.txt"
if PATH="$TMP_DIR:$PATH" bash "$SUT" \
       --function-app fa --resource-group rg --excluded-ids "$TMP_DIR/excluded.txt" >/dev/null 2>&1; then
    fail "expected CRLF-terminated excluded line to still match"
fi
pass "CRLF excluded-IDs file is handled"

# 13. Comment and blank lines in the excluded-ids file are ignored.
write_stub "InstrumentationKey=abc;ApplicationId=66666666-0000-0000-0000-000000000000"
{
    printf '# this is a comment\n'
    printf '\n'
    printf '   \n'
    printf '99999999-0000-0000-0000-000000000000\n'
} > "$TMP_DIR/excluded.txt"
out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" \
    --function-app fa --resource-group rg --excluded-ids "$TMP_DIR/excluded.txt")"
[ "$out" = "APP_INSIGHTS_ID=66666666-0000-0000-0000-000000000000" ] \
    || fail "expected comment/blank lines to be ignored and resolve to succeed, got: $out"
pass "comment lines and blank lines in excluded-ids are ignored"

# 14. --subscription is forwarded to the az call. Stub records args so we can verify.
cat > "$TMP_DIR/az" <<STUB
#!/usr/bin/env bash
# Record args for later inspection. Deliberately goes to a separate file so the
# script's stdout capture stays clean.
printf '%s\n' "\$@" > "$TMP_DIR/az_args.log"
cat <<'JSON'
[{"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "InstrumentationKey=abc;ApplicationId=77777777-0000-0000-0000-000000000000"}]
JSON
STUB
chmod +x "$TMP_DIR/az"
out="$(PATH="$TMP_DIR:$PATH" bash "$SUT" --function-app fa --resource-group rg --subscription sub-123)"
[ "$out" = "APP_INSIGHTS_ID=77777777-0000-0000-0000-000000000000" ] \
    || fail "happy-path with subscription failed: $out"
grep -q "^--subscription$" "$TMP_DIR/az_args.log" \
    || fail "expected --subscription flag to reach az, got args: $(cat "$TMP_DIR/az_args.log")"
grep -q "^sub-123$" "$TMP_DIR/az_args.log" \
    || fail "expected sub-123 value to reach az, got args: $(cat "$TMP_DIR/az_args.log")"
pass "--subscription is forwarded to az"

echo "all smoke tests passed"
