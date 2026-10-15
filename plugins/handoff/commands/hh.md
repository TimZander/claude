---
description: Shortcut for /handoff. Write a resume note for the current work so /pickup (or /hp) can continue it later.
argument-hint: "[optional: a note path in docs/handoffs/; defaults to docs/handoffs/<date>.md]"
allowed-tools: Bash, Read, Write, Glob
---

# hh: shortcut for /handoff

Read `${CLAUDE_PLUGIN_ROOT}/commands/handoff.md` and follow it exactly, with **$ARGUMENTS** as its
arguments. If that path still reads literally `${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for
`**/handoff/**/commands/handoff.md` under `~/.claude/plugins` (resolve `~` first), skip
candidates whose plugin folder has a `.orphaned_at` marker, and take the first that remains.
