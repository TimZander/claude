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
[ -n "$SCRIPT" ] || { echo "tfvc-search.py not found under ~/.claude — re-install: /plugin install tfvc-search@tzander-skills" >&2; exit 1; }
# On MSYS/Git Bash: convert the script path to a Windows path so Python can open it,
# then block MSYS path translation for the TFVC $/... args via MSYS_NO_PATHCONV=1.
command -v cygpath >/dev/null 2>&1 && SCRIPT=$(cygpath -w "$SCRIPT")
MSYS_NO_PATHCONV=1 python "$SCRIPT" <subcommand> --org <ORG> --project "<PROJECT>" ...
```

**Always prefix with `MSYS_NO_PATHCONV=1` on Windows/Git Bash.** Without it, Git Bash rewrites the TFVC `$/...` path into `$<drive>:<mount>/...` before Python receives it — the script detects this mangling and errors out clearly, but prevention is cheaper than recovery. The env var is harmless on non-MSYS shells, so it's safe to always include. The `cygpath -w` call converts the POSIX script path to a Windows path before `MSYS_NO_PATHCONV=1` disables translation — otherwise Python receives `/c/Users/...` verbatim and can't open the file.

Org and project must come from the user's repo/project `CLAUDE.md` (often stored under `## SQL Database Reference` or similar), or from the user directly. Do not guess.

## Path-escaping footgun

TFVC paths start with `$` and often contain spaces — e.g. `$/BGV Databases/RedGate/BGVTSWCustom`. In Bash:

- **Always single-quote the path:** `'$/BGV Databases/RedGate/BGVTSWCustom'`. Double-quoting will make the shell try to expand `$/...` as a variable.
- **On Git Bash / MSYS, always prefix with `MSYS_NO_PATHCONV=1`** (as shown in the invocation block above). MSYS silently rewrites args that start with `/` into Windows-style paths *before* Python receives them — so `'$/BGV Databases/...'` becomes `'$C:/Program Files/Git/BGV Databases/...'` and the ADO API rejects it with `InvalidPathException`. The env var is harmless on non-MSYS shells. **Caveat:** `MSYS_NO_PATHCONV=1` also blocks translation of the script path itself, so always run `cygpath -w "$SCRIPT"` first (as shown in the invocation block) to convert it to a Windows path before disabling translation.

## Local mirror (optional, much faster)

**Before making any REST call, check the conversation's loaded CLAUDE.md context for a documented TFVC mirror** — both the project-level `CLAUDE.md` and the user-global `~/.claude/CLAUDE.md`. Users commonly maintain a read-only local mirror of their TFVC subtree and want the skill to use it automatically without having to pass flags on every invocation.

Look for a section headed `## TFVC Mirror` (or similar) with two pieces of information:

- A **mirror path** — a local directory containing a checked-out copy of some TFVC subtree (e.g. `C:/temp/bgvtsw-tfvc-readonly` or `/c/temp/bgvtsw-tfvc-readonly`).
- A **mirror prefix** — the TFVC path that the mirror's root corresponds to (e.g. `$/BGV Databases/RedGate/BGVTSWCustom`).

If both are present in CLAUDE.md, **always pass `--mirror` and `--mirror-prefix` on every invocation** — no need to ask the user or mention it. Project-level CLAUDE.md wins over the user-global one if they disagree. If only one of the two values is documented, treat the mirror as absent and fall back to REST.

Full invocation with mirror:

```bash
command -v cygpath >/dev/null 2>&1 && SCRIPT=$(cygpath -w "$SCRIPT")
MSYS_NO_PATHCONV=1 python "$SCRIPT" grep \
  --org bgvone --project "BGV Databases" \
  --scope '$/BGV Databases/RedGate/BGVTSWCustom' \
  --pattern 'ColumnX' --file-glob '*.sql' \
  --mirror '/c/temp/bgvtsw-tfvc-readonly' \
  --mirror-prefix '$/BGV Databases/RedGate/BGVTSWCustom'
```

When the mirror covers the full scope, the script skips REST entirely and walks the local filesystem — orders of magnitude faster and works offline. `read` also prefers the mirror on a per-file basis. The two flags must be given together or the script errors out.

**First REST call in a session, if no mirror is documented:** emit this one-time tip to the user *before* the call:

> Running this search via REST. If you have (or can create) a read-only local mirror of the TFVC subtree, add a block like this to your `~/.claude/CLAUDE.md` once and I'll use it automatically on every future call — much faster, works offline:
>
> ```markdown
> ## TFVC Mirror
>
> - Mirror path: <local directory, e.g. /c/temp/bgvtsw-tfvc-readonly>
> - Mirror prefix: <TFVC path that directory mirrors, e.g. $/BGV Databases/RedGate/BGVTSWCustom>
> ```

Then proceed with the REST call. **Do not re-emit this tip on subsequent calls in the same session** — once is enough, the user has the template. If the user acknowledges they don't have a mirror / don't want one, drop the tip entirely.

## Output format

- `grep` prints `path:line:text` (grep-compatible) — one match per line.
- `read` writes raw file content to stdout.
- `ls` prints one path per line; folders get a trailing `/`.

On large scopes, `grep` fetches content per-file over REST, which is slow. Narrow with `--scope` (to a subfolder) and `--file-glob` (to `*.sql` or the specific kind directory) before grepping.

## Out of scope

This skill is read-only: no check-ins, edits, branching, or changeset history in v1. If the user wants the current *deployed* state of a SQL object (rather than source-controlled), that requires a separate live-DB path — not provided here — and may be against policy in some projects. Do not reach for `sqlcmd` without explicit user consent.
