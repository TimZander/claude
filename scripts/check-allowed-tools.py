#!/usr/bin/env python3
"""Fail when a plugin command, skill or agent pre-approves a broad tool.

`allowed-tools` in a command or skill's frontmatter (and `tools` in an agent's)
pre-approves those tools while it runs: Claude Code does not ask first. A broad
grant - bare `Bash`, a Bash rule that matches anything or launches an
interpreter, or an unrestricted `WebFetch` - lets the agent run any command or
reach any URL unasked. That is dangerous in commands that read text other
people wrote (PR descriptions, work items, logs, web pages), where that text
can try to steer the agent.

Rules:
  - a NEW command, skill or agent may not grant a broad tool; grant specific
    commands instead, e.g. `Bash(gh pr view *)`, or none;
  - the files in BASELINE predate this check and still do. They are a
    burn-down list: when a file is narrowed, delete its entry (the check fails
    until you do). Adding an entry is a review decision, not a fix - reviewers
    should reject it unless the PR says why the grant cannot be narrowed.

Usage: python3 scripts/check-allowed-tools.py [repo-root]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# A Bash rule whose command is one of these can run anything, whatever follows.
INTERPRETERS = {"bash", "sh", "zsh", "dash", "pwsh", "powershell", "cmd", "python", "python3", "py",
                "node", "perl", "ruby", "eval", "env", "xargs", "sudo", "exec", "command", "source"}

# Files that granted a broad tool when this check was added. Narrow them one PR
# at a time and delete each entry as you go. Kept sorted.
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
    "plugins/investigate-appinsights-logs/commands/investigate-appinsights-logs.md",
    "plugins/sdd/commands/init.md",
    "plugins/sdd/commands/opt-out.md",
    "plugins/sdd/skills/conformance-review/SKILL.md",
    "plugins/sdd/skills/spec-review/SKILL.md",
    "plugins/self-review/commands/self-review.md",
    "plugins/start-work/commands/start-work.md",
    "plugins/tfvc-search/commands/tfvc-search.md",
    "plugins/typ-glyph/commands/typ-glyph.md",
}

# Where tool grants live, and the frontmatter key each kind of file uses.
SCAN = (
    ("commands/**/*.md", "allowed-tools"),
    ("skills/**/SKILL.md", "allowed-tools"),
    ("agents/**/*.md", "tools"),
)
PLUGIN_ROOTS = ("plugins", "external_plugins")

FRONTMATTER = re.compile(r"\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\Z)", re.DOTALL)


class FrontmatterError(ValueError):
    """The frontmatter cannot be read reliably, so the file fails the check."""


def _strip_comment(value: str) -> str:
    """Drop a YAML comment (` #...`) that is not inside parentheses or quotes."""
    depth, quote = 0, ""
    for index, char in enumerate(value):
        if quote:
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth = max(depth - 1, 0)
        elif char == "#" and depth == 0 and (index == 0 or value[index - 1].isspace()):
            return value[:index]
    return value


def _split(value: str) -> list[str]:
    """Split a comma-separated list on commas outside parentheses."""
    entries, depth, current = [], 0, ""
    for char in value:
        if char == "(":
            depth += 1
        elif char == ")":
            depth = max(depth - 1, 0)
        if char == "," and depth == 0:
            entries.append(current)
            current = ""
        else:
            current += char
    entries.append(current)
    return entries


def _unquote(entry: str) -> str:
    entry = entry.strip()
    if len(entry) >= 2 and entry[0] == entry[-1] and entry[0] in "'\"":
        entry = entry[1:-1].strip()
    return entry


def tool_grants(text: str, key: str = "allowed-tools") -> list[str] | None:
    """Return the tool entries under `key` in a file's frontmatter, or None if
    there is no frontmatter or no such key. Accepts the inline comma form, a
    flow list `[a, b]`, a block list (`- a` lines), quoted entries and trailing
    comments. Raises FrontmatterError for a duplicated key."""
    text = text.lstrip("﻿")
    match = FRONTMATTER.match(text)
    if not match:
        return None
    lines = match.group(1).splitlines()
    key_lines = [i for i, line in enumerate(lines) if re.match(rf"{re.escape(key)}[ \t]*:", line)]
    if not key_lines:
        return None
    if len(key_lines) > 1:
        raise FrontmatterError(f"'{key}' appears {len(key_lines)} times in the frontmatter")
    index = key_lines[0]
    value = _strip_comment(lines[index].split(":", 1)[1]).strip()
    if not value:
        block = []
        for line in lines[index + 1:]:
            item = re.match(r"[ \t]+-[ \t]*(.*)$", line)
            if not item:
                if line.strip() == "" or line.lstrip().startswith("#"):
                    continue
                break
            block.append(_strip_comment(item.group(1)))
        entries = block
    else:
        value = _unquote(value)
        if value.startswith("[") and value.endswith("]"):
            value = value[1:-1]
        entries = _split(value)
    return [entry for entry in (_unquote(e) for e in entries) if entry]


def is_broad(entry: str) -> bool:
    """True if a tool entry pre-approves any command or any URL."""
    name, _, rest = entry.partition("(")
    name = name.strip().lower()
    if name not in ("bash", "webfetch"):
        return False
    if not rest:
        return True
    spec = rest.rsplit(")", 1)[0].strip()
    if spec in ("", "*", ":*"):
        return True
    if name == "webfetch":
        return spec.endswith("*")
    if spec.startswith("*"):
        return True
    command = spec.split()[0].replace("\\", "/").rsplit("/", 1)[-1].lower().removesuffix(".exe")
    return command in INTERPRETERS


def broad_grants(entries: list[str]) -> list[str]:
    return [entry for entry in entries if is_broad(entry)]


def check(root: Path) -> list[str]:
    problems = []
    seen = set()
    for plugin_root in PLUGIN_ROOTS:
        for pattern, key in SCAN:
            for path in sorted(root.glob(f"{plugin_root}/*/{pattern}")):
                rel = path.relative_to(root).as_posix()
                seen.add(rel)
                try:
                    entries = tool_grants(path.read_text(encoding="utf-8"), key)
                except (OSError, UnicodeDecodeError, FrontmatterError) as exc:
                    problems.append(f"{rel}: cannot read its tool grants ({exc})")
                    continue
                broad = broad_grants(entries or [])
                if broad and rel not in BASELINE:
                    problems.append(f"{rel}: grants {', '.join(broad)}, which pre-approves any command or URL; "
                                    f"grant specific commands instead, e.g. Bash(gh pr view *)")
                if not broad and rel in BASELINE:
                    problems.append(f"{rel}: no longer grants a broad tool - remove it from BASELINE")
    for rel in sorted(BASELINE - seen):
        problems.append(f"{rel}: listed in BASELINE but does not exist - remove it")
    return problems


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    if not (root / "plugins").is_dir():
        print(f"FAIL: {root} has no plugins/ directory; pass the repository root.")
        return 2
    problems = check(root)
    if problems:
        print(f"FAIL: {len(problems)} tool-grant problem(s):")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"OK: no new broad tool grants ({len(BASELINE)} grandfathered files left to narrow).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
