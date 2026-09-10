---
name: mutation-test
description: Mutation-test a change set — break the changed source in targeted ways, run the suite after each break, and report which mutations survived, because a surviving mutation is a test that passes against broken code
argument-hint: "[--base <branch> | <file>...] [--test-cmd \"<command>\"] [--rerun-caught] [--verify-green] [--timeout <seconds>] [--exclude <glob>] [--allow-dirty]"
allowed-tools: Bash, Read, Edit, Grep, Glob, AskUserQuestion
user-input: optional
disable-model-invocation: true
model: opus
---

You are mutation-testing a change set. The question you are answering is not "do the tests pass?" but **"would the tests notice if this code were wrong?"** You answer it by breaking the code on purpose, one targeted break at a time, and reporting every break the suite failed to catch. A surviving mutation is a test that passes against broken code — that is the finding, and it is the deliverable.

Reading tests does not reveal this. Mutating does. Tests whose own docstrings assert exactly the behaviour they fail to pin are common, and they look fine on the page.

A bundled script owns the destructive and verification steps — backup, restore, and the byte-identical proof — because those are the steps that get skipped near the end of a long campaign, and skipping them is how a mutation ships. **You** own the part a script cannot do: choosing mutations that match what the change actually claims to do.

**Report only what you observed.** The script classifies each run as `caught`, `survived`, `flaky`, `timeout`, or `error`. Only the first two are verdicts. The rest mean nothing was proven, and must be relayed as inconclusive — never rounded to a catch. A harness that cannot tell "survived" from "never ran" is the same defect as the vacuous tests it exists to find.

## Step 0: Parse arguments

- `--base <branch>` — mutate the files changed versus `<branch>`. Default when nothing else is given: `main` (fall back to `master` if `main` does not exist).
- `<file>...` — one or more explicit paths to mutate instead of, or in addition to, the diff.
- `--test-cmd "<command>"` — the command that runs the suite. Exit 0 must mean green.
- `--timeout <seconds>` — per-run wall-clock cap. Default 600.
- `--exclude <glob>` — drop resolved targets matching the glob. Repeatable.
- `--rerun-caught` — re-run every caught result once to filter flaky failures. Turn this on for any suite with known intermittency.
- `--verify-green` — re-run the suite after each restore, proving the tree is green again before the next mutation so failures cannot cascade. Doubles the campaign's cost; `finish` does this once regardless.
- `--allow-dirty` — proceed with uncommitted changes (see Step 2).

If `--test-cmd` is not supplied, infer a candidate from the repository (`package.json` scripts, `pytest.ini`/`pyproject.toml`, `*.csproj`, `Cargo.toml`, `Makefile`, a `scripts/test.sh`) and **confirm it with the user via AskUserQuestion before running anything**. You are about to run their suite dozens of times; guessing wrong wastes a long campaign. In the same question, ask two things that change the outcome:

- Is the suite known to be flaky? If so, recommend `--rerun-caught`.
- Does the suite modify tracked files (snapshot updating, a formatter with `--fix`, codegen)? If so, say plainly that mutation testing is unreliable against it — the suite can overwrite a mutation mid-run — and stop rather than produce results you cannot trust.

## Step 1: Locate the bundled script

Use Glob with the pattern `**/mutation-test/**/mutation-test.sh` rooted at the user's plugin directory (`~/.claude/plugins`, with `~` resolved to an absolute path).

If Glob returns multiple candidates, skip any whose version directory (the parent of `scripts/`) contains a `.orphaned_at` marker (check with Read). **Do not assume the ordering is meaningful** — it is not sorted by modification time, and an install can include a `vendored/` or `marketplaces/` copy that the `.orphaned_at` convention does not cover, sometimes as a stub of a few bytes. Prefer the largest remaining candidate, then confirm the choice by running `bash <SCRIPT> --help` and checking it prints usage. If none remain or none work, tell the user the plugin may need reinstalling and stop.

Refer to the resolved path as `<SCRIPT>` below.

## Step 2: Begin the session

```bash
bash <SCRIPT> begin --test-cmd "<command>" --base "<branch>" [--file <path>]... \
  [--exclude <glob>]... [--timeout <seconds>] [--rerun-caught] [--verify-green] \
  [--session-dir <dir>]
```

Capture from stdout:
- `SESSION=<dir>` — pass this to every later call. Refer to it as `<SESSION>`. It is printed **before** the baseline runs, so it is available even on a failed start.
- `TARGETS=<n>` — how many files are in play.
- `BASELINE=green` — the suite passed before anything was broken. `BASELINE=red` means it did not.

Diagnostics and `note:` lines go to **stderr**; the `KEY=value` lines go to stdout. Read both — the remediation text for every failure is on stderr.

The script refuses a dirty working tree (exit 4) and aborts on a red baseline (exit 3). Both refusals are correct and neither should be worked around:

- **Dirty tree** — surface it and ask the user to commit or discard. Only pass `--allow-dirty` if they explicitly acknowledge that the baseline is not a known-good state. Their uncommitted work is still protected by the backup, but a survivor could then be an artifact of that work rather than of the mutation.
- **Red baseline** — stop and report it. Every result after a red baseline is meaningless; fix the suite first.

By default the session lives in a temp directory, which also holds every reproduction script the report hands the user. If the campaign's findings need to outlive TMPDIR cleanup, pass `--session-dir <dir>` pointing somewhere durable and **outside the repository**.

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

**Do not mutate test files, fixtures, docs, config, or lockfiles.** Breaking a test produces a guaranteed, meaningless `caught`; breaking a doc produces a guaranteed, meaningless `survived`. `--base` targets everything the diff touched, so drop the rest with `--exclude` — the script prints a note for each target that looks like a test or doc, and for each exclusion, so nothing is dropped silently. Also skip comments, whitespace, and log strings: the suite could not observe them even in principle.

**Prefer mutations that keep the file valid.** A mutation that makes the source unparseable — a broken import, a dropped argument in a statically typed language — produces a `caught` that proves nothing about test coverage; it only proves the code still has to compile. When a mutation could do that, say so when you report the result.

## Step 4: Run each mutation

For each mutation, in order:

1. **Apply it yourself** with Edit, to a file listed in `<SESSION>/targets`. Change exactly one thing. If a mutation needs edits in two places to be coherent, that is fine — but it is still one mutation. **Do not edit files outside the target list**: they are not backed up and will not be restored.
2. **Hand control back to the script:**
   ```bash
   bash <SCRIPT> run --session "<SESSION>" --name "<short-name>" \
     --description "<what this break does, in the change's own terms>"
   ```
   `--name` accepts letters, digits, dot, underscore and hyphen only — no spaces. The script saves the mutated source, a diff, and a `repro.sh`, runs the suite under the timeout, classifies the result, and **restores the file by copying the backup back** before returning. It then proves the restore worked, so you never layer one mutation on top of another.
3. **Read the result** from stdout:
   - `RESULT=caught` — the suite failed. The behaviour is pinned. Check the failure signal in the final report: a mutation that trips an assertion *other* than the one it targeted is not coverage of the behaviour it broke.
   - `RESULT=survived` — the suite passed against broken code. **This is a finding.**
   - `RESULT=flaky` — the two runs disagreed. Inconclusive; not a catch.
   - `RESULT=timeout` — the suite never finished on either attempt. Inconclusive.
   - `RESULT=error` — the test command could not be executed, so the code was never tested. Inconclusive; investigate before continuing.
   - `RESTORED=yes` — the per-mutation proof that the tree was put back. Confirm it on every run; it is the guarantee the whole procedure rests on.
   - `GREEN_AGAIN=yes` — only with `--verify-green`.

**Never restore a mutation yourself with `git checkout --`, `git restore`, or `git stash`.** They also discard the user's uncommitted work in the same file, and the campaign then keeps running against a tree you did not intend, looking green the whole way. Restoring is the script's job, and it does it by copying from a backup held outside the repository.

**On any non-zero exit from `run`, check the tree before continuing.** The script restores on every path it controls, but you applied the mutation before `run` was invoked, so a failure in your own edit step is outside its reach. Specifically:

- **exit 3** — no mutation was actually applied; your Edit did not land. Re-apply and try again.
- **exit 2** — a usage error, including a duplicate or invalid `--name`. The script restores before exiting; fix the argument and re-apply the mutation.
- **exit 5** — the restore failed, or `--verify-green` found the suite red after restoring. **Stop the campaign** and surface the manual `cp` command the script printed on stderr.

## Step 5: Finish and report

```bash
bash <SCRIPT> finish --session "<SESSION>" [--allow-test-artifacts]
```

This prints the full report, verifies the tree, and re-runs the suite once to prove the tree the user is left with is green again. Relay it to the user, leading with the survivors. Include:

1. **The table** — mutation, result, seconds, failure signal, and what it broke.
2. **The survivors**, each with the reproduction command the script emitted. These are the deliverable. Say plainly that `repro.sh` re-applies the mutation and leaves the tree broken, and that its header carries the `cp` line that restores it.
3. **The inconclusive results** — flaky, timed out, or errored — reported as such, never folded into the caught count.
4. **The verification lines**:
   - `TREE_VERIFIED=yes` — every target file is byte-identical to the backup and `git status --porcelain` is unchanged.
   - `TREE_VERIFIED=partial` — target files are byte-identical and no *tracked* file drifted; untracked artifacts were forgiven by `--allow-test-artifacts`.
   - `TREE_VERIFIED=no` — the tree could not be proven clean. `finish` exits 5. Surface the manual restore command.
   - `FINAL_SUITE=green|red|skipped` — whether the restored tree still passes.

If the suite leaves untracked artifacts (caches, coverage) that trip the porcelain check, add `--allow-test-artifacts` **to `finish`** and re-run it — the campaign is not lost, and the flag never forgives a modified tracked file.

For each survivor, say which of these it is rather than asserting a defect:

- **A missing test** — the behaviour is observable at this layer and nothing checks it. Name the test that should exist.
- **A documented gap** — the behaviour is genuinely untestable here (a UI paint, a platform call, a timing window). The honest output is the gap written down, not a contorted test.

If **no** mutation was caught in the whole campaign, treat every survivor as unproven and say so: a green baseline shows the suite passes, not that it can fail. A piped test command without `pipefail` always exits 0 and turns the entire report into false findings. The script prints this warning too — do not relay survivors as findings without addressing it.

Close by telling the user where the session lives and that deleting it (`rm -rf <SESSION>`) invalidates the reproduction commands.

**Stop at the report.** Do not write the missing tests in this run. The survivors are the finding; deciding what to do about them is the user's call, and a report that also rewrites the suite is much harder to trust.

## Rules

- **Never bypass the dirty-tree refusal or the red-baseline abort** without an explicit acknowledgement from the user.
- **Never undo a mutation with git.** Backup-copy restoration is the only mechanism.
- **Never skip `finish`.** The byte-identical proof is the point of the procedure, not a formality.
- **Never report a result you did not observe.** Flaky, timed-out, and errored runs are inconclusive, not catches.
- **No silent caps.** If you mutated only part of the change set, say which part you left out and why.
- **Do not write tests in this run.** Report the survivors and stop.
