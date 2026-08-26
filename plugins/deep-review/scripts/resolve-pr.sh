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
#   WORKITEM_KIND=issue|workitem|none
#                               The story behind the work — resolved INDEPENDENTLY
#                               of the PR above, so one invocation reports both.
#                               See WORK ITEM RESOLUTION below.
#   WORKITEM_ID=<N>             The work item / issue number (omitted when none)
#   WORKITEM_SOURCE=argument|pr-body|branch-prefix
#                               HOW it was found (omitted when none). Confidence
#                               falls off down that list — the caller should name
#                               the route when it reports the item, so the user
#                               can reject a wrong guess.
#   WORKITEM_LOOKUP=ok|pr-body-unreadable
#                               Whether every route that was TRIED completed.
#                               `pr-body-unreadable` means the PR description
#                               could not be fetched, so a link that may exist
#                               there was never seen — the caller must not report
#                               a fallback result as if the stronger route had
#                               been checked and come back empty.
#   ORG=<url>                   ADO organization URL (HOST=azdo only). Emitted
#                               because a work item cannot be fetched without it:
#                               `az boards work-item show --id <N> --org <ORG>`.
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
# WORK ITEM RESOLUTION: the precedence chain above selects at most one
# reference, which used to mean `deep-review pr 4506 <issue-url>` resolved the
# PR and silently discarded the issue — the most common invocation was exactly
# the one that threw away the acceptance criteria. A PR reference and a story
# reference answer different questions ("which branch do I review" vs "what was
# asked for"), so they are now resolved independently and both are reported.
#
# The WORKITEM_* keys are context only: they never select a branch, and a
# failure to find one is never an error. Routes, first hit wins:
#   1. argument       — an explicit issue / work-item reference in the arguments
#   2. pr-body        — Closes/Fixes/Resolves #N, or AB#<id>, in the PR description
#   3. branch-prefix  — the id in our branches/<id>-<slug> naming convention
#
# A WRONG story is worse than no story: it grades the diff against someone
# else's acceptance criteria while looking like a successful resolution. Every
# pattern below is therefore anchored on BOTH sides, and every route reports
# how it decided so the caller can put the guess in front of the user.
#
# There is deliberately NO commit-message route. A previous draft scanned the
# branch's commits for AB#<id>, but it could not fire where it was needed: this
# script runs BEFORE the caller fetches the PR's source ref, so the range was
# uncomputable on the PR path, and on the non-PR path it was only reached when
# route 3 had already missed — i.e. on branches that violate the naming
# convention, which are the least likely to carry disciplined trailers.
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

# ── Resolve the work item behind the work ────────────────────────────
# Independent of the PR resolution above — see WORK ITEM RESOLUTION in the
# header. Every lookup here is best-effort: a failure leaves WORKITEM_KIND=none
# and the caller reports "no story found", which is a legitimate outcome and
# must stay distinguishable both from a story that was found, and from a route
# that could not be checked at all (WORKITEM_LOOKUP).

WORKITEM_KIND="none"
WORKITEM_ID=""
WORKITEM_SOURCE=""
WORKITEM_LOOKUP="ok"

# The PR arm above derives ORG only when a PR was resolved, but a work item
# needs it in every case — including a bare `/deep-review` on an ADO branch.
# Non-fatal here: failing to derive an org must not break a review that has no
# work item to fetch anyway.
if [[ "$HOST" == "azdo" && -z "${ORG:-}" ]]; then
    ORG=$(ado_org_url "$REMOTE_URL") || ORG=""
fi

# Classify a bare number for this host. ADO numbers work items separately from
# PRs, so a bare number there is always a work item. GitHub shares one counter,
# so #<N> might name a PR — but that only costs the caller a failed fetch, not a
# wrong review target, because nothing here selects a branch.
workitem_kind_for_host() {
    if [[ "$HOST" == "azdo" ]]; then
        printf 'workitem'
    else
        printf 'issue'
    fi
}

# Normalize scp-style remotes (git@host:path) to host/path so the two forms can
# be compared segment-wise. Everything else is returned host-first, unchanged.
url_after_host() {
    local url="$1"
    if [[ "$url" != *://* ]]; then
        url="${url/:/\/}"
    else
        url="${url#*://}"
    fi
    url="${url#*@}"
    url="${url#*/}"
    url="${url%/}"
    printf '%s' "${url%.git}"
}

# The leading path segments that scope a number to a repository. GitHub numbers
# issues per REPOSITORY, so owner/repo must match; anything less and `gh issue
# view <N>` silently reads this repo's issue of the same number.
url_owner_repo() {
    local path parts IFS='/'
    path=$(url_after_host "$1")
    read -r -a parts <<< "$path"
    if [[ ${#parts[@]} -lt 2 ]]; then
        return 1
    fi
    printf '%s/%s' "${parts[0]}" "${parts[1]}"
}

# Does a reference URL point at the repository this review is about?
#
# The bare number is NOT enough on its own: the caller fetches with `gh issue
# view <N>` / `az boards work-item show --id <N>` scoped to origin, so an id
# lifted from someone else's repository resolves to a DIFFERENT, real story and
# grades the diff against it while reporting provenance "argument" —
# "authoritative". The PR-URL path above already refuses a foreign host (see
# "Refusing to look up a PR number from one host against another"); this is the
# same guard for the context routes.
#
# KNOWN LIMIT: on ADO only the ORGANIZATION is compared, not the project. ADO
# numbers work items per project, so a cross-project URL within one org still
# passes. Comparing projects would mean reconciling percent-encoding across six
# remote dialects; the org check covers the realistic cross-tenant mistake.
reference_url_is_local() {
    local url="$1" url_host url_scope origin_scope
    url_host=$(remote_host "$url")
    if [[ -n "$REMOTE_HOST" && "$url_host" != "$REMOTE_HOST" ]]; then
        return 1
    fi
    if [[ "$HOST" == "azdo" ]]; then
        url_scope=$(ado_org_url "$url") || return 1
        origin_scope=$(ado_org_url "$REMOTE_URL") || return 1
    else
        url_scope=$(url_owner_repo "$url") || return 1
        origin_scope=$(url_owner_repo "$REMOTE_URL") || return 1
    fi
    [[ "$url_scope" == "$origin_scope" ]]
}

# Route 1 — an explicit reference in the arguments.
if [[ "$ARGS" =~ (https?://[^[:space:]]+)/_workitems/edit/([0-9]+) ]]; then
    if reference_url_is_local "${BASH_REMATCH[1]}"; then
        WORKITEM_KIND="workitem"
        WORKITEM_ID="${BASH_REMATCH[2]}"
        WORKITEM_SOURCE="argument"
    fi
elif [[ "$ARGS" =~ (https?://[^[:space:]]+)/issues/([0-9]+) ]]; then
    if reference_url_is_local "${BASH_REMATCH[1]}"; then
        WORKITEM_KIND="issue"
        WORKITEM_ID="${BASH_REMATCH[2]}"
        WORKITEM_SOURCE="argument"
    fi
elif [[ "$HOST" != "unknown" ]]; then
    # Bare `#<N>`. Bash regex has no global match, so scan by consuming each
    # match from a working copy — the same technique collect_pr_refs uses.
    #
    # The loop matters: `#<N>` may name the PR we already selected, and an
    # EARLIER draft simply abandoned the route in that case. On `pr #170 and
    # see #143` that discarded the user's explicit #143 and fell through to a
    # weaker route — reproducing the exact "silently dropped the issue" bug
    # this whole feature exists to fix. Skip the PR's own number and keep
    # looking instead.
    wi_text="$ARGS"
    while [[ "$wi_text" =~ ${BOUNDARY_L}#([0-9]+)${BOUNDARY_R} ]]; do
        wi_candidate="${BASH_REMATCH[2]}"
        wi_text="${wi_text/"${BASH_REMATCH[0]}"/ }"
        if [[ "$KIND" == "pr" && "$wi_candidate" == "$REF_ID" ]]; then
            continue
        fi
        WORKITEM_ID="$wi_candidate"
        WORKITEM_KIND=$(workitem_kind_for_host)
        WORKITEM_SOURCE="argument"
        break
    done
fi

# Route 2 — the PR's own description. Matched with grep rather than a bash
# regex because the keywords are case-insensitive and `${var,,}` is bash 4+;
# macOS ships bash 3.2.
#
# Both patterns are anchored on BOTH sides. Without a left boundary `prefixes
# #12`, `unclosed #5` and `collab#5` all match; without a right one `Fixes
# #12abc` yields 12. This file learned that lesson once already — see
# BOUNDARY_L/BOUNDARY_R, added because `compr 4` matched `pr 4`.
if [[ "$WORKITEM_KIND" == "none" && "$KIND" == "pr" ]]; then
    PR_BODY=""
    PR_BODY_OK=true
    if [[ "$HOST" == "github" ]]; then
        # A second round trip rather than adding `body` to the lookup above.
        # DO NOT "simplify" these into one call: that query renders through
        # @tsv, and a multi-line description would shift every field — the
        # branch names silently become garbage. The ADO arm has the same
        # hazard with its line-wise `read -r` parse.
        PR_BODY=$(gh pr view "$REF_ID" --json body --jq '.body' 2>"$ERR_FILE") || PR_BODY_OK=false
    else
        PR_BODY=$(az repos pr show --id "$REF_ID" --org "${ORG:-}" \
            --query "description" -o tsv 2>"$ERR_FILE") || PR_BODY_OK=false
    fi
    # az on Windows emits CRLF here exactly as it does for the branch lookup.
    PR_BODY=${PR_BODY//$'\r'/}

    if [[ "$PR_BODY_OK" != true ]]; then
        # An auth, network or rate-limit failure is NOT "the body had no link".
        # Reporting them the same way lets a weaker fallback masquerade as a
        # checked-and-empty stronger route.
        WORKITEM_LOOKUP="pr-body-unreadable"
    else
        WI_BOUNDARY_L='(^|[^0-9A-Za-z])'
        WI_BOUNDARY_R='($|[^0-9A-Za-z])'
        # AB#<id> is checked FIRST on ADO: it is ADO's own work-item link
        # syntax, whereas a bare `#5` in an ADO description is not a work-item
        # reference at all. On GitHub the precedence is reversed.
        WI_CLOSE_HIT=$(printf '%s' "$PR_BODY" \
            | grep -Eio "${WI_BOUNDARY_L}(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#[0-9]+${WI_BOUNDARY_R}" \
            | head -1 || printf '')
        WI_AB_HIT=$(printf '%s' "$PR_BODY" \
            | grep -Eo "${WI_BOUNDARY_L}AB#[0-9]+${WI_BOUNDARY_R}" \
            | head -1 || printf '')
        # Trailing boundary character, if any, is not part of the number.
        WI_CLOSE_HIT="${WI_CLOSE_HIT%%[^0-9]}"
        WI_AB_HIT="${WI_AB_HIT%%[^0-9]}"

        if [[ "$HOST" == "azdo" && -n "$WI_AB_HIT" ]]; then
            WORKITEM_ID="${WI_AB_HIT##*#}"
            WORKITEM_KIND="workitem"
            WORKITEM_SOURCE="pr-body"
        elif [[ -n "$WI_CLOSE_HIT" ]]; then
            WORKITEM_ID="${WI_CLOSE_HIT##*#}"
            WORKITEM_KIND=$(workitem_kind_for_host)
            WORKITEM_SOURCE="pr-body"
        elif [[ -n "$WI_AB_HIT" ]]; then
            # AB#<id> is an ADO work-item link wherever it is written — but a
            # GitHub-hosted repo has no ADO org to fetch it from, so the caller
            # is told the kind and left to decide (see ORG in the header).
            WORKITEM_ID="${WI_AB_HIT##*#}"
            WORKITEM_KIND="workitem"
            WORKITEM_SOURCE="pr-body"
        fi
    fi
fi

# Route 3 — our own branch convention, `branches/<id>-<slug>`. The id is right
# there in the name; nothing has to be fetched to read it.
#
# Anchored on the LITERAL `branches/` segment, not on any numeric path prefix.
# A looser `(^|/)([0-9]+)-` matched `release/2024-01-hotfix` as story 2024 and
# `20250101-my-branch` as story 20250101 — real branch names that resolve to
# real, unrelated issues in any repo with a few thousand of them.
if [[ "$WORKITEM_KIND" == "none" && "$HOST" != "unknown" ]]; then
    WI_BRANCH="$CURRENT_BRANCH"
    if [[ "$KIND" == "pr" ]]; then
        WI_BRANCH="$SOURCE_BRANCH"
    fi
    if [[ "$WI_BRANCH" =~ (^|/)branches/([0-9]+)- ]]; then
        WORKITEM_ID="${BASH_REMATCH[2]}"
        WORKITEM_KIND=$(workitem_kind_for_host)
        WORKITEM_SOURCE="branch-prefix"
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
    if [[ -n "$SOURCE_BRANCH" && "$SOURCE_BRANCH" == "$CURRENT_BRANCH" ]]; then
        echo "BRANCH_MATCH=true"
    else
        echo "BRANCH_MATCH=false"
    fi
    if [[ -n "$OTHER_REFS" ]]; then
        echo "OTHER_REFS=$OTHER_REFS"
    fi
fi
echo "WORKITEM_KIND=$WORKITEM_KIND"
# Keyed on KIND, not on a non-empty id, so the code states the invariant the
# header advertises rather than one that merely coincides with it today.
if [[ "$WORKITEM_KIND" != "none" ]]; then
    echo "WORKITEM_ID=$WORKITEM_ID"
    echo "WORKITEM_SOURCE=$WORKITEM_SOURCE"
fi
echo "WORKITEM_LOOKUP=$WORKITEM_LOOKUP"
# The org is required to fetch an ADO work item at all, so publish the one the
# PR lookup already derived instead of making the caller re-derive it.
if [[ "$HOST" == "azdo" && -n "${ORG:-}" ]]; then
    echo "ORG=$ORG"
fi
echo "CURRENT_BRANCH=$CURRENT_BRANCH"
echo "IN_WORKTREE=$IN_WORKTREE"
