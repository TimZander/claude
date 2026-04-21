---
name: tfvc-search
description: Search and read Azure DevOps TFVC content (SQL schema scripts, etc.) via REST without a local workspace
allowed-tools: Bash
user-input: required
argument-hint: "[grep|read|ls] <args>  OR  <natural-language query>"
model: sonnet
---

You help the user investigate Azure DevOps TFVC content without cloning or mapping a workspace. TFVC is typically used in this context to store SQL schema scripts (stored procs, functions, tables, views) that sit outside a git repo — so the common task is grepping across `.sql` files by name or content.

## Operations

The skill wraps `tfvc-search.py`, which exposes three subcommands:

- **`grep`** — recursive regex search under a scope path. Supports `--file-glob` to narrow by filename.
- **`read`** — fetch the full content of a single TFVC item.
- **`ls`** — list files/folders under a path (default one level; `--recursive` for full).

## Interpreting user intent

Translate natural-language asks into the right subcommand:

| User asks… | Run |
|---|---|
| *"find procs that reference ColumnX under `$/Foo/Bar`"* | `grep --scope '$/Foo/Bar' --pattern 'ColumnX' --file-glob '*.sql'` |
| *"show me the body of `$/Foo/Bar/dbo.MyProc.sql`"* | `read --path '$/Foo/Bar/dbo.MyProc.sql'` |
| *"what's under `$/Foo/Bar`"* | `ls --scope '$/Foo/Bar'` (or add `--recursive` if they ask for the full tree) |
| *"is there a function called `stc.GetSalesAgents` under `$/BGV/RedGate/Custom`"* | `ls --scope '$/BGV/RedGate/Custom/Functions' --recursive` first, then `read --path '...'` on the hit |

When the user names a SQL object by schema-qualified name (e.g. `stc.GetSalesAgents`), the RedGate SQL Source Control layout is `$/<Project>/RedGate/<Db>/{Stored Procedures,Functions,Views,Tables,Synonyms,Security/Schemas}/<schema>.<Name>.sql`. Narrow the `--scope` by kind when you can (`Functions/` vs `Stored Procedures/`) — much faster than recursive grep over the whole DB.

## Invocation

**Prerequisite:** `az login` must be done (the script uses `az account get-access-token` for ADO auth). If the script errors with "run 'az login'", tell the user to authenticate and retry.

Locate the script and run the appropriate subcommand — Bash shell state does not persist between tool calls, so resolve the path in each step:

```bash
SCRIPT=$(find ~/.claude -name tfvc-search.py -path "*/tfvc-search/*" -type f 2>/dev/null | head -1)
python3 "$SCRIPT" <subcommand> --org <ORG> --project "<PROJECT>" ...
```

Org and project must come from the user's repo/project `CLAUDE.md` (often stored under `## SQL Database Reference` or similar), or from the user directly. Do not guess.

## Path-escaping footgun

TFVC paths start with `$` and often contain spaces — e.g. `$/BGV Databases/RedGate/BGVTSWCustom`. In Bash:

- **Always single-quote the path:** `'$/BGV Databases/RedGate/BGVTSWCustom'`. Double-quoting will make the shell try to expand `$/...` as a variable.
- On Git Bash / MSYS, if a path arg starts with `/` and is being passed to a Windows-side binary, MSYS may rewrite it. This skill's Python wrapper avoids that layer, but if you see path mangling, prefix the whole command with `MSYS_NO_PATHCONV=1`.

## Local mirror (optional, much faster)

If the user has a read-only local mirror of the TFVC subtree (e.g. `C:/temp/bgvtsw-tfvc-readonly/` mapped to `$/BGV Databases/RedGate/BGVTSWCustom`), pass `--mirror` and `--mirror-prefix`:

```bash
python3 "$SCRIPT" grep \
  --org bgvone --project "BGV Databases" \
  --scope '$/BGV Databases/RedGate/BGVTSWCustom' \
  --pattern 'ColumnX' --file-glob '*.sql' \
  --mirror '/c/temp/bgvtsw-tfvc-readonly' \
  --mirror-prefix '$/BGV Databases/RedGate/BGVTSWCustom'
```

When the mirror covers the full scope, the script skips REST entirely and walks the local filesystem — orders of magnitude faster and works offline. `read` also prefers the mirror on a per-file basis. The two flags must be given together or the script errors out.

**Check the user's repo `CLAUDE.md` for a mirror path before making REST calls.** If a mirror is documented, use it unconditionally — it avoids network round-trips and respects any org policy against reaching the live DB or live TFVC during investigation.

## Output format

- `grep` prints `path:line:text` (grep-compatible) — one match per line.
- `read` writes raw file content to stdout.
- `ls` prints one path per line; folders get a trailing `/`.

On large scopes, `grep` fetches content per-file over REST, which is slow. Narrow with `--scope` (to a subfolder) and `--file-glob` (to `*.sql` or the specific kind directory) before grepping.

## Out of scope

This skill is read-only: no check-ins, edits, branching, or changeset history in v1. If the user wants the current *deployed* state of a SQL object (rather than source-controlled), that requires a separate live-DB path — not provided here — and may be against policy in some projects. Do not reach for `sqlcmd` without explicit user consent.
