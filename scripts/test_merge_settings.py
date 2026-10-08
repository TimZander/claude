#!/usr/bin/env python3
"""Unit tests for merge_settings.merge (issue #203). Run:
    python3 scripts/test_merge_settings.py
Exit 0 on pass, 1 on failure.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from merge_settings import merge

fails = []


def chk(cond, desc):
    print(("  ok: " if cond else "  FAIL: ") + desc)
    if not cond:
        fails.append(desc)


# deep merge + override wins
chk(merge({"k": "base"}, {"k": "over"})["k"] == "over", "override wins on scalar conflict")
chk(merge({"a": {"x": 1}}, {"a": {"y": 2}}) == {"a": {"x": 1, "y": 2}}, "objects deep-merge")

# array union: order-preserving, case-sensitive dedup
chk(merge({"a": ["z", "m"]}, {"a": ["m", "new"]})["a"] == ["z", "m", "new"],
    "array union is order-preserving + deduped")
chk(len(merge({"a": ["Bash(git log:*)"]}, {"a": ["bash(GIT LOG:*)"]})["a"]) == 2,
    "array union is case-sensitive")

# null heal (matches the PowerShell path: never crash/erase on a null)
chk(merge({"permissions": {"allow": ["x"]}}, {"permissions": None}) == {"permissions": {"allow": ["x"]}},
    "null override heals to base")
chk(merge({"k": None}, {"k": "v"})["k"] == "v", "null base yields override")

# whitespace-key drop (self-heal of a prior-corruption signature)
healed = merge({"permissions": {"allow": []}}, {"a b c": None, "tui": "x"})
chk("a b c" not in healed, "whitespace garbage key dropped")
chk(healed.get("tui") == "x", "clean keys survive the guard")

# the #201 real-world shape: single-key base + corrupted override
real = merge(
    {"permissions": {"allow": ["Bash(gh pr view:*)"], "deny": []}},
    {"permissions garbage": None,
     "permissions": {"allow": ["Bash(dotnet test *)"]},
     "tui": "dark"},
)
chk("permissions garbage" not in real, "corrupted key dropped (real-world shape)")
chk("Bash(gh pr view:*)" in real["permissions"]["allow"]
    and "Bash(dotnet test *)" in real["permissions"]["allow"], "allow unioned (real-world shape)")
chk(real["tui"] == "dark", "user pref preserved (real-world shape)")

# idempotency: re-merging an already-merged result changes nothing
base = {"permissions": {"allow": ["a", "b"], "deny": []}}
once = merge(base, {"permissions": {"allow": ["b", "c"]}, "tui": "dark"})
chk(once == merge(base, once), "merge is idempotent")

print("---")
if fails:
    print(f"FAILED: {len(fails)} case(s)")
    raise SystemExit(1)
print("OK: all merge_settings tests pass")
