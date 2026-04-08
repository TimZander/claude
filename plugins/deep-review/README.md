# deep-review

Rigorous code review plugin that reviews all changes on the current branch compared to a base branch (default `main`).

> **Renamed from `review-code`** to avoid conflict with Claude's built-in `/review` skill.
> If you have `review-code` installed, uninstall it and install `deep-review`:
> ```
> /plugin uninstall review-code
> /plugin install deep-review@tzander-skills
> ```

## Usage

### Basic review (current branch vs main)

```
/deep-review
```

### With a focus area

Provide free-form text to direct attention toward specific concerns:

```
/deep-review focus on thread safety and error handling
```

### With issue/PR context

Pass a GitHub issue, PR, or Azure DevOps work item URL. The review will fetch the requirements and cross-reference them against the implementation:

```
/deep-review https://github.com/org/repo/issues/42
/deep-review https://github.com/org/repo/pull/99
/deep-review https://dev.azure.com/org/project/_workitems/edit/1234
/deep-review https://github.com/org/repo/pull/99 check auth edge cases
```

### With a custom base branch

By default, changes are compared to `main`. Use `base:<name>` to compare against a different branch:

```
/deep-review base:develop
/deep-review base:release/2.0
/deep-review base:develop focus on error handling
```

### With a branch target (for worktree agents)

Use `branch:<name>` to review a specific branch instead of the current HEAD. This is designed for running the review inside an Agent with worktree isolation:

```
/deep-review branch:feature/new-api
/deep-review branch:feature/new-api base:develop
```

### Combining arguments

All argument types can be combined freely:

```
/deep-review base:develop focus on auth edge cases
/deep-review branch:feature/auth base:develop https://github.com/org/repo/issues/42
```

### Running parallel reviews across branches

You can review multiple branches simultaneously by asking Claude to spawn parallel worktree agents. Each agent gets its own isolated copy of the repo and can checkout a different branch without conflicts.

Example prompt:

> Review branches feature/auth, feature/api, and bugfix/null-check in parallel

Claude will spawn agents like:

```
Agent({
  description: "Deep review feature/auth",
  model: "opus",
  isolation: "worktree",
  prompt: "Read the file plugins/deep-review/commands/deep-review.md and follow
           its instructions exactly. Your arguments are:
           branch:feature/auth base:develop"
})
```

Each agent checks out its target branch, diffs against the specified base, runs the full review (including its own parallel subagents for correctness, testing, design, and assumptions analysis), and returns a structured verdict.

## What It Does

Runs a structured, skeptical code review covering:

- Feature fitness and necessity
- Complexity and maintenance burden
- Unintended consequences
- Assumptions audit
- Test coverage gaps

Uses parallel subagents to deeply analyze correctness/security, test coverage, design quality, and assumptions simultaneously — then merges and verifies findings into a single comprehensive output.

Outputs a structured verdict with critical issues, simplification opportunities, and actionable feedback.
