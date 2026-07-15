#!/usr/bin/env bash
set -euo pipefail

# resolve-pr.sh — Resolve a PR reference in /deep-review's free-form arguments
# to the branch that should actually be reviewed. Called by the deep-review
# plugin command before it gathers the diff.
#
# The script REPORTS; it never checks anything out. The caller decides whether
# to switch branches (and confirms with the user first), so the destructive
# step stays visible.
#
# Usage:
#   bash resolve-pr.sh --args "<raw /deep-review arguments>"
#
# Output (KEY=value lines on stdout; parse the ones you need):
#   HOST=github|azdo|unknown   Hosting platform, detected from the origin remote
#   KIND=pr|issue|workitem|none  What the reference resolved to
#   REF_ID=<N>                 The referenced number (absent when KIND=none)
#   SOURCE_BRANCH=<name>       PR's source branch, bare (KIND=pr only)
#   TARGET_BRANCH=<name>       PR's target branch, bare (KIND=pr only)
#   STATE=open|merged|closed|abandoned   Normalized PR state (KIND=pr only)
#   CURRENT_BRANCH=<name>      Checked-out branch ("" when detached)
#   BRANCH_MATCH=true|false    SOURCE_BRANCH == CURRENT_BRANCH (KIND=pr only)
#   IN_WORKTREE=true|false     Whether the cwd is a git worktree
#
# Token precedence: PR URL > `pr <N>` > `#<N>`. Only the first match is used.
#
# `#<N>` is deliberately host-dependent. GitHub numbers issues and PRs from one
# shared counter, so `#<N>` names exactly one object and resolves cleanly. Azure
# DevOps numbers work items and PRs SEPARATELY — `#7775` may be both work item
# 7775 and PR 7775, and the number alone cannot disambiguate. A bare `#N` also
# renders as a work-item mention in the ADO UI. So on ADO, `#<N>` is a work item
# (context only) and never selects a branch; ADO users pass `pr <N>` instead.
#
# Exit codes:
#   0 — Resolved (including KIND=none: no reference present, review HEAD)
#   1 — Error (no origin remote, unsupported host, lookup failed)

# ── Arguments ────────────────────────────────────────────────────────

ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --args) ARGS="${2:-}"; shift 2 ;;
        *)      echo "Error: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Detect platform ──────────────────────────────────────────────────
# Copied from craft-pr/scripts/create-pr.sh rather than sourced: plugins are
# installed independently, so each must stand alone at runtime.

REMOTE_URL=$(git remote get-url origin 2>/dev/null) || {
    echo "Error: No 'origin' remote found." >&2
    exit 1
}

HOST=""
if [[ "$REMOTE_URL" == *"github.com"* ]]; then
    HOST="github"
elif [[ "$REMOTE_URL" == *"dev.azure.com"* ]] || [[ "$REMOTE_URL" == *"visualstudio.com"* ]]; then
    HOST="azdo"
else
    echo "Error: Could not determine hosting platform from remote URL: $REMOTE_URL" >&2
    echo "PR reference resolution is supported for GitHub and Azure DevOps." >&2
    exit 1
fi

# ── Git context ──────────────────────────────────────────────────────

# Worktrees have a .git *file*; a normal checkout has a .git directory.
IN_WORKTREE=false
if [[ -f .git ]]; then
    IN_WORKTREE=true
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)

# ── Parse the reference ──────────────────────────────────────────────
# Precedence: PR URL, then `pr <N>`, then `#<N>`.

KIND="none"
REF_ID=""

# GitHub:  https://github.com/<owner>/<repo>/pull/<N>
# ADO:     https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<N>
if [[ "$ARGS" =~ https?://[^[:space:]]*/(pull|pullrequest)/([0-9]+) ]]; then
    KIND="pr"
    REF_ID="${BASH_REMATCH[2]}"
# ADO work item URL: .../_workitems/edit/<N>
elif [[ "$ARGS" =~ https?://[^[:space:]]*/_workitems/edit/([0-9]+) ]]; then
    KIND="workitem"
    REF_ID="${BASH_REMATCH[1]}"
# GitHub issue URL: https://github.com/<owner>/<repo>/issues/<N>
elif [[ "$ARGS" =~ https?://[^[:space:]]*/issues/([0-9]+) ]]; then
    KIND="issue"
    REF_ID="${BASH_REMATCH[1]}"
# Bare `pr <N>` (case-insensitive, on a word boundary so "compr 4" won't match)
elif [[ "$ARGS" =~ (^|[[:space:]])[Pp][Rr][[:space:]]+#?([0-9]+)($|[[:space:]]) ]]; then
    KIND="pr"
    REF_ID="${BASH_REMATCH[2]}"
# Bare `#<N>` — meaning depends on the host (see header).
elif [[ "$ARGS" =~ (^|[[:space:]])#([0-9]+)($|[[:space:]]) ]]; then
    REF_ID="${BASH_REMATCH[2]}"
    if [[ "$HOST" == "azdo" ]]; then
        KIND="workitem"
    else
        # GitHub numbers issues and PRs from one shared counter, so #<N> names
        # exactly one object — but which one is only knowable by asking. Defer
        # to the resolution step, which tries the PR fetch and falls back to
        # issue when it 404s.
        #
        # Do NOT probe with `gh pr view <N> --json number`: gh echoes the number
        # straight back with exit 0 without validating it, so that probe passes
        # for issues too. Only fields that force a real fetch (state,
        # headRefName, ...) distinguish a PR from an issue.
        KIND="ambiguous"
    fi
fi

# ── Resolve a PR to its branches ─────────────────────────────────────

SOURCE_BRANCH=""
TARGET_BRANCH=""
STATE=""

# Strip an ANCHORED refs/heads/ prefix. ADO returns fully-qualified refs; gh
# returns bare names. This must not be a greedy strip: branch names here
# legitimately contain a `branches/` segment, so `refs/heads/branches/7493-foo`
# must yield `branches/7493-foo`, never `7493-foo` (a branch that does not exist).
normalize_ref() {
    printf '%s' "${1#refs/heads/}"
}

# Derive the ADO organization URL from the origin remote. Handles both
# https://dev.azure.com/<org>/... and https://<org>.visualstudio.com/..., plus
# their ssh forms (git@ssh.dev.azure.com:v3/<org>/...).
ado_org_url() {
    local url="$1"
    if [[ "$url" =~ ssh\.dev\.azure\.com[:/]v3/([^/]+) ]]; then
        printf 'https://dev.azure.com/%s' "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ dev\.azure\.com/([^/]+) ]]; then
        printf 'https://dev.azure.com/%s' "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ([A-Za-z0-9_-]+)\.visualstudio\.com ]]; then
        printf 'https://%s.visualstudio.com' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

if [[ "$KIND" == "pr" || "$KIND" == "ambiguous" ]]; then
    if [[ "$HOST" == "github" ]]; then
        # Explicit array order — do not rely on JSON key order.
        # This lookup doubles as the PR-vs-issue test for an ambiguous #<N>:
        # a failure here means the number is an issue, not a PR.
        if PR_TSV=$(gh pr view "$REF_ID" --json headRefName,baseRefName,state \
                --jq '[.headRefName, .baseRefName, .state] | @tsv' 2>&1); then
            KIND="pr"
            SOURCE_BRANCH=$(printf '%s' "$PR_TSV" | cut -f1)
            TARGET_BRANCH=$(printf '%s' "$PR_TSV" | cut -f2)
            GH_STATE=$(printf '%s' "$PR_TSV" | cut -f3)
            case "$GH_STATE" in
                OPEN)   STATE="open" ;;
                MERGED) STATE="merged" ;;
                CLOSED) STATE="closed" ;;
                *)      STATE="$GH_STATE" ;;
            esac
        elif [[ "$KIND" == "ambiguous" ]]; then
            # #<N> named an issue: context only, no branch selection.
            KIND="issue"
        else
            # An explicit `pr <N>` / PR URL that does not resolve is an error.
            echo "Error: Could not resolve GitHub PR #$REF_ID." >&2
            echo "$PR_TSV" >&2
            exit 1
        fi
    else
        ORG=$(ado_org_url "$REMOTE_URL") || {
            echo "Error: Could not derive an Azure DevOps organization URL from: $REMOTE_URL" >&2
            exit 1
        }
        # `az repos pr show --id <N>` resolves org-wide — no repository scoping
        # needed, unlike the ADO MCP tool which requires a repositoryId GUID.
        #
        # Query as an ordered ARRAY, not a {dict}: az renders a dict to tsv in
        # alphabetical key order, so a {source,target,status} hash silently
        # comes back source/status/target. An array pins the order.
        #
        # az prints an array to tsv one element per LINE (not tab-separated),
        # so read it line-wise — `cut -f1` finds no tabs and returns the whole
        # blob for every field.
        PR_OUT=$(az repos pr show --id "$REF_ID" --org "$ORG" \
            --query "[sourceRefName, targetRefName, status]" -o tsv 2>&1) || {
            echo "Error: Could not resolve Azure DevOps PR #$REF_ID in $ORG." >&2
            echo "$PR_OUT" >&2
            exit 1
        }
        {
            read -r SOURCE_BRANCH
            read -r TARGET_BRANCH
            read -r AZ_STATUS
        } <<< "$PR_OUT"
        case "$AZ_STATUS" in
            active)    STATE="open" ;;
            completed) STATE="merged" ;;
            abandoned) STATE="abandoned" ;;
            *)         STATE="$AZ_STATUS" ;;
        esac
    fi

    # Guarded: an ambiguous #<N> may have resolved to an issue above, leaving
    # the branch vars empty.
    if [[ "$KIND" == "pr" ]]; then
        SOURCE_BRANCH=$(normalize_ref "$SOURCE_BRANCH")
        TARGET_BRANCH=$(normalize_ref "$TARGET_BRANCH")
    fi
fi

# ── Report ───────────────────────────────────────────────────────────

echo "HOST=$HOST"
echo "KIND=$KIND"
# A plain `[[ ... ]] && echo` would return non-zero when REF_ID is empty and,
# under `set -e`, abort the script before it reports the git context.
if [[ -n "$REF_ID" ]]; then
    echo "REF_ID=$REF_ID"
fi
if [[ "$KIND" == "pr" ]]; then
    echo "SOURCE_BRANCH=$SOURCE_BRANCH"
    echo "TARGET_BRANCH=$TARGET_BRANCH"
    echo "STATE=$STATE"
    if [[ "$SOURCE_BRANCH" == "$CURRENT_BRANCH" ]]; then
        echo "BRANCH_MATCH=true"
    else
        echo "BRANCH_MATCH=false"
    fi
fi
echo "CURRENT_BRANCH=$CURRENT_BRANCH"
echo "IN_WORKTREE=$IN_WORKTREE"
