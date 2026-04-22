# tzander-skills

A Claude Code plugin marketplace for community plugins and skills by Tim Zander.

## Quick Start

### Register the marketplace

```
/plugin marketplace add TimZander/claude
```

### Install a plugin

```
/plugin install plugin-name@tzander-skills
```

### Browse available plugins

Run `/plugin` and select **Discover** to browse all available plugins from registered marketplaces.

## Marketplace Structure

```
.claude-plugin/
  marketplace.json      # Marketplace registry (lists all available plugins)
plugins/                # First-party plugins
external_plugins/       # Community-submitted plugins
hooks/                  # Git hook scripts and manifest
standards/              # Team coding standards source
```

## Environment Setup

Run the setup script to bootstrap your local environment — installs global git hooks and syncs team coding standards into `~/.claude/CLAUDE.md`.

**macOS / Linux:**

```
./setup-env.sh
```

**Windows (PowerShell):**

```
./setup-env.ps1
```

Re-run after pulling updates to pick up new hooks or standard changes.

### What it does

1. **Git hooks** — Installs a global `pre-push` hook (via `core.hooksPath`) that blocks pushes to `main`/`master` and warns on force pushes. Hooks are configured in `hooks/hooks.json`.
2. **Team standards** — Syncs `standards/CLAUDE.md` into `~/.claude/CLAUDE.md`, preserving any personal content.

### Per-repo opt-out

The `pre-push` hook applies globally to all repos on your machine. To allow pushing to `main` in a specific repo (e.g., personal projects), create a `.allow-push-main` file in that repo's root:

```
touch .allow-push-main
```

Add it to `.gitignore` so it stays local. Team repos should **not** include this file.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to submit a plugin.

## Plugin Format

Each plugin lives in its own directory under `plugins/` or `external_plugins/` and can include:

| File/Dir | Purpose |
|----------|---------|
| `README.md` | Plugin description and usage |
| `.claude-plugin/plugin.json` | Plugin metadata |
| `commands/` | Slash commands (`.md` files with frontmatter) |
| `skills/` | Skills (`SKILL.md` with YAML frontmatter) |
| `agents/` | Agent definitions |
| `.mcp.json` | MCP server configuration |

For the full skill specification, see the [Agent Skills spec](https://agentskills.io/specification).

## License

MIT


<!-- Fix for #110 -->
