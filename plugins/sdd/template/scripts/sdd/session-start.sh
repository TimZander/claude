#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# SessionStart hook: gets the repository ready for spec-driven work and prints its state,
# at the start of every session, local or cloud.
#
#   bash scripts/sdd/session-start.sh [<repo-dir>]
#
# 1. Installs the pinned OpenSpec CLI with `npm ci`, unless node_modules is current: npm's
#    own record of the last install (node_modules/.package-lock.json) is newer than
#    package-lock.json.
# 2. Prints the repository's sdd state, one `sdd:` line each: active changes waiting to be
#    archived, and whether learning mode is on.
#
# Its output goes into the session's context, so it stays short. It never fails the session:
# every problem is a `sdd: warning:` line, and it always exits 0.

root="${1:-${CLAUDE_PROJECT_DIR:-}}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root" 2>/dev/null || { echo "sdd: warning: cannot enter $root"; exit 0; }

if [ ! -f .claude/sdd-workflow.md ]; then
    echo "sdd: this repository isn't set up for spec-driven development; ask the owner before running /sdd:init."
    exit 0
fi

# 1. The pinned OpenSpec CLI.
if [ ! -f package-lock.json ]; then
    echo "sdd: warning: no package-lock.json, so OpenSpec wasn't installed; run \`npm install\` and commit the lock file."
elif [ -f node_modules/.package-lock.json ] && [ node_modules/.package-lock.json -nt package-lock.json ]; then
    : # current
elif ! command -v npm >/dev/null 2>&1; then
    echo "sdd: warning: npm not found, so OpenSpec wasn't installed."
elif OPENSPEC_TELEMETRY=0 npm ci --no-audit --no-fund >/dev/null 2>&1; then
    echo "sdd: installed the pinned OpenSpec CLI (npm ci)."
else
    echo "sdd: warning: \`npm ci\` failed; run it yourself to see why."
fi

# 2. State.
active="$(bash scripts/sdd/sdd-archive.sh active 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
if [ -n "$active" ]; then
    echo "sdd: active change(s) on this branch: $active. Before new work from the default branch, archive them with /sdd:archive-pr."
fi
if grep -qiE '^[^a-z]*ADR detail: *learning' CLAUDE.md 2>/dev/null; then
    echo "sdd: learning mode is on (ADR detail: learning): record decisions in full and add lessons."
fi
exit 0
