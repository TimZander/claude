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

## Testing

1. Register: `/plugin marketplace add TimZander/claude`
2. Verify the marketplace appears in `/plugin` > Discover.
3. Install a plugin: `/plugin install plugin-name@tzander-skills`
4. Confirm the plugin's commands/skills are available.
