#!/usr/bin/env bash
set -euo pipefail

# resolve-pr.sh — Resolve a PR reference in /deep-review's free-form arguments
# to the branch that should actually be reviewed. Called by the deep-review
# plugin command before it gathers the diff.
#
# The script REPORTS; it never checks anything out. The caller decides whether
# to switch branches (and must confirm with the user first), so the destructive
# step stays visible.
#
# Usage:
#   bash resolve-pr.sh --args "<raw /deep-review arguments>"
#
# Output (KEY=value lines on stdout; parse the ones you need):
#   HOST=github|azdo|unknown    Hosting platform, detected from the origin remote.
#                               `unknown` (no origin, or a host that is neither
#                               GitHub nor Azure DevOps) is NOT an error: only
#                               PR lookup needs a known host, and a review with
#                               no PR reference must still work anywhere.
#   KIND=pr|issue|workitem|none What the reference resolved to
#   REF_ID=<N>                  The referenced number (omitted when KIND=none)
#   SOURCE_BRANCH=<name>        PR's source branch, bare (KIND=pr only)
#   TARGET_BRANCH=<name>        PR's target branch, bare (KIND=pr only)
#   STATE=<state>               Normalized PR state (KIND=pr only): open, merged,
#                               closed or abandoned. An unrecognized upstream
#                               state passes through verbatim, so treat any other
#                               value as "unknown, surface it to the user".
#   OTHER_REFS=<N>[,<N>...]     Other PR numbers mentioned in the arguments but
#                               NOT selected (KIND=pr only; omitted when there
#                               are none). See MULTIPLE REFERENCES below.
#   CURRENT_BRANCH=<name>       Checked-out branch (empty when detached)
#   BRANCH_MATCH=true|false     SOURCE_BRANCH == CURRENT_BRANCH (KIND=pr only).
#                               Never true on an empty branch name.
#   IN_WORKTREE=true|false      Whether the repo is a git worktree
#
# Errors go to stderr; stdout carries nothing but KEY=value lines.
#
# Token precedence, first match wins:
#   PR URL > `pr <N>` > work-item URL > issue URL > `#<N>`
#
# `pr <N>` outranks the context URLs deliberately: it selects the review target,
# and a dropped selector means reviewing the wrong branch, whereas a dropped
# context URL only means less context.
#
# `#<N>` is deliberately host-dependent. GitHub numbers issues and PRs from one
# shared counter, so `#<N>` names exactly one object and resolves cleanly. Azure
# DevOps numbers work items and PRs SEPARATELY — `#7775` may be both work item
# 7775 and PR 7775, and the number alone cannot disambiguate. A bare `#N` also
# renders as a work-item mention in the ADO UI. So on ADO, `#<N>` is a work item
# (context only) and never selects a branch; ADO users pass `pr <N>` instead.
#
# KNOWN AMBIGUITY: `pr <N>` is matched anywhere in the arguments, so prose such
# as "regression from PR 4" parses as a PR selector. The caller MUST confirm
# with the user before switching branches, which is what bounds the damage.
#
# MULTIPLE REFERENCES: exactly one reference is ever selected — the leftmost,
# which matches how people write ("pr 3, and check against work done in pr 4"
# means review 3). But word order is a guess, not intent: "check pr 4, then
# review pr 3" selects 4. Rather than silently discard that knowledge, every
# other PR number found is reported in OTHER_REFS so the caller can name them
# in its confirmation prompt and let the user catch a wrong pick. A mention is
# never a selector — OTHER_REFS is informational only.
#
# Exit codes:
#   0 — Resolved (including KIND=none: no reference present, review HEAD)
#   1 — Error (no origin remote, unsupported host, missing CLI, lookup failed,
#       lookup returned no branch, cross-host or cross-repo reference)

# ── Arguments ────────────────────────────────────────────────────────

ARGS=""
ARGS_SEEN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --args)
            if [[ $# -lt 2 ]]; then
                echo "Error: --args requires a value." >&2
                exit 1
            fi
            if [[ "$ARGS_SEEN" == true ]]; then
                echo "Error: --args given more than once." >&2
                exit 1
            fi
            ARGS="$2"
            ARGS_SEEN=true
            shift 2
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Scratch space for captured stderr ────────────────────────────────
# gh and az must never have their stderr folded into the value stream: both
# emit notices on success (gh upgrade banners, "az repos pr is in preview"),
# and a merged notice becomes the first line — i.e. the branch name.

ERR_FILE=""
cleanup() {
    if [[ -n "$ERR_FILE" ]]; then
        rm -f "$ERR_FILE"
    fi
}
trap cleanup EXIT INT TERM
ERR_FILE=$(mktemp)

die_with_stderr() {
    echo "Error: $1" >&2
    if [[ -s "$ERR_FILE" ]]; then
        sed 's/^/  /' "$ERR_FILE" >&2
    fi
    exit 1
}

require_cli() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: '$1' is required to resolve a pull request on this host, but it is not on PATH." >&2
        exit 1
    fi
}

# ── Detect platform ──────────────────────────────────────────────────
# Host detection derived from craft-pr/scripts/create-pr.sh, but matched on the
# URL's HOST COMPONENT rather than as a substring of the whole URL: a substring
# test misclassifies e.g. https://gitlab.com/me/github.com-mirror.git. Copied
# rather than sourced — plugins are installed independently and must stand alone.

# Extract the host component from a git remote URL, handling https://,
# ssh://, and scp-style (git@host:path) forms.
remote_host() {
    local url="$1"
    url="${url#*://}"   # strip scheme
    url="${url#*@}"     # strip userinfo
    url="${url%%[:/]*}" # keep up to the first : or /
    printf '%s' "$url"
}

# An unknown host is NOT an error here. /deep-review runs this step for ANY
# non-empty arguments, and most invocations are a plain focus area with no PR
# reference at all. Failing early would break `/deep-review focus on X` for
# every GitLab, Bitbucket, self-hosted and remote-less repo — a review that
# works today. The host only has to be known to LOOK UP a PR, so that
# requirement is enforced at the resolution step instead.
REMOTE_URL=$(git remote get-url origin 2>/dev/null || printf '')
REMOTE_HOST=""
HOST="unknown"

if [[ -n "$REMOTE_URL" ]]; then
    REMOTE_HOST=$(remote_host "$REMOTE_URL")
    case "$REMOTE_HOST" in
        github.com|*.github.com)
            HOST="github" ;;
        dev.azure.com|ssh.dev.azure.com|*.visualstudio.com)
            HOST="azdo" ;;
    esac
fi

# Called only from paths that genuinely need to reach a PR API.
require_known_host() {
    if [[ "$HOST" != "unknown" ]]; then
        return 0
    fi
    if [[ -z "$REMOTE_URL" ]]; then
        echo "Error: Cannot resolve PR #$REF_ID — no 'origin' remote found." >&2
    else
        echo "Error: Cannot resolve PR #$REF_ID — could not determine hosting platform from remote URL: $REMOTE_URL" >&2
        echo "PR reference resolution is supported for GitHub and Azure DevOps." >&2
    fi
    exit 1
}

# ── Git context ──────────────────────────────────────────────────────

# A worktree's git dir sits under the main repo's git dir, so the two differ.
# `test -f .git` would also work but only from the repo root — it silently
# reports false from any subdirectory, and true inside a submodule.
IN_WORKTREE=false
GIT_DIR_PATH=$(git rev-parse --absolute-git-dir 2>/dev/null || printf '')
GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '')
if [[ -n "$GIT_DIR_PATH" && -n "$GIT_COMMON_DIR" && "$GIT_DIR_PATH" != "$GIT_COMMON_DIR" ]]; then
    IN_WORKTREE=true
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)

# ── Parse the reference ──────────────────────────────────────────────

KIND="none"
REF_ID=""

# Boundaries are non-alphanumeric rather than whitespace, so that `(pr 170)`,
# `PR #170, focus on tests` and `pr 4506.` all match while `compr 4` and
# `pr 170x` do not. A whitespace-only boundary silently degraded a trailing
# comma into "no reference" — i.e. into a review of the wrong branch.
BOUNDARY_L='(^|[^0-9A-Za-z])'
BOUNDARY_R='($|[^0-9A-Za-z])'

# GitHub:  https://github.com/<owner>/<repo>/pull/<N>
# ADO:     https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<N>
if [[ "$ARGS" =~ (https?://[^[:space:]]+)/(pull|pullrequest)/([0-9]+) ]]; then
    KIND="pr"
    REF_ID="${BASH_REMATCH[3]}"
    PR_URL_HOST=$(remote_host "${BASH_REMATCH[1]}")
    if [[ -n "$REMOTE_HOST" && "$PR_URL_HOST" != "$REMOTE_HOST" ]]; then
        echo "Error: PR URL points at '$PR_URL_HOST' but origin is '$REMOTE_HOST'." >&2
        echo "Refusing to look up a PR number from one host against another." >&2
        exit 1
    fi
# Bare `pr <N>` — outranks the context URLs below; see the header.
elif [[ "$ARGS" =~ ${BOUNDARY_L}[Pp][Rr][[:space:]]+#?([0-9]+)${BOUNDARY_R} ]]; then
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
# Bare `#<N>` — meaning depends on the host (see header).
elif [[ "$ARGS" =~ ${BOUNDARY_L}#([0-9]+)${BOUNDARY_R} ]]; then
    REF_ID="${BASH_REMATCH[2]}"
    if [[ "$HOST" == "unknown" ]]; then
        # Without a known host, `#<N>` cannot even be classified — GitHub shares
        # one counter between issues and PRs, ADO does not — let alone looked up.
        # Leave it as prose, which is exactly what it was before this feature.
        KIND="none"
        REF_ID=""
    elif [[ "$HOST" == "azdo" ]]; then
        KIND="workitem"
    else
        # GitHub numbers issues and PRs from one shared counter, so #<N> names
        # exactly one object — but which one is only knowable by asking. Defer
        # to the resolution step, which tries the PR fetch and falls back to
        # issue when it reports a genuine not-found.
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

# Derive the ADO organization URL from the origin remote. The v3 ssh dialects
# must be matched BEFORE the generic visualstudio.com arm, or
# vs-ssh.visualstudio.com derives the org as "vs-ssh".
ado_org_url() {
    local url="$1"
    if [[ "$url" =~ (ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)[:/]v3/([^/]+) ]]; then
        printf 'https://dev.azure.com/%s' "${BASH_REMATCH[2]}"
    elif [[ "$url" =~ dev\.azure\.com/([^/]+) ]]; then
        printf 'https://dev.azure.com/%s' "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ([A-Za-z0-9_-]+)\.visualstudio\.com ]]; then
        printf 'https://%s.visualstudio.com' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# The repository name from the origin remote (last path segment, minus .git).
origin_repo_name() {
    local url="${1%/}"
    url="${url%.git}"
    printf '%s' "${url##*/}"
}

# Every PR number mentioned in the arguments, space-separated, in order of
# appearance — from PR URLs and from `pr <N>` tokens. Bash regex has no global
# match, so each match is consumed from a working copy of the text until none
# remain. BASH_REMATCH[0] always contains "pr" or "/pull/", so it is never empty
# and the loop always makes progress.
collect_pr_refs() {
    local text="$1" found=""
    while [[ "$text" =~ (https?://[^[:space:]]+)/(pull|pullrequest)/([0-9]+) ]]; do
        found+="${BASH_REMATCH[3]} "
        text="${text/"${BASH_REMATCH[0]}"/ }"
    done
    while [[ "$text" =~ ${BOUNDARY_L}[Pp][Rr][[:space:]]+#?([0-9]+)${BOUNDARY_R} ]]; do
        found+="${BASH_REMATCH[2]} "
        text="${text/"${BASH_REMATCH[0]}"/ }"
    done
    printf '%s' "$found"
}

if [[ "$KIND" == "pr" || "$KIND" == "ambiguous" ]]; then
    require_known_host
    if [[ "$HOST" == "github" ]]; then
        require_cli gh
        # Explicit array order — do not rely on JSON key order. isCrossRepository
        # tells us the head lives in a fork, where `git fetch origin` cannot see it.
        #
        # This lookup doubles as the PR-vs-issue test for an ambiguous #<N>:
        # a genuine not-found means the number is an issue, not a PR.
        if PR_TSV=$(gh pr view "$REF_ID" \
                --json headRefName,baseRefName,state,isCrossRepository \
                --jq '[.headRefName, .baseRefName, .state, .isCrossRepository] | @tsv' \
                2>"$ERR_FILE"); then
            KIND="pr"
            PR_TSV=${PR_TSV//$'\r'/}
            SOURCE_BRANCH=$(printf '%s' "$PR_TSV" | cut -f1)
            TARGET_BRANCH=$(printf '%s' "$PR_TSV" | cut -f2)
            GH_STATE=$(printf '%s' "$PR_TSV" | cut -f3)
            GH_FORK=$(printf '%s' "$PR_TSV" | cut -f4)
            case "$GH_STATE" in
                OPEN)   STATE="open" ;;
                MERGED) STATE="merged" ;;
                CLOSED) STATE="closed" ;;
                *)      STATE="$GH_STATE" ;;
            esac
            if [[ "$GH_FORK" == "true" ]]; then
                echo "Error: PR #$REF_ID comes from a fork; its source branch '$SOURCE_BRANCH' does not exist on origin." >&2
                echo "Fetch the fork's ref manually (e.g. 'gh pr checkout $REF_ID') and re-run with branch:<name>." >&2
                exit 1
            fi
        elif [[ "$KIND" == "ambiguous" ]] && grep -q "Could not resolve to a PullRequest" "$ERR_FILE"; then
            # #<N> named an issue: context only, no branch selection. Only a
            # genuine not-found may downgrade — a network, auth or 404-on-repo
            # failure must not silently become "review HEAD".
            KIND="issue"
        else
            die_with_stderr "Could not resolve GitHub PR #$REF_ID."
        fi
    else
        require_cli az
        ORG=$(ado_org_url "$REMOTE_URL") || {
            echo "Error: Could not derive an Azure DevOps organization URL from: $REMOTE_URL" >&2
            exit 1
        }
        # `az repos pr show --id <N>` resolves org-wide — no repository scoping
        # needed, unlike the ADO MCP tool which requires a repositoryId GUID.
        # That breadth is also a hazard: an id from another repo in the same org
        # resolves fine, so the PR's repository is checked against origin below.
        #
        # Query as an ordered ARRAY, not a {dict}: az renders a dict to tsv in
        # alphabetical key order, so a {source,target,status} hash silently
        # comes back source/status/target. An array pins the order.
        #
        # az prints an array to tsv one element per LINE (not tab-separated),
        # so read it line-wise — `cut -f1` finds no tabs and returns the whole
        # blob for every field.
        if ! PR_OUT=$(az repos pr show --id "$REF_ID" --org "$ORG" \
                --query "[sourceRefName, targetRefName, status, repository.name]" \
                -o tsv 2>"$ERR_FILE"); then
            die_with_stderr "Could not resolve Azure DevOps PR #$REF_ID in $ORG."
        fi
        # az on Windows emits CRLF. A trailing \r rides along into the branch
        # name and git rejects the ref ("Needed a single revision"), so strip it
        # before anything else touches these values.
        PR_OUT=${PR_OUT//$'\r'/}
        {
            read -r SOURCE_BRANCH || true
            read -r TARGET_BRANCH || true
            read -r AZ_STATUS || true
            read -r AZ_REPO || true
        } <<< "$PR_OUT"
        case "$AZ_STATUS" in
            active)    STATE="open" ;;
            completed) STATE="merged" ;;
            abandoned) STATE="abandoned" ;;
            *)         STATE="$AZ_STATUS" ;;
        esac
        ORIGIN_REPO=$(origin_repo_name "$REMOTE_URL")
        if [[ -n "$AZ_REPO" && -n "$ORIGIN_REPO" && "$AZ_REPO" != "$ORIGIN_REPO" ]]; then
            echo "Error: PR #$REF_ID belongs to repository '$AZ_REPO', but origin is '$ORIGIN_REPO'." >&2
            echo "Azure DevOps PR ids are unique per organization, not per repository." >&2
            exit 1
        fi
    fi

    if [[ "$KIND" == "pr" ]]; then
        SOURCE_BRANCH=$(normalize_ref "$SOURCE_BRANCH")
        TARGET_BRANCH=$(normalize_ref "$TARGET_BRANCH")
        # A lookup that exits 0 but yields nothing usable must fail loudly.
        # Publishing an empty SOURCE_BRANCH hands the caller an empty checkout
        # target, and an empty-vs-empty comparison would report BRANCH_MATCH=true
        # against a detached HEAD — telling the caller it is already on the PR
        # branch when nothing is known at all.
        if [[ -z "$SOURCE_BRANCH" || -z "$TARGET_BRANCH" ]]; then
            echo "Error: Resolved PR #$REF_ID but the lookup returned no branch names." >&2
            exit 1
        fi
    fi
fi

if [[ "$KIND" == "ambiguous" ]]; then
    # Unreachable: every host branch above resolves ambiguous to pr or issue.
    echo "Error: Internal error — reference #$REF_ID was left unresolved." >&2
    exit 1
fi

# ── Other PR references mentioned but not selected ───────────────────

OTHER_REFS=""
if [[ "$KIND" == "pr" ]]; then
    for ref in $(collect_pr_refs "$ARGS"); do
        if [[ "$ref" == "$REF_ID" ]]; then
            continue
        fi
        case ",$OTHER_REFS," in
            *",$ref,"*) continue ;;
        esac
        OTHER_REFS+="${OTHER_REFS:+,}$ref"
    done
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
    if [[ -n "$SOURCE_BRANCH" && "$SOURCE_BRANCH" == "$CURRENT_BRANCH" ]]; then
        echo "BRANCH_MATCH=true"
    else
        echo "BRANCH_MATCH=false"
    fi
    if [[ -n "$OTHER_REFS" ]]; then
        echo "OTHER_REFS=$OTHER_REFS"
    fi
fi
echo "CURRENT_BRANCH=$CURRENT_BRANCH"
echo "IN_WORKTREE=$IN_WORKTREE"
