# Contributing a Plugin

## Plugin Directory Structure

Create a directory under `plugins/` (first-party) or `external_plugins/` (community) with this structure:

```
plugins/my-plugin/
  README.md                       # Required: description and usage
  .claude-plugin/plugin.json      # Optional: plugin metadata
  commands/                       # Optional: slash commands
    my-command.md
  skills/                         # Optional: skills
    SKILL.md
  agents/                         # Optional: agent definitions
  .mcp.json                       # Optional: MCP server config
```

At minimum, a plugin must have a `README.md`.

## Command Format

Commands are Markdown files in `commands/` with YAML frontmatter:

```markdown
---
description: Short description shown in /help
argument-hint: "<required-arg> [optional-arg]"
allowed-tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"]
---

The prompt content that Claude will execute when the command is invoked.
```

## Skill Format

Skills follow the [Agent Skills spec](https://agentskills.io/specification). Create a `SKILL.md` file with YAML frontmatter:

```markdown
---
name: my-skill
description: What this skill does
version: 1.0.0
---

Skill instructions and context for Claude.
```

## Registering Your Plugin

After creating your plugin directory, add an entry to `.claude-plugin/marketplace.json`:

```json
{
  "name": "my-plugin",
  "description": "What it does",
  "author": { "name": "Your Name" },
  "source": "./plugins/my-plugin",
  "category": "development"
}
```

### Categories

Use one of: `development`, `productivity`, `security`, `testing`, `learning`, `database`, `deployment`, `monitoring`, `design`.

## Submitting

1. Fork this repository
2. Create your plugin directory under `plugins/` or `external_plugins/`
3. Add your plugin entry to `.claude-plugin/marketplace.json`
4. Open a pull request with a description of your plugin
