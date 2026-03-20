# deep-review

Rigorous code review plugin that reviews all changes on the current branch compared to main.

> **Renamed from `review-code`** to avoid conflict with Claude's built-in `/review` skill.
> If you have `review-code` installed, uninstall it and install `deep-review`:
> ```
> /plugin uninstall review-code
> /plugin install deep-review@tzander-skills
> ```

## Usage

```
/deep-review
/deep-review focus on thread safety and error handling
/deep-review https://github.com/org/repo/issues/42
/deep-review https://dev.azure.com/org/project/_workitems/edit/1234
/deep-review https://github.com/org/repo/pull/99 check auth edge cases
```

Optional text after `/deep-review` provides additional context for the review. This can be a focus area, a GitHub issue/PR URL, an Azure DevOps work item URL, a plain URL, or any combination.

## What It Does

Runs a structured, skeptical code review covering:

- Feature fitness and necessity
- Complexity and maintenance burden
- Unintended consequences
- Assumptions audit
- Test coverage gaps

Uses parallel subagents to deeply analyze correctness/security, test coverage, design quality, and assumptions simultaneously — then merges and verifies findings into a single comprehensive output.

Outputs a structured verdict with critical issues, simplification opportunities, and actionable feedback.
