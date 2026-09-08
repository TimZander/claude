#!/usr/bin/env python3
"""cc-census collector — run on each developer's machine.

Scans local Claude Code transcripts and emits ONE JSON file containing only
timestamps, counts, token totals, and Claude's own limit messages.

NEVER emitted: prompt text, assistant text, file paths, repo names, branch
names, tool inputs/outputs, or session titles. Session IDs are counted, never
emitted. Per-hour activity is collapsed to a working band before it leaves the
machine (see working_band).

Usage:
    python collect.py --user alice              # print summary, write nothing
    python collect.py --user alice --full       # also dump the raw payload
    python collect.py --user alice --yes        # write cc-census-alice.json

Writing REQUIRES --yes. The summary-first flow is enforced here rather than in
documentation so it cannot be skipped by a caller that did not read the README.

Transcripts are pruned after ~30 days by default, so run this soon.
"""
import argparse
import hashlib
import json
import os
import re
import sys
from bisect import bisect_right
from collections import defaultdict
from datetime import datetime, timedelta, timezone

# Windows consoles default to a legacy codepage, so the middot and em dashes in
# Claude's own limit messages render as replacement characters. The payload is
# unaffected (json.dumps is ensure_ascii), but a privacy tool that looks broken
# on first run is a bad way to ask someone for their data.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

SCHEMA = 4
USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,40}$")

# ---------------------------------------------------------------- detector
# Message templates read from the Claude Code binary, v2.1.226:
#   {five_hour:"session limit", seven_day:"weekly limit",
#    seven_day_opus:"Opus limit", seven_day_sonnet:"Sonnet limit"}
#
# ORDER IS LOAD-BEARING: classify() returns the first match, so the
# model-scoped kinds must precede the generic "weekly limit" or a message like
# "your Opus weekly limit" collapses into the generic bucket.
LIMIT_KINDS = [
    ("weekly_opus",    r"Opus limit|Opus weekly limit"),
    ("weekly_sonnet",  r"Sonnet limit|Sonnet weekly limit"),
    ("fast_mode",      r"fast limit"),
    ("session_5h",     r"session limit"),
    ("weekly",         r"weekly limit"),
    ("spend_monthly",  r"monthly spend limit|monthly limit"),
    ("credits_user",   r"out of usage credits"),
    ("credits_org",    r"org(?:anization)? is out of usage|org's monthly usage limit"),
    ("seat_tier",      r"seat type doesn't include"),
    ("org_cap",        r"usage_cap_reached|reached your specified[\w\s-]*?usage limits?"),
]

# Longest plausible outage per kind. Without this, the "reset is tomorrow"
# rollover below turns a 5-hour limit hit at 13:00 with a "resets 12pm"
# message into a 23-hour phantom outage.
MAX_WINDOW = {
    "session_5h": timedelta(hours=5),
    "fast_mode": timedelta(hours=5),
    "weekly": timedelta(days=7),
    "weekly_opus": timedelta(days=7),
    "weekly_sonnet": timedelta(days=7),
}
DEFAULT_MAX_WINDOW = timedelta(days=7)

LIMIT_OPENER = re.compile(
    r"(You've hit your|You've reached your|You're out of usage credits"
    r"|Your org(?:anization)? is out of usage|Your seat type doesn't include"
    r"|usage limit reached|usage_cap_reached)",
    re.I,
)
GRACE_RE = re.compile(r"grace window active", re.I)
NEAR_RE = re.compile(r"You're close to your[\s\S]{0,40}?(usage limit|usage credit limit)", re.I)

RESET_ABS = re.compile(
    r"resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(?:\(([\w/+-]+)\))?",
    re.I,
)
# Unit WORDS, not bare letters: "resets in 2 months" must not parse as 2 minutes.
RESET_REL = re.compile(
    r"resets?\s+in\s+((?:\d+\s*(?:days?|hours?|minutes?|seconds?|[dhms])\b\s*)+)", re.I)
RESET_UNIT = re.compile(r"(\d+)\s*(days?|hours?|minutes?|seconds?|[dhms])\b", re.I)
RESET_EPOCH = re.compile(r"usage limit reached\|(\d{10})\b")

# Claude Code UI strings use a typographic apostrophe; the detector patterns
# above are written with the ASCII one. Normalising before matching is what
# stops "You’ve hit your weekly limit" from silently scoring zero outages.
APOSTROPHES = {"’": "'", "ʼ": "'", "‘": "'", "＇": "'"}


def norm(text):
    for bad, good in APOSTROPHES.items():
        text = text.replace(bad, good)
    return text


def classify(text):
    for kind, pat in LIMIT_KINDS:
        if re.search(pat, text, re.I):
            return kind
    return "unknown"


def parse_reset(text, at, kind):
    """Return (reset_datetime_or_None, how, zone_assumed).

    `zone_assumed` is True when the message named a timezone we could not
    resolve, so the hour was interpreted in the collector's local zone. That
    is a real source of error and the report surfaces it rather than hiding it.
    """
    m = RESET_EPOCH.search(text)
    if m:
        secs = int(m.group(1))
        # Reject absurd epochs (a 13-digit millisecond stamp truncated to 10
        # digits lands centuries away and would produce enormous outages).
        if abs(secs - at.timestamp()) <= DEFAULT_MAX_WINDOW.total_seconds() * 2:
            return datetime.fromtimestamp(secs, tz=at.tzinfo), "epoch", False
        return None, "none", False

    m = RESET_REL.search(text)
    if m:
        units = {"d": "days", "h": "hours", "m": "minutes", "s": "seconds"}
        total = timedelta()
        for n, unit in RESET_UNIT.findall(m.group(1)):
            key = units[unit[0].lower()]
            total += timedelta(**{key: int(n)})
        if total > timedelta(0):
            return at + total, "relative", False
        return None, "none", False

    m = RESET_ABS.search(text)
    if m:
        hour = int(m.group(1))
        minute = int(m.group(2) or 0)
        ampm = m.group(3).lower()
        if ampm == "pm" and hour != 12:
            hour += 12
        elif ampm == "am" and hour == 12:
            hour = 0
        if not (0 <= hour <= 23 and 0 <= minute <= 59):
            return None, "none", False        # never crash on a malformed hour

        zone_name = m.group(4)
        tzinfo, assumed = at.tzinfo, False
        if zone_name and "/" in zone_name:
            try:                              # stdlib on 3.9+, but the IANA db
                from zoneinfo import ZoneInfo  # is absent on Windows w/o tzdata
                tzinfo = ZoneInfo(zone_name)
            except Exception:
                assumed = True                # flagged, not silently wrong
        else:
            assumed = bool(zone_name)

        base = at.astimezone(tzinfo)
        cand = base.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if cand <= base:
            cand += timedelta(days=1)
        cand = cand.astimezone(at.tzinfo)
        # Clamp to the longest outage this limit kind can actually produce.
        if cand - at > MAX_WINDOW.get(kind, DEFAULT_MAX_WINDOW):
            return None, "none", assumed
        return cand, "absolute", assumed

    return None, "none", False


# ---------------------------------------------------------------- helpers
def fam(model):
    m = (model or "").lower()
    for k in ("opus", "sonnet", "haiku", "fable", "mythos"):
        if k in m:
            return k
    return "other"


def working_band(hours):
    """Collapse a per-hour activity histogram to [start_hour, end_hour].

    Deliberately lossy. The raw per-developer, per-hour histogram is a record
    of who works nights and weekends; the report only ever needed the 5th/95th
    percentile band, so that is all this collector emits.
    """
    tally = defaultdict(int)
    for _, hrs in hours.items():
        for h, n in hrs.items():
            tally[int(h)] += n
    if not tally:
        return [9, 17]
    total = sum(tally.values())
    lo, acc = 0, 0
    for h in sorted(tally):
        acc += tally[h]
        if acc >= total * 0.05:
            lo = h
            break
    hi, acc = 23, 0
    for h in sorted(tally, reverse=True):
        acc += tally[h]
        if acc >= total * 0.05:
            hi = h + 1
            break
    return [lo, min(24, max(hi, lo + 1))]


def text_of(content):
    """Concatenate every text block, not just the first.

    A limit message preceded by a thinking block would otherwise read as empty
    and be filed as an unclassified error instead of an outage.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [str(b.get("text", "")) for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        if not parts:
            parts = [str(b.get("text", "")) for b in content if isinstance(b, dict)]
        return "\n".join(p for p in parts if p)
    return ""


def collect(root):
    daily = defaultdict(lambda: defaultdict(int))
    hours = defaultdict(lambda: defaultdict(int))
    tokens = defaultdict(lambda: defaultdict(int))
    sessions_seen = defaultdict(set)
    ok_turns, limit_events = [], []
    unmatched = defaultdict(int)
    seen_usage = set()                 # (message.id, requestId) -> dedup key
    counts = defaultdict(int)

    for dirpath, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            fp = os.path.join(dirpath, name)
            try:
                fh = open(fp, "r", encoding="utf-8", errors="replace")
            except OSError:
                counts["unreadable_files"] += 1
                continue
            counts["transcript_files"] += 1
            with fh:
                for lineno, line in enumerate(fh):
                    if not line.startswith("{"):
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        counts["json_parse_errors"] += 1
                        continue
                    ts = r.get("timestamp")
                    if not ts or r.get("type") != "assistant":
                        continue
                    try:
                        # No explicit tz: .astimezone() resolves the local
                        # offset FOR THAT INSTANT, so records either side of a
                        # DST change are not all stamped with today's offset.
                        at = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
                    except Exception:
                        counts["timestamp_parse_errors"] += 1
                        continue

                    msg = r.get("message") or {}

                    if r.get("isApiErrorMessage"):
                        txt = norm(text_of(msg.get("content"))).strip()
                        is_grace = bool(GRACE_RE.search(txt))
                        is_near = bool(NEAR_RE.search(txt))
                        is_limit = bool(LIMIT_OPENER.search(txt))
                        if is_grace or is_near or is_limit:
                            # Warnings win: the grace message contains the
                            # literal "usage limit reached", and scoring it as
                            # a hard outage inflates every figure downstream.
                            severity = ("grace" if is_grace else
                                        "approaching" if is_near else "blocked")
                            kind = classify(txt)
                            reset, how, assumed = parse_reset(txt, at, kind)
                            limit_events.append({
                                "at_utc": at.astimezone(timezone.utc).isoformat(),
                                "at_local": at.isoformat(),
                                "kind": kind,
                                "severity": severity,
                                "reset_utc": reset.astimezone(timezone.utc).isoformat()
                                             if reset else None,
                                "reset_parsed_as": how,
                                "reset_zone_assumed": assumed,
                                "message": txt[:200],
                            })
                        else:
                            unmatched[txt.split(".")[0][:70] or "(empty)"] += 1
                        continue

                    u = msg.get("usage") or {}
                    if not u:
                        continue
                    # One API response spans several JSONL rows (thinking,
                    # text, tool_use), and EVERY row repeats the full usage
                    # object. Without this guard every token total, and so
                    # every cost figure, is inflated ~2.7x.
                    key = (msg.get("id"), r.get("requestId"))
                    if key == (None, None):
                        key = (fp, lineno)
                    if key in seen_usage:
                        counts["duplicate_usage_rows"] += 1
                        continue
                    seen_usage.add(key)

                    d = at.date().isoformat()
                    speed = "fast" if u.get("speed") == "fast" else "standard"
                    k = f"{d}|{fam(msg.get('model'))}|{speed}"
                    cc = u.get("cache_creation") or {}
                    try:
                        tokens[k]["input"] += int(u.get("input_tokens") or 0)
                        tokens[k]["output"] += int(u.get("output_tokens") or 0)
                        tokens[k]["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
                        tokens[k]["cache_write_5m"] += int(cc.get("ephemeral_5m_input_tokens") or 0)
                        tokens[k]["cache_write_1h"] += int(cc.get("ephemeral_1h_input_tokens") or 0)
                    except (TypeError, ValueError):
                        counts["usage_value_errors"] += 1
                        continue
                    tokens[k]["turns"] += 1
                    daily[d]["turns"] += 1
                    daily[d]["subagent_turns"] += 1 if r.get("isSidechain") else 0
                    hours[d][at.hour] += 1
                    if r.get("sessionId"):
                        sessions_seen[d].add(r["sessionId"])
                    ok_turns.append(at)

    ok_turns.sort()
    limit_events.sort(key=lambda e: e["at_utc"])

    # Resumption: next successful turn anywhere on this machine (limits are
    # per-account, so a block in one session blocks every session).
    for ev in limit_events:
        at = datetime.fromisoformat(ev["at_local"])
        i = bisect_right(ok_turns, at)
        ev["resumed_utc"] = (ok_turns[i].astimezone(timezone.utc).isoformat()
                             if i < len(ok_turns) else None)

    now = datetime.now().astimezone()
    return {
        "schema": SCHEMA,
        "user": None,                      # filled in by main()
        "collected_utc": now.astimezone(timezone.utc).isoformat(),
        "tz_offset_minutes": int(now.utcoffset().total_seconds() // 60),
        "tz_name": now.tzname(),
        "transcript_files": counts["transcript_files"],
        "oldest_utc": ok_turns[0].astimezone(timezone.utc).isoformat() if ok_turns else None,
        "newest_utc": ok_turns[-1].astimezone(timezone.utc).isoformat() if ok_turns else None,
        # active_hours per day (a count, never WHICH hours) lets the report
        # cap a day's charged outage at what that developer would plausibly
        # still have worked, instead of at the full width of their band.
        "daily": {d: dict(v, active_hours=len(hours.get(d, {})))
                  for d, v in sorted(daily.items())},
        "sessions_per_day": {d: len(s) for d, s in sorted(sessions_seen.items())},
        # Per-hour activity is NOT emitted — see working_band() for why.
        "working_band": working_band(hours),
        "active_hour_count": sum(len(h) for h in hours.values()),
        "tokens": {k: dict(v) for k, v in sorted(tokens.items())},
        "limit_events": limit_events,
        "unmatched_api_errors": dict(sorted(unmatched.items(), key=lambda x: -x[1])),
        # Silent skips are counted, not swallowed: a transcript-format change
        # must not read as "no blocking occurred".
        "skipped": {k: v for k, v in sorted(counts.items()) if k != "transcript_files"},
    }


def summarise(out, user):
    """Human-readable summary — what the consent step shows before writing."""
    ev = out["limit_events"]
    sev = defaultdict(int)
    for e in ev:
        sev[e["severity"]] += 1
    lo, hi = out["working_band"]
    lines = [
        f"cc-census summary for '{user}'  (schema {out['schema']})",
        f"  window            : {(out['oldest_utc'] or '-')[:10]} .. {(out['newest_utc'] or '-')[:10]} UTC",
        f"  transcripts read  : {out['transcript_files']}   active days: {len(out['daily'])}",
        f"  limit events      : {len(ev)} total  "
        f"(blocked {sev['blocked']}, grace {sev['grace']}, approaching {sev['approaching']})",
        f"  working band      : {lo:02d}:00-{hi:02d}:00 local  "
        f"(the per-hour breakdown of when you work is NOT collected)",
        f"  timezone shared   : {out['tz_name']} (UTC{out['tz_offset_minutes'] // 60:+d})",
        "",
        "  NOT included: prompt text, assistant text, thinking, tool inputs/outputs,",
        "  file paths, repo or branch names, session titles, credentials.",
    ]
    if out["skipped"]:
        lines += ["", "  records skipped during the scan (should be near zero):"]
        lines += [f"    {v:>6}  {k}" for k, v in out["skipped"].items()]
    if out["unmatched_api_errors"]:
        lines += ["", "  REVIEW THESE — API errors the detector did not recognise.",
                  "  They are shared verbatim (first 70 chars). If any looks like your",
                  "  own work rather than Claude's own error text, do not share the file:"]
        lines += [f"    {n:>4}  {k}" for k, n in out["unmatched_api_errors"].items()]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Collect local Claude Code usage-limit history.")
    ap.add_argument("--user", required=True, help="short label, e.g. a first name")
    ap.add_argument("-o", "--out", help="output JSON path")
    ap.add_argument("--yes", action="store_true",
                    help="actually write the file (default: summary only)")
    ap.add_argument("--full", action="store_true",
                    help="also print the raw payload to stdout")
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    args = ap.parse_args()

    if not USER_RE.match(args.user):
        sys.exit("--user must be 1-40 chars of letters, digits, dot, dash or underscore "
                 "(no '@', no path separators — the label is shared and becomes a filename)")
    if not os.path.isdir(args.root):
        sys.exit(f"no transcripts at {args.root}")

    out = collect(args.root)
    out["user"] = args.user
    blob = json.dumps(out, indent=2)

    print(summarise(out, args.user))
    if args.full:
        print("\n--- raw payload ---")
        print(blob)

    if not args.yes:
        # Flush stdout first: the two streams buffer independently, so without
        # this the note lands ABOVE the summary it refers to whenever both are
        # captured together — which is exactly how the plugin command runs it.
        sys.stdout.flush()
        print(f"\nNothing written. Review the above, then re-run with --yes to write "
              f"({len(blob)} bytes).", file=sys.stderr)
        return

    path = args.out or f"cc-census-{args.user}.json"
    if os.path.exists(path):
        print(f"\nRefusing to overwrite existing {path} — remove it or pass -o.",
              file=sys.stderr)
        sys.exit(1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(blob)
    print(f"\nwrote {path} ({len(blob)} bytes). Sharing it is your call; "
          f"this tool sends nothing anywhere.")


if __name__ == "__main__":
    main()
