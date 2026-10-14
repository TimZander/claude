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
cloud/                  # Cloud session setup (bootstrap stub + profiles)
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

Cloud sessions ([claude.ai/code](https://claude.ai/code), the Claude app, GitHub Actions) run in a fresh Ubuntu container, not on your machine. Nothing from your local setup carries over: your `~/.claude/CLAUDE.md`, installed plugins, and tools like `gh` are all absent unless the environment installs them. The [`cloud/`](cloud) directory does that, with one **profile** per kind of environment.

### Profiles

| Profile | For | Installs |
|---------|-----|----------|
| `default` | Everyday work | Team standards, `deep-review`, `craft-pr`, `craft-stage-commit-push`, `start-work`, `self-review`, `gh` |
| `sdd` | Spec-driven development | The [`sdd`](plugins/sdd) plugin, `gh`, and a short `CLAUDE.md` pointing sessions at each repo's sdd workflow — no team standards, no other plugins |

The `sdd` profile builds the same environment as [`plugins/sdd/cloud-setup.sh`](plugins/sdd/cloud-setup.sh), which can be pasted on its own. `/sdd:conformance-review` is the code review in that flow, so `deep-review` is left out. OpenSpec isn't installed here: each repo pins its own version and installs it from its SessionStart hook.

### Configure an environment

1. Open a cloud session, then open the cloud environment menu in the session's title bar and choose **Edit** (or create a new environment — one per profile).
2. Set **Network access** to **Trusted**. Setup needs GitHub, the Ubuntu package mirrors (`gh`), and the npm registry (for any `NPM_PACKAGES`).
3. Paste [`cloud/bootstrap.sh`](cloud/bootstrap.sh) into **Setup script**, set `PROFILE` to the profile you want, and save.
4. Start a new session.

See the [cloud environments docs](https://code.claude.com/docs/en/cloud-environments) for the full settings reference.

### How it works

The pasted `bootstrap.sh` is a small stub that stays the same between updates: it shallow-clones this repo at `REF` (default `main`) and runs [`cloud/setup.sh`](cloud/setup.sh) with your `PROFILE`. `setup.sh` then:

1. **Plugins** — adds this marketplace at `REF` and installs the profile's `PLUGINS` through the plugin system.
2. **Tools** — installs `APT_PACKAGES` (in the background, overlapping the plugin install) and `NPM_PACKAGES` globally.
3. **Instructions** — copies the profile's `CLAUDE_MD` to `/root/.claude/CLAUDE.md`. By default that's `standards/CLAUDE.md`, the same file `setup-env` syncs locally.
4. **Verification** — checks each of `VERIFY_COMMANDS` is on `PATH`, logs the plugin list, and reports whether GitHub auth is present (never the token itself).

To try a change before merging it, set `REF` in the stub to your branch. Plugins are installed from that branch too, so new or changed plugins can be tested the same way.

### Keeping it updated

Profile and setup changes merged here need no re-paste, but they reach cloud sessions only after a **cache rebuild**: the setup script runs only when no cached environment exists. Editing the pasted stub forces a rebuild, so bump its `REVISION` number after merging a change you need right away.

### Adding a profile

1. Copy [`cloud/profiles/default.sh`](cloud/profiles/default.sh) to `cloud/profiles/<name>.sh` and set `PROFILE_DESCRIPTION`, `PLUGINS`, `APT_PACKAGES`, `NPM_PACKAGES`, and `VERIFY_COMMANDS`. Set `CLAUDE_MD` to a repo-relative file to install something other than the team standards.
2. Add a row to the profiles table above.
3. Run `bash cloud/test_setup.sh`. It checks that every profile's plugins exist in the marketplace. CI runs it on any change under `cloud/`.

### Gotchas

- **Install plugins with the setup script, not account-level enablement.** Enabling a plugin at the account level exposes its definition, but its slash commands (e.g. `/deep-review`) are not invocable because these plugins ship commands rather than bundled skills.
- **The setup script must exit zero.** A non-zero exit fails the session, so every fallible step is best-effort and problems are logged as `WARNING:` lines instead.
- **Keep setup under ~5 minutes** so the environment cache can build.
- **Base-image PPAs are removed.** The `deadsnakes` and `ondrej/php` PPAs redirect to `ppa.launchpadcontent.net`, which isn't on the Trusted allowlist, and their 403s make `apt-get update` fail. Neither is needed.

### Troubleshooting

Setup logs to `/root/setup-script.log`. From inside a session, ask Claude to read it, or run:

```
cat /root/setup-script.log
```

The first line shows the profile, ref, and revision that ran. Look for `WARNING:` lines — a failed clone, `claude` or `npm` not on `PATH`, or a missing command from `VERIFY_COMMANDS`.

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
