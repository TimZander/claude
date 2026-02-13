---
name: setup-newrelic
description: Discover New Relic application entities for this repo and add them to the project CLAUDE.md
allowed-tools: Read, Edit, Write, Glob, mcp__newrelic__get_entity, mcp__newrelic__list_available_new_relic_accounts
---

You are setting up the New Relic section in this repository's CLAUDE.md file. Your job is to discover the New Relic application entities that correspond to this repo and record them grouped by environment.

## Step 1: Gather Context

**Run all of these in parallel:**

1. Read the user's private `~/.claude/CLAUDE.md` to find the New Relic account ID(s). Look for the `## New Relic` section. If no account IDs are found, stop and tell the user to add their New Relic account IDs to `~/.claude/CLAUDE.md` first.
2. Read this repo's `CLAUDE.md` to understand the project and check if a `## New Relic` section already exists.
3. Determine the likely application/service name from the repo name, directory name, and any project files (e.g., `package.json`, `*.csproj`, `*.sln`, `appsettings.json`, `docker-compose.yml`).

## Step 2: Search for Entities

Using the account ID(s) from Step 1, search for New Relic application entities using `get_entity` with name patterns that match this repo's likely application/service names.

- Try several variations: the repo name, common prefixes/suffixes, with and without environment suffixes (e.g., `-Dev`, `-Staging`, `-Prod`, `-Production`, `-QA`).
- Applications typically have different names per environment (e.g., `MyApp-Dev`, `MyApp-Staging`, `MyApp-Production`). Find all of them.
- Search across all account IDs found in Step 1.

If no entities are found, tell the user what names you searched for and ask them to provide the correct application name.

## Step 3: Update CLAUDE.md

Add or update a `## New Relic` section in this repo's `CLAUDE.md` with the discovered entities grouped by environment.

**Format:**

```markdown
## New Relic
  - Production: AppName-Prod (entity GUID: `xxx`)
  - Staging: AppName-Staging (entity GUID: `xxx`)
  - Dev: AppName-Dev (entity GUID: `xxx`)
```

- If a `## New Relic` section already exists, update it in place.
- If it does not exist, add it as a new section in an appropriate location (near other infrastructure/connection details if present, otherwise at the end before any auto-synced blocks).
- Only include environments where you found matching entities.
- If entities were found across multiple accounts, note which account each belongs to.

## Step 4: Report

Tell the user what you found and what was written to `CLAUDE.md`. List any environments you expected but could not find entities for.
