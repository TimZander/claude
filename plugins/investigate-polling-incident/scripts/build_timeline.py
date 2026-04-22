#!/usr/bin/env python3
"""Merge server + device events into one UTC-sorted timeline with publish-window annotations.

Reads a JSON object on stdin:

  {
    "server": [ {"utc": "2026-04-22T22:34:12Z", "kind": "...", "message": "..."}, ... ],
    "device": [ {"utc": "2026-04-22T22:35:07Z", "kind": "...", "message": "..."}, ... ],
    "publishWindows": [ {"name": "CAIC", "utcTime": "22:30", "toleranceMinutes": 15}, ... ]
  }

`server` and `device` are required (may be []). `publishWindows` is optional.
Every event must carry a `utc` field in ISO 8601 form; tz-aware values are
normalized to UTC, tz-naive values are assumed UTC.

Emits a plain-text timeline on stdout, one event per line, grouped by date:

  === 2026-04-22 (UTC) ===
  22:34:12Z  [server] kind: message
  22:35:07Z  [device] kind: message   ⚠ publish-window: CAIC (+5m)

Exit 0 on success, non-zero with an error message on malformed input.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone


@dataclass(frozen=True)
class PublishWindow:
    name: str
    utc_time: time
    tolerance: timedelta


def parse_utc(value: str) -> datetime:
    # datetime.fromisoformat handles trailing 'Z' only on 3.11+; normalize first.
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_publish_windows(raw) -> list[PublishWindow]:
    out: list[PublishWindow] = []
    if not raw:
        return out
    for entry in raw:
        name = str(entry.get("name", "")).strip() or "window"
        t_str = str(entry.get("utcTime", "")).strip()
        raw_tol = entry.get("toleranceMinutes", 15)
        # bool is a subclass of int — reject explicitly so True/False don't
        # silently become 1/0. Floats (even integer-valued ones like 15.0) are
        # rejected too, to stay consistent with the same-type contract applied
        # to strings like "fifteen".
        if isinstance(raw_tol, bool) or not isinstance(raw_tol, int):
            raise SystemExit(
                f"error: publish window '{name}' has non-integer "
                f"toleranceMinutes={raw_tol!r}"
            )
        if raw_tol < 0:
            raise SystemExit(
                f"error: publish window '{name}' has negative toleranceMinutes={raw_tol} "
                f"(expected >= 0)"
            )
        tol = raw_tol
        try:
            # Accept "HH:MM" or "HH:MM:SS" only — reject 1-part or 4+-part strings.
            parts = [int(p) for p in t_str.split(":")]
            if len(parts) not in (2, 3):
                raise ValueError(f"expected HH:MM or HH:MM:SS, got {len(parts)} segments")
            while len(parts) < 3:
                parts.append(0)
            t = time(parts[0], parts[1], parts[2], tzinfo=timezone.utc)
        except (ValueError, IndexError):
            raise SystemExit(f"error: publish window '{name}' has invalid utcTime {t_str!r} (expected HH:MM)")
        out.append(PublishWindow(name=name, utc_time=t, tolerance=timedelta(minutes=tol)))
    return out


def nearest_publish_window(dt: datetime, windows: list[PublishWindow]):
    """Return (PublishWindow, signed_minutes) for the closest window within its tolerance, else None.

    `signed_minutes` is negative when the event is before the window, positive after.
    Anchors are checked on dt.date() ± 1 day so a window at e.g. 23:30 UTC can still
    match an event at 00:05 UTC the following day.
    """
    if not windows:
        return None
    best = None
    best_abs: timedelta | None = None
    for w in windows:
        for day_offset in (-1, 0, 1):
            anchor_date = dt.date() + timedelta(days=day_offset)
            anchor = datetime.combine(anchor_date, w.utc_time)
            delta = dt - anchor
            abs_delta = abs(delta)
            if abs_delta <= w.tolerance and (best_abs is None or abs_delta < best_abs):
                # int() on a float truncates toward zero — symmetric for +/- deltas,
                # unlike // 60 which rounds toward -inf for negatives.
                best = (w, int(delta.total_seconds() / 60))
                best_abs = abs_delta
    return best


def format_event(ev: dict, tag: str, windows: list[PublishWindow]) -> str:
    dt = parse_utc(ev["utc"])
    kind = str(ev.get("kind", "")).strip()
    msg = str(ev.get("message", "")).strip()
    left = f"{dt.strftime('%H:%M:%S')}Z  [{tag}]"
    mid = f" {kind}:" if kind else ""
    line = f"{left}{mid} {msg}".rstrip()
    hit = nearest_publish_window(dt, windows)
    if hit is not None:
        w, signed_min = hit
        sign = "+" if signed_min >= 0 else ""
        line += f"   ⚠ publish-window: {w.name} ({sign}{signed_min}m)"
    return line


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="-", help="Path to input JSON (default: stdin)")
    args = parser.parse_args(argv)

    if args.input == "-":
        raw = sys.stdin.read()
    else:
        with open(args.input, "r", encoding="utf-8") as f:
            raw = f.read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON on input: {e}", file=sys.stderr)
        return 2

    if not isinstance(data, dict):
        print(
            f"error: top-level JSON must be an object with 'server'/'device' keys, "
            f"got {type(data).__name__}",
            file=sys.stderr,
        )
        return 2

    server = data.get("server", []) or []
    device = data.get("device", []) or []
    windows = parse_publish_windows(data.get("publishWindows"))

    events: list[tuple[datetime, str]] = []
    for ev in server:
        try:
            dt = parse_utc(ev["utc"])
        except (KeyError, ValueError) as e:
            print(f"warning: skipping server event with bad utc: {e}", file=sys.stderr)
            continue
        events.append((dt, format_event(ev, "server", windows)))
    for ev in device:
        try:
            dt = parse_utc(ev["utc"])
        except (KeyError, ValueError) as e:
            print(f"warning: skipping device event with bad utc: {e}", file=sys.stderr)
            continue
        events.append((dt, format_event(ev, "device", windows)))

    events.sort(key=lambda x: x[0])

    current_date = None
    for dt, line in events:
        d = dt.date().isoformat()
        if d != current_date:
            if current_date is not None:
                print()
            print(f"=== {d} (UTC) ===")
            current_date = d
        print(line)

    if not events:
        print("(no events)")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
