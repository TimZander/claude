---
name: improve-stories
description: Review user stories for completeness, research the codebase to fill gaps, and update each story with structured documentation
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion, mcp__azure-devops__core_list_project_teams, mcp__azure-devops__wit_get_work_items_for_iteration, mcp__azure-devops__wit_get_work_item, mcp__azure-devops__wit_update_work_item, mcp__azure-devops__wit_add_work_item_comment, mcp__azure-devops__wit_my_work_items, mcp__azure-devops__wit_list_backlogs, mcp__azure-devops__wit_list_backlog_work_items, mcp__azure-devops__wit_get_work_items_batch_by_ids
user-input: optional
argument-hint: "[iteration-path or work-item-ids]"
model: opus
---

You are improving user stories so they are actionable, complete, and ready for any developer to pick up. Your deliverable is **updated work item descriptions** — you do NOT begin implementation.

## Step 1: Gather Stories (lightweight fetch)

- If the user provided specific work item IDs, fetch those directly.
- If the user provided an iteration path, resolve it to an iteration ID (see below) and fetch work items for it.
- If no argument was given, detect the current iteration automatically (see below). Tell the user which iteration was detected and proceed. If detection fails (common causes: `az` CLI not installed, not logged in, or `azure-devops` extension missing), tell the user what went wrong and fall back to asking them which iteration to target.
- Filter to the relevant project or area if specified (e.g., a specific area path prefix).

**Use a lightweight batch fetch** to minimize payload size. Request only the fields needed for filtering and triage:
- `System.Id`, `System.Title`, `System.State`, `System.WorkItemType`, `System.AreaPath`, `System.Tags`, `System.AssignedTo`
- Do **not** fetch `System.Description` or `Microsoft.VSTS.Common.AcceptanceCriteria` yet — those are large text fields and most items will be filtered out before they're needed.

### Resolving the Current Iteration

The MCP server's `wit_get_work_items_for_iteration` requires an iteration **ID** (GUID), not a path or name. Use the Azure DevOps REST API via the `az` CLI to resolve iterations:

**Get the current iteration:**
```bash
MSYS_NO_PATHCONV=1 az devops invoke \
  --area work --resource iterations \
  --route-parameters project="PROJECT" team="TEAM" \
  --query-parameters '$timeframe=current' \
  --org ORG_URL -o json
```

**Resolve an iteration path to an ID:**
```bash
MSYS_NO_PATHCONV=1 az devops invoke \
  --area work --resource iterations \
  --route-parameters project="PROJECT" team="TEAM" \
  --org ORG_URL -o json
```
Then find the matching iteration by path or name in the response.

Replace `PROJECT`, `TEAM`, and `ORG_URL` with values from the user's `~/.claude/CLAUDE.md` or the project's `CLAUDE.md`. If no team is specified, use `core_list_project_teams` with `mine=true` to find teams the user belongs to. If exactly one team is returned, use it. If multiple are returned, ask the user which team to target.

The response includes an `id` field (GUID) — pass that to `wit_get_work_items_for_iteration`.

## Step 2: Filter to Repository-Relevant Stories

This skill runs from within a specific repository, which is where codebase research happens. Stories unrelated to this repo cannot be meaningfully improved.

- Read the project's CLAUDE.md and examine the repo structure (top-level directories, solution files, project names) to understand what this codebase covers.
- For each fetched story, check whether its title, description, tags, or area path relate to this repository's domain. Look for mentions of components, services, namespaces, or features that exist in this codebase.
- **Keep** stories that clearly relate to this repo or are ambiguous enough that research might clarify them.
- **Skip** stories that clearly belong to a different codebase or domain (e.g., a mobile app story when you're in a backend API repo).
- If all stories are filtered out, tell the user and suggest which repo might be more appropriate.

## Step 3: Triage

### 3a: Filter by state (from lightweight data)

Using the fields already fetched, skip items without needing their descriptions:

**Already in progress** (skip) — state is Active, In Progress, Resolved, or any non-New/non-Proposed state. A developer has already started work and changing the description under them could be disruptive.

### 3b: Fetch full details for remaining candidates

For items that survived Steps 1-3a, fetch `System.Description` and `Microsoft.VSTS.Common.AcceptanceCriteria` using `wit_get_work_items_batch_by_ids`. Fetch in batches of up to 10.

### 3c: Classify with full details

**Well-documented** (skip) — has a clear description, acceptance criteria, and enough context to start work.

**Needs improvement** — flag if ANY of these are true:
- Empty or near-empty description
- No acceptance criteria
- Description is a single vague sentence with no context
- Missing steps to reproduce (for bugs)
- No mention of affected files or components

Present the triage summary to the user:
- How many stories were fetched, how many were filtered as irrelevant, how many are well-documented, how many need improvement
- List which stories you plan to improve and why
- List which stories you're skipping and why
- If more than 10 stories need improvement, recommend processing in chunks and ask the user how many to tackle now
- Ask the user to confirm before proceeding
- If the user declines, asks to skip specific stories, or wants to add stories that were filtered out, adjust the selection accordingly and re-present the updated plan

## Step 4: Research and Update (chunked)

Process stories in chunks of up to 5 at a time. For each chunk:

### 4a: Research

For each story in the chunk, research the codebase:

- **Parse the title and description** for keywords — component names, enum values, UI elements, error descriptions
- **Search the codebase** for related files, components, models, and services using Grep and Glob
- **Trace the code path** from UI to data layer to understand the full flow
- **Identify the root cause** (for bugs) or the exact change scope (for features)
- **Check for existing patterns** — does the codebase already solve a similar problem elsewhere?
- **Review tests** — do existing tests cover or contradict the reported behavior?

Use the Agent tool to parallelize research across stories within the chunk.

### 4b: Detect Description Format

Only needs to be done once (for the first chunk). Examine the descriptions fetched in Step 3b to determine whether the project uses **HTML** or **Markdown** for descriptions.

- Look at well-documented stories (the ones you skipped in 3c) and any non-empty descriptions on the stories you're improving.
- HTML indicators: `<div>`, `<br>`, `<b>`, `<ol>`, `<ul>`, `<li>`, `<h2>`, `&nbsp;`, inline `style=` attributes.
- Markdown indicators: `##` headings, `**bold**`, `- ` bullet lists, `1. ` numbered lists, backtick code spans.
- Match whatever format the existing stories use. If the project mixes both, prefer the format used by the majority.
- If all existing descriptions are empty (no signal), default to HTML since that is the ADO native format.

### 4c: Write the Updated Descriptions

Use the appropriate template based on the work item type. **Write in whichever format you detected in Step 4b** — the examples below show both.

#### For Bugs:

**Markdown version:**
```
## Problem
What is happening and where. Be specific about the component/page.

## Steps to Reproduce
1. Start from [clear starting state]
2. Do [action]
3. Observe [result]

## Expected vs Actual Behavior
What should happen vs what actually happens.

## Root Cause
The specific code location and why it fails. Include file paths and line numbers.

## Proposed Fix
The recommended approach. Reference existing patterns in the codebase.

## Acceptance Criteria
Numbered list. Each item is independently testable.
```

**HTML version:**
```html
<h2>Problem</h2>
<p>What is happening and where. Be specific about the component/page.</p>

<h2>Steps to Reproduce</h2>
<ol>
<li>Numbered steps to reliably trigger the bug. Start from a clear starting state.</li>
</ol>

<h2>Expected vs Actual Behavior</h2>
<p>What should happen vs what actually happens.</p>

<h2>Root Cause</h2>
<p>The specific code location and why it fails. Include file paths and line numbers.</p>

<h2>Proposed Fix</h2>
<p>The recommended approach. Reference existing patterns in the codebase.</p>

<h2>Acceptance Criteria</h2>
<ol>
<li>Each item is independently testable.</li>
</ol>
```

#### For Features:

**Markdown version:**
```
## Goal
What capability is being added and why.

## Current Behavior
What happens today (or what's missing).

## Proposed Solution
The recommended approach. Reference existing patterns, files to modify.

## Acceptance Criteria
Numbered list. Each item is independently testable.
```

**HTML version:**
```html
<h2>Goal</h2>
<p>What capability is being added and why.</p>

<h2>Current Behavior</h2>
<p>What happens today (or what's missing).</p>

<h2>Proposed Solution</h2>
<p>The recommended approach. Reference existing patterns, files to modify.</p>

<h2>Acceptance Criteria</h2>
<ol>
<li>Each item is independently testable.</li>
</ol>
```

#### Acceptance Criteria Guidelines

Each criterion must be:
- **Specific** — names the exact behavior, not "it works correctly"
- **Testable** — a reviewer can verify pass/fail unambiguously
- **Independent** — doesn't depend on other criteria to make sense

Always include:
- The primary happy-path behavior
- At least one edge case or negative scenario
- Regression safety ("existing X behavior remains unchanged")
- Test coverage expectations if the change touches logic

### 4d: Quality Check

Before updating each story, verify:
- A developer unfamiliar with the code could start work from the description alone
- Root cause or change scope references specific files/lines
- Steps to reproduce are numbered and start from a clear state (for bugs)
- Expected vs actual behavior is explicitly stated (for bugs)
- Current behavior description is concrete, not abstract (for features)
- Acceptance criteria are numbered and independently testable
- Proposed fix leverages existing codebase patterns where possible
- Open questions are called out explicitly (e.g., "Confirm whether X should also be updated")

### 4e: Update the Work Items

- If the story already has description content, incorporate any relevant context from the original into the new structured description. Do not silently discard product owner notes, links, stakeholder references, or edge case mentions — weave them into the appropriate section of the template.
- **Preserve all images and attachments.** Scan the original HTML for `<img>` tags (typically pointing to `_apis/wit/attachments/...`). These are screenshots, mockups, or reference images added by the author. Include them in the new description — either inline in the relevant section or in a dedicated "Reference Images" section at the end. Never drop `<img>` tags during a rewrite.
- Write the updated description to each ADO work item using the update tool.
- After each successful update, add a brief work item comment noting what was changed (e.g., "Description restructured — added root cause analysis, acceptance criteria, and proposed fix based on codebase research."). This creates an audit trail so reviewers know the description was reworked.
- Do NOT change title, state, assignment, or story points.
- Do NOT begin implementation — the deliverable is the updated story.
- If an update fails, report the error and continue with the remaining stories.

### 4f: Chunk Progress

After completing each chunk, report progress to the user:
- Which stories were updated in this chunk
- How many stories remain
- Continue to the next chunk automatically unless the user intervenes

## Step 5: Summary

After all chunks are complete, present a final summary:
- How many stories were fetched, filtered, skipped, and improved
- For each improved story: the work item ID, title, and a one-line summary of what was added
