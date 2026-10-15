---
description: Resume interrupted work from the newest /handoff note, and continue from where it stopped instead of restarting. Use after /clear, a compaction, a new session, or a crash. (Named pickup, not resume, so it doesn't collide with the built-in /resume.)
argument-hint: "[optional: a note path in docs/handoffs/; defaults to the newest open note]"
allowed-tools: Bash, Read, Write, Glob
---

# Pickup: resume from a handoff note

`/pickup` reads the note a `/handoff` left and **continues, never restarts**.

## Find the script

It is `${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh`. If that path still reads literally
`${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for `**/handoff/**/scripts/handoff.sh` under
`~/.claude/plugins` (resolve `~` first), skip candidates whose plugin folder has a
`.orphaned_at` marker, and take the first that remains. Below, `<handoff>` means
`bash <that path>`.

## Steps

1. **Choose the note.** If **$ARGUMENTS** names one, use it. Otherwise run `<handoff> open`: one
   `<note>\t<next action>` line per open note, newest first, read from the index
   `docs/handoffs/README.md`. Take the first.
   - Nothing printed: nothing to resume on this branch. A handoff committed in another session
     lives on its work branch, so run `<handoff> remote`: one `<branch>\t<note>\t<next action>`
     line per open note on a remote branch. If it finds any, list them and ask which to resume;
     check that branch out (keeping any local work safe) before going on. If it finds none,
     there's nothing to resume: say so and stop.
   - More than one open note: name them all with their next actions, resume the newest, and say
     that the others are still open.
   - A next action of `(no index)`: the repository has notes but no index. Read the newest note,
     and treat it as open unless it says it is done.
2. **Read the note's four sections**: Current state, Next action, Remaining work, Decisions &
   gotchas.
3. **Check it against reality first.** Run `<handoff> state` and compare it with **Current
   state**: the branch, uncommitted files, ahead/behind. If they disagree (another branch, work
   that is gone, commits the note doesn't mention), tell the user what differs and ask before
   acting on the note.
4. **Carry the decisions and gotchas forward**, so they aren't argued again.
5. **Mark it resumed**: `<handoff> set <note> resumed`, so a later `/pickup` doesn't take it
   again. This edits the index in the working tree only; it is committed with the next work.
6. **Start from the literal Next action**, then work the Remaining work in order. Commit only as
   the repository's own rules and the user say; resuming doesn't commit anything by itself.
