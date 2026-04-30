# start-work

Bookend to `craft-pr`. Encodes the **Git Hygiene Before New Work**, **Branch Naming and PR Linking**, and **Mark Work Items Active** procedures from `standards/CLAUDE.md` so every developer lands on the same starting line when picking up a card.

## Usage

```
/start-work 7212         # ADO work item by ID
/start-work #29          # GitHub issue by number
/start-work              # detect next priority from "my work items" / assigned issues
```

Optional flags:

- `--base <branch>` — base the new branch on a non-`main` branch (e.g., a long-lived feature branch). Default: `main`.
- `--no-worktree` — skip worktree creation; create the branch in the current checkout instead. Default: a worktree is created at `.claude/worktrees/<id>-<slug>` for parallel multi-task isolation.

## What it does

1. **Detect source** — GitHub issue (`#NN`) or ADO work item (bare ID), same logic as `improve-stories`.
2. **Fetch the card** — title, description, area path, current state, dependencies.
3. **Run Git Hygiene** — verify clean tree, fetch `origin/<base>`. The new branch is rooted directly at the latest `origin/<base>` tip, so no fast-forward of local `<base>` is needed.
4. **Create the branch** — `branches/<id>-<slug>` from clean base, slug derived from the title (kebab-case, ≤ 50 chars).
5. **Worktree by default** — branch lives in `.claude/worktrees/<id>-<slug>` for isolation. `--no-worktree` opts out.
6. **Mark work item active** — `gh issue edit --add-assignee @me` for GitHub; ADO transitions to `Active` and self-assigns.
7. **Codebase research** — Explore subagent scoped to keywords from the card returns a short punch list of touched files.
8. **Draft plan handoff** — present the card + research + suggested approach for your review before any implementation begins.

## Why a worktree by default

Worktrees keep new work isolated from the main checkout: uncommitted changes and untracked files in the parent stay put, switching contexts between tasks is one `cd` away, and there's no need to stash or juggle. The team standard documents `branches/<id>-<slug>` naming; the worktree just adds isolation on top of that — same branch name either way.

## Requirements

- `git` 2.20+ (worktree support)
- **GitHub:** `gh` CLI authenticated for the target repo
- **ADO:** `az` CLI with the `azure-devops` extension and the Azure DevOps MCP server, both already required by `improve-stories`
