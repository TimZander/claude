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
  advisory. The gate is your own re-run with the default branch's scripts. The completion then
  names the commit you verified, and is confirmed afterwards (Step 3A).

## Step 0: The repository's settings

Run `node scripts/sdd/sdd-config.mjs --json` from the default branch's checkout. The settings
that matter here:
- `host`: `github` (the default) or `azure-devops`. It picks Step 3 or Step 3A, and the tools
  you use: `gh` on GitHub; on Azure DevOps, `az` with the `azure-devops` extension, signed in
  (`az devops` with a login or a PAT), through `scripts/sdd/sdd-azure-pr.sh`. If the origin is
  on Azure DevOps (`dev.azure.com`, `*.visualstudio.com`) but `host` says `github`, or
  `scripts/sdd/sdd-azure-pr.sh` is missing, the repository's sdd files predate Azure DevOps
  support, or were set up for GitHub on purpose: ask the owner. If `package.json` records
  `"host": "github"`, `/sdd:init` keeps it, so the owner changes that setting first (or runs
  `/sdd:init --host azure-devops` once it's gone); otherwise re-running `/sdd:init` moves the
  repository to Azure DevOps. Then stop.
- `archiveVerdicts` (GitHub): more verdicts that must be `success` before merging, each a
  workflow file and a verdict line name (for example a repository's own pin check).
- `autoMerge`: when `false`, stop before merging (as with `--no-merge`) and leave the merge to
  the owner.
- `archiveBypassReviewers` (Azure DevOps): whether you may complete a verified archive PR past a
  "Minimum number of reviewers" policy (Step 3A). Off unless the repository turned it on.

If the command fails, the settings are invalid: report its message and don't merge.

## Step 1: Is there anything to archive?

1. Find the default branch (`git symbolic-ref refs/remotes/origin/HEAD`, else `main`; on Azure
   DevOps, where a clone's `origin/HEAD` can be stale, check it against `az repos show --org <org>
   --project <project> --repository <repository> --query defaultBranch`), fetch it,
   and check whether an archive PR is already open: a PR **from a branch of this repository**
   (not a fork) whose branch starts with `archive/` or whose title starts with "Archive". If one
   is open, go to Step 3 (3A on Azure DevOps) with it; never open a second. Never adopt a PR
   from a fork: its author controls its workflows. On Azure DevOps,
   `bash scripts/sdd/sdd-azure-pr.sh find --default <default>` lists them (`pr=<id>`, or
   `pr=none`).
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
   left undone. On Azure DevOps, write the body to a file and run `bash
   scripts/sdd/sdd-azure-pr.sh open --default <default> --source <branch> --title "Archive
   <changes>" --description-file <file>`; it prints `pr=<id>`, and never sets auto-complete
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

There is no trustworthy CI verdict to read here, so nothing in this step reads one: the PR
build ran the PR's own scripts. `scripts/sdd/sdd-azure-pr.sh merge` does the whole step, and
you act on its last line. Run it **from a clean checkout of the default branch's tip**, with its
dependencies installed by `npm ci --ignore-scripts`: that checkout's scripts and `package.json`
judge the PR, never the PR's own. `merge` refuses to run anywhere else.

```
bash scripts/sdd/sdd-azure-pr.sh merge --default <default> --pr <n> --message "Archive <changes>"
```

Add `--no-merge` when it was given, or when the user asked to merge themselves. Add
`--bypass-reviewers` only on a second run, after a first one ended `review`, and only when
`archiveBypassReviewers` is `true`.

In order, it: checks the OpenSpec CLI in `node_modules` is the one the checkout's
`package-lock.json` pins (`node_modules` is ignored, so a clean checkout can still hold what a
PR branch's `npm ci` installed; on a mismatch it ends `failed` and asks for
`npm ci --ignore-scripts`); reads the PR (`sdd-azure.mjs pr`: this repository, not a fork, no auto-complete,
a safely named source branch, into the default branch, no conflict; it waits while the merge is
being computed, or while the PR still names an older head than its branch); checks the head is
based on the default branch's tip; runs `sdd-archive.sh verify` against that tip, and goes on
only on `archive-mechanical: success`; reads the policies, waiting while a build is queued or
running; reads the PR, its policies, the branch's policy configurations and the tip again right
before completing, and goes on only if the tip is still the verified one and Azure DevOps
computed the PR's merge against it (`lastMergeTargetCommit`: the API pins only the source);
completes with the body `sdd-azure.mjs complete-body` builds, through a PATCH
to the repository's `pullrequests/<id>`; and reads the PR until it is completed, confirming both
the source and the target commit it merged. The body is pinned to the verified head as
`lastMergeSourceCommit`, names the merge strategy the branch's "Require a merge strategy"
policies allow (squash first: it lands one commit, so the branch's intermediate commits, which
verify doesn't judge, stay out of the history; a policy that forbids squash brings them along),
and deletes the
source branch, as an archive branch has no further use. No completion goes past a reviewer who
voted Reject or Waiting for author, or a required reviewer who hasn't approved.

Act on its last line, `archive-pr: <state>`:
- `completed`: merged. Report it.
- `verified`: the archive is mechanical, and it stopped before completing, as asked.
- `behind`: the PR's branch is behind the default branch, the tip moved during the run, or the
  PR's merge was being recomputed or was computed against another commit than the verified tip
  (the default branch moved, or `origin` is a mirror that lags Azure DevOps). If the branch is behind, merge the default branch into it and
  push; then run it again.
- `review`: only "Minimum number of reviewers" is unmet. Leave the PR open and report that it
  needs one approval; after it, running `/sdd:archive-pr` again checks everything again, and
  completes the PR if it still may. **Never approve or vote on the PR yourself.** If
  `archiveBypassReviewers` is `true`, you may run it again with `--bypass-reviewers`: it then
  bypasses only when the reviewer count is still the only unmet blocking policy and no reviewer
  stands against the PR. The bypass skips every policy at the moment Azure DevOps completes,
  so anything that changes in the seconds after its last read is bypassed too; say in the report
  that it was used. It needs the "Bypass policies when completing pull requests" permission.
- `refused`: report the `- ` lines above it. A failed verify means the PR isn't a mechanical
  archive of the default branch: the owner reviews it. A failed or expired `sdd-checks` build,
  a vote against, or another unmet policy (Required reviewers, a linked work item, comments, a
  status) is the owner's to resolve; it is refused at once, since waiting won't meet it.
- `timeout`: Azure DevOps was still computing something (a merge, a build, the completion).
  A build that never starts may need queueing by hand. Report it; run again later.
- `unverified`: it completed with a source or target commit other than the ones verified. Say
  so first in the report, so the owner reviews what landed.
- `failed`: report the lines above it. Don't retry a refused completion with other options.

The pin rests on Azure DevOps refusing a completion whose `lastMergeSourceCommit` isn't the
PR's current head; no test here can exercise that, which is why the final confirmation exists.
The target has no pin at all: a push to the default branch in the seconds between the last read
and the completion lands the PR on a target nobody verified, and only that confirmation
(`unverified`) catches it.

## Step 4: Report

The PR link, the changes archived, any unfinished tasks noted, your own re-run's result and
the base it was compared against, and whether it merged. On GitHub, each verdict too. On Azure
DevOps, the last state `sdd-azure-pr.sh` printed, whether a reviewer bypass was used, and the
completed source and target commits. Then the next work can branch from the updated default
branch.
