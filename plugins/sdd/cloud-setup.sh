#!/bin/bash
#
# Cloud environment setup script for spec-driven development with the sdd plugin.
#
# Paste this into the cloud environment's settings (environment menu → Edit → Setup script).
# It runs as root, after the repository is cloned and before Claude Code starts, and its
# result is cached with the environment (re-run when the script changes, or after about
# seven days). A repository's own .claude/settings.json can't install plugins in a cloud
# session, which is why this lives here.
#
# What it does:
#   1. Adds the tzander-skills marketplace (or updates it if it's already there).
#   2. Installs the sdd plugin at user scope, so /sdd:* skills are in every session.
#
# It doesn't install a repository's npm packages: the cache is per environment, not per
# repository. Run `npm ci` in the session (or from a SessionStart hook) when a repository
# needs OpenSpec.
#
# Needs network access to github.com (the default "Trusted" level allows it).
# SDD_MARKETPLACE overrides the marketplace source, for testing a branch from a local path.

set -euo pipefail

MARKETPLACE="${SDD_MARKETPLACE:-TimZander/claude}"

# `claude` may not be on PATH yet while the setup script runs.
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
    for candidate in /opt/node*/bin/claude /usr/local/bin/claude /usr/bin/claude; do
        if [ -x "$candidate" ]; then
            CLAUDE_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$CLAUDE_BIN" ]; then
    echo "sdd cloud setup: the claude CLI was not found, so the sdd plugin was not installed" >&2
    exit 1
fi

if "$CLAUDE_BIN" plugin marketplace list 2>/dev/null | grep -q 'tzander-skills'; then
    "$CLAUDE_BIN" plugin marketplace update tzander-skills
else
    "$CLAUDE_BIN" plugin marketplace add "$MARKETPLACE"
fi

"$CLAUDE_BIN" plugin install sdd@tzander-skills

echo "sdd cloud setup: done"
