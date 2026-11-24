#!/usr/bin/env bash
# Sets the Azure DevOps CLI's default organization when none is set, so the
# team's az commands can run with `--detect false` and no --org. The team
# settings make every `az ... --org` ask (POLICY_ASK in
# standards/validate-settings.py). Run by setup-env.sh. The PowerShell twin is
# scripts/Set-AzDevOpsDefaultOrg.ps1; keep the two in step.
#
# A default the developer already set is kept, whatever it is. Setup never
# fails here: a missing Azure CLI or azure-devops extension, or an az call
# that fails, is reported (with az's own message) and skipped (exit 0).
# Exit 2 is a usage error.
#
# Every az call reads stdin from /dev/null, so a prompt (an auto-upgrade
# question, say) cannot block setup behind captured output. The extension is
# checked before any `az devops` call because az would otherwise offer to
# install it, which is a prompt too.
#
# SETUP_ENV_AZ names the az executable to run instead of `az`. It exists for
# the tests, which point it at a stub; setup says when it is in effect.
#
# Usage: set-az-default-org.sh <organization-url>

set -u

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: set-az-default-org.sh <organization-url>" >&2
    exit 2
fi

ORG="$1"
AZ="${SETUP_ENV_AZ:-az}"

if [ -n "${SETUP_ENV_AZ:-}" ]; then
    echo "Using az from SETUP_ENV_AZ: $AZ"
fi

if ! command -v "$AZ" >/dev/null 2>&1; then
    echo "Azure CLI not found - skipping. Install it, then re-run setup to set the default organization."
    exit 0
fi

if ! extension_output="$("$AZ" extension show --name azure-devops 2>&1 </dev/null)"; then
    echo "Could not confirm the azure-devops az extension is installed - skipping."
    echo "Install it with 'az extension add --name azure-devops', then re-run setup."
    printf 'az said: %s\n' "$extension_output"
    exit 0
fi

# stderr is kept with stdout so a failure can be shown; only `organization =`
# lines are read, so az warnings in the output do not matter.
if ! listing="$("$AZ" devops configure --list 2>&1 </dev/null)"; then
    echo "Warning: could not read the Azure DevOps CLI defaults - skipping." >&2
    printf 'az said: %s\n' "$listing" >&2
    exit 0
fi

# `organization = <url>` (CRLF on Windows); an unset default prints an empty value.
current="$(printf '%s\n' "$listing" | tr -d '\r' |
    sed -n 's/^[[:space:]]*organization[[:space:]]*=[[:space:]]*//p' | head -n 1 |
    sed 's/[[:space:]]*$//')"

# Lowercase, without trailing slashes (all of them, as TrimEnd does in the twin).
normalize() { printf '%s' "$1" | sed 's#/*$##' | tr '[:upper:]' '[:lower:]'; }

if [ -n "$current" ]; then
    if [ "$(normalize "$current")" = "$(normalize "$ORG")" ]; then
        echo "Azure DevOps default organization is already $current"
    else
        echo "Keeping your Azure DevOps default organization $current (the team's is $ORG)."
    fi
    exit 0
fi

if set_output="$("$AZ" devops configure --defaults "organization=$ORG" 2>&1 </dev/null)"; then
    echo "Set the Azure DevOps default organization to $ORG"
else
    echo "Warning: could not set the Azure DevOps default organization." >&2
    printf 'az said: %s\n' "$set_output" >&2
    echo "         Run 'az devops configure --defaults organization=$ORG' yourself." >&2
fi
exit 0
