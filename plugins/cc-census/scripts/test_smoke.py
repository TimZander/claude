#!/usr/bin/env python3
"""cc-census collector smoke test — run with: python test_smoke.py

Builds a synthetic transcript tree, runs collect.py against it, and asserts the
detector classifies every limit type and reset format.

This exists because the detector has silently under-reported three times during
development: v1 matched only "weekly limit" and reported ZERO outages on a
machine that had one; v2 scored still-working grace warnings as hard outages;
v3 summed duplicated usage rows and inflated every cost figure 2.7x. All three
are silent and directional. Add a fixture for any message shape you teach it.
"""
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECT = os.path.join(HERE, "collect.py")
FAILURES = []


def check(label, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}" + ("" if cond else f"  {detail}"))
    if not cond:
        FAILURES.append(label)


def turn(ts, text=None, model="claude-opus-5", error=False, sidechain=False,
         msg_id=None, req_id=None, speed="standard"):
    rec = {
        "type": "assistant",
        "timestamp": ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "sessionId": "sess-fixture",
        "isSidechain": sidechain,
        "requestId": req_id or f"req-{ts.timestamp()}",
        "message": {"model": model, "role": "assistant", "id": msg_id or f"msg-{ts.timestamp()}"},
    }
    if error:
        rec["isApiErrorMessage"] = True
        rec["message"]["content"] = [{"type": "text", "text": text}]
    else:
        rec["message"]["usage"] = {
            "input_tokens": 100, "output_tokens": 200,
            "cache_read_input_tokens": 5000, "speed": speed,
            "cache_creation": {"ephemeral_5m_input_tokens": 300,
                               "ephemeral_1h_input_tokens": 50},
        }
    return json.dumps(rec)


def run_collect(root, *extra):
    out = os.path.join(root, "out.json")
    p = subprocess.run([sys.executable, COLLECT, "--user", "fixture",
                        "--root", root, "-o", out, *extra],
                       capture_output=True, text=True)
    return p, out


def main():
    base = datetime(2026, 5, 12, 9, 0, tzinfo=timezone.utc).astimezone()

    CASES = [
        ("weekly + absolute reset w/ tz",
         "You've hit your weekly limit · resets 12pm (America/Denver)", "weekly", "absolute"),
        ("5-hour session + relative reset",
         "You've hit your session limit · resets in 2h 15m", "session_5h", "relative"),
        ("Opus weekly limit (model-scoped, not generic)",
         "You've reached your Opus weekly limit · resets in 3h", "weekly_opus", "relative"),
        ("Sonnet weekly limit",
         "You've reached your Sonnet limit · resets in 45m", "weekly_sonnet", "relative"),
        ("fast mode limit",
         "You've hit your fast limit · resets in 30m", "fast_mode", "relative"),
        ("monthly spend limit",
         "You've hit your monthly spend limit. Run /usage-credits to manage your limits.",
         "spend_monthly", "none"),
        ("user out of credits",
         "You're out of usage credits. /model to switch models.", "credits_user", "none"),
        ("org out of usage",
         "Your org is out of usage · contact your admin", "credits_org", "none"),
        ("seat tier excluded",
         "Your seat type doesn't include usage for this model", "seat_tier", "none"),
        ("TYPOGRAPHIC APOSTROPHE (U+2019)",
         "You’ve hit your weekly limit · resets in 4h", "weekly", "relative"),
        ("limit text behind a thinking block", None, "weekly", "relative"),
    ]

    with tempfile.TemporaryDirectory() as root:
        proj = os.path.join(root, "some--private--repo--name")
        os.makedirs(proj)
        lines, t = [], base

        for _, text, _, _ in CASES[:-1]:
            lines.append(turn(t, text, error=True))
            lines.append(turn(t + timedelta(minutes=1), text, error=True))   # retry
            lines.append(turn(t + timedelta(hours=4)))                        # resumption
            t += timedelta(days=1)

        # A limit message whose FIRST content block is thinking, not text.
        rec = json.loads(turn(t, "x", error=True))
        rec["message"]["content"] = [
            {"type": "thinking", "thinking": "hmm"},
            {"type": "text", "text": "You've hit your weekly limit · resets in 4h"}]
        lines.append(json.dumps(rec))
        lines.append(turn(t + timedelta(hours=4)))
        t += timedelta(days=1)

        # Malformed reset hour must NOT crash the collector.
        lines.append(turn(t, "You've hit your session limit · resets 99pm", error=True))
        lines.append(turn(t + timedelta(hours=1)))
        t += timedelta(days=1)

        # Grace + approaching (leading indicators, NOT outages).
        lines.append(turn(t, "[Usage limit reached — grace window active. Wrap up.]", error=True))
        lines.append(turn(t + timedelta(minutes=30)))
        t += timedelta(days=1)
        lines.append(turn(t, "You're close to your weekly usage limit", error=True))
        lines.append(turn(t + timedelta(minutes=30)))
        t += timedelta(days=1)

        # Non-limit errors must be routed to unmatched, not scored as outages.
        # The second carries a middot: unmatched keys are echoed to stdout, so
        # this is what proves the console is not mangling Claude's own text.
        lines.append(turn(t, "API Error: 529 Overloaded", error=True))
        lines.append(turn(t, "Login expired · Please run /login", error=True))

        # DUPLICATED usage rows: one response split across three JSONL rows,
        # each repeating the same usage object. Must be counted ONCE.
        for _ in range(3):
            lines.append(turn(t + timedelta(minutes=5), msg_id="msg-dup", req_id="req-dup"))
        lines.append(turn(t + timedelta(minutes=6), model="claude-fable-5"))
        lines.append(turn(t + timedelta(minutes=7), model="claude-sonnet-5", sidechain=True))
        lines.append(turn(t + timedelta(minutes=8), model="claude-haiku-4-5-20251001"))
        lines.append(turn(t + timedelta(minutes=9), model="claude-opus-5", speed="fast"))

        with open(os.path.join(proj, "fixture.jsonl"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

        print("\n-- consent gate " + "-" * 61)
        p, out = run_collect(root)
        check("exits 0 without --yes", p.returncode == 0, p.stderr[-200:])
        check("writes NOTHING without --yes", not os.path.exists(out))
        check("prints a summary, not raw JSON", "cc-census summary" in p.stdout
              and '"limit_events"' not in p.stdout)
        p2, _ = run_collect(root, "--full")
        check("--full does dump the payload", '"limit_events"' in p2.stdout)

        print("\n-- console output " + "-" * 59)
        # Read the child's stdout as UTF-8 rather than the locale codepage:
        # this asserts what the process WROTE, not what this console can show.
        pu = subprocess.run([sys.executable, COLLECT, "--user", "fixture", "--root", root],
                            capture_output=True, encoding="utf-8", errors="replace")
        check("non-ASCII in Claude's own messages survives stdout",
              "·" in pu.stdout and "�" not in pu.stdout,
              f"...{pu.stdout[-120:]!r}")
        # Merge the streams the way the plugin command captures them.
        pm = subprocess.run([sys.executable, COLLECT, "--user", "fixture", "--root", root],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding="utf-8", errors="replace")
        summary_at = pm.stdout.find("cc-census summary")
        note_at = pm.stdout.find("Nothing written")
        check("the 'Nothing written' note follows the summary it refers to",
              0 <= summary_at < note_at, f"summary@{summary_at} note@{note_at}")

        p, out = run_collect(root, "--yes")
        check("writes the file with --yes", os.path.exists(out), p.stderr[-300:])
        if not os.path.exists(out):
            sys.exit("cannot continue")
        with open(out, encoding="utf-8") as fh:
            got = json.load(fh)
        raw = json.dumps(got)

        p3, _ = run_collect(root, "--yes")
        check("refuses to overwrite an existing file", p3.returncode != 0)

    print("\n-- payload contract (report.py depends on these) " + "-" * 28)
    for key in ("schema", "user", "working_band", "active_hour_count", "tokens",
                "limit_events", "unmatched_api_errors", "daily", "skipped",
                "tz_offset_minutes", "tz_name", "oldest_utc", "newest_utc"):
        check(f"emits {key!r}", key in got, f"keys={sorted(got)}")
    check("user label round-trips", got.get("user") == "fixture")
    check("schema matches what report.py accepts", got.get("schema") == 4)

    print("\n-- detector coverage " + "-" * 56)
    by_kind = {}
    for ev in got["limit_events"]:
        if ev["severity"] == "blocked":
            by_kind.setdefault(ev["kind"], []).append(ev)
    for label, _, kind, mode in CASES:
        evs = by_kind.get(kind, [])
        check(label, bool(evs), f"expected kind={kind}, got {sorted(by_kind)}")
        if evs and mode != "none":
            check(f"  reset parsed as {mode}",
                  any(e["reset_parsed_as"] == mode for e in evs),
                  f"got {[e['reset_parsed_as'] for e in evs]}")

    print("\n-- reset clamping and malformed input " + "-" * 39)
    sess = [e for e in got["limit_events"] if e["kind"] == "session_5h"]
    for e in sess:
        if e["reset_utc"]:
            span = (datetime.fromisoformat(e["reset_utc"])
                    - datetime.fromisoformat(e["at_utc"])).total_seconds() / 3600
            check(f"session-limit window {span:.1f}h is <= 5h", span <= 5.001)
    check("malformed 'resets 99pm' did not crash the run", got["schema"] == 4)
    check("malformed hour yields no reset rather than a bogus one",
          any(e["reset_parsed_as"] == "none" for e in sess))

    print("\n-- severities " + "-" * 63)
    sev = {}
    for ev in got["limit_events"]:
        sev[ev["severity"]] = sev.get(ev["severity"], 0) + 1
    check("grace window detected", sev.get("grace") == 1, f"got {sev}")
    check("approaching warning detected", sev.get("approaching") == 1, f"got {sev}")

    print("\n-- deduplication " + "-" * 60)
    tot_turns = sum(v["turns"] for v in got["tokens"].values())
    check("3 duplicate rows counted once", got["skipped"].get("duplicate_usage_rows") == 2,
          f"skipped={got['skipped']}")
    opus_std = [v for k, v in got["tokens"].items() if k.endswith("|opus|standard")]
    check("fast-mode turn tracked separately",
          any(k.endswith("|opus|fast") for k in got["tokens"]), f"{list(got['tokens'])}")

    print("\n-- non-limit errors are NOT misclassified " + "-" * 35)
    check("529 routed to unmatched", any("529" in k for k in got["unmatched_api_errors"]))
    check("529 not in limit_events", not any("529" in e["message"] for e in got["limit_events"]))

    print("\n-- privacy invariants " + "-" * 55)
    check("no per-hour histogram emitted", "active_hours" not in got)
    check("working_band emitted instead", isinstance(got.get("working_band"), list))
    check("repo/dir name absent", "some--private--repo--name" not in raw)
    check("session id absent", "sess-fixture" not in raw)
    check("no .jsonl filenames", ".jsonl" not in raw)
    check("no 'project' identifier emitted", '"project"' not in raw)
    check("skipped-record counters present", isinstance(got.get("skipped"), dict))

    print("\n-- --user validation " + "-" * 56)
    with tempfile.TemporaryDirectory() as root2:
        os.makedirs(os.path.join(root2, "p"))
        open(os.path.join(root2, "p", "f.jsonl"), "w").write("")
        for bad in ("alice@corp.com", "../escape", "a/b"):
            p = subprocess.run([sys.executable, COLLECT, "--user", bad, "--root", root2],
                               capture_output=True, text=True)
            check(f"rejects --user {bad!r}", p.returncode != 0)

    print()
    if FAILURES:
        sys.exit(f"{len(FAILURES)} check(s) failed: {FAILURES}")
    print("all checks passed")


if __name__ == "__main__":
    main()
