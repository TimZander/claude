# improve-stories

Review user stories and GitHub issues for completeness, research the codebase to fill gaps, and update each with structured documentation that any developer can pick up and execute.

## Usage

```
/improve-stories [iteration-path, work-item-ids, or #issue-number]
```

Run this from the repository whose code the stories/issues relate to. The skill searches the local codebase to fill in root causes, affected files, and proposed fixes.

**GitHub Issues** require the `gh` CLI. **ADO work items** require the Azure CLI (`az`) with the `azure-devops` extension and the `azure-devops` MCP server.

Examples:
- `/improve-stories` — auto-detects: open GitHub issues (if repo has GitHub remote) or current ADO sprint
- `/improve-stories #29` — targets a specific GitHub issue
- `/improve-stories #29 #30 #31` — targets multiple GitHub issues
- `/improve-stories "Project\Sprint 5"` — targets a specific ADO sprint
- `/improve-stories 12345 12346 12347` — targets specific ADO work items

## What It Does

1. Detects the source (GitHub Issues or Azure DevOps) based on the argument
2. Fetches items with a lightweight query, then full details only for candidates
3. Filters to items relevant to the current repository
4. Triages each item: **well-documented** (skip), **needs improvement** (rewrite), or **multi-feature** (propose a split into child stories)
5. For multi-feature items, drafts a split plan and asks you to confirm before creating any child items. Never auto-splits.
6. Researches the codebase for each item that needs improvement
7. Writes structured descriptions with problem statements, root causes, proposed fixes, and acceptance criteria
8. Updates the items — does not change title, state, assignment, labels, or points

## Multi-feature story detection

When a story names several independently-shippable features (e.g., "Add day-use parking, parking restrictions, and parking override"), the skill proposes splitting it into child stories before any implementation work begins. Signals include "and"/comma-linked distinct feature nouns in the title, acceptance criteria that cluster into independent groups, and multiple distinct user-facing deliverables. Rationale and thresholds live in `standards/CLAUDE.md` → **PR Size and Splitting** (the team standard this extension enforces upstream).

On approval, the skill creates the children (GitHub: `gh issue create` + `addBlockedBy` linking; ADO: `wit_add_child_work_items` for atomic create-and-parent-link), annotates the parent with pointers to the children, and optionally queues the new children through the same improvement flow in the current session.

## Large Batches

When a batch contains many items, the skill filters and chunks automatically:

- Items unrelated to the current repository are skipped
- Only items needing improvement or splitting are processed (well-documented items are skipped)
- Remaining items are processed in chunks of 5, with a progress update after each chunk
