#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# Runs the OpenSpec CLI pinned in a repo's node_modules, with telemetry off.
#
#   bash openspec.sh [-C <dir>] <openspec args...>
#
# Never falls back to `npx openspec`: that downloads an unpinned version when
# the pinned one is missing, and would run with telemetry on outside CI.
#
# Exit status: the CLI's own, or 2 for a usage error, 3 when the CLI is not
# installed.

set -euo pipefail

usage() {
    echo "usage: openspec.sh [-C <dir>] <openspec args...>" >&2
    exit 2
}

dir="."
if [ "${1:-}" = "-C" ]; then
    [ $# -ge 2 ] || usage
    dir="$2"
    shift 2
fi
[ $# -ge 1 ] || usage

root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "openspec.sh: $dir is not inside a git repository" >&2
    exit 3
}
bin="$root/node_modules/@fission-ai/openspec/bin/openspec.js"
if [ ! -f "$bin" ]; then
    echo "openspec.sh: OpenSpec is not installed in $root: run \`npm install\` there first" >&2
    exit 3
fi

cd "$dir"
OPENSPEC_TELEMETRY=0 exec node "$bin" "$@"
