---
description: Opt the current repository out of spec-driven development for good, by adding one line to its CLAUDE.md, so an sdd environment works there normally and never asks to set it up
allowed-tools: Bash, Glob
---

Opt this repository out of spec-driven development. The script edits `CLAUDE.md`; you run it,
commit the change, then report.

1. **Locate the script.** It is `${CLAUDE_PLUGIN_ROOT}/scripts/sdd-optout.sh`. If that path
   still reads literally `${CLAUDE_PLUGIN_ROOT}` (the variable wasn't substituted) or the file
   doesn't exist, find it instead: Glob for `**/sdd/**/scripts/sdd-optout.sh` under
   `~/.claude/plugins` (resolve `~` to an absolute path first), skip any candidate whose plugin
   folder (the parent of `scripts/`) contains a `.orphaned_at` marker, and take the first that
   remains. If none remains, tell the user to reinstall the plugin and stop.
2. Run `bash <script> --repo .`. Its last line is `sdd-optout: done`,
   `sdd-optout: already opted out` or `sdd-optout: failed`; before it, on success, it prints
   `root: <repo root>` and `file: <path>`, the file it edited: `CLAUDE.md`, or the file a
   symlinked `CLAUDE.md` points to.
3. On failure, report the error line and stop. A repository already set up for sdd can't opt
   out: say so, and that there is no command that removes sdd. A `CLAUDE.md` with uncommitted
   changes: ask the user to commit or stash them, then run `/sdd:opt-out` again.
4. Already opted out: say so and stop; nothing changed.
5. On success, commit that file alone, from the repo root whatever the current directory:
   `git -C <root> add -- <file>`, then
   `git -C <root> commit -m "Opt out of spec-driven development (sdd)" -- <file>`. The script
   refused a file with changes of its own, so the commit holds only the opt-out line, and every
   other change stays uncommitted.
   On `main` or `master`, ask before committing: many repositories take changes only through a
   pull request. Push only as the repository's own rules and the user say.
6. Report what changed and the commit. Say that sessions now treat the repository as not using
   sdd, and that removing the line from `CLAUDE.md` undoes it.
