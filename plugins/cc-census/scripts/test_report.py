#!/usr/bin/env python3
"""cc-census report smoke test — run with: python test_report.py

report.py produces the dollar figures a human acts on, so it needs at least as
much scrutiny as the collector. Every cost assertion below is a hand-computed
golden value, not a self-consistency check: a swapped cache multiplier or a
dropped /1e6 must fail here.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "report.py")
spec = importlib.util.spec_from_file_location("report", REPORT)
rp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rp)

FAILURES = []
UTC = timezone.utc


def check(label, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}" + ("" if cond else f"  {detail}"))
    if not cond:
        FAILURES.append(label)


def near(a, b, tol=1e-6):
    return abs(a - b) < tol


MILLION = {"input": 1_000_000, "output": 1_000_000, "cache_read": 1_000_000,
           "cache_write_5m": 1_000_000, "cache_write_1h": 1_000_000}


def main():
    print("-- cost model: hand-computed golden values " + "-" * 34)
    # opus standard @ $5 in / $25 out, 1M tokens in every bucket:
    #   input 5.00 + output 25.00 + cache_read (5*0.1) 0.50
    #   + write5m (5*1.25) 6.25 + write1h (5*2.0) 10.00 = 46.75
    check("opus/standard 1M each bucket == $46.75",
          near(rp.cost_usd("opus", "standard", MILLION), 46.75),
          f"got {rp.cost_usd('opus','standard',MILLION)}")
    # opus FAST @ $10/$50 -> exactly double
    check("opus/fast == $93.50 (2x standard)",
          near(rp.cost_usd("opus", "fast", MILLION), 93.50),
          f"got {rp.cost_usd('opus','fast',MILLION)}")
    check("fable == $93.50", near(rp.cost_usd("fable", "standard", MILLION), 93.50))
    check("mythos priced as fable, not opus",
          near(rp.cost_usd("mythos", "standard", MILLION), 93.50))
    # sonnet @ $3/$15: 3 + 15 + 0.30 + 3.75 + 6.00 = 28.05
    check("sonnet == $28.05", near(rp.cost_usd("sonnet", "standard", MILLION), 28.05),
          f"got {rp.cost_usd('sonnet','standard',MILLION)}")
    # haiku @ $1/$5: 1 + 5 + 0.10 + 1.25 + 2.00 = 9.35
    check("haiku == $9.35", near(rp.cost_usd("haiku", "standard", MILLION), 9.35),
          f"got {rp.cost_usd('haiku','standard',MILLION)}")
    check("unknown family priced at TOP tier, not Opus",
          near(rp.cost_usd("nonesuch", "standard", MILLION), 93.50))
    check("missing buckets treated as zero, not KeyError",
          near(rp.cost_usd("opus", "standard", {"output": 1_000_000}), 25.00))
    check("cache multipliers are distinct (5m 1.25x != 1h 2.0x)",
          not near(rp.cost_usd("opus", "standard", {"cache_write_5m": 1_000_000}),
                   rp.cost_usd("opus", "standard", {"cache_write_1h": 1_000_000})))

    print("\n-- overlap_hours " + "-" * 60)
    d = lambda h, m=0: datetime(2026, 5, 12, h, m, tzinfo=UTC)
    check("fully inside 9-17 band: 10:00-12:00 == 2.0",
          near(rp.overlap_hours(d(10), d(12), 9, 17), 2.0))
    check("clipped at band start: 07:00-10:00 == 1.0",
          near(rp.overlap_hours(d(7), d(10), 9, 17), 1.0))
    check("clipped at band end: 16:00-20:00 == 1.0",
          near(rp.overlap_hours(d(16), d(20), 9, 17), 1.0))
    check("entirely outside the band == 0.0",
          near(rp.overlap_hours(d(2), d(5), 9, 17), 0.0))
    check("overnight span counts both days' bands: 16:00->10:00 == 2.0",
          near(rp.overlap_hours(d(16), d(10) + timedelta(days=1), 9, 17), 2.0))
    check("end == start -> 0.0", near(rp.overlap_hours(d(10), d(10), 9, 17), 0.0))
    check("end before start -> 0.0", near(rp.overlap_hours(d(12), d(10), 9, 17), 0.0))
    check("end None -> 0.0", near(rp.overlap_hours(d(10), None, 9, 17), 0.0))
    check("absurd far-future end is capped, not unbounded",
          rp.overlap_hours(d(10), d(10).replace(year=2527), 9, 17) <= 8 * 8 + 1)
    check("24h band accepted (hi=24 does not raise)",
          near(rp.overlap_hours(d(0), d(24 - 1, 59), 0, 24), 23.983333, 1e-4))

    print("\n-- Friday block, no work until Monday " + "-" * 39)
    # Blocked Fri 15 May 13:00, next successful turn Mon 18 May 09:00.
    # Worked Fri and Mon; nothing Sat/Sun. Typical day = 7 h.
    fri, mon = datetime(2026, 5, 15, 13, tzinfo=UTC), datetime(2026, 5, 18, 9, tzinfo=UTC)
    workdays = {"2026-05-15": {"turns": 40, "active_hours": 5},
                "2026-05-18": {"turns": 40, "active_hours": 7}}
    naive = rp.overlap_hours(fri, mon, 9, 17)
    check("without the day filter this charged the whole weekend (20.0 h)",
          near(naive, 20.0), f"got {naive}")
    skip_only = rp.overlap_hours(fri, mon, 9, 17, workdays, None)
    check("skipping idle Sat+Sun alone drops it to 4.0 h",
          near(skip_only, 4.0), f"got {skip_only}")
    modelled = rp.overlap_hours(fri, mon, 9, 17, workdays, 7.0)
    check("with a 7 h typical day the Friday charge is 2.0 h",
          near(modelled, 2.0), f"got {modelled}")
    wide = rp.overlap_hours(fri, mon, 8, 22, workdays, 7.0)
    check("a wide 08-22 band no longer inflates it (2.0 h, was 38.0 h)",
          near(wide, 2.0), f"got {wide}")
    check("a developer who worked a FULL day before the block is charged 0",
          near(rp.overlap_hours(fri, mon, 9, 17,
                                {"2026-05-15": {"turns": 9, "active_hours": 9},
                                 "2026-05-18": {"turns": 9, "active_hours": 7}}, 7.0), 0.0))
    check("Monday-morning block before a same-day resume still counts",
          near(rp.overlap_hours(datetime(2026, 5, 18, 9, tzinfo=UTC),
                                datetime(2026, 5, 18, 12, tzinfo=UTC),
                                9, 17, {"2026-05-18": {"turns": 9, "active_hours": 2}}, 7.0),
               3.0))

    print("\n-- merge_windows (retried block bills once) " + "-" * 33)
    spans = [(d(10), d(14)), (d(10, 10), d(14)), (d(10, 25), d(14)), (d(11), d(14))]
    merged = rp.merge_windows(spans)
    check("4 overlapping retries -> 1 window", len(merged) == 1, f"got {merged}")
    check("merged window spans 10:00-14:00", merged[0] == (d(10), d(14)))
    check("disjoint windows stay separate",
          len(rp.merge_windows([(d(10), d(11)), (d(13), d(14))])) == 2)
    check("adjacent windows merge", len(rp.merge_windows([(d(10), d(11)), (d(11), d(12))])) == 1)

    print("\n-- working_band validation (input is another machine's file) " + "-" * 16)
    check("valid band passes through", rp.working_band({"working_band": [8, 22]}) == (8, 22))
    check("missing key -> default", rp.working_band({}) == (9, 17))
    check("null -> default", rp.working_band({"working_band": None}) == (9, 17))
    check("1-element list -> default, not IndexError",
          rp.working_band({"working_band": [9]}) == (9, 17))
    check("non-numeric -> default, not ValueError",
          rp.working_band({"working_band": ["x", "y"]}) == (9, 17))
    check("inverted band -> default", rp.working_band({"working_band": [17, 9]}) == (9, 17))
    check("out-of-range band -> default", rp.working_band({"working_band": [9, 25]}) == (9, 17))

    print("\n-- dt() never raises " + "-" * 56)
    check("valid iso parses", rp.dt("2026-05-12T10:00:00+00:00") == d(10))
    check("None -> None", rp.dt(None) is None)
    check("garbage -> None, not ValueError", rp.dt("not-a-date") is None)

    print("\n-- end-to-end: schema gate and crash-safety " + "-" * 33)
    def rec(**over):
        base = {
            "schema": 4, "user": "alice", "collected_utc": "2026-05-20T10:00:00+00:00",
            "tz_offset_minutes": -360, "tz_name": "MDT", "transcript_files": 3,
            "oldest_utc": "2026-05-12T09:00:00+00:00", "newest_utc": "2026-05-19T09:00:00+00:00",
            "daily": {"2026-05-12": {"turns": 10}}, "sessions_per_day": {"2026-05-12": 1},
            "working_band": [9, 17], "active_hour_count": 10,
            "tokens": {"2026-05-12|opus|standard": dict(MILLION, turns=10)},
            "limit_events": [], "unmatched_api_errors": {}, "skipped": {},
        }
        base.update(over)
        return base

    with tempfile.TemporaryDirectory() as tmp:
        def write(name, obj):
            p = os.path.join(tmp, name)
            with open(p, "w", encoding="utf-8") as fh:
                json.dump(obj, fh)
            return p

        def run(*paths):
            return subprocess.run([sys.executable, REPORT, *paths],
                                  capture_output=True, text=True)

        good = write("cc-census-alice.json", rec())
        p = run(good)
        check("happy path exits 0", p.returncode == 0, p.stderr[-300:])
        check("prints the golden cost $46.75", "46.75" in p.stdout, p.stdout[-300:])
        check("labels times as UTC", "UTC" in p.stdout)

        old = write("cc-census-bob.json", rec(user="bob", schema=2))
        p = run(old)
        check("older schema is REFUSED, not silently mispriced",
              "SKIPPED" in p.stderr and "schema" in p.stderr, p.stderr[-200:])
        p = run(good, old)
        check("one bad file does not kill the pooled run", p.returncode == 0)
        check("...and bob is excluded from totals", "bob" not in p.stdout)

        empty = write("cc-census-carol.json",
                      rec(user="carol", oldest_utc=None, newest_utc=None,
                          daily={}, tokens={}, active_hour_count=0))
        p = run(empty)
        check("no-successful-turns record does not crash", p.returncode == 0, p.stderr[-300:])
        check("...and reports burn rate as n/a", "n/a" in p.stdout)

        junk = write("cc-census-junk.json", {"hello": "world"})
        p = run(junk, good)
        check("non-census JSON skipped with a message",
              p.returncode == 0 and "not a cc-census file" in p.stderr, p.stderr[-200:])

        with open(os.path.join(tmp, "cc-census-bad.json"), "w") as fh:
            fh.write("{ truncated")
        p = run(os.path.join(tmp, "cc-census-bad.json"), good)
        check("truncated JSON skipped, run continues",
              p.returncode == 0 and "unreadable" in p.stderr, p.stderr[-200:])

        dup = write("cc-census-alice-copy.json", rec())
        p = run(good, dup)
        check("duplicate user warns about double-counting",
              "double-count" in p.stderr, p.stderr[-200:])

        p = run(os.path.join(tmp, "nope-*.json"))
        check("no matching files exits non-zero", p.returncode != 0)

        # A retried block: 4 events, one true 4h window, band 9-17 -> 4.0h
        evs = []
        for mins in (0, 10, 25, 60):
            evs.append({
                "at_utc": (d(10) + timedelta(minutes=mins)).isoformat(),
                "at_local": (d(10) + timedelta(minutes=mins)).isoformat(),
                "kind": "weekly", "severity": "blocked",
                "reset_utc": d(14).isoformat(), "reset_parsed_as": "absolute",
                "reset_zone_assumed": False, "message": "You've hit your weekly limit",
                "resumed_utc": d(14, 5).isoformat()})
        retried = write("cc-census-dave.json", rec(user="dave", limit_events=evs))
        p = run(retried)
        check("4 retries collapse to 1 outage window",
              "-> 1 distinct outage window" in p.stdout, p.stdout[-500:])
        check("...billing 4.0h, not 16.0h", "4.0 h" in p.stdout, p.stdout[-500:])

        # resumed before reset => reset is suspect, and the SHORTER span wins
        susp = [{"at_utc": d(10).isoformat(), "at_local": d(10).isoformat(),
                 "kind": "weekly", "severity": "blocked",
                 "reset_utc": d(16).isoformat(), "reset_parsed_as": "absolute",
                 "reset_zone_assumed": True, "message": "m",
                 "resumed_utc": d(11).isoformat()}]
        p = run(write("cc-census-erin.json", rec(user="erin", limit_events=susp)))
        check("resumption before reset shortens the window to 1.0h",
              "1.0 h" in p.stdout, p.stdout[-500:])
        check("...and flags the assumed timezone", "zone assumed" in p.stdout)

        # unmatched errors containing limit-shaped words must raise the canary
        canary = write("cc-census-fred.json", rec(
            user="fred", unmatched_api_errors={"Weekly limit reached, try later": 3}))
        p = run(canary)
        check("limit-shaped unmatched error raises the canary",
              "may have changed" in p.stdout, p.stdout[-400:])

    print()
    if FAILURES:
        sys.exit(f"{len(FAILURES)} check(s) failed: {FAILURES}")
    print("all checks passed")


if __name__ == "__main__":
    main()
