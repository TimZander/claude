#!/usr/bin/env python3
"""Guard against mutating commands slipping into the team allowlist.

`standards/settings.json` is synced into every developer's user-scope
`~/.claude/settings.json`, so anything in its `permissions.allow` list is
pre-approved for everyone in every repo and worktree. This validator fails
(exit 1) if any allow entry names a command or MCP tool that can change
state, so a well-meaning edit can't silently pre-approve a write.

The check is capability-aware, not a leading-token blocklist: it knows which
"looks read-only" commands can still write without a shell redirect (e.g.
`sort -o FILE`, `uniq in out`, `git worktree add -B` resetting a branch).

Usage: python validate-settings.py [path-to-settings.json]
       (defaults to the settings.json next to this script)
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Bash prefixes that must NEVER appear as an allow entry, each with the reason.
# Keyed by the command prefix as it would appear inside Bash(<prefix>:*).
# An allow entry is a violation when its command equals a key or begins with
# "<key> " (token boundary), so `git worktree add` also catches `add -B ...`.
WRITE_CAPABLE = {
    # read-looking utils with a non-redirect write vector
    "sort": "sort -o/--output FILE overwrites a file",
    "uniq": "uniq takes a positional OUTPUT file (uniq in out)",
    "tee": "tee writes stdin to files",
    "dd": "dd of= writes a file/device",
    # generic mutating file ops
    "cp": "copies/overwrites files", "mv": "moves/overwrites files",
    "rm": "deletes files", "chmod": "changes permissions",
    "chown": "changes ownership", "ln": "creates links",
    "truncate": "truncates files",
    # git subcommands that mutate refs/worktree/index/history
    "git commit": "writes history", "git push": "publishes refs",
    "git checkout": "mutates working tree/refs",
    "git switch": "mutates working tree/refs",
    "git reset": "moves refs / discards changes",
    "git restore": "discards working-tree changes",
    "git branch": "-D/-m/-f create/delete/rename branches",
    "git tag": "creates/deletes tags", "git stash": "mutates stash/worktree",
    "git merge": "mutates history/worktree", "git rebase": "rewrites history",
    "git pull": "fetches and merges", "git clean": "deletes untracked files",
    "git rm": "removes tracked files", "git mv": "moves tracked files",
    "git apply": "applies patches", "git am": "applies patches",
    "git config": "the write form (git config key value) mutates config",
    "git worktree add": "-B resets an existing branch; creates worktrees",
    "git worktree remove": "--force discards uncommitted work",
    "git worktree prune": "removes worktree metadata",
    "git worktree move": "moves a worktree",
    "git symbolic-ref": "the two-arg form writes a ref",
    "git reflog": "delete/expire mutate the reflog",
    "git update-ref": "writes refs", "git update-index": "writes the index",
    # general-purpose API clients that mutate depending on args
    "gh api": "runs GraphQL/REST mutations",
    "gh pr merge": "merges", "gh pr create": "creates", "gh pr edit": "edits",
    "gh pr comment": "posts", "gh pr close": "closes", "gh pr checkout": "mutates worktree",
    "gh issue create": "creates", "gh issue edit": "edits", "gh issue close": "closes",
    "az rest": "arbitrary REST incl. writes",
    "az devops invoke": "arbitrary API incl. writes",
    "az boards work-item update": "updates work items",
    "az boards work-item create": "creates work items",
    "az repos pr create": "creates PRs", "az repos pr update": "updates PRs",
}

# Exception: git config read forms explicitly flagged read-only. These must be
# more specific than the "git config" key above, and are allowed through.
BASH_READONLY_EXCEPTIONS = (
    "git config --get",
    "git config --list",
)

# Substrings that mark an MCP tool as mutating. An mcp__ allow entry containing
# any of these is a violation (read-only tools use get/list/show/query/search).
MUTATING_MCP = (
    "_update", "_create", "_add_", "_add ", "_delete", "_remove", "_reply",
    "_vote", "_link", "_unlink", "run_pipeline", "create_pipeline",
    "update_build", "_set_", "authenticate",
)


def bash_command(entry: str) -> str | None:
    """Return the command string inside a Bash(...) allow entry, else None."""
    m = re.match(r"^Bash\((.*?)(?::\*)?\)$", entry)
    if not m:
        return None
    return m.group(1).strip()


def main() -> int:
    here = Path(__file__).resolve().parent
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else here / "settings.json"

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot read/parse {path}: {exc}")
        return 1

    allow = (data.get("permissions") or {}).get("allow", [])
    violations: list[str] = []

    for entry in allow:
        if entry.startswith("mcp__"):
            lowered = entry.lower()
            for mark in MUTATING_MCP:
                if mark in lowered:
                    violations.append(f"{entry}  -> mutating MCP tool (matched '{mark.strip()}')")
                    break
            continue

        cmd = bash_command(entry)
        if cmd is None:
            continue  # Write(...) and other rule types are out of scope here
        if any(cmd == ex or cmd.startswith(ex + " ") for ex in BASH_READONLY_EXCEPTIONS):
            continue
        for key, reason in WRITE_CAPABLE.items():
            if cmd == key or cmd.startswith(key + " "):
                violations.append(f"Bash({cmd})  -> {reason}")
                break

    if violations:
        print(f"FAIL: {len(violations)} mutating allow rule(s) in {path.name}:")
        for v in violations:
            print(f"  - {v}")
        return 1

    n_bash = sum(1 for e in allow if e.startswith("Bash("))
    n_mcp = sum(1 for e in allow if e.startswith("mcp__"))
    print(f"OK: {len(allow)} allow entries validated ({n_bash} Bash, {n_mcp} MCP) - none can mutate state.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
