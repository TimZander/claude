---
name: improve-stories
description: Review user stories and GitHub issues for completeness, research the codebase to fill gaps, and update each with structured documentation
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion, mcp__azure-devops__core_list_project_teams, mcp__azure-devops__wit_get_work_items_for_iteration, mcp__azure-devops__wit_get_work_item, mcp__azure-devops__wit_update_work_item, mcp__azure-devops__wit_add_work_item_comment, mcp__azure-devops__wit_my_work_items, mcp__azure-devops__wit_list_backlogs, mcp__azure-devops__wit_list_backlog_work_items, mcp__azure-devops__wit_get_work_items_batch_by_ids, mcp__azure-devops__wit_work_items_link
user-input: optional
argument-hint: "[iteration-path, work-item-ids, or #issue-number]"
model: opus
---

You are improving user stories and issues so they are actionable, complete, and ready for any developer to pick up. Your deliverable is **updated descriptions** — you do NOT begin implementation.

This skill supports two sources: **Azure DevOps work items** and **GitHub Issues**. Detect which source to use in Step 1, then follow the appropriate path in each step.

## Step 0: Detect Source

Determine whether the user is targeting GitHub Issues or ADO work items:

- **GitHub** if the argument contains `#` (e.g., `#29`, `#29 #30`), or uses the word `issue`/`issues`
- **ADO** if the argument is an iteration path (contains `\`), or references ADO concepts (iteration, sprint, area path)
- **Bare numbers** (e.g., `29`, `12345 12346`) are ambiguous — check if the repo has a GitHub remote (`gh repo view --json url 2>/dev/null`). If yes, ask the user: "Did you mean GitHub issue #29 or ADO work item 29?" If no GitHub remote, route to ADO.
- **No argument:** Check if the repo has a GitHub remote. If yes, offer to process open GitHub issues. If no, fall back to ADO iteration detection.

Once the source is determined, follow the corresponding path in each step below.

## Step 1: Gather Items (lightweight fetch)

### GitHub path

- **Specific issues:** If the user provided issue numbers, fetch them with `gh issue view <number> --json number,title,state,labels,assignees,body`. Since the body is already fetched, these issues can skip Step 3b.
- **All open issues:** Run `gh issue list --state open --json number,title,state,labels,assignees --limit 100` for a lightweight fetch. Do **not** fetch `body` yet — it's the largest field and most issues will be filtered out. Note: only the 100 most recent open issues are fetched. If the repo has more, tell the user and suggest narrowing with labels or specific issue numbers.
- Tell the user how many open issues were found and proceed.

### ADO path

- If the user provided specific work item IDs, fetch those directly.
- If the user provided an iteration path, resolve it to an iteration ID (see below) and fetch work items for it.
- If no argument was given, detect the current iteration automatically (see below). Tell the user which iteration was detected and proceed. If detection fails (common causes: `az` CLI not installed, not logged in, or `azure-devops` extension missing), tell the user what went wrong and fall back to asking them which iteration to target.
- Filter to the relevant project or area if specified (e.g., a specific area path prefix).

**Use a lightweight batch fetch** to minimize payload size. Request only the fields needed for filtering and triage:
- `System.Id`, `System.Title`, `System.State`, `System.WorkItemType`, `System.AreaPath`, `System.Tags`, `System.AssignedTo`
- Do **not** fetch `System.Description` or `Microsoft.VSTS.Common.AcceptanceCriteria` yet — those are large text fields and most items will be filtered out before they're needed.

### Resolving the Current Iteration (ADO only)

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

## Step 2: Filter to Repository-Relevant Items

This skill runs from within a specific repository, which is where codebase research happens. Items unrelated to this repo cannot be meaningfully improved.

- Read the project's CLAUDE.md and examine the repo structure (top-level directories, solution files, project names) to understand what this codebase covers.
- For each fetched item, check whether its title, description, tags, labels, or area path relate to this repository's domain. Look for mentions of components, services, namespaces, or features that exist in this codebase.
- **Keep** items that clearly relate to this repo or are ambiguous enough that research might clarify them.
- **Skip** items that clearly belong to a different codebase or domain (e.g., a mobile app story when you're in a backend API repo).
- If all items are filtered out, tell the user and suggest which repo might be more appropriate.

## Step 3: Triage

### 3a: Filter by state (from lightweight data)

Using the fields already fetched, skip items without needing their full descriptions:

**GitHub:** Skip closed issues. Skip issues that have both an assignee and a linked pull request or branch (someone is actively working on them). Issues with only an assignee but no linked PR are kept — many teams assign at triage before work begins.

**ADO:** Skip items where state is Active, In Progress, Resolved, or any non-New/non-Proposed state. A developer has already started work and changing the description under them could be disruptive.

### 3b: Fetch full details for remaining candidates

**GitHub:** For issues that survived Steps 1-3a, fetch their body with `gh issue view <number> --json number,title,body,labels`. Fetch in parallel (up to 5 concurrent `gh issue view` calls via the Agent tool).

**ADO:** For items that survived Steps 1-3a, fetch `System.Description` and `Microsoft.VSTS.Common.AcceptanceCriteria` using `wit_get_work_items_batch_by_ids`. Fetch in batches of up to 10.

### 3c: Classify with full details

**Well-documented** (skip) — has a clear description, acceptance criteria, and enough context to start work.

**Needs improvement** — flag if ANY of these are true:
- Empty or near-empty description/body
- No acceptance criteria
- Description is a single vague sentence with no context
- Missing steps to reproduce (for bugs)
- No mention of affected files or components

**Detecting item type:** For ADO, use `System.WorkItemType`. For GitHub, infer from labels — issues labeled `bug` are bugs, others are features. If no labels exist, infer from the title and body content (error reports, "broken", "doesn't work" → bug; otherwise feature).

Present the triage summary to the user:
- How many items were fetched, how many were filtered as irrelevant, how many are well-documented, how many need improvement
- List which items you plan to improve and why
- List which items you're skipping and why
- If more than 10 items need improvement, recommend processing in chunks and ask the user how many to tackle now
- Ask the user to confirm before proceeding
- If the user declines, asks to skip specific items, or wants to add items that were filtered out, adjust the selection accordingly and re-present the updated plan

## Step 4: Research and Update (chunked)

Process items in chunks of up to 5 at a time. For each chunk:

### 4a: Research

For each item in the chunk, research the codebase:

- **Parse the title and description** for keywords — component names, enum values, UI elements, error descriptions
- **Search the codebase** for related files, components, models, and services using Grep and Glob
- **Trace the code path** from UI to data layer to understand the full flow
- **Identify the root cause** (for bugs) or the exact change scope (for features)
- **Check for existing patterns** — does the codebase already solve a similar problem elsewhere?
- **Review tests** — do existing tests cover or contradict the reported behavior?

Use the Agent tool to parallelize research across items within the chunk.

### 4b: Dependency Analysis

After researching all items in the chunk, analyze them for dependencies. This step only applies when the chunk contains 2+ items. Note: dependencies between items in different chunks won't be detected — if cross-chunk dependencies are a concern, process all items in a single chunk or ask the user to run the skill on the specific items together.

**Detection — check for:**
- **Overlapping code paths:** Does one item's proposed fix touch code that another item also modifies? If so, one likely needs to land first.
- **Prerequisite changes:** Does a bug's root cause live in a component that a feature item is adding or changing? The feature may need to land first.
- **Explicit mentions:** Scan titles and descriptions for references to other items (e.g., "after #45 is done", "depends on PBI 12345", "blocked by #30").
- **Assumed completion:** Do acceptance criteria of one item assume another item is already done?

**Reporting — present to user before acting:**
- List each proposed dependency with: blocked item, blocking item, and a one-sentence rationale
- Allow the user to approve, reject, or modify each relationship individually
- Do not create any relationships without user confirmation

**Setting relationships (after confirmation):**

**GitHub:** Use the GraphQL `addBlockedBy` mutation (documented in `standards/CLAUDE.md`). First fetch node IDs for the affected issues, then create the relationships. Before creating, query existing `blockedBy` relationships to avoid duplicates — `addBlockedBy` is not idempotent and will error on duplicates.

**ADO:** Use `wit_work_items_link` with type `predecessor` (the blocking item) / `successor` (the blocked item). Example: if item 100 blocks item 101, link item 101 with `linkToId: 100, type: "predecessor"`. ADO also errors on duplicate links — check existing links on the work item before creating new ones.

**Description integration:** When a dependency is confirmed, reference it in the relevant description section:
- For bugs: note in "Root Cause" or "Proposed Fix" if the fix depends on another item
- For features: note in "Proposed Solution" if the feature requires another item first

### 4c: Detect Description Format

Only needs to be done once (for the first chunk).

**GitHub:** Always use Markdown. Skip format detection.

**ADO:** Examine the descriptions fetched in Step 3b to determine whether the project uses **HTML** or **Markdown** for descriptions.

- Look at well-documented items (the ones you skipped in 3c) and any non-empty descriptions on the items you're improving.
- HTML indicators: `<div>`, `<br>`, `<b>`, `<ol>`, `<ul>`, `<li>`, `<h2>`, `&nbsp;`, inline `style=` attributes.
- Markdown indicators: `##` headings, `**bold**`, `- ` bullet lists, `1. ` numbered lists, backtick code spans.
- Match whatever format the existing items use. If the project mixes both, prefer the format used by the majority.
- If all existing descriptions are empty (no signal), default to HTML since that is the ADO native format.

### 4d: Write the Updated Descriptions

Use the appropriate template based on the item type. **Write in whichever format you detected in Step 4c** — the examples below show both.

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

**HTML version (ADO only):**
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

**HTML version (ADO only):**
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

### 4e: Quality Check

Before updating each item, verify:
- A developer unfamiliar with the code could start work from the description alone
- Root cause or change scope references specific files/lines
- Steps to reproduce are numbered and start from a clear state (for bugs)
- Expected vs actual behavior is explicitly stated (for bugs)
- Current behavior description is concrete, not abstract (for features)
- Acceptance criteria are numbered and independently testable
- Proposed fix leverages existing codebase patterns where possible
- Open questions are called out explicitly (e.g., "Confirm whether X should also be updated")

### 4f: Update the Items

- If the item already has description content, incorporate any relevant context from the original into the new structured description. Do not silently discard product owner notes, links, stakeholder references, or edge case mentions — weave them into the appropriate section of the template.
- **Preserve all images and attachments.** Scan the original content for image references — `<img>` tags in HTML (typically pointing to `_apis/wit/attachments/...` in ADO) or `![alt](url)` in Markdown. These are screenshots, mockups, or reference images added by the author. Include them in the new description — either inline in the relevant section or in a dedicated "Reference Images" section at the end. Never drop image references during a rewrite.
- Do NOT change title, state, assignment, labels, or story points.
- Do NOT begin implementation — the deliverable is the updated description.
- If an update fails, report the error and continue with the remaining items.

**GitHub:** Use a heredoc to pass the body inline, avoiding temp file writes (which trigger extra permission prompts):
```bash
gh issue edit <number> --body "$(cat <<'ENDOFBODY'
<full updated description>
ENDOFBODY
)"
```
The single-quoted `'ENDOFBODY'` delimiter prevents shell expansion, so backticks, `$`, and quotes in the markdown are preserved. Use `ENDOFBODY` (not `EOF`) to avoid early termination if the content contains shell examples. After each successful update, add an audit trail comment with `gh issue comment <number> --body "Description restructured — added [what was added] based on codebase research."`.

**ADO:** Write the updated description to each ADO work item using the update tool. After each successful update, add a brief work item comment noting what was changed (e.g., "Description restructured — added root cause analysis, acceptance criteria, and proposed fix based on codebase research."). This creates an audit trail so reviewers know the description was reworked.

### 4g: Chunk Progress

After completing each chunk, report progress to the user:
- Which items were updated in this chunk
- How many items remain
- Continue to the next chunk automatically unless the user intervenes

## Step 5: Summary

After all chunks are complete, present a final summary:
- How many items were fetched, filtered, skipped, and improved
- For each improved item: the ID/number, title, and a one-line summary of what was added
