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
#       `pr=none`. It reads the list past the first page too, which must be empty: a page
#       Azure DevOps cut shorter than asked for is never read as the whole list.
#
#   bash sdd-azure-pr.sh open  --default <branch> --source <branch> --title <text>
#                              --description-file <file>
#       Opens the PR through the REST API, the description sent as JSON (at most 4000
#       characters), never with auto-complete: it isn't pinned to a commit. Prints `pr=<id>`.
#
#   bash sdd-azure-pr.sh merge --default <branch> --pr <id> [--no-merge] [--bypass-reviewers]
#                              [--message <text>]
#       1. Checks this checkout is clean and at the default branch's tip, and that npm's record
#          of the install in node_modules matches the tip's package-lock.json (sdd-azure.mjs
#          installed), so an OpenSpec CLI that a PR branch's `npm ci` installed isn't the one
#          that verifies. It reads npm's records, not the files: code that rewrote node_modules
#          in place isn't caught. On a mismatch: `npm ci --ignore-scripts --include=dev` here.
#       2. Reads the PR (sdd-azure.mjs pr), and fetches its head into a ref of this run's own,
#          refs/sdd/archive-pr-<id>-<pid>, deleted on exit (see below); waits while the merge is
#          being computed, while the PR still names an older head than its branch, or while
#          its merge was computed against another commit than the tip (lastMergeTargetCommit).
#       3. Checks the head is based on the tip: an archive branch behind the default branch
#          can't be verified against it.
#       4. Runs sdd-archive.sh verify --base <tip> --result <head> from this checkout, and
#          goes on only when its last non-empty line is `archive-mechanical: success` and the
#          one before it `- compared base <tip> with result <head>`. This re-run is the gate:
#          CI on Azure DevOps runs the PR's own scripts. verify unable to run (exit 2 or more:
#          OpenSpec not installed, say) ends `failed`, not a verdict on the PR.
#       5. Stops here with --no-merge or `"autoMerge": false`.
#       6. Reads the policies, waiting while a build is queued or running.
#       7. Right before completing, reads the PR, its policies, the branch's policy
#          configurations and the default branch's tip again, and builds the body with
#          sdd-azure.mjs complete-body: pinned to <head> (lastMergeSourceCommit), with the merge
#          strategy the branch's policies allow, deleting the source branch
#          (`deleteSourceBranch`), and a bypass only as complete-body allows one. A build queued
#          again since step 6 ends `timeout`: run again once it finishes.
#          The API pins only the source, so the target is checked here instead: the tip must
#          still be <tip>, and Azure DevOps must have computed the PR's merge against <tip>
#          (lastMergeTargetCommit). A push to the default branch in the seconds between this
#          read and the PATCH isn't caught until step 8, as `unverified`.
#       8. Completes the PR with a PATCH to the repository's pullrequests/<id> (az rest), then
#          reads it until it is completed, and confirms both the source commit (<head>) and the
#          target commit (<tip>) it merged.
#       Once its arguments are accepted, the last line on every exit path is
#       `archive-pr: <state>`, one of
#         completed    merged, pinned, and both commits confirmed
#         verified     the archive is mechanical; not completed (--no-merge, autoMerge false)
#         behind       the PR's branch is behind the default branch, the tip moved, or the PR's
#                      merge is being recomputed or was computed against another commit: merge
#                      the default branch into the branch if it is behind, push, and run again;
#                      otherwise just run again
#         review       only "Minimum number of reviewers" is unmet, still waiting for approvals:
#                      it needs one (a vote rejecting it is `refused`)
#         refused      the PR can't be adopted, or verify, a reviewer, the policies or the
#                      settings refuse it
#         timeout      still waiting on Azure DevOps (a merge, a build, the completion), or for
#                      the PR's merge to be computed against the tip
#         unverified   completed, but with a source or target commit other than the verified
#                      ones: the owner must review what landed
#         failed       an az call, git, a helper or this checkout failed (node_modules not
#                      installed from the tip's lock file, verify unable to run, for two)
#       Once the PATCH is sent, the verified commit is kept in this repository as the run's
#       ref, named in the output, unless the run ends `completed`: completing deletes the
#       source branch.
#
# Every mode first checks that node and az are installed, and warns when az's azure-devops
# extension isn't (az may install it on first use). open and merge call the REST API with
# `az rest`, which needs `az login`: a PAT alone isn't enough. Options belong to a mode, each
# given once. Branch names follow sdd-azure.mjs's rule: [A-Za-z0-9._/-], starting with a letter
# or digit, without `..`, `//`, a trailing `/` or `.lock`.
#
# Environment: SDD_AZ_WAIT_MERGE (default 120), SDD_AZ_WAIT_POLICIES (1200) and
# SDD_AZ_WAIT_COMPLETE (120) are the longest waits in seconds (0: don't wait); SDD_AZ_POLL (10,
# at least 1) the interval. Each is at most 86400. az runs with PYTHONIOENCODING=utf-8, so
# non-ASCII names reach the helpers intact on Windows, where az otherwise writes in the
# console's code page.
#
# Exit status: 0 completed or verified, or find/open done; 1 any other state, or find/open
# failed (an az call, or a list of open PRs that may be cut short); 2 usage error. No other
# status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AZURE="$SCRIPT_DIR/sdd-azure.mjs"
PAGE=1000
# Azure DevOps' resource id, for az rest's token.
ADO_RESOURCE=499b84ac-1321-427f-aa17-267ca6975798
DESCRIPTION_MAX=4000

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

STATE_PRINTED=0
ARMED=0
TMP=""
ROOT=""
# The ref this run fetches the PR's head into: its own (by PR and process), so it never
# clobbers another run's, one an earlier run kept, or refs/sdd/archive-head from 0.4.1. KEEP_REF
# keeps it past exit, from the PATCH on, unless the run ends `completed`.
HEAD_REF=""
KEEP_REF=0
finish() {
    if [ $KEEP_REF -eq 1 ] && [ "$1" = completed ]; then
        KEEP_REF=0
    elif [ $KEEP_REF -eq 1 ]; then
        say "the verified commit is kept as $HEAD_REF in this repository, since completing deletes the source branch; delete it with \`git update-ref -d $HEAD_REF\` once the PR is settled"
    fi
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
    if [ -n "$HEAD_REF" ] && [ $KEEP_REF -eq 0 ]; then
        git -C "$ROOT" update-ref -d "$HEAD_REF" 2>/dev/null || true
    fi
    if [ $ARMED -eq 1 ] && [ $STATE_PRINTED -eq 0 ]; then
        echo "archive-pr: failed"
        code=1
    fi
    # Only the documented statuses: a command that stopped the script (git's 128, a helper's 3)
    # is a failure, 1.
    case $code in
        0|1|2) ;;
        *) code=1 ;;
    esac
    exit $code
}
trap on_exit EXIT

say() { printf -- '- %s\n' "$*"; }
# A file's lines, quoted, so nothing in them starts a line of ours.
quoted() { [ ! -s "$1" ] || sed 's/^/  | /' "$1"; }

# A JSON field by dotted path, from a file: empty when absent.
jget() {
    node -e '
        let t = require("fs").readFileSync(process.argv[1], "utf8")
        if (t.charCodeAt(0) === 0xfeff) { t = t.slice(1) }
        let v = JSON.parse(t)
        for (const k of process.argv[2].split(".")) { v = v == null ? undefined : v[k] }
        process.stdout.write(v == null ? "" : String(v))
    ' "$1" "$2"
}

# az, with JSON output in UTF-8 (az on Windows otherwise writes in the console's code page,
# which mangles or fails on a non-ASCII name), and no MSYS path conversion of its arguments
# (Git Bash on Windows).
azj() {
    PYTHONIOENCODING=utf-8 MSYS2_ARG_CONV_EXCL='*' az "$@" -o json
}

# A path az (a Windows program under Git Bash) can open.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# An Azure DevOps REST call through az rest: method, URL, [JSON body file].
az_rest() {
    if [ $# -ge 3 ]; then
        azj rest --method "$1" --resource "$ADO_RESOURCE" --url "$2" \
            --headers Content-Type=application/json --body "@$(native_path "$3")"
    else
        azj rest --method "$1" --resource "$ADO_RESOURCE" --url "$2"
    fi
}

# A whole number of seconds from the environment, from $3 to SECS_MAX. At most six digits are
# read, so bash's arithmetic never sees a number too large for it.
SECS_MAX=86400
secs() {
    local v="${!1:-$2}"
    if ! [[ "$v" =~ ^[0-9]{1,6}$ ]] || [ $((10#$v)) -lt "$3" ] || [ $((10#$v)) -gt $SECS_MAX ]; then
        echo "sdd-azure-pr: $1 must be a whole number of seconds, at least $3 and at most $SECS_MAX" >&2
        exit 2
    fi
    printf '%s' $((10#$v))
}

# A branch name sdd-azure.mjs's isSafeRef accepts under refs/heads/: the same rule, in ASCII
# whatever the locale (a range like A-Z can take in other letters elsewhere).
safe_branch() {
    local LC_ALL=C
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
    case "$1" in
        *..*|*//*|*/|*.lock) return 1 ;;
    esac
}

GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# What every mode needs, each with its remedy. A missing extension is only a warning: az can
# install one on first use (extension.use_dynamic_install).
preflight() {
    command -v node >/dev/null 2>&1 || { say "node is not installed: install Node.js, then run again"; return 1; }
    command -v az >/dev/null 2>&1 || { say "az is not installed: install the Azure CLI (https://aka.ms/azcli), run \`az extension add --name azure-devops\` and \`az login\`, then run again"; return 1; }
    azj extension show --name azure-devops > /dev/null 2>&1 \
        || say "warning: az's azure-devops extension is not installed; if an az call below fails, run \`az extension add --name azure-devops\` and run again"
}

load_remote() {
    local remote
    if ! remote="$(cd "$ROOT" && node "$AZURE" remote)"; then
        printf '%s\n' "$remote"
        return 1
    fi
    printf '%s' "$remote" > "$TMP/remote.json"
    # Called as `if ! load_remote`, where set -e is off: each value is checked.
    ORG="$(jget "$TMP/remote.json" organization)"
    PROJECT="$(jget "$TMP/remote.json" project)"
    REPOSITORY="$(jget "$TMP/remote.json" repository)"
    [ -n "$ORG" ] && [ -n "$PROJECT" ] && [ -n "$REPOSITORY" ] \
        || { say "cannot read origin's organization, project and repository"; return 1; }
}

# The repository's and its project's ids, for the REST API.
load_ids() {
    azj repos show --org "$ORG" --project "$PROJECT" --repository "$REPOSITORY" > "$TMP/repo.json" 2> "$TMP/az.err" \
        || { say "az repos show failed:"; quoted "$TMP/az.err"; return 1; }
    REPO_ID="$(jget "$TMP/repo.json" id)"
    PROJECT_ID="$(jget "$TMP/repo.json" project.id)"
    [[ "$REPO_ID" =~ $GUID_RE ]] && [[ "$PROJECT_ID" =~ $GUID_RE ]] || { say "az repos show printed no repository or project id (a GUID)"; return 1; }
}

# The repository's REST URL, with a path and query after it.
repo_url() {
    printf '%s/%s/_apis/git/repositories/%s/%s' "$ORG" "$PROJECT_ID" "$REPO_ID" "$1"
}

DEFAULT=""; PR=""; SOURCE=""; TITLE=""; DESC=""; MESSAGE=""; NO_MERGE=0; BYPASS=0
[ $# -ge 1 ] || usage
MODE="$1"; shift
# The options each mode takes; each may be given once.
case "$MODE" in
    find) OPTIONS=" --default " ;;
    open) OPTIONS=" --default --source --title --description-file " ;;
    merge) OPTIONS=" --default --pr --message --no-merge --bypass-reviewers " ;;
    *) usage ;;
esac
SEEN=" "
while [ $# -gt 0 ]; do
    case "$OPTIONS" in *" $1 "*) ;; *) usage ;; esac
    case "$SEEN" in *" $1 "*) usage ;; esac
    SEEN="$SEEN$1 "
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
safe_branch "$DEFAULT" || usage
case "$MODE" in
    open) [ -n "$TITLE" ] && [ -f "$DESC" ] && safe_branch "$SOURCE" || usage ;;
    merge) [[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage ;;
esac
POLL="$(secs SDD_AZ_POLL 10 1)"
WAIT_MERGE="$(secs SDD_AZ_WAIT_MERGE 120 0)"
WAIT_POLICIES="$(secs SDD_AZ_WAIT_POLICIES 1200 0)"
WAIT_COMPLETE="$(secs SDD_AZ_WAIT_COMPLETE 120 0)"

[ "$MODE" != merge ] || ARMED=1
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
if ! preflight || ! load_remote; then
    [ "$MODE" != merge ] || finish failed
    exit 1
fi

if [ "$MODE" = find ]; then
    list_prs() { # more az arguments
        azj repos pr list --org "$ORG" --project "$PROJECT" --repository "$REPOSITORY" \
            --status active --target-branch "$DEFAULT" "$@"
    }
    list_prs --top "$PAGE" > "$TMP/list.json" 2> "$TMP/az.err" \
        || { say "az repos pr list failed:"; quoted "$TMP/az.err"; exit 1; }
    # In case Azure DevOps returns fewer than --top: the list past this page must be empty. (A
    # full page is refused by find-archive anyway.) The extra options ride in "$@", expanded
    # as ${1+"$@"}: bash 3.2's set -u rejects an empty "$@".
    count="$(jget "$TMP/list.json" length)" || count=""
    set --
    if [[ "$count" =~ ^[1-9][0-9]*$ ]] && [ "$count" -lt "$PAGE" ]; then
        list_prs --skip "$count" --top "$PAGE" > "$TMP/more.json" 2> "$TMP/az.err" \
            || { say "az repos pr list failed:"; quoted "$TMP/az.err"; exit 1; }
        set -- --after "$TMP/more.json"
    fi
    node "$AZURE" find-archive --page-size "$PAGE" ${1+"$@"} "$TMP/list.json" > "$TMP/find.out" 2> "$TMP/helper.err" \
        || { say "sdd-azure.mjs find-archive failed:"; quoted "$TMP/helper.err"; exit 1; }
    cat "$TMP/find.out"
    exit 0
fi

if [ "$MODE" = open ]; then
    load_ids || exit 1
    # A JSON body, so the description reaches Azure DevOps as written, newlines and all. No MSYS
    # conversion of the arguments either (Git Bash on Windows would rewrite a title like
    # `/c/x` as a Windows path): the one path among them is converted here.
    MSYS2_ARG_CONV_EXCL='*' node -e '
        const fs = require("fs")
        const [source, target, title, file, max] = process.argv.slice(1)
        const description = fs.readFileSync(file, "utf8")
        if (description.length > Number(max)) {
            console.error(`the description is ${description.length} characters; Azure DevOps takes at most ${max}`)
            process.exit(1)
        }
        process.stdout.write(JSON.stringify({ sourceRefName: `refs/heads/${source}`, targetRefName: `refs/heads/${target}`, title, description }))
    ' "$SOURCE" "$DEFAULT" "$TITLE" "$(native_path "$DESC")" "$DESCRIPTION_MAX" > "$TMP/create.json" || exit 1
    az_rest post "$(repo_url "pullrequests?api-version=7.1")" "$TMP/create.json" > "$TMP/created.json" 2> "$TMP/az.err" \
        || { say "creating the PR failed:"; quoted "$TMP/az.err"; exit 1; }
    id="$(jget "$TMP/created.json" pullRequestId)"
    [[ "$id" =~ ^[1-9][0-9]*$ ]] || { say "Azure DevOps returned no PR id"; exit 1; }
    echo "pr=$id"
    exit 0
fi

# --- merge -------------------------------------------------------------------------------

# Reads the PR into $TMP/pr.json and runs `sdd-azure.mjs pr` on it; sets HEAD_SHA, TARGET_SHA,
# SOURCE_REF, REPO_ID and PROJECT_ID. Returns 0 ok, 1 refused, 4 wait, 5 az failed, 6 the helper failed.
read_pr() {
    azj repos pr show --org "$ORG" --id "$PR" > "$TMP/pr.json" 2> "$TMP/az.err" || return 5
    local status=0
    node "$AZURE" pr --default "$DEFAULT" --project "$PROJECT" --repository "$REPOSITORY" \
        "$TMP/pr.json" > "$TMP/pr.out" 2> "$TMP/helper.err" || status=$?
    case $status in
        0)
            HEAD_SHA="$(sed -n 's/^head=//p' "$TMP/pr.out")"
            TARGET_SHA="$(sed -n 's/^target=//p' "$TMP/pr.out")"
            SOURCE_REF="$(sed -n 's/^source=//p' "$TMP/pr.out")"
            REPO_ID="$(sed -n 's/^repository_id=//p' "$TMP/pr.out")"
            PROJECT_ID="$(sed -n 's/^project_id=//p' "$TMP/pr.out")"
            return 0 ;;
        1|4) return $status ;;
        *) return 6 ;;
    esac
}

# Says why read_pr's status isn't usable, and finishes. Wait (4) is the caller's.
pr_failed() {
    case $1 in
        1) sed '/^pr=/d' "$TMP/pr.out"; finish refused ;;
        5) say "az repos pr show failed:"; quoted "$TMP/az.err"; finish failed ;;
        *) say "sdd-azure.mjs pr failed:"; quoted "$TMP/helper.err"; finish failed ;;
    esac
}

# Reads the policy evaluations into $TMP/policies.json and judges them; sets POLICIES.
# Returns 0, 5 az failed, 6 the helper failed (bad input, or a page too full to be complete).
read_policies() {
    azj repos pr policy list --org "$ORG" --id "$PR" --top "$PAGE" > "$TMP/policies.json" 2> "$TMP/az.err" || return 5
    local status=0
    node "$AZURE" policies --page-size "$PAGE" "$TMP/policies.json" > "$TMP/policies.out" 2> "$TMP/helper.err" || status=$?
    [ $status -le 1 ] || return 6
    POLICIES="$(sed -n 's/^policies=//p' "$TMP/policies.out")"
    [ -n "$POLICIES" ] || return 6
}

policies_failed() {
    case $1 in
        5) say "az repos pr policy list failed:"; quoted "$TMP/az.err" ;;
        *) say "sdd-azure.mjs policies failed:"; quoted "$TMP/helper.err" ;;
    esac
    finish failed
}

# The default branch's tip on origin, by its exact ref.
tip() {
    local out
    out="$(git -C "$ROOT" ls-remote origin "refs/heads/$DEFAULT")" || return 1
    printf '%s\n' "$out" | awk -v ref="refs/heads/$DEFAULT" '$2 == ref { print $1 }'
}

# 1. A clean checkout of the default branch's tip.
TIP="$(tip)" || { say "cannot read origin's $DEFAULT"; finish failed; }
[ -n "$TIP" ] || { say "origin has no branch $DEFAULT"; finish failed; }
if [ "$(git -C "$ROOT" rev-parse HEAD)" != "$TIP" ] || [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    say "run this from a clean checkout of $DEFAULT's tip ($TIP): its scripts and settings judge the PR"
    finish failed
fi
# node_modules is ignored, so a clean checkout can still hold what a PR branch's `npm ci`
# installed: the CLI that verifies must be the one the tip's lock file pins. The lock is read
# from the tip's commit, not the working tree, which an ignored or skip-worktree file escapes.
# npm ci prefers npm-shrinkwrap.json, so this does too.
lock_name=""
for name in npm-shrinkwrap.json package-lock.json; do
    if git -C "$ROOT" cat-file -e "$TIP:$name" 2>/dev/null; then
        lock_name="$name"
        break
    fi
done
if [ -z "$lock_name" ]; then
    say "$DEFAULT has no package-lock.json, so nothing pins the OpenSpec CLI that would verify: run \`npm install\` with npm 7 or later, commit the lock file, and run again"
    finish failed
fi
git -C "$ROOT" show "$TIP:$lock_name" > "$TMP/lock.json" 2> "$TMP/git.err" \
    || { say "cannot read $DEFAULT's $lock_name:"; quoted "$TMP/git.err"; finish failed; }
status=0
node "$AZURE" installed --lock "$TMP/lock.json" "$ROOT" > "$TMP/installed.out" 2> "$TMP/helper.err" || status=$?
case $status in
    0) ;;
    1)
        sed '/^installed=/d' "$TMP/installed.out"
        say "node_modules was not installed from $DEFAULT's $lock_name, so the OpenSpec CLI that would verify isn't the pinned one: run \`npm ci --ignore-scripts --include=dev\` here, then run again (if the lock itself pins no OpenSpec, fix and commit the lock first)"
        finish failed ;;
    *)
        say "sdd-azure.mjs installed failed:"
        quoted "$TMP/helper.err"
        say "a lock file or install record without \`packages\` comes from npm 6 or lockfileVersion 1: regenerate $lock_name with npm 7 or later and commit it, then run \`npm ci --ignore-scripts --include=dev\` here"
        finish failed ;;
esac

# 2. The PR, once its merge is computed and its head is its branch's.
waited=0
HEAD_REF="refs/sdd/archive-pr-$PR-$$"
while :; do
    status=0
    read_pr || status=$?
    if [ $status -eq 0 ]; then
        git -C "$ROOT" fetch -q --no-tags origin "+$SOURCE_REF:$HEAD_REF" 2> "$TMP/git.err" \
            || { say "cannot fetch $SOURCE_REF:"; quoted "$TMP/git.err"; finish failed; }
        fetched="$(git -C "$ROOT" rev-parse "$HEAD_REF" 2> "$TMP/git.err")" \
            || { say "cannot read the fetched head:"; quoted "$TMP/git.err"; finish failed; }
        if [ "$fetched" != "$HEAD_SHA" ]; then
            # Azure DevOps updates the PR's head a little after a push: read it again.
            waiting_for="the PR to name its branch's head ($fetched; it says $HEAD_SHA)"
        elif [ "$TARGET_SHA" != "$TIP" ]; then
            # And recomputes its merge a little after the default branch moves.
            waiting_for="Azure DevOps to compute the PR's merge against $DEFAULT's tip $TIP (it says $TARGET_SHA; if it never does, $DEFAULT moved, or origin is a mirror that lags Azure DevOps)"
        else
            break
        fi
    elif [ $status -eq 4 ]; then
        waiting_for="the PR's merge to be computed"
    else
        pr_failed $status
    fi
    if [ $waited -ge "$WAIT_MERGE" ]; then
        say "still waiting for $waiting_for after ${WAIT_MERGE}s"
        finish timeout
    fi
    sleep "$POLL"; waited=$((waited + POLL))
done
say "PR $PR: head $HEAD_SHA from $SOURCE_REF"

# 3. Based on the tip.
# --is-ancestor exits 1 for "no"; anything else (128) is git failing, not a branch behind.
status=0
git -C "$ROOT" merge-base --is-ancestor "$TIP" "$HEAD_SHA" 2> "$TMP/git.err" || status=$?
case $status in
    0) ;;
    1)
        say "the PR's branch is behind $DEFAULT ($TIP): merge $DEFAULT into it, push, and run again"
        finish behind ;;
    *)
        say "cannot tell whether the PR's head is based on $DEFAULT's tip (git merge-base exited $status):"
        quoted "$TMP/git.err"
        finish failed ;;
esac

# Everything from here judges this commit; a later read of the PR never replaces it.
VERIFIED="$HEAD_SHA"

# 4. The gate: verify, with this checkout's scripts.
# Exit 0 also means not-an-archive-pr: only the success line itself lets it through.
verify_status=0
verify_out="$(bash "$SCRIPT_DIR/sdd-archive.sh" verify -C "$ROOT" --base "$TIP" --result "$VERIFIED" 2>&1)" || verify_status=$?
printf '%s\n' "$verify_out"
# 2 or more is verify unable to run (a usage error, OpenSpec not installed, git failing), not a
# verdict on the PR.
if [ $verify_status -ge 2 ]; then
    say "verify could not run (sdd-archive.sh exited $verify_status): fix what the lines above say, usually in this checkout, and run again"
    finish failed
fi
# The verdict is the last non-empty line, right after the comparison of exactly these commits.
verdict="$(printf '%s\n' "$verify_out" | awk 'NF { before = last; last = $0 } END { print before; print last }')"
if [ "$verdict" != "$(printf -- '- compared base %s with result %s\narchive-mechanical: success' "$TIP" "$VERIFIED")" ]; then
    say "verify did not pass: this is not a mechanical archive of $DEFAULT. Report the lines above and leave the PR to its owner"
    finish refused
fi

# 5. Stop before merging? (complete-body refuses autoMerge false too; this stops before
# reading the policies, and says so as `verified`.)
auto="$(node "$SCRIPT_DIR/sdd-config.mjs" autoMerge)" || { say "the sdd settings in package.json are invalid"; finish failed; }
if [ $NO_MERGE -eq 1 ] || [ "$auto" != true ]; then
    say "verified; not completing (--no-merge, or autoMerge is false)"
    finish verified
fi

# 6. The policies, once no build is still running.
waited=0
while :; do
    status=0
    read_policies || status=$?
    [ $status -eq 0 ] || policies_failed $status
    [ "$POLICIES" = pending ] || break
    if [ $waited -ge "$WAIT_POLICIES" ]; then
        sed '/^policies=/d' "$TMP/policies.out"
        say "a build was still queued or running after ${WAIT_POLICIES}s: a manual or expired build needs queueing"
        finish timeout
    fi
    sleep "$POLL"; waited=$((waited + POLL))
done
case "$POLICIES" in
    blocked)
        sed '/^policies=/d' "$TMP/policies.out"
        say "a blocking policy isn't met, and waiting won't meet it"
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
if [ $status -eq 4 ]; then
    say "the PR's merge is being recomputed (a push, or $DEFAULT moved): run again"
    finish behind
fi
[ $status -eq 0 ] || pr_failed $status
status=0
read_policies || status=$?
[ $status -eq 0 ] || policies_failed $status
if [ "$POLICIES" = pending ]; then
    sed '/^policies=/d' "$TMP/policies.out"
    say "a build was queued again right before completing: run again once it finishes"
    finish timeout
fi
azj repos policy list --org "$ORG" --project "$PROJECT_ID" --repository-id "$REPO_ID" --branch "$DEFAULT" \
    > "$TMP/merge-policies.json" 2> "$TMP/az.err" \
    || { say "az repos policy list failed:"; quoted "$TMP/az.err"; finish failed; }
now="$(tip)" || { say "cannot read origin's $DEFAULT"; finish failed; }
if [ "$now" != "$TIP" ]; then
    say "$DEFAULT moved since the verify ($TIP, now ${now:-gone}): run again"
    finish behind
fi
# Azure DevOps' own view of the target: the commit it computed the PR's merge against, which
# the completion merges onto. The tip check above reads origin, which can be a mirror (an
# insteadOf rewrite) that lags; this reads Azure DevOps.
# (read_pr has just set TARGET_SHA, a commit id sdd-azure.mjs pr checked the form of.)
if [ "$TARGET_SHA" != "$TIP" ]; then
    say "Azure DevOps computed the PR's merge against $TARGET_SHA, not the verified $TIP: $DEFAULT moved, or Azure DevOps hasn't recomputed the merge yet. Run again (if it keeps saying this while origin's $DEFAULT is $TIP, origin is a mirror that lags Azure DevOps: wait for it, or point origin at Azure DevOps)"
    finish behind
fi
# complete-body checks the target again, as it checks the head: the body is never built for
# another one. The message is text, not a path: no MSYS conversion (Git Bash on Windows) of the
# arguments, the paths among them converted here.
set -- --commit "$VERIFIED" --target "$TIP" --pr "$(native_path "$TMP/pr.json")" \
    --policies "$(native_path "$TMP/policies.json")" --merge-policies "$(native_path "$TMP/merge-policies.json")"
[ -z "$MESSAGE" ] || set -- "$@" --message "$MESSAGE"
[ $BYPASS -eq 0 ] || set -- "$@" --bypass-reviewers
status=0
MSYS2_ARG_CONV_EXCL='*' node "$(native_path "$AZURE")" complete-body "$@" > "$TMP/body.json" 2> "$TMP/helper.err" || status=$?
case $status in
    0) ;;
    1) cat "$TMP/body.json"; finish refused ;;
    *) say "sdd-azure.mjs complete-body failed:"; quoted "$TMP/helper.err"; finish failed ;;
esac

# 8. Complete, then confirm what landed. From here the PR may complete, deleting its source
# branch, whatever this run sees: the verified commit is kept unless it ends `completed`.
KEEP_REF=1
if ! az_rest patch "$(repo_url "pullrequests/$PR?api-version=7.1")" "$TMP/body.json" > "$TMP/patched.json" 2> "$TMP/az.err"; then
    say "Azure DevOps refused the completion:"
    quoted "$TMP/az.err"
    say "don't retry with other options"
    finish failed
fi
waited=0
while :; do
    azj repos pr show --org "$ORG" --id "$PR" > "$TMP/done.json" 2> "$TMP/az.err" \
        || { say "az repos pr show failed:"; quoted "$TMP/az.err"; finish failed; }
    pr_status="$(jget "$TMP/done.json" status)"
    merge_status="$(jget "$TMP/done.json" mergeStatus)"
    [ "$pr_status" != completed ] || break
    if [ "$pr_status" = abandoned ]; then
        say "the PR was abandoned while it was completing"
        finish refused
    fi
    case "$merge_status" in
        rejectedByPolicy|failure|conflicts)
            say "the completion failed: merge status $merge_status"
            finish failed ;;
    esac
    if [ $waited -ge "$WAIT_COMPLETE" ]; then
        say "the completion was still pending after ${WAIT_COMPLETE}s (status $pr_status, merge status $merge_status): check the PR"
        finish timeout
    fi
    sleep "$POLL"; waited=$((waited + POLL))
done
merged_source="$(jget "$TMP/done.json" lastMergeSourceCommit.commitId)"
merged_target="$(jget "$TMP/done.json" lastMergeTargetCommit.commitId)"
say "completed: source $merged_source, target $merged_target, merge strategy $(jget "$TMP/body.json" completionOptions.mergeStrategy)"
if [ "$merged_source" != "$VERIFIED" ] || [ "$merged_target" != "$TIP" ]; then
    say "UNVERIFIED: it completed with source $merged_source and target $merged_target, but $VERIFIED was verified against $TIP. The owner must review what landed"
    finish unverified
fi
finish completed
