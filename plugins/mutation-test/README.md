# mutation-test

Break the changed code on purpose, run the suite after each break, and report which mutations **survived**. A surviving mutation is a test that passes against broken code.

The question this answers is not "do the tests pass?" but "would the tests notice if this code were wrong?" Reading tests does not reveal the difference — tests whose own docstrings assert exactly the behaviour they fail to pin are common, and they look fine on the page.

## Usage

```
/mutation-test                                     # files changed vs main, suite inferred and confirmed
/mutation-test --base develop                      # files changed vs another branch
/mutation-test src/parser.ts src/render.ts         # explicit files
/mutation-test --test-cmd "npm test" --rerun-caught
```

Options:

- `--base <branch>` — mutate the files changed versus `<branch>`. Default `main`.
- `<file>...` — explicit paths, instead of or in addition to the diff.
- `--test-cmd "<command>"` — how to run the suite. Exit 0 must mean green. Inferred and confirmed with you if omitted.
- `--exclude <glob>` — drop resolved targets matching the glob. Repeatable. Every exclusion is announced.
- `--timeout <seconds>` — per-run wall-clock cap. Default 600. A mutation that hangs is restored, not left behind.
- `--rerun-caught` — re-run every caught result once. Use on any suite with known intermittency: a flaky failure reads as a catch and hides a survivor.
- `--verify-green` — re-run the suite after each restore, proving the tree is green again before the next mutation. Doubles the cost; `finish` does it once regardless.
- `--allow-dirty` — proceed on a tree with uncommitted or untracked changes, acknowledging the baseline is not known-good.

## What it does

1. **Refuses a dirty working tree** — the procedure assumes a known-good baseline. `--allow-dirty` overrides it with an explicit acknowledgement.
2. **Backs the target files up by copy, outside the repository** — so the backup can never show up in `git status` and corrupt the check that proves the tree was restored.
3. **Proves the suite is green** before anything is broken. A red baseline aborts; every result after one is meaningless.
4. **Runs each mutation** under a timeout, records the outcome, and **restores from the backup copy** before the next one — from a signal handler as well as the normal path, so an interrupted run cannot leave a mutation behind.
5. **Verifies the tree is byte-identical** when finished — `cmp` per target file plus an unchanged `git status --porcelain` — and re-runs the suite to prove it is green again. A run that cannot prove this exits 5.
6. **Reports survivors distinctly** from caught mutations, each with an exact reproduction command.

## Results are five-valued, not two

| Result | Meaning |
|---|---|
| `caught` | The suite failed. The behaviour is pinned. |
| `survived` | The suite passed against broken code. **This is the finding.** |
| `flaky` | The two runs disagreed. Nothing proven. |
| `timeout` | The suite never finished on either attempt. Nothing proven. |
| `error` | The test command could not be executed at all. Nothing proven. |

Only the first two are verdicts. The rest are reported as inconclusive and never folded into the caught count — a harness that cannot tell "survived" from "never ran" is the same defect as the vacuous tests it exists to find. That is also why a suite killed with `SIGKILL` after ignoring `SIGTERM` (exit 137, not 124) is classified as a timeout rather than a failure: filing a hang as a catch would hide a survivor.

Each row also carries a **failure signal** — the first assertion-like line from that run's log. A mutation that trips an assertion *other* than the one it targeted is not coverage of the behaviour it broke, and a pass/fail column cannot show that.

## Why the restore never uses git

`git checkout -- <path>` also reverts uncommitted work in the same file, silently, and the campaign keeps running against a tree nobody intended — looking green the whole way. Restoration is done by copying back a file backup taken before the first mutation, and the script never invokes `git checkout`, `git restore`, `git stash`, `git clean`, or `git reset`. Its smoke test asserts this statically (against a comment- and string-stripped copy, so the check cannot be satisfied by quoting) as well as behaviourally.

## Who chooses the mutations

You (well — the agent) do, from the diff's semantics. The script deliberately does not generate them.

Mutations that match what the change *claims* to do find real defects; a generic "flip every `>` to `>=`" sweep mostly does not. The productive set: invert a new guard, make a new conditional constant, drop a newly-added argument at one call site, revert a changed default, remove a newly-added filter, neuter a new early return. Output-shaping code deserves special attention — it is routinely tested only for "did it not throw", and mutations there survive at a much higher rate than in logic.

Test files, fixtures, docs, and lockfiles are the wrong targets: breaking a test is a guaranteed meaningless catch, breaking a doc a guaranteed meaningless survivor. `--base` selects everything the diff touched, so the script flags targets that look like tests or docs and `--exclude` drops them — announced, never silently.

## Is a survivor always a defect?

No. A survivor is either a **missing test** — the behaviour is observable here and nothing checks it — or a **documented gap**, where the behaviour is genuinely untestable at this layer and the honest output is the gap written down rather than a contorted test. The report distinguishes them; the command stops at the report rather than writing tests, because a report that also rewrites the suite is much harder to trust.

If nothing at all was caught in a campaign, the report says so and withholds the survivors as unproven: a green baseline shows the suite passes, not that it can fail. A piped test command without `pipefail` always exits 0 and would otherwise turn the whole report into false findings.

## The script

`scripts/mutation-test.sh` is a four-verb state machine and is usable on its own:

```bash
bash mutation-test.sh begin  --test-cmd "npm test" --base main [--rerun-caught]
# ... apply a mutation by editing a file listed in $SESSION/targets ...
bash mutation-test.sh run    --session "$SESSION" --name break-guard --description "..."
bash mutation-test.sh status --session "$SESSION"     # report so far, no verification
bash mutation-test.sh finish --session "$SESSION"     # report + byte-identical proof + green-again run
```

`begin` also accepts `--file <path>` (repeatable), `--files-from <listfile>`, `--session-dir <dir>` (must be outside the repo), and `--allow-test-artifacts`. `finish` accepts `--allow-test-artifacts` (so discovering artifact drift does not mean re-running the campaign) and `--no-final-check`.

`finish` reports `TREE_VERIFIED=yes|partial|no` and `FINAL_SUITE=green|red|skipped-by-request|skipped-tree-unverified` **independently**. `partial` means every target file is byte-identical and no **tracked** file drifted, with untracked artifacts forgiven by `--allow-test-artifacts`; tracked drift always fails. A red closing suite on a verified tree exits 6 and is explicitly *not* reported as a restore problem — telling you to restore a tree that is provably restored would send you chasing nothing. `status` never emits `TREE_VERIFIED` at all — it verifies nothing, and reports `VERIFICATION=not-run`.

Exit codes: `0` success, `1` general error, `2` usage, `3` no green baseline (or no mutation applied), `4` dirty tree without `--allow-dirty`, `5` tree verification failed, `6` tree verified but the suite is not green.

A session whose baseline never went green is refused by every later verb: `begin` writes the backup before running the baseline, so an aborted session looks complete and would otherwise produce verdicts from a suite that was already failing.

### Sessions

A session directory holds the backups, every mutated source, and the `repro.sh` for each mutation. It defaults to a `mktemp -d` under `$TMPDIR`, which is not cleaned up automatically and has no lifetime guarantee — reboot and OS temp reaping both destroy it, and the reproduction commands in the report go with it. Pass `--session-dir <dir>` (outside the repository) when the findings need to outlive that. `finish` prints the path and the `rm -rf` that removes it.

### Testing

Run the smoke test with `bash scripts/test_mutation-test.sh`. It drives real git repositories rather than mocks and takes several minutes; no CI job runs it. Coverage includes the usage errors and exit codes, the dirty-tree and red-baseline refusals, all five classifications, restoration on the error paths as well as the happy path, a suite that ignores `SIGTERM`, a suite that writes its own cache, `--allow-test-artifacts` in both directions, relative paths from a subdirectory, and the static "never use git to restore" guard.

## Requirements

- `bash` 3.2+ (stock macOS is fine), `git`, and the usual POSIX toolchain: `cmp`, `diff`, `mktemp`, `sed`, `grep`, `awk`, `cut`, `tr`, `wc`, `tail`, `find`, `cp -p`, `touch`, `date +%s`, `dirname`, `basename`
- GNU `timeout` if available; a portable polling fallback (with process-group kill) is used when it is not. Set `MUTATION_TEST_FORCE_POLL=1` to exercise the fallback deliberately.
