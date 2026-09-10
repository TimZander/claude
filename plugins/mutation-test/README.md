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
- `--timeout <seconds>` — per-run wall-clock cap. Default 600. A mutation that hangs is restored, not left behind.
- `--rerun-caught` — re-run every caught result once. Use on any suite with known intermittency: a flaky failure reads as a catch and hides a survivor.

## What it does

1. **Refuses a dirty working tree** — the procedure assumes a known-good baseline. `--allow-dirty` overrides it with an explicit acknowledgement.
2. **Backs the target files up by copy, outside the repository** — so the backup can never show up in `git status` and corrupt the check that proves the tree was restored.
3. **Proves the suite is green** before anything is broken. A red baseline aborts; every result after one is meaningless.
4. **Runs each mutation** under a timeout, records caught/survived/flaky/timeout, and **restores from the backup copy** before the next one.
5. **Verifies the tree is byte-identical** when finished — `cmp` per target file plus an unchanged `git status --porcelain` — and says so explicitly. A run that cannot prove this exits non-zero.
6. **Reports survivors distinctly** from caught mutations, each with an exact reproduction command.

## Why the restore never uses git

`git checkout -- <path>` also reverts uncommitted work in the same file, silently, and the campaign keeps running against a tree nobody intended — looking green the whole way. Restoration is done by copying back a file backup taken before the first mutation, and the script never invokes `git checkout`, `git restore`, or `git stash`. Its smoke test asserts this statically as well as behaviourally.

## Who chooses the mutations

You (well — the agent) do, from the diff's semantics. The script deliberately does not generate them.

Mutations that match what the change *claims* to do find real defects; a generic "flip every `>` to `>=`" sweep mostly does not. The productive set: invert a new guard, make a new conditional constant, drop a newly-added argument at one call site, revert a changed default, remove a newly-added filter, neuter a new early return. Output-shaping code deserves special attention — it is routinely tested only for "did it not throw", and mutations there survive at a much higher rate than in logic.

## Is a survivor always a defect?

No. A survivor is either a **missing test** — the behaviour is observable here and nothing checks it — or a **documented gap**, where the behaviour is genuinely untestable at this layer and the honest output is the gap written down rather than a contorted test. The report distinguishes them; the command stops at the report rather than writing tests, because a report that also rewrites the suite is much harder to trust.

## The script

`scripts/mutation-test.sh` is a four-verb state machine and is usable on its own:

```bash
bash mutation-test.sh begin  --test-cmd "npm test" --base main [--rerun-caught]
# ... apply a mutation by editing a file listed in $SESSION/targets ...
bash mutation-test.sh run    --session "$SESSION" --name break-guard --description "..."
bash mutation-test.sh status --session "$SESSION"     # report so far, no verification
bash mutation-test.sh finish --session "$SESSION"     # report + byte-identical proof
```

`begin` also accepts `--file <path>` (repeatable), `--files-from <listfile>`, `--session-dir <dir>` (must be outside the repo), `--allow-dirty`, and `--allow-test-artifacts`.

Exit codes: `0` success, `1` general error, `2` usage, `3` red baseline or no mutation applied, `4` dirty tree without `--allow-dirty`, `5` tree verification failed.

Run the smoke test with `bash scripts/test_mutation-test.sh`. It uses real git repositories as fixtures and covers the usage errors, the dirty-tree and red-baseline refusals, caught/survived/flaky/timeout classification, byte-identical restoration, and the final verification failing loudly when the tree does not match.

## Requirements

- `bash`, `git`, and `cmp`/`diff` (coreutils/diffutils)
- GNU `timeout` if available; a portable polling fallback is used when it is not
