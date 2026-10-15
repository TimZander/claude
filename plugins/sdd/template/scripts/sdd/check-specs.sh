#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# Do the specs validate now, do they still validate once every active change
# is archived, and does every active change hold complete base pins?
#
#   bash check-specs.sh [-C <dir>] [--rev <rev> | --worktree] [--no-archive]
#
# `openspec validate --strict` checks a change's deltas, not the main specs they
# produce, so a change can validate and still archive into a spec that does not
# (a MODIFIED requirement, for example, is checked against the length and
# Purpose rules only once it is in the main spec). This script runs all three
# checks in a temporary checkout of <rev> (default HEAD).
#
# --worktree    checks the working tree instead, uncommitted and untracked
#               files included (ignored ones aren't), without touching the
#               index or any branch. For local use; CI checks a commit.
# --no-archive  runs only `spec-validate`, for checks where an active change
#               that no longer archives mustn't fail, such as a deploy from the
#               default branch. A PR's checks never use it.
#
# <rev> is read as data. The OpenSpec CLI always comes from <dir>'s own
# node_modules, never from the checkout of <rev>, and a <rev> that tracks
# node_modules/ fails outright. CI relies on this to check a PR without
# running its code.
#
# Prints `spec-validate: <state>`, `archived-specs: <state>` and
# `base-pins: <state>`, then as its last line `spec-checks: success|failure`.
# Pins are checked only when they are on (package.json "sdd": { "pins": ... },
# default true); hashes are compared when the change is archived, not here.
# The CLI's own output is quoted (each line starts with `  | `), so text from
# <rev> never starts a line.
#
# Exit status: 0 success, 1 failure, 2 usage error, 3 internal error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENSPEC="$SCRIPT_DIR/openspec.sh"

usage() {
    echo "usage: check-specs.sh [-C <dir>] [--rev <rev> | --worktree] [--no-archive]" >&2
    exit 2
}

dir="."
rev=""
worktree=0
archive=1
while [ $# -gt 0 ]; do
    case "$1" in
        -C) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
        --rev) [ $# -ge 2 ] || usage; rev="$2"; shift 2 ;;
        --worktree) worktree=1; shift ;;
        --no-archive) archive=0; shift ;;
        *) usage ;;
    esac
done
[ $worktree -eq 0 ] || [ -z "$rev" ] || usage

internal() {
    echo "check-specs: $*" >&2
    echo "- reason: $*"
    echo "spec-checks: failure"
    exit 3
}

# Quotes command output: every line indented, workflow-command syntax broken.
quote() {
    sed -e 's/##\[/#\\u0023[/g' -e 's/::/:\\u003a/g' -e "s/$(printf '\t')/ /g" -e 's/^/  | /'
}

root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || internal "$dir is not a git repository"
if [ $worktree -eq 1 ]; then
    # The working tree as a commit object: a throwaway index seeded from the real
    # one, so the real index, HEAD and branches are never touched.
    rev="the working tree"
    index="$(mktemp)"
    real_index="$(git -C "$root" rev-parse --git-path index)"
    case "$real_index" in /*) ;; *) real_index="$root/$real_index" ;; esac
    if [ -f "$real_index" ]; then cp "$real_index" "$index"; else rm -f "$index"; fi
    tree="$(cd "$root" && GIT_INDEX_FILE="$index" git add -A . >/dev/null 2>&1 && GIT_INDEX_FILE="$index" git write-tree)" \
        || { rm -f "$index"; internal "cannot read the working tree"; }
    rm -f "$index"
    parent=""
    head="$(git -C "$root" rev-parse --verify --quiet HEAD)" && parent="-p $head"
    # shellcheck disable=SC2086
    commit="$(GIT_AUTHOR_NAME=sdd GIT_AUTHOR_EMAIL=sdd@localhost GIT_COMMITTER_NAME=sdd \
        GIT_COMMITTER_EMAIL=sdd@localhost git -C "$root" commit-tree $parent -m "sdd: working tree" "$tree")" \
        || internal "cannot read the working tree"
else
    [ -n "$rev" ] || rev="HEAD"
    commit="$(git -C "$root" rev-parse --verify --quiet "$rev^{commit}")" || internal "$rev is not a commit"
fi
[ -f "$root/node_modules/@fission-ai/openspec/bin/openspec.js" ] \
    || internal "OpenSpec is not installed: run \`npm install\` first"

if [ -n "$(git -C "$root" ls-tree --name-only "$commit" node_modules)" ]; then
    echo "- $rev tracks node_modules/: refusing to check it"
    echo "spec-validate: failure"
    echo "archived-specs: failure"
    echo "base-pins: failure"
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

if [ $archive -eq 0 ]; then
    echo "archived-specs: skipped"
    echo "base-pins: skipped"
    [ $status -eq 0 ] && echo "spec-checks: success" || echo "spec-checks: failure"
    exit $status
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

# Pins, read from the commit with this checkout's parsers. The verdict line comes
# from sdd-specs.mjs; its other lines start with `- `.
if node "$SCRIPT_DIR/sdd-specs.mjs" check -C "$root" --cli-root "$root" --rev "$commit" >"$scratch/out" 2>&1; then
    grep -E '^(- |base-pins: )' "$scratch/out" || true
else
    grep -E '^(- |base-pins: )' "$scratch/out" || echo "base-pins: failure"
    sed -n 's/^sdd-specs: /- /p' "$scratch/out"
    status=1
fi

if [ $status -eq 0 ]; then
    echo "spec-checks: success"
else
    echo "spec-checks: failure"
fi
exit $status
