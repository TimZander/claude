# har-investigate

Analyze HAR files for API reverse engineering — endpoints, auth flows, sequencing, and schemas.

## What it does

When you provide a `.har` file, this plugin parses it with a bundled Python script and presents a structured analysis:

- **API Endpoints** — every unique endpoint grouped by domain, with full request/response detail
- **Authentication Flow** — traces tokens and session IDs from origin to consumption
- **Call Dependencies** — maps which responses feed into which subsequent requests
- **Observations** — flags errors, retries, rate limiting, and sensitive data

## Usage

Mention or provide a `.har` file in conversation. The plugin triggers automatically.

To focus on a specific API domain when the capture contains mixed traffic:

> Analyze network.har, filtering to api.example.com

## Requirements

- Python 3
