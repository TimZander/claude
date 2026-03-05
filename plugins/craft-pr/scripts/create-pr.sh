#!/usr/bin/env bash
set -euo pipefail

# create-pr.sh — Push the current branch and create a pull request on GitHub
# or Azure DevOps. Called by the craft-pr plugin command after crafting the
# title and description.
#
# Usage:
#   bash create-pr.sh --title "PR title" --body-file /tmp/body.md [--draft] [--skip-dirty-check]
#
# Exit codes:
#   0 — PR created successfully
#   1 — Error (pre-flight failure, push failure, PR creation failure)
#   2 — Uncommitted changes detected (re-run with --skip-dirty-check to proceed)

# ── Arguments ────────────────────────────────────────────────────────

TITLE=""
BODY_FILE=""
DRAFT=false
SKIP_DIRTY_CHECK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)            TITLE="$2"; shift 2 ;;
        --body-file)        BODY_FILE="$2"; shift 2 ;;
        --draft)            DRAFT=true; shift ;;
        --skip-dirty-check) SKIP_DIRTY_CHECK=true; shift ;;
        *)                  echo "Error: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$TITLE" ]]; then
    echo "Error: --title is required." >&2
    exit 1
fi

if [[ -z "$BODY_FILE" ]]; then
    echo "Error: --body-file is required." >&2
    exit 1
fi

if [[ ! -f "$BODY_FILE" ]]; then
    echo "Error: Body file not found: $BODY_FILE" >&2
    exit 1
fi

# ── Cleanup ──────────────────────────────────────────────────────────
# Always clean up the body temp file on exit, EXCEPT when exiting with
# code 2 (dirty worktree) — the caller may re-invoke with --skip-dirty-check.

KEEP_BODY=false
cleanup() {
    if [[ "$KEEP_BODY" == false ]]; then
        rm -f "$BODY_FILE"
    fi
}
trap cleanup EXIT

# ── Detect platform ──────────────────────────────────────────────────

REMOTE_URL=$(git remote get-url origin 2>/dev/null) || {
    echo "Error: No 'origin' remote found." >&2
    exit 1
}

PLATFORM=""
if [[ "$REMOTE_URL" == *"github.com"* ]]; then
    PLATFORM="github"
elif [[ "$REMOTE_URL" == *"dev.azure.com"* ]] || [[ "$REMOTE_URL" == *"visualstudio.com"* ]]; then
    PLATFORM="azdo"
else
    echo "Error: Could not determine hosting platform from remote URL: $REMOTE_URL" >&2
    echo "PR creation is supported for GitHub and Azure DevOps." >&2
    exit 1
fi

BRANCH=$(git branch --show-current)
if [[ -z "$BRANCH" ]]; then
    echo "Error: Detached HEAD state. Check out a branch before creating a PR." >&2
    exit 1
fi

# ── Branch safety ────────────────────────────────────────────────────

if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    echo "Error: Refusing to push to '$BRANCH'. Create a feature branch first." >&2
    exit 1
fi

# ── Pre-flight checks ───────────────────────────────────────────────

if [[ "$PLATFORM" == "github" ]]; then
    command -v gh >/dev/null 2>&1 || {
        echo "Error: GitHub CLI (gh) is required to create PRs on GitHub. Install from https://cli.github.com" >&2
        exit 1
    }
    gh auth status >/dev/null 2>&1 || {
        echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login'." >&2
        exit 1
    }

    EXISTING_PR=$(gh pr list --head "$BRANCH" --base main --state open --json url --jq '.[0].url' 2>/dev/null || true)
    if [[ -n "$EXISTING_PR" ]]; then
        echo "Error: A PR already exists for this branch: $EXISTING_PR" >&2
        echo "Use 'gh pr edit' to update it." >&2
        exit 1
    fi

elif [[ "$PLATFORM" == "azdo" ]]; then
    command -v az >/dev/null 2>&1 || {
        echo "Error: Azure CLI (az) is required to create PRs on Azure DevOps. Install from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli" >&2
        exit 1
    }
    az extension show --name azure-devops -o none 2>/dev/null || {
        echo "Error: azure-devops extension missing. Run 'az extension add --name azure-devops'." >&2
        exit 1
    }
    az account show >/dev/null 2>&1 || {
        echo "Error: Not logged in to Azure CLI. Run 'az login'." >&2
        exit 1
    }

    EXISTING_PR=$(az repos pr list --detect --source-branch "$BRANCH" --target-branch main --status active --query '[0].pullRequestId' -o tsv 2>/dev/null || true)
    if [[ -n "$EXISTING_PR" ]]; then
        echo "Error: A PR already exists for this branch (ID: $EXISTING_PR)." >&2
        echo "Use 'az repos pr update --id $EXISTING_PR' to update it." >&2
        exit 1
    fi
fi

# ── Dirty worktree check ────────────────────────────────────────────

if [[ "$SKIP_DIRTY_CHECK" == false ]] && [[ -n "$(git status --porcelain)" ]]; then
    KEEP_BODY=true
    echo "Warning: Uncommitted changes detected. These will not be included in the PR." >&2
    echo "Body file preserved at: $BODY_FILE" >&2
    exit 2
fi

# ── Push ─────────────────────────────────────────────────────────────

echo "Pushing $BRANCH to origin..."
git push -u origin HEAD || {
    echo "Error: Push failed." >&2
    exit 1
}

# ── Create PR ────────────────────────────────────────────────────────

if [[ "$PLATFORM" == "github" ]]; then
    GH_ARGS=(gh pr create --base main --title "$TITLE" --body-file "$BODY_FILE")
    if [[ "$DRAFT" == true ]]; then
        GH_ARGS+=(--draft)
    fi
    "${GH_ARGS[@]}"

elif [[ "$PLATFORM" == "azdo" ]]; then
    AZ_ARGS=(az repos pr create --detect --target-branch main --title "$TITLE")
    if [[ "$DRAFT" == true ]]; then
        AZ_ARGS+=(--draft true)
    fi

    # Try @file syntax first; fall back to create-then-update if it fails
    # (e.g. description exceeds length limit).
    AZ_ERR=$(mktemp)
    if ! "${AZ_ARGS[@]}" --description @"$BODY_FILE" 2>"$AZ_ERR"; then
        echo "Retrying with description update strategy..." >&2
        PR_ID=$("${AZ_ARGS[@]}" --description "See PR body" --query pullRequestId -o tsv) || {
            echo "Error: PR creation failed. Original error:" >&2
            cat "$AZ_ERR" >&2
            rm -f "$AZ_ERR"
            exit 1
        }
        if ! az repos pr update --id "$PR_ID" --detect --description @"$BODY_FILE"; then
            echo "Warning: PR created (ID: $PR_ID) but description could not be set." >&2
            echo "Update manually: az repos pr update --id $PR_ID" >&2
            cat "$AZ_ERR" >&2
            rm -f "$AZ_ERR"
            exit 1
        fi
        rm -f "$AZ_ERR"
        echo "PR created: $(az repos pr show --id "$PR_ID" --detect --query url -o tsv 2>/dev/null || echo "ID $PR_ID")"
    else
        rm -f "$AZ_ERR"
    fi
fi
