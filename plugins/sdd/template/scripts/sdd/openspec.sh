#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# Runs the OpenSpec CLI pinned in a repo's node_modules, with telemetry off.
#
#   bash openspec.sh [-C <dir>] [--cli-root <dir>] <openspec args...>
#
# -C <dir>          the directory to run in (default: the current one)
# --cli-root <dir>  the checkout whose node_modules holds the CLI (default: the
#                   git root of -C). The checks pass the trusted checkout here,
#                   so a checkout of a PR never supplies the code that runs.
#
# Never falls back to `npx openspec`: that downloads an unpinned version when
# the pinned one is missing, and would run with telemetry on outside CI.
#
# Exit status: the CLI's own, or 2 for a usage error, 3 when the CLI is not
# installed.

set -euo pipefail

usage() {
    echo "usage: openspec.sh [-C <dir>] [--cli-root <dir>] <openspec args...>" >&2
    exit 2
}

dir="."
cli_root=""
while [ $# -gt 0 ]; do
    case "$1" in
        -C) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
        --cli-root) [ $# -ge 2 ] || usage; cli_root="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || usage

if [ -z "$cli_root" ]; then
    cli_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
        echo "openspec.sh: $dir is not inside a git repository" >&2
        exit 3
    }
fi
bin="$cli_root/node_modules/@fission-ai/openspec/bin/openspec.js"
if [ ! -f "$bin" ]; then
    echo "openspec.sh: OpenSpec is not installed in $cli_root: run \`npm install\` there first" >&2
    exit 3
fi

cd "$dir"
OPENSPEC_TELEMETRY=0 exec node "$bin" "$@"
