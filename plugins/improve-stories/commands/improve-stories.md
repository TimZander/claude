---
name: improve-stories
description: Review user stories for completeness, research the codebase to fill gaps, and update each story with structured documentation
allowed-tools: Bash, Read, Grep, Glob, Agent, AskUserQuestion, mcp__azure-devops__wit_get_work_items_for_iteration, mcp__azure-devops__wit_get_work_item, mcp__azure-devops__wit_update_work_item, mcp__azure-devops__wit_my_work_items, mcp__azure-devops__wit_list_backlogs, mcp__azure-devops__wit_list_backlog_work_items, mcp__azure-devops__wit_get_work_items_batch_by_ids
user-input: optional
argument-hint: "[iteration-path or work-item-ids]"
model: opus
---

You are improving user stories so they are actionable, complete, and ready for any developer to pick up. Your deliverable is **updated work item descriptions** — you do NOT begin implementation.

## Step 1: Gather Stories

- If the user provided specific work item IDs, fetch those directly.
- If the user provided an iteration path, fetch all user stories for that iteration.
- If no argument was given, ask the user which iteration or work items to target.
- Filter to the relevant project or area if specified (e.g., "STC" prefix).

## Step 2: Filter to Repository-Relevant Stories

This skill runs from within a specific repository, which is where codebase research happens. Stories unrelated to this repo cannot be meaningfully improved.

- Read the project's CLAUDE.md and examine the repo structure (top-level directories, solution files, project names) to understand what this codebase covers.
- For each fetched story, check whether its title, description, tags, or area path relate to this repository's domain. Look for mentions of components, services, namespaces, or features that exist in this codebase.
- **Keep** stories that clearly relate to this repo or are ambiguous enough that research might clarify them.
- **Skip** stories that clearly belong to a different codebase or domain (e.g., a mobile app story when you're in a backend API repo).
- If all stories are filtered out, tell the user and suggest which repo might be more appropriate.

## Step 3: Triage

For each remaining story, read its full details and classify it:

**Well-documented** (skip) — has a clear description, acceptance criteria, and enough context to start work.

**Needs improvement** — flag if ANY of these are true:
- Empty or near-empty description
- No acceptance criteria
- Description is a single vague sentence with no context
- Missing failure scenario (for bugs)
- No mention of affected files or components

Present the triage summary to the user:
- How many stories were fetched, how many were filtered as irrelevant, how many are well-documented, how many need improvement
- List which stories you plan to improve and why
- List which stories you're skipping and why
- If more than 10 stories need improvement, recommend processing in chunks and ask the user how many to tackle now
- Ask the user to confirm before proceeding

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

Only needs to be done once (for the first chunk). Examine the existing work items you fetched to determine whether the project uses **HTML** or **Markdown** for descriptions.

- Look at well-documented stories (the ones you skipped) and any non-empty descriptions on the stories you're improving.
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

## Failure Example
Concrete scenario a user would encounter. Walk through the steps.

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

<h2>Failure Example</h2>
<p>Concrete scenario a user would encounter. Walk through the steps.</p>

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
- Failure example or current behavior is concrete, not abstract
- Acceptance criteria are numbered and independently testable
- Proposed fix leverages existing codebase patterns where possible
- Open questions are called out explicitly (e.g., "Confirm whether X should also be updated")

### 4e: Update the Work Items

- Write the updated description to each ADO work item using the update tool.
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
