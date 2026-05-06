#!/usr/bin/env python3
"""Unit tests for scripts/claude-usage-report.py.

Functions tested in isolation: percentile, bucketize, summarize_daily,
summarize_blocks, to_yyyymmdd, parse_iso_date, sanitize_user, resolve_ccusage,
get_ccusage_version.

Run directly:  python scripts/test_claude_usage_report_unit.py
Or via the smoke test, which runs these as step 0.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
import unittest
from pathlib import Path


def _load_module():
    """Load claude-usage-report.py despite the hyphen in the filename."""
    script_path = Path(__file__).parent / "claude-usage-report.py"
    spec = importlib.util.spec_from_file_location("claude_usage_report", script_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["claude_usage_report"] = module
    spec.loader.exec_module(module)
    return module


cur = _load_module()


class PercentileTests(unittest.TestCase):
    def test_percentile_empty_list_returns_zero(self):
        # Arrange
        values: list[float] = []
        const_pct = 50.0
        # Act
        result = cur.percentile(values, const_pct)
        # Assert
        self.assertEqual(result, 0.0)

    def test_percentile_single_element_returns_that_element_for_any_pct(self):
        # Arrange
        const_only = 42.0
        values = [const_only]
        # Act / Assert
        self.assertEqual(cur.percentile(values, 0), const_only)
        self.assertEqual(cur.percentile(values, 50), const_only)
        self.assertEqual(cur.percentile(values, 100), const_only)

    def test_percentile_ten_sorted_p50_returns_linear_median(self):
        # Arrange — n=10, k=(10-1)*0.5=4.5 → interpolate between sorted[4]=5 and sorted[5]=6
        values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        const_expected = 5.5
        # Act
        result = cur.percentile(values, 50)
        # Assert
        self.assertAlmostEqual(result, const_expected)

    def test_percentile_p0_and_p100_return_min_and_max(self):
        # Arrange
        values = [3, 1, 4, 1, 5, 9, 2, 6]
        const_expected_min = 1
        const_expected_max = 9
        # Act / Assert
        self.assertEqual(cur.percentile(values, 0), const_expected_min)
        self.assertEqual(cur.percentile(values, 100), const_expected_max)

    def test_percentile_unsorted_input_produces_sorted_answer(self):
        # Arrange — sorted = [1,3,5,8,10], k=(5-1)*0.5=2.0, sorted[2]=5
        values = [10, 1, 5, 3, 8]
        const_expected = 5
        # Act
        result = cur.percentile(values, 50)
        # Assert
        self.assertEqual(result, const_expected)


class BucketizeTests(unittest.TestCase):
    def test_bucketize_empty_list_all_zero_counts(self):
        # Arrange / Act
        result = cur.bucketize([])
        # Assert
        self.assertTrue(all(count == 0 for count in result.values()))
        self.assertEqual(sum(result.values()), 0)

    def test_bucketize_boundary_values_land_in_expected_half_open_bucket(self):
        # Arrange — half-open intervals: [0,1) [1,5) [5,10) ... [500,inf)
        const_zero = 0.0
        const_one = 1.0
        const_five = 5.0
        const_500 = 500.0
        # Act
        result = cur.bucketize([const_zero, const_one, const_five, const_500])
        # Assert
        self.assertEqual(result["<$1"], 1)
        self.assertEqual(result["$1-5"], 1)
        self.assertEqual(result["$5-10"], 1)
        self.assertEqual(result["$500+"], 1)

    def test_bucketize_large_value_lands_in_top_bucket(self):
        # Arrange
        const_huge = 12345.0
        # Act
        result = cur.bucketize([const_huge])
        # Assert
        self.assertEqual(result["$500+"], 1)

    def test_bucketize_negative_value_clamped_to_bottom_bucket(self):
        # Arrange — defensive: ccusage shouldn't produce negatives
        const_negative = -5.0
        # Act
        result = cur.bucketize([const_negative])
        # Assert — clamped to 0, bucket totals still sum to input count
        self.assertEqual(result["<$1"], 1)
        self.assertEqual(sum(result.values()), 1)

    def test_bucketize_bucket_totals_equal_input_count(self):
        # Arrange
        costs = [0.5, 2.5, 7.0, 100.0, 250.0, 999.0]
        # Act
        result = cur.bucketize(costs)
        # Assert
        self.assertEqual(sum(result.values()), len(costs))


class ToYyyymmddTests(unittest.TestCase):
    def test_to_yyyymmdd_valid_date_returns_compact_form(self):
        # Arrange
        const_iso = "2026-05-06"
        const_expected = "20260506"
        # Act
        result = cur.to_yyyymmdd(const_iso)
        # Assert
        self.assertEqual(result, const_expected)

    def test_to_yyyymmdd_invalid_format_raises_value_error(self):
        # Arrange
        const_bad = "2026/05/06"
        # Act / Assert
        with self.assertRaises(ValueError):
            cur.to_yyyymmdd(const_bad)


class ParseIsoDateTests(unittest.TestCase):
    def test_parse_iso_date_valid_returns_string_unchanged(self):
        # Arrange
        const_iso = "2026-05-06"
        # Act
        result = cur.parse_iso_date(const_iso)
        # Assert
        self.assertEqual(result, const_iso)

    def test_parse_iso_date_invalid_format_raises_argparse_type_error(self):
        # Arrange
        const_bad = "may-6-2026"
        # Act / Assert
        with self.assertRaises(argparse.ArgumentTypeError):
            cur.parse_iso_date(const_bad)

    def test_parse_iso_date_invalid_calendar_date_raises_argparse_type_error(self):
        # Arrange — Feb 30 is a real format but not a real date
        const_bad = "2026-02-30"
        # Act / Assert
        with self.assertRaises(argparse.ArgumentTypeError):
            cur.parse_iso_date(const_bad)


class SanitizeUserTests(unittest.TestCase):
    def test_sanitize_user_path_separators_replaced(self):
        # Arrange
        const_traversal = "../foo/bar"
        # Act
        result = cur.sanitize_user(const_traversal)
        # Assert — no slashes, no dots, no parent-traversal substring
        self.assertNotIn("/", result)
        self.assertNotIn("\\", result)
        self.assertNotIn(".", result)
        self.assertNotIn("..", result)

    def test_sanitize_user_spaces_and_case_normalized(self):
        # Arrange
        const_input = "Tim Zander"
        const_expected = "tim_zander"
        # Act
        result = cur.sanitize_user(const_input)
        # Assert
        self.assertEqual(result, const_expected)

    def test_sanitize_user_only_unsafe_chars_falls_back_to_default(self):
        # Arrange — strips to nothing, should default to "user"
        const_input = "../"
        const_expected = "user"
        # Act
        result = cur.sanitize_user(const_input)
        # Assert
        self.assertEqual(result, const_expected)

    def test_sanitize_user_already_safe_passes_through(self):
        # Arrange
        const_input = "tzander"
        # Act
        result = cur.sanitize_user(const_input)
        # Assert
        self.assertEqual(result, const_input)


class ResolveCcusageTests(unittest.TestCase):
    def test_resolve_ccusage_empty_override_exits_with_error(self):
        # Arrange
        const_empty = ""
        # Act / Assert
        with self.assertRaises(SystemExit):
            cur.resolve_ccusage(const_empty)

    def test_resolve_ccusage_whitespace_override_exits_with_error(self):
        # Arrange
        const_whitespace = "   "
        # Act / Assert
        with self.assertRaises(SystemExit):
            cur.resolve_ccusage(const_whitespace)


class SummarizeDailyTests(unittest.TestCase):
    def test_summarize_daily_empty_data_returns_zero_valued_summary(self):
        # Arrange
        const_data: dict = {"daily": [], "totals": {}}
        const_since = "2026-04-01"
        const_until = "2026-04-30"
        const_expected_days = 30
        # Act
        result = cur.summarize_daily(const_data, const_since, const_until)
        # Assert
        self.assertEqual(result["totals"]["cost_usd"], 0.0)
        self.assertEqual(result["active_days"], 0)
        self.assertEqual(result["window"]["days"], const_expected_days)
        self.assertEqual(result["per_model_cost_usd"], {})

    def test_summarize_daily_single_day_produces_correct_aggregate(self):
        # Arrange
        const_cost = 100.0
        const_opus_cost = 90.0
        const_haiku_cost = 10.0
        const_data = {
            "daily": [{
                "date": "2026-04-01",
                "totalCost": const_cost,
                "modelBreakdowns": [
                    {"modelName": "claude-opus-4-7", "cost": const_opus_cost},
                    {"modelName": "claude-haiku-4-5", "cost": const_haiku_cost},
                ],
            }],
            "totals": {
                "totalCost": const_cost,
                "inputTokens": 1000, "outputTokens": 500,
                "cacheCreationTokens": 100, "cacheReadTokens": 5000,
            },
        }
        # Act
        result = cur.summarize_daily(const_data, "2026-04-01", "2026-04-01")
        # Assert
        self.assertEqual(result["totals"]["cost_usd"], const_cost)
        self.assertEqual(result["active_days"], 1)
        self.assertEqual(result["window"]["days"], 1)
        self.assertEqual(result["per_model_cost_usd"]["claude-opus-4-7"], const_opus_cost)
        self.assertEqual(result["per_model_cost_usd"]["claude-haiku-4-5"], const_haiku_cost)
        self.assertEqual(result["daily_timeline"],
                         [{"date": "2026-04-01", "cost_usd": const_cost}])

    def test_summarize_daily_null_cost_fields_treated_as_zero(self):
        # Arrange — defensive against schema drift; ccusage today doesn't emit nulls.
        const_data = {
            "daily": [{"date": "2026-04-01", "totalCost": None, "modelBreakdowns": None}],
            "totals": {"totalCost": None, "inputTokens": None},
        }
        # Act
        result = cur.summarize_daily(const_data, "2026-04-01", "2026-04-01")
        # Assert — no crash; nulls treated as zero
        self.assertEqual(result["totals"]["cost_usd"], 0.0)
        self.assertEqual(result["totals"]["input_tokens"], 0)
        self.assertEqual(result["daily_stats"]["min"], 0.0)

    def test_summarize_daily_aggregates_same_model_across_days(self):
        # Arrange — same model reported on two days; per_model_cost_usd should sum them
        const_data = {
            "daily": [
                {"date": "2026-04-01", "totalCost": 50.0,
                 "modelBreakdowns": [{"modelName": "claude-opus-4-7", "cost": 50.0}]},
                {"date": "2026-04-02", "totalCost": 30.0,
                 "modelBreakdowns": [{"modelName": "claude-opus-4-7", "cost": 30.0}]},
            ],
            "totals": {"totalCost": 80.0},
        }
        const_expected_opus_total = 80.0
        # Act
        result = cur.summarize_daily(const_data, "2026-04-01", "2026-04-02")
        # Assert
        self.assertEqual(result["per_model_cost_usd"]["claude-opus-4-7"],
                         const_expected_opus_total)

    def test_summarize_daily_monthly_projection_is_avg_times_thirty(self):
        # Arrange — 5-day window, $50 total → avg=$10/day → projection=$300
        const_data = {
            "daily": [{"date": "2026-04-01", "totalCost": 50.0, "modelBreakdowns": []}],
            "totals": {"totalCost": 50.0},
        }
        const_expected_projection = 300.0
        # Act — 5-day window: 04-01 to 04-05 inclusive
        result = cur.summarize_daily(const_data, "2026-04-01", "2026-04-05")
        # Assert
        self.assertEqual(result["window"]["days"], 5)
        self.assertEqual(result["monthly_projection_usd"], const_expected_projection)


class SummarizeBlocksTests(unittest.TestCase):
    def test_summarize_blocks_empty_blocks_returns_zero_valued_summary(self):
        # Arrange
        const_data = {"blocks": []}
        # Act
        result = cur.summarize_blocks(const_data)
        # Assert
        self.assertEqual(result["total_blocks"], 0)
        self.assertEqual(result["max_block_usd"], 0.0)
        self.assertEqual(result["mean_block_usd"], 0.0)

    def test_summarize_blocks_gap_blocks_filtered_out(self):
        # Arrange
        const_real_low = 10.0
        const_gap = 20.0
        const_real_high = 30.0
        const_data = {"blocks": [
            {"costUSD": const_real_low, "isGap": False},
            {"costUSD": const_gap, "isGap": True},
            {"costUSD": const_real_high, "isGap": False},
        ]}
        # Act
        result = cur.summarize_blocks(const_data)
        # Assert
        self.assertEqual(result["total_blocks"], 2)
        self.assertEqual(result["max_block_usd"], const_real_high)

    def test_summarize_blocks_single_block_all_percentiles_equal(self):
        # Arrange
        const_cost = 50.0
        const_data = {"blocks": [{"costUSD": const_cost, "isGap": False}]}
        # Act
        result = cur.summarize_blocks(const_data)
        # Assert
        for key in ("p50", "p75", "p90", "p95", "p99"):
            self.assertEqual(result["percentiles_usd"][key], const_cost)

    def test_summarize_blocks_null_cost_treated_as_zero(self):
        # Arrange
        const_data = {"blocks": [{"costUSD": None, "isGap": False}]}
        # Act
        result = cur.summarize_blocks(const_data)
        # Assert — no crash; null becomes 0, lands in <$1 bucket
        self.assertEqual(result["total_blocks"], 1)
        self.assertEqual(result["buckets"]["<$1"], 1)


if __name__ == "__main__":
    unittest.main()
