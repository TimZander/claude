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
#   WORKITEM_SOURCE=argument|pr-link|pr-body|branch-prefix
#                               HOW it was found (omitted when none). Confidence
#                               falls off down that list — the caller should name
#                               the route when it reports the item, so the user
#                               can reject a wrong guess. `pr-link` is ADO's own
#                               PR/work-item relation: structural, not a string
#                               match, and it needs no convention from the author.
#   WORKITEM_OTHER_IDS=<N>[,<N>...]
#                               Work items the PR ALSO links but that were not
#                               selected. Emitted ONLY by the pr-link route, and
#                               only when it returned more than one id — so it
#                               is absent both when the choice was forced AND
#                               whenever that route did not run (an explicit
#                               argument pre-empted it, the host is not ADO, or
#                               the lookup failed). Its PRESENCE means "this was
#                               a pick"; its absence means nothing on its own.
#                               The first id returned is selected — see ORDER IS
#                               TAKEN AS GIVEN at the route itself; the order is
#                               not known to be meaningful, which is exactly why
#                               the alternatives are reported rather than
#                               silently dropped.
#   WORKITEM_LOOKUP=ok|pr-link-unreadable|pr-body-unreadable
#                               The STRONGEST route that could not be checked,
#                               or `ok` when every route that ran completed. A
#                               later failure never overwrites an earlier one:
#                               one bad credential breaks both `az` calls, and
#                               the actionable fact is that a stronger route
#                               went unchecked. So `pr-link-unreadable` does not
#                               imply the description WAS read — only that the
#                               link lookup is the strongest thing that failed.
#                               `pr-link-unreadable` means the PR's work-item
#                               relations could not be listed, or came back
#                               unintelligible; `pr-body-unreadable` means the
#                               PR description could not be fetched, so a link
#                               that may exist there was never seen — the caller
#                               must not report whatever a weaker route produced
#                               as if the stronger one had been checked and come
#                               back empty.
#   RESOLVER_ROUTES=<name>[,<name>...]
#                               The work-item routes THIS version implements, in
#                               precedence order. Always present. Added because
#                               the caller could not otherwise tell a version
#                               that checked a route and found nothing from one
#                               that never had the route at all — the two emit
#                               byte-identical output, so a prompt had to warn
#                               about the possibility unconditionally, forever,
#                               even on the newest install. Test for a route by
#                               name (`pr-link`), never by list length.
#   REFERENCE_REFUSED=true|false
#                               Always present. `true` means a reference URL was
#                               supplied but named another repository or ADO
#                               organization, so it was declined. ORTHOGONAL to
#                               WORKITEM_LOOKUP — both can be true at once, and
#                               a refusal can coexist with a perfectly good
#                               story found by another route in the same
#                               arguments. The caller must never say "no story
#                               was referenced" while this is `true`.
#   ORG=<url>                   ADO organization URL. Emitted only when
#                               HOST=azdo AND an organization was derivable
#                               from the remote — an ADO remote with no parsable
#                               org yields HOST=azdo and NO ORG. Emitted at all
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
# failure to find one is never an error. Every route is gated on a known host —
# a story that cannot be fetched is not a story — so WORKITEM_KIND is always
# `none` when HOST=unknown, even though KIND may still name a local reference
# there. Routes, first hit wins:
#   1. argument       — an explicit issue / work-item reference in the arguments
#   2. pr-link        — ADO's own PR/work-item relation, the link its UI shows.
#                       Structural rather than a string match, so it needs no
#                       convention from the author: no AB# in the body, no
#                       numeric branch prefix. ADO only for now; GitHub's
#                       equivalent (closingIssuesReferences) is not read yet.
#   3. pr-body        — Closes/Fixes/Resolves #N on GitHub; AB#<id> on ADO, where
#                       a bare `#N` in a description is not a work-item link
#   4. branch-prefix  — the id in our branches/<id>-<slug> naming convention
#
# KNOWN GAP, deliberately not fixed here: because first-hit-wins, a successful
# pr-link means route 3 never runs, so an author's explicit `AB#999` in the
# description is neither read nor reported in WORKITEM_OTHER_IDS. Folding it in
# would cost an unconditional description fetch on every ADO PR — a second `az`
# process to catch a case where the author contradicts the PR's own link — so
# the cost was judged the larger harm. Revisit if the two ever disagree in
# practice; the fix is to fetch the body anyway and append a differing id.
#
# A WRONG story is worse than no story: it grades the diff against someone
# else's acceptance criteria while looking like a successful resolution. So the
# body patterns are anchored on BOTH sides, reference URLs must belong to this
# repository/organization, and every route reports how it decided so the caller
# can put the guess in front of the user.
#
# There is deliberately NO commit-message route. A previous draft scanned the
# branch's commits for AB#<id>, but it could not fire where it was needed: this
# script runs BEFORE the caller fetches the PR's source ref, so the range was
# uncomputable on the PR path, and on the non-PR path it was only reached when
# route 4 had already missed — i.e. on branches that violate the naming
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
#   1 — Error. Every case: lib-remote.sh unreadable or incomplete beside this
#       script; a usage error in this script's own arguments; no
#       origin remote, an unsupported host, or a missing CLI when a PR must be
#       looked up; a PR URL naming a different repository or host; a PR lookup
#       that failed, returned no branch names, or returned a PR belonging to
#       another ADO repository; a GitHub PR whose source is in a fork; an ADO
#       remote with no derivable organization URL on the PR path; and the
#       internal-error guard for an unresolved `ambiguous` reference.
#   2 — Not produced by this script: bash's own exit status when lib-remote.sh
#       is present but does not parse. The message names the file and line, so
#       it is left to bash rather than papered over with a friendlier one.
#
#       A cross-repo CONTEXT reference is deliberately NOT an error: it exits 0,
#       resolves no story from that reference, and reports REFERENCE_REFUSED=true.
#       Only the branch-SELECTING path exits non-zero, because there the wrong
#       answer is a review of the wrong code.

# ── Shared remote parsing ────────────────────────────────────────────
# Resolved from BASH_SOURCE, not $0 or the caller's cwd: this script is invoked
# by absolute path from a plugin directory that is not the working directory,
# and in CI from a staged read-only copy.

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# `-r`, not `-f`: a present-but-unreadable file passes an existence test and
# then dies at the `.` below with a bare "Permission denied", skipping the
# remediation this branch exists to print.
if [[ ! -r "$SCRIPT_DIR/lib-remote.sh" ]]; then
    echo "Error: lib-remote.sh not readable beside resolve-pr.sh (looked in $SCRIPT_DIR)." >&2
    echo "The plugin install is incomplete — reinstall or re-sync it." >&2
    exit 1
fi
# shellcheck source=lib-remote.sh
. "$SCRIPT_DIR/lib-remote.sh"

# Existence is not integrity. An interrupted copy or a truncated vendor snapshot
# leaves a readable file that loads without error and is missing functions, and
# the failure then surfaces hundreds of lines later as `command not found` on a
# name the user has no reason to recognize. Check the surface up front so the
# same remediation message covers the partial-install case, which is the more
# likely one. (A truncation landing mid-function is a parse error instead; that
# is loud on its own and names the file and line.)
for _fn in remote_host host_kind equals_ignoring_case ado_org_name ado_org_url \
           repo_name_from_url url_after_host url_owner_repo reference_scope \
           urls_same_scope; do
    if ! declare -F "$_fn" >/dev/null 2>&1; then
        echo "Error: lib-remote.sh loaded but does not define '$_fn' — the file is incomplete." >&2
        echo "The plugin install is incomplete — reinstall or re-sync it." >&2
        exit 1
    fi
done
unset _fn

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
# Host detection derived from craft-pr/scripts/create-pr.sh. Copied from that
# plugin rather than sourced from it — plugins are installed independently and
# must stand alone. lib-remote.sh, sourced at the top of this file, is a
# different case: it ships inside THIS plugin, so sourcing it keeps deep-review
# self-contained and separately installable.

# An unknown host is NOT an error here. /deep-review runs this step on EVERY
# invocation, including with no arguments at all, and most invocations are a
# plain focus area with no PR reference. Failing early would break `/deep-review focus on X` for
# every GitLab, Bitbucket, self-hosted and remote-less repo — a review that
# works today. The host only has to be known to LOOK UP a PR, so that
# requirement is enforced at the resolution step instead.
REMOTE_URL=$(git remote get-url origin 2>/dev/null || printf '')
HOST="unknown"
# Initialized like every other output variable. Without this, `${ORG:-}` reads
# the CALLER'S exported ORG — a plausible variable for someone working with az
# to have set — which then skips derivation and gets published as this repo's
# organization. Every other emitted value is initialized here or at its section.
ORG=""

# Unconditional: host_kind "" already yields `unknown`, which is what the
# initializer above says. Guarding it would only re-state that.
HOST=$(host_kind "$REMOTE_URL")

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

# ── Reference locality ───────────────────────────────────────────────
# Defined here, ABOVE the parse chain, because both the KIND path and the
# WORKITEM_* path need them. An earlier version defined them only alongside the
# work-item routes, so the KIND path published a foreign id unchecked while the
# guard sat twenty lines below it.
#
# Why locality matters at all: a reference URL's NUMBER is meaningless without
# its repository. The caller fetches with `gh issue view <N>` / `az boards
# work-item show --id <N>` scoped to origin, so an id lifted from someone
# else's repository resolves to a DIFFERENT, real story and grades the diff
# against it. The PR-URL path already refuses a foreign host; this is the same
# guard for every other reference.

# Does a reference URL point at the repository this review is about?
#
# The comparison itself is urls_same_scope in lib-remote.sh, which takes both
# URLs and the host family as arguments so it can be shared. This wrapper is the
# only thing that has to know which globals hold "the repo under review", and it
# keeps that knowledge in the script that owns them.
#
# Returns non-zero to mean "no", so call it in conditional context under set -e:
#   0  — yes, local
#   1  — the reference names somewhere else. The user's URL is foreign.
#   2  — OUR OWN origin could not be identified (absent, or unparsable). Nothing
#        can be said about the reference either way, and blaming it would be a
#        confident false statement — an earlier version reported a perfectly
#        ordinary same-repo URL as "pointed at another repository" purely
#        because the repo had no origin remote.
reference_url_is_local() {
    urls_same_scope "$1" "$REMOTE_URL" "$HOST"
}

# ── Parse the reference ──────────────────────────────────────────────

KIND="none"
REF_ID=""
# Set when a reference URL was present but pointed somewhere else. Reported via
# WORKITEM_LOOKUP so "you named a story I refused" never looks like "you named
# no story" — the caller would otherwise present a branch-name guess as though
# nothing had been supplied.
REFERENCE_REFUSED=false

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
    # Scope, not just host. A same-host PR URL from ANOTHER repository used to
    # pass this guard, and the number was then looked up against origin — so
    # `github.com/other/repo/pull/99` selected THIS repo's PR 99 and reviewed
    # its branch. That is the widest blast radius in the file: every other
    # refusal costs context, this one costs the review target.
    PR_URL_LOCAL=0
    reference_url_is_local "${BASH_REMATCH[1]}" || PR_URL_LOCAL=$?
    if [[ "$PR_URL_LOCAL" == 1 ]]; then
        echo "Error: PR URL names a different repository than origin." >&2
        echo "  PR URL: ${BASH_REMATCH[1]}" >&2
        echo "  origin: $REMOTE_URL" >&2
        echo "Refusing to look up a PR number against a repository, organization or host that is not this one." >&2
        exit 1
    fi
    # PR_URL_LOCAL=2 means origin itself is missing or unparsable. Say nothing
    # here: require_known_host below reports that accurately, and claiming the
    # user's URL is foreign would blame the wrong thing.
# Bare `pr <N>` — outranks the context URLs below; see the header.
elif [[ "$ARGS" =~ ${BOUNDARY_L}[Pp][Rr][[:space:]]+#?([0-9]+)${BOUNDARY_R} ]]; then
    KIND="pr"
    REF_ID="${BASH_REMATCH[2]}"
fi

# The context references below are NOT part of the elif chain above, and the
# three of them are not chained to each other either.
#
# Each URL arm can MATCH and then be REFUSED as foreign, and a refusal must not
# consume the slot: on `<foreign-url> and see #143` an elif chain swallowed the
# perfectly local `#143`, so a stray URL in the prose silently moved the review
# target off the PR's branch and onto HEAD. The WORKITEM routes below hit this
# same bug and fixed it there only — this is the same fix, one level up.
#
# Why refuse at all: the number alone is meaningless, because the caller
# fetches it scoped to origin, so an id from another repository resolves to a
# different, real story. That mirrors the PR-URL arm above, which has always
# refused a foreign host.

# ADO work item URL: .../_workitems/edit/<N>
if [[ "$KIND" == "none" && "$ARGS" =~ (https?://[^[:space:]]+)/_workitems/edit/([0-9]+) ]]; then
    REF_LOCAL=0
    reference_url_is_local "${BASH_REMATCH[1]}" || REF_LOCAL=$?
    if [[ "$REF_LOCAL" == 0 ]]; then
        KIND="workitem"
        REF_ID="${BASH_REMATCH[2]}"
    elif [[ "$REF_LOCAL" == 1 ]]; then
        REFERENCE_REFUSED=true
    fi
fi

# GitHub issue URL: https://github.com/<owner>/<repo>/issues/<N>
if [[ "$KIND" == "none" && "$ARGS" =~ (https?://[^[:space:]]+)/issues/([0-9]+) ]]; then
    REF_LOCAL=0
    reference_url_is_local "${BASH_REMATCH[1]}" || REF_LOCAL=$?
    if [[ "$REF_LOCAL" == 0 ]]; then
        KIND="issue"
        REF_ID="${BASH_REMATCH[2]}"
    elif [[ "$REF_LOCAL" == 1 ]]; then
        REFERENCE_REFUSED=true
    fi
fi

# Bare `#<N>` — meaning depends on the host (see header).
if [[ "$KIND" == "none" && "$ARGS" =~ ${BOUNDARY_L}#([0-9]+)${BOUNDARY_R} ]]; then
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
        # --repo, always. A bare `gh pr view <N>` resolves against gh's DEFAULT
        # remote, which `gh repo set-default` can point anywhere — so without
        # this the whole locality model, which is built on `origin`, can be
        # bypassed by a setting this script never reads. The ADO arm below has
        # always checked repository.name for the same reason.
        GH_SLUG=$(url_owner_repo "$REMOTE_URL") || {
            echo "Error: Could not derive owner/repo from the origin remote: $REMOTE_URL" >&2
            exit 1
        }
        if PR_TSV=$(gh pr view "$REF_ID" --repo "$GH_SLUG" \
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
        ORIGIN_REPO=$(repo_name_from_url "$REMOTE_URL")
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
WORKITEM_OTHER_IDS=""

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

# Route 1 — an explicit reference in the arguments.
#
# Every arm is gated on a known host: an id we cannot classify or fetch is not
# a story, and the bare-`#N` arm has always said so. The URL arms used to skip
# that gate, so a GitLab repo produced WORKITEM_KIND=issue and the caller was
# then told to run `gh issue view` in it.
#
# NOTE the deliberate absence of `elif` between the URL arms and the bare-`#N`
# scan. A URL that matches but is REFUSED must not consume the route: on
# `<foreign-url> see also #143` an elif chain discarded the perfectly local
# #143 — the same "silently dropped the user's reference" bug the scan below
# was written to fix, reintroduced one level up.
if [[ "$HOST" != "unknown" && "$ARGS" =~ (https?://[^[:space:]]+)/_workitems/edit/([0-9]+) ]]; then
    REF_LOCAL=0
    reference_url_is_local "${BASH_REMATCH[1]}" || REF_LOCAL=$?
    if [[ "$REF_LOCAL" == 0 ]]; then
        WORKITEM_KIND="workitem"
        WORKITEM_ID="${BASH_REMATCH[2]}"
        WORKITEM_SOURCE="argument"
    elif [[ "$REF_LOCAL" == 1 ]]; then
        REFERENCE_REFUSED=true
    fi
fi

if [[ "$WORKITEM_KIND" == "none" && "$HOST" != "unknown" \
    && "$ARGS" =~ (https?://[^[:space:]]+)/issues/([0-9]+) ]]; then
    REF_LOCAL=0
    reference_url_is_local "${BASH_REMATCH[1]}" || REF_LOCAL=$?
    if [[ "$REF_LOCAL" == 0 ]]; then
        WORKITEM_KIND="issue"
        WORKITEM_ID="${BASH_REMATCH[2]}"
        WORKITEM_SOURCE="argument"
    elif [[ "$REF_LOCAL" == 1 ]]; then
        REFERENCE_REFUSED=true
    fi
fi

if [[ "$WORKITEM_KIND" == "none" && "$HOST" != "unknown" ]]; then
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

# Route 2 — the pull request's own WORK ITEM LINK (Azure DevOps only).
#
# This is the link ADO itself treats as authoritative: it is what the PR's
# "Work items" tab shows, what `AB#<id>` in a commit or description ultimately
# CREATES, and what the REST API returns as a relation. It survives a branch
# rename and a rewritten description, and it is the one route that needs no
# convention from the author at all — which is why it sits ahead of both
# text-scraping routes below rather than after them.
#
# It was missing entirely until now, so a PR linked the way the ADO UI links
# one — through the work-item link API, with no `AB#` in the body and no
# numeric branch prefix — resolved to no story whatsoever. The linkage was
# right there in the PR and this script could not see it.
#
# `az repos pr work-item list` can return the linked items' fields as well as
# their ids, and this route deliberately takes only the ids. Not an oversight:
# the caller already owns one fetch path (`az boards work-item show`), a second
# one here would drift from it, and the fields arrive as HTML with embedded
# newlines that a `-o tsv` parse would silently corrupt. This stays a resolver.
#
# ADO only. On GitHub the equivalent relation is `closingIssuesReferences`
# (`gh pr view --json closingIssuesReferences`), which the Development sidebar
# creates and which likewise survives a rewritten body. It is NOT read yet — a
# GitHub PR linked that way with no `Closes #N` still resolves to no story, and
# closing that gap is a separate change. Route 3 reads the description text,
# which is the only GitHub linkage this script sees today.
if [[ "$WORKITEM_KIND" == "none" && "$KIND" == "pr" && "$HOST" == "azdo" ]]; then
    WI_LINK_OK=true
    # `--query` rather than parsing the whole payload: the fields block carries
    # HTML descriptions with embedded newlines, and a line-wise read of that is
    # the same hazard the PR-body lookup below documents. Ids are integers, so
    # one per line is safe.
    #
    # `${ORG:-}` for symmetry with the route-3 call below, not because it can be
    # empty: KIND=pr on azdo means the derivation above already succeeded or the
    # script exited.
    WI_LINK_IDS=$(az repos pr work-item list --id "$REF_ID" --org "${ORG:-}" \
        --query "[].id" -o tsv 2>"$ERR_FILE") || WI_LINK_OK=false
    # Before the numeric filter below, never after: `$` would not match past a
    # trailing CR, and az on Windows really does emit one per line (verified:
    # `8421\r\n`). After the fail-closed change below, an unstripped payload
    # would classify every id as noise and report the route unreadable — not
    # silently wrong, but a working lookup reported as broken.
    WI_LINK_IDS=${WI_LINK_IDS//$'\r'/}

    if [[ "$WI_LINK_OK" != true ]]; then
        # Same reasoning as pr-body-unreadable: an auth or network failure is
        # NOT "the PR had no linked work item". Reporting them alike would let
        # a branch-prefix guess masquerade as proof the strongest route came
        # back empty.
        #
        # The likeliest cause in practice is an azure-devops CLI extension too
        # old to expose this subcommand, which would otherwise report every ADO
        # review unreadable forever with no hint. Nothing consumes ERR_FILE
        # after the PR-resolution block, so surface the first line here or it
        # is lost when route 3 truncates the file.
        WORKITEM_LOOKUP="pr-link-unreadable"
        if [[ -s "$ERR_FILE" ]]; then
            echo "Note: could not list work-item links for PR #$REF_ID:" >&2
            head -n 1 "$ERR_FILE" | sed 's/^/  /' >&2
            echo "  If this persists, try: az extension update --name azure-devops" >&2
        fi
    else
        # PURE BASH, no forks — matching the sibling OTHER_REFS loop, which does
        # the identical job with none. (The fork cost this avoids is small
        # beside the `az` process above; the reason to match is consistency with
        # the sibling, not speed.)
        #
        # ORDER IS TAKEN AS GIVEN, and deliberately NOT sorted — but do not read
        # that as "ADO's relation order is preserved". It is not: `az repos pr
        # work-item list` fetches the relation refs, DISCARDS them, and
        # re-queries `wit_client.get_work_items(ids=[...])`, so what comes back
        # is the WIT batch endpoint's order, which is undocumented. Sorting here
        # would add a second unverified ordering on top of an unknown one, so we
        # take the first returned and REPORT the rest rather than pretending
        # either order is meaningful. WORKITEM_OTHER_IDS is what makes that
        # honest: the caller names the alternatives instead of the script
        # silently electing one.
        WI_LINK_SEEN=""
        WI_LINK_NOISE=false
        while IFS= read -r wi_line; do
            [[ -n "$wi_line" ]] || continue
            if [[ ! "$wi_line" =~ ^[0-9]+$ ]]; then
                # Output we did not understand is NOT "no links". A stray az
                # notice on stdout, a BOM, or a future --query shape all land
                # here.
                WI_LINK_NOISE=true
                continue
            fi
            case ",$WI_LINK_SEEN," in
                *",$wi_line,"*) continue ;;
            esac
            WI_LINK_SEEN+="${WI_LINK_SEEN:+,}$wi_line"
        done <<< "$WI_LINK_IDS"

        # FAIL CLOSED ON ANY NOISE, even when some ids parsed — checked BEFORE
        # the success arm, which is the whole point. Honouring noise only when
        # NOTHING parsed looked equivalent and was not: a BOM attaches to the
        # FIRST line, so `<BOM>7493\n7500` dropped 7493 and published 7500 as
        # the PR's sole, structurally-confirmed story with WORKITEM_LOOKUP=ok —
        # a wrong story wearing this file's highest-confidence label, which its
        # own axiom rates worse than no story at all.
        #
        # Partial output cannot be told apart from corrupted output from in
        # here, so the safe reading is "this list is not trustworthy". Noise on
        # stdout is anomalous anyway: az notices go to stderr, which is
        # redirected above, and `--query "[].id" -o tsv` emits nothing else.
        if [[ "$WI_LINK_NOISE" == true ]]; then
            WORKITEM_LOOKUP="pr-link-unreadable"
        elif [[ -n "$WI_LINK_SEEN" ]]; then
            WORKITEM_ID="${WI_LINK_SEEN%%,*}"
            # workitem_kind_for_host rather than a literal `workitem`: correct
            # either way under the azdo guard, but a second copy of an invariant
            # this file already keeps in one place is how they drift.
            WORKITEM_KIND=$(workitem_kind_for_host)
            WORKITEM_SOURCE="pr-link"
            # A PR may link several. Picking one silently would grade the whole
            # review against an arbitrary story, so the others are REPORTED —
            # the same contract OTHER_REFS uses for multiple PR references, and
            # genuinely the same: de-duplicated, in order of appearance.
            if [[ "$WI_LINK_SEEN" == *,* ]]; then
                WORKITEM_OTHER_IDS="${WI_LINK_SEEN#*,}"
            fi
        fi
    fi
fi

# Route 3 — the PR's own description. Matched with grep rather than a bash
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
        # --repo for the same reason as the branch lookup above; GH_SLUG is set
        # there, on the only path that reaches this line (KIND=pr on GitHub).
        PR_BODY=$(gh pr view "$REF_ID" --repo "${GH_SLUG:-}" --json body --jq '.body' 2>"$ERR_FILE") || PR_BODY_OK=false
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
        #
        # ONLY WHEN NOTHING STRONGER ALREADY FAILED. This field names the
        # STRONGEST route that could not be checked, and an unconditional write
        # here destroyed `pr-link-unreadable` in the one case that actually
        # happens: a single bad credential, dead network or wrong tenant breaks
        # `az repos pr work-item list` and `az repos pr show` alike, so both
        # routes fail together and the caller heard only about the weaker one.
        # Reported as a list instead of a winner, this field would stop being
        # an enum and every consumer comparing it by value would break; the
        # actionable fact — a stronger route went unchecked, treat what follows
        # as a fallback — survives intact by keeping the first failure.
        #
        # NOTE this encodes "first failure wins", which equals "strongest
        # failure wins" only because the routes run in precedence order. A route
        # inserted out of order would silently break the documented invariant.
        # Keep new routes in strength order, or make this compare rank.
        if [[ "$WORKITEM_LOOKUP" == "ok" ]]; then
            WORKITEM_LOOKUP="pr-body-unreadable"
        fi
    else
        # BOUNDARY_L/BOUNDARY_R are reused directly — they are ERE and valid in
        # both `[[ =~ ]]` and `grep -E`. A duplicate WI_ pair lived here and
        # drifting copies of one invariant is exactly what this file already
        # learned to avoid.
        #
        # AB#<id> is checked FIRST on ADO: it is ADO's own work-item link
        # syntax, whereas a bare `#5` in an ADO description is not a work-item
        # reference at all. On GitHub the precedence is reversed.
        WI_CLOSE_HIT=$(printf '%s' "$PR_BODY" \
            | grep -Eio "${BOUNDARY_L}(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#[0-9]+${BOUNDARY_R}" \
            | head -1 || printf '')
        WI_AB_HIT=$(printf '%s' "$PR_BODY" \
            | grep -Eo "${BOUNDARY_L}AB#[0-9]+${BOUNDARY_R}" \
            | head -1 || printf '')
        # Trailing boundary character, if any, is not part of the number.
        WI_CLOSE_HIT="${WI_CLOSE_HIT%%[^0-9]}"
        WI_AB_HIT="${WI_AB_HIT%%[^0-9]}"

        if [[ "$HOST" == "azdo" ]]; then
            # On ADO, AB#<id> is the ONLY work-item link syntax in a PR
            # description. A bare `#5` there is not a work-item reference —
            # which is exactly why the header refuses to let `#N` select an
            # ADO branch — so it must not resolve a story either. An earlier
            # version fell through to the generic arm and returned work item
            # 5, a number that exists in every ADO project.
            if [[ -n "$WI_AB_HIT" ]]; then
                WORKITEM_ID="${WI_AB_HIT##*#}"
                WORKITEM_KIND="workitem"
                WORKITEM_SOURCE="pr-body"
            fi
        elif [[ -n "$WI_CLOSE_HIT" ]]; then
            WORKITEM_ID="${WI_CLOSE_HIT##*#}"
            WORKITEM_KIND=$(workitem_kind_for_host)
            WORKITEM_SOURCE="pr-body"
        fi
        # There is deliberately no `AB#<id> outside ADO` arm. An earlier draft
        # had one, gated on a derivable ORG — but ORG is only ever set on the
        # azdo path, so the arm was unreachable except through an inherited
        # environment variable, and when it did fire it set a kind the caller
        # cannot fetch (no org) while suppressing the usable branch-name story
        # below. On a non-ADO host an AB#<id> in a PR body is a mention, not a
        # link this script can resolve; fall through to route 4.
    fi
fi

# Route 4 — our own branch convention, `branches/<id>-<slug>`. The id is right
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
# A literal, not a list built from the code above: this must say what this
# VERSION implements, and a value derived from which routes happened to run
# would report `pr-link` missing on every GitHub repo. Update it in the same
# commit that adds or removes a route.
echo "RESOLVER_ROUTES=argument,pr-link,pr-body,branch-prefix"
echo "WORKITEM_KIND=$WORKITEM_KIND"
# Keyed on KIND, not on a non-empty id, so the code states the invariant the
# header advertises rather than one that merely coincides with it today.
if [[ "$WORKITEM_KIND" != "none" ]]; then
    echo "WORKITEM_ID=$WORKITEM_ID"
    echo "WORKITEM_SOURCE=$WORKITEM_SOURCE"
    # Only ever set by the pr-link route, and only when it returned more than
    # one id. Its PRESENCE means the choice was a pick and the caller must say
    # so; its absence means nothing on its own, because the route may not have
    # run at all.
    if [[ -n "$WORKITEM_OTHER_IDS" ]]; then
        echo "WORKITEM_OTHER_IDS=$WORKITEM_OTHER_IDS"
    fi
fi
# A refusal and an unreadable body are ORTHOGONAL facts, so they get separate
# keys. Folding the refusal into WORKITEM_LOOKUP made one field carry two
# meanings: it clobbered `pr-body-unreadable` when both happened, and — worse —
# it reported `reference-not-local` alongside a perfectly good
# `WORKITEM_SOURCE=argument`, because a refused URL and an accepted `#<N>` can
# occur in the same arguments. The caller then disowned a story the user did
# name.
echo "WORKITEM_LOOKUP=$WORKITEM_LOOKUP"
echo "REFERENCE_REFUSED=$REFERENCE_REFUSED"
# The org is required to fetch an ADO work item at all, so publish the one the
# PR lookup already derived instead of making the caller re-derive it.
if [[ "$HOST" == "azdo" && -n "${ORG:-}" ]]; then
    echo "ORG=$ORG"
fi
echo "CURRENT_BRANCH=$CURRENT_BRANCH"
echo "IN_WORKTREE=$IN_WORKTREE"
