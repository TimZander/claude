#!/usr/bin/env python3
"""Discover KQL queries in a repo.

Looks in two places:
  1. `*.kql` files (recursive, skipping common vendored/build dirs).
  2. Fenced ```kql blocks inside `*.md` files.

Emits a JSON array on stdout:
  [{"source": "...", "title": "...", "content": "..."}, ...]

`source` is a display-friendly relative path (with an optional `#N` suffix for
the Nth fenced block in a markdown file). `title` is a best-effort single-line
guess: the first `// ...` comment in a .kql file, or the nearest preceding
markdown heading for a fenced block, falling back to the source path.

Usage:
  discover_queries.py [--cwd <path>] [--include <glob>]... [--exclude <glob>]...

  --include defaults to every `*.kql` and `*.md` under --cwd.
  --exclude is applied on top of the default skip list (.git, node_modules, etc.).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
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


def iter_files(root: Path, excludes: list[str]):
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        parts = set(path.relative_to(root).parts)
        if parts & DEFAULT_SKIP_DIRS:
            continue
        rel = str(path.relative_to(root))
        if any(fnmatch.fnmatch(rel, pat) for pat in excludes):
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
                        help="Extra glob(s) to scan (default: **/*.kql and **/*.md)")
    parser.add_argument("--exclude", action="append", default=[],
                        help="Globs to exclude (on top of the built-in skip dirs)")
    args = parser.parse_args(argv)

    root = Path(args.cwd).resolve()
    if not root.is_dir():
        print(f"error: --cwd is not a directory: {root}", file=sys.stderr)
        return 2

    results: list[dict] = []

    for path in iter_files(root, args.exclude):
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
            results.append({
                "source": rel,
                "title": title_from_kql(text, rel),
                "content": text.rstrip() + "\n",
            })
        elif suffix in {".md", ".markdown"}:
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                print(f"warning: could not read {rel}: {e}", file=sys.stderr)
                continue
            for heading, content, idx in extract_kql_from_markdown(text):
                if not content.strip():
                    continue
                results.append({
                    "source": f"{rel}#{idx}",
                    "title": heading or f"{rel} (block {idx})",
                    "content": content.rstrip() + "\n",
                })

    json.dump(results, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
