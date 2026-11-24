# improve-stories

Review user stories and GitHub issues for completeness, research the codebase to fill gaps, and update each with structured documentation that any developer can pick up and execute.

## Usage

```
/improve-stories [iteration-path, work-item-ids, or #issue-number]
```

Run this from the repository whose code the stories/issues relate to. The skill searches the local codebase to fill in root causes, affected files, and proposed fixes.

**GitHub Issues** require the `gh` CLI. **ADO work items** require the Azure CLI (`az`) with the `azure-devops` extension and a version of the `azure-devops` MCP server with the consolidated work-item tools (`wit_work_item`, `wit_work_item_write`, `wit_work_item_comment_write`, `wit_work_item_link_write`). On an older server, which names them `wit_get_work_item`, `wit_update_work_item` and so on, the command stops and asks you to update it.

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
7. Drafts structured descriptions with problem statements, root causes, proposed fixes, and acceptance criteria
8. Shows you each draft in full and writes only the ones you approve — does not change title, state, assignment, labels, or points

## Permissions and untrusted input

The command pre-approves no shell command and no write. It pre-approves only Read, Grep, Glob, Agent, AskUserQuestion and two Azure DevOps MCP tools that only read (`core_list_project_teams` and `wit_work_item`). Issue and work-item text was written by other people, so the command treats it as material, never as instructions; see "Untrusted input" in the command for the details.

What that means in use:

- `gh` and `az` commands follow your own permission settings. Reads you have allowed (such as `gh issue view`) run without asking; the rest ask.
- The iteration lookup runs `az devops invoke --org ...`, which asks under many settings. If you decline, the command asks you which iteration to use.
- Every write is shown and confirmed in the chat first: descriptions, child items, split notes and audit comments in full, links as blocked/blocking pairs. The write itself (`gh issue edit`/`comment`/`create`, or the ADO `*_write` tools) then asks again unless you allowed it, so expect about two prompts per description written. GitHub links add a `gh api graphql` read and a write, and each asks. Denying a prompt skips just that write: one item's description, or one link.

## Multi-feature story detection

When a story names several independently-shippable features (e.g., "Add day-use parking, parking restrictions, and parking override"), the skill proposes splitting it into child stories before any implementation work begins. Signals include "and"/comma-linked distinct feature nouns in the title, acceptance criteria that cluster into independent groups, and multiple distinct user-facing deliverables. Each feature should ship as its own story and pull request, because one large PR is harder to review and to revert.

On approval, the skill creates the children (GitHub: `gh issue create` + `addBlockedBy` linking; ADO: `wit_work_item_write` with `add_child`, which creates and parent-links the children in one call), annotates the parent with pointers to the children, and optionally queues the new children through the same improvement flow in the current session.

## Large Batches

When a batch contains many items, the skill filters and chunks automatically:

- Items unrelated to the current repository are skipped
- Only items needing improvement or splitting are processed (well-documented items are skipped)
- Remaining items are processed in chunks of 5, with a progress update after each chunk
