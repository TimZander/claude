#!/usr/bin/env python3
"""Unit tests for scripts/claude-throttle-audit.py.

Functions tested in isolation: classify_event, extract_error_events, in_window,
date_from_http_headers, summarize_events.

Run directly:  python scripts/test_claude_throttle_audit_unit.py
Or via the smoke test, which runs these alongside the cost-report tests.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from datetime import datetime
from pathlib import Path


def _load_module():
    """Load claude-throttle-audit.py despite the hyphen in the filename."""
    script_path = Path(__file__).parent / "claude-throttle-audit.py"
    spec = importlib.util.spec_from_file_location("claude_throttle_audit", script_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["claude_throttle_audit"] = module
    spec.loader.exec_module(module)
    return module


cta = _load_module()


class ClassifyEventTests(unittest.TestCase):
    def test_classify_event_extra_usage_text_wins_over_status(self):
        # Arrange — 1M-context feature gate has status 429 but is not throttling
        const_text = "API Error: Extra usage is required for 1M context - run /extra-usage"
        const_status = 429
        # Act
        result = cta.classify_event(const_status, const_text)
        # Assert
        self.assertEqual(result, "extra_usage_required")

    def test_classify_event_server_per_second_throttle_distinguished_from_plan_cap(self):
        # Arrange — Anthropic explicitly disclaims plan cap in the error text
        const_text = "API Error: Server is temporarily limiting requests (not your usage limit)"
        const_status = 429
        # Act
        result = cta.classify_event(const_status, const_text)
        # Assert
        self.assertEqual(result, "server_per_second_throttle")

    def test_classify_event_anthropic_overload_by_status(self):
        # Arrange
        const_status = 529
        const_text = "API Error: 529 Overloaded"
        # Act
        result = cta.classify_event(const_status, const_text)
        # Assert
        self.assertEqual(result, "anthropic_overload")

    def test_classify_event_anthropic_overload_by_text_when_status_missing(self):
        # Arrange — text mentions overload but no status code attached
        const_status = None
        const_text = "API Error: Overloaded"
        # Act
        result = cta.classify_event(const_status, const_text)
        # Assert
        self.assertEqual(result, "anthropic_overload")

    def test_classify_event_server_error_by_status(self):
        # Arrange
        const_status = 500
        # Act
        result = cta.classify_event(const_status, "")
        # Assert
        self.assertEqual(result, "server_error")

    def test_classify_event_429_with_unrecognized_text_is_unspecified(self):
        # Arrange — bare 429 without Anthropic's specific phrasings
        const_status = 429
        const_text = "Some other error"
        # Act
        result = cta.classify_event(const_status, const_text)
        # Assert
        self.assertEqual(result, "rate_limit_unspecified")

    def test_classify_event_no_status_no_text_is_unclassified(self):
        # Arrange
        # Act / Assert
        self.assertEqual(cta.classify_event(None, ""), "unclassified")
        self.assertEqual(cta.classify_event(None, None), "unclassified")


class DateFromHttpHeadersTests(unittest.TestCase):
    def test_date_from_http_headers_valid_rfc7231_date_returns_iso(self):
        # Arrange
        const_headers = {"date": "Wed, 06 May 2026 15:24:50 GMT"}
        const_expected = "2026-05-06T15:24:50Z"
        # Act
        result = cta.date_from_http_headers(const_headers)
        # Assert
        self.assertEqual(result, const_expected)

    def test_date_from_http_headers_missing_date_returns_none(self):
        # Arrange
        const_headers: dict = {}
        # Act
        result = cta.date_from_http_headers(const_headers)
        # Assert
        self.assertIsNone(result)

    def test_date_from_http_headers_malformed_date_returns_none(self):
        # Arrange
        const_headers = {"date": "not a real date"}
        # Act
        result = cta.date_from_http_headers(const_headers)
        # Assert
        self.assertIsNone(result)


class ExtractErrorEventsTests(unittest.TestCase):
    def test_extract_error_events_invalid_json_returns_empty(self):
        # Arrange
        const_line = "{not valid json"
        # Act
        result = cta.extract_error_events(const_line)
        # Assert
        self.assertEqual(result, [])

    def test_extract_error_events_unrelated_line_returns_empty(self):
        # Arrange — normal user message, no error indicators
        obj = {"type": "user", "message": {"role": "user", "content": "hello"}}
        # Act
        result = cta.extract_error_events(json.dumps(obj))
        # Assert
        self.assertEqual(result, [])

    def test_extract_error_events_system_api_error_extracted(self):
        # Arrange — shape 1: system-level api_error log
        const_status = 529
        obj = {
            "type": "system", "subtype": "api_error", "level": "error",
            "error": {"status": const_status,
                      "headers": {"date": "Wed, 06 May 2026 15:24:50 GMT"}},
            "timestamp": "2026-05-06T15:24:50Z",
        }
        # Act
        events = cta.extract_error_events(json.dumps(obj))
        # Assert
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "api_error_system")
        self.assertEqual(events[0]["status"], const_status)
        self.assertEqual(events[0]["category"], "anthropic_overload")

    def test_extract_error_events_assistant_api_error_message_extracted(self):
        # Arrange — shape 2: assistant-message-level error
        const_status = 429
        const_text = "API Error: Server is temporarily limiting requests (not your usage limit)"
        obj = {
            "type": "assistant",
            "isApiErrorMessage": True,
            "apiErrorStatus": const_status,
            "error": "rate_limit",
            "timestamp": "2026-04-15T10:30:00Z",
            "message": {"content": [{"type": "text", "text": const_text}]},
        }
        # Act
        events = cta.extract_error_events(json.dumps(obj))
        # Assert
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "api_error_message")
        self.assertEqual(events[0]["status"], const_status)
        self.assertEqual(events[0]["error_type"], "rate_limit")
        self.assertEqual(events[0]["category"], "server_per_second_throttle")

    def test_extract_error_events_extra_usage_gate_classified_separately(self):
        # Arrange — same status (429) but feature-gate text, not throttling
        obj = {
            "type": "assistant",
            "isApiErrorMessage": True,
            "apiErrorStatus": 429,
            "error": "rate_limit",
            "timestamp": "2026-04-15T10:30:00Z",
            "message": {"content": [{
                "type": "text",
                "text": "API Error: Extra usage is required for 1M context",
            }]},
        }
        # Act
        events = cta.extract_error_events(json.dumps(obj))
        # Assert
        self.assertEqual(events[0]["category"], "extra_usage_required")

    def test_extract_error_events_malformed_error_field_skipped_safely(self):
        # Arrange — defensive: error field is a string instead of dict on shape 1
        obj = {"type": "system", "subtype": "api_error", "error": "rate_limit",
               "timestamp": "2026-04-15T10:30:00Z"}
        # Act — should not crash; shape 1 branch ignores non-dict error
        events = cta.extract_error_events(json.dumps(obj))
        # Assert
        self.assertEqual(events, [])


class InWindowTests(unittest.TestCase):
    def test_in_window_inside_returns_true(self):
        # Arrange
        const_ts = "2026-04-15T10:00:00Z"
        since_dt = datetime(2026, 4, 1)
        until_dt = datetime(2026, 4, 30)
        # Act / Assert
        self.assertTrue(cta.in_window(const_ts, since_dt, until_dt))

    def test_in_window_before_since_returns_false(self):
        # Arrange
        const_ts = "2026-03-31T23:00:00Z"
        since_dt = datetime(2026, 4, 1)
        until_dt = datetime(2026, 4, 30)
        # Act / Assert
        self.assertFalse(cta.in_window(const_ts, since_dt, until_dt))

    def test_in_window_at_until_returns_false(self):
        # Arrange — half-open interval, until is exclusive
        const_ts = "2026-04-30T00:00:00Z"
        since_dt = datetime(2026, 4, 1)
        until_dt = datetime(2026, 4, 30)
        # Act / Assert
        self.assertFalse(cta.in_window(const_ts, since_dt, until_dt))

    def test_in_window_missing_timestamp_returns_false(self):
        # Arrange
        since_dt = datetime(2026, 4, 1)
        until_dt = datetime(2026, 4, 30)
        # Act / Assert
        self.assertFalse(cta.in_window(None, since_dt, until_dt))
        self.assertFalse(cta.in_window("", since_dt, until_dt))

    def test_in_window_malformed_timestamp_returns_false(self):
        # Arrange
        const_ts = "not a real timestamp"
        since_dt = datetime(2026, 4, 1)
        until_dt = datetime(2026, 4, 30)
        # Act / Assert
        self.assertFalse(cta.in_window(const_ts, since_dt, until_dt))


class SummarizeEventsTests(unittest.TestCase):
    def test_summarize_events_empty_returns_zero_totals(self):
        # Arrange
        # Act
        result = cta.summarize_events([], "2026-04-01", "2026-04-30")
        # Assert
        self.assertEqual(result["total_events"], 0)
        self.assertEqual(result["by_kind"], {})
        self.assertEqual(result["by_status"], {})
        self.assertEqual(result["by_category"], {})

    def test_summarize_events_groups_by_category_and_month(self):
        # Arrange
        events = [
            {"kind": "api_error_message", "status": 429,
             "category": "server_per_second_throttle",
             "timestamp": "2026-04-15T10:00:00Z"},
            {"kind": "api_error_message", "status": 429,
             "category": "server_per_second_throttle",
             "timestamp": "2026-05-02T11:00:00Z"},
            {"kind": "api_error_system", "status": 529,
             "category": "anthropic_overload",
             "timestamp": "2026-05-06T15:00:00Z"},
        ]
        # Act
        result = cta.summarize_events(events, "2026-04-01", "2026-05-31")
        # Assert
        self.assertEqual(result["total_events"], 3)
        self.assertEqual(result["by_category"]["server_per_second_throttle"], 2)
        self.assertEqual(result["by_category"]["anthropic_overload"], 1)
        self.assertEqual(result["by_month"]["2026-04"]["server_per_second_throttle"], 1)
        self.assertEqual(result["by_month"]["2026-05"]["server_per_second_throttle"], 1)
        self.assertEqual(result["by_month"]["2026-05"]["anthropic_overload"], 1)

    def test_summarize_events_timeline_sorted_by_timestamp(self):
        # Arrange — out of order
        events = [
            {"kind": "api_error_message", "status": 529, "category": "anthropic_overload",
             "timestamp": "2026-05-06T15:00:00Z"},
            {"kind": "api_error_message", "status": 429,
             "category": "server_per_second_throttle",
             "timestamp": "2026-04-15T10:00:00Z"},
        ]
        # Act
        result = cta.summarize_events(events, "2026-04-01", "2026-05-31")
        # Assert
        timestamps = [e["timestamp"] for e in result["timeline"]]
        self.assertEqual(timestamps, sorted(timestamps))


if __name__ == "__main__":
    unittest.main()
