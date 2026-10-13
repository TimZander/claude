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

## Claude Code Cloud Sessions

Cloud sessions ([claude.ai/code](https://claude.ai/code), the Claude app, GitHub Actions) run in a fresh Ubuntu container, not on your machine. Nothing from your local setup carries over: your `~/.claude/CLAUDE.md`, installed plugins, and tools like `gh` are all absent unless the environment installs them. [`scripts/cloud-setup.sh`](scripts/cloud-setup.sh) does that.

### Configure the environment

1. Open a cloud session, then open the cloud environment menu in the session's title bar and choose **Edit** (or create a new environment).
2. Set **Network access** to **Trusted**. The script needs GitHub (marketplace + standards clone) and the Ubuntu package mirrors (`gh`).
3. Paste the contents of [`scripts/cloud-setup.sh`](scripts/cloud-setup.sh) into **Setup script** and save.
4. Start a new session. The setup script runs only on new sessions, and only when no cached environment exists.

See the [cloud environments docs](https://code.claude.com/docs/en/cloud-environments) for the full settings reference.

### What it does

1. **Plugins** — Adds this marketplace and installs `deep-review`, `craft-pr`, `craft-stage-commit-push`, `start-work`, and `self-review` through the plugin system. Edit `PLUGINS` to change the list.
2. **Team standards** — Shallow-clones this repo and copies `standards/CLAUDE.md` to `/root/.claude/CLAUDE.md`, the same file `setup-env` syncs locally.
3. **`gh` CLI** — Installs `gh` via apt, in the background so it overlaps the plugin install.
4. **Verification** — Logs the plugin list, `gh` version, and whether GitHub auth is present (never the token itself).

### Gotchas

- **Install plugins with the setup script, not account-level enablement.** Enabling a plugin at the account level exposes its definition, but its slash commands (e.g. `/deep-review`) are not invocable because these plugins ship commands rather than bundled skills.
- **The script must exit zero.** A non-zero exit fails the session, so every fallible step ends in `|| true` and problems are logged as `WARNING:` lines instead.
- **Keep it under ~5 minutes** so the environment cache can build.
- **Base-image PPAs are removed.** The `deadsnakes` and `ondrej/php` PPAs redirect to `ppa.launchpadcontent.net`, which isn't on the Trusted allowlist, and their 403s make `apt-get update` fail. Neither is needed.
- **Standards and plugins are snapshotted into the cache.** The script doesn't re-run while a cached environment exists, so changes merged here can lag in cloud sessions. Editing the setup script forces a cache rebuild — make a trivial edit to pick up new `standards/CLAUDE.md` or plugin versions sooner.

### Troubleshooting

The script logs to `/root/setup-script.log`. From inside a session, ask Claude to read it, or run:

```
cat /root/setup-script.log
```

Look for `WARNING:` lines — missing `gh`, a failed clone, or `claude` not on `PATH`.

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
