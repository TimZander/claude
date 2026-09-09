# cc-census

Measure how much Claude Code usage-limit blocking a team actually experiences,
from local transcripts. Produces a per-developer ledger — blocked at, resets
at, resumed at, hours lost inside working hours — plus an API-equivalent cost
model.

Answers "how many hours did we lose last month, and what would it have cost to
not lose them." Does **not** predict future blocking; see [Limitations](#limitations).

## Quick start

### As a plugin (recommended)

Everyone who can use this tool already has Claude Code — that's the
prerequisite — so the install and the audience are the same set.

```
/plugin marketplace add TimZander/claude
/plugin install cc-census@tzander-skills
```

Each developer then runs `/cc-census` on their own machine. The command runs the
collector in dry-run first, walks them through exactly what the payload contains,
and writes the file only after they approve. The coordinator runs
`/cc-census-report` once the JSON files are gathered.

The consent walkthrough is the reason to prefer this over the scripts: a README
can't make anyone check before sharing, and a command can.

### As plain scripts

Nothing depends on the plugin wrapper. From `scripts/`:

```bash
python collect.py --user alice          # prints a summary, writes NOTHING
python collect.py --user alice --full   # also dumps the raw payload
python collect.py --user alice --yes    # writes cc-census-alice.json
python report.py cc-census-*.json
```

**Writing requires `--yes`.** The summary-first flow is enforced in the script
rather than in documentation, so it cannot be skipped by a caller who did not
read this file.

Python 3.9+. No dependencies, no network calls, no credentials. On Windows,
prefer `py -3` — a bare `python3` is often a Microsoft Store alias stub.

> **Where the file lands:** `collect.py` writes to the **current working
> directory**. Running it from inside a work repo drops a usage profile at that
> repo's root, where this plugin's `.gitignore` has no effect. Either run it
> outside the repo, pass `-o`, or add `cc-census-*.json` to that repo's
> `.gitignore`.

**Run it soon.** Claude Code prunes transcripts after ~30 days by default
(`cleanupPeriodDays`). There is no way to recover a window that has aged out.

## What gets shared

`--dry-run` prints the exact payload. It contains timestamps, counts, token
totals by model, and Claude Code's own limit messages. It does **not** contain:

- prompt text, assistant text, thinking, or tool inputs/outputs
- file paths, repo names, branch names, or session titles
- credentials of any kind

Project directories and session IDs are salted-hashed. The salt is random per
run and never stored, so hashes correlate **within** one collection and not
across two — deliberate, and worth knowing before you try to diff runs.

### Per-hour activity is deliberately not collected

An earlier version emitted a per-developer, per-hour activity histogram. That
is a record of who works nights and weekends — a timesheet, not a usage metric.
The report only ever consumed the 5th/95th-percentile band derived from it, so
the collector now computes that band locally and emits `working_band: [8, 22]`
instead. Nothing downstream lost anything.

Dates are still present (the outage ledger and demand trend need them).

### The one field to review

`unmatched_api_errors` holds the first ~70 characters of any API error the
detector did **not** classify as a limit. This is the safety net that catches a
message wording the tool doesn't know about yet — don't remove it. In practice
these are Claude Code's own strings (`API Error: 529 Overloaded`), but a `400`
could in principle echo request detail, so eyeball it before sharing.

## How it works

The detector matches the limit-message templates Claude Code itself emits.
There are four limit types, each with its own wording (the left column is the
`kind` value that appears in the JSON; the binary's own internal keys are
`five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet`):

| `kind` emitted | Message says |
|---|---|
| `session_5h` | session limit |
| `weekly` | weekly limit |
| `weekly_opus` | Opus limit |
| `weekly_sonnet` | Sonnet limit |

plus credit, spend-cap, seat-tier, fast-mode, grace-window, and
approaching-limit states. Reset times render three ways — absolute with an IANA
zone (`resets 12pm (America/Denver)`), relative (`· resets in 2h 15m`), and a
legacy epoch form — all three are parsed.

Outage duration is the union of `blocked → min(reset, resumption)` windows,
intersected with that developer's working band. Taking the minimum matters: a
model-scoped limit whose reset is days away is not a days-long outage if the
developer demonstrably resumed on another model an hour later. Unioning matters
too — a block retried four times is one outage, not four. Reset times are also
clamped to the longest window the limit kind can produce (5 h for a session
limit, 7 d for a weekly one), because the "reset is tomorrow" rollover would
otherwise turn a 5-hour limit into a 23-hour phantom outage.

Resumption lag (`resumed − reset`) is reported separately, because it measures
something different: whether they were actually waiting or had context-switched
away. A **negative** lag is printed with a warning — it is proof the reset was
mis-parsed, not a real measurement.

**Timestamps in the report are UTC**, since the point is pooling developers in
different zones. Each developer's working band stays in their own local hours,
and the outage window is converted into that local time before the two are
intersected — mixing the two silently returns zero hours whenever a
developer's band and their UTC block times do not happen to overlap.

### Two known sources of error, surfaced rather than hidden

- **`[zone assumed]`** — Claude renders resets in the *account's* timezone
  (`resets 12pm (America/Denver)`). Resolving that needs the IANA database,
  which Windows lacks unless `tzdata` is installed. Without it the hour is read
  as machine-local and the row is flagged. Install `tzdata` for exact values.
- **Duplicate rows** — Claude Code writes one transcript row per content block,
  and every row repeats the full `usage` object. The collector deduplicates on
  `(message.id, requestId)`; on real data this removes ~2.7× inflation. The
  count appears as `duplicate_usage_rows` in the skipped-records block, where a
  large number is *expected*.

> **Unofficial and version-pinned.** These message templates were read out of
> the Claude Code binary, **v2.1.226**. They are undocumented internals and can
> change in any release, silently. The `unmatched_api_errors` block is your
> canary: if a limit type stops appearing and unclassified errors start showing
> limit-shaped text, the templates moved. Nothing here circumvents a limit —
> the tool only reads transcripts Claude Code already wrote.

## Cost model

Rates are hardcoded in `report.py` and **verified as of 2026-09-08** against
<https://platform.claude.com/docs/en/pricing>. Re-check before trusting a
figure — Sonnet 5's introductory rate expired 2026-08-31, and a stale table
produces a confidently wrong number with no error.

Cache reads bill at 0.1× input; cache writes at 1.25× (5m TTL) or 2× (1h TTL),
tracked separately rather than blended. Partner-platform pricing (Bedrock,
Vertex) is **not** modeled.

Note that cache reads usually dominate the total on agentic workloads. Compare
per-active-hour burn across developers, not just totals — a developer doing
short interactive edits prices out very differently from one running long
agentic sessions.

## Limitations

- **The hour figures are floors, not estimates.** A transcript only records a
  block if the developer was mid-session. Someone who knows they're capped and
  doesn't open Claude Code leaves no evidence — so the undercount is worst for
  the developers who are blocked most. Do not read a small number as good news.
- **~30-day ceiling.** You cannot reconstruct a quarter retrospectively.
- **Near-misses are completely invisible.** Running at 91% of your weekly window
  and never tripping produces **no signal at all** here. Utilization percentage
  is not written to transcripts — it exists only in the live statusLine payload
  (`rate_limits.used_percentage` / `resets_at`), which this tool cannot see. The
  `approaching` severity only fires if Claude Code writes a "You're close to
  your usage limit" message into the transcript, and that has never been
  observed in real data. Treat a zero-outage census as "nobody tripped", never
  as "nobody was under pressure".
- **Rare events resist trending.** Detecting a *doubling* in block frequency by
  counting blocks needs roughly 68 events. If your team generates a handful a
  month, that is a year of data. Trending the underlying pressure requires
  sampling utilization continuously — see the note above on why that data is
  not in transcripts.
- **Blocked hours are modelled, not measured.** A day is charged for the part
  of the outage falling inside that developer's working band, and days with no
  recorded activity are skipped — so a Friday-afternoon block that resumes
  Monday charges the Friday afternoon, not the whole weekend. The report prints
  the idle-days-included figure alongside so you can see the difference.
- **Consumption under a binding constraint measures the constraint, not
  demand.** Heavily-limited developers adapt — smaller models, shorter
  sessions — so token totals can *fall* while the problem worsens. Watch the
  model mix for that.

## Tests

```bash
python scripts/test_smoke.py     # collect.py
python scripts/test_report.py    # report.py — the cost model
```

`test_smoke.py` builds a synthetic transcript tree covering every limit type,
all three reset formats, a typographic apostrophe, a limit message behind a
thinking block, a malformed reset hour, duplicated usage rows, the grace and
approaching states, the `--yes` gate, `--user` validation, and the privacy
invariants. `test_report.py` asserts hand-computed golden dollar values for
every model family and cache multiplier, plus window merging, schema refusal,
and every crash path found in review.

These exist for a specific reason. The detector has silently under-reported
three times during development:

1. v1 matched only `"weekly limit"` and reported **zero** outages on a machine
   that had one.
2. v2 scored grace-window warnings — where work continues — as hard outages,
   inflating every stoppage figure.
3. v3 summed duplicated usage rows, inflating every cost figure **2.7×**.

All three are silent and directional, and none would have been caught by
eyeballing the output. Add a fixture for any message shape you teach it, and a
golden value for any number you add.

## License

MIT.
