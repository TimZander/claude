---
name: conformance-review
description: Review an applied OpenSpec change's code against its spec - does the code do what the changed requirements say, and nothing they don't, and would its tests catch a regression. Lighter than a general code review; use after /opsx:apply and before opening the change's PR.
argument-hint: "<change-name> [--base <branch>]"
context: fork
agent: general-purpose
allowed-tools: Read, Grep, Glob, Bash
---

# Conformance review

The spec was reviewed for intent before any code was written. This review checks the code
against that spec, and nothing else: **conformance** (the code does what the spec says),
**sufficiency** (the spec covers everything the code does that matters), and whether the tests
would catch a regression. It is not a general code review: no style, naming or design-taste
findings.

You are a **fresh reviewer**: work only from the files and the diff, not from anything said
about the change in conversation.

## Rules

- **Read-only, except the spot check**, which edits files temporarily and must leave the tree
  exactly as it found it (step 4).
- Report only findings you can point to with `file:line`.
- At most **15 findings**. Two severities: **hard fail** (the code or a test is wrong against
  the spec, or real harm) and **soft fail** (a gap that should be fixed before merge). If you
  have more, keep the most severe and say how many you dropped.

## Inputs

- `<change>`: the argument; if empty, the only active folder in `openspec/changes/` other than
  `archive/`.
- `<base>`: `--base`, else the default branch (`git symbolic-ref refs/remotes/origin/HEAD`,
  else `main`).
- The change's `proposal.md`, `design.md`, `tasks.md` and deltas; the main spec of every
  capability a delta touches; `openspec/conventions.md`; the repo's `CLAUDE.md`.
- The code diff: `git diff <base>...HEAD -- . ':!openspec/'`.

## Step 1: Scenario map

List every ADDED or MODIFIED requirement and each of its scenarios. For each scenario, find the
test that exercises it: a test that cites the requirement or scenario, or plainly asserts its
THEN. Record `scenario → test (file:line) | none`. Also list REMOVED requirements and the code
and tests that implemented them.

## Step 2: Conformance

For each scenario, read the code path its WHEN drives and check that it yields the THEN.
Findings:
- a scenario with no test (**hard fail**);
- a test that doesn't assert the THEN it claims, or asserts something else (**hard fail**);
- code that does something different from the scenario (**hard fail**);
- a removed requirement whose code or tests are still there (**soft fail**).

## Step 3: Sufficiency

Walk the code diff and list behaviour a user, caller or operator could observe that no
requirement covers: a new output, error, default, limit, ordering, file, route, header or side
effect. For each, decide:
- **refactor**: no observable change, so no finding;
- **spec gap**: observable and unspecified, so a finding (**soft fail**, or **hard fail** when
  it decides something the owner should, such as data loss, privacy or cost).

## Step 4: Spot check (mutation)

Reading a test is not proof it can fail. Pick the **3 scenarios with the most risk**:
behaviour that loses or corrupts data, gates something, or that review found hardest to test.
For each:
1. Make sure `git status --porcelain` is empty before you start; if not, skip the spot check
   and say so. Never stash or discard the author's work.
2. Revert or break the smallest piece of code that implements the scenario (a condition, a
   return value, a line).
3. Run only that scenario's test (the repo's test command filtered to the test).
4. Restore the code with `git checkout -- <file>` and confirm `git status --porcelain` is
   empty again.

A test that still passes with its code broken is a **hard fail** (vacuous test). Also flag, from
reading, tests whose values give the same result under the rule and a plausible wrong rule
(**soft fail**), and tests that pin values of real content rather than a fixture (**soft fail**).

## Step 5: Spec-blind risks

Only what would cause real harm and the spec can't be expected to state: a security hole
(injection, secrets, unsafe input handling), data loss, a cache or deploy that keeps serving the
old behaviour, a failure left silent. No performance or style findings unless they break a
requirement.

## Report

```
## Conformance review: <change> (<base>...HEAD)

Scenarios: <n>, with tests: <n>; untested: <list or none>
Spot check: <scenario → test: fails when broken | STILL PASSES> (x3, or why skipped)

| ID | Severity | Location | Requirement | Finding | Route |
|----|----------|----------|-------------|---------|-------|

Counts: hard fail <n>, soft fail <n>
Verdict: <conforms | conforms with gaps | does not conform>
```

**Requirement** is the requirement's name or ID, or `unspecified`. **Route** says where the fix
goes, for `/sdd:spec-fix`:
- `spec`: the spec is missing, wrong or ambiguous: a delta first, then test, then code;
- `test`: the spec is right and the code may be, but the test can't show it;
- `code`: the spec and test are right and the code is not.

Use stable IDs (`C1`, `S1`, `M1`, `R1` for conformance, sufficiency, mutation, risk).
