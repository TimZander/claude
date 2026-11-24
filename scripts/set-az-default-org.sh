#!/usr/bin/env bash
# Sets the Azure DevOps CLI's default organization when none is set, so the
# team's az commands can leave out --org. The team settings make every
# `az ... --org` prompt (POLICY_ASK in standards/validate-settings.py), and
# without --org az takes the organization from the repository's remote or
# from this default. Run by setup-env.sh. The PowerShell twin is
# scripts/Set-AzDevOpsDefaultOrg.ps1; keep the two in step.
#
# A default the developer already set is kept, whatever it is. Setup never
# fails here: a missing Azure CLI or azure-devops extension, or an az call
# that fails, is reported and skipped (exit 0). Exit 2 is a usage error.
#
# SETUP_ENV_AZ names the az executable to run instead of `az` (tests use a stub).
#
# Usage: set-az-default-org.sh <organization-url>

set -u

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: set-az-default-org.sh <organization-url>" >&2
    exit 2
fi

ORG="$1"
AZ="${SETUP_ENV_AZ:-az}"

if ! command -v "$AZ" >/dev/null 2>&1; then
    echo "Azure CLI not found - skipping. Install it, then re-run setup to set the default organization."
    exit 0
fi

if ! "$AZ" extension show --name azure-devops >/dev/null 2>&1; then
    echo "The azure-devops az extension is not installed - skipping."
    echo "Install it with 'az extension add --name azure-devops', then re-run setup."
    exit 0
fi

if ! listing="$("$AZ" devops configure --list 2>/dev/null)"; then
    echo "Warning: could not read the Azure DevOps CLI defaults - skipping." >&2
    exit 0
fi

# `organization = <url>` (CRLF on Windows); an unset default prints an empty value.
current="$(printf '%s\n' "$listing" | tr -d '\r' |
    sed -n 's/^[[:space:]]*organization[[:space:]]*=[[:space:]]*//p' | head -n 1 |
    sed 's/[[:space:]]*$//')"

normalize() { printf '%s' "${1%/}" | tr '[:upper:]' '[:lower:]'; }

if [ -n "$current" ]; then
    if [ "$(normalize "$current")" = "$(normalize "$ORG")" ]; then
        echo "Azure DevOps default organization is already $current"
    else
        echo "Keeping your Azure DevOps default organization $current (the team's is $ORG)."
    fi
    exit 0
fi

if "$AZ" devops configure --defaults "organization=$ORG" >/dev/null 2>&1; then
    echo "Set the Azure DevOps default organization to $ORG"
else
    echo "Warning: could not set the Azure DevOps default organization." >&2
    echo "         Run 'az devops configure --defaults organization=$ORG' yourself." >&2
fi
exit 0
