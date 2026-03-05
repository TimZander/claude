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
```

## What It Does

Runs a structured, skeptical code review covering:

- Feature fitness and necessity
- Complexity and maintenance burden
- Unintended consequences
- Assumptions audit
- Test coverage gaps

Outputs a structured verdict with critical issues, simplification opportunities, and actionable feedback.
