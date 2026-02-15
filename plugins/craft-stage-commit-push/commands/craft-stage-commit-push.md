---
name: craft-stage-commit-push
description: Filter junk files, stage meaningful changes, craft a commit message, and output a combined stage-commit-push command
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
user-input: optional
---

You are crafting a single command that stages meaningful files, commits, and pushes. Your job is to analyze the working directory, filter out junk files, craft a clear commit message, and produce a ready-to-copy command.

**If the user provided input, treat it as a feature filter.** The input describes which feature or piece of work to isolate. Only stage files whose changes are related to that feature. All other changed files — even if they are meaningful and not junk — must be left unstaged. When a feature filter is active, after Step 2 (junk filtering), apply an additional pass: read the diffs of every remaining file and include only files whose changes are directly related to the user's described feature. Report which meaningful files were excluded because they belong to a different piece of work.

## Step 1: Gather Context

**Run all of these in parallel:**

1. Run `git status --porcelain` to see all modified, untracked, and staged files.
2. Run `git diff --stat` to see unstaged tracked changes.
3. Run `git diff --cached --stat` to check for already-staged changes.
4. Run `git diff -U5` to see the full unstaged diff with context.
5. Run `git diff --cached -U5` to see the full staged diff with context.

If there are no unstaged changes, no untracked files, and no staged changes, stop immediately and tell the user: "No changes found. There is nothing to stage or commit."

## Step 2: Filter Files

Analyze each unstaged/untracked file and classify it as **meaningful** or **junk**. Exclude junk files from the staging command.

### Junk patterns to exclude:

- **Build artifacts:** `bin/`, `obj/`, `out/`, `dist/`, `build/`
- **IDE/editor files:** `.vs/`, `.idea/`, `.vscode/settings.json`, `*.suo`, `*.user`
- **OS files:** `Thumbs.db`, `.DS_Store`, `desktop.ini`
- **Temp/cache files:** `*.tmp`, `*.log`, `*.cache`
- **Package manager output:** `node_modules/`, `packages/`
- **Files matching `.gitignore` patterns that appear as untracked** — these are ignored files leaking into the status

After filtering, report the excluded files grouped by reason. For example:

> **Excluded (build artifacts):** `bin/Debug/App.dll`, `obj/Release/cache.dat`
> **Excluded (IDE files):** `.vs/config/applicationhost.config`

If ALL unstaged/untracked files were filtered out as junk and there are no already-staged changes, stop and tell the user: "All changed files are build artifacts, IDE files, or other junk. Nothing meaningful to stage."

## Step 2b: Feature Filter (only when user provided input)

If the user provided a feature description, apply it now as a second filter on top of the junk-filtered list.

1. **Read the diff of each remaining file.** Use the diffs gathered in Step 1 to understand what each file's changes do.
2. **For each file, decide: does this change relate to the user's described feature?** Be precise — only include files that are clearly part of the specified work. When in doubt, exclude the file.
3. **Report excluded files.** List the meaningful files that were left out because they belong to different work:

> **Excluded (not part of this feature):** `src/Unrelated.cs`, `tests/OtherTests.cs`

4. If no files remain after feature filtering, stop and tell the user: "None of the current changes match the described feature: '{user input}'."

## Step 3: Analyze the Changes

Consider both the already-staged changes and the meaningful unstaged changes together — they will all be part of the same commit.

- **Understand the intent.** What problem do these changes solve? What behavior do they add, change, or remove?
- **Identify the scope.** Is this a single focused change or does it touch multiple concerns?
- **Note key details.** New files, deleted files, renamed files, changed signatures, configuration changes.

## Step 4: Summarize

Briefly describe what the meaningful changes represent:

- What files are being staged and what kind of changes they contain (new files, modifications, deletions).
- Group related files if applicable (e.g. "3 source files for the new validation feature").
- If there are already-staged files, mention them and note they are already staged.

## Step 5: Commit Message Style

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

## Step 6: Output

Present the commit message in exactly two formats:

### Text

Output the full commit message as plain text in a code block:

```
Subject line here

Optional body paragraph here, wrapped at 72 characters. Explains why
the change was made and any important context.
```

### Command

Build a single-line command that stages the meaningful files, commits, and pushes. Use `;` to chain the commands. Use PowerShell's `` `n `` escape for newlines within the `-m` string. List every meaningful file explicitly in the `git add` so junk files are excluded.

For subject-only messages:
```powershell
git add file1 file2; git commit -m "Subject line here"; git push
```

For messages with a body, use `` `n`n `` to separate the subject from the body (double newline = blank line):
```powershell
git add file1 file2; git commit -m "Subject line here`n`nBody paragraph here, wrapped at 72 characters. Explains why the change was made and any important context."; git push
```

**Quoting rule:** If the commit message body contains words that need quoting, use single quotes — NEVER double quotes. Double-quote escaping (`""` or `\"`) inside the `-m` string breaks PowerShell argument parsing for `git commit`.
- Bad: `git commit -m "Fix parsing of ""Critical Issues"" section"`
- Good: `git commit -m "Fix parsing of 'Critical Issues' section"`

**Copy to clipboard:** Use the Bash tool to pipe the command string to `clip.exe` so it lands on the user's clipboard as one unbroken line. For example:

```
echo 'git add src/Profile.cs src/Validator.cs; git commit -m "Subject line here"; git push' | clip
```

Then tell the user the command has been copied to their clipboard and they can paste it directly.

Also display the command in your response for reference, but note that the clipboard copy is the reliable way to use it.

**Do NOT run the git add, git commit, or git push commands.** Only copy the command to the clipboard and display it.

**Do NOT add a `Co-Authored-By` trailer or any other attribution line.** The commit message must contain only the subject and optional body — nothing else.
