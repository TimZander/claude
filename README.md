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
2. **Team standards** — Syncs `standards/CLAUDE.md` into `~/.claude/CLAUDE.md`, between the `TEAM-STANDARDS` START and END marker lines. Everything outside those markers is yours and is kept exactly as written. Before each update the previous file is copied to `~/.claude/CLAUDE.md.team-sync.bak` (one copy, replaced on the next update; it holds your personal content too, so keep it out of anything you publish).
   - If the markers are damaged (one missing, duplicated, or not on a line of its own), setup changes nothing in that file, finishes the other steps, and exits with an error. Fix the markers by hand — or delete the whole team block, markers included, so it is re-appended — then re-run.
   - On Windows PowerShell the file must be UTF-8; setup refuses to rewrite a file in another encoding rather than altering your text.

### Per-repo opt-out

The `pre-push` hook applies globally to all repos on your machine. To allow pushing to `main` in a specific repo (e.g., personal projects), create a `.allow-push-main` file in that repo's root:

```
touch .allow-push-main
```

Add it to `.gitignore` so it stays local. Team repos should **not** include this file.

### Code owners

Everything setup-env copies onto a developer's machine reaches every developer at their next sync, so [`.github/CODEOWNERS`](.github/CODEOWNERS) assigns an owner to those paths: `standards/`, `hooks/`, `setup-env.sh`, `setup-env.ps1`, the sync and merge scripts in `scripts/` with their tests, and `.github/`.

On its own the file only requests a review from the owner. It blocks a merge only once branch protection on `main` has **Require review from Code Owners** turned on (Settings → Branches, or Rules → Rulesets), which a repository admin has to set.

With a single owner and that setting on, a PR the owner writes to these paths can't get a code-owner approval, because GitHub doesn't count an author's own review. Merging such a PR needs an admin bypass, or a second owner added to the file.

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
