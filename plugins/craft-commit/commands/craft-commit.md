---
name: craft-commit
description: Craft a commit message for all currently staged changes and output it as text and a ready-to-run command
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are crafting a commit message for the currently staged changes. Your job is to analyze the diff, understand the intent, and produce a clear, accurate commit message.

## Step 1: Gather Context

**Run all of these in parallel:**

1. Run `git diff --cached --stat` to see which files are staged.
2. Run `git diff --cached -U5` to see the full staged diff with context.

If there are no staged changes, stop immediately and tell the user: "No staged changes found. Stage your changes with `git add` first."

## Step 2: Analyze the Changes

- **Understand the intent.** What problem do these changes solve? What behavior do they add, change, or remove?
- **Identify the scope.** Is this a single focused change or does it touch multiple concerns?
- **Note key details.** New files, deleted files, renamed files, changed signatures, configuration changes.

## Step 3: Commit Message Style

Follow these rules exactly:

- **Subject line:** Imperative mood, present tense. Start with a capitalized verb. No period at the end.
  - Good: `Add user authentication middleware`
  - Good: `Fix null pointer in payment processor`
  - Good: `Remove deprecated API endpoints`
  - Bad: `Added user authentication` (past tense)
  - Bad: `Adds user authentication` (third person)
  - Bad: `Add user authentication.` (trailing period)
- **Subject length:** 50 characters or fewer. Hard limit: 72 characters.
- **Body (when needed):** If the change is non-trivial, add a body separated from the subject by a blank line. The body should explain **why** the change was made, not **what** changed (the diff shows what). Wrap body lines at 72 characters.
- **When to include a body:**
  - The change affects behavior in a non-obvious way.
  - There are multiple files changed for a single purpose that benefits from explanation.
  - The motivation or context isn't obvious from the diff alone.
- **When to skip the body:**
  - Simple, single-purpose changes where the subject says it all (rename, typo fix, add a single clear function).

## Step 4: Output

Present the commit message in exactly two formats:

### Text

Output the full commit message as plain text in a code block:

```
Subject line here

Optional body paragraph here, wrapped at 72 characters. Explains why
the change was made and any important context.
```

### Command

Output a ready-to-paste single-line command using PowerShell's `` `n `` escape for newlines within the `-m` string. This keeps the command on one line regardless of terminal width.

For subject-only messages:
```powershell
git commit -m "Subject line here"
```

For messages with a body, use `` `n`n `` to separate the subject from the body (double newline = blank line):
```powershell
git commit -m "Subject line here`n`nBody paragraph here, wrapped at 72 characters. Explains why the change was made and any important context."
```

**Quoting rule:** If the commit message body contains words that need quoting, use single quotes — NEVER double quotes. Double-quote escaping (`""` or `\"`) inside the `-m` string breaks PowerShell argument parsing for `git commit`.
- ❌ `git commit -m "Fix parsing of ""Critical Issues"" section"`
- ✅ `git commit -m "Fix parsing of 'Critical Issues' section"`

**Do NOT run the commit command.** Only output it for the user to copy.

**Do NOT add a `Co-Authored-By` trailer or any other attribution line.** The commit message must contain only the subject and optional body — nothing else.
