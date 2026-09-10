---
name: mutation-test
description: Mutation-test a change set — break the changed source in targeted ways, run the suite after each break, and report which mutations survived, because a surviving mutation is a test that passes against broken code
argument-hint: "[--base <branch> | <file>...] [--test-cmd \"<command>\"] [--rerun-caught] [--timeout <seconds>]"
allowed-tools: Bash, Read, Edit, Grep, Glob, AskUserQuestion
model: opus
---

You are mutation-testing a change set. The question you are answering is not "do the tests pass?" but **"would the tests notice if this code were wrong?"** You answer it by breaking the code on purpose, one targeted break at a time, and reporting every break the suite failed to catch. A surviving mutation is a test that passes against broken code — that is the finding, and it is the deliverable.

Reading tests does not reveal this. Mutating does. Tests whose own docstrings assert exactly the behaviour they fail to pin are common, and they look fine on the page.

A bundled script owns the destructive and verification steps — backup, restore, and the byte-identical proof — because those are the steps that get skipped near the end of a long campaign, and skipping them is how a mutation ships. **You** own the part a script cannot do: choosing mutations that match what the change actually claims to do.

## Step 0: Parse arguments

- `--base <branch>` — mutate the files changed versus `<branch>`. Default when nothing else is given: `main` (fall back to `master` if `main` does not exist).
- `<file>...` — one or more explicit paths to mutate instead of, or in addition to, the diff.
- `--test-cmd "<command>"` — the command that runs the suite. Exit 0 must mean green.
- `--timeout <seconds>` — per-run wall-clock cap. Default 600.
- `--rerun-caught` — re-run every caught result once to filter flaky failures. Turn this on for any suite with known intermittency.

If `--test-cmd` is not supplied, infer a candidate from the repository (`package.json` scripts, `pytest.ini`/`pyproject.toml`, `*.csproj`, `Cargo.toml`, `Makefile`, a `scripts/test.sh`) and **confirm it with the user via AskUserQuestion before running anything**. You are about to run their suite dozens of times; guessing wrong wastes a long campaign. If the suite is known to be flaky, recommend `--rerun-caught` in the same question.

## Step 1: Locate the bundled script

Use Glob with the pattern `**/mutation-test/**/mutation-test.sh` rooted at the user's plugin directory (`~/.claude/plugins`, with `~` resolved to an absolute path).

If Glob returns multiple candidates, skip any whose version directory (the parent of `scripts/`) contains a `.orphaned_at` marker. If none remain, tell the user the plugin may need reinstalling and stop. Otherwise use the first result.

Refer to the resolved path as `<SCRIPT>` below.

## Step 2: Begin the session

```bash
bash <SCRIPT> begin --test-cmd "<command>" --base "<branch>" [--file <path>]... \
  [--timeout <seconds>] [--rerun-caught]
```

Capture from stdout:
- `SESSION=<dir>` — pass this to every later call. Refer to it as `<SESSION>`.
- `TARGETS=<n>` — how many files are in play.
- `BASELINE=green` — the suite passed before anything was broken.

The script refuses a dirty working tree (exit 4) and aborts on a red baseline (exit 3). Both refusals are correct and neither should be worked around:

- **Dirty tree** — surface it and ask the user to commit or discard. Only pass `--allow-dirty` if they explicitly acknowledge that the baseline is not a known-good state. Their uncommitted work is still protected by the backup, but a survivor could then be an artifact of that work rather than of the mutation.
- **Red baseline** — stop and report it. Every result after a red baseline is meaningless; fix the suite first.

## Step 3: Choose the mutations

This is the step that determines whether the campaign is worth anything. Read the actual diff (`git diff <base>...HEAD`) and derive mutations from **what the change claims to do**, not from a generic operator set. A blanket "flip every `>` to `>=`" sweep finds far less than a handful of mutations aimed at the change's own claims.

Productive mutations, in rough order of yield:

- **Invert a new guard** — if the change added `if (!allowed) return;`, drop the negation.
- **Make a new conditional constant** — force the new branch to always take one side. If the suite stays green, that whole branch is untested.
- **Drop a newly-added argument at one call site** — or pass the old value, so the new parameter stops mattering.
- **Revert a changed default** — put the previous default back.
- **Remove a newly-added filter, sort, clamp, or dedupe** — pass the collection straight through.
- **Neuter a new early return or short-circuit** — make the check dead code. If 100+ tests stay green, the mechanism is unpinned.
- **Break the rendering/formatting half** — output-shaping code is routinely tested only for "did it not throw", and mutations there survive at a much higher rate than in logic.

Aim for one mutation per distinct claim the change makes. Default to at most 12 in a single campaign; if the diff warrants more, say so explicitly and offer a second pass rather than silently covering only part of the change.

Do not mutate: comments, whitespace, log strings, or anything the suite could not observe even in principle. Those produce guaranteed survivors that teach nothing.

## Step 4: Run each mutation

For each mutation, in order:

1. **Apply it yourself** with Edit, to a file listed in `<SESSION>/targets`. Change exactly one thing. If a mutation needs edits in two places to be coherent, that is fine — but it is still one mutation.
2. **Hand control back to the script:**
   ```bash
   bash <SCRIPT> run --session "<SESSION>" --name "<short-name>" \
     --description "<what this break does, in the change's own terms>"
   ```
   The script saves the mutated source and a diff for reproduction, runs the suite under the timeout, classifies the result, and **always restores the file by copying the backup back** before returning. It then proves the restore worked, so you never layer one mutation on top of another.
3. **Read the result** from stdout:
   - `RESULT=caught` — the suite failed. The behaviour is pinned.
   - `RESULT=survived` — the suite passed against broken code. **This is a finding.**
   - `RESULT=flaky` — failed once, passed once against the same mutation. Not a catch; nothing was proven.
   - `RESULT=timeout` — the suite never finished. Inconclusive, and the tree was still restored.

**Never restore a mutation yourself with `git checkout --`, `git restore`, or `git stash`.** They also discard the user's uncommitted work in the same file, and the campaign then keeps running against a tree you did not intend, looking green the whole way. Restoring is the script's job, and it does it by copying from a backup held outside the repository.

If `run` exits 3, no mutation was actually applied — your Edit did not land. Re-apply it and try again. If `run` exits 5, the restore failed; stop the campaign immediately and surface the manual `cp` command the script printed.

## Step 5: Finish and report

```bash
bash <SCRIPT> finish --session "<SESSION>"
```

This prints the full report and the verification tail. Relay it to the user, leading with the survivors. Include:

1. **The table** — mutation, result, and what it broke.
2. **The survivors**, each with the reproduction command the script emitted. These are the deliverable.
3. **The verification line** — `TREE_VERIFIED=yes` means every target file is byte-identical to the backup and `git status --porcelain` is unchanged. Say this explicitly; a run that cannot prove it is a failed run, and `finish` exits 5 when it cannot.

If the suite leaves untracked artifacts (caches, coverage files) that trip the porcelain check, re-running `begin` with `--allow-test-artifacts` downgrades that specific drift to a note — target files must still match exactly.

For each survivor, say which of these it is rather than asserting a defect:

- **A missing test** — the behaviour is observable at this layer and nothing checks it. Name the test that should exist.
- **A documented gap** — the behaviour is genuinely untestable here (a UI paint, a platform call, a timing window). The honest output is the gap written down, not a contorted test.

**Stop at the report.** Do not write the missing tests in this run. The survivors are the finding; deciding what to do about them is the user's call, and a report that also rewrites the suite is much harder to trust.

## Rules

- **Never bypass the dirty-tree refusal or the red-baseline abort** without an explicit acknowledgement from the user.
- **Never undo a mutation with git.** Backup-copy restoration is the only mechanism.
- **Never skip `finish`.** The byte-identical proof is the point of the procedure, not a formality.
- **Never report a caught result you did not observe.** If a run timed out or was flaky, report it as inconclusive — a flake reads as a catch and hides a survivor.
- **No silent caps.** If you mutated only part of the change set, say which part you left out and why.
- **Do not write tests in this run.** Report the survivors and stop.
