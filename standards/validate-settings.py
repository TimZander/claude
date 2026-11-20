#!/usr/bin/env python3
"""Guard what the team settings file may grant.

`standards/settings.json` is synced into every developer's user-scope
`~/.claude/settings.json`, so whatever it contains applies to everyone in every
repo and worktree. This validator fails (exit 1) unless:

  - the file holds only the keys a team file may set: `permissions` (with only
    `allow`, `ask` and `deny`), `attribution` (with only string `commit`/`pr`)
    and `$schema`. Anything else - `defaultMode`, `hooks`, `env`,
    `apiKeyHelper`, `additionalDirectories`, `statusLine`, ... - can run code
    or weaken every prompt, so it is rejected (fail-closed);
  - every `allow` entry is a rule type this guard knows how to vet (fail-closed):
      * `Bash(...)`: exact, or a single trailing word wildcard (` *` / `:*`);
        not a known write-capable / arbitrary-execution command, a bare
        command-family root, or a token prefix of a write command;
      * `mcp__...`: an MCP tool in the reviewed read-only set `KNOWN_SAFE_MCP`;
      * `Edit(...)`: a path rule in the reviewed set `KNOWN_SAFE_PATH_RULES`.
    `Write(...)` (ignored by Claude Code), `Read(...)`, `WebFetch(...)` and
    every other type fail;
  - every allowed command family with a known file-writing or disclosure flag
    is paired with the `ask` rules in `REQUIRED_ASK`, so that flag still
    prompts (ask rules beat allow rules and Claude Code's built-in read-only
    approval);
  - `ask` and `deny` entries are well-formed rule strings.

The surfaces are gated differently on purpose:
  - Bash is a DENYLIST of known-dangerous shapes. An open-ended command space
    can't be enumerated, so a novel dangerous Bash command could still pass -
    treat a green Bash result as "no known-dangerous entry", not "provably safe".
  - MCP tools and path rules are ALLOWLISTS: anything not explicitly reviewed is
    rejected.

Matching note: Claude Code treats `Bash(cmd:*)` exactly like `Bash(cmd *)` - a
word-bounded prefix - so `Bash(git c:*)` cannot reach `git commit`, and the
token-bounded prefix check below mirrors that.

Usage: python3 validate-settings.py [path-to-settings.json]
       (defaults to the settings.json next to this script)
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from allowlist_common import parse_bash_prefix

ALLOWED_TOP_LEVEL = {"$schema", "permissions", "attribution"}
ALLOWED_PERMISSION_KEYS = {"allow", "ask", "deny"}
ALLOWED_ATTRIBUTION_KEYS = {"commit", "pr"}

# Command prefixes that must NEVER be allow-listed, each with a reason. Matched
# when an entry's command equals the key or begins with "<key> " (token bound),
# so `git worktree add` also catches `git worktree add -B ...`. Order matters
# where one key extends another: the first match supplies the reason.
WRITE_CAPABLE = {
    # read-looking utils with a non-redirect write or exec vector
    "sort": "sort -o/--output FILE overwrites a file",
    "uniq": "uniq takes a positional OUTPUT file (uniq in out)",
    "tee": "tee writes stdin to files",
    "dd": "dd of= writes a file/device",
    "sed": "sed -i edits files in place; the e command runs shell",
    "awk": "awk system() and print > file run commands and write files",
    "find": "find -exec runs commands and -delete removes files",
    # generic mutating file ops
    "cp": "copies/overwrites files", "mv": "moves/overwrites files",
    "rm": "deletes files", "chmod": "changes permissions",
    "chown": "changes ownership", "ln": "creates links",
    "truncate": "truncates files", "mkdir": "creates directories",
    # arbitrary code execution / interpreters
    "python": "arbitrary code execution", "python3": "arbitrary code execution",
    "py": "arbitrary code execution", "bash": "runs an arbitrary script",
    "sh": "runs an arbitrary script", "zsh": "runs an arbitrary script",
    "pwsh": "runs an arbitrary script", "powershell": "runs an arbitrary script",
    "cmd": "runs an arbitrary script",
    "node": "arbitrary code execution", "ruby": "arbitrary code execution",
    "perl": "arbitrary code execution", "eval": "evaluates arbitrary text",
    "xargs": "runs arbitrary commands", "env": "can exec an arbitrary command",
    "make": "runs arbitrary recipes", "npm": "runs arbitrary scripts",
    "npx": "runs arbitrary packages", "pnpm": "runs arbitrary scripts",
    "yarn": "runs arbitrary scripts", "pip": "can run setup code",
    "pip3": "can run setup code", "uv": "can run setup code",
    "dotnet": "builds/runs arbitrary code",
    # network I/O (download / exfiltration)
    "curl": "network I/O", "wget": "network I/O", "ssh": "remote execution",
    "scp": "remote file copy", "nc": "network I/O", "ncat": "network I/O",
    # git subcommands that mutate refs/worktree/index/history or run tools
    "git commit": "writes history", "git push": "publishes refs",
    "git checkout": "mutates working tree/refs",
    "git switch": "mutates working tree/refs",
    "git reset": "moves refs / discards changes",
    "git restore": "discards working-tree changes",
    "git branch": "-D/-m/-f create/delete/rename branches",
    "git tag": "creates/deletes tags", "git stash": "mutates stash/worktree",
    "git merge": "mutates history/worktree", "git rebase": "rewrites history",
    "git cherry-pick": "writes history", "git revert": "writes history",
    "git pull": "fetches and merges", "git fetch": "writes refs; --upload-pack runs a command",
    "git clone": "writes a repository; --upload-pack runs a command",
    "git init": "creates a repository", "git clean": "deletes untracked files",
    "git rm": "removes tracked files", "git mv": "moves tracked files",
    "git apply": "applies patches", "git am": "applies patches",
    "git format-patch": "-o writes patch files",
    "git archive": "-o/--output writes an archive",
    "git bundle": "create writes a bundle file",
    "git difftool": "--extcmd runs an arbitrary command",
    "git mergetool": "runs a configured tool and writes files",
    "git submodule": "clones and checks out code",
    "git bisect": "checks out commits; run executes a command",
    "git gc": "rewrites the object store", "git notes": "writes notes refs",
    "git replace": "writes replace refs", "git filter-branch": "rewrites history",
    "git config --list": "prints credentials embedded in remote URLs; --file reads any path",
    "git config": "the write form (git config key value) mutates config",
    "git worktree add": "-B resets an existing branch; creates worktrees",
    "git worktree remove": "--force discards uncommitted work",
    "git worktree prune": "removes worktree metadata",
    "git worktree move": "moves a worktree",
    "git symbolic-ref": "the two-arg form writes a ref",
    "git reflog": "delete/expire mutate the reflog",
    "git update-ref": "writes refs", "git update-index": "writes the index",
    # general-purpose API clients and gh/az subcommands that mutate or disclose
    "gh api": "runs GraphQL/REST mutations",
    "gh auth login": "changes stored credentials", "gh auth logout": "removes credentials",
    "gh auth refresh": "changes token scopes", "gh auth setup-git": "writes git config",
    "gh auth switch": "changes the active account", "gh auth token": "prints the auth token",
    "gh pr merge": "merges", "gh pr create": "creates", "gh pr edit": "edits",
    "gh pr comment": "posts", "gh pr close": "closes", "gh pr checkout": "mutates worktree",
    "gh issue create": "creates", "gh issue edit": "edits", "gh issue close": "closes",
    "gh repo clone": "writes a repository", "gh repo create": "creates",
    "gh repo delete": "deletes", "gh repo edit": "edits", "gh repo fork": "creates",
    "gh run rerun": "starts runs", "gh run cancel": "cancels runs",
    "gh run delete": "deletes runs", "gh run download": "writes files",
    "gh release create": "creates", "gh release delete": "deletes",
    "gh release download": "writes files", "gh release upload": "uploads",
    "gh workflow run": "starts workflows", "gh secret": "reads/writes secrets",
    "gh variable": "writes variables",
    "az rest": "arbitrary REST incl. writes",
    "az devops invoke": "arbitrary API incl. writes",
    "az boards work-item update": "updates work items",
    "az boards work-item create": "creates work items",
    "az repos pr create": "creates PRs", "az repos pr update": "updates PRs",
    "az pipelines run": "queues a build", "az pipelines create": "creates pipelines",
    "az pipelines update": "updates pipelines", "az pipelines delete": "deletes pipelines",
    "az pipelines build queue": "queues a build",
}

# Bare command-family roots: an entry equal to one of these (e.g. `Bash(git:*)`)
# would auto-approve every subcommand, including writes.
FAMILY_ROOTS = {"git", "gh", "az", "aws", "gcloud", "docker", "kubectl",
                "psql", "mysql", "sqlcmd", "cargo", "go"}

# git read forms explicitly allowed through (more specific than the
# "git config" write key above).
BASH_READONLY_EXCEPTIONS = ("git config --get", "git config --get-all", "git config --get-regexp")

# Commands that may only be allowed in their exact, argument-free form, because
# one of their flags discloses a secret.
EXACT_ONLY = {
    "gh auth status": "-t/--show-token prints the auth token; allow only the bare `Bash(gh auth status)`",
}

# Allowed command families with a flag that writes a file or reads outside the
# repo. An allow entry for the family is valid only if every rule listed here is
# in `ask` (or `deny`), so that flag keeps prompting.
REQUIRED_ASK = {
    "git log": ("Bash(git log *--output*)",),
    "git diff": ("Bash(git diff *--output*)",),
    "git show": ("Bash(git show *--output*)",),
    "git rev-list": ("Bash(git rev-list *--output*)",),
    "git shortlog": ("Bash(git shortlog *--output*)",),
    "git diff-tree": ("Bash(git diff-tree *--output*)",),
    "git diff-index": ("Bash(git diff-index *--output*)",),
    # git accepts --contents abbreviated down to --con.
    "git blame": ("Bash(git blame *--output*)", "Bash(git blame *--con*)"),
}

# Substrings that mark an MCP tool as mutating (read-only tools use
# get/list/show/query/search). Kept as a defense-in-depth backstop under the
# allowlist below - it flags a mutating name accidentally added to KNOWN_SAFE_MCP.
MUTATING_MCP = (
    "_update", "_create", "_add_", "_delete", "_remove", "_reply",
    "_vote", "_link", "_unlink", "run_pipeline", "create_pipeline",
    "update_build", "_set_", "authenticate", "attachment",
)

# MCP tools reviewed and verified read-only. An mcp__ allow entry MUST be in
# this set (fail-closed). Adding a name here is a deliberate security decision.
# Before adding a tool, read its live SCHEMA, not just its name: reject it if
# any parameter names a local path or file (savePath, outputPath, fileName, ...)
# or otherwise lets it write, run, or send anything. CI fails if settings.json
# allows an mcp__ tool absent from this set.
KNOWN_SAFE_MCP = {
    "mcp__azure-devops__wit_get_work_item",
    "mcp__azure-devops__wit_get_work_items_batch_by_ids",
    "mcp__azure-devops__wit_query_by_wiql",
    "mcp__azure-devops__wit_list_work_item_comments",
    "mcp__azure-devops__wit_my_work_items",
    "mcp__azure-devops__wit_get_work_item_type",
    "mcp__azure-devops__wit_get_query",
    "mcp__azure-devops__wit_get_query_results_by_id",
    "mcp__azure-devops__wit_get_work_items_for_iteration",
    "mcp__azure-devops__wit_list_work_item_revisions",
    "mcp__azure-devops__wit_list_backlogs",
    "mcp__azure-devops__wit_list_backlog_work_items",
    "mcp__azure-devops__repo_get_pull_request_by_id",
    "mcp__azure-devops__repo_list_pull_request_threads",
    "mcp__azure-devops__repo_list_pull_request_thread_comments",
    "mcp__azure-devops__repo_get_pull_request_changes",
    "mcp__azure-devops__repo_list_pull_requests_by_repo_or_project",
    "mcp__azure-devops__repo_list_pull_requests_by_commits",
    "mcp__azure-devops__repo_get_file_content",
    "mcp__azure-devops__repo_get_repo_by_name_or_id",
    "mcp__azure-devops__repo_list_repos_by_project",
    "mcp__azure-devops__repo_list_directory",
    "mcp__azure-devops__repo_list_branches_by_repo",
    "mcp__azure-devops__repo_list_my_branches_by_repo",
    "mcp__azure-devops__repo_get_branch_by_name",
    "mcp__azure-devops__repo_search_commits",
    "mcp__azure-devops__core_list_projects",
    "mcp__azure-devops__core_list_project_teams",
    "mcp__azure-devops__core_get_identity_ids",
    "mcp__azure-devops__pipelines_get_builds",
    "mcp__azure-devops__pipelines_get_build_log",
    "mcp__azure-devops__pipelines_get_build_log_by_id",
    "mcp__azure-devops__pipelines_get_build_definitions",
    "mcp__azure-devops__pipelines_get_build_definition_revisions",
    "mcp__azure-devops__pipelines_get_build_status",
    "mcp__azure-devops__pipelines_get_build_changes",
    "mcp__azure-devops__pipelines_get_run",
    "mcp__azure-devops__pipelines_list_runs",
    "mcp__azure-devops__pipelines_list_artifacts",
    "mcp__newrelic__execute_nrql_query",
    "mcp__newrelic__natural_language_to_nrql_query",
    "mcp__newrelic__get_entity",
    "mcp__newrelic__search_entity_with_tag",
    "mcp__newrelic__list_change_events",
    "mcp__newrelic__convert_time_period_to_epoch_ms",
}

# Path rules reviewed and allowed (fail-closed). Each grants writes to one
# narrow scratch location. Claude Code ignores Write(...) rules; Edit(...) also
# governs the Write tool. `//` anchors at the filesystem root; a bare relative
# path is relative to the session's working directory.
KNOWN_SAFE_PATH_RULES = {
    "Edit(//tmp/pastedlog-*)",
    "Edit(.claude-scratch/**)",
}

# A well-formed rule string: a tool name with an optional (...) specifier, or an
# MCP tool name.
RULE_SHAPE = re.compile(r"^(mcp__[A-Za-z0-9_-]+(__[A-Za-z0-9_*-]+)?|[A-Za-z]+(\(.+\))?)$")


def has_wildcard(entry: str) -> bool:
    """True if a Bash allow entry ends in a word wildcard (` *` or `:*`)."""
    return entry.endswith(":*)") or entry.endswith(" *)")


def check_bash(cmd: str):
    """Return a violation reason for a Bash command prefix, or None if allowed."""
    if "*" in cmd:
        return "wildcard inside the rule; only one trailing ` *` (or `:*`) is allowed"
    if any(cmd == ex or cmd.startswith(ex + " ") for ex in BASH_READONLY_EXCEPTIONS):
        return None
    if cmd in FAMILY_ROOTS:
        return "bare command-family root; wildcard would auto-approve every subcommand incl. writes"
    hit = next((k for k in WRITE_CAPABLE if cmd == k or cmd.startswith(k + " ")), None)
    if hit:
        return WRITE_CAPABLE[hit]
    hit = next((k for k in WRITE_CAPABLE if k.startswith(cmd + " ")), None)
    if hit:
        return f"prefix of write command '{hit}' ({WRITE_CAPABLE[hit]})"
    return None


def check_mcp(entry: str):
    """Return a violation reason for an mcp__ entry, or None if allowed.

    Allowlist (fail-closed): the entry must be a vetted read-only tool. The
    substring denylist is a defense-in-depth backstop against a mutating tool
    being added to KNOWN_SAFE_MCP by mistake.
    """
    if "*" in entry:
        return "wildcard MCP grant; would auto-approve every tool on the server incl. mutating ones"
    if entry not in KNOWN_SAFE_MCP:
        return ("not in the reviewed known-safe set (KNOWN_SAFE_MCP); if it is read-only, "
                "add it there after verifying its schema, then to settings.json")
    lowered = entry.lower()
    hit = next((m for m in MUTATING_MCP if m in lowered), None)
    if hit:
        return f"listed in KNOWN_SAFE_MCP but the name looks mutating (matched '{hit.strip('_')}') - re-verify"
    return None


def check_allow_entry(entry):
    """Classify one allow entry. Returns (kind, violation-or-None)."""
    if not isinstance(entry, str) or not entry:
        return "invalid", "not a non-empty string"
    if entry.startswith("mcp__"):
        return "mcp", check_mcp(entry)
    if entry.startswith("Bash("):
        cmd = parse_bash_prefix(entry)
        if not cmd:
            return "bash", "unparseable Bash rule"
        reason = check_bash(cmd)
        if reason is None and cmd in EXACT_ONLY and has_wildcard(entry):
            reason = EXACT_ONLY[cmd]
        return "bash", reason
    if entry.startswith("Edit("):
        if entry in KNOWN_SAFE_PATH_RULES:
            return "path", None
        return "path", "path rule not in the reviewed set (KNOWN_SAFE_PATH_RULES)"
    if entry.startswith("Write("):
        return "other", "Claude Code ignores Write(...) rules; use a reviewed Edit(...) rule instead"
    return "other", "rule type this guard cannot vet; only Bash(...), mcp__... and reviewed Edit(...) may be allowed"


def check_structure(data) -> list[str]:
    """Return violations for keys a team settings file must not contain."""
    if not isinstance(data, dict):
        return ["top level is not a JSON object"]
    violations = []
    for key in sorted(set(data) - ALLOWED_TOP_LEVEL):
        violations.append(f"top-level key '{key}' is not allowed in the team file "
                          f"(only {', '.join(sorted(ALLOWED_TOP_LEVEL))})")
    permissions = data.get("permissions", {})
    if not isinstance(permissions, dict):
        violations.append("'permissions' is not an object")
    else:
        for key in sorted(set(permissions) - ALLOWED_PERMISSION_KEYS):
            violations.append(f"'permissions.{key}' is not allowed in the team file "
                              f"(only {', '.join(sorted(ALLOWED_PERMISSION_KEYS))})")
        for key in sorted(ALLOWED_PERMISSION_KEYS & set(permissions)):
            if not isinstance(permissions[key], list):
                violations.append(f"'permissions.{key}' is not a list")
    if "attribution" in data:
        attribution = data["attribution"]
        if attribution is not False and not isinstance(attribution, dict):
            violations.append("'attribution' must be an object or false")
        elif isinstance(attribution, dict):
            for key in sorted(set(attribution) - ALLOWED_ATTRIBUTION_KEYS):
                violations.append(f"'attribution.{key}' is not allowed in the team file")
            for key in sorted(ALLOWED_ATTRIBUTION_KEYS & set(attribution)):
                if not isinstance(attribution[key], str):
                    violations.append(f"'attribution.{key}' must be a string")
    return violations


def main() -> int:
    here = Path(__file__).resolve().parent
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else here / "settings.json"

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot read/parse {path}: {exc}")
        return 1

    violations = check_structure(data)
    permissions = data.get("permissions", {}) if isinstance(data, dict) else {}
    if not isinstance(permissions, dict):
        permissions = {}

    def rule_list(key):
        value = permissions.get(key, [])
        return value if isinstance(value, list) else []

    allow, ask, deny = rule_list("allow"), rule_list("ask"), rule_list("deny")

    counts = {"bash": 0, "mcp": 0, "path": 0}
    allowed_cmds = []
    for entry in allow:
        kind, reason = check_allow_entry(entry)
        if reason:
            violations.append(f"allow {entry!r}  -> {reason}")
            continue
        counts[kind] += 1
        if kind == "bash":
            allowed_cmds.append(parse_bash_prefix(entry))

    for key, entries in (("ask", ask), ("deny", deny)):
        for entry in entries:
            if not isinstance(entry, str) or not RULE_SHAPE.match(entry):
                violations.append(f"{key} {entry!r}  -> not a well-formed permission rule")

    prompting = set(x for x in ask + deny if isinstance(x, str))
    for family, rules in REQUIRED_ASK.items():
        if any(cmd == family or cmd.startswith(family + " ") for cmd in allowed_cmds):
            for rule in rules:
                if rule not in prompting:
                    violations.append(f"allow Bash({family} ...) needs ask rule {rule!r}  "
                                      f"-> the flag writes a file or reads outside the repo")

    if violations:
        print(f"FAIL: {len(violations)} problem(s) in {path.name}:")
        for v in violations:
            print(f"  - {v}")
        return 1

    print(f"OK: {sum(counts.values())} allow entries checked ({counts['bash']} Bash, "
          f"{counts['mcp']} MCP, {counts['path']} path), {len(ask)} ask, {len(deny)} deny - "
          f"none match a known-dangerous pattern.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
