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
| `/handoff [note]` | Writes `docs/handoffs/<date>.md` with four sections (Current state, Next action, Remaining work, Decisions & gotchas), lists anything left stranded (uncommitted or unpushed work, debug probes, background processes, worktrees), and adds an `open` row to the index `docs/handoffs/README.md` |
| `/pickup [note]` | Takes the newest `open` note, checks it against `git status` before trusting it, carries the decisions forward, marks the row `resumed`, and starts on the next action |

### Cloud sessions

A note you `/clear` past and `/pickup` straight away needs nothing more: the files are still
there. A note that must outlive the container does, since a cloud session's container is
reclaimed after a period of inactivity. So in a cloud session `/handoff` asks whether to commit
and push it. That commit holds only the note and the index, goes on the current branch (never
`main` or `master`), and is never forced. A later session finds it with `/pickup`, which also
looks for open notes on remote branches when the current one has none.

Outside a cloud session nothing is committed unless you ask.

## Files

- `commands/handoff.md`, `commands/pickup.md`: the two commands.
- `scripts/handoff.sh`: the bookkeeping both call: `state`, `new`, `add`, `set`, `open`,
  `remote`, `commit` (see its header).
- `templates/index.md`: the index a repository starts with.

The index is plain Markdown, so any person or tool can read it. Keep its table as it is: the
script edits it.

## Tests

```
bash plugins/handoff/scripts/test_handoff.sh
```

Runs against real git repos with a bare origin, offline. CI runs it on Linux and macOS
(`test-handoff-scripts.yml`).

## Attribution

Adapted from the `/handoff` and `/pickup` commands of
[keystone](https://github.com/j-loyd/keystone) by Jordan Loyd (version 0.9.0), under the MIT
License. Changes here: the index bookkeeping moved into a tested script; keystone's
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
