#!/usr/bin/env python3
"""Fail when a plugin command or skill pre-approves a broad tool.

`allowed-tools` in a command or skill's frontmatter pre-approves those tools
while it runs: Claude Code does not ask first. A bare `Bash` grant lets every
shell command run unasked, and `WebFetch` lets any URL be fetched unasked -
dangerous in commands that read text other people wrote (PR descriptions, work
items, logs, web pages), where that text can try to steer the agent.

Rules:
  - a NEW command or skill may not grant bare `Bash` or `WebFetch`; grant
    specific commands instead, e.g. `Bash(gh pr view *)`;
  - the files in BASELINE predate this check and still do. They are a
    burn-down list: when a file is narrowed, remove it from BASELINE (the
    check fails until you do, so the list can only shrink).

Usage: python3 scripts/check-allowed-tools.py [repo-root]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

BROAD = ("Bash", "WebFetch")

# Files that granted a broad tool when this check was added. Narrow them one PR
# at a time and delete each entry as you go.
BASELINE = {
    "plugins/cc-census/commands/cc-census-report.md",
    "plugins/cc-census/commands/cc-census.md",
    "plugins/ci/commands/init.md",
    "plugins/ci/commands/minutes.md",
    "plugins/ci/commands/update.md",
    "plugins/craft-commit-push/commands/craft-commit-push.md",
    "plugins/craft-commit/commands/craft-commit.md",
    "plugins/craft-pr/commands/craft-pr.md",
    "plugins/craft-stage-commit-push/commands/craft-stage-commit-push.md",
    "plugins/craft-stage/commands/craft-stage.md",
    "plugins/handoff/commands/handoff.md",
    "plugins/handoff/commands/hh.md",
    "plugins/handoff/commands/hp.md",
    "plugins/handoff/commands/hr.md",
    "plugins/handoff/commands/pickup.md",
    "plugins/handoff/commands/relay.md",
    "plugins/har-investigate/commands/har-investigate.md",
    "plugins/improve-stories/commands/improve-stories.md",
    "plugins/investigate-appinsights-logs/commands/investigate-appinsights-logs.md",
    "plugins/sdd/commands/init.md",
    "plugins/sdd/commands/opt-out.md",
    "plugins/self-review/commands/self-review.md",
    "plugins/start-work/commands/start-work.md",
    "plugins/tfvc-search/commands/tfvc-search.md",
    "plugins/typ-glyph/commands/typ-glyph.md",
    "plugins/sdd/skills/conformance-review/SKILL.md",
}


def allowed_tools(text: str) -> list[str] | None:
    """Return the allowed-tools entries from a file's YAML frontmatter, or None."""
    match = re.match(r"---\r?\n(.*?)\r?\n---", text, re.DOTALL)
    if not match:
        return None
    line = re.search(r"^allowed-tools:[ \t]*(.*)$", match.group(1), re.MULTILINE)
    if not line:
        return None
    # Split on commas that are not inside a Bash(...) specifier.
    entries, depth, current = [], 0, ""
    for char in line.group(1):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            entries.append(current.strip())
            current = ""
        else:
            current += char
    entries.append(current.strip())
    return [entry for entry in entries if entry]


def broad_grants(entries: list[str]) -> list[str]:
    return [entry for entry in entries if entry in BROAD]


def check(root: Path) -> list[str]:
    problems = []
    files = sorted(root.glob("plugins/*/commands/*.md")) + sorted(root.glob("plugins/*/skills/*/SKILL.md"))
    seen = set()
    for path in files:
        rel = path.relative_to(root).as_posix()
        seen.add(rel)
        entries = allowed_tools(path.read_text(encoding="utf-8"))
        broad = broad_grants(entries or [])
        if broad and rel not in BASELINE:
            problems.append(f"{rel}: grants {', '.join(broad)} without a specifier; grant specific "
                            f"commands instead, e.g. Bash(gh pr view *)")
        if not broad and rel in BASELINE:
            problems.append(f"{rel}: no longer grants a broad tool - remove it from BASELINE")
    for rel in sorted(BASELINE - seen):
        problems.append(f"{rel}: listed in BASELINE but does not exist - remove it")
    return problems


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    problems = check(root)
    if problems:
        print(f"FAIL: {len(problems)} allowed-tools problem(s):")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"OK: no new broad tool grants ({len(BASELINE)} grandfathered files left to narrow).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
