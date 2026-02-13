# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

This is the **tzander-skills** Claude Code plugin marketplace (MIT License, Tim Zander). It provides a registry of plugins installable via `/plugin install plugin-name@tzander-skills`.

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

## Testing

1. Register: `/plugin marketplace add TimZander/claude`
2. Verify the marketplace appears in `/plugin` > Discover.
3. Install a plugin: `/plugin install plugin-name@tzander-skills`
4. Confirm the plugin's commands/skills are available.
