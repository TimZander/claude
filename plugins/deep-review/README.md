# deep-review

Rigorous code review plugin that reviews a pull request — or all changes on the current branch — against a base branch.

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

### Reviewing a pull request

Pass a PR reference and the review targets **that PR's source branch** — not whatever happens to be checked out — and compares it against the PR's own target branch. The PR description is pulled in as requirements context at the same time.

```
/deep-review pr 4506
/deep-review #99
/deep-review https://github.com/org/repo/pull/99
/deep-review pr 4506 check auth edge cases
```

Works on both GitHub and Azure DevOps; the host is detected from the `origin` remote. If the PR is already merged or abandoned, the review says so rather than treating it as open.

**This checks out the PR's branch.** When the resolved branch is not the one you have checked out, the review tells you and **asks before switching** — it detaches your working directory to `origin/<source-branch>` and restores your original ref afterwards. It refuses to start if your tree is dirty, and it never switches silently. Requires a clean tree, `gh` (GitHub) or `az` with the `azure-devops` extension (ADO). Fork PRs are not supported: their source branch does not exist on `origin`, so use `gh pr checkout <N>` and then `branch:<name>`.

**`#<N>` means different things per host.** On GitHub, issues and PRs share one numbering counter, so `#<N>` resolves to whichever exists — a PR selects the branch, an issue is context only. On Azure DevOps, work items and PRs are numbered **separately**, so `#<N>` is always read as a work item (context only) and never selects a branch. Use the explicit `pr <N>` form for an ADO PR.

### With issue/work-item context

Pass a GitHub issue or Azure DevOps work item URL. The review fetches the requirements and cross-references them against the implementation. These supply context only — they do not change which branch is reviewed:

```
/deep-review https://github.com/org/repo/issues/42
/deep-review https://dev.azure.com/org/project/_workitems/edit/1234
/deep-review #7775 focus on error handling
```

### With a custom base branch

Changes are compared to the PR's target branch when a PR was given, and to `main` otherwise. Use `base:<name>` to override either:

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

An explicit `branch:` wins over a branch derived from a PR reference.

### Combining arguments

All argument types can be combined freely:

```
/deep-review base:develop focus on auth edge cases
/deep-review pr 4506 focus on error handling
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

## Agent Invocation

Agents can invoke `/deep-review` via the Skill tool:

```
Skill({ skill: "deep-review", args: "focus on error handling" })
```

To run a review in the background while continuing other work:

```
Agent({
  description: "Deep review of current branch",
  model: "opus",
  prompt: "Use the Skill tool to invoke deep-review. Your arguments are: focus on error handling"
})
```
