#!/usr/bin/env bash
# The ci plugin's one script: shared CI from TimZander/ci-recipes.
#
#   ci.sh pin                              the ci-recipes commit this plugin pins by default
#   ci.sh init --project NAME --wrangler VERSION [--directory DIR] [--sha SHA]
#                                          write .github/workflows/preview.yml and
#                                          preview-teardown.yml from ci-recipes' templates
#   ci.sh update [--sha SHA]               move every ci-recipes pin in .github/workflows/ to
#                                          SHA (default: ci-recipes' main)
#   ci.sh minutes [--repo OWNER/NAME] PR...
#                                          a pull request's billed Actions minutes
#
# Runs in the current directory, which must be a repository's root. Exit codes: 0 done,
# 2 usage error, 3 refused (nothing changed), 1 anything else.
# CI_RECIPES_URL overrides the source repository (tests only).
#
# bash 3.2 (macOS) is the floor: no associative arrays, no ${var,,}, no mapfile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${CI_RECIPES_URL:-https://github.com/TimZander/ci-recipes}"
WORKFLOWS=".github/workflows"
PIN_PATTERN='TimZander/ci-recipes/actions/[A-Za-z0-9_./-]*@[0-9a-f]\{40\}'

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}
die() { echo "ci.sh: $*" >&2; exit 1; }
refuse() { echo "ci.sh: $*" >&2; exit 3; }

default_pin() {
    local sha
    sha="$(tr -d '[:space:]' < "$SCRIPT_DIR/ci-recipes.pin")"
    is_sha "$sha" || die "ci-recipes.pin does not hold a commit SHA"
    printf '%s' "$sha"
}
is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

# fetch_at SHA DIR: ci-recipes at exactly that commit, shallow, into DIR.
fetch_at() {
    git init -q "$2"
    git -C "$2" fetch -q --depth 1 "$URL" "$1" 2>/dev/null \
        || die "could not fetch ci-recipes at $1 from $URL"
    git -C "$2" checkout -q FETCH_HEAD
}

main_sha() {
    local sha
    sha="$(git ls-remote "$URL" refs/heads/main | cut -f1)"
    is_sha "$sha" || die "could not read ci-recipes' main from $URL"
    printf '%s' "$sha"
}

cmd_init() {
    local project="" wrangler="" directory="dist" sha=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --project) project="${2-}"; shift 2 || usage ;;
            --wrangler) wrangler="${2-}"; shift 2 || usage ;;
            --directory) directory="${2-}"; shift 2 || usage ;;
            --sha) sha="${2-}"; shift 2 || usage ;;
            *) usage ;;
        esac
    done
    # Strict shapes: each value is substituted into YAML, so nothing that could break it.
    printf '%s' "$project" | grep -Eq '^[a-z0-9][a-z0-9-]{0,57}$' \
        || { echo "ci.sh: --project must be a Pages project name (lowercase, digits, hyphens)" >&2; exit 2; }
    printf '%s' "$wrangler" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || { echo "ci.sh: --wrangler must be an exact version such as 4.142.0, never a range" >&2; exit 2; }
    printf '%s' "$directory" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_./-]*$' \
        || { echo "ci.sh: --directory must be a plain relative path" >&2; exit 2; }
    case "$directory" in *..*) echo "ci.sh: --directory must not contain .." >&2; exit 2 ;; esac
    [ -n "$sha" ] || sha="$(default_pin)"
    is_sha "$sha" || { echo "ci.sh: --sha must be a full 40-character commit SHA" >&2; exit 2; }

    git rev-parse --show-toplevel >/dev/null 2>&1 || refuse "not inside a git repository"
    [ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || refuse "run from the repository's root"

    local existing=""
    for f in preview.yml preview-teardown.yml; do
        [ -e "$WORKFLOWS/$f" ] && existing="$existing $WORKFLOWS/$f"
    done
    [ -z "$existing" ] || refuse "already exists, nothing written:$existing (edit them, or move them aside first)"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    fetch_at "$sha" "$tmp/src"
    mkdir -p "$WORKFLOWS"
    for f in preview.yml preview-teardown.yml; do
        [ -f "$tmp/src/templates/$f" ] || die "ci-recipes at $sha has no templates/$f"
        sed -e "s|__PROJECT__|$project|g" -e "s|__SHA__|$sha|g" -e "s|__WRANGLER__|$wrangler|g" \
            -e "s|directory: dist\$|directory: $directory|" \
            "$tmp/src/templates/$f" > "$WORKFLOWS/$f"
        if grep -q '__[A-Z]*__' "$WORKFLOWS/$f"; then
            die "$WORKFLOWS/$f still has a placeholder: $(grep -o '__[A-Z]*__' "$WORKFLOWS/$f" | head -1)"
        fi
        echo "wrote $WORKFLOWS/$f"
    done
    echo "pinned ci-recipes $sha"
    echo "next: replace the template's build steps in $WORKFLOWS/preview.yml with this repository's build"
}

cmd_update() {
    local sha=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --sha) sha="${2-}"; shift 2 || usage ;;
            *) usage ;;
        esac
    done
    [ -n "$sha" ] || sha="$(main_sha)"
    is_sha "$sha" || { echo "ci.sh: --sha must be a full 40-character commit SHA" >&2; exit 2; }
    [ -d "$WORKFLOWS" ] || refuse "no $WORKFLOWS directory here"

    local files
    files="$(grep -l "$PIN_PATTERN" "$WORKFLOWS"/*.yml "$WORKFLOWS"/*.yaml 2>/dev/null || true)"
    [ -n "$files" ] || refuse "no TimZander/ci-recipes pin in $WORKFLOWS (run /ci:init first)"

    # The new commit must exist and still carry every action the repository uses.
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    fetch_at "$sha" "$tmp/src"
    local action
    for action in $(grep -ho "$PIN_PATTERN" $files | sed 's|^TimZander/ci-recipes/||; s|@.*||' | sort -u); do
        [ -f "$tmp/src/$action/action.yml" ] || refuse "ci-recipes at $sha has no $action; nothing changed"
    done

    local f old changed=0
    for f in $files; do
        old="$(grep -o "$PIN_PATTERN" "$f" | sed 's/.*@//' | sort -u | tr '\n' ' ')"
        if [ "$old" = "$sha " ]; then
            echo "$f: already at $sha"
            continue
        fi
        sed "s|\(TimZander/ci-recipes/actions/[A-Za-z0-9_./-]*@\)[0-9a-f]\{40\}|\1$sha|g" "$f" > "$tmp/new"
        cat "$tmp/new" > "$f"
        echo "$f: ${old% } -> $sha"
        changed=1
    done
    if [ "$changed" = 1 ]; then
        echo "what changed: https://github.com/TimZander/ci-recipes/commits/$sha"
    fi
}

cmd_minutes() {
    command -v python3 >/dev/null || die "python3 is needed"
    local tmp code=0
    tmp="$(mktemp -d)"
    fetch_at "$(default_pin)" "$tmp/src"
    # -I: isolated, so nothing in the current directory is imported in place of the stdlib.
    python3 -I "$tmp/src/scripts/ci_minutes.py" "$@" || code=$?
    rm -rf "$tmp"
    return "$code"
}

case "${1-}" in
    pin) [ $# -eq 1 ] || usage; default_pin; echo ;;
    init) shift; cmd_init "$@" ;;
    update) shift; cmd_update "$@" ;;
    minutes) shift; [ $# -gt 0 ] || usage; cmd_minutes "$@" ;;
    *) usage ;;
esac
