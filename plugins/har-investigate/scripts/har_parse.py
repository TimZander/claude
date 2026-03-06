#!/usr/bin/env python3
"""
HAR file parser for API reverse engineering.

Outputs every request/response in chronological order with full detail,
plus dependency analysis showing which response values flow into later requests.

Usage:
    python3 har_parse.py <path_to_har_file>
    python3 har_parse.py <path_to_har_file> --filter <domain_substring>
"""

import json
import sys
from collections import defaultdict
from urllib.parse import urlparse, parse_qs


_SKIP_TYPE_PREFIXES = ("image/", "font/", "audio/", "video/")
_SKIP_MIME_TYPES = frozenset([
    "text/css", "text/html",
    "application/javascript", "text/javascript",
    "application/wasm", "application/octet-stream",
])


def _is_static_asset(entry):
    """Return True for entries that are clearly not API calls."""
    mime = entry.get("response", {}).get("content", {}).get("mimeType", "")
    if not mime:
        return False
    mime = mime.lower().split(";")[0].strip()
    if mime.startswith(_SKIP_TYPE_PREFIXES):
        return True
    return mime in _SKIP_MIME_TYPES


def load_har(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return json.load(f)


def parse_entries(har):
    log = har.get("log", har)
    return log.get("entries", [])


def parse_body(text, max_length=5000):
    """Parse body text, returning structured JSON if possible, truncated text otherwise."""
    if not text:
        return None
    text = text.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        pass
    if len(text) > max_length:
        return text[:max_length] + f"\n... truncated ({len(text)} chars total)"
    return text


def headers_to_dict(headers):
    """Convert HAR header list to a dict. Duplicate keys get list values."""
    result = {}
    for h in headers:
        name = h.get("name")
        value = h.get("value")
        if name is None or value is None:
            continue
        if name in result:
            existing = result[name]
            if isinstance(existing, list):
                existing.append(value)
            else:
                result[name] = [existing, value]
        else:
            result[name] = value
    return result


def extract_string_values(obj, min_length=16, max_depth=6, _depth=0):
    """Recursively extract string values from a JSON object that look like tokens/IDs."""
    values = set()
    if _depth > max_depth:
        return values
    if isinstance(obj, dict):
        for key, val in obj.items():
            values.update(extract_string_values(val, min_length, max_depth, _depth + 1))
    elif isinstance(obj, list):
        for item in obj[:50]:  # cap list traversal
            values.update(extract_string_values(item, min_length, max_depth, _depth + 1))
    elif isinstance(obj, str) and len(obj) >= min_length:
        # Skip values that are clearly not tokens/IDs (keep URLs — they are common dependencies)
        if not obj.startswith("<") and len(obj) <= 4000:
            values.add(obj)
    return values


def find_value_in_request(value, req_url, req_headers, req_body_text):
    """Check if a value appears in a subsequent request. Returns where it was found."""
    locations = []
    if value in req_url:
        locations.append("url")
    for h_name, h_val in req_headers.items():
        h_val_str = h_val if isinstance(h_val, str) else json.dumps(h_val)
        if value in h_val_str:
            locations.append(f"header:{h_name}")
    if req_body_text and value in req_body_text:
        locations.append("body")
    return locations


def analyze_har(har_data, domain_filter=None):
    entries = parse_entries(har_data)
    if not entries:
        return {"error": "No entries found in HAR file"}

    # Sort by startedDateTime if present (HAR spec doesn't guarantee array order)
    entries.sort(key=lambda e: e.get("startedDateTime", ""))

    # Filter by domain if requested
    if domain_filter:
        entries = [
            e for e in entries
            if domain_filter.lower() in e.get("request", {}).get("url", "").lower()
        ]
        if not entries:
            return {"error": f"No entries match filter '{domain_filter}'"}

    # Skip static assets (images, CSS, JS, fonts) — irrelevant for API analysis
    total_before_filter = len(entries)
    entries = [e for e in entries if not _is_static_asset(e)]
    skipped_static = total_before_filter - len(entries)

    # -- Build per-call detail --
    calls = []
    # Track response values for dependency detection
    # Each item: (call_index, key_path, value)
    response_values = []

    for i, entry in enumerate(entries):
        req = entry.get("request", {})
        resp = entry.get("response", {})

        method = req.get("method", "UNKNOWN")
        url = req.get("url", "")
        parsed_url = urlparse(url)

        # Request
        req_headers = headers_to_dict(req.get("headers", []))
        query_params = parse_qs(parsed_url.query, keep_blank_values=True)
        # Flatten single-value lists
        query_params = {
            k: v[0] if len(v) == 1 else v
            for k, v in query_params.items()
        }

        post_data = req.get("postData") or {}
        req_body_text = post_data.get("text", "")
        if not req_body_text and post_data.get("params"):
            # Fall back to params list when text is absent (form-encoded data)
            req_body_text = "&".join(
                f"{p.get('name', '')}={p.get('value', '')}"
                for p in post_data["params"]
            )
        req_body = parse_body(req_body_text)
        req_mime = post_data.get("mimeType", None)

        # Response
        status = resp.get("status", 0)
        status_text = resp.get("statusText", "")
        resp_headers = headers_to_dict(resp.get("headers", []))
        resp_content = resp.get("content", {})
        resp_body_text = resp_content.get("text", "")
        resp_body = parse_body(resp_body_text)
        resp_mime = resp_content.get("mimeType", "")

        # Timing
        time_ms = entry.get("time")

        call = {
            "index": i,
            "method": method,
            "url": f"{parsed_url.scheme}://{parsed_url.netloc}{parsed_url.path}",
            "request": {
                "headers": req_headers,
            },
            "response": {
                "status": status,
                "status_text": status_text,
                "headers": resp_headers,
            },
        }

        if query_params:
            call["request"]["query_params"] = query_params
        if req_body is not None:
            call["request"]["body"] = req_body
        if req_mime:
            call["request"]["content_type"] = req_mime

        if resp_body is not None:
            call["response"]["body"] = resp_body
        if resp_mime:
            call["response"]["content_type"] = resp_mime
        if time_ms is not None:
            call["time_ms"] = round(time_ms, 1)

        calls.append(call)

        # Collect response values for dependency tracking
        if isinstance(resp_body, dict):
            for key, val in resp_body.items():
                for sv in extract_string_values(val):
                    response_values.append((i, key, sv))
        elif isinstance(resp_body, list):
            for sv in extract_string_values(resp_body):
                response_values.append((i, "response_body[]", sv))
        elif isinstance(resp_body, str) and len(resp_body) >= 16:
            response_values.append((i, "response_body", resp_body))
        # Also check Set-Cookie and Location headers (case-insensitive lookup)
        resp_headers_lower = {k.lower(): (k, v) for k, v in resp_headers.items()}
        for h_name in ("set-cookie", "location", "x-request-id"):
            if h_name in resp_headers_lower:
                original_name, val = resp_headers_lower[h_name]
                vals = val if isinstance(val, list) else [val]
                for v in vals:
                    if isinstance(v, str) and len(v) >= 8:
                        response_values.append((i, f"response_header:{original_name}", v))

    # Pre-compute searchable request data per call to avoid repeated serialization
    call_request_data = []
    for c in calls:
        req = c.get("request", {})
        url = c.get("url", "")
        headers = req.get("headers", {})
        body_raw = ""
        if "body" in req:
            body = req["body"]
            body_raw = body if isinstance(body, str) else json.dumps(body)
        header_vals = [
            h_val if isinstance(h_val, str) else json.dumps(h_val)
            for h_val in headers.values()
        ]
        searchable = "\0".join([url] + header_vals + [body_raw])
        call_request_data.append((url, headers, body_raw, searchable))

    # -- Dependency detection --
    _DEP_ITERATION_THRESHOLD = 5_000_000
    estimated_iterations = len(response_values) * len(calls)
    if estimated_iterations > _DEP_ITERATION_THRESHOLD:
        print(
            f"Warning: dependency detection is scanning ~{estimated_iterations:,} pairs "
            f"({len(response_values)} response values × {len(calls)} calls). "
            "This may be slow. Use --filter to narrow to a specific domain.",
            file=sys.stderr,
        )

    dependencies = []
    seen_deps = set()

    for resp_idx, resp_key, resp_value in response_values:
        for later_idx in range(resp_idx + 1, len(calls)):
            url, headers, body_raw, searchable = call_request_data[later_idx]
            if resp_value not in searchable:
                continue
            locations = find_value_in_request(resp_value, url, headers, body_raw)
            if locations:
                dep_key = (resp_idx, later_idx, resp_key, resp_value)
                if dep_key not in seen_deps:
                    seen_deps.add(dep_key)
                    dependencies.append({
                        "from_call": resp_idx,
                        "from_field": resp_key,
                        "to_call": later_idx,
                        "used_in": locations,
                        "value_preview": resp_value[:80] + "..." if len(resp_value) > 80 else resp_value,
                    })

    # -- Summary --
    domains = set()
    methods = defaultdict(int)
    status_counts = defaultdict(int)
    for c in calls:
        parsed = urlparse(c["url"])
        domains.add(parsed.netloc)
        methods[c["method"]] += 1
        status_counts[c["response"]["status"]] += 1

    summary = {
        "total_requests": len(calls),
        "domains": sorted(domains),
        "methods": dict(methods),
        "status_codes": dict(sorted(status_counts.items(), key=lambda x: x[0])),
    }
    if skipped_static:
        summary["skipped_static_assets"] = skipped_static

    output = {
        "summary": summary,
        "calls": calls,
    }

    if dependencies:
        output["dependencies"] = dependencies

    return output


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <har_file> [--filter <domain_substring>]", file=sys.stderr)
        sys.exit(1)

    har_path = sys.argv[1]
    domain_filter = None
    if len(sys.argv) > 2:
        if sys.argv[2] == "--filter":
            if len(sys.argv) < 4:
                print("Error: --filter requires a domain substring argument", file=sys.stderr)
                sys.exit(1)
            domain_filter = sys.argv[3]
        else:
            print(f"Error: Unknown argument: {sys.argv[2]}", file=sys.stderr)
            sys.exit(1)

    try:
        har_data = load_har(har_path)
    except FileNotFoundError:
        print(f"Error: File not found: {har_path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in HAR file: {e}", file=sys.stderr)
        sys.exit(1)

    result = analyze_har(har_data, domain_filter)
    json.dump(result, sys.stdout, indent=2, default=str)
    print()


if __name__ == "__main__":
    main()
