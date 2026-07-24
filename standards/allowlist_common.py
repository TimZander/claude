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
    `Bash(cmd)`. Returns None for non-Bash rules (Write(...), mcp__..., etc.).
    """
    m = re.match(r"^Bash\((.*?)(?::\*| \*)?\)$", entry)
    return m.group(1).strip() if m else None


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
