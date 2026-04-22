# investigate-polling-incident

Run the standard Azure Functions polling-incident workflow: resolve the *active* Application Insights resource, execute every KQL query discoverable in the repo, optionally correlate a device log, and emit a single UTC timeline with publish-window annotations.

## What it does

Invoke as `/investigate-polling-incident --time-window 6h` (or any duration / ISO range). The skill:

1. **Resolves the active App Insights ID** from the Function App's `APPLICATIONINSIGHTS_CONNECTION_STRING` — never via `az resource list` (which is a documented gotcha that can return an inactive resource).
2. **Discovers queries** in the current repo: every `*.kql` file, plus every ` ```kql ` fenced block in `*.md` files.
3. **Runs the queries in parallel** against the resolved App Insights, scoped to `--time-window`.
4. **Correlates a device log** (if `--device-log-path` is given) by delegating parsing to a sub-agent, so the full log never enters the main conversation context.
5. **Emits a UTC timeline** with server + device events, annotating events within tolerance of configured publish windows (e.g., data-provider release times).

## Per-repo config

Drop a `.claude/investigate-polling-incident.json` in the repo root to avoid passing flags every time. All keys are optional:

```json
{
  "functionApp": "my-func-app",
  "resourceGroup": "my-rg",
  "subscription": "00000000-0000-0000-0000-000000000000",
  "healthUrl": "https://my-func-app.azurewebsites.net/api/health",
  "publishWindows": [
    { "name": "ProviderA", "utcTime": "22:30", "toleranceMinutes": 15 },
    { "name": "ProviderB", "utcTime": "23:00", "toleranceMinutes": 15 }
  ],
  "excludedAppInsightsIds": [
    "00000000-0000-0000-0000-000000000000"
  ],
  "deviceLogEventPatterns": [
    { "name": "FCM receipt",       "pattern": "FCM.*received" },
    { "name": "Cache commit",      "pattern": "CACHE.*commit" },
    { "name": "Validator warning", "pattern": "VALIDATOR.*WARN" }
  ]
}
```

CLI flags override config. Notes:

- `toleranceMinutes` defaults to **15** if omitted on a `publishWindows` entry; must be a non-negative integer.
- `excludedAppInsightsIds` entries are compared case-insensitively; case/whitespace in the config file does not matter.
- `deviceLogEventPatterns` is **required** when `--device-log-path` is passed. Each entry is `{ "name": "<label>", "pattern": "<regex>" }`; the pattern is a Python regex applied case-insensitively, and `name` becomes the event's `kind` in the timeline.
- The config file is discovered by walking upward from the current working directory until `$HOME` (inclusive). This lets you invoke the skill from a subdirectory of the target repo.

## Arguments

- `--time-window <dur>` (required): `az monitor app-insights query --offset` duration form like `6h`, `24h`, `7d`, `1h30m`; or an explicit ISO `<start>/<end>` UTC range. ISO 8601 duration forms (`PT6H`, `P7D`) are **not** accepted by the Azure CLI — use the `##d##h[##m]` form.
- `--device-log-path <path>`: optional path to a pasted/scratch device log.
- `--function-app`, `--resource-group`, `--subscription`: Azure target (may come from config).
- `--health-url`: one-shot snapshot URL (may come from config).
- `--queries <glob>`: restrict query discovery to matching paths.

## Time-window template substitution

If a discovered query contains the literal token `{{TIMEWINDOW}}`, it is replaced with the raw `--time-window` value before submission. This lets queries opt into parameterization without requiring it:

```kql
traces
| where timestamp > ago({{TIMEWINDOW}})
| where message has "Poll"
```

Queries without the token run as-written, and the `--time-window` is still applied as the `az monitor app-insights query` scope.

## Safety rails

- The skill refuses to query any App Insights Application ID listed in `excludedAppInsightsIds`. Use this to mark known-inactive resources that previously caused misleading empty-result queries.
- The skill never calls `az resource list` to discover App Insights.
- The full device log is never pulled into main context — correlation happens in a delegated sub-agent.

## Requirements

- `az` CLI, logged in (`az login`) with access to the target subscription
- Python 3 on PATH (stdlib only — no external packages)
- `bash`, `curl` (for the optional health snapshot)
