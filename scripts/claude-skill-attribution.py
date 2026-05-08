#!/usr/bin/env python3
"""Claude Code per-skill / per-agent cost attribution.

Reads ~/.claude/projects/**/*.jsonl directly (does NOT wrap ccusage), groups
assistant turns by the active skill and main-vs-sidechain context, and applies
per-model pricing locally. Reconciles total spend against ccusage at the end so
drift in hardcoded rates is visible.

Outputs:
  <user>-attribution.md      ranked tables + top-N expensive turns
  <user>-attribution.json    raw aggregates (no transcript text)

Skill attribution model:
  Main-thread turns: a skill is active from the assistant turn that emits a
  Skill tool_use through the next user message. Nested invocations replace the
  active skill (innermost wins).

  Subagent turns: read directly from the `attributionSkill` and
  `attributionAgent` fields the harness already records on agent-*.jsonl turns.

Usage:
  python scripts/claude-skill-attribution.py [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                                             [--user NAME] [--out-dir PATH]
                                             [--top N] [--ccusage 'CMD ARGS']
                                             [--no-reconcile]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

SCHEMA_VERSION = 2  # v2 added skill_efficiency (per-invocation context bloat metrics)
SAFE_USER_RE = re.compile(r"[^a-z0-9_-]")
DEFAULT_TOP_N = 20
# ccusage doesn't read agent-*.jsonl files, so our totals run modestly higher
# than ccusage's by the subagent share. Empirically ~5-15% on heavy-subagent
# usage. Beyond this threshold something else is wrong (stale rates, new model
# tier, etc.) and the user should investigate.
RECONCILE_WARN_PCT = 20.0

# Per-1M-token rates in USD, sourced from LiteLLM's model_prices_and_context_window.json
# (the same dataset ccusage uses). Last verified 2026-05-07. The reconcile step against
# ccusage surfaces drift if Anthropic changes pricing or new models appear.
#
# Note: Opus 4 / 4.1 stayed at $15 input / $75 output, but Opus 4.5+ dropped to
# $5 input / $25 output. Treating them all the same was a 3x overcount.
#
# Keys are CANONICAL model names (date suffixes stripped — see canonicalize_model).
PRICES: dict[str, dict[str, float]] = {
    # Opus 4.5+ tier
    "claude-opus-4-7": {
        "input": 5.0, "output": 25.0,
        "cache_5m": 6.25, "cache_1h": 10.0, "cache_read": 0.50,
    },
    "claude-opus-4-6": {
        "input": 5.0, "output": 25.0,
        "cache_5m": 6.25, "cache_1h": 10.0, "cache_read": 0.50,
    },
    "claude-opus-4-5": {
        "input": 5.0, "output": 25.0,
        "cache_5m": 6.25, "cache_1h": 10.0, "cache_read": 0.50,
    },
    # Older Opus 4.x tier
    "claude-opus-4-1": {
        "input": 15.0, "output": 75.0,
        "cache_5m": 18.75, "cache_1h": 30.0, "cache_read": 1.50,
    },
    "claude-opus-4": {
        "input": 15.0, "output": 75.0,
        "cache_5m": 18.75, "cache_1h": 30.0, "cache_read": 1.50,
    },
    # Sonnet 4.x tier (5/6 share rates)
    "claude-sonnet-4-6": {
        "input": 3.0, "output": 15.0,
        "cache_5m": 3.75, "cache_1h": 6.0, "cache_read": 0.30,
    },
    "claude-sonnet-4-5": {
        "input": 3.0, "output": 15.0,
        "cache_5m": 3.75, "cache_1h": 6.0, "cache_read": 0.30,
    },
    "claude-sonnet-4": {
        "input": 3.0, "output": 15.0,
        "cache_5m": 3.75, "cache_1h": 6.0, "cache_read": 0.30,
    },
    # Haiku 4.5
    "claude-haiku-4-5": {
        "input": 1.0, "output": 5.0,
        "cache_5m": 1.25, "cache_1h": 2.0, "cache_read": 0.10,
    },
}

DATE_SUFFIX_RE = re.compile(r"-\d{8}$")


def canonicalize_model(model: str) -> str:
    """Strip trailing -YYYYMMDD date suffix that some model IDs carry.

    e.g. claude-haiku-4-5-20251001 → claude-haiku-4-5.
    Returns the input unchanged if no suffix matches; unknown models are
    surfaced as-is so the unknown-model warning fires later.
    """
    return DATE_SUFFIX_RE.sub("", model or "")


def parse_iso_date(value: str) -> str:
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
                        help="Window start (YYYY-MM-DD, UTC). Default: 60 days ago.")
    parser.add_argument("--until", default=default_until, type=parse_iso_date,
                        help="Window end (YYYY-MM-DD, UTC). Default: today.")
    parser.add_argument("--user", default=None,
                        help="Output filename prefix (default: $USER / $USERNAME, sanitized).")
    parser.add_argument("--out-dir", default=".", help="Output directory.")
    parser.add_argument("--top", default=DEFAULT_TOP_N, type=int,
                        help=f"Top-N most expensive turns to list. Default: {DEFAULT_TOP_N}.")
    parser.add_argument("--projects-dir", default=None,
                        help="Override transcripts root (default: ~/.claude/projects).")
    parser.add_argument("--ccusage", default=None,
                        help="Override ccusage command for the reconcile step.")
    parser.add_argument("--no-reconcile", action="store_true",
                        help="Skip the ccusage reconcile cross-check.")
    return parser.parse_args()


def sanitize_user(value: str) -> str:
    cleaned = SAFE_USER_RE.sub("_", value.strip().lower().replace(" ", "_"))
    cleaned = cleaned.strip("_")
    return cleaned or "user"


def derive_user() -> str:
    for var in ("USER", "USERNAME"):
        value = os.environ.get(var)
        if value:
            return sanitize_user(value)
    return "user"


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


def turn_cost_usd(model_canon: str, usage: dict, unknown_models: set[str]) -> float:
    """Compute per-turn cost using the cache-aware token breakdown.

    Returns 0.0 for unknown models and records them so the report surfaces
    pricing gaps. ccusage's reconcile step is the safety net.
    """
    if model_canon not in PRICES:
        unknown_models.add(model_canon)
        return 0.0
    p = PRICES[model_canon]
    cache_creation = usage.get("cache_creation") or {}
    ephem_5m = cache_creation.get("ephemeral_5m_input_tokens") or 0
    ephem_1h = cache_creation.get("ephemeral_1h_input_tokens") or 0
    # cacheCreationInputTokens is the total of 5m + 1h. If the breakdown is
    # missing (older transcripts), bill the whole thing at the 5m rate — this
    # is what ccusage does and what older Anthropic API responses imply.
    total_creation = usage.get("cache_creation_input_tokens") or 0
    if not (ephem_5m or ephem_1h) and total_creation:
        ephem_5m = total_creation
    input_t = usage.get("input_tokens") or 0
    cache_read = usage.get("cache_read_input_tokens") or 0
    output_t = usage.get("output_tokens") or 0
    return (
        input_t * p["input"]
        + output_t * p["output"]
        + ephem_5m * p["cache_5m"]
        + ephem_1h * p["cache_1h"]
        + cache_read * p["cache_read"]
    ) / 1_000_000


def context_size(usage: dict) -> int:
    """Total tokens-in-prompt for this turn (input side only — excludes output).

    This is what fills the context window; useful for spotting skills that
    bloat prompts.
    """
    return ((usage.get("input_tokens") or 0)
            + (usage.get("cache_read_input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0))


def in_window(timestamp: str, since: str, until: str) -> bool:
    """until is inclusive: the whole calendar day in UTC."""
    if not timestamp:
        return False
    # ISO timestamps end in 'Z'; date prefix is YYYY-MM-DD.
    day = timestamp[:10]
    return since <= day <= until


def is_real_user_turn(entry: dict) -> bool:
    """A user turn that resets the skill window (not a tool_result, not meta).

    Tool results come back as user-role messages too, but they don't end the
    skill — only a true user prompt does.
    """
    if entry.get("type") != "user" or entry.get("isMeta"):
        return False
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        # If every block is a tool_result, this is a tool turn, not user input.
        if all((c.get("type") == "tool_result") for c in content if isinstance(c, dict)):
            return False
    return True


def extract_tool_uses(entry: dict) -> list[dict]:
    msg = entry.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return []
    return [c for c in content if isinstance(c, dict) and c.get("type") == "tool_use"]


def walk_main_session(path: Path, since: str, until: str,
                      unknown_models: set[str]) -> list[dict]:
    """Walk a main-session JSONL, attributing each assistant turn to a skill
    via the windowing rule (Skill invocation → next user message)."""
    records: list[dict] = []
    active_skill: str | None = None
    try:
        with path.open("r", encoding="utf-8") as fp:
            for line in fp:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = entry.get("type")
                if etype == "user" and is_real_user_turn(entry):
                    active_skill = None
                    continue
                if etype != "assistant":
                    continue
                # Update the active skill BEFORE emitting the record so the
                # turn that invoked the skill is attributed to that skill.
                for tu in extract_tool_uses(entry):
                    if tu.get("name") == "Skill":
                        skill = (tu.get("input") or {}).get("skill")
                        if skill:
                            active_skill = skill
                if not in_window(entry.get("timestamp", ""), since, until):
                    continue
                msg = entry.get("message") or {}
                usage = msg.get("usage") or {}
                model_canon = canonicalize_model(msg.get("model") or "")
                cost = turn_cost_usd(model_canon, usage, unknown_models)
                records.append({
                    "timestamp": entry.get("timestamp"),
                    "model": model_canon,
                    "is_sidechain": False,
                    "skill": active_skill,
                    "agent_type": None,
                    "session_id": entry.get("sessionId"),
                    "git_branch": entry.get("gitBranch"),
                    "message_id": msg.get("id"),
                    "request_id": entry.get("requestId"),
                    "context_tokens": context_size(usage),
                    "output_tokens": usage.get("output_tokens") or 0,
                    "cost_usd": cost,
                })
    except OSError:
        pass
    return records


def walk_subagent_file(path: Path, since: str, until: str,
                       unknown_models: set[str]) -> list[dict]:
    """Walk an agent-*.jsonl, using the harness-provided attribution fields."""
    records: list[dict] = []
    try:
        with path.open("r", encoding="utf-8") as fp:
            for line in fp:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") != "assistant":
                    continue
                if not in_window(entry.get("timestamp", ""), since, until):
                    continue
                msg = entry.get("message") or {}
                usage = msg.get("usage") or {}
                model_canon = canonicalize_model(msg.get("model") or "")
                cost = turn_cost_usd(model_canon, usage, unknown_models)
                records.append({
                    "timestamp": entry.get("timestamp"),
                    "model": model_canon,
                    "is_sidechain": True,
                    "skill": entry.get("attributionSkill"),
                    "agent_type": entry.get("attributionAgent"),
                    "session_id": entry.get("sessionId"),
                    "git_branch": entry.get("gitBranch"),
                    "message_id": msg.get("id"),
                    "request_id": entry.get("requestId"),
                    "context_tokens": context_size(usage),
                    "output_tokens": usage.get("output_tokens") or 0,
                    "cost_usd": cost,
                })
    except OSError:
        pass
    return records


def cache_read_rate(model_canon: str) -> float:
    """USD per token for cache_read at this model's rate, 0 if unknown."""
    if model_canon not in PRICES:
        return 0.0
    return PRICES[model_canon]["cache_read"] / 1_000_000


def walk_main_session_invocations(path: Path, since: str, until: str,
                                  unknown_models: set[str]) -> list[dict]:
    """Emit one record per main-thread Skill invocation.

    Captures the context size at the moment the skill was invoked (everything
    the skill had to inherit) and the cost of the entire skill window. Lets us
    flag skills that are repeatedly invoked deep into bloated sessions.

    Subagents start fresh, so they're not the question — only main-session
    JSONLs feed this walker.
    """
    records: list[dict] = []
    active: dict | None = None  # in-flight invocation accumulator

    def close(active_state: dict | None) -> None:
        if active_state is None:
            return
        records.append(active_state)

    try:
        with path.open("r", encoding="utf-8") as fp:
            for line in fp:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = entry.get("type")
                if etype == "user" and is_real_user_turn(entry):
                    close(active)
                    active = None
                    continue
                if etype != "assistant":
                    continue
                msg = entry.get("message") or {}
                usage = msg.get("usage") or {}
                model_canon = canonicalize_model(msg.get("model") or "")
                # When a Skill tool_use appears, close any prior window and open a new one.
                # The invocation turn itself is included in the new window.
                for tu in extract_tool_uses(entry):
                    if tu.get("name") == "Skill":
                        skill = (tu.get("input") or {}).get("skill")
                        if skill:
                            close(active)
                            if not in_window(entry.get("timestamp", ""), since, until):
                                active = None
                                continue
                            active = {
                                "skill": skill,
                                "timestamp": entry.get("timestamp"),
                                "session_id": entry.get("sessionId"),
                                "git_branch": entry.get("gitBranch"),
                                "model_at_invoke": model_canon,
                                "ctx_at_invoke": context_size(usage),
                                "n_turns": 0,
                                "window_cost_usd": 0.0,
                                "wasted_cache_read_lb_usd": 0.0,
                            }
                if active is not None:
                    active["n_turns"] += 1
                    active["window_cost_usd"] += turn_cost_usd(model_canon, usage, unknown_models)
                    # Floor: every turn re-reads at least the inherited context.
                    active["wasted_cache_read_lb_usd"] += (
                        active["ctx_at_invoke"] * cache_read_rate(model_canon))
            close(active)
    except OSError:
        pass
    return records


def collect_invocations(projects_dir: Path, since: str, until: str,
                        unknown_models: set[str]) -> list[dict]:
    """Walk every main-session JSONL and collect Skill invocation records."""
    invocations: list[dict] = []
    for jsonl in projects_dir.rglob("*.jsonl"):
        if jsonl.name.startswith("agent-"):
            continue
        invocations.extend(
            walk_main_session_invocations(jsonl, since, until, unknown_models))
    return invocations


def aggregate_skill_efficiency(invocations: list[dict]) -> list[dict]:
    """Per-skill: how often is it invoked into a bloated context, and what does
    that cost. Sorted by total wasted-spend descending so the worst offenders
    surface first."""
    by_skill: dict[str, list[dict]] = defaultdict(list)
    for inv in invocations:
        by_skill[inv["skill"]].append(inv)
    rows = []
    for skill, items in by_skill.items():
        n = len(items)
        total_cost = sum(i["window_cost_usd"] for i in items)
        total_wasted = sum(i["wasted_cache_read_lb_usd"] for i in items)
        rows.append({
            "skill": skill,
            "invocations": n,
            "mean_ctx_at_invoke": round(sum(i["ctx_at_invoke"] for i in items) / n),
            "p95_ctx_at_invoke": round(percentile(
                [i["ctx_at_invoke"] for i in items], 95)),
            "max_ctx_at_invoke": max(i["ctx_at_invoke"] for i in items),
            "mean_turns_per_invocation": round(
                sum(i["n_turns"] for i in items) / n, 1),
            "total_window_cost_usd": round(total_cost, 2),
            "wasted_cache_read_lb_usd": round(total_wasted, 2),
            "wasted_pct": round((total_wasted / total_cost) * 100, 1) if total_cost else 0.0,
        })
    rows.sort(key=lambda r: -r["wasted_cache_read_lb_usd"])
    return rows


def collect_all(projects_dir: Path, since: str, until: str,
                unknown_models: set[str]) -> list[dict]:
    """Walk every JSONL under projects_dir, classifying main vs subagent by name.

    Deduplicates by (message_id, request_id). The same message often appears in
    multiple project dirs (e.g., when a session spans worktrees), and ccusage
    applies the same dedup rule — without it our totals come in ~2x too high.
    """
    raw: list[dict] = []
    for jsonl in projects_dir.rglob("*.jsonl"):
        if jsonl.name.startswith("agent-"):
            raw.extend(walk_subagent_file(jsonl, since, until, unknown_models))
        else:
            raw.extend(walk_main_session(jsonl, since, until, unknown_models))
    seen: set = set()
    deduped: list[dict] = []
    for r in raw:
        key = (r.get("message_id"), r.get("request_id"))
        # Records without IDs (defensive: shouldn't happen for assistant turns)
        # pass through unchecked rather than collapsing to a single entry.
        if key != (None, None) and key in seen:
            continue
        seen.add(key)
        deduped.append(r)
    return deduped


def aggregate_per_skill(records: list[dict]) -> list[dict]:
    """Group by skill name. Unattributed turns bucket as '(no skill)'."""
    by_skill: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        key = r["skill"] or "(no skill)"
        by_skill[key].append(r)
    rows = []
    for skill, turns in by_skill.items():
        costs = [t["cost_usd"] for t in turns]
        ctx = [t["context_tokens"] for t in turns]
        model_costs: dict[str, float] = defaultdict(float)
        for t in turns:
            model_costs[t["model"]] += t["cost_usd"]
        total_cost = sum(costs)
        model_share = {
            m: round((c / total_cost) * 100, 1) if total_cost else 0.0
            for m, c in sorted(model_costs.items(), key=lambda kv: -kv[1])
        }
        rows.append({
            "skill": skill,
            "total_cost_usd": round(total_cost, 2),
            "turn_count": len(turns),
            "sidechain_turn_count": sum(1 for t in turns if t["is_sidechain"]),
            "mean_context_tokens": round(sum(ctx) / len(ctx)) if ctx else 0,
            "p95_context_tokens": round(percentile(ctx, 95)),
            "max_context_tokens": max(ctx) if ctx else 0,
            "model_share_pct": model_share,
        })
    rows.sort(key=lambda r: -r["total_cost_usd"])
    return rows


def aggregate_per_agent_type(records: list[dict]) -> list[dict]:
    """Sidechain-only breakdown by attributionAgent."""
    by_agent: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        if not r["is_sidechain"]:
            continue
        by_agent[r["agent_type"] or "(unknown)"].append(r)
    rows = []
    for agent, turns in by_agent.items():
        costs = [t["cost_usd"] for t in turns]
        rows.append({
            "agent_type": agent,
            "total_cost_usd": round(sum(costs), 2),
            "turn_count": len(turns),
            "mean_cost_per_turn_usd": round(sum(costs) / len(costs), 4) if costs else 0.0,
        })
    rows.sort(key=lambda r: -r["total_cost_usd"])
    return rows


def main_vs_sidechain(records: list[dict]) -> dict:
    main_cost = sum(r["cost_usd"] for r in records if not r["is_sidechain"])
    side_cost = sum(r["cost_usd"] for r in records if r["is_sidechain"])
    total = main_cost + side_cost
    return {
        "main_thread_cost_usd": round(main_cost, 2),
        "sidechain_cost_usd": round(side_cost, 2),
        "main_thread_pct": round((main_cost / total) * 100, 1) if total else 0.0,
        "sidechain_pct": round((side_cost / total) * 100, 1) if total else 0.0,
    }


def top_turns(records: list[dict], n: int) -> list[dict]:
    sorted_recs = sorted(records, key=lambda r: -r["cost_usd"])[:n]
    return [
        {
            "timestamp": r["timestamp"],
            "cost_usd": round(r["cost_usd"], 2),
            "model": r["model"],
            "context_tokens": r["context_tokens"],
            "output_tokens": r["output_tokens"],
            "session_suffix": (r["session_id"] or "")[-8:],
            "git_branch": r["git_branch"],
            "skill": r["skill"] or "(no skill)",
            "is_sidechain": r["is_sidechain"],
            "agent_type": r["agent_type"],
        }
        for r in sorted_recs
    ]


def resolve_ccusage(override: str | None) -> list[str] | None:
    """Returns a runnable command, or None if neither ccusage nor npx is on PATH."""
    if override is not None:
        parts = override.split()
        if not parts:
            return None
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
    return None


def reconcile_with_ccusage(cmd: list[str], since: str, until: str,
                           our_total: float) -> dict:
    """Cross-check our local total against ccusage. Non-fatal on mismatch."""
    since_yyyymmdd = datetime.strptime(since, "%Y-%m-%d").strftime("%Y%m%d")
    until_yyyymmdd = datetime.strptime(until, "%Y-%m-%d").strftime("%Y%m%d")
    args = cmd + ["daily", "--json", "--since", since_yyyymmdd,
                  "--until", until_yyyymmdd, "--mode", "calculate", "--timezone", "UTC"]
    try:
        result = subprocess.run(args, capture_output=True, text=True,
                                check=False, timeout=900)
        if result.returncode != 0:
            return {"status": "error", "detail": result.stderr.strip()[:200]}
        data = json.loads(result.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired,
            json.JSONDecodeError) as exc:
        return {"status": "error", "detail": str(exc)}
    ccusage_total = (data.get("totals") or {}).get("totalCost") or 0.0
    if ccusage_total <= 0:
        return {"status": "no_data", "ccusage_total_usd": ccusage_total}
    drift_pct = abs(our_total - ccusage_total) / ccusage_total * 100
    return {
        "status": "ok",
        "ccusage_total_usd": round(ccusage_total, 2),
        "our_total_usd": round(our_total, 2),
        "drift_pct": round(drift_pct, 2),
        "exceeded_threshold": drift_pct > RECONCILE_WARN_PCT,
    }


def render_markdown(report: dict, top_n: int) -> str:
    window = report["window"]
    split = report["main_vs_sidechain"]
    lines = [
        f"# Claude Code Skill Attribution - {report['user']}",
        "",
        f"**Window:** {window['since']} to {window['until']} ({window['days']} days, UTC)",
        f"**Generated:** {report['generated']}",
        f"**Schema:** v{report['schema_version']}",
        f"**Total spend (local calc):** ${report['total_cost_usd']:,.2f} "
        f"across {report['turn_count']:,} assistant turns",
        "",
    ]

    rec = report.get("reconcile") or {}
    if rec.get("status") == "ok":
        marker = " WARN drift > threshold" if rec.get("exceeded_threshold") else ""
        lines += [
            f"**Reconcile vs ccusage:** ours ${rec['our_total_usd']:,.2f} | "
            f"ccusage ${rec['ccusage_total_usd']:,.2f} | "
            f"drift {rec['drift_pct']}%{marker}",
            "",
            "_Ours is typically a few percent higher because ccusage doesn't "
            "read `agent-*.jsonl` subagent transcripts; that spend is real but "
            "invisible to ccusage. Drift above 20% suggests stale rates._",
            "",
        ]
    elif rec.get("status") == "error":
        lines += [f"**Reconcile vs ccusage:** skipped ({rec.get('detail','error')})", ""]
    elif rec.get("status") == "no_data":
        lines += ["**Reconcile vs ccusage:** ccusage reported no data for window", ""]

    if report.get("unknown_models"):
        lines += [
            f"**WARNING:** unknown models (no rates in PRICES dict): "
            f"{', '.join(sorted(report['unknown_models']))} - their cost is reported as $0.",
            "",
        ]

    lines += [
        "## Main thread vs subagent split",
        "",
        f"- Main thread: **${split['main_thread_cost_usd']:,.2f}** ({split['main_thread_pct']}%)",
        f"- Subagent (sidechain): **${split['sidechain_cost_usd']:,.2f}** ({split['sidechain_pct']}%)",
        "",
        "## Per-skill spend",
        "",
        "| Skill | Cost | Turns | Sidechain turns | Mean ctx (tok) | p95 ctx | Top model share |",
        "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in report["per_skill"]:
        share = row["model_share_pct"]
        share_str = ", ".join(f"{m} {p}%" for m, p in list(share.items())[:2]) or "-"
        lines.append(
            f"| `{row['skill']}` | ${row['total_cost_usd']:,.2f} | {row['turn_count']:,} | "
            f"{row['sidechain_turn_count']:,} | {row['mean_context_tokens']:,} | "
            f"{row['p95_context_tokens']:,} | {share_str} |"
        )

    eff_rows = report.get("skill_efficiency") or []
    if eff_rows:
        lines += [
            "",
            "## Skill context efficiency (main-thread invocations)",
            "",
            "_How bloated was the conversation when each skill was invoked?_ "
            "`wasted (lb)` is a lower bound: every turn in the skill window "
            "re-reads at least the inherited context, billed at cache_read rates. "
            "High % means the skill is repeatedly invoked into a session that's "
            "already large and could likely run cheaper after `/clear`.",
            "",
            "| Skill | Inv | Mean ctx@invoke | p95 | Turns/inv | Cost | Wasted (lb) | % |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for r in eff_rows:
            lines.append(
                f"| `{r['skill']}` | {r['invocations']:,} | "
                f"{r['mean_ctx_at_invoke']:,} | {r['p95_ctx_at_invoke']:,} | "
                f"{r['mean_turns_per_invocation']} | "
                f"${r['total_window_cost_usd']:,.2f} | "
                f"${r['wasted_cache_read_lb_usd']:,.2f} | "
                f"{r['wasted_pct']}% |"
            )

    lines += ["", "## Per-subagent_type spend (sidechain only)", "",
              "| Agent type | Cost | Turns | Mean $/turn |",
              "| --- | ---: | ---: | ---: |"]
    for row in report["per_agent_type"]:
        lines.append(
            f"| `{row['agent_type']}` | ${row['total_cost_usd']:,.2f} | "
            f"{row['turn_count']:,} | ${row['mean_cost_per_turn_usd']:,.4f} |"
        )
    if not report["per_agent_type"]:
        lines.append("| _(no sidechain turns in window)_ | | | |")

    lines += ["", f"## Top {top_n} most expensive turns", "",
              "| Time | Cost | Model | Ctx (tok) | Out (tok) | Session | Branch | Skill | Sidechain |",
              "| --- | ---: | --- | ---: | ---: | --- | --- | --- | :---: |"]
    for t in report["top_turns"]:
        lines.append(
            f"| {t['timestamp']} | ${t['cost_usd']:,.2f} | `{t['model']}` | "
            f"{t['context_tokens']:,} | {t['output_tokens']:,} | "
            f"`...{t['session_suffix']}` | `{t['git_branch'] or '-'}` | "
            f"`{t['skill']}` | {'Y' if t['is_sidechain'] else 'N'} |"
        )

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
    if not projects_dir.is_dir():
        sys.exit(f"error: projects directory not found: {projects_dir}")

    print(f"Reading transcripts from {projects_dir}", file=sys.stderr)
    print(f"Window: {args.since} to {args.until} (UTC)", file=sys.stderr)

    unknown_models: set[str] = set()
    records = collect_all(projects_dir, args.since, args.until, unknown_models)
    print(f"Collected {len(records):,} assistant turns in window.", file=sys.stderr)

    invocations = collect_invocations(projects_dir, args.since, args.until, unknown_models)
    print(f"Collected {len(invocations):,} main-thread skill invocations.", file=sys.stderr)

    total_cost = sum(r["cost_usd"] for r in records)
    window_days = (datetime.strptime(args.until, "%Y-%m-%d")
                   - datetime.strptime(args.since, "%Y-%m-%d")).days + 1

    report = {
        "schema_version": SCHEMA_VERSION,
        "user": user,
        "generated": date.today().isoformat(),
        "window": {"since": args.since, "until": args.until, "days": window_days},
        "total_cost_usd": round(total_cost, 2),
        "turn_count": len(records),
        "unknown_models": sorted(unknown_models),
        "main_vs_sidechain": main_vs_sidechain(records),
        "per_skill": aggregate_per_skill(records),
        "skill_efficiency": aggregate_skill_efficiency(invocations),
        "per_agent_type": aggregate_per_agent_type(records),
        "top_turns": top_turns(records, args.top),
    }

    if not args.no_reconcile:
        ccmd = resolve_ccusage(args.ccusage)
        if ccmd is None:
            report["reconcile"] = {"status": "error",
                                   "detail": "ccusage/npx not on PATH"}
        else:
            print(f"Reconciling against ccusage: {' '.join(ccmd)}", file=sys.stderr)
            report["reconcile"] = reconcile_with_ccusage(
                ccmd, args.since, args.until, total_cost)

    md_path = out_dir / f"{user}-attribution.md"
    json_path = out_dir / f"{user}-attribution.json"
    md_path.write_text(render_markdown(report, args.top), encoding="utf-8")
    json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {md_path}")
    print(f"Wrote {json_path}")
    print(f"Total: ${report['total_cost_usd']:,.2f} across {report['turn_count']:,} turns")
    rec = report.get("reconcile") or {}
    if rec.get("status") == "ok" and rec.get("exceeded_threshold"):
        print(f"WARNING: drift vs ccusage is {rec['drift_pct']}% (>{RECONCILE_WARN_PCT}%). "
              "PRICES dict may be stale.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
