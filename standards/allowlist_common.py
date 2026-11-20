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


def parse_bash_prefix(entry: str):
    """Return the command prefix inside a `Bash(<prefix>[:*| *])` allow entry.

    Handles both the `:*` and the space-` *` wildcard forms and a bare
    `Bash(cmd)`. Returns None for non-Bash rules (Edit(...), mcp__..., etc.).
    """
    m = re.match(r"^Bash\((.*?)(?::\*| \*)?\)$", entry)
    return m.group(1).strip() if m else None


def has_trailing_wildcard(entry: str) -> bool:
    """True if a Bash rule ends in a word wildcard (` *` or `:*`)."""
    return entry.endswith(":*)") or entry.endswith(" *)")


def bash_rule_matches(rule: str, command: str) -> bool:
    """True if a `Bash(...)` permission rule matches one command, following the
    documented Claude Code semantics (https://code.claude.com/docs/en/permissions):
    `*` matches any text including spaces and may appear anywhere; a trailing
    `:*` is the same as ` *`; and a trailing ` *` that is the rule's only
    wildcard also matches the bare command. Quoting is not modeled.
    """
    m = re.fullmatch(r"Bash\((.*)\)", rule, re.DOTALL)
    if not m:
        return False
    pattern = m.group(1)
    if pattern.endswith(":*"):
        pattern = pattern[:-2] + " *"
    if pattern.endswith(" *") and pattern.count("*") == 1 and command == pattern[:-2]:
        return True
    regex = ".*".join(re.escape(part) for part in pattern.split("*"))
    return re.fullmatch(regex, command, re.DOTALL) is not None


def seg_matches(seg: str, prefixes) -> bool:
    """True if one command segment is covered by an allow prefix (token-bounded)."""
    seg = seg.strip()
    return any(seg == p or seg.startswith(p + " ") for p in prefixes)


def bash_covered(cmd: str, prefixes) -> bool:
    """True only if EVERY segment of a compound command matches an allow prefix
    (mirrors Claude Code: one unapproved segment prompts the whole line), and
    the command contains no redirect/substitution that a prefix match can't vet.
    """
    if any(tok in cmd for tok in RISKY):
        return False
    segs = [s for s in SEP.split(cmd) if s.strip()]
    return bool(segs) and all(seg_matches(s, prefixes) for s in segs)
