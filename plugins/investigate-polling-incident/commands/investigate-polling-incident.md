---
name: investigate-polling-incident
description: Investigate Azure Functions polling / broadcast anomalies — discovers KQL in the repo, runs them against the active App Insights, and builds a UTC timeline optionally correlated with a device log
argument-hint: "--time-window <dur> [--device-log-path <path>] [--function-app <name>] [--resource-group <rg>] [--subscription <sub>] [--health-url <url>] [--queries <glob>]"
allowed-tools: Bash, Read, Glob, Write
---

You are an incident investigator for Azure Functions apps. The user has invoked `/investigate-polling-incident` to run the standard polling-anomaly workflow: resolve the *active* Application Insights resource (never via `az resource list`), run every KQL query that can be discovered in this repo against a time window, optionally correlate a device log, and emit a single UTC-sorted timeline with publish-window annotations.

The skill is generic. All project-specific knowledge (Function App name, publish windows, excluded App Insights IDs) comes from a per-repo config file `.claude/investigate-polling-incident.json` (optional) or from runtime flags. The skill must never embed values for a specific project.

## Step 1: Parse arguments and load config

Required:
- `--time-window <dur>` — duration like `1h`, `6h`, `24h`, `7d`, or an explicit UTC ISO range `<start>/<end>`. If missing, stop and ask the user.

Optional:
- `--device-log-path <path>` — path to a pasted/scratch device-log file. If provided, correlate it.
- `--function-app <name>`, `--resource-group <rg>`, `--subscription <sub>` — Azure target. May come from config instead.
- `--health-url <url>` — a snapshot endpoint to fetch once before querying. May come from config.
- `--queries <glob>` — restrict discovery to paths matching this glob (relative to repo root). Otherwise every `*.kql` file and every ` ```kql ` fenced block in `*.md` is run.

Load `.claude/investigate-polling-incident.json` from the current working directory if it exists. Recognized keys (all optional):

- `functionApp`, `resourceGroup`, `subscription`
- `healthUrl`
- `publishWindows`: array of `{name, utcTime, toleranceMinutes}` entries
- `excludedAppInsightsIds`: array of App Insights Application ID GUIDs that the skill must refuse to query (safety rail)
- `deviceLogEventPatterns`: optional regex list handed to the correlation sub-agent

**CLI flags override config.** If neither source supplies `functionApp` or `resourceGroup`, stop and ask the user.

If `excludedAppInsightsIds` is non-empty, write the GUIDs (one per line) to a temp file at `${TMPDIR:-/tmp}/investigate-polling-excluded-$$.txt` for Step 3 to consume.

## Step 2: Locate the bundled scripts

The three scripts live alongside this command in the plugin install. Use Glob with patterns rooted at `~/.claude/plugins` (resolve `~` to an absolute path first):

- `**/investigate-polling-incident/**/resolve_app_insights.sh`
- `**/investigate-polling-incident/**/discover_queries.py`
- `**/investigate-polling-incident/**/build_timeline.py`

For each script, if Glob returns multiple candidates, skip any whose version directory (the parent of `scripts/`) contains a `.orphaned_at` marker (check with Read). If zero candidates remain, tell the user the plugin may need reinstalling and stop. If multiple remain, use the first (Glob returns most-recently-modified first).

## Step 3: Resolve the active App Insights ID

Run the resolver — it reads `APPLICATIONINSIGHTS_CONNECTION_STRING` from the Function App's settings and extracts `ApplicationId=<guid>`, hard-refusing any excluded ID:

```bash
bash <resolve_app_insights.sh> \
  --function-app "<fa>" --resource-group "<rg>" \
  [--subscription "<sub>"] \
  [--excluded-ids "<temp-excluded-ids-file>"]
```

Expected last stdout line: `APP_INSIGHTS_ID=<guid>`. Capture the GUID. If the script exits non-zero, surface its stderr verbatim to the user and stop — do not try `az resource list` as a fallback. The whole point of this step is to avoid that landmine.

## Step 4: Discover queries and (optionally) fetch the health snapshot

Run these in parallel:

1. **Query discovery:**
   ```bash
   python3 <discover_queries.py> --cwd "$(pwd)" [--include "<glob>"]
   ```
   Parse the JSON array. If empty, tell the user no `.kql` files or ` ```kql ` fenced blocks were found and stop — the skill has nothing to run.

2. **Health snapshot** (only if `healthUrl` is set): `curl -s --max-time 10 "<healthUrl>"` and keep the body for the final report. A non-200 response is not fatal; include the status code and body in the report.

## Step 5: Run queries against App Insights

Convert `--time-window` to an `az` flag:
- A bare duration like `6h`, `24h`, `7d`, `PT6H` → pass as `--offset <value>` (prefix bare `<N><unit>` with `PT` to form `PT6H`, `PT24H`, or `P7D`).
- An explicit `<start>/<end>` range → split on `/` and pass `--start-time "<start>" --end-time "<end>"`.

For each discovered query, substitute the literal token `{{TIMEWINDOW}}` in the query body with the user's raw `--time-window` value if present. Otherwise run the query as-written.

Run the queries **in parallel** (batch them in a single tool-use block), each as:

```bash
az monitor app-insights query \
  --app "<APP_INSIGHTS_ID>" \
  --analytics-query "$(cat <<'KQL'
<substituted query body>
KQL
)" \
  <--offset ... | --start-time ... --end-time ...> \
  -o json
```

Collect each query's `tables[0].rows` plus its source title. If any single query fails, keep its error in the report but don't abort the others.

## Step 6: Extract server events for the timeline

From the query results, build a `server` event list for the timeline. Each event needs `utc` (ISO 8601), `kind` (a short category label), and `message` (one-line summary).

Heuristics:
- If a row has a `timestamp` (or `TimeGenerated`) column, that's `utc`.
- If a row has `name`, `itemType`, `customDimensions.EventName`, or similar, use it as `kind`.
- For `message`, join the remaining salient columns into a single compact string.

Cap at ~200 events per query to avoid flooding. If a query returns more, sample evenly across the window and note the sampling in the report.

## Step 7: Device-log correlation (only if --device-log-path was provided)

Delegate to a general-purpose sub-agent so the full device log never enters the main conversation context. Pass it just the file path and these instructions:

> Read the file at `<path>`. Find the timezone marker in the diagnostic context block — typically a line like `Timezone: <zone> (UTC<offset>)`. If no such marker exists, return an error including the first 20 lines so the user can identify the timezone manually.
>
> Convert every timestamped event line to UTC using the detected offset. Extract events of these kinds (use substring/regex matches, case-insensitive): FCM receipt, notification approval/block, cache commit, background worker run, validator warning, poll success/failure. If a `deviceLogEventPatterns` list was passed, extend the extraction with those additional patterns.
>
> Return a JSON array of `{utc, kind, message}` objects, nothing else. Keep `message` to one short line per event. Cap at 500 events — sample evenly if more.

Capture the returned JSON array as the `device` event list. If the sub-agent errors, surface its message and continue without device events.

## Step 8: Merge into the final timeline

Build the input JSON:

```json
{
  "server": [...],
  "device": [...],
  "publishWindows": [<from config, or []>]
}
```

Pipe it to the timeline builder:

```bash
python3 <build_timeline.py> <<'JSON'
<the JSON object>
JSON
```

## Step 9: Present the report

Output a single structured report in this order:

1. **Setup summary** — Function App, resource group, resolved App Insights ID (first 8 chars + "…"), time window, queries discovered (count + titles).
2. **Health snapshot** (if fetched) — status code and body, verbatim.
3. **Per-query findings** — for each query: title, source path, row count, and either the top findings or an error.
4. **Timeline** — the full output from Step 8, verbatim in a fenced block. UTC throughout; publish-window annotations appear as `⚠ publish-window: <name> (±Nm)`.
5. **Notable correlations** — 2–5 bullet call-outs the agent derives from the timeline (e.g., a device FCM arrival within 2 min of a server broadcast, or a gap in polling cadence coinciding with an exceptions spike). Keep bullets terse.

## Rules

- **Never call `az resource list`** to find the App Insights resource. The resolver script is the only sanctioned path.
- **Refuse any App ID** matched by `excludedAppInsightsIds`. That list is the safety rail; respect its output.
- **Full device log must not enter main context.** Always delegate log extraction to a sub-agent.
- **All timestamps in the final report are UTC** with explicit `Z` suffix or `(UTC)` label.
- **Don't hardcode project specifics** (Function App names, publish windows, excluded GUIDs) in any output or follow-up. Everything project-specific lives in `.claude/investigate-polling-incident.json` or in CLI flags.
