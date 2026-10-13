---
description: Set up or update spec-driven development (OpenSpec + the sdd flow) in the current repository
argument-hint: "[--openspec-version <x.y.z>] [--no-ci] [--no-install]"
allowed-tools: Bash, Read
---

Set up this repository for spec-driven development, or update the sdd files it already has.
The installer script does the work; you run it, then report.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdd-init.sh" --repo . $ARGUMENTS`.
   Its last line is `sdd-init: done` (possibly with a warning count) or `sdd-init: failed`.
2. On failure, report the error line and stop.
3. On success, summarise what it added or updated, grouped as plugin files, repo files and
   settings. For each `warning:` line, say what the repo has, what sdd expects, and what the
   owner should decide. In particular:
   - a CLAUDE.md that already describes an OpenSpec workflow: point out the passages that
     `.claude/sdd-workflow.md` now covers, and offer to remove them (don't edit unasked);
   - a different pinned OpenSpec version or a different `prepare` script: kept as is.
4. List the next steps that apply:
   - commit the changes on a branch and open a PR (this is a code-free change);
   - `openspec/specs/` is empty: describe the first capability with `/opsx:propose`;
   - the `sdd-checks` workflow uses `pull_request_target`, so it runs from the default branch
     only after this PR merges; to gate merging, require its `checks` job in branch protection.
