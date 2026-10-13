#!/bin/bash
# Profile-driven setup for Claude Code cloud environments.
#
# Usage: setup.sh <profile> [repo-dir]
#
#   <profile>   Name of a file in cloud/profiles/ (without .sh).
#   [repo-dir]  Checkout of this repo, used for profiles and team standards.
#               Defaults to the checkout this script lives in.
#
# Normally run by cloud/bootstrap.sh (the script pasted into the environment's
# Setup script field), which clones this repo and calls this with a profile.
# Runs as root on Ubuntu 24.04 BEFORE Claude Code launches.
#
# A profile is a bash file that sets:
#   PROFILE_DESCRIPTION  One line, logged at start.
#   PLUGINS              Space-separated plugins from this marketplace.
#   APT_PACKAGES         Space-separated apt packages.
#   NPM_PACKAGES         Space-separated global npm packages.
#   VERIFY_COMMANDS      Space-separated commands that must be on PATH afterwards.
#
# Exits non-zero only on a usage error. Every install step is best-effort and
# ends in `|| true`; failures surface as WARNING lines in the verification step.

PROFILE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${2:-$(dirname "$SCRIPT_DIR")}"
PROFILES_DIR="${REPO_DIR}/cloud/profiles"

# Overridable so the smoke test can run without root.
CLAUDE_HOME="${CLOUD_SETUP_CLAUDE_HOME:-/root/.claude}"
APT_SOURCES_DIR="${CLOUD_SETUP_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

MARKETPLACE_REPO="TimZander/claude"
MARKETPLACE_NAME="tzander-skills"
STANDARDS_PATH="standards/CLAUDE.md"

list_profiles() {
    local f
    for f in "$PROFILES_DIR"/*.sh; do
        [ -e "$f" ] && echo "  $(basename "$f" .sh)"
    done
}

if [ -z "$PROFILE" ] || [ ! -f "${PROFILES_DIR}/${PROFILE}.sh" ]; then
    echo "ERROR: unknown or missing profile '${PROFILE}'. Available profiles:" >&2
    list_profiles >&2
    echo "Usage: setup.sh <profile> [repo-dir]" >&2
    exit 2
fi

PROFILE_DESCRIPTION=""
PLUGINS=""
APT_PACKAGES=""
NPM_PACKAGES=""
VERIFY_COMMANDS=""
# shellcheck source=/dev/null
. "${PROFILES_DIR}/${PROFILE}.sh"

echo "profile: ${PROFILE} — ${PROFILE_DESCRIPTION}"

# --------------------------------------------------------------- apt / tools
#
# Two PPAs preconfigured in the base image (deadsnakes, ondrej/php) redirect to
# ppa.launchpadcontent.net, which is not on the Trusted allowlist, so they 403.
# Neither is needed here; removing them lets apt-get update finish cleanly.
APT_PID=""
if [ -n "$APT_PACKAGES" ]; then
    find "$APT_SOURCES_DIR" \( -name '*deadsnakes*' -o -name '*ondrej*' \) 2>/dev/null \
        | xargs -r rm -f

    # Deliberately NOT `update && install`. apt-get update returns non-zero when
    # any single source fails, so chaining with && meant one broken PPA
    # short-circuited the install and nothing was attempted at all.
    #
    # Backgrounded so it overlaps the plugin work below.
    # shellcheck disable=SC2086
    ( apt-get update -qq || true
      apt-get install -y -qq $APT_PACKAGES || true ) &
    APT_PID=$!
fi

# ------------------------------------------------------------------- plugins
#
# Installed through the plugin system rather than declared in a repo's
# .claude/settings.json or enabled at the account level. That distinction is the
# point: account-level enablement exposed the plugin's definition but left
# /deep-review un-invocable, because these plugins ship commands rather than
# bundled skills.
if [ -n "$PLUGINS" ]; then
    if command -v claude >/dev/null 2>&1; then
        claude plugin marketplace add "$MARKETPLACE_REPO" || true
        for p in $PLUGINS; do
            claude plugin install "${p}@${MARKETPLACE_NAME}" || true
        done
        echo "--- plugins after install ---"
        claude plugin list || true
    else
        echo "WARNING: claude not on PATH — plugin install skipped"
    fi
fi

# ----------------------------------------------------------------------- npm
if [ -n "$NPM_PACKAGES" ]; then
    if command -v npm >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        npm install -g --no-fund --no-audit $NPM_PACKAGES || true
    else
        echo "WARNING: npm not on PATH — skipped: ${NPM_PACKAGES}"
    fi
fi

# ----------------------------------------------------------------- standards
#
# ~/.claude/CLAUDE.md does not carry over from your machine; cloud sessions only
# see a repo's own CLAUDE.md. This is the same file your local sync writes, from
# the same repo, so the repo stays the single source of truth.
mkdir -p "$CLAUDE_HOME"
if [ -f "${REPO_DIR}/${STANDARDS_PATH}" ]; then
    cp "${REPO_DIR}/${STANDARDS_PATH}" "${CLAUDE_HOME}/CLAUDE.md"
    echo "standards installed: $(wc -l < "${CLAUDE_HOME}/CLAUDE.md") lines"
else
    echo "WARNING: ${STANDARDS_PATH} missing from ${REPO_DIR}"
fi

# -------------------------------------------------------------- verification
[ -n "$APT_PID" ] && wait "$APT_PID" 2>/dev/null

for cmd in $VERIFY_COMMANDS; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "${cmd}: $("$cmd" --version 2>/dev/null | head -1)"
    else
        echo "WARNING: ${cmd} missing — skills that shell out to ${cmd} will fail"
    fi
done

# Reported, never printed: a real token here would land in a log anyone using
# this environment can read.
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    echo "github auth: no token in env at setup time (proxy may inject at session start)"
elif [ "${GH_TOKEN:-${GITHUB_TOKEN:-}}" = "proxy-injected" ]; then
    echo "github auth: proxy-injected placeholder — gh authenticates via the proxy"
else
    echo "github auth: an explicit token is set in the environment"
fi

exit 0
