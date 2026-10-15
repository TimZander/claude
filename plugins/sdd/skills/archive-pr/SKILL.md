---
name: archive-pr
description: Archive the active OpenSpec changes in their own PR and merge it once CI shows the archive is mechanical. Use before starting new work when openspec/changes/ holds an active change, or right after a change's PR merges.
argument-hint: "[--no-merge]"
---

# Archive PR

A change is archived after its PR merges, in a PR that holds only `openspec archive` output.
Such a PR merges without review once the `sdd-checks` job shows `archive-mechanical: success`
against the current tip of the default branch, any extra verdicts the repository names pass,
and the same check passes when you re-run it yourself. The scripts do the work; you decide and
report.

## Step 0: The repository's settings

Run `node scripts/sdd/sdd-config.mjs --json` from the default branch's checkout. Two settings
matter here:
- `archiveVerdicts`: more verdicts that must be `success` before merging, each a workflow file
  and a verdict line name (for example a repository's own pin check).
- `autoMerge`: when `false`, stop before merging (as with `--no-merge`) and leave the merge to
  the owner.

If the command fails, the settings are invalid: report its message and don't merge.

## Step 1: Is there anything to archive?

1. Find the default branch (`git symbolic-ref refs/remotes/origin/HEAD`, else `main`), fetch it,
   and check whether an archive PR is already open: a PR **from a branch of this repository**
   (not a fork) whose branch starts with `archive/` or whose title starts with "Archive". If one
   is open, go to Step 3 with it; never open a second. Never adopt a PR from a fork: its author
   controls its workflows.
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
5. Push and open the PR against the default branch, titled `Archive <changes>`, its body listing
   the changes and saying it holds only `openspec archive` output.

## Step 3: Wait for the verdicts, then merge

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
   PR without waiting for other jobs or review, unless `--no-merge` was given, `autoMerge` is
   `false`, or the user asked to merge themselves.
7. Otherwise don't merge: report the lines above each verdict that failed. The owner reviews the
   PR.

## Step 4: Report

The PR link, the changes archived, each verdict and the base it was compared against, your own
re-run's result, and whether it merged. Then the next work can branch from the updated default
branch.
