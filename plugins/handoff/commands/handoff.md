---
description: Write a forward-looking resume note for the current work (what's done, what's next, the gotchas) so a fresh context, or a later session, picks up mid-task. Use before /clear, before pausing, when handing work to another session, or when wrapping up for the day. Resume it with /pickup.
argument-hint: "[optional: a note path in docs/handoffs/; defaults to docs/handoffs/<date>.md]"
allowed-tools: Bash, Read, Write
---

# Handoff: leave a resume note

The harness compacts context on its own when it grows long, but that summary is opaque and loses
intent. Before you pause, clear the context or hand work to another session, write a deliberate
note so the next context continues mid-task instead of rebuilding the state from scratch.

The flow is **`/handoff` → `/clear` → `/pickup`**: aim a note, wipe the context on purpose, then
rehydrate from the note. It works the same in a terminal, the desktop app and a cloud session.

A handoff is task state, forward-looking and disposable: "the refactor is half done in
`src/x.ts`; do Y next". `/pickup` deletes the note once it has resumed it, so notes never reach
the base branch with the work. Lasting lessons belong where the repository keeps its rules
(`CLAUDE.md`, or an ADR), not here.

## Find the script

It is `${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh`. If that path still reads literally
`${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for `**/handoff/**/scripts/handoff.sh` under
`~/.claude/plugins` (resolve `~` first), skip candidates whose plugin folder has a
`.orphaned_at` marker, and take the first that remains. Below, `<handoff>` means
`bash <that path>`.

## Steps

1. **Gather the facts.** Run `<handoff> state`. It reports the branch, its upstream and how far
   ahead or behind it is, uncommitted files, stashes, other worktrees, and whether this is a
   cloud session.
2. **Pick the note's path.** Run `<handoff> new` either way: it adds `docs/handoffs/` to the
   repository's `.git/info/exclude`, a local ignore list that is never committed, so the note
   stays out of `git status` and out of every commit. Use **$ARGUMENTS** if it names a path in
   `docs/handoffs/`; otherwise use the free path `new` prints (`docs/handoffs/<date>.md`, or
   `<date>-2.md` …).
3. **Write the note** at that path, with these four sections, tight and file-specific. Write
   only what you know, and say "none" for an empty one:

   ```markdown
   # Handoff <date>

   ## Current state
   Branch `<branch>` (<upstream, ahead/behind>). What's done, what's committed and what isn't,
   what works and what's broken.

   ## Next action
   The literal next step, specific enough to start on immediately.

   ## Remaining work
   1. The rest, in order, briefly.

   ## Decisions & gotchas
   - Choices already made, each with its why, so they aren't argued again.
   - Traps found this session.
   ```

   Lead **Current state** with the facts from step 1, so the next context can trust it. Keep the
   **Next action** to one line straight under its heading: `/pickup` lists notes by it.
4. **Leave nothing stranded.** List in **Current state**, without fixing them unasked: debug
   probes you added and didn't remove, background processes or dev servers you started, worktrees
   you created, and work that exists only on this machine (uncommitted changes, unpushed commits,
   a branch with no upstream, stashes).
5. **Clear out what it replaces.** Run `<handoff> open`. If an older note there is for the same
   work, this note replaces it: delete it with `<handoff> drop <old note>`.
6. **Make it outlive the machine, when it has to.** A note you `/clear` past and `/pickup` right
   away needs no commit: the files are still there. A note that must outlast this machine does:
   resuming tomorrow, in another session, or from another computer. In a **cloud session**
   (`cloud: yes`) the container is reclaimed after a period of inactivity, so commit it without
   asking: run `<handoff> commit <note>`. It commits only the note, pushes the current branch,
   refuses `main` and `master`, and never forces; `/pickup` deletes the note again, in a commit,
   once it resumes. Report the branch, since a later session has to check it out to find the
   note. If `commit` refuses (on `main`, `master` or a detached HEAD), say the note is only on
   this machine and that switching to the work branch and running `/handoff` again saves it.
   Outside a cloud session, commit only if the user asks. A committed note that is never picked
   up is still on the branch: `/craft-pr` refuses to describe a branch that adds one, and
   `<handoff> drop <note>` removes it.
7. **Tell the user** the note's path, whether it was committed, and how to resume: `/clear`, then
   `/pickup` or `/hp` (in a new session: check out the branch first).
