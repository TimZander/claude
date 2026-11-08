---
description: Move this repository's TimZander/ci-recipes pins forward, to ci-recipes' main or a given commit
argument-hint: "[commit SHA]"
allowed-tools: Bash, Read, Glob
---

# Update shared CI

Moves every `TimZander/ci-recipes/...@<sha>` pin in `.github/workflows/` (actions and
reusable workflows) to one commit, so the preview, the branch preview and the teardown always
come from the same ci-recipes. It moves pins only: it never adds a caller or changes a
trigger. A setup written before the preview-only route (no `branch-preview.yml`) also lacks
the teardown's `delete:` trigger and the preview's `paths-ignore`, so moving its pin alone
doesn't give it the route: say so, and point at ci-recipes' `templates/` for all three. Pins
move only when someone runs this; there is no Dependabot (ci-recipes decision 0004: every bump PR spends
CI minutes).

## Find the script

It is `${CLAUDE_PLUGIN_ROOT}/scripts/ci.sh`. If that path still reads literally
`${CLAUDE_PLUGIN_ROOT}` or doesn't exist, Glob for `**/ci/**/scripts/ci.sh` under
`~/.claude/plugins` (resolve `~` first), skip candidates whose plugin folder has a
`.orphaned_at` marker, and take the first that remains. Below, `<ci>` means `bash <that path>`.
Run it from the repository's root.

## Steps

1. Run `<ci> update`, adding `--sha <commit>` when **$ARGUMENTS** names one. Exit 3 means it
   refused and changed nothing (no pin here, or the new commit dropped an action this
   repository uses): report its reason and stop.
2. Open the "what changed" link it prints and summarise what this repository picks up, above
   all any changed input or rule in `STANDARD.md`.
3. Leave the change uncommitted unless asked; it goes through the repository's normal flow
   (in an sdd repository, as its own small change).
