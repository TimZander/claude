#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# Do the specs validate now, and do they still validate once every active
# change is archived?
#
#   bash check-specs.sh [-C <dir>] [--rev <rev>]
#
# `openspec validate --strict` checks a change's deltas, not the main specs they
# produce, so a change can validate and still archive into a spec that does not
# (OpenSpec's 500-character limit on a requirement applies only once archived).
# This script runs both checks in a temporary checkout of <rev> (default HEAD):
# only committed files count, so commit the change first.
#
# <rev> is read as data. The OpenSpec CLI always comes from <dir>'s own
# node_modules, never from the checkout of <rev>, and a <rev> that tracks
# node_modules/ fails outright. CI relies on this to check a PR without
# running its code.
#
# Prints `spec-validate: <state>` and `archived-specs: <state>`, then as its
# last line `spec-checks: success|failure`. The CLI's own output is quoted
# (each line starts with `  | `), so text from <rev> never starts a line.
#
# Exit status: 0 success, 1 failure, 2 usage error, 3 internal error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENSPEC="$SCRIPT_DIR/openspec.sh"

usage() {
    echo "usage: check-specs.sh [-C <dir>] [--rev <rev>]" >&2
    exit 2
}

dir="."
rev="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        -C) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
        --rev) [ $# -ge 2 ] || usage; rev="$2"; shift 2 ;;
        *) usage ;;
    esac
done

internal() {
    echo "check-specs: $*" >&2
    echo "- reason: $*"
    echo "spec-checks: failure"
    exit 3
}

# Quotes command output: every line indented, workflow-command syntax broken.
quote() {
    sed -e 's/##\[/#\\u0023[/g' -e 's/::/:\\u003a/g' -e 's/^/  | /'
}

root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || internal "$dir is not a git repository"
commit="$(git -C "$root" rev-parse --verify --quiet "$rev^{commit}")" || internal "$rev is not a commit"
[ -f "$root/node_modules/@fission-ai/openspec/bin/openspec.js" ] \
    || internal "OpenSpec is not installed: run \`npm install\` first"

if [ -n "$(git -C "$root" ls-tree --name-only "$commit" node_modules)" ]; then
    echo "- $rev tracks node_modules/: refusing to check it"
    echo "spec-validate: failure"
    echo "archived-specs: failure"
    echo "spec-checks: failure"
    exit 1
fi

scratch="$(mktemp -d)"
checkout="$scratch/rev"
cleanup() {
    git -C "$root" worktree remove --force "$checkout" >/dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT
git -C "$root" worktree add -q --detach "$checkout" "$commit" >/dev/null 2>&1 \
    || internal "cannot check out $rev"

cli() {
    bash "$OPENSPEC" -C "$checkout" --cli-root "$root" "$@"
}

status=0

if cli validate --all --strict --no-interactive >"$scratch/out" 2>&1; then
    quote < "$scratch/out"
    echo "spec-validate: success"
else
    quote < "$scratch/out"
    echo "spec-validate: failure"
    status=1
fi

if ! changes="$(bash "$SCRIPT_DIR/sdd-archive.sh" active -C "$checkout" 2>"$scratch/out")"; then
    quote < "$scratch/out"
    echo "archived-specs: failure"
    status=1
elif [ -z "$changes" ]; then
    echo "archived-specs: no-active-change"
else
    archived=1
    while IFS= read -r name; do
        if ! cli archive "$name" --yes >"$scratch/out" 2>&1; then
            echo "- \`openspec archive $name\` failed:"
            quote < "$scratch/out"
            archived=0
            break
        fi
    done <<EOF
$changes
EOF
    if [ $archived -eq 1 ] && cli validate --specs --strict --no-interactive >"$scratch/out" 2>&1; then
        quote < "$scratch/out"
        echo "archived-specs: success"
    else
        [ $archived -eq 0 ] || quote < "$scratch/out"
        echo "archived-specs: failure"
        status=1
    fi
fi

if [ $status -eq 0 ]; then
    echo "spec-checks: success"
else
    echo "spec-checks: failure"
fi
exit $status
