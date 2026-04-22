#!/usr/bin/env bash
# Resolve the *active* Application Insights Application ID for a Function App,
# by reading APPLICATIONINSIGHTS_CONNECTION_STRING from the app's own settings.
#
# Deliberately never calls `az resource list` — that's the documented gotcha
# which can return an unrelated App Insights resource in the same RG.
#
# Usage:
#   resolve_app_insights.sh \
#     --function-app <name> --resource-group <rg> [--subscription <sub>] \
#     [--excluded-ids <path-to-file-with-one-guid-per-line>]
#
# On success: prints "APP_INSIGHTS_ID=<guid>" as its last stdout line, exit 0.
# On failure or excluded-ID match: prints a diagnostic to stderr, exit non-zero.

set -euo pipefail

FUNCTION_APP=""
RESOURCE_GROUP=""
SUBSCRIPTION=""
EXCLUDED_IDS_FILE=""

usage() {
    cat >&2 <<USAGE
usage: $0 --function-app <name> --resource-group <rg> [--subscription <sub>] [--excluded-ids <file>]

Extracts ApplicationId from the Function App's APPLICATIONINSIGHTS_CONNECTION_STRING.
Refuses any App ID listed (one per line) in --excluded-ids.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --function-app) FUNCTION_APP="${2:-}"; shift 2;;
        --resource-group) RESOURCE_GROUP="${2:-}"; shift 2;;
        --subscription) SUBSCRIPTION="${2:-}"; shift 2;;
        --excluded-ids) EXCLUDED_IDS_FILE="${2:-}"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage; exit 2;;
    esac
done

if [ -z "$FUNCTION_APP" ] || [ -z "$RESOURCE_GROUP" ]; then
    usage
    exit 2
fi

if ! command -v az >/dev/null 2>&1; then
    echo "error: az CLI not found on PATH" >&2
    exit 1
fi

AZ_ARGS=(functionapp config appsettings list -g "$RESOURCE_GROUP" -n "$FUNCTION_APP" -o json)
if [ -n "$SUBSCRIPTION" ]; then
    AZ_ARGS+=(--subscription "$SUBSCRIPTION")
fi

SETTINGS_JSON="$(az "${AZ_ARGS[@]}" 2>&1)" || {
    echo "error: 'az functionapp config appsettings list' failed:" >&2
    echo "$SETTINGS_JSON" >&2
    exit 1
}

# Extract APPLICATIONINSIGHTS_CONNECTION_STRING via python (stdlib, avoids jq dep).
CONN_STRING="$(
    printf '%s' "$SETTINGS_JSON" | python3 -c '
import json, sys
settings = json.load(sys.stdin)
for s in settings:
    if s.get("name") == "APPLICATIONINSIGHTS_CONNECTION_STRING":
        print(s.get("value", ""))
        break
'
)"

if [ -z "$CONN_STRING" ]; then
    echo "error: APPLICATIONINSIGHTS_CONNECTION_STRING not set on function app '$FUNCTION_APP'" >&2
    echo "       cannot resolve active App Insights ID without it." >&2
    exit 1
fi

# Parse ApplicationId=<guid> from the connection string.
APP_INSIGHTS_ID="$(
    printf '%s' "$CONN_STRING" | python3 -c '
import sys, re
m = re.search(r"ApplicationId=([^;]+)", sys.stdin.read())
print(m.group(1) if m else "")
'
)"

if [ -z "$APP_INSIGHTS_ID" ]; then
    echo "error: APPLICATIONINSIGHTS_CONNECTION_STRING does not contain ApplicationId=..." >&2
    echo "       This is required for KQL queries via 'az monitor app-insights query'." >&2
    echo "       Newer connection strings include it; older ones may need to be regenerated in the portal." >&2
    exit 1
fi

if [ -n "$EXCLUDED_IDS_FILE" ] && [ -f "$EXCLUDED_IDS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Strip whitespace and skip empty/comment lines.
        trimmed="$(printf '%s' "$line" | tr -d '[:space:]')"
        case "$trimmed" in
            ""|\#*) continue;;
        esac
        if [ "$trimmed" = "$APP_INSIGHTS_ID" ]; then
            echo "error: resolved App Insights ID '$APP_INSIGHTS_ID' is on the excluded list ($EXCLUDED_IDS_FILE)." >&2
            echo "       Refusing to query it. Check the Function App's connection string points at the active resource." >&2
            exit 1
        fi
    done < "$EXCLUDED_IDS_FILE"
fi

echo "APP_INSIGHTS_ID=$APP_INSIGHTS_ID"
