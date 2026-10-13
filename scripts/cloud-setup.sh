#!/bin/bash
# Cloud environment setup for Claude Code.
#
# Runs as root on Ubuntu 24.04 BEFORE Claude Code launches, and only when no
# cached environment exists. Editing this file forces a cache rebuild.
#
# Must exit zero — a non-zero exit fails the session — so every fallible step
# ends in `|| true`. Keep total runtime under ~5 minutes so the cache can build.

LOG=/root/setup-script.log
exec > >(tee -a "$LOG") 2>&1
echo "=== setup started $(date -u) ==="

MARKETPLACE_REPO="TimZander/claude"
MARKETPLACE_NAME="tzander-skills"
PLUGINS="deep-review craft-pr craft-stage-commit-push start-work self-review"
STANDARDS_PATH="standards/CLAUDE.md"

# --------------------------------------------------------------- apt / tools
#
# Two PPAs preconfigured in the base image (deadsnakes, ondrej/php) redirect to
# ppa.launchpadcontent.net, which is not on the Trusted allowlist, so they 403.
# Neither is needed here; removing them lets apt-get update finish cleanly.
find /etc/apt/sources.list.d \( -name '*deadsnakes*' -o -name '*ondrej*' \) 2>/dev/null \
    | xargs -r rm -f

# Deliberately NOT `update && install`. apt-get update returns non-zero when any
# single source fails, so chaining with && meant one broken PPA short-circuited
# the install and gh was never attempted at all.
#
# Backgrounded so it overlaps the plugin work below.
( apt-get update -qq || true
  apt-get install -y -qq gh || true ) &
APT_PID=$!

# ------------------------------------------------------------------- plugins
#
# Installed through the plugin system rather than declared in a repo's
# .claude/settings.json or enabled at the account level. That distinction is the
# point: account-level enablement exposed the plugin's definition but left
# /deep-review un-invocable, because these plugins ship commands rather than
# bundled skills.
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

# ----------------------------------------------------------------- standards
#
# ~/.claude/CLAUDE.md does not carry over from your machine; cloud sessions only
# see a repo's own CLAUDE.md. This is the same file your local sync writes,
# fetched from the same repo, so the repo stays the single source of truth.
mkdir -p /root/.claude
if git clone --depth 1 "https://github.com/${MARKETPLACE_REPO}" /tmp/std 2>/dev/null; then
    if [ -f "/tmp/std/${STANDARDS_PATH}" ]; then
        cp "/tmp/std/${STANDARDS_PATH}" /root/.claude/CLAUDE.md
        echo "standards installed: $(wc -l < /root/.claude/CLAUDE.md) lines"
    else
        echo "WARNING: ${STANDARDS_PATH} missing from the clone"
    fi
    rm -rf /tmp/std
else
    echo "WARNING: could not clone ${MARKETPLACE_REPO}"
fi

# -------------------------------------------------------------- verification
wait $APT_PID 2>/dev/null

if command -v gh >/dev/null 2>&1; then
    echo "gh: $(gh --version | head -1)"
else
    echo "WARNING: gh still missing — skills that shell out to gh will fail"
fi

# Reported, never printed: a real token here would land in a log anyone using
# this environment can read.
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    echo "github auth: no token in env at setup time (proxy may inject at session start)"
elif [ "${GH_TOKEN:-${GITHUB_TOKEN:-}}" = "proxy-injected" ]; then
    echo "github auth: proxy-injected placeholder — gh authenticates via the proxy"
else
    echo "github auth: an explicit token is set in the environment"
fi

echo "=== setup finished $(date -u) ==="
exit 0
