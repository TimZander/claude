---
name: spec-review
description: Read-only semantic review of an OpenSpec change (proposal, design, spec deltas, tasks) against the main specs, before any code is written. Use after check-specs passes on a new or edited change, and again after a round of spec fixes that found a blocker.
argument-hint: "<change-name>"
context: fork
agent: general-purpose
background: false
allowed-tools: Read, Grep, Glob, Bash(bash scripts/sdd/*), Bash(git log:*), Bash(git diff:*), Bash(git show:*)
---

# Spec review for an OpenSpec change

`openspec validate --strict` checks structure only. This review checks meaning: whether the
change says one consistent, testable thing and whether its tasks cover it. Its passes adapt
SpecKit's `analyze` to OpenSpec's artefacts.

You are a **fresh reviewer**: work only from the files, not from anything said about the change
in conversation. A reviewer that wrote the spec reads what it meant, not what it says.

## Rules

- **Read-only.** Edit no file. Report findings; the author fixes them through the spec.
- Report only findings you can point to with `file:line`. No style preferences.
- Run `bash scripts/sdd/openspec.sh validate <change> --strict` first and report its result.

## Inputs

For change `<change>` (the argument; if empty, the only active folder in `openspec/changes/`
other than `archive/`; if there are several, stop and ask which):

- `openspec/changes/<change>/proposal.md`, `design.md` (if present), `tasks.md`
- every delta under `openspec/changes/<change>/specs/`
- the main spec of every capability a delta touches (`openspec/specs/<capability>/spec.md`),
  and a grep of all of `openspec/specs/` for each requirement name, rule ID or term the change
  modifies or removes
- `openspec/conventions.md`, if present

## Build the inventories first

1. **Requirements:** every ADDED or MODIFIED requirement, by name and any rule ID it defines.
2. **Definitions:** every term, number, rule ID and severity defined in the change or the
   touched main specs, with where.
3. **References:** every rule ID, requirement name or term used, with where.
4. **Tasks:** every task, mapped to the requirements it implements.

## Detection passes

**A. Contradictions.** Two statements that cannot both hold: a value, order, severity or
behaviour stated differently in two places: delta against delta, against design, or against a
main spec the change does not modify.

**B. Dangling and stale references.** A reference with no definition. After the change is
applied, a main-spec requirement the change doesn't touch that still mentions something the
change removes or redefines (OpenSpec does not flag these).

**C. Untestable statements.** A SHALL with no observable check: vague adjectives with no
measure, or behaviour no command, output or file could show. Every ADDED or MODIFIED
requirement needs a scenario whose THEN is observable.

**D. Ambiguity.** A statement two competent builders, working only from the spec, would build
differently in a way a user could observe. Name the two readings.

**E. Coverage gaps.** A requirement with no task; a task that maps to no requirement; a
REMOVED requirement whose code or tests no task removes.

**F. Scope.** Anything beyond the proposal's stated scope: a requirement added, widened or
strengthened, or one dropped or weakened. Descriptive text promoted to a SHALL counts.

**G. Format misuse.** A MODIFIED block that silently drops a scenario from the requirement it
replaces, design decisions that disagree with the deltas, tasks that describe behaviour the
deltas don't.

**H. Undecided requirements.** A requirement that settles something the proposal or design
doesn't show the owner decided, without being recorded as an open question with its
assumption.

## Severity

- **Blocker:** a contradiction or dangling reference in a rule; a requirement with no task; a
  severity conflict. A builder would build the wrong thing or skip something.
- **Should-fix:** an ambiguity with observable effect; an untestable SHALL; a scope change; a
  stale reference; an undecided requirement.
- **Consider:** wording that is correct but easy to misread; minor duplication.

## Report

```
## Spec review: <change>
validate --strict: <result>

| ID | Pass | Severity | Location | Requirement | Problem | Why a builder would go wrong |
|----|------|----------|----------|-------------|---------|------------------------------|

Coverage: <n> requirements, <n> with tasks; uncovered: <list or none>
Counts: blocker <n>, should-fix <n>, consider <n>
Another round: <yes, because blocker IDs … | no>
```

Use stable IDs (`A1`, `B2`, …). At most 40 rows; summarise any overflow in one line.
