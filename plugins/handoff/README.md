# handoff

Deliberate continuity between contexts. `/handoff` writes a short resume note for the work in
progress; `/pickup` reads it back and continues from where it stopped. The flow is
**`/handoff` → `/clear` → `/pickup`**: aim a note, wipe the context on purpose, rehydrate from
the note, instead of relying on the harness's automatic compaction, which keeps the facts and
loses the intent.

It works the same in a terminal, the desktop app and a cloud session.

## Install

```
/plugin install handoff@tzander-skills
```

## Commands

| Command | What it does |
|---|---|
| `/handoff [note]` | Writes `docs/handoffs/<date>.md` with four sections (Current state, Next action, Remaining work, Decisions & gotchas), lists anything left stranded (uncommitted or unpushed work, debug probes, background processes, worktrees), and deletes an older note it replaces |
| `/pickup [note]` | Takes the newest note, checks it against `git status` before trusting it, carries the decisions forward, deletes the note, and starts on the next action |
| `/hh [note]`, `/hp [note]` | Shortcuts for `/handoff` and `/pickup` |

### Notes stay off the base branch

A note is disposable task state, so it should never merge into `main` with the work:

- **Local by default.** `/handoff` adds `docs/handoffs/` to the repository's
  `.git/info/exclude`, a local ignore list that is never committed. Notes don't show in
  `git status` and no `git add -A` picks them up. There is no index: a note waits to be picked
  up for as long as its file exists.
- **Deleted on pickup.** Once `/pickup` has checked a note against the repository, and moved
  anything lasting from its "Decisions & gotchas" into `CLAUDE.md` or an ADR, it deletes it.
- **Committed only to outlive a container.** A note you `/clear` past and `/pickup` straight away
  needs nothing more: the file is still there. A cloud session's container is reclaimed after a
  period of inactivity, so there `/handoff` commits and pushes the note without asking. That commit
  holds only the note, goes on the current branch (never `main` or `master`), and is never
  forced. A later session finds it with `/pickup`, which looks on remote branches when the
  current one has none, and whose deletion is a commit of its own, pushed, so the branch stops
  adding the note. On `main` (a PR that merged before pickup) the deletion is staged for the
  next work branch's first commit, since the script never commits there.
- **Guarded at PR time.** `/craft-pr` stops if the branch still adds a note under
  `docs/handoffs/`, so one that was never picked up can't slip into a PR.

Outside a cloud session nothing is committed unless you ask. An older version kept an index at
`docs/handoffs/README.md`; it is no longer read, and can be deleted.

## Files

- `commands/handoff.md`, `commands/pickup.md`: the two commands; `commands/hh.md` and
  `commands/hp.md` are shortcuts that follow them.
- `scripts/handoff.sh`: the bookkeeping both call: `state`, `new`, `open`, `remote`, `commit`,
  `drop` (see its header).

## Tests

```
bash plugins/handoff/scripts/test_handoff.sh
```

Runs against real git repos with a bare origin, offline. CI runs it on Linux and macOS
(`test-handoff-scripts.yml`).

## Attribution

Adapted from the `/handoff` and `/pickup` commands of
[keystone](https://github.com/j-loyd/keystone) by Jordan Loyd (version 0.9.0), under the MIT
License. Changes here: the bookkeeping moved into a tested script, and the index was dropped in
favor of deleting a note once it is picked up; keystone's
`subagent-driven-development` run-state resume, `/pause` and `/learn` hand-offs were left out;
and cloud sessions can commit and push a note so it outlives the container.

keystone's license notice:

```
MIT License

Copyright (c) 2026 Jordan Loyd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
