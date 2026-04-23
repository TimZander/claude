#!/usr/bin/env python3
"""Discover KQL queries in a repo.

Looks in two places:
  1. `*.kql` files (recursive, skipping common vendored/build dirs).
  2. Fenced ```kql or ```kusto blocks inside `*.md` / `*.markdown` files.

Emits a JSON array on stdout:
  [{"source": "...", "title": "...", "content": "..."}, ...]

`source` is a display-friendly relative path (with an optional `#N` suffix for
the Nth fenced block in a markdown file). `title` is a best-effort single-line
guess: the first `// ...` comment in a .kql file, or the nearest preceding
markdown heading for a fenced block, falling back to the source path.

Usage:
  discover_queries.py [--cwd <path>] [--include <glob>]... [--exclude <glob>]...

`--include`, if given at least once, restricts discovery to files whose
relative path matches at least one glob (union across multiple flags). The
default (no `--include`) considers every `*.kql`, `*.md`, and `*.markdown`
file. `--exclude` is applied on top of the default skip list (`.git`,
`node_modules`, `dist`, `build`, etc.) which prunes any directory matching
by name — at every depth — so nested `node_modules` are also dropped.

Glob matching uses `fnmatch.fnmatchcase` (case-sensitive, deterministic across
OSes). `*` matches any character including `/` — it is NOT shell-glob
semantics. Use explicit patterns like `ops/traces.kql` or `**/*.kql` as
needed. ATX markdown headings only are recognized (setext `====`/`----` is
not matched). Heading tracking is "sticky": a fenced block below a section
header inherits the most recent heading, even across horizontal rules.

Skip-marker convention: a query whose first non-blank line is a KQL comment
containing `@skill-skip` (e.g. `// @skill-skip date-pinned helper`) is
emitted with a `"skipped": "<reason>"` field and `"content": ""`. The
handler is expected to surface these in the per-query findings table as
`[SKIPPED: <reason>]` without executing the query against the Azure CLI.
Useful for analytical helpers with hardcoded `datetime(...)` literals that
would otherwise produce meaningless single-row results.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_SKIP_DIRS = {
    ".git", "node_modules", "dist", "build", "out", "bin", "obj",
    ".venv", "venv", "__pycache__", ".next", ".nuxt", "target",
    ".claude", ".idea", ".vscode",
}

FENCE_RE = re.compile(r"^(`{3,}|~{3,})\s*([A-Za-z0-9_+.-]*)\s*$")
HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
# Matches a KQL comment on the first non-blank line carrying the @skill-skip marker.
# Examples:
#   // @skill-skip
#   // @skill-skip date-pinned helper, meant for manual copy-paste
SKILL_SKIP_RE = re.compile(r"^\s*//\s*@skill-skip(?:\s+(.+?))?\s*$")


def skill_skip_reason(content: str) -> str | None:
    """If `content`'s first non-blank line is a `// @skill-skip [reason]`
    marker, return the trimmed reason (or the literal string "author-marked"
    if no reason was supplied). Returns None if the marker is absent.
    """
    for line in content.splitlines():
        if not line.strip():
            continue
        m = SKILL_SKIP_RE.match(line)
        if m:
            return (m.group(1) or "").strip() or "author-marked"
        return None
    return None


def iter_files(root: Path, includes: list[str], excludes: list[str]):
    """Yield candidate files under `root`, pruning DEFAULT_SKIP_DIRS at every
    directory level via in-place `dirs[:]` modification so the walker never
    descends into them. Matching is case-sensitive (`fnmatchcase`) for
    cross-platform determinism.
    """
    for dirpath, dirs, files in os.walk(root):
        # Prune skip dirs in-place so os.walk doesn't descend.
        dirs[:] = sorted(d for d in dirs if d not in DEFAULT_SKIP_DIRS)
        for filename in sorted(files):
            path = Path(dirpath) / filename
            rel = path.relative_to(root).as_posix()
            if any(fnmatch.fnmatchcase(rel, pat) for pat in excludes):
                continue
            if includes and not any(fnmatch.fnmatchcase(rel, pat) for pat in includes):
                continue
            yield path


def title_from_kql(text: str, fallback: str) -> str:
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("//"):
            return line.lstrip("/ ").strip() or fallback
        break
    return fallback


def extract_kql_from_markdown(md_text: str):
    """Yield (title, content, block_index) for each ```kql fenced block."""
    lines = md_text.splitlines()
    last_heading: str | None = None
    i = 0
    block_index = 0
    while i < len(lines):
        line = lines[i]
        m_head = HEADING_RE.match(line)
        if m_head:
            last_heading = m_head.group(2).strip()
            i += 1
            continue
        m_fence = FENCE_RE.match(line)
        if m_fence and m_fence.group(2).lower() in {"kql", "kusto"}:
            fence = m_fence.group(1)
            start = i + 1
            j = start
            while j < len(lines):
                m_close = FENCE_RE.match(lines[j])
                if m_close and m_close.group(1).startswith(fence[0]) and len(m_close.group(1)) >= len(fence) and not m_close.group(2):
                    break
                j += 1
            content = "\n".join(lines[start:j])
            block_index += 1
            yield (last_heading, content, block_index)
            i = j + 1
            continue
        i += 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", default=".", help="Directory to search (default: .)")
    parser.add_argument("--include", action="append", default=[],
                        help="Restrict discovery to files whose relative path "
                             "matches at least one of these globs (case-sensitive "
                             "fnmatch). Repeatable; results are unioned. Default: "
                             "no filter — every *.kql / *.md / *.markdown file is "
                             "considered.")
    parser.add_argument("--exclude", action="append", default=[],
                        help="Drop files whose relative path matches any of these "
                             "globs. Repeatable. Applied on top of the built-in "
                             "top-level skip list (.git, node_modules, etc.).")
    args = parser.parse_args(argv)

    root = Path(args.cwd).resolve()
    if not root.is_dir():
        print(f"error: --cwd is not a directory: {root}", file=sys.stderr)
        return 2

    results: list[dict] = []

    for path in iter_files(root, args.include, args.exclude):
        rel = path.relative_to(root).as_posix()
        suffix = path.suffix.lower()
        if suffix == ".kql":
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                print(f"warning: could not read {rel}: {e}", file=sys.stderr)
                continue
            if not text.strip():
                continue
            entry: dict = {
                "source": rel,
                "title": title_from_kql(text, rel),
                "content": text.rstrip() + "\n",
            }
            skip_reason = skill_skip_reason(text)
            if skip_reason is not None:
                entry["skipped"] = skip_reason
                entry["content"] = ""
            results.append(entry)
        elif suffix in {".md", ".markdown"}:
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                print(f"warning: could not read {rel}: {e}", file=sys.stderr)
                continue
            for heading, content, idx in extract_kql_from_markdown(text):
                if not content.strip():
                    continue
                entry = {
                    "source": f"{rel}#{idx}",
                    "title": heading or f"{rel} (block {idx})",
                    "content": content.rstrip() + "\n",
                }
                skip_reason = skill_skip_reason(content)
                if skip_reason is not None:
                    entry["skipped"] = skip_reason
                    entry["content"] = ""
                results.append(entry)

    json.dump(results, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
