---
description: Cloud sessions only. Hand the work to a new cloud session instead of using /clear - write and push a /handoff note, start a new session on the same branch that resumes it with /pickup, then archive this one. Use in a cloud session whenever you would otherwise /clear.
argument-hint: "[optional: a note path in docs/handoffs/; defaults to docs/handoffs/<date>.md]"
allowed-tools: Bash, Read, Write, Glob, ToolSearch, mcp__claude-code-remote__create_session, mcp__claude-code-remote__get_session, mcp__claude-code-remote__archive_session
---

# Relay: continue in a new cloud session

In a cloud session, `/clear` starts a new transcript but keeps the old one, and a worker restart
after an idle spell can bring back the conversation from **before** the `/clear`. That context
doesn't remember its own later work. `/handoff:relay` avoids that: instead of clearing, it
starts a **new** cloud session that resumes the note with `/pickup`, and archives this one, so
each conversation keeps exactly one transcript.

## Find the script

It is `${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh`. If that path still reads literally
`${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for `**/handoff/**/scripts/handoff.sh` under
`~/.claude/plugins` (resolve `~` first), skip candidates whose plugin folder has a
`.orphaned_at` marker, and take the first that remains. Below, `<handoff>` means
`bash <that path>`.

## Steps

1. **Check that relaying is possible.** Run `<handoff> state`. If it says `cloud: no`, stop:
   relay is for cloud sessions; outside one, use `/handoff`, `/clear` and `/pickup`. Load the
   cloud-session tools with ToolSearch (`select:mcp__claude-code-remote__create_session,mcp__claude-code-remote__get_session,mcp__claude-code-remote__archive_session`).
   If `create_session` isn't available, stop and say so: run `/handoff` instead, and resume in
   a new session started from the app.
2. **Refuse while work is still running.** Archiving this session kills its container, and with
   it every background shell, subagent and workflow, whose results are then lost. If any is
   still running, list them and stop: the user waits for them, or tells you to stop them. A dev
   server or watcher you started counts too: say it will die, and name it in the note.
3. **Write the note.** Follow steps 1–5 of `handoff.md` (next to this file, in `commands/`),
   with **$ARGUMENTS** as its arguments. Add a fifth section after **Decisions & gotchas**,
   because the new session starts from a fresh clone, on a new container:

   ```markdown
   ## Recreate the environment
   - The exact commands the new session runs before the Next action, in order: worktrees
     (`git worktree add --detach <path> <sha>`), dependencies the environment's setup script
     doesn't install (`npm ci`), history the work needs beyond the clone's 50 commits
     (`git fetch --unshallow`), files from outside the repository.
   ```

   Say "none" if the clone needs nothing. Scratchpad files and anything outside the repository
   don't travel: move what matters into the note or into a commit, or say it's gone. In
   **Current state**, say what stays behind with this container, so `/pickup` in the new session
   expects it to be missing instead of stopping over it.
4. **Push it.** Run `<handoff> commit <note>`. If it refuses, stop and report why; nothing has
   been relayed.
5. **Run the preflight.** Run `<handoff> relay <note>`. It fetches the branch first. If it
   refuses (exit 1), report every reason it gave and stop: the work isn't all on
   `origin/<branch>`, so nothing is relayed. The note is committed, so the user can fix what it
   named (commit, push or pull the work, or track `origin/<branch>`) and run `/handoff:relay`
   again, which replaces the note. On success it prints `source_url`, `branch`, `head`,
   `shallow`, `prompt` and `left behind`.
6. **Account for what stays behind.** Every `left behind` line is lost with this container:
   `untracked` and `ignored` files (another local note, a `.env`), `stash`es, a local `branch`
   with commits on no remote, and each other `worktree` with its uncommitted and unpushed
   counts. When the list ends in `... and N more`, list the rest with `git status --ignored`
   before deciding. Each item the work still needs must be in the note's **Recreate the
   environment**, or committed and pushed; a worktree's recreate command needs a commit the
   remote has. If you change the note, run `<handoff> commit <note>` and the preflight again.
   Name the rest to the user as discarded, and ask before relaying when that includes commits
   or uncommitted work.
7. **Start the new session.** Call `create_session` with:
   - `source_url`: the preflight's `source_url`;
   - `source_revision` and `outcome_branch`: its `branch`, so the new session works on this
     branch instead of a new `claude/…` one;
   - `prompt`: its `prompt`, exactly (`/handoff:pickup <note>`), and nothing more: `/pickup`
     checks the note against the repository, which a pasted summary would skip;
   - `title`: this session's title (from `get_session` with no `session_id`), or the note's
     Next action;
   - `clone_depth`: only when the note's **Recreate the environment** needs more history than
     50 commits and fetching it there won't do.

   Leave out `environment_id`, `model` and `permission_mode`, so the new session inherits this
   one's.
8. **Hand over.** Tell the user the new session's link, `https://claude.ai/code/<session_id>`,
   and the note it resumes. Say that the new session may ask for tool approvals again, since it
   starts with only this session's permission mode. Ask them to open it and confirm that it has
   picked up the note. Until they do, don't change the branch from here: the new session owns
   it now.
9. **Archive this session, once they confirm.** Say in one line that this session is being
   archived and the work continues in the new one, then call `archive_session` with this
   session's id (from `get_session` with no `session_id`). If it fails, give the user the
   error and ask them to archive this session from the app. If they don't want it archived,
   leave it, and warn them not to work on the branch from both sessions. Nothing else follows:
   the container is released.
