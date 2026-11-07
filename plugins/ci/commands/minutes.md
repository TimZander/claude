---
description: Report the billed GitHub Actions minutes of one or more pull requests
argument-hint: "<pr-number>... [--repo OWNER/NAME]"
allowed-tools: Bash, Glob
---

# CI minutes

Counts every Actions run of a PR's branch and of its merge commit, each job rounded up to a
whole minute as GitHub bills them, re-runs included. Report the figure with the agent's model
spend when a PR merges. Needs `gh` and `python3`.

## Find the script

It is `${CLAUDE_PLUGIN_ROOT}/scripts/ci.sh`. If that path still reads literally
`${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for `**/ci/**/scripts/ci.sh` under
`~/.claude/plugins` (resolve `~` first), skip candidates whose plugin folder has a
`.orphaned_at` marker, and take the first that remains. Below, `<ci>` means `bash <that path>`.
Run it from the repository's root.

## Steps

1. Run `<ci> minutes $ARGUMENTS`. Without `--repo` it measures the repository of the
   current directory.
2. Give the billed minutes per PR and the split by workflow. Name the largest workflow, since
   that is where a saving would come from. A public repository is not billed: say so, and that
   the figure is what it would cost on a private one.
