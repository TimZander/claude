#!/usr/bin/env bash
#
# Opts a repository out of spec-driven development, for good: adds one line to its CLAUDE.md,
# which every session reads, so an sdd environment works there normally and never asks
# about setting it up.
#
#   bash sdd-optout.sh [--repo <dir>]
#
# Creates CLAUDE.md if there is none. Idempotent: a CLAUDE.md that already says so is left as
# is. Refuses a repository already set up for sdd (.claude/sdd-workflow.md exists): opting out
# doesn't remove sdd, so the two would contradict each other. Commits nothing; the command
# that runs it commits CLAUDE.md.
#
# Last line: `sdd-optout: done`, `sdd-optout: already opted out`, or `sdd-optout: failed`.
# Exit status: 0 done or already opted out, 1 failed, 2 usage error.

set -euo pipefail

LINE="This repository doesn't use spec-driven development (sdd)."

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

[ ! -e .claude/sdd-workflow.md ] || die "this repository is set up for sdd (.claude/sdd-workflow.md); opting out doesn't remove it, so remove sdd first or keep it"

if [ -f CLAUDE.md ] && grep -qF "doesn't use spec-driven development" CLAUDE.md; then
    echo "CLAUDE.md already says the repository doesn't use spec-driven development"
    echo "sdd-optout: already opted out"
    exit 0
fi

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
