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
#       Fails when a name isn't [A-Za-z0-9][A-Za-z0-9._-]*, so no folder name
#       can reach the CLI as an option, or breaks the repository's stricter
#       rule ("sdd": { "changeNames": "lowercase" } in package.json).
#
#   bash sdd-archive.sh run     [-C <dir>]
#       Archives every active change in that order. Stops at the first failure.
#
#   bash sdd-archive.sh verify  [-C <dir>] --base <rev> --result <rev>
#       Is <result> a mechanical archive of <base>? True when every folder it
#       adds under openspec/changes/archive/ archives a change active on <base>,
#       re-running `openspec archive` for those changes on <base> reproduces
#       <result>'s openspec/ tree exactly, and nothing outside openspec/ changed.
#       Right before each archive, in that order, the change's base pins must
#       match the main specs as they are at that moment (unless pins are off in
#       package.json), and its tasks.md must have no unfinished task.
#       Last line, on every exit path: `archive-mechanical: success|failure|
#       not-an-archive-pr`, preceded by `- compared base <sha> with result <sha>`
#       when a comparison ran. Every other line starts with `- ` or `  | `, so
#       text from the PR (paths, folder names, CLI output) never starts a line.
#       The OpenSpec CLI always comes from this checkout's node_modules.
#
#   bash sdd-archive.sh verdict [--line <name>] <log-file>
#       Reads a CI log and prints `verdict=<state>` and `base=<sha>`. Counts only
#       whole lines (after GitHub's timestamp prefix, or `gh run view --log`'s
#       job, step and timestamp), takes the last, and accepts `success` only
#       when the line right before it is the `- compared base` line. Accepts
#       the `openspec/archive-mechanical:` spelling too.
#       With --line, reads another check's verdict instead: the last whole line
#       `<name>: success|failure|error`, with `base=unknown`. For the extra
#       verdicts a repository names in package.json ("archiveVerdicts").
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

VERIFYING=0
VERDICT_PRINTED=0
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
LOWER_RE='^[a-z0-9][a-z0-9-]*$'
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-'
NAME_RULE=""

# The repository's change-name rule, from this checkout's package.json (never the PR's).
load_name_rule() {
    [ -n "$NAME_RULE" ] && return 0
    NAME_RULE="$(node "$SCRIPT_DIR/sdd-config.mjs" changeNames)" || internal "invalid sdd settings in package.json"
}

# Is $1 a valid change name? [[ =~ ]] matches the whole string, so a name with a line
# break in it never passes. Call load_name_rule first.
name_ok() {
    [[ "$1" =~ $NAME_RE ]] || return 1
    if [ "$NAME_RULE" = lowercase ]; then
        [[ "$1" =~ $LOWER_RE ]] || return 1
        if [[ "$1" =~ $DATE_RE ]]; then return 1; fi
    fi
    return 0
}

internal() {
    echo "sdd-archive: $*" >&2
    [ $VERIFYING -eq 0 ] || echo "- reason: $*" | neutralise
    exit 3
}

verdict_line() {
    VERDICT_PRINTED=1
    echo "archive-mechanical: $1"
}

# verify always ends with a verdict line, whatever stops it.
on_exit() {
    local code=$?
    if [ $VERIFYING -eq 1 ] && [ $VERDICT_PRINTED -eq 0 ]; then
        echo "archive-mechanical: failure"
        [ $code -ne 0 ] || code=3
    fi
    exit $code
}
trap on_exit EXIT

# Breaks GitHub's `##[` and `::` workflow-command syntax in text from the repo.
neutralise() {
    sed -e 's/##\[/#\\u0023[/g' -e 's/::/:\\u003a/g'
}

# Folders directly under $2 at revision $1, one per line.
folders_at() {
    git ls-tree -d --name-only "$1" "$2/" 2>/dev/null | sed "s#^$2/##" | LC_ALL=C sort
}

active_in() {
    local root="$1" d names="" bad=0
    [ -d "$root/openspec/changes" ] || return 0
    for d in "$root"/openspec/changes/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        d="${d##*/}"
        [ "$d" = "archive" ] && continue
        if name_ok "$d"; then
            names="$names$d"$'\n'
        else
            echo "sdd-archive: not a valid change name: $(printf '%q' "$d")" >&2
            bad=1
        fi
    done
    printf '%s' "$names" | LC_ALL=C sort
    return $bad
}

cmd_active() {
    local root
    root="$(git -C "$DIR" rev-parse --show-toplevel)" || internal "$DIR is not a git repository"
    load_name_rule
    active_in "$root" || exit 1
}

cmd_run() {
    local root names name
    root="$(git -C "$DIR" rev-parse --show-toplevel)" || internal "$DIR is not a git repository"
    load_name_rule
    names="$(active_in "$root")" || exit 1
    if [ -z "$names" ]; then
        echo "no active change"
        return 0
    fi
    while IFS= read -r name; do
        echo "archiving $name"
        if ! bash "$OPENSPEC" -C "$root" --cli-root "$root" archive "$name" --yes; then
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
    VERIFYING=1

    local root
    root="$(git -C "$DIR" rev-parse --show-toplevel)" || internal "$DIR is not a git repository"
    cd "$root"
    base="$(git rev-parse --verify --quiet "$base^{commit}")" || internal "base is not a commit"
    result="$(git rev-parse --verify --quiet "$result^{commit}")" || internal "result is not a commit"

    local added
    added="$(LC_ALL=C comm -13 <(folders_at "$base" "$ARCHIVE") <(folders_at "$result" "$ARCHIVE"))"
    if [ -z "$added" ]; then
        echo "- compared base $base with result $result"
        verdict_line not-an-archive-pr
        return 0
    fi

    local problems="" active="" folder change names="" seen=""
    load_name_rule
    while IFS= read -r folder; do
        if [ -n "$folder" ] && [ "$folder" != archive ] && name_ok "$folder"; then
            active="$active$folder"$'\n'
        fi
    done <<EOF
$(folders_at "$base" openspec/changes)
EOF
    while IFS= read -r folder; do
        # A dated folder, YYYY-MM-DD-<change>. OpenSpec keeps a change name that
        # already starts with a date as the whole folder name, so try that first.
        if printf '%s' "$active" | grep -qxF -- "$folder"; then
            change="$folder"
        elif [[ "$folder" =~ $DATE_RE ]] && name_ok "${folder:11}"; then
            change="${folder:11}"
        else
            problems="$problems- $folder is not a dated archive folder of a valid change name"$'\n'
            continue
        fi
        if ! printf '%s' "$active" | grep -qxF -- "$change"; then
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

    echo "${problems%$'\n'}" | sed '/^$/d' | neutralise
    echo "- compared base $base with result $result"
    if [ -n "$problems" ]; then
        verdict_line failure
        exit 1
    fi
    verdict_line success
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

    local change folder made before out
    while IFS=' ' read -r change folder; do
        [ -n "$change" ] || continue
        # Pins and tasks, against the main specs as the archives before it left them.
        if ! out="$(node "$SCRIPT_DIR/sdd-specs.mjs" gate --cli-root "$root" --dir "$checkout" --change "$change" 2>&1)"; then
            printf '%s\n' "$out" | sed '/^$/d' | sed 's/^sdd-specs: /- /'
            status=1
        fi
        before="$(ls -1 "$checkout/$ARCHIVE" 2>/dev/null | LC_ALL=C sort)"
        if ! out="$(bash "$OPENSPEC" -C "$checkout" --cli-root "$root" archive "$change" --yes 2>&1)"; then
            echo "- \`openspec archive $change\` fails on the base:"
            printf '%s\n' "$out" | sed '/^$/d' | tail -n 5 | sed 's/^/  | /'
            return 1
        fi
        # The archive folder carries today's date; give it the result's name.
        # The new folder is the one that wasn't there before this archive.
        made="$(LC_ALL=C comm -13 <(printf '%s\n' "$before" | sed '/^$/d') \
            <(ls -1 "$checkout/$ARCHIVE" | LC_ALL=C sort))"
        if [ "$(printf '%s\n' "$made" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]; then
            echo "- \`openspec archive $change\` did not add exactly one archive folder"
            return 1
        fi
        if [ "$made" != "$folder" ]; then
            mv "$checkout/$ARCHIVE/$made" "$checkout/$ARCHIVE/$folder"
        fi
    done <<EOF
$(printf '%s' "$names" | LC_ALL=C sort)
EOF

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
    local line=""
    if [ "${1:-}" = "--line" ]; then
        [ $# -ge 2 ] || usage
        line="$2"
        shift 2
        [[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || usage
    fi
    [ $# -eq 1 ] || usage
    [ -f "$1" ] || internal "no such log file: $1"
    if [ -n "$line" ]; then
        # Another check's verdict: the last whole line `<name>: <state>`, nothing more.
        awk -v name="$line" '
            BEGIN { ts = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z " }
            {
                sub(/\r$/, "")
                if ($0 ~ /^[^\t]+\t[^\t]*\t/) { sub(/^[^\t]+\t[^\t]*\t/, "") }
                if ($0 ~ ts) { sub(ts, "") }
                n = length(name) + 2
                if (substr($0, 1, n) == name ": ") {
                    v = substr($0, n + 1)
                    if (v == "success" || v == "failure" || v == "error") { verdict = v }
                }
            }
            END {
                if (verdict == "") { print "verdict=none"; exit 1 }
                print "verdict=" verdict
                print "base=unknown"
            }
        ' "$1"
        return
    fi
    # Strip a log line to the text the step printed: drop `gh run view --log`'s
    # `<job>\t<step>\t` and GitHub's `<timestamp> ` prefix, nothing else. A line
    # with any other prefix (such as the `  | ` on quoted output) never matches.
    awk '
        BEGIN { ts = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z " }
        {
            sub(/\r$/, "")
            if ($0 ~ /^checks\t[^\t]*\t/) { sub(/^checks\t[^\t]*\t/, "") }
            if ($0 ~ ts) { sub(ts, "") }
            if ($0 ~ /^(openspec\/)?archive-mechanical: (success|failure|not-an-archive-pr)$/) {
                v = $0; sub(/^.*: /, "", v)
                b = ""
                if (prev ~ /^- compared base [0-9a-f]+ with result [0-9a-f]+$/) {
                    b = prev; sub(/^- compared base /, "", b); sub(/ .*$/, "", b)
                }
                verdict = v; base = b
            }
            prev = $0
        }
        END {
            if (verdict == "") { print "verdict=none"; exit 1 }
            if (verdict == "success" && base == "") { print "verdict=none"; exit 1 }
            print "verdict=" verdict
            print "base=" (base == "" ? "unknown" : base)
        }
    ' "$1"
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
