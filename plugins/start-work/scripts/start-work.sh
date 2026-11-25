#!/usr/bin/env bash
# Run Git Hygiene Before New Work and create the working branch (in a worktree by default).
#
# Usage:
#   start-work.sh --slug <kebab-case-slug> [--id <number>] [--base <branch>] [--no-worktree]
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
# Exit codes: 2 for an argument problem (a missing or invalid value, an unknown
# argument, a --base that is not a plain branch name); any other non-zero code when
# it refuses or fails later (dirty working tree, branch already exists locally or on
# origin, worktree path already exists, fetch failure, or a git error).

set -euo pipefail

ID=""
SLUG=""
BASE="main"
USE_WORKTREE=1

usage() {
    cat >&2 <<USAGE
usage: $0 --slug <kebab-case-slug> [--id <number>] [--base <branch>] [--no-worktree]

Creates branches/<id>-<slug> (or branches/<slug> if --id is omitted) from clean
origin/<base>. Worktree at .claude/worktrees/<id>-<slug>/ by default; --no-worktree
creates the branch in the current checkout instead.
USAGE
}

# Print a user-supplied value safely inside an error message: shell-quoted, so
# control characters and quotes in it cannot garble the terminal.
quoted() { printf '%q' "$1"; }

# An option needs a value that is present, non-empty and not itself an option, so
# `--base --no-worktree` reports the missing value instead of swallowing the flag.
require_value() {
    if [ "$2" -lt 2 ] || [ -z "$3" ] || [ "${3#-}" != "$3" ]; then
        echo "error: $1 needs a value" >&2
        usage
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --id) require_value "$1" "$#" "${2:-}"; ID="$2"; shift 2;;
        --slug) require_value "$1" "$#" "${2:-}"; SLUG="$2"; shift 2;;
        --base) require_value "$1" "$#" "${2:-}"; BASE="$2"; shift 2;;
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
# Matched with [[ =~ ]] on the whole value: grep would test each line separately,
# so a value with a newline in it could pass.
SLUG_PATTERN='^[a-z0-9]+(-[a-z0-9]+)*$'
if ! [[ $SLUG =~ $SLUG_PATTERN ]]; then
    echo "error: --slug $(quoted "$SLUG") is not kebab-case (expected lowercase letters/digits, hyphens between words, no leading or trailing hyphens)" >&2
    exit 2
fi

# Validate --base before any git command sees it: it must be a plain branch name. A value
# starting with "-" would be read as a git option, and one starting with "+" as a forced
# refspec. `check-ref-format` on the full ref rejects "..", "@{", ":", spaces, control
# characters and the other forms git refuses; the --branch form is avoided because it
# expands "@{-1}" to the previously checked-out branch. (An empty value never reaches
# here: require_value rejects it.)
case "$BASE" in
    -* | +*) base_ok=0 ;;
    *) if git check-ref-format "refs/heads/$BASE"; then base_ok=1; else base_ok=0; fi ;;
esac
if [ "$base_ok" -ne 1 ]; then
    echo "error: --base $(quoted "$BASE") is not a valid branch name (no spaces, '..', '@{', ':', '~', '^', '\\', and it must not start with '-' or '+')" >&2
    exit 2
fi

# Construct branch name and worktree dir name per the team's Branch Naming standard.
if [ -n "$ID" ]; then
    # Issue and work-item numbers are positive integers with no leading zero, at most
    # 10 digits (both GitHub and Azure DevOps IDs fit). Matched on the whole value, as
    # for the slug, so path components, options and newlines never reach a branch or
    # worktree name.
    ID_PATTERN='^[1-9][0-9]{0,9}$'
    if ! [[ $ID =~ $ID_PATTERN ]]; then
        echo "error: --id $(quoted "$ID") must be a number (digits only, no leading zero, at most 10 digits)" >&2
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

# Resolve the root to operate from. The two modes want different roots:
#
#   Worktree mode: the new worktree must be created under the MAIN repo's
#   .claude/worktrees/, even when this script is invoked from inside an existing
#   worktree. `git rev-parse --show-toplevel` returns the *current* worktree's root, so
#   using it here would nest the new worktree inside the current one (#155).
#   `--git-common-dir` points at the main repo's shared .git directory (always the main
#   checkout's, regardless of which worktree we're in), and its parent is the main root.
#
#   In-place mode (--no-worktree): `git checkout -b` switches the *current* checkout onto
#   the new branch, so we must operate from the worktree the user is actually in —
#   `--show-toplevel`. Using the main root here would silently switch the main checkout's
#   branch instead of the current worktree's.
if [ "$USE_WORKTREE" -eq 1 ]; then
    REPO_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
else
    REPO_ROOT="$(git rev-parse --show-toplevel)"
fi
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

# Fetch with an explicit refspec, and use the full remote-tracking ref below, so git never
# guesses: a bare name could also match a tag or HEAD on origin, and `origin/<base>` could
# resolve to a local branch or tag that happens to have that name.
BASE_REF="refs/remotes/origin/$BASE"
if ! git fetch origin "refs/heads/$BASE:$BASE_REF" 2>"$FETCH_ERR_FILE"; then
    echo "error: fetching branch '$BASE' from origin failed:" >&2
    cat "$FETCH_ERR_FILE" >&2
    exit 1
fi

if ! git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
    echo "error: origin/$BASE does not exist after fetch. Verify --base is correct." >&2
    exit 1
fi

# Refuse if the target branch already exists on origin (a teammate may have pushed
# a same-named branch). Creating a divergent local copy here would silently set up
# a force-push trap. The user can rename the slug or coordinate with the original
# author before retrying.
git fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || true
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
    git worktree add -b "$BRANCH" "$WT_PATH" "$BASE_REF" >&2
    echo "BRANCH=$BRANCH"
    echo "WORKTREE_PATH=$WT_PATH"
else
    # In-place: branch directly off origin/<base> so we don't depend on local <base> being current.
    git checkout -b "$BRANCH" "$BASE_REF" >&2
    echo "BRANCH=$BRANCH"
fi
