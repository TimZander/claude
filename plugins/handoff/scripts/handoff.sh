#!/usr/bin/env bash
#
# Bookkeeping for /handoff and /pickup: resume notes in docs/handoffs/, local to the
# machine unless a note has to outlive it, and deleted once picked up, so they never reach
# the base branch. The commands decide what to write; this script does the file and git
# work, so it behaves the same on every run.
#
#   bash handoff.sh state  [-C <dir>]
#       Facts for a note's "Current state", one `key: value` line each: branch, upstream,
#       ahead/behind, uncommitted files, stashes, other worktrees, and `cloud: yes|no`
#       (a cloud session, whose container is thrown away after a period of inactivity).
#
#   bash handoff.sh new    [-C <dir>]
#       Keeps notes local: adds docs/handoffs/ to the repository's .git/info/exclude, an
#       ignore list that is never committed. Prints the path for a new note:
#       docs/handoffs/<today>.md, or <today>-2.md, -3.md, ... if that one exists.
#
#   bash handoff.sh open   [-C <dir>]
#       Lists the notes waiting to be picked up, newest first: `<note>\t<next action>` per
#       line, the next action being the first line under the note's "## Next action".
#       A note is open as long as its file exists. Prints nothing when there is none.
#
#   bash handoff.sh remote [-C <dir>]
#       Notes on other branches: fetches origin and prints `<branch>\t<note>\t<next action>`
#       per note committed on a remote branch. For a handoff committed in another session,
#       which lives on its work branch.
#
#   bash handoff.sh commit [-C <dir>] <note>
#       Commits only the note, and pushes the current branch, so the note outlives the
#       machine. Refuses on main or master, never forces, and leaves every other change
#       uncommitted. `drop` takes the note back out once it is picked up.
#
#   bash handoff.sh relay  [-C <dir>] <note>
#       Preflight for /handoff:relay, which moves the work to a new cloud session and archives
#       this one. Refuses (exit 1, each reason on stderr) unless this is a cloud session, on a
#       work branch that tracks origin/<the same name>, with the note committed, nothing
#       uncommitted, and nothing unpushed or unpulled after a fresh fetch: a new session starts
#       from a fresh clone of origin/<branch>, and archiving this one throws away its
#       container. Then prints `key: value` lines for create_session: source_url, branch, head,
#       shallow, prompt, and `left behind: <count>` with what the clone won't have, one
#       indented `kind: item` line each (untracked, ignored, stash, branch with commits on no
#       remote, worktree with its uncommitted and unpushed counts), the first 20 shown.
#
#   bash handoff.sh drop   [-C <dir>] <note>
#       Deletes a note that has been picked up or replaced. If it was committed, also commits
#       the deletion (that path alone), so the note doesn't reach the base branch with the
#       work, and pushes it when the note was on the upstream, so `remote` can't find it
#       again. On main or master it stages the deletion for the next work branch's first
#       commit instead.
#
# Exit status: 0 done, 1 failure (reported on stderr), 2 usage error.

set -euo pipefail

DIR_REL="docs/handoffs"
NOTE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?\.md$'

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

# Keep docs/handoffs/ out of `git status` and out of commits, without touching any committed
# file: .git/info/exclude is local to this clone.
ensure_excluded() {
    local exclude
    exclude="$(git rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude")"
    grep -qxF "/$DIR_REL/" "$exclude" 2>/dev/null || echo "/$DIR_REL/" >> "$exclude"
}

# Note file names read from stdin, newest first: by date, then by the -N suffix (none counts
# as 1).
newest_first() {
    { grep -E "$NOTE_RE" || true; } \
        | awk '{ n = substr($0, 11); sub(/\.md$/, "", n); n = (n == "" ? 1 : substr(n, 2) + 0);
                 printf "%s %06d\t%s\n", substr($0, 1, 10), n, $0 }' \
        | sort -r | cut -f 2-
}

# The first line under a note's "## Next action", read from stdin, cut to 120 characters.
next_action() {
    local line
    line="$(awk '/^## / { if (f) exit; f = ($0 ~ /^## Next action/); next } f && NF { print; exit }' \
        | tr '\t\r' '  ' | cut -c 1-120)"
    printf '%s' "${line:-(no next action)}"
}

# A note path relative to the repo root, under docs/handoffs/.
note_rel() {
    local n="${1#./}"
    case "$n" in
        "$DIR_REL"/*.md) ;;
        *) die "a note must be a .md file in $DIR_REL/: $1" ;;
    esac
    case "$n" in *'|'*|*' '*|*..*|*$'\t'*) die "a note path can't contain spaces, tabs, | or ..: $1" ;; esac
    printf '%s' "$n"
}

# True in a cloud session, whose container is thrown away after a period of inactivity.
in_cloud() {
    [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]
}

# The upstream of a ref (`origin/work`); fails when it has none.
upstream_of() {
    git rev-parse --abbrev-ref --symbolic-full-name "$1@{upstream}" 2>/dev/null
}

# `<behind> <ahead>` of HEAD against an upstream, or `? ?` when git can't tell.
ahead_behind() {
    git rev-list --left-right --count "$1...HEAD" 2>/dev/null | tr -s '\t ' '  ' || echo "? ?"
}

# Copies stdin with a prefix on each line, up to 20 lines, then says how many more there were.
capped() {
    awk -v p="$1" 'NR <= 20 { print p $0 } END { if (NR > 20) printf "%s... and %d more\n", p, NR - 20 }'
}

cmd_state() {
    local branch upstream counts status
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached at $(git rev-parse --short HEAD 2>/dev/null || echo none))")"
    echo "branch: $branch"
    if upstream="$(upstream_of HEAD)"; then
        counts="$(ahead_behind "$upstream")"
        echo "upstream: $upstream"
        echo "behind: ${counts%% *}"
        echo "ahead: ${counts##* }"
    else
        echo "upstream: none (this branch exists only here)"
    fi
    status="$(git status --porcelain)"
    echo "uncommitted: $(printf '%s' "$status" | grep -c . || true)"
    [ -z "$status" ] || printf '%s\n' "$status" | capped "  "
    echo "stashes: $(git stash list | wc -l | tr -d ' ')"
    echo "other worktrees: $(( $(git worktree list | wc -l | tr -d ' ') - 1 ))"
    git worktree list | sed 1d | sed 's/^/  /'
    if in_cloud; then echo "cloud: yes"; else echo "cloud: no"; fi
}

cmd_new() {
    [ $# -eq 0 ] || usage
    ensure_excluded
    mkdir -p "$DIR_REL"
    local today path n=1
    today="$(date +%Y-%m-%d)"
    path="$DIR_REL/$today.md"
    while [ -e "$path" ]; do
        n=$((n + 1))
        path="$DIR_REL/$today-$n.md"
    done
    echo "$path"
}

cmd_open() {
    [ $# -eq 0 ] || usage
    [ -d "$DIR_REL" ] || return 0
    local f
    ls -1 "$DIR_REL" | newest_first | while IFS= read -r f; do
        printf '%s/%s\t%s\n' "$DIR_REL" "$f" "$(next_action < "$DIR_REL/$f")"
    done
}

cmd_remote() {
    [ $# -eq 0 ] || usage
    git fetch -q origin 2>/dev/null || die "cannot fetch origin"
    local b f
    git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v '^origin/HEAD$' | grep -vx origin \
        | while IFS= read -r b; do
            git ls-tree --name-only "$b" "$DIR_REL/" 2>/dev/null | sed "s#^$DIR_REL/##" | newest_first \
                | while IFS= read -r f; do
                    printf '%s\t%s/%s\t%s\n' "${b#origin/}" "$DIR_REL" "$f" \
                        "$(git show "$b:$DIR_REL/$f" | next_action)"
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
    # -f: the note is in .git/info/exclude so that nothing else commits it by accident.
    git add -f -- "$note"
    git commit -q -m "handoff: $(basename "$note" .md)" -- "$note" || die "nothing to commit"
    echo "committed $note on $branch"
    if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        git push -q || die "push failed; the handoff is committed but only on this machine"
    else
        git push -q -u origin "$branch" || die "push failed; the handoff is committed but only on this machine"
    fi
    echo "pushed $branch"
}

# origin as a URL a new cloud session can clone: credentials stripped, an SSH remote or the
# cloud git proxy (http://...@127.0.0.1:<port>/git/<owner>/<repo>) turned into https.
clone_url() {
    printf '%s' "$1" | sed -E \
        -e 's#^git@([^:]+):#https://\1/#' \
        -e 's#^ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/#https://\2/#' \
        -e 's#^(https?://)[^@/]+@#\1#' \
        -e 's#^https?://(127\.0\.0\.1|localhost)(:[0-9]+)?/git/#https://github.com/#' \
        -e 's#\.git$##'
}

cmd_relay() {
    [ $# -eq 1 ] || usage
    local note branch="" upstream counts origin dirty bad=0 report b n wt sha
    note="$(note_rel "$1")"
    refuse() { echo "handoff: relay: $*" >&2; bad=1; }
    in_cloud || refuse "not a cloud session; outside one, use /handoff, /clear and /pickup"
    if branch="$(git symbolic-ref --quiet --short HEAD)"; then
        case "$branch" in main|master) refuse "on $branch; the new session needs a work branch to continue on" ;; esac
    else
        branch=""
        refuse "not on a branch: check out the work branch first"
    fi
    git cat-file -e "HEAD:$note" 2>/dev/null || refuse "$note is not committed: run \`handoff.sh commit $note\` first"
    # The URL as configured, before any local insteadOf rewrite, which the new session won't have.
    origin="$(git config --get remote.origin.url)" || refuse "no origin remote to clone from"
    if [ -n "$branch" ] && upstream="$(upstream_of HEAD)"; then
        # The new session clones origin/<branch>, so that's the upstream that has to hold the work.
        if [ "$upstream" != "origin/$branch" ]; then
            refuse "$branch tracks $upstream, but the new session clones origin/$branch: push to origin/$branch and track it"
        elif ! git fetch -q origin "$branch" 2>/dev/null; then
            refuse "cannot fetch origin/$branch to check it holds the work"
        else
            counts="$(ahead_behind "$upstream")"
            [ "${counts##* }" = 0 ] || refuse "${counts##* } commit(s) not pushed to $upstream"
            [ "${counts%% *}" = 0 ] || refuse "$upstream has ${counts%% *} commit(s) this checkout lacks: pull them, and update the note if they change it"
        fi
    elif [ -n "$branch" ]; then
        refuse "$branch has no upstream: push it first"
    fi
    dirty="$(git status --porcelain --untracked-files=no)"
    if [ -n "$dirty" ]; then
        refuse "uncommitted changes would be lost with this container:"
        printf '%s\n' "$dirty" | capped "  " >&2
    fi
    [ "$bad" = 0 ] || exit 1

    # What the fresh clone won't have, one `kind: item` per line.
    report="$(
        git ls-files --others --exclude-standard | sed 's/^/untracked: /'
        git ls-files --others --ignored --exclude-standard --directory | sed 's/^/ignored: /'
        git stash list | sed 's/^/stash: /'
        git for-each-ref --format='%(refname:short)' refs/heads | while IFS= read -r b; do
            [ "$b" != "$branch" ] || continue
            n="$(git rev-list --count "$b" --not --remotes)"
            [ "$n" = 0 ] || echo "branch: $b ($n commit(s) on no remote)"
        done
        git worktree list --porcelain | awk '/^worktree / { sub(/^worktree /, ""); print }' | sed 1d \
            | while IFS= read -r wt; do
                sha="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || echo "?")"
                printf 'worktree: %s at %s' "$wt" "$sha"
                n="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
                [ "$n" = 0 ] || printf ', %s uncommitted' "$n"
                n="$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
                [ "$n" = 0 ] || printf ', %s commit(s) on no remote' "$n"
                echo
            done
    )"
    echo "source_url: $(clone_url "$origin")"
    echo "branch: $branch"
    echo "head: $(git rev-parse HEAD)"
    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then echo "shallow: yes"; else echo "shallow: no"; fi
    echo "prompt: /handoff:pickup $note"
    if [ -z "$report" ]; then
        echo "left behind: 0"
    else
        echo "left behind: $(printf '%s\n' "$report" | wc -l | tr -d ' ')"
        printf '%s\n' "$report" | capped "  "
    fi
}

cmd_drop() {
    [ $# -eq 1 ] || usage
    local note branch pushed=""
    note="$(note_rel "$1")"
    if ! git ls-files --error-unmatch -- "$note" >/dev/null 2>&1; then
        [ -f "$note" ] || die "no such note: $note"
        rm -f -- "$note"
        echo "deleted $note"
        return 0
    fi
    branch="$(git symbolic-ref --quiet --short HEAD)" || branch=""
    case "$branch" in
        ""|main|master)
            git rm -q -- "$note"
            echo "deleted $note and staged the deletion; ${branch:-a detached HEAD} takes no handoff commits, so commit it as the first commit of the next work branch"
            return 0 ;;
    esac
    # Push only when the note reached the upstream: that copy is the one a later `remote` finds.
    if git cat-file -e "@{upstream}:$note" 2>/dev/null; then pushed=yes; fi
    git rm -q -- "$note"
    git commit -q -m "handoff: drop $(basename "$note" .md)" -- "$note" || die "could not commit the deletion of $note"
    echo "deleted $note and committed the deletion on $branch"
    if [ -n "$pushed" ]; then
        git push -q || die "push failed; the deletion is committed but only on this machine"
        echo "pushed $branch"
    fi
}

case "$cmd" in
    state) [ $# -eq 0 ] || usage; cmd_state ;;
    new) cmd_new "$@" ;;
    open) cmd_open "$@" ;;
    remote) cmd_remote "$@" ;;
    commit) cmd_commit "$@" ;;
    relay) cmd_relay "$@" ;;
    drop) cmd_drop "$@" ;;
    -h|--help|help) usage ;;
    *) usage ;;
esac
