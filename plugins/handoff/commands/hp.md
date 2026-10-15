---
description: Shortcut for /pickup. Resume interrupted work from the newest /handoff (or /hh) note.
argument-hint: "[optional: a note path in docs/handoffs/; defaults to the newest note]"
allowed-tools: Bash, Read, Write, Glob
---

# hp: shortcut for /pickup

Read `${CLAUDE_PLUGIN_ROOT}/commands/pickup.md` and follow it exactly, with **$ARGUMENTS** as its
arguments. If that path still reads literally `${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for
`**/handoff/**/commands/pickup.md` under `~/.claude/plugins` (resolve `~` first), skip
candidates whose plugin folder has a `.orphaned_at` marker, and take the first that remains.
