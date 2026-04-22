# tfvc-search

Search and read Azure DevOps TFVC content (typically SQL schema scripts — stored procs, functions, views, tables) via the TFVC REST API. No workspace mapping, no cloning, no `tf.exe`.

## Install

```
/plugin install tfvc-search@tzander-skills
```

## Prerequisites

- **Azure CLI (`az`)** on `PATH` — the script picks up your existing credentials via `az account get-access-token`.
- **`az login`** completed at least once. If not, the skill will tell you.
- **Python 3** on `PATH` — stdlib only, no external dependencies.

## Usage

Invoke via `/tfvc-search` with a natural-language query, or run the script directly:

```bash
python path/to/tfvc-search.py grep \
  --org <ORG> --project "<PROJECT>" \
  --scope '$/Path/To/Scope' \
  --pattern 'RegexHere' \
  [--file-glob '*.sql'] \
  [--mirror /local/path --mirror-prefix '$/Matching/Tfvc/Path']

python path/to/tfvc-search.py read \
  --org <ORG> --project "<PROJECT>" \
  --path '$/Path/To/File.sql'

python path/to/tfvc-search.py ls \
  --org <ORG> --project "<PROJECT>" \
  --scope '$/Path/To/Scope' [--recursive]
```

## Optional: local mirror

If your team keeps a read-only local mirror of the TFVC subtree (e.g. `C:/temp/bgvtsw-tfvc-readonly/`), the skill can use it automatically instead of REST — orders of magnitude faster, works offline, and avoids any org policy against reaching live TFVC during investigation.

**Setup (one-time):** add a `## TFVC Mirror` block to your `~/.claude/CLAUDE.md` with your mirror path and the TFVC scope it mirrors. The skill's command markdown instructs Claude to pick these up on every invocation — no flags needed after that.

```markdown
## TFVC Mirror

- Mirror path: /c/temp/bgvtsw-tfvc-readonly
- Mirror prefix: $/BGV Databases/RedGate/BGVTSWCustom
```

Once that's in place, `/tfvc-search find procs referencing ColumnX` will walk the local mirror instead of hitting ADO. No per-call flags, no re-explaining the mirror each session.

If you only have a mirror for some subtrees, document just those — the skill falls back to REST when the requested scope isn't under the mirror prefix.

**Manual override:** you can still pass `--mirror` and `--mirror-prefix` explicitly on the command line if you want to point at a different mirror for a one-off call. The two flags must be given together.

## Output

- `grep` → `path:line:text` (grep-compatible)
- `read` → raw file content to stdout
- `ls` → one path per line; folders get a trailing `/`

## Path-escaping note

TFVC paths start with `$` and often contain spaces. Two rules on Bash:

1. **Always single-quote the path:** `'$/BGV Databases/RedGate/BGVTSWCustom'`. Double quotes will make the shell try to expand `$/…` as a variable.
2. **On Git Bash / MSYS, always prefix the command with `MSYS_NO_PATHCONV=1`.** Without it, MSYS rewrites `'$/Foo/Bar'` into `'$C:/Program Files/Git/Foo/Bar'` before Python receives the arg, and ADO rejects the call. The variable is harmless on non-MSYS shells, so you can always include it. **Caveat:** if you invoke via an absolute POSIX path (e.g., `/c/Users/.../tfvc-search.py`), `MSYS_NO_PATHCONV=1` also blocks translation of that path — run `cygpath -m "$SCRIPT"` first to convert it to a Windows path before disabling translation.

```bash
MSYS_NO_PATHCONV=1 python tfvc-search.py ls \
  --org bgvone --project "BGV Databases" \
  --scope '$/BGV Databases/RedGate/BGVTSWCustom'
```

## Scope (v1)

Read-only: `grep`, `read`, `ls`. No check-ins, edits, branching, or changeset history. Live-DB inspection (current deployed state via `sqlcmd`) is explicitly out of scope — it's a separate concern with its own policy considerations.

## Tests

```bash
python plugins/tfvc-search/scripts/test_tfvc-search.py
```

Tests mock both `az` and `urllib.request.urlopen` — no network required.
