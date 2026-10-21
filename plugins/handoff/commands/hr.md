---
description: Shortcut for /handoff:relay. Cloud sessions only - continue the work in a new cloud session instead of using /clear.
argument-hint: "[optional: a note path in docs/handoffs/; defaults to docs/handoffs/<date>.md]"
allowed-tools: Bash, Read, Write, Glob, ToolSearch, mcp__claude-code-remote__create_session, mcp__claude-code-remote__get_session, mcp__claude-code-remote__archive_session
---

# hr: shortcut for /handoff:relay

Read `${CLAUDE_PLUGIN_ROOT}/commands/relay.md` and follow it exactly, with **$ARGUMENTS** as its
arguments. If that path still reads literally `${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for
`**/handoff/**/commands/relay.md` under `~/.claude/plugins` (resolve `~` first), skip
candidates whose plugin folder has a `.orphaned_at` marker, and take the first that remains.
