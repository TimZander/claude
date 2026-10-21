---
description: Set up or update spec-driven development (OpenSpec + the sdd flow) in the current repository
argument-hint: "[--openspec-version <x.y.z>] [--no-ci] [--no-install]"
allowed-tools: Bash, Read, Glob
---

Set up this repository for spec-driven development, or update the sdd files it already has.
The installer script does the work; you run it, then report.

1. **Locate the installer.** It is `${CLAUDE_PLUGIN_ROOT}/scripts/sdd-init.sh`. If that path
   still reads literally `${CLAUDE_PLUGIN_ROOT}` (the variable wasn't substituted) or the file
   doesn't exist, find it instead: Glob for `**/sdd/**/scripts/sdd-init.sh` under
   `~/.claude/plugins` (resolve `~` to an absolute path first), skip any candidate whose plugin
   folder (the parent of `scripts/`) contains a `.orphaned_at` marker, and take the first that
   remains. If none remains, tell the user to reinstall the plugin and stop.
2. Run `bash <installer> --repo . $ARGUMENTS`.
   Its last line is `sdd-init: done` (possibly with a warning count) or `sdd-init: failed`.
3. On failure, report the error line and stop.
4. On success, summarise what it added or updated, grouped as plugin files, repo files and
   settings. For each `warning:` line, say what the repo has, what sdd expects, and what the
   owner should decide. In particular:
   - a CLAUDE.md that already describes an OpenSpec workflow: point out the passages that
     `.claude/sdd-workflow.md` now covers, and offer to remove them (don't edit unasked);
   - a different pinned OpenSpec version or a different `prepare` script: kept as is. If the
     repo pins an OpenSpec older than 1.14.1, pass on the warning that 1.14.1's strict validation
     fails requirement text over 500 characters: the owner should split long requirements, on
     the old version, before bumping it in its own PR;
   - an active change without `base-pins.json`: `check-specs` fails until it is pinned. Pin it
     with `npm run spec:pin -- <name>` only after checking its deltas still hold the main spec's
     current text of every requirement they modify (pinning blesses that text);
   - invalid `sdd` settings in `package.json`: quote the message; the scripts fail until fixed;
   - no `package-lock.json`: CI's `npm ci` needs one, so run `npm install` and commit the lock.
   - `removed the sdd opt-out from CLAUDE.md`: not a warning, but name it, since the repository
     had opted out of sdd before.
5. List the next steps that apply:
   - commit the changes on a branch and open a PR (this is a code-free change);
   - `openspec/specs/` is empty: describe the first capability with `/opsx:propose`;
   - the `sdd-checks` workflow uses `pull_request_target`, so it runs from the default branch
     only after this PR merges; to gate merging, require its `checks` job in branch protection
     (or, with `"sdd": { "statuses": true }`, the `sdd/<check>` statuses one by one);
   - a repository with its own copies of what sdd now does (pin scripts, a requirements check, a
     main-spec diff, its own archive check): offer to retire them, one PR each, after this one
     merges and the new checks have run on a PR.
