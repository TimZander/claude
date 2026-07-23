#!/usr/bin/env python3
"""Measure how many tool calls the team allowlist auto-approves.

Scans Claude Code transcripts and, for every Bash / MCP tool call, decides
whether the *effective* allow rules would let it run WITHOUT a permission
prompt. Use it to size the impact of the allowlist and to watch it over time.

Caveat: transcripts do not record, per call, whether a prompt was actually
shown (that depended on the settings state at the time, plus any per-project
"don't ask again"). So this reports what the CURRENT rules WOULD auto-approve
over the scanned window — a forward-looking proxy, not a historical count.
Run it with --since <install-date> to count prompts avoided since you synced.

It also tallies hard rejection markers ("doesn't want to proceed" / "User
rejected") as ground-truth evidence that a prompt was shown and declined.

Usage:
  python measure-allowlist-impact.py [--settings PATH] [--projects DIR] [--since YYYY-MM-DD]

Defaults: --settings ~/.claude/settings.json (the synced, effective rules;
falls back to this repo's standards/settings.json), --projects ~/.claude/projects.
"""
from __future__ import annotations

import argparse
import json
import os
import re
from collections import Counter, defaultdict
from pathlib import Path

SEP = re.compile(r"&&|\|\||;|\|&|\||\n")
REJECTION_MARKERS = ("doesn't want to proceed", "User rejected")


def load_rules(settings_path: Path):
    data = json.loads(settings_path.read_text(encoding="utf-8"))
    allow = (data.get("permissions") or {}).get("allow", [])
    bash_prefixes, mcp_allow = [], set()
    for a in allow:
        if a.startswith("mcp__"):
            mcp_allow.add(a)
            continue
        m = re.match(r"^Bash\((.*?)\)$", a)
        if not m:
            continue
        inner = m.group(1)
        if inner.endswith(":*"):
            inner = inner[:-2]
        elif inner.endswith(" *"):
            inner = inner[:-2]
        bash_prefixes.append(inner.strip())
    return bash_prefixes, mcp_allow


def seg_matches(seg: str, prefixes) -> bool:
    seg = seg.strip()
    return any(seg == p or seg.startswith(p + " ") for p in prefixes)


def bash_covered(cmd: str, prefixes) -> bool:
    segs = [s for s in SEP.split(cmd) if s.strip()]
    return bool(segs) and all(seg_matches(s, prefixes) for s in segs)


def within_since(line: str, since: str | None) -> bool:
    if not since:
        return True
    # transcript lines carry an ISO "timestamp"; compare the date prefix
    m = re.search(r'"timestamp"\s*:\s*"(\d{4}-\d{2}-\d{2})', line)
    return (m.group(1) >= since) if m else True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings")
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--since", help="only count transcript lines on/after YYYY-MM-DD")
    args = ap.parse_args()

    if args.settings:
        settings_path = Path(args.settings)
    else:
        user = Path(os.path.expanduser("~/.claude/settings.json"))
        settings_path = user if user.exists() else Path(__file__).resolve().parent / "settings.json"
    print(f"# rules from: {settings_path}")
    if args.since:
        print(f"# window: on/after {args.since}")

    bash_prefixes, mcp_allow = load_rules(settings_path)
    covered = Counter()
    would_prompt = Counter()
    covered_sessions = defaultdict(set)
    rejections = 0

    for f in Path(args.projects).rglob("*.jsonl"):
        sid = f.name
        try:
            for line in f.open(encoding="utf-8", errors="replace"):
                if not within_since(line, args.since):
                    continue
                if any(mk in line for mk in REJECTION_MARKERS):
                    rejections += 1
                if '"tool_use"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                content = (obj.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for it in content:
                    if not (isinstance(it, dict) and it.get("type") == "tool_use"):
                        continue
                    name = it.get("name", "")
                    if name == "Bash":
                        cmd = (it.get("input") or {}).get("command", "")
                        if not isinstance(cmd, str) or not cmd.strip():
                            continue
                        key = " ".join(cmd.strip().split()[:3])
                        if bash_covered(cmd, bash_prefixes):
                            covered[key] += 1
                            covered_sessions[key].add(sid)
                        else:
                            would_prompt["Bash: " + key] += 1
                    elif name.startswith("mcp__"):
                        if name in mcp_allow:
                            covered[name] += 1
                            covered_sessions[name].add(sid)
                        else:
                            would_prompt[name] += 1
        except OSError:
            continue

    tot_cov = sum(covered.values())
    tot_prompt = sum(would_prompt.values())
    print(f"\n=== IMPACT ===")
    print(f"tool calls AUTO-APPROVED by the allowlist (no prompt): {tot_cov}")
    print(f"tool calls that would STILL prompt:                    {tot_prompt}")
    print(f"hard rejection markers in window (prompt shown+declined): {rejections}")

    print(f"\n-- top auto-approved (calls / distinct sessions) --")
    for k, c in covered.most_common(20):
        label = k.replace("mcp__azure-devops__", "ado:").replace("mcp__", "")
        print(f"  {c:5d} / {len(covered_sessions[k]):3d}s  {label}")

    print(f"\n-- top still-prompting (candidates for a future pass) --")
    for k, c in would_prompt.most_common(20):
        print(f"  {c:5d}  {k.replace('mcp__azure-devops__', 'ado:').replace('mcp__', '')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
