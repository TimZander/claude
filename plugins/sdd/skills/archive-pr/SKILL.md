---
name: archive-pr
description: Archive the active OpenSpec changes in their own PR and merge it once CI shows the archive is mechanical. Use before starting new work when openspec/changes/ holds an active change, or right after a change's PR merges.
argument-hint: "[--no-merge]"
---

# Archive PR

A change is archived after its PR merges, in a PR that holds only `openspec archive` output.
Such a PR merges without review once the `sdd-checks` job shows `archive-mechanical: success`
against the current tip of the default branch. The scripts do the work; you decide and report.

## Step 1: Is there anything to archive?

1. Find the default branch (`git symbolic-ref refs/remotes/origin/HEAD`, else `main`), fetch it,
   and check whether an archive PR is already open (a PR whose branch starts with `archive/`
   or whose title starts with "Archive"). If one is open, go to Step 3 with it; never open a
   second.
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
   `archive-mechanical: success`.
5. Push and open the PR against the default branch, titled `Archive <changes>`, its body listing
   the changes and saying it holds only `openspec archive` output.

## Step 3: Wait for the verdict, then merge

1. Wait for the `sdd-checks` workflow run on the PR's head commit to finish. You can't read
   commit statuses: read the `checks` job's log through the Actions API (or `gh run view
   --log`), save it to a file, and run `bash scripts/sdd/sdd-archive.sh verdict <log-file>`.
2. If `verdict=success`, compare `base=` with the default branch's current tip
   (`git ls-remote origin <default>`). If they differ, the default branch moved after the job
   ran, and a re-run replays the old merge commit: update the PR branch from the default
   branch, push, and wait for the new verdict.
3. If `verdict=success` and the base is the current tip, merge the PR without waiting for other
   jobs or review, unless `--no-merge` was given or the user asked to merge themselves.
4. If `verdict=failure`, don't merge: report the lines above the verdict. The owner reviews the
   PR.

## Step 4: Report

The PR link, the changes archived, the verdict and the base it was compared against, and
whether it merged. Then the next work can branch from the updated default branch.
