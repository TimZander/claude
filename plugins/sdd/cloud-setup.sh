#!/bin/bash
# Cloud environment setup for spec-driven development with the sdd plugin.
#
# Paste this file into the cloud environment's settings (environment menu → Edit → Setup
# script). It sets up an environment for sdd work only: the sdd and handoff plugins, gh, and a
# short ~/.claude/CLAUDE.md that points every session at the repository's sdd workflow. Nothing
# else: no shared team standards and no other plugins.
#
# Runs as root on Ubuntu 24.04 BEFORE Claude Code launches, and only when no cached
# environment exists. Editing it forces a cache rebuild.
#
# Must exit zero — a non-zero exit fails the session — so every fallible step ends in
# `|| true` and failures are reported as WARNING lines in the log. Keep total runtime under
# ~5 minutes so the cache can build.
#
# Test overrides (leave unset in a real environment):
#   CLOUD_SETUP_HOME  home directory for the log and ~/.claude/CLAUDE.md (default /root)
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

# ------------------------------------------------------------------ plugins
#
# A cloud session ignores plugins a repository enables in its own .claude/settings.json,
# so the plugins are installed through the plugin system here: sdd for the flow, and handoff
# (/handoff, /pickup, /handoff:relay, and their shortcuts /hh, /hp, /hr) for resuming work in a
# new session. Each install is independent: one that fails doesn't stop the others. `claude` may not be on PATH yet while
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
    for plugin in sdd handoff; do
        "$CLAUDE_BIN" plugin install "${plugin}@${MARKETPLACE_NAME}" \
            || echo "WARNING: the ${plugin} plugin did not install"
    done
    echo "--- plugins after install ---"
    "$CLAUDE_BIN" plugin list || true
else
    echo "WARNING: claude CLI not found — the sdd and handoff plugins were not installed"
fi

# ------------------------------------------------------------- instructions
#
# ~/.claude/CLAUDE.md is loaded in every session on this environment. It holds only the sdd
# working agreement, not the shared team standards, and it's written here rather than fetched
# because this script is pasted into the environment settings and can't read the repo.
mkdir -p "${SETUP_HOME}/.claude"
cat > "${SETUP_HOME}/.claude/CLAUDE.md" <<'MD'
# Spec-driven development environment

This environment is for spec-driven development with OpenSpec and the sdd plugin (`/sdd:*`
skills).

- **Follow the repository's workflow.** Read `.claude/sdd-workflow.md` (imported by the repo's
  `CLAUDE.md`) before changing anything, and follow its flow for every change, including its
  rules for recording decisions as ADRs.
- **A repository without sdd: ask, don't set it up.** If there's no `.claude/sdd-workflow.md`,
  tell the owner the repository isn't set up for spec-driven development and ask what they want.
  Never run `/sdd:init` unasked: setting up a repository is the owner's decision.
- **Use the sdd reviews.** `/sdd:spec-review` for the spec, `/sdd:conformance-review` for the
  code, and what the workflow adds for high-risk changes.
- **Hand off on purpose.** Before a pause or the end of a session, run `/handoff` (`/hh`);
  resume with `/pickup` (`/hp`). This container is reclaimed after a period of inactivity, so
  `/handoff` commits and pushes the note to the work branch, and `/pickup` deletes it again once
  it resumes. Instead of `/clear`, run `/handoff:relay` (`/hr`): it continues the work in a new
  cloud session, since a worker restart can bring back the context from before a `/clear`.
MD
echo "sdd instructions written: ${SETUP_HOME}/.claude/CLAUDE.md"

# -------------------------------------------------------------- verification
wait $APT_PID 2>/dev/null

if command -v gh >/dev/null 2>&1; then
    echo "gh: $(gh --version | head -1)"
else
    echo "WARNING: gh still missing — /sdd:archive-pr will need the Actions API to read logs"
fi

echo "=== sdd setup finished $(date -u) ==="
exit 0
