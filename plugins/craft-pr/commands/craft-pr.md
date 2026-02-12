---
name: craft-pr
description: Generate a PR title and description for the current branch compared to origin/main
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion, WebFetch
---

You are generating a pull request title and description for the current branch compared to origin/main. The title will appear in release notes, so it must be precise and meaningful to someone who hasn't seen the code.

## Step 1: Gather Context

**Run all of these in parallel:**

1. Run `git fetch origin main && git log origin/main..HEAD --oneline` to see all commits on this branch.
2. Run `git diff origin/main...HEAD --stat` to see the summary of changed files.
3. Run `git diff -U10 origin/main...HEAD` to see the full diff with context.
4. Run `git branch --show-current` to get the branch name.

If there are no commits ahead of origin/main, stop immediately and tell the user: "No changes found compared to origin/main. Make sure you're on a feature branch with commits."

## Step 2: Analyze the Changes

Read every line of the diff carefully.

- **What is the user-facing change?** Describe the outcome, not the implementation.
- **What files were touched?** Group them by concern (feature code, tests, config, migrations, etc.).
- **Are there assumed SQL/database changes?** SQL lives in a separate repository. Look for clues in the code that suggest database changes are required: references to new tables, columns, or stored procedures that don't exist in the current codebase; new or changed entity mappings/models; updated query strings; new repository methods that reference unfamiliar schema. These are *assumed* changes — the SQL itself is not in this diff.
- **Are there breaking changes?** Look for: changed or removed public API endpoints, changed method signatures on shared/public interfaces, renamed or removed fields in API responses or request contracts, changed event payloads, removed or renamed configuration keys, changed database contracts that other services consume, behavioral changes to existing functionality that consumers rely on (e.g., a method that used to return null now throws).
- **What could break?** Trace changed method signatures, altered behavior, new dependencies, changed configuration, state mutations, or removed functionality.
- **What needs testing?** Identify the scenarios a reviewer should verify — especially edge cases, error paths, and integration points.

If you need more context on a specific file to understand a change, Read the full file. **Make parallel Read calls** when examining multiple files.

## Step 3: PR Title

The title appears in release notes. Follow these rules exactly:

- **Imperative mood, present tense.** Start with a capitalized verb. No period at the end.
  - Good: `Add two-factor authentication to login flow`
  - Good: `Fix payment rounding error for fractional quantities`
  - Bad: `Added 2FA` (past tense, too vague)
  - Bad: `Auth updates` (no verb, unclear)
  - Bad: `Fix bug` (too vague for release notes)
- **Describe the user-visible outcome**, not the implementation detail.
  - Good: `Show error message when upload exceeds size limit`
  - Bad: `Add validation check in FileUploadService`
- **Be specific enough that someone reading release notes understands the change without clicking through.**
- **Length:** Aim for under 60 characters. Hard limit: 72 characters.

## Step 4: PR Description

Write the description in markdown using exactly this structure:

```
## Summary

1-3 sentences explaining what this PR does and why. Focus on the motivation and user-facing impact, not implementation details.

## Changes

Bulleted list of the key changes, grouped logically. Each bullet should describe a meaningful change, not just list files. Keep it concise — a reviewer reads this to orient themselves before looking at the diff.

## Breaking Changes

**Present only if there are breaking changes.** If there are none, omit this section entirely.

List each breaking change:
- What changed (removed endpoint, renamed field, changed return type, etc.)
- What consumers are affected (other services, API clients, UI, etc.)
- What the consumer must do to adapt (update call site, handle new response shape, etc.)

## SQL / Database Dependencies

**Present only if the code changes suggest database changes are required.** If no database dependencies are detected, omit this section entirely.

List each assumed database dependency:
- What the code expects (new table, new column, changed stored procedure, etc.)
- Which code references it (file and line)

> **Changeset:** [ID provided by author, or "Not provided"]

- [ ] SQL changes have been released to all environments

## Gotchas

Things a reviewer or deployer should watch out for:
- Behavior changes that aren't obvious from the diff
- Changes to shared code that affect other features
- New environment variables, config changes, or feature flags required
- Performance implications
- Order-of-operations concerns during deployment

If there are genuinely no gotchas, write "None identified." Do not omit this section.

## Test Cases

Key scenarios to verify. Use checkboxes. Focus on cases that a reviewer should think about — not an exhaustive QA plan.

- [ ] Happy path scenario
- [ ] Important edge case
- [ ] Error/failure scenario
- [ ] Regression check for related behavior

Include at least one negative test case (verifying something is correctly rejected or handled on failure).
```

## Step 5: SQL Changeset (Interactive)

**Only perform this step if you identified assumed database dependencies in Step 2.**

Use AskUserQuestion to ask the user:
- Whether there are corresponding SQL changes for this PR.
- If yes, ask for the Azure DevOps changeset ID.

If the user provides a changeset ID:
1. Use WebFetch to retrieve the changeset details from Azure DevOps (the URL will typically be in the format `https://dev.azure.com/{org}/{project}/_git/{repo}/changeset/{id}` — ask the user for the correct URL if needed).
2. Review the SQL changes in the changeset and update the "SQL / Database Dependencies" section with concrete details about what the SQL changeset contains and whether it aligns with what the code expects.
3. Fill in the changeset ID in the description template.

If the user says there are no SQL changes or declines to provide a changeset ID, note this in the description — the assumed dependencies still need to be called out as a warning so reviewers are aware.

## Step 6: Output

Present the PR title and description clearly so the user can copy them.

### Title

Output the title on its own line in a code block:

```
PR title here
```

### Description

Output the full markdown description in a code block:

```markdown
## Summary
...
```

**Do NOT create the PR.** Only output the title and description for the user to use.
