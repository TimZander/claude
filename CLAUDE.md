# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

This is the **tzander-skills** Claude Code plugin marketplace (MIT License, Tim Zander). It provides a registry of plugins installable via `/plugin install plugin-name@tzander-skills`.

## Shared Team Standards

The shared `~/.claude/CLAUDE.md` (team coding standards) is sourced from `standards/CLAUDE.md` in this repo. When asked to add or edit shared/team rules, modify `standards/CLAUDE.md` — not the developer's `~/.claude/CLAUDE.md` directly.

The shared `~/.claude/settings.json` (team permission rules and settings) is sourced from `standards/settings.json`. The sync scripts deep-merge team settings into the user's existing settings (arrays are unioned, objects are merged, personal entries are preserved). When asked to add or edit shared settings, modify `standards/settings.json`.

## Environment Setup

Run `./setup-env.sh` (bash) or `./setup-env.ps1` (PowerShell) to bootstrap the local environment:

1. **Git hooks** — Installs global hooks from `hooks/` to `~/.git-hooks/` (controlled by `hooks/hooks.json`). Sets `core.hooksPath` globally.
2. **Team standards** — Syncs `standards/CLAUDE.md` into `~/.claude/CLAUDE.md`.
3. **Team settings** — Deep-merges `standards/settings.json` into `~/.claude/settings.json`.

The script is idempotent — safe to re-run at any time. It replaces the old `sync-standards` scripts.

### Per-repo hook opt-out

The `pre-push` hook blocks pushes to `main`/`master` globally. To opt out for a specific repo (e.g., personal projects), create a `.allow-push-main` file in that repo's root.

## Marketplace Structure

- `.claude-plugin/marketplace.json` — The marketplace registry. Lists all available plugins.
- `plugins/` — First-party plugin directories.
- `external_plugins/` — Community-submitted plugin directories.

## Adding a New Plugin

1. Create a plugin directory under `plugins/` or `external_plugins/` with at least a `README.md`.
2. Add an entry to `.claude-plugin/marketplace.json` in the `plugins` array:
   ```json
   {
     "name": "plugin-name",
     "description": "What it does",
     "author": { "name": "Author Name" },
     "source": "./plugins/plugin-name",
     "category": "development"
   }
   ```
3. The `source` path must be relative to the repository root.

## SQL Database Reference

When doing SQL-related work, the database schema is stored in Azure DevOps TFVC.
Connection details (org, project, TFVC path) are defined in the developer's
private `~/.claude/CLAUDE.md`. Use `az devops invoke` to query it.

**Prerequisites:** Before running any commands below, verify the required tools are installed:
1. Run `az --version` to confirm Azure CLI is installed.
2. Run `az extension list -o table` and check that `azure-devops` appears. If missing, install it with `az extension add --name azure-devops`.
3. Run `az account show` to confirm you are logged in. If not, run `az login`.

**Commands (prefix with `MSYS_NO_PATHCONV=1` on Git Bash to avoid path mangling):**

List items:
```
az devops invoke --area tfvc --resource items \
  --route-parameters project="<PROJECT>" \
  --query-parameters 'scopePath=<TFVC_ROOT>/Tables' 'recursionLevel=OneLevel' \
  --org <ORG_URL> -o json
```

Read a file:
```
az devops invoke --area tfvc --resource items \
  --route-parameters project="<PROJECT>" \
  --query-parameters 'path=<TFVC_ROOT>/Tables/dbo.Example.sql' 'includeContent=true' \
  --org <ORG_URL> -o json
```

Replace `<PROJECT>`, `<TFVC_ROOT>`, and `<ORG_URL>` with values from your private `~/.claude/CLAUDE.md`.

## GitHub Issue Relationships

GitHub's "Relationships" feature (Blocked by / Blocking) can be managed via `gh api graphql`.

### Get issue node IDs

Single issue:
```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    issue(number: 123) { id number title }
  }
}'
```

Multiple issues (use aliases — `issues` doesn't support a `numbers` filter):
```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    a: issue(number: 445) { id number title }
    b: issue(number: 446) { id number title }
    c: issue(number: 447) { id number title }
  }
}'
```

### Create "blocked by" relationships

**Schema:** `addBlockedBy(input: { issueId: BLOCKED_ISSUE, blockingIssueId: BLOCKING_ISSUE })`

- `issueId` = the issue that IS blocked (the dependent)
- `blockingIssueId` = the issue that BLOCKS it (the dependency)

Single relationship (e.g., #446 is blocked by #445):
```bash
gh api graphql -f query='
mutation {
  addBlockedBy(input: {
    issueId: "<NODE_ID_OF_446>"
    blockingIssueId: "<NODE_ID_OF_445>"
  }) {
    issue { number title }
  }
}'
```

Batch — multiple relationships in one mutation (use aliases):
```bash
gh api graphql -f query='
mutation {
  a: addBlockedBy(input: { issueId: "<ID_446>", blockingIssueId: "<ID_445>" }) { issue { number } }
  b: addBlockedBy(input: { issueId: "<ID_447>", blockingIssueId: "<ID_445>" }) { issue { number } }
}'
```

### Remove relationships

```bash
gh api graphql -f query='
mutation {
  removeBlockedBy(input: {
    issueId: "<NODE_ID_OF_BLOCKED_ISSUE>"
    blockingIssueId: "<NODE_ID_OF_BLOCKING_ISSUE>"
  }) {
    issue { number }
  }
}'
```

### Query existing relationships

```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    issue(number: 447) {
      number
      title
      blockedBy(first: 10) { nodes { number title } }
      blocking(first: 10) { nodes { number title } }
    }
  }
}'
```

Batch — verify relationships across multiple issues:
```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    a: issue(number: 446) { number blockedBy(first: 5) { nodes { number title } } }
    b: issue(number: 447) { number blockedBy(first: 5) { nodes { number title } } }
    c: issue(number: 448) { number blockedBy(first: 5) { nodes { number title } } }
  }
}'
```

### Gotchas

- `issues(numbers: [...])` does **not** exist in the GraphQL schema — use aliases (`a: issue(number: N)`) to batch
- `addBlockedBy` is **not idempotent** — calling it twice for the same pair will error
- Node IDs are opaque strings (e.g., `I_kwDOQOqPc871pGVo`) — always fetch them fresh

## No Attribution

Never add `Co-Authored-By` trailers, "generated by" footers, or any other attribution metadata to commit messages, PR titles, PR descriptions, issue comments, or any other generated output.

## Git Push Safety

These rules apply to all plugin commands and manual operations:

- **Never push to `main` or `master`** — all changes must go through pull requests
- **Never force push** (`--force`, `-f`, `--force-with-lease`) to any branch

## Testing

1. Register: `/plugin marketplace add TimZander/claude`
2. Verify the marketplace appears in `/plugin` > Discover.
3. Install a plugin: `/plugin install plugin-name@tzander-skills`
4. Confirm the plugin's commands/skills are available.
