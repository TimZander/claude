#!/usr/bin/env bash
#
# Opts a repository out of spec-driven development, for good: adds one line to its CLAUDE.md,
# which every session reads, so an sdd environment works there normally and never asks
# about setting it up.
#
#   bash sdd-optout.sh [--repo <dir>]
#
# The line is the one in optout-line.txt, next to this script, matched exactly (ignoring
# trailing whitespace and a CR); /sdd:init removes the same line. Creates CLAUDE.md if there is
# none. Idempotent: a CLAUDE.md that already has the line is left as is. Refuses a repository
# already set up for sdd (.claude/sdd-workflow.md exists), since the two would contradict each
# other, and a CLAUDE.md with uncommitted changes, which the commit of the opt-out would sweep
# up. Commits nothing; the command that runs it commits CLAUDE.md.
#
# Last line: `sdd-optout: done`, `sdd-optout: already opted out`, or `sdd-optout: failed`.
# Exit status: 0 done or already opted out, 1 failed, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINE="$(cat "$SCRIPT_DIR/optout-line.txt")"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

die() {
    echo "sdd-optout: $*" >&2
    echo "sdd-optout: failed"
    exit 1
}

repo="."
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || usage; repo="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "$repo is not inside a git repository"
cd "$root"

[ ! -e .claude/sdd-workflow.md ] || die "this repository is set up for sdd (.claude/sdd-workflow.md), and opting out doesn't remove it"

has_line() {
    awk -v line="$LINE" '{ t = $0; sub(/\r$/, "", t); sub(/[ \t]+$/, "", t) } t == line { f = 1 } END { exit !f }' CLAUDE.md
}

if [ -f CLAUDE.md ] && has_line; then
    echo "CLAUDE.md already has the opt-out line"
    echo "sdd-optout: already opted out"
    exit 0
fi

[ -z "$(git status --porcelain -- CLAUDE.md)" ] \
    || die "CLAUDE.md has uncommitted changes; commit or stash them first, so the opt-out commit holds only its line"

if [ -s CLAUDE.md ]; then
    # Keep the file's last line intact, then leave a blank line before ours.
    [ -z "$(tail -c 1 CLAUDE.md)" ] || echo >> CLAUDE.md
    printf '\n%s\n' "$LINE" >> CLAUDE.md
    echo "added the opt-out line to CLAUDE.md"
else
    printf '# CLAUDE.md\n\n%s\n' "$LINE" > CLAUDE.md
    echo "created CLAUDE.md with the opt-out line"
fi
echo "sdd-optout: done"
