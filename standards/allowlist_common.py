#!/usr/bin/env python3
"""Shared, read-only parsing/matching helpers for the allowlist scripts
(`validate-settings.py`, `measure-allowlist-impact.py`) and their tests, so
there is a single source of truth for how a `Bash(...)` rule is parsed and how
a command is matched against the allow prefixes. No writes / no network.
"""
from __future__ import annotations

import re

# The full separator set Claude Code documents for compound-command splitting.
# Order matters: multi-char operators before their single-char prefixes.
SEP = re.compile(r"&&|\|\||;|\|&|\||&|\n")

# Redirection / command-substitution tokens. A command containing any of these
# is NOT treated as auto-approved: a prefix rule's handling of `>` is
# undocumented and could write a file, and `$(...)`/backticks run a subcommand
# the prefix match never inspects. Conservatively count these as prompting.
RISKY = ("$(", "`", ">")

# Commands Claude Code auto-approves as built-in read-only, needing no allow
# rule (documented for v2.1.208+). Callers that want to model real auto-approval
# (e.g. measure-allowlist-impact.py) pass this to bash_covered(); callers that
# only care about the team allowlist (the validator, its tests) leave it empty.
# Two documented caveats are handled in bash_covered(): `cd` into a directory
# before `git` still prompts (the new dir's git hooks could run), and `find`
# with -delete/-exec mutates.
CLAUDE_BUILTIN_READONLY = frozenset({
    "ls", "cat", "echo", "pwd", "head", "tail", "grep", "find",
    "wc", "which", "diff", "stat", "du", "cd",
})

# find flags that make it mutate/execute (so it is no longer read-only).
_FIND_MUTATES = re.compile(r"(?:^|\s)-(?:delete|exec|execdir|fprint\w*|ok)\b")


def parse_bash_prefix(entry: str):
    """Return the command prefix inside a `Bash(<prefix>[:*| *])` allow entry.

    Handles both the `:*` and the space-` *` wildcard forms and a bare
    `Bash(cmd)`. Returns None for non-Bash rules (Write(...), mcp__..., etc.).
    """
    m = re.match(r"^Bash\((.*?)(?::\*| \*)?\)$", entry)
    return m.group(1).strip() if m else None


def seg_matches(seg: str, prefixes) -> bool:
    """True if one command segment is covered by an allow prefix (token-bounded)."""
    seg = seg.strip()
    return any(seg == p or seg.startswith(p + " ") for p in prefixes)


def _lead(seg: str) -> str:
    """Leading command token of a segment (empty string if none)."""
    parts = seg.split()
    return parts[0] if parts else ""


def bash_covered(cmd: str, prefixes, builtins=()) -> bool:
    """True only if Claude Code would run `cmd` WITHOUT a permission prompt.

    A compound command auto-approves only when EVERY segment is covered
    (mirrors Claude Code: one unapproved segment prompts the whole line). Each
    segment is covered when it matches an allow `prefix` or — when `builtins`
    is supplied — leads with a built-in read-only command. Always prompts (not
    covered) on:
      - redirect/substitution the prefix match can't vet (RISKY),
      - `cd <dir> && git ...`: running git in a new directory can execute that
        directory's hooks, so Claude Code prompts regardless of allow rules,
      - `find` with a mutating/executing flag (-delete/-exec/...).
    """
    if any(tok in cmd for tok in RISKY):
        return False
    segs = [s for s in SEP.split(cmd) if s.strip()]
    if not segs:
        return False
    leads = [_lead(s) for s in segs]
    if "cd" in leads and "git" in leads:
        return False
    for seg in segs:
        if seg_matches(seg, prefixes):
            continue
        lead = _lead(seg)
        if lead in builtins:
            if lead == "find" and _FIND_MUTATES.search(seg):
                return False
            continue
        return False
    return True
