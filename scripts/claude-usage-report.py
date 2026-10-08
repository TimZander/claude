#!/usr/bin/env python3
"""Claude Code usage summary, wrapping ccusage.

Produces a per-seat baseline suitable for team-subscription cost analysis.
Walks ~/.claude/projects/**/*.jsonl via ccusage and emits two files:

  <user>-summary.md      one-page markdown report (per-day + per-block stats)
  <user>-aggregate.json  mailable totals (no transcript content, no project names)

Usage:
  python scripts/claude-usage-report.py [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                                        [--user NAME] [--out-dir PATH]
                                        [--ccusage 'CMD ARGS']

Defaults:
  --since   60 days ago
  --until   today
  --user    derived from $USER / $USERNAME (sanitized to [a-z0-9_-])
  --out-dir current directory (recommend a path outside the repo)
  --ccusage 'ccusage' if on PATH, else 'npx -y ccusage@latest'

All ccusage calls use --timezone UTC and --mode calculate so cross-seat
aggregates are comparable regardless of where the developer ran the script.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import date, datetime, timedelta
from pathlib import Path


SCHEMA_VERSION = 2
COST_MODE = "calculate"
TIMEZONE = "UTC"
SAFE_USER_RE = re.compile(r"[^a-z0-9_-]")


def parse_iso_date(value: str) -> str:
    """argparse `type=` callable: validate YYYY-MM-DD and return the original string."""
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"invalid date {value!r}: expected YYYY-MM-DD"
        )
    return value


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
                        help=("Output directory (default: current dir). Recommended: a path "
                              "outside the repo working tree (e.g., ~/claude-usage)."))
    parser.add_argument("--ccusage", default=None,
                        help=("Override ccusage command. Default: 'ccusage' if on PATH, "
                              "else 'npx -y ccusage@latest'. Pass extra args via quotes, "
                              "e.g. --ccusage 'ccusage --no-offline'."))
    return parser.parse_args()


def to_yyyymmdd(iso: str) -> str:
    return datetime.strptime(iso, "%Y-%m-%d").strftime("%Y%m%d")


def sanitize_user(value: str) -> str:
    """Reduce a username to filesystem-safe characters [a-z0-9_-].

    Used both for env-derived names ($USER / $USERNAME) and explicit --user.
    Path separators, dots, and other unsafe characters are replaced with `_`.
    Falls back to "user" if the result is empty.
    """
    cleaned = SAFE_USER_RE.sub("_", value.strip().lower().replace(" ", "_"))
    cleaned = cleaned.strip("_")
    return cleaned or "user"


def derive_user() -> str:
    for var in ("USER", "USERNAME"):
        value = os.environ.get(var)
        if value:
            return sanitize_user(value)
    return "user"


def resolve_ccusage(override: str | None) -> list[str]:
    if override is not None:
        parts = override.split()
        if not parts:
            sys.exit("error: --ccusage cannot be empty or whitespace-only")
        # Resolve the first token via shutil.which so Windows .cmd shims work.
        resolved = shutil.which(parts[0])
        if resolved:
            parts[0] = resolved
        return parts
    ccusage_path = shutil.which("ccusage")
    if ccusage_path:
        return [ccusage_path]
    npx_path = shutil.which("npx")
    if npx_path:
        return [npx_path, "-y", "ccusage@latest"]
    sys.exit("error: neither 'ccusage' nor 'npx' on PATH. "
             "Install Node.js then run: npm install -g ccusage")


def run_ccusage(cmd: list[str], subcommand: str, extra: list[str]) -> dict:
    args = cmd + [subcommand, "--json"] + extra
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, check=False, timeout=900,
        )
    except FileNotFoundError as exc:
        sys.exit(f"error: could not run ccusage ({exc}). "
                 "Install with: npm install -g ccusage")
    except subprocess.TimeoutExpired:
        sys.exit("error: ccusage timed out after 15 minutes. "
                 "Try narrowing the window with --since.")
    if result.returncode != 0:
        sys.exit(f"error: ccusage exited {result.returncode}\n"
                 f"command: {' '.join(args)}\n"
                 f"stderr: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        sys.exit(f"error: ccusage produced invalid JSON: {exc}\n"
                 f"first 200 chars: {result.stdout[:200]!r}")


def get_ccusage_version(cmd: list[str]) -> str:
    """Best-effort capture of the ccusage version string for the audit trail."""
    try:
        result = subprocess.run(
            cmd + ["--version"], capture_output=True, text=True,
            timeout=120, check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return "unknown"


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    sorted_values = sorted(values)
    k = (len(sorted_values) - 1) * pct / 100.0
    floor_index = int(k)
    ceil_index = min(floor_index + 1, len(sorted_values) - 1)
    fraction = k - floor_index
    return sorted_values[floor_index] + (sorted_values[ceil_index] - sorted_values[floor_index]) * fraction


def bucketize(costs: list[float]) -> dict[str, int]:
    edges = [0, 1, 5, 10, 25, 50, 100, 200, 500, float("inf")]
    labels = ["<$1", "$1-5", "$5-10", "$10-25", "$25-50",
              "$50-100", "$100-200", "$200-500", "$500+"]
    counts = [0] * len(labels)
    for cost in costs:
        # Negative costs aren't expected from ccusage; clamp to 0 so the bucket
        # totals always sum to len(costs) instead of silently dropping inputs.
        clamped = max(cost, 0.0)
        for i in range(len(edges) - 1):
            if edges[i] <= clamped < edges[i + 1]:
                counts[i] += 1
                break
    return dict(zip(labels, counts))


def summarize_daily(daily_data: dict, since: str, until: str) -> dict:
    daily = daily_data.get("daily") or []
    totals = daily_data.get("totals") or {}

    # `or 0.0` guards against `{"totalCost": null}` — `dict.get(k, default)`
    # returns the explicit None, not the default, when the key exists.
    daily_costs = [(d.get("totalCost") or 0.0) for d in daily]
    window_days = (datetime.strptime(until, "%Y-%m-%d")
                   - datetime.strptime(since, "%Y-%m-%d")).days + 1
    active_days = sum(1 for c in daily_costs if c > 0)
    reported_total = totals.get("totalCost")
    total_cost = sum(daily_costs) if reported_total is None else reported_total
    avg_daily = total_cost / window_days if window_days > 0 else 0.0
    p95_daily = percentile(daily_costs, 95)
    monthly_projection = avg_daily * 30

    model_totals: dict[str, float] = {}
    for entry in daily:
        for breakdown in entry.get("modelBreakdowns") or []:
            name = breakdown.get("modelName") or "unknown"
            cost = breakdown.get("cost") or 0.0
            model_totals[name] = model_totals.get(name, 0.0) + cost

    return {
        "window": {"since": since, "until": until, "days": window_days},
        "active_days": active_days,
        "totals": {
            "cost_usd": round(total_cost, 2),
            "input_tokens": totals.get("inputTokens") or 0,
            "output_tokens": totals.get("outputTokens") or 0,
            "cache_creation_tokens": totals.get("cacheCreationTokens") or 0,
            "cache_read_tokens": totals.get("cacheReadTokens") or 0,
        },
        "daily_stats": {
            "min": round(min(daily_costs, default=0.0), 2),
            "avg": round(avg_daily, 2),
            "p95": round(p95_daily, 2),
            "max": round(max(daily_costs, default=0.0), 2),
        },
        "monthly_projection_usd": round(monthly_projection, 2),
        "per_model_cost_usd": {
            k: round(v, 2)
            for k, v in sorted(model_totals.items(), key=lambda kv: -kv[1])
        },
        "daily_timeline": [
            {"date": d.get("date"), "cost_usd": round((d.get("totalCost") or 0.0), 2)}
            for d in daily
        ],
    }


def summarize_blocks(blocks_data: dict) -> dict:
    """Aggregate block stats. Window filtering is performed by ccusage itself
    via --since/--until/--timezone; this function only consumes pre-filtered
    data and skips gap blocks."""
    blocks = [b for b in (blocks_data.get("blocks") or [])
              if not b.get("isGap", False)]
    costs = [(b.get("costUSD") or 0.0) for b in blocks]
    if not costs:
        return {
            "total_blocks": 0,
            "buckets": bucketize([]),
            "percentiles_usd": {"p50": 0.0, "p75": 0.0, "p90": 0.0, "p95": 0.0, "p99": 0.0},
            "max_block_usd": 0.0,
            "mean_block_usd": 0.0,
        }
    return {
        "total_blocks": len(blocks),
        "buckets": bucketize(costs),
        "percentiles_usd": {
            "p50": round(percentile(costs, 50), 2),
            "p75": round(percentile(costs, 75), 2),
            "p90": round(percentile(costs, 90), 2),
            "p95": round(percentile(costs, 95), 2),
            "p99": round(percentile(costs, 99), 2),
        },
        "max_block_usd": round(max(costs), 2),
        "mean_block_usd": round(sum(costs) / len(costs), 2),
    }


def render_markdown(summary: dict, user: str) -> str:
    window = summary["window"]
    totals = summary["totals"]
    stats = summary["daily_stats"]
    blocks = summary.get("block_stats", {})

    lines = [
        f"# Claude Code Usage Report - {user}",
        "",
        f"**Window:** {window['since']} to {window['until']} "
        f"({window['days']} days, {summary.get('timezone', TIMEZONE)})",
        f"**Generated:** {summary.get('generated', date.today().isoformat())}",
        f"**Schema:** v{summary['schema_version']}",
        f"**ccusage:** {summary.get('ccusage_version', 'unknown')} "
        f"(mode: {summary.get('cost_mode', COST_MODE)})",
        "",
        "## Summary",
        "",
        f"- Total spend (API-rate equivalent): **${totals['cost_usd']:,.2f}**",
        f"- Active days: {summary['active_days']} of {window['days']}",
        f"- Daily spend - avg: ${stats['avg']:,.2f}, p95: ${stats['p95']:,.2f}, max: ${stats['max']:,.2f}",
        f"- Monthly projection (avg x 30): **${summary['monthly_projection_usd']:,.2f}**",
        "",
        "## Per-model split",
        "",
        "| Model | Cost | Share |",
        "| --- | ---: | ---: |",
    ]
    total = totals["cost_usd"] or 1.0
    for model, cost in summary["per_model_cost_usd"].items():
        share = (cost / total) * 100
        lines.append(f"| `{model}` | ${cost:,.2f} | {share:.1f}% |")

    lines += [
        "",
        "## Token totals",
        "",
        f"- Input: {totals['input_tokens']:,}",
        f"- Output: {totals['output_tokens']:,}",
        f"- Cache write: {totals['cache_creation_tokens']:,}",
        f"- Cache read: {totals['cache_read_tokens']:,}",
        "",
    ]

    if blocks.get("total_blocks", 0) > 0:
        percentiles = blocks["percentiles_usd"]
        lines += [
            "## 5-hour block distribution",
            "",
            f"- Total non-gap blocks: {blocks['total_blocks']}",
            f"- Mean block cost: ${blocks['mean_block_usd']:,.2f}",
            f"- Percentiles - p50: ${percentiles['p50']:,.2f}, p75: ${percentiles['p75']:,.2f}, "
            f"p90: ${percentiles['p90']:,.2f}, p95: ${percentiles['p95']:,.2f}, p99: ${percentiles['p99']:,.2f}",
            f"- Max block cost: ${blocks['max_block_usd']:,.2f}",
            "",
            "| Bucket | Blocks |",
            "| --- | ---: |",
        ]
        for bucket, count in blocks["buckets"].items():
            lines.append(f"| {bucket} | {count} |")
        lines.append("")

    lines += [
        "## Daily timeline",
        "",
        "| Date | Cost |",
        "| --- | ---: |",
    ]
    for entry in summary["daily_timeline"]:
        lines.append(f"| {entry['date']} | ${entry['cost_usd']:,.2f} |")

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()

    # Fail fast on inverted windows. argparse already validated the format.
    if args.until < args.since:
        sys.exit(f"error: --until ({args.until}) is before --since ({args.since}).")

    user = sanitize_user(args.user) if args.user else derive_user()
    out_dir = Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = resolve_ccusage(args.ccusage)
    since_yyyymmdd = to_yyyymmdd(args.since)
    until_yyyymmdd = to_yyyymmdd(args.until)
    print(f"Running ccusage as: {' '.join(cmd)}", file=sys.stderr)
    print(f"Window: {args.since} to {args.until} ({TIMEZONE})", file=sys.stderr)

    common_extra = ["--since", since_yyyymmdd, "--until", until_yyyymmdd,
                    "--mode", COST_MODE, "--timezone", TIMEZONE]
    daily_data = run_ccusage(cmd, "daily", common_extra + ["--breakdown"])
    blocks_data = run_ccusage(cmd, "blocks", common_extra)
    ccusage_version = get_ccusage_version(cmd)

    summary = summarize_daily(daily_data, args.since, args.until)
    summary["block_stats"] = summarize_blocks(blocks_data)
    summary["schema_version"] = SCHEMA_VERSION
    summary["user"] = user
    summary["generated"] = date.today().isoformat()
    summary["ccusage_version"] = ccusage_version
    summary["cost_mode"] = COST_MODE
    summary["timezone"] = TIMEZONE

    md_path = out_dir / f"{user}-summary.md"
    json_path = out_dir / f"{user}-aggregate.json"
    md_path.write_text(render_markdown(summary, user), encoding="utf-8")
    json_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {md_path}")
    print(f"Wrote {json_path}")
    print(f"Total: ${summary['totals']['cost_usd']:,.2f} over {summary['window']['days']} "
          f"days (monthly projection: ${summary['monthly_projection_usd']:,.2f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
