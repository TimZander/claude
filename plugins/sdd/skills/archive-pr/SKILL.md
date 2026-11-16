---
name: archive-pr
description: Archive the active OpenSpec changes in their own PR and merge it once it is shown to be mechanical (on GitHub or Azure DevOps). Use before starting new work when openspec/changes/ holds an active change, or right after a change's PR merges.
argument-hint: "[--no-merge]"
---

# Archive PR

A change is archived after its PR merges, in a PR that holds only `openspec archive` output.
Such a PR merges without review once it is shown to be mechanical against the current tip of
the default branch. The scripts do the work; you decide and report.

How it is shown depends on the host (`host` below):
- **GitHub:** the `sdd-checks` job shows `archive-mechanical: success`, any extra verdicts the
  repository names pass, and the same check passes when you re-run it yourself (Step 3).
- **Azure DevOps:** a PR build runs the PR's own pipeline YAML and scripts, so its verdict is
  advisory. The gate is your own re-run with the default branch's scripts, then a completion
  pinned to the commit you verified, within the branch's policies (Step 3A).

## Step 0: The repository's settings

Run `node scripts/sdd/sdd-config.mjs --json` from the default branch's checkout. The settings
that matter here:
- `host`: `github` (the default) or `azure-devops`. It picks Step 3 or Step 3A, and the tools
  you use: `gh` on GitHub; on Azure DevOps, `az` with the `azure-devops` extension, signed in
  (`az account show`), and `node scripts/sdd/sdd-azure.mjs remote` for the organization,
  project and repository to pass to every `az repos` call.
- `archiveVerdicts` (GitHub): more verdicts that must be `success` before merging, each a
  workflow file and a verdict line name (for example a repository's own pin check).
- `autoMerge`: when `false`, stop before merging (as with `--no-merge`) and leave the merge to
  the owner.
- `archiveBypassReviewers` (Azure DevOps): whether you may complete a verified archive PR past a
  "Minimum number of reviewers" policy (Step 3A). Off unless the repository turned it on.

If the command fails, the settings are invalid: report its message and don't merge.

## Step 1: Is there anything to archive?

1. Find the default branch (`git symbolic-ref refs/remotes/origin/HEAD`, else `main`), fetch it,
   and check whether an archive PR is already open: a PR **from a branch of this repository**
   (not a fork) whose branch starts with `archive/` or whose title starts with "Archive". If one
   is open, go to Step 3 (3A on Azure DevOps) with it; never open a second. Never adopt a PR
   from a fork: its author controls its workflows. On Azure DevOps, list them with
   `az repos pr list --status active --target-branch <default> -o json` and skip any with a
   `forkSource`.
2. From a clean tree on the updated default branch, run
   `bash scripts/sdd/sdd-archive.sh active`. If it prints nothing, there's nothing to archive:
   say so and stop.

## Step 2: Archive and open the PR

1. Create a branch `archive/<first-change>[-and-more]` from the default branch.
2. Run `bash scripts/sdd/sdd-archive.sh run`. It archives every active change in name order and
   stops at the first failure. On failure, report its output and stop: an archive that fails is
   a spec problem for its change, not something to fix in the archive PR.
3. Confirm only `openspec/` changed (`git status --porcelain`), and commit:
   `Archive <change>[, <change>…]`.
4. Verify locally before pushing:
   `bash scripts/sdd/sdd-archive.sh verify --base <default> --result HEAD`. It must end with
   `archive-mechanical: success`. A failure naming a stale pin means two changes edited the same
   requirement: the second one's delta was written against older text. Don't hand-merge it in
   the archive PR silently; report it, because that PR then needs the owner's review.
   Unfinished tasks don't fail it: each change with any gets a `- note: ` line. Never tick them
   in the archive PR, which must hold only `openspec archive` output; the change is archived as
   it merged.
5. Push and open the PR against the default branch, titled `Archive <changes>`, its body listing
   the changes and saying it holds only `openspec archive` output. If verify printed any
   `- note: ` lines, add them under **Unfinished tasks**, verbatim, so the record shows what was
   left undone. On Azure DevOps: `az repos pr create --source-branch <branch> --target-branch
   <default> --title "Archive <changes>" --description <lines>`, with no `--auto-complete`
   (auto-complete isn't pinned to a commit).

## Step 3 (GitHub): Wait for the verdicts, then merge

1. **Find the right run.** List the workflow runs for the PR's head commit and accept only one
   whose workflow **path** is `.github/workflows/sdd-checks.yml`, whose **event** is
   `pull_request_target`, and whose `head_sha` is the PR's current head. Any other run, even one
   named `sdd-checks` with a `checks` job, could come from a workflow the PR itself added, and
   its verdict means nothing. Wait for that run to finish.
2. **Read its verdict.** You can't read commit statuses: read the `checks` job's log through the
   Actions API (or `gh run view --log`), save it to a file unedited, and run
   `bash scripts/sdd/sdd-archive.sh verdict <log-file>`. It counts only whole verdict lines, and
   accepts `success` only right after the `- compared base` line; `verdict=none` means no
   trustworthy verdict, so don't merge.
3. **Read each extra verdict** from `archiveVerdicts` the same way: a run of that workflow file,
   event `pull_request_target`, for the PR's head commit; then
   `bash scripts/sdd/sdd-archive.sh verdict --line <line> <log-file>`. Each must be
   `verdict=success`.
4. If `verdict=success`, compare `base=` with the default branch's current tip
   (`git ls-remote origin <default>`). If they differ, the default branch moved after the job
   ran, and a re-run replays the old merge commit: update the PR branch from the default
   branch, push, and wait for the new verdicts.
5. **Re-run the check yourself** before merging, with the default branch's scripts, never the
   PR's: in a clean checkout of the default branch's tip, with its dependencies installed by
   `npm ci --ignore-scripts`, fetch the PR head (`git fetch origin pull/<n>/head`) and run
   `bash scripts/sdd/sdd-archive.sh verify --base <default tip> --result FETCH_HEAD`. It must end
   with `archive-mechanical: success` too. This doesn't depend on CI at all, so a forged or
   misread log can't merge the PR on its own.
6. If every verdict is `success`, the base is the current tip and your re-run passed, merge the
   PR **pinned to the head commit you verified** (the merge API's `sha`, or
   `gh pr merge --match-head-commit <sha>`), so a push after your checks makes the merge fail
   instead of merging unchecked commits. Merge without waiting for other jobs or review, unless `--no-merge` was given, `autoMerge` is
   `false`, or the user asked to merge themselves.
7. Otherwise don't merge: report the lines above each verdict that failed. The owner reviews the
   PR.

## Step 3A (Azure DevOps): Verify, then complete pinned to the verified commit

There is no trustworthy CI verdict to read here, so nothing in this step reads one. Pass the
organization, project and repository from `sdd-azure.mjs remote` to every `az` call.

1. **Read the PR.** `az repos pr show --id <n> -o json | node scripts/sdd/sdd-azure.mjs pr
   --default <default>` must print `head=<sha>` and `source=<ref>`. Otherwise its `- ` lines
   say why not: not active, a draft, from a fork, into another branch, or a merge conflict.
   Stop and report them.
2. **Re-run the check yourself**, with the default branch's scripts, never the PR's: in a clean
   checkout of the default branch's tip, with its dependencies installed by
   `npm ci --ignore-scripts`, fetch the PR's source branch (`git fetch origin <source>`),
   confirm `FETCH_HEAD` is `<head>` (if not, someone pushed: start this step again), and run
   `bash scripts/sdd/sdd-archive.sh verify --base <default tip> --result <head>`. It must end
   with `archive-mechanical: success`. Note the default tip you verified against.
3. **Read the policies.** `az repos pr policy list --id <n> -o json | node
   scripts/sdd/sdd-azure.mjs policies`. Its last line is `policies=<state>`:
   - `pending`: a build or status is still running, often the advisory `sdd-checks` pipeline.
     Wait and read again (back off; give up after about 20 minutes and report).
   - `blocked`: a blocking policy failed or isn't met. A failed `sdd-checks` build means
     something is wrong even though your re-run passed: compare the two, and report rather than
     merge.
   - `reviewers`: only "Minimum number of reviewers" stands between the PR and completion.
     Continue only if `archiveBypassReviewers` is `true`. Otherwise leave the PR open and report
     that it needs one approval, after which running `/sdd:archive-pr` again completes it.
     **Never approve or vote on the PR yourself**, and never bypass on your own judgment.
   - `approved`: continue.
4. **Check the base hasn't moved.** `git ls-remote origin refs/heads/<default>` must still be the
   tip you verified against. If it moved, merge the default branch into the PR's branch, push,
   and start this step again: a re-run against the old tip says nothing about the new one.
5. **Complete, pinned.** Stop here instead if `--no-merge` was given, `autoMerge` is `false`, or
   the user asked to merge themselves. Otherwise build the body with
   `az repos pr policy list --id <n> -o json | node scripts/sdd/sdd-azure.mjs complete-body
   --commit <head> --policies - --message "Archive <changes>"`, adding `--bypass-reviewers`
   only when step 3 said `reviewers`. It re-reads the policies and refuses (a
   `- not completing:` line) unless they allow it, so a stale decision never completes the PR.
   Write the body to a temporary file and send it with `az devops invoke --area git --resource
   pullRequests --route-parameters project=<project> repositoryId=<repository>
   pullRequestId=<n> --http-method PATCH --in-file <file> --api-version 7.1 -o json`. The body
   names `<head>` as `lastMergeSourceCommit`, the commit Azure DevOps is asked to complete, so a
   push after your re-run should make the call fail instead of merging unchecked commits; step
   6 checks that it did. The bypass,
   when used, skips every policy, which is why `complete-body` allows it only when nothing but
   the reviewer count is unmet. It needs the "Bypass policies when completing pull requests"
   permission; without it the call fails: report that.
6. **Confirm.** `az repos pr show --id <n> -o json`: `status` is `completed` and
   `lastMergeSourceCommit.commitId` is `<head>`. If it completed with any other commit,
   unverified commits merged: say so first in the report, so the owner reviews what landed. If
   the call failed, report its message and don't retry with other options.

## Step 4: Report

The PR link, the changes archived, any unfinished tasks noted, each verdict and the base it was
compared against (on Azure DevOps: the policy state, and whether a reviewer bypass was used),
your own re-run's result, and whether it merged. Then the next work can branch from the updated default
branch.
