# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

This is the **tzander-skills** Claude Code plugin marketplace (MIT License, Tim Zander). It provides a registry of plugins installable via `/plugin install plugin-name@tzander-skills`.

## Shared Team Standards

The shared `~/.claude/CLAUDE.md` (team coding standards) is sourced from `standards/CLAUDE.md` in this repo. When asked to add or edit shared/team rules, modify `standards/CLAUDE.md` — not the developer's `~/.claude/CLAUDE.md` directly.

The shared `~/.claude/settings.json` (team permission rules and settings) is sourced from `standards/settings.json`. The sync scripts deep-merge team settings into the user's existing settings (arrays are unioned, objects are merged, personal entries are preserved). When asked to add or edit shared settings, modify `standards/settings.json`.

### Where standards live

| Location | Scope | What belongs here |
|---|---|---|
| `standards/CLAUDE.md` | All repos, all developers | Coding conventions, review standards, CLI references (e.g., GraphQL snippets), workflow rules |
| `standards/settings.json` | All repos, all developers | Tool permissions, environment variables, hooks |
| `CLAUDE.md` (this file) | This repo only | Repo structure, plugin instructions, repo-specific references (e.g., SQL/TFVC for this project) |
| `~/.claude/CLAUDE.md` | All repos, one developer | Private credentials, connection strings, personal overrides (never edit directly — managed by sync scripts + personal additions) |

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

## Plugin Logic: Prefer Scripts Over Inline Markdown

When a plugin command needs non-trivial logic (dependency resolution, multi-step conditionals, file manipulation beyond one command, error handling with specific remediation), put it in a concrete script under `plugins/<plugin>/scripts/` and invoke it from the command markdown. The agent should act as a **handler**: decide what script to call, pass arguments, and interpret the result — not re-execute the logic step-by-step.

Inline bash in markdown is re-interpreted by the agent on every run, can't be tested outside the agent, and tends to grow unboundedly as review cycles surface edge cases. A committed script is deterministic, shell-testable (`bash -n` for syntax, a smoke-test script for behavior), and copy-pastable between plugins.

Ship a minimal smoke test (even ~20 lines) alongside any script that encodes non-trivial logic — verify the usage error and the happy path at minimum. The first time the script is edited, the test pays for itself.

## Python Plugin Dependencies

Plugins with Python runtime dependencies should resolve them via a cascade: (1) check if the current system interpreter already satisfies the deps; (2) install via `uv pip install --python <PY> --system` if `uv` is available, retrying with `--break-system-packages` on failure; (3) fall back to a user-local disposable venv at `${TMPDIR:-/tmp}/<plugin-name>-venv-$(id -u)`, probing for the interpreter at `bin/python` (Unix) or `Scripts/python.exe` (Windows); (4) verify the imports before proceeding.

A reference implementation lives at [`plugins/typ-glyph/scripts/dependency-check.sh`](plugins/typ-glyph/scripts/dependency-check.sh). Plugin authors should copy it into their plugin and invoke it from their command markdown:

```bash
bash <script_path>/dependency-check.sh <plugin-name> "<import-expr>" <pkg>...
```

where `<script_path>` is the directory holding the plugin's scripts (i.e., `plugins/<plugin>/scripts/`).

The script writes `PLUGIN_PY=<path>` as its last stdout line on success. Since shell variables don't survive across separate Bash tool invocations, capture that path and substitute the literal value for `<PLUGIN_PY>` in every subsequent script-execution step.

Packages with native C extensions (`cairosvg` → libcairo, `lxml` → libxml2, `psycopg2` → libpq) depend on system libraries that `pip` cannot install; the verify step surfaces a remediation hint if that's the failure mode.

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
