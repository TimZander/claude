---
name: craft-stage
description: Analyze working directory changes, filter junk files, and output a ready-to-run git add command
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are crafting a `git add` command for the current working directory changes. Your job is to analyze the git state, filter out junk files, and produce a ready-to-copy command that stages only the meaningful files.

## Step 1: Gather Context

**Run all of these in parallel:**

1. Run `git status --porcelain` to see all modified, untracked, and staged files.
2. Run `git diff --stat` to see unstaged tracked changes.
3. Run `git diff --cached --stat` to check for already-staged changes.

If there are no unstaged changes and no untracked files (nothing new to stage), stop immediately and tell the user: "No unstaged changes found. There is nothing to stage."

If there are already-staged changes, note them but focus on the **unstaged** and **untracked** files — those are what need staging.

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

If ALL files were filtered out as junk, stop and tell the user: "All changed files are build artifacts, IDE files, or other junk. Nothing meaningful to stage."

## Step 3: Summarize

Briefly describe what the meaningful changes represent:

- What files are being staged and what kind of changes they contain (new files, modifications, deletions).
- Group related files if applicable (e.g. "3 source files for the new validation feature").

## Step 4: Output

Build a single-line `git add` command with all meaningful files:

**Format:** `git add file1 file2 ...`

- List every meaningful file explicitly so junk files are excluded.
- If there are already-staged files, mention them separately and note they are already staged — do not include them in the `git add` command.

**Copy to clipboard:** Use the Bash tool to pipe the command string to `clip.exe` so it lands on the user's clipboard as one unbroken line. For example:

```
echo 'git add src/Profile.cs src/Validator.cs tests/ProfileTests.cs' | clip
```

Then tell the user the command has been copied to their clipboard and they can paste it directly.

Also display the command in your response for reference, but note that the clipboard copy is the reliable way to use it.

**Do NOT run the git add command itself.** Only copy it to the clipboard and display it.
