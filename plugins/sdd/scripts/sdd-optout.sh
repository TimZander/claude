#!/usr/bin/env bash
#
# Opts a repository out of spec-driven development, for good: adds one line to its CLAUDE.md,
# which every session reads, so an sdd environment works there normally and never asks
# about setting it up.
#
#   bash sdd-optout.sh [--repo <dir>]
#
# The line is the one in optout-line.txt, next to this script, matched exactly (ignoring
# trailing whitespace, a CR, and anything inside a fenced code block); /sdd:init removes the
# same line. A symlinked CLAUDE.md is followed to its target inside the repository. Creates CLAUDE.md if there is
# none. Idempotent: a CLAUDE.md that already has the line is left as is. Refuses a repository
# already set up for sdd (.claude/sdd-workflow.md exists, or CLAUDE.md imports it), since the
# two would contradict each other, and a CLAUDE.md with uncommitted changes, which the commit of the opt-out would sweep
# up. Commits nothing; the command that runs it commits CLAUDE.md.
#
# Before the last line, on success: `root: <repo root>` and `file: <the file it edited>`, the
# path to commit. Last line: `sdd-optout: done`, `sdd-optout: already opted out`, or `sdd-optout: failed`.
# Exit status: 0 done or already opted out, 1 failed, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINE="$(tr -d '\r' < "$SCRIPT_DIR/optout-line.txt")"

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

# The file to edit: CLAUDE.md, or the file it links to (AGENTS.md, say). A link is resolved to
# a physical path first, then has to land on a committed regular file inside the repository,
# so no spelling of the target (`.//etc/x`, `sub/../../x`, a symlinked parent) gets outside it.
file="CLAUDE.md"
if [ -L CLAUDE.md ]; then
    target="$(readlink CLAUDE.md)"
    here="$(pwd -P)"
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || die "CLAUDE.md links to $target, which doesn't exist"
    base="$(basename "$target")"
    case "$base" in .|..) die "CLAUDE.md links to $target, which is not a file" ;; esac
    case "$dir/" in "$here"/*) file="${dir#"$here"}/$base"; file="${file#/}" ;; *) die "CLAUDE.md links outside the repository: $target" ;; esac
    [ -f "$file" ] && [ ! -L "$file" ] || die "CLAUDE.md links to $file, which is not a regular file"
    git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 || die "CLAUDE.md links to $file, which is not committed"
fi

# Whether $file has the line $1 outside fenced code blocks, ignoring a trailing CR and trailing
# whitespace. A fence closes only on the same character, at least as long, with nothing after
# it, as in Markdown. All in awk, which reads the whole file: a `grep -q` that stops early
# would make the pipeline fail under pipefail on a large file.
has_plain() {
    awk -v want="$1" '
        { t = $0; sub(/\r$/, "", t); sub(/[ \t]+$/, "", t) }
        t ~ /^[ \t]*(```|~~~)/ {
            s = t; sub(/^[ \t]*/, "", s); c = substr(s, 1, 1); n = 0
            while (substr(s, n + 1, 1) == c) n++
            if (!fence) { fence = 1; fc = c; fl = n; next }
            if (c == fc && n >= fl && substr(s, n + 1) ~ /^[ \t]*$/) { fence = 0; next }
        }
        !fence && t == want { found = 1 }
        END { exit !found }' "$file"
}

if [ -f "$file" ] && has_plain "$LINE"; then
    echo "$file already has the opt-out line"
    echo "root: $root"
    echo "file: $file"
    echo "sdd-optout: already opted out"
    exit 0
fi
if [ -f "$file" ] && has_plain '@.claude/sdd-workflow.md'; then
    die "$file imports .claude/sdd-workflow.md, so the repository is set up for sdd"
fi

[ -z "$(git status --porcelain -- "$file")" ] \
    || die "$file has uncommitted changes; commit or stash them first, so the opt-out commit holds only its line"

if [ -s "$file" ]; then
    # Keep the file's last line intact, then leave a blank line before ours.
    [ -z "$(tail -c 1 "$file")" ] || echo >> "$file"
    printf '\n%s\n' "$LINE" >> "$file"
    echo "added the opt-out line to $file"
elif [ "$file" = CLAUDE.md ]; then
    printf '# CLAUDE.md\n\n%s\n' "$LINE" > "$file"
    echo "created $file with the opt-out line"
else
    printf '%s\n' "$LINE" > "$file"
    echo "added the opt-out line to the empty $file"
fi
echo "root: $root"
echo "file: $file"
echo "sdd-optout: done"
