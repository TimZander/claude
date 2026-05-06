# Claude Code Usage Report — Team Member Guide

Run this to produce a per-developer Claude Code usage baseline. Useful as
input to a team-subscription cost analysis: per-day, per-model, and
per-5-hour-block breakdowns of the API-rate-equivalent cost recorded in your
local Claude Code transcripts. Share the aggregate JSON with whoever is
collecting team baselines; the full markdown summary stays on your machine.

## What this does

Walks `~/.claude/projects/` (your local Claude Code transcripts), aggregates
tokens by day, by model, and by 5-hour block via [ccusage](https://github.com/ryoppippi/ccusage),
applies current Anthropic API pricing, and produces:

- `<youruser>-summary.md` — one-page report with daily timeline, per-model
  split, 5-hour-block distribution, and token totals. **Keep this for yourself.**
- `<youruser>-aggregate.json` — totals + percentiles + per-day cost timeline,
  no transcript content. **Share this with whoever is collecting team baselines.**

Cost figures are *API-rate equivalent* — what your usage would have cost
pay-per-token. The point of the team-subscription analysis is to compare these
numbers against flat-rate plan options.

All ccusage calls use `--timezone UTC` and `--mode calculate` so each
developer's aggregate is comparable regardless of where they ran the script.

## One-time setup

Both Node.js and Python are required. Most dev machines already have them.

1. Confirm Node.js: `node --version` (any recent LTS is fine).
2. Confirm Python 3.9+: `python3 --version` or `python --version`. **If your
   `python` reports 2.x, install Python 3 from python.org** — the script does
   not run on Python 2.
3. Install ccusage globally so subsequent runs are fast:

   ```bash
   npm install -g ccusage
   ```

   On macOS or Linux installs that use the system Node, this may need `sudo`:
   `sudo npm install -g ccusage`. If you use nvm, asdf, or a per-user prefix
   (`npm config set prefix ~/.npm-global`) sudo isn't needed.

   Verify: `ccusage --version`

If you skip step 3, the script falls back to `npx -y ccusage@latest`, which
works but adds ~60 seconds of download to every run.

## Get the script

Pick one approach:

### Option A — download just the script (single file, recommended for one-time use)

PowerShell (Windows):

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/TimZander/claude/main/scripts/claude-usage-report.py" -OutFile "claude-usage-report.py"
```

bash (macOS / Linux / Git Bash):

```bash
curl -O https://raw.githubusercontent.com/TimZander/claude/main/scripts/claude-usage-report.py
```

This drops `claude-usage-report.py` in your current directory.

### Option B — clone the repo (if you want updates or other tools)

```bash
git clone https://github.com/TimZander/claude
cd claude
```

The script is at `scripts/claude-usage-report.py` from the repo root.

## Run

> **Pick an output directory outside any repo working tree** (e.g., `~/claude-usage`).
> The script writes two files containing your dollar amounts and daily timeline.
> Don't run it inside a git repo — accidental `git add -A` commits personal data.

If you used **Option A** (single-file download), the script is in your current directory:

```bash
python3 claude-usage-report.py --out-dir ~/claude-usage
```

If you used **Option B** (cloned the repo), the script has a `scripts/` prefix:

```bash
python3 scripts/claude-usage-report.py --out-dir ~/claude-usage
```

Default window is the last 60 days. Two files appear in `~/claude-usage/`:
`<youruser>-summary.md` and `<youruser>-aggregate.json`.

### Common overrides

The examples below assume Option B (cloned repo). Drop the `scripts/` prefix if you
used Option A.

```bash
# Custom window
python3 scripts/claude-usage-report.py --since 2026-03-01 --until 2026-04-30 \
    --out-dir ~/claude-usage

# Custom output filename prefix (defaults to your OS username, sanitized)
python3 scripts/claude-usage-report.py --user firstname-lastname \
    --out-dir ~/claude-usage

# Force ccusage to fetch fresh pricing (recommended after a model launch)
python3 scripts/claude-usage-report.py --ccusage 'ccusage --no-offline' \
    --out-dir ~/claude-usage
```

## What to send back

Share the **`<youruser>-aggregate.json`** file with whoever is collecting
team baselines. Keep the `<youruser>-summary.md` for your own records.

The aggregate JSON contains:

- Window dates (UTC) and total token counts (input, output, cache read, cache write)
- Per-model cost breakdown (e.g., how much of your spend is Opus vs Sonnet vs Haiku)
- Daily statistics (min, avg, p95, max) and a per-day cost timeline
- 5-hour block percentiles and a bucketed distribution
- Tooling provenance: `schema_version`, `ccusage_version`, `cost_mode`, `timezone`
  — so cross-seat comparisons are auditable

It does **not** contain transcript content, project names, branch names, or
working directory paths. The script never invokes ccusage with `-i`/`--instances`,
so per-project breakdowns are not computed.

## Privacy

- The aggregate JSON intentionally excludes per-project breakdown.
- Do **not** run ccusage with `-i, --instances` and share that output unless
  whoever's collecting baselines explicitly asks. That flag exposes which
  repos you've worked on.
- The summary markdown's daily timeline contains dates and dollar amounts only.
  Share it if asked, but it's not required for the team analysis.

## Troubleshooting

**"It looks like the script hung."** First run downloads ~50MB of npm packages
through `npx` with no progress indicator. If you ran `npm install -g ccusage`
during setup, subsequent runs should complete in <30 seconds. If you still
suspect a hang, narrow the window with `--since`.

**"Pricing missing for model X"** or unfamiliar model names in the breakdown.
ccusage's pricing table may lag a few weeks behind newly-released models. Re-run
with `--ccusage 'ccusage --no-offline'` to force fresh pricing from the API.

**"`ccusage`: command not found"** but you ran `npm install -g ccusage`.
Your shell may not have picked up the new PATH. Open a new terminal, or use
the npx fallback: `--ccusage 'npx -y ccusage@latest'`.

**"`python`: command not found"** — try `python3` instead. Modern macOS and
some Linux distros omit the `python` alias and only ship `python3`.

**"Python 3.9+ required"** — the script uses modern type-hint syntax. Any
Python 3.9+ should work; no pip dependencies needed (stdlib only).

**"No Claude Code transcripts found"** — you may not have used Claude Code in
the default 60-day window. Try `--since 2026-01-01` (or however far back your
usage goes) to widen.

**"Monthly projection looks low — I had vacation / PTO during the window."**
The `monthly_projection_usd` field is computed as `total_cost / calendar_days × 30`,
so days with zero spend (vacation, weekends, light periods) drag the average down.
For a vacation-corrected projection, divide `totals.cost_usd` by `active_days`
(both in the aggregate JSON) and multiply by 30 — that's `total / working_days × 30`,
which approximates demand on days you were actually using Claude Code. Or, narrow
the window with `--since` to start after any time off in the period.

**"`error: --until ... is before --since ...`"** — the window is inverted.
Swap the arguments.

## Background

This tool was built to support a team-subscription cost analysis: rather than
guessing per-developer Claude Code usage, capture each developer's actual
per-day, per-model, and per-5-hour-block spend, then compare against flat-rate
subscription tiers. It emits no transcript content — only aggregated cost and
token totals — so it's safe to share aggregates across a team without exposing
the work the developer was doing.
