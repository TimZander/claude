# start-work

Bookend to `craft-pr`. Encodes the **Git Hygiene Before New Work**, **Branch Naming and PR Linking**, and **Mark Work Items Active** team procedures so every developer lands on the same starting line when picking up a card.

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

1. **Detect source** — decided from the `origin` remote's host (by the bundled `origin-info.sh`, which never prints the URL). On a github.com origin `#NN` is a GitHub issue and a bare ID asks; on an Azure DevOps origin both `NN` and `#NN` are work items. Any other host — GitHub Enterprise, a fork or mirror elsewhere — or no `origin` always asks. (Before this version, `#NN` always meant GitHub and a bare ID was routed by whether the repository had a GitHub remote.)
2. **Fetch the card** — title, description, state, assignee, and (ADO) area path and tags.
   - **Check it before any branch exists** — for ADO, the state guard (by the state's category in the work-item type), the target state, your sign-in address, and whether the card is assigned to someone else are all settled here, so a "no" leaves nothing to clean up. For GitHub, a closed or already-assigned issue asks first.
3. **Run Git Hygiene** — verify clean tree, fetch `origin/<base>`. The new branch is rooted directly at the latest `origin/<base>` tip, so no fast-forward of local `<base>` is needed.
4. **Create the branch** — `branches/<id>-<slug>` from clean base, slug derived from the title (kebab-case, ≤ 50 chars).
5. **Worktree by default** — branch lives in `.claude/worktrees/<id>-<slug>` for isolation. `--no-worktree` opts out.
6. **Mark work item active** — `gh issue edit --add-assignee @me` for GitHub. For ADO it applies what step 2 settled: moves the card to `Active` (or the state you chose when the type has none) and assigns it to you, in one update guarded by the card's revision.
7. **Codebase research** — Explore subagent scoped to keywords from the card returns a short punch list of touched files.
8. **Draft plan handoff** — present the card + research + suggested approach for your review before any implementation begins.

## Why a worktree by default

Worktrees keep new work isolated from the main checkout: uncommitted changes and untracked files in the parent stay put, switching contexts between tasks is one `cd` away, and there's no need to stash or juggle. The team standard documents `branches/<id>-<slug>` naming; the worktree just adds isolation on top of that — same branch name either way.

## Requirements

- `git` 2.31+ (worktree support and `rev-parse --path-format`)
- **GitHub:** `gh` CLI authenticated for the target repo
- **ADO:** the consolidated Azure DevOps MCP server — the generation with `wit_work_item` and `wit_work_item_write`. No `az` CLI is needed. Reading the card is pre-approved; the state and assignee update goes through your permission settings and may prompt. Shell commands (including `gh issue edit` on the GitHub path) are still pre-approved; narrowing that is [#284](https://github.com/TimZander/claude/issues/284).
  - **On an older server** (per-operation tools such as `wit_get_work_item`), the ADO path stops and says the server needs updating. The GitHub path is unaffected.
