#!/usr/bin/env python3
"""cc-census report — pool collector outputs into a per-developer ledger.

    python report.py cc-census-*.json

Produces:
  1. Outage ledger per developer (blocked -> reset -> resumed), labelled UTC
  2. Time-wasted estimate, clipped to each developer's own working band
  3. Model mix (scarcity-adaptation signal)
  4. API-equivalent cost of observed usage, and marginal cost of unblocking
"""
import glob
import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

SUPPORTED_SCHEMA = 4

# A successful turn this soon after a block came from a CONCURRENT session that
# got through, not from the developer regaining access. Real recoveries and
# concurrent hits are cleanly bimodal in practice — measured 1.5-14.5s for the
# concurrent kind against 3990-8004s for genuine ones, with nothing between.
RESUME_MIN_GAP = timedelta(seconds=60)

# ---------------------------------------------------------------- pricing
# USD per million tokens, Anthropic first-party API rates.
#
#   RATES VERIFIED 2026-09-08. RE-CHECK BEFORE TRUSTING A COST FIGURE.
#   https://platform.claude.com/docs/en/pricing
#
# These change. Sonnet 5 carried an introductory $2/$10 rate that expired
# 2026-08-31; a stale table produces a confidently wrong number with no error.
# Partner platforms (Bedrock, Vertex) are priced separately and NOT modelled.
# Cache read = 0.1x input; cache write = 1.25x input (5m TTL), 2x (1h TTL).
PRICING_AS_OF = "2026-09-08"
STALE_AFTER_DAYS = 90
PRICING = {                       # (family, speed): (input, output)
    ("fable", "standard"):  (10.00, 50.00),
    ("mythos", "standard"): (10.00, 50.00),
    ("opus", "standard"):   (5.00,  25.00),
    ("opus", "fast"):       (10.00, 50.00),   # fast mode bills at 2x
    ("sonnet", "standard"): (3.00,  15.00),
    ("haiku", "standard"):  (1.00,   5.00),
}
# Unknown families price at the TOP tier: under-pricing an unrecognised model
# understates the figure this tool exists to defend.
FALLBACK_RATE = (10.00, 50.00)
CACHE_READ_MULT = 0.10
CACHE_WRITE_5M_MULT = 1.25
CACHE_WRITE_1H_MULT = 2.00


def init_streams():
    """Make stdout/stderr UTF-8 and line-buffered. Called from main() only.

    Kept byte-identical to collect.py's copy on purpose: five parameterless
    lines, and importing a sibling would turn a partial plugin install from
    degraded into ImportError. See collect.py's copy for the full rationale.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="backslashreplace",
                               line_buffering=True)
        except Exception:
            pass


def rate_for(family, speed):
    return PRICING.get((family, speed)) or PRICING.get((family, "standard")) or FALLBACK_RATE


def cost_usd(family, speed, t):
    inp, outp = rate_for(family, speed)
    return (
        t.get("input", 0) * inp / 1e6
        + t.get("output", 0) * outp / 1e6
        + t.get("cache_read", 0) * inp * CACHE_READ_MULT / 1e6
        + t.get("cache_write_5m", 0) * inp * CACHE_WRITE_5M_MULT / 1e6
        + t.get("cache_write_1h", 0) * inp * CACHE_WRITE_1H_MULT / 1e6
    )


def dt(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except (TypeError, ValueError):
        return None


def working_band(rec):
    """(start, end) hours — computed by the collector, never derived here.

    The collector emits only this band, never the per-hour histogram it came
    from, so this report cannot reconstruct anyone's working pattern.
    """
    band = rec.get("working_band") or [9, 17]
    try:
        lo, hi = int(band[0]), int(band[1])
    except (TypeError, ValueError, IndexError):
        return 9, 17
    if not (0 <= lo < hi <= 24):
        return 9, 17
    return lo, hi


def overlap_hours(start, end, lo, hi, daily=None, tz=None):
    """Working hours lost to an outage spanning [start, end).

    `tz` is the developer's UTC offset and is REQUIRED for a correct answer:
    the band (`lo`/`hi`) and the `daily` keys are both in that developer's
    local time, while the ledger timestamps are UTC. Intersecting a local band
    against UTC instants silently returns 0 whenever the two do not happen to
    overlap — which is how a colleague with a 09:00-17:00 band and blocks at
    17:47 UTC reported five real outages as zero hours lost.

    A day is charged for the part of the outage that falls inside that
    developer's working band, and **days with no recorded activity are
    skipped** — a Friday block that resumes Monday must not bill Saturday and
    Sunday. Absent a `daily` map every day counts, which over-charges.

    An earlier version also capped each day at the hours left in a *typical*
    day, reasoning that someone blocked late in a long day had lost little.
    That was wrong, and real data showed it: `active_hours` covers the whole
    day including the hours worked AFTER the block cleared, so working through
    and past an outage made the model score it as costless. On the first
    colleague's file it zeroed five genuine mid-morning outages. Working a long
    day around a block does not make the block free, and the error ran against
    the most-affected people — the same direction the README warns about.
    """
    if not start or not end or end <= start:
        return 0.0
    if tz is not None:
        start, end = start.astimezone(tz), end.astimezone(tz)
    # Guard the day loop: a mis-parsed reset must not iterate for centuries.
    end = min(end, start + timedelta(days=8))
    total = 0.0
    day = start.replace(hour=0, minute=0, second=0, microsecond=0)
    while day < end:
        if daily is not None and not daily.get(day.date().isoformat()):
            day += timedelta(days=1)          # no activity: not a working day
            continue
        w0, w1 = day + timedelta(hours=lo), day + timedelta(hours=hi)
        a, b = max(start, w0), min(end, w1)
        if b > a:
            total += (b - a).total_seconds() / 3600
        day += timedelta(days=1)
    return total


def merge_windows(spans):
    """Union overlapping [start,end) spans so a retried block bills once."""
    out = []
    for s, e in sorted(spans, key=lambda x: x[0]):
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def load(paths):
    recs, problems = [], []
    for p in sorted(set(paths)):
        try:
            with open(p, encoding="utf-8") as fh:
                r = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            problems.append(f"{p}: unreadable ({type(exc).__name__})")
            continue
        if not isinstance(r, dict) or "user" not in r:
            problems.append(f"{p}: not a cc-census file (no 'user' key)")
            continue
        got = r.get("schema")
        if got != SUPPORTED_SCHEMA:
            problems.append(
                f"{p}: schema {got!r}, this report understands {SUPPORTED_SCHEMA} — "
                f"re-run collect.py from the same plugin version")
            continue
        r["_path"] = p
        recs.append(r)
    return recs, problems


def main():
    init_streams()
    paths = []
    for a in sys.argv[1:]:
        hits = glob.glob(a)
        if not hits:
            print(f"warning: no file matched {a!r}", file=sys.stderr)
        paths.extend(hits)
    if not paths:
        sys.exit("usage: report.py cc-census-*.json")

    recs, problems = load(paths)
    for msg in problems:
        print(f"SKIPPED  {msg}", file=sys.stderr)
    if not recs:
        sys.exit("no usable cc-census files")

    seen_users = defaultdict(list)
    for r in recs:
        seen_users[r["user"]].append(r["_path"])
    for user, ps in seen_users.items():
        if len(ps) > 1:
            print(f"warning: {len(ps)} files for user {user!r} — totals will double-count: "
                  f"{', '.join(ps)}", file=sys.stderr)

    recs.sort(key=lambda r: r["user"])

    stale = ""
    try:
        age = (datetime.now(timezone.utc)
               - datetime.fromisoformat(PRICING_AS_OF).replace(tzinfo=timezone.utc)).days
        if age > STALE_AFTER_DAYS:
            stale = f"  ** PRICING IS {age} DAYS OLD — RE-VERIFY BEFORE QUOTING **"
    except ValueError:
        pass

    print("=" * 78)
    print(f"CC-CENSUS — {len(recs)} developer(s)   pricing as of {PRICING_AS_OF}{stale}")
    print("All ledger times are UTC. Working bands are each developer's own local hours.")
    print("=" * 78)

    fleet_cost = fleet_blocked = fleet_marginal = 0.0

    for r in recs:
        user = r["user"]
        lo, hi = working_band(r)
        off = r.get("tz_offset_minutes", 0)
        sign = "+" if off >= 0 else "-"
        oldest = (r.get("oldest_utc") or "")[:10] or "?"
        newest = (r.get("newest_utc") or "")[:10] or "?"
        print(f"\n{'='*78}\n{user}   tz={r.get('tz_name','?')} "
              f"(UTC{sign}{abs(off)//60:02d}:{abs(off)%60:02d})"
              f"   window {oldest}..{newest}   workday {lo:02d}:00-{hi:02d}:00 local")

        events = r.get("limit_events") or []
        sev = defaultdict(int)
        for e in events:
            sev[e.get("severity", "?")] += 1

        # Union overlapping windows per kind: a block retried four times is one
        # outage, not four, and must not bill its window four times.
        spans_by_kind = defaultdict(list)
        rows = []
        for e in events:
            if e.get("severity") != "blocked":
                continue
            b = dt(e.get("at_utc"))
            reset = dt(e.get("reset_utc"))
            resumed = dt(e.get("resumed_utc"))
            if not b:
                continue
            # Discard a "resumption" that is really a concurrent session
            # squeaking through, or the window collapses to a few seconds.
            usable = resumed if (resumed and resumed - b >= RESUME_MIN_GAP) else None
            # Prefer whichever comes first: a reset days out is not an outage
            # if the developer demonstrably resumed before it.
            ends = [x for x in (reset, usable) if x and x > b]
            end = min(ends) if ends else None
            if end:
                spans_by_kind[e.get("kind", "unknown")].append((b, end))
            rows.append((b, e.get("kind", "?"), reset, resumed, end,
                         e.get("reset_zone_assumed"), e.get("reset_parsed_as"), usable))

        dailymap = r.get("daily") or {}
        active_days = len(dailymap)
        # The band and the daily keys are local; the ledger is UTC. Convert.
        localtz = timezone(timedelta(minutes=r.get("tz_offset_minutes") or 0))

        user_blocked = 0.0    # band hours in the window, idle days skipped
        window_span = 0.0     # upper bound: idle days counted too
        for kind, spans in spans_by_kind.items():
            for s, e in merge_windows(spans):
                user_blocked += overlap_hours(s, e, lo, hi, dailymap, localtz)
                window_span += overlap_hours(s, e, lo, hi, None, localtz)

        unresolved = sum(1 for row in rows if row[4] is None)
        assumed_tz = sum(1 for row in rows if row[5])

        if rows:
            print(f"\n  blocked events: {len(rows)}  -> {sum(len(merge_windows(v)) for v in spans_by_kind.values())} "
                  f"distinct outage window(s)   (grace {sev['grace']}, approaching {sev['approaching']})")
            print(f"  {'blocked (UTC)':17} {'kind':14} {'reset (UTC)':17} {'resumed (UTC)':17}")
            for b, kind, reset, resumed, end, assumed, how, usable in rows:
                sr = f"{reset:%m-%d %H:%M}" if reset else f"({how or 'unparsed'})"
                sm = f"{resumed:%m-%d %H:%M}" if resumed else "never"
                flag = "  [zone assumed]" if assumed else ""
                print(f"  {b:%m-%d %H:%M}{'':6} {kind:14} {sr:17} {sm:17}{flag}")
                if resumed and not usable:
                    # A successful turn seconds after the block came from a
                    # concurrent session, not a recovery. It says nothing about
                    # when this developer regained access, and the window math
                    # ignores it — so don't imply the reset time is wrong.
                    gap = (resumed - b).total_seconds()
                    print(f"  {'':17} {'':14} concurrent session succeeded {gap:.0f}s "
                          f"after the block — not a resumption")
                elif usable and reset:
                    lag = (usable - reset).total_seconds() / 60
                    note = "  <- resumed BEFORE reset: reset time is suspect" if lag < 0 else ""
                    print(f"  {'':17} {'':14} resumption lag {lag:+.0f} min{note}")
            print(f"\n  wasted working hours (working days only): {user_blocked:.1f} h")
            if window_span - user_blocked > 0.05:
                print(f"  ...counting idle days too               : {window_span:.1f} h "
                      f"(weekends/PTO inside a multi-day outage)")
            if unresolved:
                print(f"  {unresolved} blocked event(s) had no usable reset or resumption "
                      f"and contribute 0 h — the total is a floor.")
            if assumed_tz:
                print(f"  {assumed_tz} reset time(s) named a timezone this machine could not "
                      f"resolve (no tzdata) and were read as {user}'s local time.")
                print(f"  That is CORRECT if {user} is in the zone the message named, and off "
                      f"by the offset difference if not — check before discounting these.")
        else:
            print(f"\n  blocked events: 0   (grace {sev['grace']}, approaching {sev['approaching']})")

        skipped = r.get("skipped") or {}
        if skipped:
            print(f"\n  collector skipped records (near-zero expected):")
            for k, v in skipped.items():
                print(f"    {v:>6}  {k}")

        unmatched = r.get("unmatched_api_errors") or {}
        if unmatched:
            suspicious = [k for k in unmatched
                          if any(w in k.lower() for w in ("limit", "resets", "usage", "credit"))]
            print(f"\n  detector audit — API errors NOT classified as limits:")
            for k, n in list(unmatched.items())[:6]:
                print(f"    {n:>4}  {k}")
            if len(unmatched) > 6:
                print(f"    ... {len(unmatched) - 6} more")
            if suspicious:
                print(f"  ** {len(suspicious)} unmatched error(s) contain limit-shaped words — "
                      f"the message templates may have changed. Outages are UNDERCOUNTED. **")

        by_fam = defaultdict(lambda: defaultdict(int))
        for key, t in (r.get("tokens") or {}).items():
            parts = key.split("|")
            if len(parts) != 3:
                continue
            for k, v in t.items():
                by_fam[(parts[1], parts[2])][k] += v

        user_cost = sum(cost_usd(f, s, t) for (f, s), t in by_fam.items())
        turns_total = sum(t.get("turns", 0) for t in by_fam.values())
        out_total = sum(t.get("output", 0) for t in by_fam.values())

        print(f"\n  model mix ({turns_total:,} deduplicated turns):")
        for (f, s), t in sorted(by_fam.items(), key=lambda x: -x[1].get("turns", 0)):
            share = 100 * t.get("turns", 0) / turns_total if turns_total else 0
            oshare = 100 * t.get("output", 0) / out_total if out_total else 0
            label = f"{f}/{s}" if s != "standard" else f
            print(f"    {label:14} {t.get('turns',0):>7,} turns ({share:4.1f}%)   "
                  f"output {t.get('output',0)/1e6:6.1f}M ({oshare:4.1f}%)   "
                  f"${cost_usd(f, s, t):8,.2f}")

        print(f"\n  API-equivalent cost of observed usage : ${user_cost:9,.2f}"
              f"   over {active_days} active days")
        if active_days:
            print(f"  per active day                        : ${user_cost/active_days:9,.2f}")

        active_hours_total = r.get("active_hour_count") or 0
        if active_hours_total:
            burn = user_cost / active_hours_total
            marginal = user_blocked * burn
            print(f"  observed burn rate                    : ${burn:9,.2f} / active hour")
            print(f"  blocked working hours                 : {user_blocked:9.1f} h")
            print(f"  est. extra-usage cost to unblock      : ${marginal:9,.2f}")
            fleet_marginal += marginal
        else:
            print("  burn rate                             : n/a (no active hours recorded)")

        fleet_cost += user_cost
        fleet_blocked += user_blocked

    print(f"\n{'='*78}\nFLEET TOTAL ({len(recs)} devs)")
    print(f"  API-equivalent cost of observed usage : ${fleet_cost:10,.2f}")
    print(f"  blocked working hours (floor)         : {fleet_blocked:10.1f} h")
    print(f"  est. extra-usage cost to unblock      : ${fleet_marginal:10,.2f}")
    print("\n  Both hour figures are FLOORS: a developer who gave up without")
    print("  opening Claude Code leaves no transcript and is not counted, and")
    print("  blocked events with no usable reset time contribute zero.")


if __name__ == "__main__":
    main()
