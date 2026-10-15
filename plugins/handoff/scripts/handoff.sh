#!/usr/bin/env bash
#
# Bookkeeping for /handoff and /pickup: resume notes in docs/handoffs/ and their index,
# docs/handoffs/README.md. The commands decide what to write; this script does the
# file and git work, so it behaves the same on every run.
#
#   bash handoff.sh state  [-C <dir>]
#       Facts for a note's "Current state", one `key: value` line each: branch, upstream,
#       ahead/behind, uncommitted files, stashes, other worktrees, and `cloud: yes|no`
#       (a cloud session, whose container is thrown away after a period of inactivity).
#
#   bash handoff.sh new    [-C <dir>]
#       Creates the index from the template if it is missing, and prints the path for a new
#       note: docs/handoffs/<today>.md, or <today>-2.md, -3.md, ... if that one exists.
#
#   bash handoff.sh add    [-C <dir>] <note> <next-action>
#       Adds the note's row to the top of the index as `open`, or updates its row if it has
#       one. The next action is cut to one line of at most 120 characters.
#
#   bash handoff.sh set    [-C <dir>] <note> <open|resumed|superseded>
#       Sets a row's status.
#
#   bash handoff.sh open   [-C <dir>]
#       Lists the open notes, newest first: `<note>\t<next action>` per line. Without an
#       index, lists every dated note in docs/handoffs/, newest name first, with the next
#       action `(no index)`. Prints nothing when there is nothing to resume.
#
#   bash handoff.sh remote [-C <dir>]
#       Open notes on other branches: fetches origin, reads each remote branch's index, and
#       prints `<branch>\t<note>\t<next action>` per open note. For a handoff committed in
#       another session, which lives on its work branch.
#
#   bash handoff.sh commit [-C <dir>] <note>
#       Commits only the note and the index, and pushes the current branch, so the note
#       outlives the machine. Refuses on main or master, never forces, and leaves every
#       other change uncommitted.
#
# Exit status: 0 done, 1 failure (reported on stderr), 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/index.md"
DIR_REL="docs/handoffs"
INDEX_REL="$DIR_REL/README.md"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

die() {
    echo "handoff: $*" >&2
    exit 1
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
dir="."
if [ "${1:-}" = "-C" ]; then
    [ $# -ge 2 ] || usage
    dir="$2"
    shift 2
fi
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || die "$dir is not inside a git repository"
cd "$root"

ensure_index() {
    if [ ! -f "$INDEX_REL" ]; then
        mkdir -p "$DIR_REL"
        cp "$TEMPLATE" "$INDEX_REL"
    fi
    grep -q '^| ---- | ---- | ------ | ----------- |$' "$INDEX_REL" \
        || die "$INDEX_REL has no handoff table; restore it from the plugin's templates/index.md"
}

# A note path as the index records it: relative to the repo root, under docs/handoffs/.
note_rel() {
    local n="${1#./}"
    case "$n" in
        "$DIR_REL"/*.md) ;;
        *) die "a note must be a .md file in $DIR_REL/: $1" ;;
    esac
    [ "$n" != "$INDEX_REL" ] || die "the index is not a note"
    case "$n" in *'|'*|*' '*|*..*|*$'\t'*) die "a note path can't contain spaces, tabs, | or ..: $1" ;; esac
    printf '%s' "$n"
}

cmd_state() {
    local branch upstream counts
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached at $(git rev-parse --short HEAD 2>/dev/null || echo none))")"
    echo "branch: $branch"
    if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
        counts="$(git rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || echo "? ?")"
        echo "upstream: $upstream"
        echo "behind: ${counts%%[[:space:]]*}"
        echo "ahead: ${counts##*[[:space:]]}"
    else
        echo "upstream: none (this branch exists only here)"
    fi
    echo "uncommitted: $(git status --porcelain | wc -l | tr -d ' ')"
    git status --porcelain | head -n 20 | sed 's/^/  /'
    echo "stashes: $(git stash list | wc -l | tr -d ' ')"
    echo "other worktrees: $(( $(git worktree list | wc -l | tr -d ' ') - 1 ))"
    git worktree list | sed 1d | sed 's/^/  /'
    if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then echo "cloud: yes"; else echo "cloud: no"; fi
}

cmd_new() {
    [ $# -eq 0 ] || usage
    ensure_index
    local today path n=1
    today="$(date +%Y-%m-%d)"
    path="$DIR_REL/$today.md"
    while [ -e "$path" ] || grep -qF "| $path |" "$INDEX_REL"; do
        n=$((n + 1))
        path="$DIR_REL/$today-$n.md"
    done
    echo "$path"
}

cmd_add() {
    [ $# -eq 2 ] || usage
    ensure_index
    local note next date
    note="$(note_rel "$1")"
    [ -f "$note" ] || die "no such note: $note (write it first)"
    # One line, no table breaks, at most 120 characters.
    next="$(printf '%s' "$2" | tr '\r\n\t' '   ' | sed -e 's/|/\//g' -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c 1-120)"
    [ -n "$next" ] || die "the next action is empty"
    date="$(basename "$note" .md | cut -c 1-10)"
    printf '%s' "$date" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || date="$(date +%Y-%m-%d)"
    local row="| $date | $note | open | $next |"
    local tmp
    tmp="$(mktemp)"
    # ENVIRON, not -v: awk would read backslashes in the text as escapes.
    NOTE="$note" ROW="$row" awk '
        BEGIN { sep = "| ---- | ---- | ------ | ----------- |"; note = ENVIRON["NOTE"]; row = ENVIRON["ROW"] }
        $0 == sep { print; print row; next }
        index($0, "| " note " |") > 0 { next }
        { print }
    ' "$INDEX_REL" > "$tmp"
    mv "$tmp" "$INDEX_REL"
    echo "added $note to $INDEX_REL as open"
}

cmd_set() {
    [ $# -eq 2 ] || usage
    case "$2" in open|resumed|superseded) ;; *) usage ;; esac
    [ -f "$INDEX_REL" ] || die "no $INDEX_REL"
    local note tmp
    note="$(note_rel "$1")"
    grep -qF "| $note |" "$INDEX_REL" || die "$note has no row in $INDEX_REL"
    tmp="$(mktemp)"
    # Replace the status cell, the one right after the note's cell.
    NOTE="$note" STATUS="$2" awk '
        BEGIN { p = "| " ENVIRON["NOTE"] " | " }
        {
            i = index($0, p)
            if (i > 0) {
                rest = substr($0, i + length(p))
                j = index(rest, " |")
                $0 = substr($0, 1, i + length(p) - 1) ENVIRON["STATUS"] substr(rest, j)
            }
            print
        }
    ' "$INDEX_REL" > "$tmp"
    mv "$tmp" "$INDEX_REL"
    echo "marked $note $2"
}

cmd_open() {
    [ $# -eq 0 ] || usage
    if [ -f "$INDEX_REL" ]; then
        open_rows < "$INDEX_REL"
        return 0
    fi
    [ -d "$DIR_REL" ] || return 0
    # Newest first: by date, then by the -N suffix (none counts as 1).
    ls -1 "$DIR_REL" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?\.md$' \
        | awk -v d="$DIR_REL" '{ n = substr($0, 11); sub(/\.md$/, "", n); n = (n == "" ? 1 : substr(n, 2) + 0);
                                 printf "%s %06d\t%s/%s\t(no index)\n", substr($0, 1, 10), n, d, $0 }' \
        | sort -r | cut -f 2-
}

# Open rows of an index read from stdin: `<note>\t<next action>`.
open_rows() {
    awk -F ' \\| ' '
        /^\| [0-9]{4}-[0-9]{2}-[0-9]{2} \| / && $3 == "open" { sub(/ \|$/, "", $4); print $2 "\t" $4 }
    '
}

cmd_remote() {
    [ $# -eq 0 ] || usage
    git fetch -q origin 2>/dev/null || die "cannot fetch origin"
    local b line
    git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v '^origin/HEAD$' | grep -vx origin \
        | while IFS= read -r b; do
            git cat-file -e "$b:$INDEX_REL" 2>/dev/null || continue
            git show "$b:$INDEX_REL" | open_rows | while IFS= read -r line; do
                printf '%s\t%s\n' "${b#origin/}" "$line"
            done
        done
}

cmd_commit() {
    [ $# -eq 1 ] || usage
    local note branch
    note="$(note_rel "$1")"
    [ -f "$note" ] || die "no such note: $note"
    branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch: check one out before committing a handoff"
    case "$branch" in
        main|master) die "won't commit a handoff on $branch; switch to the work branch" ;;
    esac
    git add -- "$note" "$INDEX_REL"
    git commit -q -m "handoff: $(basename "$note" .md)" -- "$note" "$INDEX_REL" || die "nothing to commit"
    echo "committed $note and $INDEX_REL on $branch"
    if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        git push -q || die "push failed; the handoff is committed but only on this machine"
    else
        git push -q -u origin "$branch" || die "push failed; the handoff is committed but only on this machine"
    fi
    echo "pushed $branch"
}

case "$cmd" in
    state) [ $# -eq 0 ] || usage; cmd_state ;;
    new) cmd_new "$@" ;;
    add) cmd_add "$@" ;;
    set) cmd_set "$@" ;;
    open) cmd_open "$@" ;;
    remote) cmd_remote "$@" ;;
    commit) cmd_commit "$@" ;;
    -h|--help|help) usage ;;
    *) usage ;;
esac
