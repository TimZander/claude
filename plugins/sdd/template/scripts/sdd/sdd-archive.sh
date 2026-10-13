#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# Archive helpers for the OpenSpec change lifecycle: an archive PR holds only
# the output of `openspec archive`, and merges without review once it is shown
# to be mechanical.
#
#   bash sdd-archive.sh active  [-C <dir>]
#       Active change names (folders in openspec/changes/ other than archive/),
#       one per line, in ascending byte order: the order they are archived in.
#
#   bash sdd-archive.sh run     [-C <dir>]
#       Archives every active change in that order. Stops at the first failure.
#
#   bash sdd-archive.sh verify  [-C <dir>] --base <rev> --result <rev>
#       Is <result> a mechanical archive of <base>? True when every folder it
#       adds under openspec/changes/archive/ archives a change active on <base>,
#       re-running `openspec archive` for those changes on <base> reproduces
#       <result>'s openspec/ tree exactly, and nothing outside openspec/ changed.
#       Last line: `archive-mechanical: success|failure|not-an-archive-pr`,
#       preceded by `- compared base <sha> with result <sha>`.
#
#   bash sdd-archive.sh verdict <log-file>
#       Reads a CI log and prints `verdict=<state>` and `base=<sha>` from its
#       last `archive-mechanical:` and `compared base` lines. Accepts the
#       `openspec/archive-mechanical:` spelling too.
#
# Exit status: 0 success (or not-an-archive-pr, or no active change), 1 failure,
# 2 usage error, 3 internal error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENSPEC="$SCRIPT_DIR/openspec.sh"
ARCHIVE="openspec/changes/archive"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

internal() {
    echo "sdd-archive: $*" >&2
    exit 3
}

# Folders directly under $2 at revision $1, one per line.
folders_at() {
    git ls-tree -d --name-only "$1" "$2/" 2>/dev/null | sed "s#^$2/##" | LC_ALL=C sort
}

active_in() {
    local root="$1" d
    [ -d "$root/openspec/changes" ] || return 0
    for d in "$root"/openspec/changes/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        d="${d##*/}"
        [ "$d" = "archive" ] && continue
        printf '%s\n' "$d"
    done | LC_ALL=C sort
}

cmd_active() {
    local root
    root="$(git -C "$DIR" rev-parse --show-toplevel)" || internal "$DIR is not a git repository"
    active_in "$root"
}

cmd_run() {
    local root names name
    root="$(git -C "$DIR" rev-parse --show-toplevel)" || internal "$DIR is not a git repository"
    names="$(active_in "$root")"
    if [ -z "$names" ]; then
        echo "no active change"
        return 0
    fi
    while IFS= read -r name; do
        echo "archiving $name"
        if ! bash "$OPENSPEC" -C "$root" archive "$name" --yes; then
            echo "sdd-archive: \`openspec archive $name\` failed; later changes were not archived" >&2
            exit 1
        fi
    done <<EOF
$names
EOF
}

cmd_verify() {
    local base="" result=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
            --result) [ $# -ge 2 ] || usage; result="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$base" ] && [ -n "$result" ] || usage

    local root
    root="$(git -C "$DIR" rev-parse --show-toplevel)" || internal "$DIR is not a git repository"
    cd "$root"
    base="$(git rev-parse --verify --quiet "$base^{commit}")" || internal "base is not a commit"
    result="$(git rev-parse --verify --quiet "$result^{commit}")" || internal "result is not a commit"

    local added
    added="$(LC_ALL=C comm -13 <(folders_at "$base" "$ARCHIVE") <(folders_at "$result" "$ARCHIVE"))"
    if [ -z "$added" ]; then
        echo "- compared base $base with result $result"
        echo "archive-mechanical: not-an-archive-pr"
        return 0
    fi

    local problems="" active folder change names="" seen=""
    active="$(folders_at "$base" openspec/changes | grep -vx archive || true)"
    while IFS= read -r folder; do
        # A dated folder, YYYY-MM-DD-<change>. OpenSpec keeps a change name that
        # already starts with a date as the whole folder name, so try that first.
        if printf '%s\n' "$active" | grep -qxF -- "$folder"; then
            change="$folder"
        elif printf '%s' "$folder" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-.+'; then
            change="${folder:11}"
        else
            problems="$problems- $folder is not a dated archive folder"$'\n'
            continue
        fi
        if ! printf '%s\n' "$active" | grep -qxF -- "$change"; then
            problems="$problems- $folder archives $change, which is not an active change on the base"$'\n'
        elif printf '%s' "$seen" | grep -qxF -- "$change"; then
            problems="$problems- $change is archived more than once"$'\n'
        else
            seen="$seen$change"$'\n'
            names="$names$change $folder"$'\n'
        fi
    done <<EOF
$added
EOF

    local outside
    outside="$(git diff --no-renames --name-only "$base" "$result" | grep -v '^openspec/' || true)"
    if [ -n "$outside" ]; then
        problems="$problems$(printf '%s\n' "$outside" | sed 's/^/- changed outside openspec\/: /')"$'\n'
    fi

    if [ -z "$problems" ]; then
        if [ ! -f "$root/node_modules/@fission-ai/openspec/bin/openspec.js" ]; then
            internal "OpenSpec is not installed: run \`npm ci --ignore-scripts\` first"
        fi
        problems="$(reproduce "$root" "$base" "$result" "$names")" || true
    fi

    echo "${problems%$'\n'}" | sed '/^$/d'
    echo "- compared base $base with result $result"
    if [ -n "$problems" ]; then
        echo "archive-mechanical: failure"
        exit 1
    fi
    echo "archive-mechanical: success"
}

# Re-runs the archives on a checkout of $2 and compares its openspec/ tree with
# $3's. Prints a problem line for each difference; prints nothing on a match.
reproduce() {
    local root="$1" base="$2" result="$3" names="$4"
    local scratch checkout status=0
    scratch="$(mktemp -d)"
    checkout="$scratch/base"
    # shellcheck disable=SC2064
    trap "git -C '$root' worktree remove --force '$checkout' >/dev/null 2>&1 || true; rm -rf '$scratch'" RETURN
    git -C "$root" worktree add -q --detach "$checkout" "$base" >/dev/null 2>&1 \
        || { echo "- cannot check out the base"; return 1; }
    ln -s "$root/node_modules" "$checkout/node_modules"

    local change folder made
    while IFS=' ' read -r change folder; do
        [ -n "$change" ] || continue
        if ! out="$(bash "$OPENSPEC" -C "$checkout" archive "$change" --yes 2>&1)"; then
            echo "- \`openspec archive $change\` fails on the base: $(printf '%s\n' "$out" | sed '/^$/d' | tail -n 1)"
            return 1
        fi
        # The archive folder carries today's date; give it the result's name.
        made="$(cd "$checkout/$ARCHIVE" && ls -d -- *-"$change" "$change" 2>/dev/null | head -n 1)"
        if [ -n "$made" ] && [ "$made" != "$folder" ]; then
            mv "$checkout/$ARCHIVE/$made" "$checkout/$ARCHIVE/$folder"
        fi
    done <<EOF
$(printf '%s' "$names" | LC_ALL=C sort)
EOF

    rm "$checkout/node_modules"
    local want got
    git -C "$checkout" add -A openspec
    got="$(git -C "$checkout" write-tree --prefix=openspec/)"
    want="$(git -C "$root" rev-parse "$result:openspec")"
    if [ "$got" != "$want" ]; then
        echo "- re-running the archives on the base does not reproduce the result's openspec/:"
        git -C "$root" diff --stat "$got" "$want" | sed 's/^/  | /'
        status=1
    fi
    return $status
}

cmd_verdict() {
    [ $# -eq 1 ] || usage
    [ -f "$1" ] || internal "no such log file: $1"
    local verdict base
    verdict="$(grep -Eo '(openspec/)?archive-mechanical: [a-z-]+' "$1" | tail -n 1 | sed 's/.*: //' || true)"
    base="$(grep -Eo 'compared base [0-9a-f]{7,40}' "$1" | tail -n 1 | sed 's/compared base //' || true)"
    if [ -z "$verdict" ]; then
        echo "verdict=none"
        exit 1
    fi
    echo "verdict=$verdict"
    echo "base=${base:-unknown}"
}

[ $# -ge 1 ] || usage
sub="$1"
shift
DIR="."
if [ "${1:-}" = "-C" ]; then
    [ $# -ge 2 ] || usage
    DIR="$2"
    shift 2
fi

case "$sub" in
    active) [ $# -eq 0 ] || usage; cmd_active ;;
    run) [ $# -eq 0 ] || usage; cmd_run ;;
    verify) cmd_verify "$@" ;;
    verdict) cmd_verdict "$@" ;;
    -h|--help|help) usage ;;
    *) usage ;;
esac
