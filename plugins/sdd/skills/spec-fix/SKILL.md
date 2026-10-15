---
name: spec-fix
description: Apply review findings, UAT remarks or bug reports to an OpenSpec change through the spec first - map each to the requirement it touches, fix the delta, check and commit it, then the failing test, then the code. Use for any finding that changes what the software does.
argument-hint: "<change-name> [findings or report]"
---

# Fix through the spec

A finding that changes what the software does is a spec change first. The spec stays the
source of truth only if every behaviour change lands there before the code does.

## Inputs

- `<change>`: the argument; if empty, the only active change. If there's no active change and
  a finding changes behaviour, start one with `/opsx:propose` (a fix-sized change) first.
- The findings: a `/sdd:spec-review` or `/sdd:conformance-review` report from this session, a
  UAT remark or bug report from the user, or a list in the argument.

## Step 1: Triage every finding

Verify each finding by hand before acting on it: read the cited lines; drop it, with the
reason, if it doesn't hold. Then sort each one into a route (a conformance review gives one; check
it):

| Route | When | What changes |
|---|---|---|
| `spec` | It changes or decides observable behaviour | delta → check → commit; test; code |
| `test` | The spec is right; the test can't show it | test only (it must fail first if the code is wrong) |
| `code` | Spec and test are right; code isn't | code only (a test should already be failing) |
| `none` | A rename or refactor with no observable change | a plain code fix |
| `owner` | It needs a decision the owner hasn't made | an open question in `design.md`, with the assumption the change proceeds on; raise it with the owner |

Show the triage table to the user before editing, with each finding's requirement (name or ID,
or `unspecified`).

## Step 2: Spec route, one commit per round

1. Edit the change's deltas under `openspec/changes/<change>/specs/`. A requirement that exists
   on main goes in a `MODIFIED` block holding its **full** current text with your edit; keep
   every scenario it had unless the finding removes one. Add or update the scenario that would
   have caught the finding.
2. Re-pin: `npm run spec:pin -- <change>` (unless the repository turned pins off). If the main
   spec's text of a requirement you modify has changed since the delta was written, merge that
   newer text into the delta first: pinning records what the delta was written against.
3. Update `tasks.md` if the work changed.
4. Run `bash scripts/sdd/check-specs.sh --worktree` while editing, then commit the spec edits and
   run `bash scripts/sdd/check-specs.sh` on the commit. On failure, fix and commit again. Never
   push a spec commit that fails it.
5. **Re-review** with `/sdd:spec-review <change>` only while the last review round found a
   blocker, or this round changes behaviour on real data, and only within the repo's round cap
   (3 unless the owner says otherwise). Past the cap, record the change in `design.md` as made
   after the review cap.

## Step 3: Test, then code

For each spec-route and test-route finding: write or fix the test from the scenario, run it,
and **see it fail** for the right reason. Then fix the code and see it pass. Commit the test and
the code separately from the spec commit. Never change code and back-fill its delta in the same
commit.

## Step 4: Report

List each finding with its route and the commits that resolved it, the open questions raised
for the owner, and whether another review round is due.
