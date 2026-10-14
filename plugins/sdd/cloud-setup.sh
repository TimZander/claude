#!/bin/bash
# Cloud environment setup for spec-driven development with the sdd plugin.
#
# Paste this file into the cloud environment's settings (environment menu → Edit → Setup
# script). It sets up an environment for sdd work only: the sdd plugin and gh, and nothing
# else, so no shared team standards and no other plugins.
#
# Runs as root on Ubuntu 24.04 BEFORE Claude Code launches, and only when no cached
# environment exists. Editing it forces a cache rebuild.
#
# Must exit zero — a non-zero exit fails the session — so every fallible step ends in
# `|| true` and failures are reported as WARNING lines in the log. Keep total runtime under
# ~5 minutes so the cache can build.
#
# Test overrides (leave unset in a real environment):
#   CLOUD_SETUP_HOME  home directory for the log (default /root)
#   SDD_MARKETPLACE   marketplace source: owner/repo, git URL or local path
#                     (default TimZander/claude)

SETUP_HOME="${CLOUD_SETUP_HOME:-/root}"
LOG="${SETUP_HOME}/setup-script.log"
mkdir -p "$SETUP_HOME"
exec > >(tee -a "$LOG") 2>&1
echo "=== sdd setup started $(date -u) ==="

MARKETPLACE_SOURCE="${SDD_MARKETPLACE:-TimZander/claude}"
MARKETPLACE_NAME="tzander-skills"

# --------------------------------------------------------------- apt / tools
#
# gh: /sdd:archive-pr reads the sdd-checks job log, and `gh run view --log` is one way.
#
# Two PPAs preconfigured in the base image (deadsnakes, ondrej/php) redirect to
# ppa.launchpadcontent.net, which is not on the Trusted allowlist, so they 403.
# Neither is needed here; removing them lets apt-get update finish cleanly.
find /etc/apt/sources.list.d \( -name '*deadsnakes*' -o -name '*ondrej*' \) 2>/dev/null \
    | xargs -r rm -f 2>/dev/null || true

# Deliberately NOT `update && install`: apt-get update returns non-zero when any single
# source fails, which would skip the install. Backgrounded to overlap the plugin work.
( apt-get update -qq || true
  apt-get install -y -qq gh || true ) &
APT_PID=$!

# ------------------------------------------------------------------- plugin
#
# A cloud session ignores plugins a repository enables in its own .claude/settings.json,
# so sdd is installed through the plugin system here. `claude` may not be on PATH yet while
# the setup script runs, so look in the usual install locations as well.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ]; then
    for candidate in /opt/node*/bin/claude /usr/local/bin/claude /usr/bin/claude; do
        if [ -x "$candidate" ]; then
            CLAUDE_BIN="$candidate"
            break
        fi
    done
fi
if [ -n "$CLAUDE_BIN" ]; then
    # On a re-run the marketplace is already there; refresh it instead.
    "$CLAUDE_BIN" plugin marketplace add "$MARKETPLACE_SOURCE" \
        || "$CLAUDE_BIN" plugin marketplace update "$MARKETPLACE_NAME" || true
    "$CLAUDE_BIN" plugin install "sdd@${MARKETPLACE_NAME}" \
        || echo "WARNING: the sdd plugin did not install"
    echo "--- plugins after install ---"
    "$CLAUDE_BIN" plugin list || true
else
    echo "WARNING: claude CLI not found — the sdd plugin was not installed"
fi

# -------------------------------------------------------------- verification
wait $APT_PID 2>/dev/null

if command -v gh >/dev/null 2>&1; then
    echo "gh: $(gh --version | head -1)"
else
    echo "WARNING: gh still missing — /sdd:archive-pr will need the Actions API to read logs"
fi

echo "=== sdd setup finished $(date -u) ==="
exit 0
