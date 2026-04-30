#!/usr/bin/env bash
# Run Git Hygiene Before New Work and create the working branch (in a worktree by default).
#
# Usage:
#   start-work.sh --slug <kebab-case-slug> [--id <issue-or-work-item-id>] [--base <branch>] [--no-worktree]
#
# Default behavior creates a worktree at .claude/worktrees/<id>-<slug>/ on a new branch
# named branches/<id>-<slug>. With --no-worktree the branch is created in the current
# checkout via `git checkout -b`. If --id is omitted (e.g., when no tracked issue/work
# item exists), the branch is named branches/<slug>.
#
# On success, the last lines of stdout are:
#   BRANCH=<branch>
#   WORKTREE_PATH=<path>     (only in worktree mode)
#
# Refuses to run if the working tree is dirty, the target branch already exists
# locally, or the target worktree path already exists.

set -euo pipefail

ID=""
SLUG=""
BASE="main"
USE_WORKTREE=1

usage() {
    cat >&2 <<USAGE
usage: $0 --slug <kebab-case-slug> [--id <issue-or-work-item-id>] [--base <branch>] [--no-worktree]

Creates branches/<id>-<slug> (or branches/<slug> if --id is omitted) from clean
origin/<base>. Worktree at .claude/worktrees/<id>-<slug>/ by default; --no-worktree
creates the branch in the current checkout instead.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --id) ID="${2:-}"; shift 2;;
        --slug) SLUG="${2:-}"; shift 2;;
        --base) BASE="${2:-}"; shift 2;;
        --no-worktree) USE_WORKTREE=0; shift;;
        -h|--help) usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage; exit 2;;
    esac
done

if [ -z "$SLUG" ]; then
    echo "error: --slug is required" >&2
    usage
    exit 2
fi

# Validate slug: kebab-case only — lowercase letters, digits, internal hyphens.
if ! printf '%s' "$SLUG" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    echo "error: --slug '$SLUG' is not kebab-case (expected lowercase letters/digits, hyphens between words, no leading or trailing hyphens)" >&2
    exit 2
fi

# Construct branch name and worktree dir name per the team's Branch Naming standard.
if [ -n "$ID" ]; then
    # Validate id is alphanumeric + hyphen so it can't inject path components.
    if ! printf '%s' "$ID" | grep -Eq '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$'; then
        echo "error: --id '$ID' must be alphanumeric (with optional internal hyphens)" >&2
        exit 2
    fi
    BRANCH="branches/$ID-$SLUG"
    WT_DIR_NAME="$ID-$SLUG"
else
    BRANCH="branches/$SLUG"
    WT_DIR_NAME="$SLUG"
fi

# Verify we are inside a git repo.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: not inside a git repository" >&2
    exit 1
fi

# Operate from the repo root so worktree paths resolve correctly.
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Verify clean working tree — Git Hygiene Before New Work refuses to start on dirty state.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree is dirty. Commit, stash, or discard changes before starting new work." >&2
    git status --short >&2
    exit 1
fi

# Refuse to clobber an existing local branch (precise check against refs/heads/).
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "error: branch '$BRANCH' already exists locally. Pick a different slug or delete the existing branch." >&2
    exit 1
fi

# Fetch the base branch from origin. Capture stderr separately so a network failure
# is reported clearly instead of merged into stdout (same pattern resolve_app_insights.sh uses).
FETCH_ERR_FILE="$(mktemp)"
trap 'rm -f "$FETCH_ERR_FILE"' EXIT

if ! git fetch origin "$BASE" 2>"$FETCH_ERR_FILE"; then
    echo "error: 'git fetch origin $BASE' failed:" >&2
    cat "$FETCH_ERR_FILE" >&2
    exit 1
fi

if ! git rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
    echo "error: origin/$BASE does not exist after fetch. Verify --base is correct." >&2
    exit 1
fi

# Refuse if the target branch already exists on origin (a teammate may have pushed
# a same-named branch). Creating a divergent local copy here would silently set up
# a force-push trap. The user can rename the slug or coordinate with the original
# author before retrying.
git fetch origin "$BRANCH" 2>/dev/null || true
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    echo "error: branch '$BRANCH' already exists on origin (someone else may have pushed it). Pick a different slug or coordinate with the original author." >&2
    exit 1
fi

if [ "$USE_WORKTREE" -eq 1 ]; then
    WT_PATH=".claude/worktrees/$WT_DIR_NAME"
    if [ -e "$WT_PATH" ]; then
        echo "error: worktree path '$WT_PATH' already exists. Remove it (git worktree remove --force '$WT_PATH') or pick a different slug." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$WT_PATH")"
    git worktree add -b "$BRANCH" "$WT_PATH" "origin/$BASE" >&2
    echo "BRANCH=$BRANCH"
    echo "WORKTREE_PATH=$WT_PATH"
else
    # In-place: branch directly off origin/<base> so we don't depend on local <base> being current.
    git checkout -b "$BRANCH" "origin/$BASE" >&2
    echo "BRANCH=$BRANCH"
fi
