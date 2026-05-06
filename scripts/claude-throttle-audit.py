#!/usr/bin/env python3
"""Throttle / API-error audit for Claude Code transcripts.

Diagnostic tool — companion to claude-usage-report.py. Surfaces server-side
errors and feature gates from session transcripts, useful when investigating
why specific Claude Code requests failed during a given window.

Scans ~/.claude/projects/**/*.jsonl for API error events that Claude Code
logs into the session transcripts. Reports a per-month and per-status-code
timeline, with each event classified by category.

LIMITATION (important to understand before relying on the output):
  Claude Code does NOT log plan-level cap hits (weekly / 5-hour limits) into
  the session jsonl files. Those notifications appear in the UI / status bar
  only. The events this script CAN detect are:
    - server_per_second_throttle  (Anthropic API per-minute rate limit, 429)
    - extra_usage_required        (1M-context feature gate, 429)
    - anthropic_overload          (server-side fleet overload, 529)
    - server_error / service_unavailable  (5xx)
  For authoritative plan-cap counts, see the Anthropic Console usage page.

Usage:
  python scripts/claude-throttle-audit.py [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                                          [--user NAME] [--out-dir PATH]

Outputs:
  <user>-throttle-summary.md     human-readable per-month + per-category report
  <user>-throttle-aggregate.json structured totals (no transcript content)

Re-uses parse_iso_date / sanitize_user / derive_user from claude-usage-report.py
to avoid duplication.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path


SCHEMA_VERSION = 2


def _load_usage_module():
    """Load claude-usage-report.py for shared utilities (the hyphen blocks `import`)."""
    script_path = Path(__file__).parent / "claude-usage-report.py"
    spec = importlib.util.spec_from_file_location("claude_usage_report", script_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("claude_usage_report", module)
    spec.loader.exec_module(module)
    return module


_usage = _load_usage_module()
parse_iso_date = _usage.parse_iso_date
sanitize_user = _usage.sanitize_user
derive_user = _usage.derive_user


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    default_since = (date.today() - timedelta(days=60)).isoformat()
    default_until = date.today().isoformat()
    parser.add_argument("--since", default=default_since, type=parse_iso_date,
                        help="Window start (YYYY-MM-DD). Default: 60 days ago.")
    parser.add_argument("--until", default=default_until, type=parse_iso_date,
                        help="Window end (YYYY-MM-DD). Default: today.")
    parser.add_argument("--user", default=None,
                        help="Output filename prefix (default: $USER / $USERNAME, sanitized).")
    parser.add_argument("--out-dir", default=".",
                        help="Output directory (default: current dir). Recommended: outside the repo.")
    parser.add_argument("--projects-dir", default=None,
                        help="Override Claude Code transcripts directory (default: ~/.claude/projects).")
    return parser.parse_args()


def find_jsonl_files(projects_dir: Path) -> list[Path]:
    if not projects_dir.exists():
        return []
    return list(projects_dir.rglob("*.jsonl"))


def date_from_http_headers(headers: dict) -> str | None:
    """Convert HTTP `Date` header (RFC 7231 format) to ISO8601 string with Z suffix."""
    raw = headers.get("date")
    if not raw:
        return None
    try:
        dt = datetime.strptime(raw, "%a, %d %b %Y %H:%M:%S GMT")
        return dt.isoformat() + "Z"
    except ValueError:
        return None


def classify_event(status, text: str) -> str:
    """Map (status, message text) to an actionable category.

    Distinct from raw HTTP status because the same status (429) covers very
    different operational meanings — per-minute server throttling vs feature
    gate vs plan-cap. The text is the disambiguator.
    """
    text_lower = (text or "").lower()
    if "extra usage is required" in text_lower:
        return "extra_usage_required"
    if "server is temporarily limiting" in text_lower:
        return "server_per_second_throttle"
    if status == 529 or "overloaded" in text_lower:
        return "anthropic_overload"
    if status == 503:
        return "service_unavailable"
    if status == 500 or "internal server error" in text_lower:
        return "server_error"
    if status == 429:
        return "rate_limit_unspecified"
    if status is not None:
        return f"http_{status}"
    return "unclassified"


def _extract_text(message: dict) -> str:
    """Concatenate all text-type content blocks from an assistant message."""
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text") or "")
    return "".join(parts)


def extract_error_events(line: str) -> list[dict]:
    """Return zero or more error-event dicts from a single JSONL line.

    Recognized shapes (both can co-occur for the same underlying error):

    1. system-level structured error log:
       {"type":"system", "subtype":"api_error", "level":"error",
        "error":{"status":NNN, "headers":{...}}}

    2. assistant-message-level error attribute:
       {"type":"assistant", "isApiErrorMessage":true, "apiErrorStatus":NNN,
        "error":"rate_limit"|"server_error"|...,
        "message":{"content":[{"type":"text","text":"API Error: ..."}]}}

    Per the file-level docstring, this does NOT capture Claude Code plan-cap
    hits (weekly / 5-hour) — those go through UI notifications, not transcripts.
    """
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return []

    events: list[dict] = []

    # Shape 1: system-level api_error
    if obj.get("subtype") == "api_error":
        err = obj.get("error")
        if isinstance(err, dict):
            timestamp = obj.get("timestamp") or date_from_http_headers(err.get("headers") or {})
            status = err.get("status")
            events.append({
                "kind": "api_error_system",
                "status": status,
                "error_type": None,
                "category": classify_event(status, ""),
                "timestamp": timestamp,
                "model": (obj.get("message") or {}).get("model"),
            })

    # Shape 2: assistant-message-level error attribute
    if obj.get("isApiErrorMessage") is True:
        status = obj.get("apiErrorStatus")
        error_type = obj.get("error") if isinstance(obj.get("error"), str) else None
        text = _extract_text(obj.get("message") or {})
        events.append({
            "kind": "api_error_message",
            "status": status,
            "error_type": error_type,
            "category": classify_event(status, text),
            "timestamp": obj.get("timestamp"),
            # Synthetic recovery messages carry model="<synthetic>", not informative.
            "model": None,
        })

    return events


def in_window(timestamp: str | None, since_dt: datetime, until_dt: datetime) -> bool:
    """Test whether an event timestamp falls in [since, until) using naive UTC."""
    if not timestamp:
        return False
    try:
        ts = datetime.fromisoformat(timestamp.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return False
    return since_dt <= ts < until_dt


def summarize_events(events: list[dict], since: str, until: str) -> dict:
    by_month: dict[str, Counter] = defaultdict(Counter)
    by_status: Counter = Counter()
    by_kind: Counter = Counter()
    by_category: Counter = Counter()
    timeline: list[dict] = []

    for event in events:
        ts = event.get("timestamp") or ""
        month = ts[:7] if len(ts) >= 7 else "unknown"
        kind = event.get("kind", "unknown")
        category = event.get("category", "unclassified")
        status = event.get("status")

        by_month[month][category] += 1
        if status:
            by_status[status] += 1
        by_kind[kind] += 1
        by_category[category] += 1
        timeline.append({
            "timestamp": ts,
            "kind": kind,
            "status": status,
            "category": category,
            "error_type": event.get("error_type"),
            "model": event.get("model"),
        })

    timeline.sort(key=lambda x: x.get("timestamp") or "")

    return {
        "window": {"since": since, "until": until},
        "total_events": len(events),
        "by_kind": dict(by_kind),
        "by_status": {str(k): v for k, v in by_status.items()},
        "by_category": dict(by_category),
        "by_month": {month: dict(counts) for month, counts in sorted(by_month.items())},
        "timeline": timeline,
    }


CATEGORY_MEANING = {
    "server_per_second_throttle": "Anthropic API per-minute rate limit (transient, NOT plan cap)",
    "extra_usage_required": "Feature gate (e.g., 1M context requires extra usage on account)",
    "anthropic_overload": "Anthropic fleet overloaded (server-side, not your plan)",
    "server_error": "5xx server error (transient)",
    "service_unavailable": "503 service unavailable (transient)",
    "rate_limit_unspecified": "Status 429 with unrecognized message text",
    "unclassified": "No status code; synthetic recovery only",
}


def render_markdown(summary: dict, user: str) -> str:
    window = summary["window"]
    lines = [
        f"# Claude Code Throttle Audit - {user}",
        "",
        f"**Window:** {window['since']} to {window['until']} (UTC)",
        f"**Generated:** {summary.get('generated', date.today().isoformat())}",
        f"**Schema:** v{summary['schema_version']}",
        "",
        "> **LIMITATION:** This audit captures server-side errors, per-minute API",
        "> throttling, and feature gates from Claude Code's session transcripts.",
        "> It does NOT detect weekly or 5-hour plan-cap hits — those notifications",
        "> appear in the Claude Code UI without writing to the session log. For",
        "> authoritative plan-cap counts, see the Anthropic Console usage page.",
        "",
        "## Summary",
        "",
        f"- Total error events: **{summary['total_events']}**",
    ]

    if summary["total_events"] == 0:
        lines += [
            "",
            "_No API error events found in the window._",
            "",
        ]
        return "\n".join(lines) + "\n"

    if summary.get("by_category"):
        lines += [
            "",
            "### By category",
            "",
            "| Category | Count | Meaning |",
            "| --- | ---: | --- |",
        ]
        for category, count in sorted(summary["by_category"].items(), key=lambda kv: -kv[1]):
            meaning = CATEGORY_MEANING.get(category, "")
            lines.append(f"| `{category}` | {count} | {meaning} |")

    if summary.get("by_status"):
        lines += [
            "",
            "### By HTTP status",
            "",
            "| Status | Count |",
            "| ---: | ---: |",
        ]
        for status, count in sorted(summary["by_status"].items(), key=lambda kv: -kv[1]):
            lines.append(f"| {status} | {count} |")

    if summary.get("by_month"):
        lines += [
            "",
            "### By month",
            "",
            "| Month | Total | Breakdown |",
            "| --- | ---: | --- |",
        ]
        for month, counts in sorted(summary["by_month"].items()):
            total = sum(counts.values())
            breakdown = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
            lines.append(f"| {month} | {total} | {breakdown} |")

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    if args.until < args.since:
        sys.exit(f"error: --until ({args.until}) is before --since ({args.since}).")

    user = sanitize_user(args.user) if args.user else derive_user()
    out_dir = Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    projects_dir = (Path(args.projects_dir).expanduser() if args.projects_dir
                    else Path.home() / ".claude" / "projects")
    files = find_jsonl_files(projects_dir)
    print(f"Scanning {len(files)} jsonl files under {projects_dir}", file=sys.stderr)
    print("NOTE: this audit does NOT capture plan-cap hits (weekly / 5-hour). "
          "See the Anthropic Console for those.", file=sys.stderr)

    since_dt = datetime.strptime(args.since, "%Y-%m-%d")
    until_dt = datetime.strptime(args.until, "%Y-%m-%d") + timedelta(days=1)

    all_events: list[dict] = []
    for fp in files:
        try:
            with open(fp, "r", encoding="utf-8") as f:
                for line in f:
                    for event in extract_error_events(line):
                        if in_window(event.get("timestamp"), since_dt, until_dt):
                            all_events.append(event)
        except OSError:
            continue

    summary = summarize_events(all_events, args.since, args.until)
    summary["schema_version"] = SCHEMA_VERSION
    summary["user"] = user
    summary["generated"] = date.today().isoformat()

    md_path = out_dir / f"{user}-throttle-summary.md"
    json_path = out_dir / f"{user}-throttle-aggregate.json"
    md_path.write_text(render_markdown(summary, user), encoding="utf-8")
    json_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {md_path}")
    print(f"Wrote {json_path}")
    print(f"Total events: {summary['total_events']}")
    if summary.get("by_category"):
        for category, count in sorted(summary["by_category"].items(), key=lambda kv: -kv[1]):
            print(f"  {category}: {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
