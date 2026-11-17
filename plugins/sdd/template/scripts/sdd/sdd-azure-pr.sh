#!/usr/bin/env bash
#
# Installed by the sdd plugin (sdd-init). Re-running sdd-init overwrites this file.
#
# /sdd:archive-pr on Azure DevOps: finds, opens and merges archive PRs with `az`. The decisions
# are sdd-azure.mjs's; this script fetches what they need, and runs them in order. Run it from
# a clean checkout of the default branch's tip: its scripts and settings are the ones that
# judge, never the PR's.
#
#   bash sdd-azure-pr.sh find  --default <branch>
#       Prints `pr=<id>` for each open archive PR from this repository's own branches, or
#       `pr=none`.
#
#   bash sdd-azure-pr.sh open  --default <branch> --source <branch> --title <text>
#                              --description-file <file>
#       Opens the PR (never with auto-complete: it isn't pinned to a commit). Prints `pr=<id>`.
#
#   bash sdd-azure-pr.sh merge --default <branch> --pr <id> [--no-merge] [--bypass-reviewers]
#                              [--message <text>]
#       1. Checks this checkout is clean and at the default branch's tip.
#       2. Reads the PR (sdd-azure.mjs pr), waiting while its merge is being computed.
#       3. Fetches the PR's head, and checks it is based on the tip: an archive branch behind
#          the default branch can't be verified against it.
#       4. Runs sdd-archive.sh verify --base <tip> --result <head> from this checkout. This
#          re-run is the gate: CI on Azure DevOps runs the PR's own scripts.
#       5. Stops here with --no-merge or `"autoMerge": false`.
#       6. Reads the policies, waiting while one is queued or running.
#       7. Right before completing, reads the PR, the policies and the default branch's tip
#          again, and builds the body with sdd-azure.mjs complete-body: pinned to <head>
#          (lastMergeSourceCommit), with the merge strategy the policies allow, and a bypass
#          only as complete-body allows one.
#       8. Completes the PR (az devops invoke, PATCH), then reads it until it is completed and
#          confirms both the source commit (<head>) and the target commit (<tip>) it merged.
#       Last line, on every exit path: `archive-pr: <state>`, one of
#         completed    merged, pinned, and both commits confirmed
#         verified     the archive is mechanical; not completed (--no-merge, autoMerge false)
#         behind       the PR's branch is behind the default branch, or the tip moved: merge
#                      the default branch into it, push, and run again
#         review       only "Minimum number of reviewers" is unmet: it needs an approval
#         refused      the PR can't be adopted, or verify, policies or settings refuse it
#         timeout      still waiting on Azure DevOps (a merge, a policy, the completion)
#         unverified   completed, but with a source or target commit other than the verified
#                      ones: the owner must review what landed
#         failed       an az call or this checkout failed
#
# Environment: SDD_AZ_WAIT_MERGE (default 120), SDD_AZ_WAIT_POLICIES (1200) and
# SDD_AZ_WAIT_COMPLETE (120) are the longest waits in seconds; SDD_AZ_POLL (10) the interval.
#
# Exit status: 0 completed or verified (or find/open done), 1 any other state, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AZURE="$SCRIPT_DIR/sdd-azure.mjs"
POLICY_PAGE=1000

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

STATE_PRINTED=0
TMP=""
finish() {
    STATE_PRINTED=1
    echo "archive-pr: $1"
    case "$1" in
        completed|verified) exit 0 ;;
        *) exit 1 ;;
    esac
}
on_exit() {
    local code=$?
    [ -z "$TMP" ] || rm -rf "$TMP"
    if [ $ARMED -eq 1 ] && [ $STATE_PRINTED -eq 0 ]; then
        echo "archive-pr: failed"
        [ $code -ne 0 ] || code=1
    fi
    exit $code
}
MODE=""
ARMED=0
trap on_exit EXIT

say() { printf -- '- %s\n' "$*"; }

# A JSON field by dotted path, from a file: empty when absent.
jget() {
    node -e '
        let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8").replace(/^\W*(?=[[{])/, ""))
        for (const k of process.argv[2].split(".")) { v = v == null ? undefined : v[k] }
        process.stdout.write(v == null ? "" : String(v))
    ' "$1" "$2"
}

# az, with JSON output and no MSYS path conversion of its arguments (Git Bash on Windows).
azj() {
    MSYS2_ARG_CONV_EXCL='*' az "$@" -o json
}

# A path az (a Windows program under Git Bash) can open.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

wait_secs() { # name default
    local v
    eval "v=\${$1:-$2}"
    case "$v" in ''|*[!0-9]*) v="$2" ;; esac
    printf '%s' "$v"
}

load_remote() {
    local remote
    remote="$(cd "$ROOT" && node "$AZURE" remote)" || { say "$remote"; say "origin is not an Azure Repos remote"; return 1; }
    printf '%s' "$remote" > "$TMP/remote.json"
    ORG="$(jget "$TMP/remote.json" organization)"
    PROJECT="$(jget "$TMP/remote.json" project)"
    REPOSITORY="$(jget "$TMP/remote.json" repository)"
}

DEFAULT=""; PR=""; SOURCE=""; TITLE=""; DESC=""; MESSAGE=""; NO_MERGE=0; BYPASS=0
[ $# -ge 1 ] || usage
MODE="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --default) [ $# -ge 2 ] || usage; DEFAULT="$2"; shift 2 ;;
        --pr) [ $# -ge 2 ] || usage; PR="$2"; shift 2 ;;
        --source) [ $# -ge 2 ] || usage; SOURCE="$2"; shift 2 ;;
        --title) [ $# -ge 2 ] || usage; TITLE="$2"; shift 2 ;;
        --description-file) [ $# -ge 2 ] || usage; DESC="$2"; shift 2 ;;
        --message) [ $# -ge 2 ] || usage; MESSAGE="$2"; shift 2 ;;
        --no-merge) NO_MERGE=1; shift ;;
        --bypass-reviewers) BYPASS=1; shift ;;
        *) usage ;;
    esac
done
[[ "$DEFAULT" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || usage
case "$MODE" in
    find) ;;
    open) [ -n "$TITLE" ] && [ -f "$DESC" ] && [[ "$SOURCE" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || usage ;;
    merge) [[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage ;;
    *) usage ;;
esac

[ "$MODE" != merge ] || ARMED=1
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
load_remote || { [ "$MODE" = merge ] && finish failed; exit 1; }

if [ "$MODE" = find ]; then
    azj repos pr list --org "$ORG" --project "$PROJECT" --repository "$REPOSITORY" \
        --status active --target-branch "$DEFAULT" --top 1000 > "$TMP/list.json"
    node "$AZURE" find-archive "$TMP/list.json"
    exit 0
fi

if [ "$MODE" = open ]; then
    azj repos pr create --org "$ORG" --project "$PROJECT" --repository "$REPOSITORY" \
        --source-branch "$SOURCE" --target-branch "$DEFAULT" --title "$TITLE" \
        --description "$(cat "$DESC")" > "$TMP/created.json"
    id="$(jget "$TMP/created.json" pullRequestId)"
    [[ "$id" =~ ^[1-9][0-9]*$ ]] || { echo "sdd-azure-pr: az repos pr create printed no PR id" >&2; exit 1; }
    echo "pr=$id"
    exit 0
fi

# --- merge -------------------------------------------------------------------------------
POLL="$(wait_secs SDD_AZ_POLL 10)"

# Reads the PR into $TMP/pr.json and runs `sdd-azure.mjs pr` on it; sets HEAD_SHA, SOURCE_REF,
# REPO_ID and PROJECT_ID. Returns 0 ok, 4 wait, 1 refused.
read_pr() {
    azj repos pr show --org "$ORG" --id "$PR" > "$TMP/pr.json" || return 3
    local status=0
    node "$AZURE" pr --default "$DEFAULT" --project "$PROJECT" --repository "$REPOSITORY" \
        "$TMP/pr.json" > "$TMP/pr.out" || status=$?
    if [ $status -eq 0 ]; then
        HEAD_SHA="$(sed -n 's/^head=//p' "$TMP/pr.out")"
        SOURCE_REF="$(sed -n 's/^source=//p' "$TMP/pr.out")"
        REPO_ID="$(sed -n 's/^repository_id=//p' "$TMP/pr.out")"
        PROJECT_ID="$(sed -n 's/^project_id=//p' "$TMP/pr.out")"
    fi
    return $status
}

# Reads the policy evaluations into $TMP/policies.json and judges them; sets POLICIES.
read_policies() {
    azj repos pr policy list --org "$ORG" --id "$PR" --top "$POLICY_PAGE" > "$TMP/policies.json" || return 3
    local count
    count="$(node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String((Array.isArray(v) ? v : v.value || []).length))' "$TMP/policies.json")"
    if [ "$count" -ge "$POLICY_PAGE" ]; then
        say "the PR has $count or more policy evaluations: too many to read as one complete list"
        return 1
    fi
    node "$AZURE" policies "$TMP/policies.json" > "$TMP/policies.out" || true
    POLICIES="$(sed -n 's/^policies=//p' "$TMP/policies.out")"
    [ -n "$POLICIES" ] || return 3
}

tip() {
    git -C "$ROOT" ls-remote origin "refs/heads/$DEFAULT" | cut -f1
}

# 1. A clean checkout of the default branch's tip.
TIP="$(tip)"
[ -n "$TIP" ] || { say "cannot read origin's $DEFAULT"; finish failed; }
if [ "$(git -C "$ROOT" rev-parse HEAD)" != "$TIP" ] || [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    say "run this from a clean checkout of $DEFAULT's tip ($TIP): its scripts and settings judge the PR"
    finish failed
fi

# 2. The PR, once its merge is computed.
waited=0
limit="$(wait_secs SDD_AZ_WAIT_MERGE 120)"
while :; do
    status=0
    read_pr || status=$?
    [ $status -ne 3 ] || { say "az repos pr show failed"; finish failed; }
    [ $status -ne 1 ] || { sed '/^pr=/d' "$TMP/pr.out"; finish refused; }
    [ $status -eq 4 ] || break
    if [ $waited -ge "$limit" ]; then
        say "the PR's merge was still being computed after ${limit}s"
        finish timeout
    fi
    sleep "$POLL"; waited=$((waited + POLL))
done
say "PR $PR: head $HEAD_SHA from $SOURCE_REF"

# 3. Its head, based on the tip.
git -C "$ROOT" fetch -q --no-tags origin "+$SOURCE_REF:refs/sdd/archive-head" || { say "cannot fetch $SOURCE_REF"; finish failed; }
if [ "$(git -C "$ROOT" rev-parse refs/sdd/archive-head)" != "$HEAD_SHA" ]; then
    say "$SOURCE_REF is no longer $HEAD_SHA: someone pushed. Run again"
    finish refused
fi
if ! git -C "$ROOT" merge-base --is-ancestor "$TIP" "$HEAD_SHA"; then
    say "the PR's branch is behind $DEFAULT ($TIP): merge $DEFAULT into it, push, and run again"
    finish behind
fi

# Everything from here judges this commit; a later read of the PR never replaces it.
VERIFIED="$HEAD_SHA"

# 4. The gate: verify, with this checkout's scripts.
# Exit 0 also means not-an-archive-pr: only the success line itself lets it through.
verify_out="$(bash "$SCRIPT_DIR/sdd-archive.sh" verify -C "$ROOT" --base "$TIP" --result "$HEAD_SHA" 2>&1)" || true
printf '%s
' "$verify_out"
if [ "$(printf '%s
' "$verify_out" | tail -n 1)" != "archive-mechanical: success" ]; then
    say "verify did not pass: this is not a mechanical archive of $DEFAULT. Report the lines above and leave the PR to its owner"
    finish refused
fi

# 5. Stop before merging?
auto="$(node "$SCRIPT_DIR/sdd-config.mjs" autoMerge)" || { say "the sdd settings in package.json are invalid"; finish refused; }
if [ $NO_MERGE -eq 1 ] || [ "$auto" != true ]; then
    say "verified; not completing (--no-merge, or autoMerge is false)"
    finish verified
fi

# 6. The policies, once none is still running.
waited=0
limit="$(wait_secs SDD_AZ_WAIT_POLICIES 1200)"
while :; do
    status=0
    read_policies || status=$?
    [ $status -ne 3 ] || { say "az repos pr policy list failed"; finish failed; }
    [ $status -ne 1 ] || finish refused
    [ "$POLICIES" = pending ] || break
    if [ $waited -ge "$limit" ]; then
        sed '/^policies=/d' "$TMP/policies.out"
        say "a policy was still queued or running after ${limit}s: a manual or expired build needs queueing"
        finish timeout
    fi
    sleep "$POLL"; waited=$((waited + POLL))
done
case "$POLICIES" in
    blocked)
        sed '/^policies=/d' "$TMP/policies.out"
        say "a blocking policy isn't met"
        finish refused ;;
    reviewers)
        if [ $BYPASS -eq 0 ]; then
            sed '/^policies=/d' "$TMP/policies.out"
            say "the PR needs an approval: run again once it has one"
            finish review
        fi ;;
esac

# 7. Read everything again, right before completing.
status=0
read_pr || status=$?
[ $status -eq 0 ] || { sed '/^pr=/d' "$TMP/pr.out" 2>/dev/null || true; say "the PR changed since it was verified: run again"; finish refused; }
status=0
read_policies || status=$?
[ $status -eq 0 ] || finish failed
if [ "$(tip)" != "$TIP" ]; then
    say "$DEFAULT moved since the verify: run again"
    finish behind
fi
set -- --commit "$VERIFIED" --pr "$TMP/pr.json" --policies "$TMP/policies.json"
[ -z "$MESSAGE" ] || set -- "$@" --message "$MESSAGE"
[ $BYPASS -eq 0 ] || set -- "$@" --bypass-reviewers
status=0
node "$AZURE" complete-body "$@" > "$TMP/body.json" || status=$?
if [ $status -ne 0 ]; then
    cat "$TMP/body.json"
    finish refused
fi

# 8. Complete, then confirm what landed.
if ! azj devops invoke --org "$ORG" --area git --resource pullRequests \
        --route-parameters "project=$PROJECT_ID" "repositoryId=$REPO_ID" "pullRequestId=$PR" \
        --http-method PATCH --in-file "$(native_path "$TMP/body.json")" --api-version 7.1 > "$TMP/patched.json" 2> "$TMP/patch.err"; then
    sed 's/^/  | /' "$TMP/patch.err"
    say "the completion was refused (a push since the verify, or no permission to bypass): don't retry with other options"
    finish failed
fi
waited=0
limit="$(wait_secs SDD_AZ_WAIT_COMPLETE 120)"
while :; do
    azj repos pr show --org "$ORG" --id "$PR" > "$TMP/done.json" || { say "az repos pr show failed"; finish failed; }
    [ "$(jget "$TMP/done.json" status)" != completed ] || break
    if [ $waited -ge "$limit" ]; then
        say "the completion was still queued after ${limit}s (merge status $(jget "$TMP/done.json" mergeStatus)): check the PR"
        finish timeout
    fi
    sleep "$POLL"; waited=$((waited + POLL))
done
merged_source="$(jget "$TMP/done.json" lastMergeSourceCommit.commitId)"
merged_target="$(jget "$TMP/done.json" lastMergeTargetCommit.commitId)"
say "completed: source $merged_source, target $merged_target"
if [ "$merged_source" != "$VERIFIED" ] || [ "$merged_target" != "$TIP" ]; then
    say "UNVERIFIED: it completed with source $merged_source and target $merged_target, but $VERIFIED was verified against $TIP. The owner must review what landed"
    finish unverified
fi
finish completed
