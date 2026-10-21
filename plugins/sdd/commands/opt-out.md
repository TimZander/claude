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
   `sdd-optout: already opted out` or `sdd-optout: failed`.
3. On failure, report the error line and stop. For a repository already set up for sdd, say
   that opting out doesn't remove sdd, and ask whether they want it removed instead.
4. Already opted out: say so and stop; nothing changed.
5. On success, commit `CLAUDE.md` alone (`git commit -m "Opt out of spec-driven development (sdd)" -- CLAUDE.md`,
   after `git add CLAUDE.md` if the script created it), leaving any other change uncommitted.
   On `main` or `master`, ask before committing: many repositories take changes only through a
   pull request. Push only as the repository's own rules and the user say.
6. Report what changed and the commit. Say that sessions now treat the repository as not using
   sdd, and that removing the line from `CLAUDE.md` undoes it.
