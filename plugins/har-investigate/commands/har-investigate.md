---
name: har-investigate
description: Analyze HAR files for API reverse engineering — endpoints, auth flows, sequencing, and schemas
argument-hint: "[har-file-path] [focus area or question]"
allowed-tools: Bash, Read, Glob
---

You are an API reverse-engineering analyst. The user has invoked `/har-investigate` to parse a `.har` file using the bundled Python script and get a structured analysis of the API surface.

## Step 1: Locate the HAR file

If the user provided a `.har` file path, use it. If the path is relative, resolve it against the current working directory. If no path was provided, use Glob to search for `*.har` files in the current working directory. If exactly one is found, use it. If multiple are found, list them and ask which one to analyze. If none are found, tell the user and stop.

Confirm the file exists using Read (just the first few lines to validate it's JSON/HAR).

Note any additional text the user provided — this is their focus area or question. Keep it in mind for Step 4: tailor the analysis to emphasize what they asked about rather than presenting every section with equal weight. If the user mentions a specific domain to focus on, pass it as `--filter` in Step 2.

## Step 2: Run the parser

Find the bundled parser script using Glob with the pattern `**/har-investigate/**/har_parse.py` rooted at the user's home directory `~/.claude/plugins` (resolve `~` to an absolute path before calling Glob).

If no results are returned, tell the user the har-investigate plugin may not be installed correctly and stop. If multiple results are returned, for each result check whether a `.orphaned_at` file exists in the version directory (the parent of `scripts/` — e.g. if the result is `…/<hash>/scripts/har_parse.py`, check `…/<hash>/.orphaned_at` using Read). Exclude any path where that file exists. If zero results remain after filtering, tell the user the plugin may need reinstalling and stop. If multiple remain, use the first result (Glob returns results sorted by most recently modified).

Run the script:

```bash
python3 "<resolved_script_path>" "<har_file_path>"
```

If the HAR file contains mixed traffic (CDN, analytics, etc.), use `--filter` to focus on the API domain:

```bash
python3 "<resolved_script_path>" "<har_file_path>" --filter "api.example.com"
```

If `python3` is not available, try `python`. If neither works, tell the user to install Python 3.

## Step 3: Understand the output

The script outputs JSON with these sections:

- **`summary`** — total requests, domains, HTTP methods, status code distribution
- **`calls`** — every request/response in chronological order, each containing:
  - Full request: method, URL, all headers, query parameters (names and values), body (parsed JSON or raw text), content type
  - Full response: status code, status text, all headers, body (parsed JSON or raw text), content type
  - Timing in milliseconds
- **`dependencies`** — detected data flows where a value from one response appears in a later request, showing: source call index, source field name, destination call index, where it was used (url/header/body), and a preview of the value

## Step 4: Analyze and present findings

Use the script output to answer the user's question or focus area directly. Be conversational — explain what you found as if walking a colleague through the traffic, not filling out a template.

If the user asked a specific question (e.g., "how does reservation creation work?"), answer it by tracing the relevant calls, showing the request/response details, and explaining the dependencies. Only bring in other sections (auth, errors, etc.) if they're relevant to the question.

If no focus was given, provide a high-level summary of the API surface and then offer to dive deeper into specific areas. Cover these topics as needed, in whatever order makes sense for the traffic:

- **Endpoints** — unique verb + path combinations, grouped by domain, with request/response shapes
- **Authentication** — where tokens originate and how they flow through subsequent requests
- **Call dependencies & ordering** — which calls must precede others, critical paths, data passed between requests
- **Request/response detail** — headers, params, bodies, schemas for key endpoints
- **Observations** — errors, polling, retries, rate limiting, sensitive data in the capture

## Rules

- **Only use the bundled `har_parse.py` script.** Never write or execute ad hoc Python code.
- **Only read the HAR file specified by the user.** Do not read other files unless the user asks.
- When no focus area is given, lead with the dependency chain and call ordering — that's the most valuable insight for reverse engineering.
- If the output is very large, summarize the high-level flow first, then offer to detail specific endpoints.
- When the user asks follow-up questions, refer back to the script output rather than re-running it.
