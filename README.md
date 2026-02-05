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
```

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
