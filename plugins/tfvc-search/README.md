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

If your team keeps a read-only local mirror of the TFVC subtree (e.g. `C:/temp/bgvtsw-tfvc-readonly/`), pass `--mirror` and `--mirror-prefix` together. When the mirror covers the full scope, the skill skips REST and walks the filesystem — orders of magnitude faster and works offline. On a per-file basis, `read` also prefers the mirror.

Consider documenting your mirror path and org/project defaults in your repo's `CLAUDE.md` so the skill picks them up automatically.

## Output

- `grep` → `path:line:text` (grep-compatible)
- `read` → raw file content to stdout
- `ls` → one path per line; folders get a trailing `/`

## Path-escaping note

TFVC paths start with `$` and often contain spaces. Always single-quote them in Bash:

```bash
--scope '$/BGV Databases/RedGate/BGVTSWCustom'
```

Double quotes will make the shell try to expand `$/…` as a variable.

## Scope (v1)

Read-only: `grep`, `read`, `ls`. No check-ins, edits, branching, or changeset history. Live-DB inspection (current deployed state via `sqlcmd`) is explicitly out of scope — it's a separate concern with its own policy considerations.

## Tests

```bash
python plugins/tfvc-search/scripts/test_tfvc-search.py
```

Tests mock both `az` and `urllib.request.urlopen` — no network required.
