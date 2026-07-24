#!/usr/bin/env python3
"""Unit tests for allowlist_common (the shared parse/match logic). Run:
    python3 standards/test-allowlist-common.py
Exit 0 on pass, 1 on failure.
"""
from allowlist_common import bash_covered, parse_bash_prefix

PREFIXES = ["git log", "git status", "gh pr view"]
fails = []


def check(desc, got, want):
    if got != want:
        fails.append(f"{desc}: got {got!r}, want {want!r}")


# --- parsing: both wildcard forms and bare ---
check("parse :* form", parse_bash_prefix("Bash(git log:*)"), "git log")
check("parse space-* form", parse_bash_prefix("Bash(git diff *)"), "git diff")
check("parse bare", parse_bash_prefix("Bash(cd)"), "cd")
check("parse non-Bash -> None", parse_bash_prefix("mcp__x__y"), None)

# --- covered: single + all-covered compound ---
check("bare covered", bash_covered("git log --oneline", PREFIXES), True)
check("pipe both covered", bash_covered("git log | gh pr view 1", PREFIXES), True)
check("uncovered command", bash_covered("git push", PREFIXES), False)

# --- the split cases the review flagged ---
check("bare & splits (rm not covered)", bash_covered("git log & rm -rf x", PREFIXES), False)
check("semicolon splits", bash_covered("git log ; rm x", PREFIXES), False)
check("redirect is risky", bash_covered("git log > /tmp/out", PREFIXES), False)
check("append redirect is risky", bash_covered("git log >> /tmp/out", PREFIXES), False)
check("command substitution is risky", bash_covered("git log $(rm x)", PREFIXES), False)
check("backtick substitution is risky", bash_covered("git log `rm x`", PREFIXES), False)
check("cd prefix not covered", bash_covered("cd /x && git log", PREFIXES), False)
check("empty command", bash_covered("", PREFIXES), False)

if fails:
    print(f"FAIL: {len(fails)} case(s)")
    for f in fails:
        print("  -", f)
    raise SystemExit(1)
print("OK: all allowlist_common cases pass")
