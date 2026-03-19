# improve-stories

Review user stories for completeness, research the codebase to fill gaps, and update each story with structured documentation that any developer can pick up and execute.

## Usage

```
/improve-stories [iteration-path or work-item-ids]
```

Run this from the repository whose code the stories relate to. The skill searches the local codebase to fill in root causes, affected files, and proposed fixes.

Requires the Azure CLI (`az`) with the `azure-devops` extension, and the `azure-devops` MCP server configured in your Claude Code settings.

Examples:
- `/improve-stories` — auto-detects the current sprint
- `/improve-stories "Project\Sprint 5"` — targets a specific sprint
- `/improve-stories 12345 12346 12347` — targets specific work items

## What It Does

1. Fetches stories from Azure DevOps (by iteration, backlog, or specific IDs)
2. Filters to stories relevant to the current repository
3. Triages each story and asks you to confirm before making changes
4. Researches the codebase for each poorly-scoped story
5. Detects whether the project uses HTML or Markdown descriptions and matches the format
6. Writes structured descriptions with problem statements, root causes, proposed fixes, and acceptance criteria
7. Updates the ADO work items — does not change title, state, assignment, or points

## Large Iterations

When an iteration contains many stories, the skill filters and chunks automatically:

- Stories unrelated to the current repository are skipped
- Only stories needing improvement are processed (well-documented stories are skipped)
- Remaining stories are processed in chunks of 5, with a progress update after each chunk
