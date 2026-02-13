---
name: craft-commit-push
description: Craft a commit message for staged changes and output a combined commit-and-push command
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are crafting a commit message for the currently staged changes and producing a combined commit-and-push command. Your job is to analyze the diff, understand the intent, and produce a clear, accurate commit message.

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

Build a single-line command that commits and then pushes, using `&&` to chain the commands. Use PowerShell's `` `n `` escape for newlines within the `-m` string.

For subject-only messages:
```powershell
git commit -m "Subject line here" && git push
```

For messages with a body, use `` `n`n `` to separate the subject from the body (double newline = blank line):
```powershell
git commit -m "Subject line here`n`nBody paragraph here, wrapped at 72 characters. Explains why the change was made and any important context." && git push
```

**Quoting rule:** If the commit message body contains words that need quoting, use single quotes — NEVER double quotes. Double-quote escaping (`""` or `\"`) inside the `-m` string breaks PowerShell argument parsing for `git commit`.
- Bad: `git commit -m "Fix parsing of ""Critical Issues"" section" && git push`
- Good: `git commit -m "Fix parsing of 'Critical Issues' section" && git push`

**Copy to clipboard:** Use the Bash tool to pipe the command string to `clip.exe` so it lands on the user's clipboard as one unbroken line. For example:

```
echo 'git commit -m "Subject line here" && git push' | clip
```

Then tell the user the command has been copied to their clipboard and they can paste it directly.

Also display the command in your response for reference, but note that the clipboard copy is the reliable way to use it.

**Do NOT run the git commit or git push commands.** Only copy the command to the clipboard and display it.

**Do NOT add a `Co-Authored-By` trailer or any other attribution line.** The commit message must contain only the subject and optional body — nothing else.
