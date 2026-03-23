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
4. Triages each item and asks you to confirm before making changes
5. Researches the codebase for each poorly-scoped item
6. Writes structured descriptions with problem statements, root causes, proposed fixes, and acceptance criteria
7. Updates the items — does not change title, state, assignment, labels, or points

## Large Batches

When a batch contains many items, the skill filters and chunks automatically:

- Items unrelated to the current repository are skipped
- Only items needing improvement are processed (well-documented items are skipped)
- Remaining items are processed in chunks of 5, with a progress update after each chunk
