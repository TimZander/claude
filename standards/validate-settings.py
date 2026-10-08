#!/usr/bin/env python3
"""Guard against dangerous commands slipping into the team allowlist.

`standards/settings.json` is synced into every developer's user-scope
`~/.claude/settings.json`, so anything in its `permissions.allow` list is
pre-approved for everyone in every repo and worktree. This validator fails
(exit 1) if any allow entry:
  - names a known write-capable / arbitrary-execution command (incl. ones that
    write without a redirect: `sort -o`, `uniq in out`, `git worktree add -B`),
  - is a bare command-family root (`git`, `gh`, `az`, …) whose wildcard would
    auto-approve every subcommand including writes,
  - is a proper prefix of a known write command (so `Bash(git worktree:*)`
    would reach `git worktree add`), or
  - is an MCP wildcard (`mcp__server__*`) or an MCP tool not in the reviewed
    known-safe set (`KNOWN_SAFE_MCP`).

The two surfaces are gated differently on purpose:
  - Bash is a DENYLIST of known-dangerous shapes. An open-ended command space
    can't be enumerated, so a novel dangerous Bash command not listed here
    could still pass — treat a green Bash result as "no known-dangerous entry",
    not "provably safe".
  - MCP is an ALLOWLIST (`KNOWN_SAFE_MCP`). The tool namespace is finite, so
    anything not explicitly vetted read-only is rejected (fail-closed).

Usage: python3 validate-settings.py [path-to-settings.json]
       (defaults to the settings.json next to this script)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from allowlist_common import parse_bash_prefix

# Command prefixes that must NEVER be allow-listed, each with a reason. Matched
# when an entry's command equals the key or begins with "<key> " (token bound),
# so `git worktree add` also catches `git worktree add -B ...`.
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
    "truncate": "truncates files", "mkdir": "creates directories",
    # arbitrary code execution / interpreters
    "python": "arbitrary code execution", "python3": "arbitrary code execution",
    "py": "arbitrary code execution", "bash": "runs an arbitrary script",
    "sh": "runs an arbitrary script", "zsh": "runs an arbitrary script",
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

# Bare command-family roots: an entry equal to one of these (e.g. `Bash(git:*)`)
# would auto-approve every subcommand, including writes.
FAMILY_ROOTS = {"git", "gh", "az", "aws", "gcloud", "docker", "kubectl",
                "psql", "mysql", "sqlcmd", "cargo", "go"}

# git read forms explicitly flagged read-only (more specific than the "git
# config" write key above); allowed through.
BASH_READONLY_EXCEPTIONS = ("git config --get", "git config --list")

# Substrings that mark an MCP tool as mutating (read-only tools use
# get/list/show/query/search). Kept as a defense-in-depth backstop under the
# allowlist below — it flags a mutating name accidentally added to KNOWN_SAFE_MCP.
MUTATING_MCP = (
    "_update", "_create", "_add_", "_delete", "_remove", "_reply",
    "_vote", "_link", "_unlink", "run_pipeline", "create_pipeline",
    "update_build", "_set_", "authenticate",
)

# MCP tools reviewed and verified read-only. An mcp__ allow entry MUST be in
# this set (fail-closed). Adding a name here is a deliberate security decision:
# confirm the tool cannot mutate state before adding it (and to settings.json).
# CI fails if settings.json allows an mcp__ tool absent from this set.
KNOWN_SAFE_MCP = {
    "mcp__azure-devops__wit_get_work_item",
    "mcp__azure-devops__wit_get_work_items_batch_by_ids",
    "mcp__azure-devops__wit_query_by_wiql",
    "mcp__azure-devops__wit_list_work_item_comments",
    "mcp__azure-devops__wit_my_work_items",
    "mcp__azure-devops__wit_get_work_item_attachment",
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


def check_bash(cmd: str):
    """Return a violation reason for a Bash command prefix, or None if allowed."""
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
                "add it there after verifying, then to settings.json")
    lowered = entry.lower()
    hit = next((m for m in MUTATING_MCP if m in lowered), None)
    if hit:
        return f"listed in KNOWN_SAFE_MCP but the name looks mutating (matched '{hit.strip('_')}') - re-verify"
    return None


def main() -> int:
    here = Path(__file__).resolve().parent
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else here / "settings.json"

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot read/parse {path}: {exc}")
        return 1

    allow = (data.get("permissions") or {}).get("allow", [])
    violations = []

    for entry in allow:
        if entry.startswith("mcp__"):
            reason = check_mcp(entry)
            if reason:
                violations.append(f"{entry}  -> {reason}")
            continue
        cmd = parse_bash_prefix(entry)
        if cmd is None:
            continue  # Write(...) and other rule types are out of scope here
        reason = check_bash(cmd)
        if reason:
            violations.append(f"Bash({cmd})  -> {reason}")

    if violations:
        print(f"FAIL: {len(violations)} dangerous allow rule(s) in {path.name}:")
        for v in violations:
            print(f"  - {v}")
        return 1

    n_bash = sum(1 for e in allow if e.startswith("Bash("))
    n_mcp = sum(1 for e in allow if e.startswith("mcp__"))
    print(f"OK: {len(allow)} allow entries checked ({n_bash} Bash, {n_mcp} MCP) - "
          f"none match a known-dangerous pattern.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
