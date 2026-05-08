#!/usr/bin/env python3
"""Unit tests for scripts/claude-skill-attribution.py.

Functions tested in isolation: canonicalize_model, parse_iso_date, sanitize_user,
percentile, turn_cost_usd, context_size, in_window, is_real_user_turn,
extract_tool_uses, walk_main_session (via tmp file), aggregate_per_skill,
aggregate_per_agent_type, main_vs_sidechain, top_turns.

Run directly: python scripts/test_claude_skill_attribution_unit.py
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


def _load_module():
    """Load claude-skill-attribution.py despite the hyphen in the filename."""
    script_path = Path(__file__).parent / "claude-skill-attribution.py"
    spec = importlib.util.spec_from_file_location("claude_skill_attribution", script_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["claude_skill_attribution"] = module
    spec.loader.exec_module(module)
    return module


csa = _load_module()


class CanonicalizeModelTests(unittest.TestCase):
    def test_canonicalize_model_strips_trailing_yyyymmdd(self):
        # Arrange
        const_dated = "claude-haiku-4-5-20251001"
        const_expected = "claude-haiku-4-5"
        # Act
        result = csa.canonicalize_model(const_dated)
        # Assert
        self.assertEqual(result, const_expected)

    def test_canonicalize_model_undated_passes_through(self):
        # Arrange
        const_input = "claude-opus-4-7"
        # Act
        result = csa.canonicalize_model(const_input)
        # Assert
        self.assertEqual(result, const_input)

    def test_canonicalize_model_empty_returns_empty(self):
        # Arrange / Act
        result = csa.canonicalize_model("")
        # Assert
        self.assertEqual(result, "")

    def test_canonicalize_model_partial_date_not_stripped(self):
        # Arrange — only a 6-digit suffix; canonical form should leave it alone
        const_input = "claude-foo-202510"
        # Act
        result = csa.canonicalize_model(const_input)
        # Assert
        self.assertEqual(result, const_input)


class ParseIsoDateTests(unittest.TestCase):
    def test_parse_iso_date_valid_returns_unchanged(self):
        # Arrange
        const_iso = "2026-05-07"
        # Act
        result = csa.parse_iso_date(const_iso)
        # Assert
        self.assertEqual(result, const_iso)

    def test_parse_iso_date_invalid_format_raises(self):
        # Arrange
        const_bad = "2026/05/07"
        # Act / Assert
        with self.assertRaises(argparse.ArgumentTypeError):
            csa.parse_iso_date(const_bad)


class SanitizeUserTests(unittest.TestCase):
    def test_sanitize_user_normalizes_case_and_spaces(self):
        # Arrange
        const_input = "Tim Zander"
        const_expected = "tim_zander"
        # Act
        result = csa.sanitize_user(const_input)
        # Assert
        self.assertEqual(result, const_expected)

    def test_sanitize_user_only_unsafe_falls_back_to_default(self):
        # Arrange
        const_input = "../"
        const_expected = "user"
        # Act
        result = csa.sanitize_user(const_input)
        # Assert
        self.assertEqual(result, const_expected)


class PercentileTests(unittest.TestCase):
    def test_percentile_empty_list_returns_zero(self):
        # Arrange / Act
        result = csa.percentile([], 50)
        # Assert
        self.assertEqual(result, 0.0)

    def test_percentile_p95_of_uniform_returns_max_for_small_n(self):
        # Arrange
        values = [1, 2, 3, 4, 5]
        const_expected = 4.8  # k=(5-1)*0.95=3.8 → interp(sorted[3]=4, sorted[4]=5)
        # Act
        result = csa.percentile(values, 95)
        # Assert
        self.assertAlmostEqual(result, const_expected)


class TurnCostUsdTests(unittest.TestCase):
    def test_turn_cost_unknown_model_recorded_and_zero(self):
        # Arrange
        const_unknown = "made-up-model"
        unknown: set[str] = set()
        usage = {"input_tokens": 1000, "output_tokens": 500}
        # Act
        cost = csa.turn_cost_usd(const_unknown, usage, unknown)
        # Assert
        self.assertEqual(cost, 0.0)
        self.assertIn(const_unknown, unknown)

    def test_turn_cost_opus_47_pure_input_output(self):
        # Arrange — Opus 4.5+ tier: 1M input ($5) + 1M output ($25) = $30
        const_million = 1_000_000
        const_expected = 30.0
        usage = {"input_tokens": const_million, "output_tokens": const_million}
        unknown: set[str] = set()
        # Act
        cost = csa.turn_cost_usd("claude-opus-4-7", usage, unknown)
        # Assert
        self.assertAlmostEqual(cost, const_expected, places=4)
        self.assertEqual(unknown, set())

    def test_turn_cost_opus_4_1_uses_old_higher_tier(self):
        # Arrange — Opus 4.1 stayed at $15/$75; verifies tiers don't bleed
        const_million = 1_000_000
        const_expected = 90.0
        usage = {"input_tokens": const_million, "output_tokens": const_million}
        unknown: set[str] = set()
        # Act
        cost = csa.turn_cost_usd("claude-opus-4-1", usage, unknown)
        # Assert
        self.assertAlmostEqual(cost, const_expected, places=4)

    def test_turn_cost_uses_breakdown_when_present(self):
        # Arrange — Opus 4.5+ tier: 1M of 1h cache creation at $10/MTok
        const_million = 1_000_000
        const_expected = 10.0
        usage = {
            "cache_creation_input_tokens": const_million,
            "cache_creation": {
                "ephemeral_5m_input_tokens": 0,
                "ephemeral_1h_input_tokens": const_million,
            },
        }
        unknown: set[str] = set()
        # Act
        cost = csa.turn_cost_usd("claude-opus-4-7", usage, unknown)
        # Assert
        self.assertAlmostEqual(cost, const_expected, places=4)

    def test_turn_cost_falls_back_to_5m_rate_when_breakdown_missing(self):
        # Arrange — older transcripts: only the rolled-up cache_creation_input_tokens.
        # Opus 4.5+ 5m rate: $6.25/MTok.
        const_million = 1_000_000
        const_expected = 6.25
        usage = {"cache_creation_input_tokens": const_million}
        unknown: set[str] = set()
        # Act
        cost = csa.turn_cost_usd("claude-opus-4-7", usage, unknown)
        # Assert
        self.assertAlmostEqual(cost, const_expected, places=4)

    def test_turn_cost_cache_read_at_discounted_rate(self):
        # Arrange — Opus 4.5+ cache_read at $0.50/MTok
        const_million = 1_000_000
        const_expected = 0.50
        usage = {"cache_read_input_tokens": const_million}
        unknown: set[str] = set()
        # Act
        cost = csa.turn_cost_usd("claude-opus-4-7", usage, unknown)
        # Assert
        self.assertAlmostEqual(cost, const_expected, places=4)

    def test_turn_cost_haiku_cheaper_than_opus(self):
        # Arrange — Opus 4.5+ input is $5/MTok, Haiku is $1/MTok → 5x ratio
        const_million = 1_000_000
        const_expected_ratio = 5.0
        usage = {"input_tokens": const_million, "output_tokens": 0}
        unknown: set[str] = set()
        # Act
        opus = csa.turn_cost_usd("claude-opus-4-7", usage, unknown)
        haiku = csa.turn_cost_usd("claude-haiku-4-5", usage, unknown)
        # Assert
        self.assertAlmostEqual(opus / haiku, const_expected_ratio, places=4)


class ContextSizeTests(unittest.TestCase):
    def test_context_size_sums_input_and_cache_tokens(self):
        # Arrange — input + cache_read + cache_creation, output excluded
        const_input = 100
        const_cache_read = 5000
        const_cache_create = 200
        const_output_excluded = 999_999
        usage = {
            "input_tokens": const_input,
            "cache_read_input_tokens": const_cache_read,
            "cache_creation_input_tokens": const_cache_create,
            "output_tokens": const_output_excluded,
        }
        const_expected = const_input + const_cache_read + const_cache_create
        # Act
        result = csa.context_size(usage)
        # Assert
        self.assertEqual(result, const_expected)

    def test_context_size_handles_missing_fields_as_zero(self):
        # Arrange / Act
        result = csa.context_size({})
        # Assert
        self.assertEqual(result, 0)


class InWindowTests(unittest.TestCase):
    def test_in_window_inclusive_on_both_ends(self):
        # Arrange
        const_since = "2026-04-01"
        const_until = "2026-04-30"
        # Act / Assert — both edges count
        self.assertTrue(csa.in_window("2026-04-01T00:00:00Z", const_since, const_until))
        self.assertTrue(csa.in_window("2026-04-30T23:59:59Z", const_since, const_until))

    def test_in_window_outside_returns_false(self):
        # Arrange
        const_since = "2026-04-01"
        const_until = "2026-04-30"
        # Act / Assert
        self.assertFalse(csa.in_window("2026-03-31T23:59:59Z", const_since, const_until))
        self.assertFalse(csa.in_window("2026-05-01T00:00:00Z", const_since, const_until))

    def test_in_window_empty_timestamp_returns_false(self):
        # Arrange / Act
        result = csa.in_window("", "2026-04-01", "2026-04-30")
        # Assert
        self.assertFalse(result)


class IsRealUserTurnTests(unittest.TestCase):
    def test_is_real_user_turn_string_content_is_real(self):
        # Arrange — typed user prompt
        entry = {"type": "user", "message": {"content": "hello"}}
        # Act / Assert
        self.assertTrue(csa.is_real_user_turn(entry))

    def test_is_real_user_turn_tool_result_only_is_not_real(self):
        # Arrange — tool turn shouldn't end the skill window
        entry = {"type": "user", "message": {"content": [
            {"type": "tool_result", "content": "ok"}
        ]}}
        # Act / Assert
        self.assertFalse(csa.is_real_user_turn(entry))

    def test_is_real_user_turn_meta_is_not_real(self):
        # Arrange — local-command-caveat and other meta messages
        entry = {"type": "user", "isMeta": True, "message": {"content": "x"}}
        # Act / Assert
        self.assertFalse(csa.is_real_user_turn(entry))

    def test_is_real_user_turn_assistant_type_is_not_real(self):
        # Arrange
        entry = {"type": "assistant", "message": {"content": "x"}}
        # Act / Assert
        self.assertFalse(csa.is_real_user_turn(entry))


class ExtractToolUsesTests(unittest.TestCase):
    def test_extract_tool_uses_filters_to_tool_use_blocks_only(self):
        # Arrange
        entry = {"message": {"content": [
            {"type": "text", "text": "hello"},
            {"type": "tool_use", "name": "Read", "input": {"file_path": "/x"}},
            {"type": "thinking", "thinking": "plan"},
            {"type": "tool_use", "name": "Skill", "input": {"skill": "foo"}},
        ]}}
        # Act
        result = csa.extract_tool_uses(entry)
        # Assert
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["name"], "Read")
        self.assertEqual(result[1]["name"], "Skill")

    def test_extract_tool_uses_string_content_returns_empty(self):
        # Arrange
        entry = {"message": {"content": "plain text"}}
        # Act
        result = csa.extract_tool_uses(entry)
        # Assert
        self.assertEqual(result, [])


class WalkMainSessionTests(unittest.TestCase):
    def _write_jsonl(self, lines: list[dict]) -> Path:
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonl", delete=False, encoding="utf-8")
        for entry in lines:
            tmp.write(json.dumps(entry) + "\n")
        tmp.close()
        return Path(tmp.name)

    def test_walk_main_session_skill_window_attributes_subsequent_turns(self):
        # Arrange — user→assistant(skill foo)→assistant(in window)→user(reset)→assistant(none)
        const_session = "abc12345"
        const_branch = "branches/test"
        const_timestamp = "2026-04-15T12:00:00Z"
        lines = [
            {"type": "user", "message": {"content": "hi"}, "timestamp": const_timestamp},
            {"type": "assistant", "timestamp": const_timestamp,
             "sessionId": const_session, "gitBranch": const_branch,
             "message": {"model": "claude-opus-4-7",
                         "content": [{"type": "tool_use", "name": "Skill",
                                      "input": {"skill": "foo"}}],
                         "usage": {"input_tokens": 10, "output_tokens": 20}}},
            {"type": "assistant", "timestamp": const_timestamp,
             "sessionId": const_session, "gitBranch": const_branch,
             "message": {"model": "claude-opus-4-7",
                         "content": [{"type": "text", "text": "still in foo"}],
                         "usage": {"input_tokens": 5, "output_tokens": 7}}},
            {"type": "user", "message": {"content": "next q"}, "timestamp": const_timestamp},
            {"type": "assistant", "timestamp": const_timestamp,
             "sessionId": const_session, "gitBranch": const_branch,
             "message": {"model": "claude-opus-4-7",
                         "content": [{"type": "text", "text": "no skill"}],
                         "usage": {"input_tokens": 2, "output_tokens": 3}}},
        ]
        path = self._write_jsonl(lines)
        unknown: set[str] = set()
        const_since = "2026-04-01"
        const_until = "2026-04-30"
        # Act
        records = csa.walk_main_session(path, const_since, const_until, unknown)
        # Assert — first 2 assistant turns attributed to "foo", third to None
        path.unlink()
        self.assertEqual(len(records), 3)
        self.assertEqual(records[0]["skill"], "foo")
        self.assertEqual(records[1]["skill"], "foo")
        self.assertIsNone(records[2]["skill"])
        self.assertFalse(any(r["is_sidechain"] for r in records))

    def test_walk_main_session_tool_result_user_turn_does_not_reset_skill(self):
        # Arrange — tool_result-only user message must not end the skill window
        const_timestamp = "2026-04-15T12:00:00Z"
        lines = [
            {"type": "assistant", "timestamp": const_timestamp,
             "message": {"model": "claude-opus-4-7",
                         "content": [{"type": "tool_use", "name": "Skill",
                                      "input": {"skill": "foo"}}],
                         "usage": {"input_tokens": 1, "output_tokens": 1}}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "content": "ok"}]},
             "timestamp": const_timestamp},
            {"type": "assistant", "timestamp": const_timestamp,
             "message": {"model": "claude-opus-4-7",
                         "content": [{"type": "text", "text": "still foo"}],
                         "usage": {"input_tokens": 1, "output_tokens": 1}}},
        ]
        path = self._write_jsonl(lines)
        unknown: set[str] = set()
        # Act
        records = csa.walk_main_session(path, "2026-04-01", "2026-04-30", unknown)
        path.unlink()
        # Assert — both assistant turns still inside the foo window
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["skill"], "foo")
        self.assertEqual(records[1]["skill"], "foo")

    def test_walk_main_session_filters_by_window(self):
        # Arrange — one in-window, one out-of-window
        const_in = "2026-04-15T12:00:00Z"
        const_out = "2026-03-15T12:00:00Z"
        lines = [
            {"type": "assistant", "timestamp": const_in,
             "message": {"model": "claude-opus-4-7", "content": [],
                         "usage": {"input_tokens": 1, "output_tokens": 1}}},
            {"type": "assistant", "timestamp": const_out,
             "message": {"model": "claude-opus-4-7", "content": [],
                         "usage": {"input_tokens": 1, "output_tokens": 1}}},
        ]
        path = self._write_jsonl(lines)
        unknown: set[str] = set()
        # Act
        records = csa.walk_main_session(path, "2026-04-01", "2026-04-30", unknown)
        path.unlink()
        # Assert
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["timestamp"], const_in)


class CollectAllDedupTests(unittest.TestCase):
    def _write_jsonl(self, path: Path, lines: list[dict]) -> None:
        with path.open("w", encoding="utf-8") as fp:
            for entry in lines:
                fp.write(json.dumps(entry) + "\n")

    def test_collect_all_deduplicates_same_message_across_files(self):
        # Arrange — same (message_id, request_id) appears in two project dirs
        const_msg_id = "msg_abc"
        const_req_id = "req_xyz"
        const_timestamp = "2026-04-15T12:00:00Z"
        shared_entry = {
            "type": "assistant", "timestamp": const_timestamp,
            "sessionId": "sess1", "gitBranch": "b", "requestId": const_req_id,
            "message": {"id": const_msg_id, "model": "claude-opus-4-7",
                        "content": [], "usage": {"input_tokens": 100, "output_tokens": 50}},
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "proj-a").mkdir()
            (root / "proj-b").mkdir()
            self._write_jsonl(root / "proj-a" / "session-1.jsonl", [shared_entry])
            self._write_jsonl(root / "proj-b" / "session-1.jsonl", [shared_entry])
            unknown: set[str] = set()
            # Act
            records = csa.collect_all(root, "2026-04-01", "2026-04-30", unknown)
        # Assert — appears twice raw, once after dedup
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["message_id"], const_msg_id)


class AggregatePerSkillTests(unittest.TestCase):
    def test_aggregate_per_skill_groups_and_sorts_by_cost_desc(self):
        # Arrange
        records = [
            {"skill": "foo", "is_sidechain": False, "model": "claude-opus-4-7",
             "context_tokens": 1000, "cost_usd": 5.0, "output_tokens": 100,
             "timestamp": "t", "session_id": "s", "git_branch": "b",
             "agent_type": None},
            {"skill": "foo", "is_sidechain": True, "model": "claude-haiku-4-5",
             "context_tokens": 2000, "cost_usd": 1.0, "output_tokens": 50,
             "timestamp": "t", "session_id": "s", "git_branch": "b",
             "agent_type": "Explore"},
            {"skill": "bar", "is_sidechain": False, "model": "claude-opus-4-7",
             "context_tokens": 500, "cost_usd": 10.0, "output_tokens": 80,
             "timestamp": "t", "session_id": "s", "git_branch": "b",
             "agent_type": None},
        ]
        # Act
        rows = csa.aggregate_per_skill(records)
        # Assert — bar ($10) ranks above foo ($6); foo has 2 turns including 1 sidechain
        self.assertEqual(rows[0]["skill"], "bar")
        self.assertEqual(rows[0]["total_cost_usd"], 10.0)
        self.assertEqual(rows[1]["skill"], "foo")
        self.assertEqual(rows[1]["total_cost_usd"], 6.0)
        self.assertEqual(rows[1]["turn_count"], 2)
        self.assertEqual(rows[1]["sidechain_turn_count"], 1)

    def test_aggregate_per_skill_unattributed_buckets_to_no_skill(self):
        # Arrange
        records = [{"skill": None, "is_sidechain": False,
                    "model": "claude-opus-4-7", "context_tokens": 100,
                    "cost_usd": 2.0, "output_tokens": 5, "timestamp": "t",
                    "session_id": "s", "git_branch": "b", "agent_type": None}]
        # Act
        rows = csa.aggregate_per_skill(records)
        # Assert
        self.assertEqual(rows[0]["skill"], "(no skill)")


class AggregatePerAgentTypeTests(unittest.TestCase):
    def test_aggregate_per_agent_type_excludes_main_thread(self):
        # Arrange
        records = [
            {"is_sidechain": True, "agent_type": "Explore", "cost_usd": 3.0},
            {"is_sidechain": False, "agent_type": None, "cost_usd": 100.0},
            {"is_sidechain": True, "agent_type": "general-purpose", "cost_usd": 7.0},
            {"is_sidechain": True, "agent_type": "Explore", "cost_usd": 2.0},
        ]
        # Act
        rows = csa.aggregate_per_agent_type(records)
        # Assert — main-thread $100 not in totals; Explore $5 from 2 turns sorts above general-purpose $7? No, gen-purpose=7 > explore=5
        self.assertEqual(rows[0]["agent_type"], "general-purpose")
        self.assertEqual(rows[0]["total_cost_usd"], 7.0)
        self.assertEqual(rows[1]["agent_type"], "Explore")
        self.assertEqual(rows[1]["total_cost_usd"], 5.0)
        self.assertEqual(rows[1]["turn_count"], 2)


class MainVsSidechainTests(unittest.TestCase):
    def test_main_vs_sidechain_pct_split(self):
        # Arrange — 75/25 split
        records = [
            {"is_sidechain": False, "cost_usd": 75.0},
            {"is_sidechain": True, "cost_usd": 25.0},
        ]
        const_main_pct = 75.0
        const_side_pct = 25.0
        # Act
        result = csa.main_vs_sidechain(records)
        # Assert
        self.assertEqual(result["main_thread_pct"], const_main_pct)
        self.assertEqual(result["sidechain_pct"], const_side_pct)

    def test_main_vs_sidechain_empty_returns_zero_pct(self):
        # Arrange / Act
        result = csa.main_vs_sidechain([])
        # Assert
        self.assertEqual(result["main_thread_pct"], 0.0)
        self.assertEqual(result["sidechain_pct"], 0.0)


class TopTurnsTests(unittest.TestCase):
    def test_top_turns_returns_n_most_expensive_in_order(self):
        # Arrange
        records = [
            {"timestamp": "t1", "cost_usd": 1.0, "model": "m", "context_tokens": 0,
             "output_tokens": 0, "session_id": "abcdefgh12345678",
             "git_branch": "b", "skill": "s", "is_sidechain": False, "agent_type": None},
            {"timestamp": "t2", "cost_usd": 5.0, "model": "m", "context_tokens": 0,
             "output_tokens": 0, "session_id": "abcdefgh12345678",
             "git_branch": "b", "skill": "s", "is_sidechain": False, "agent_type": None},
            {"timestamp": "t3", "cost_usd": 3.0, "model": "m", "context_tokens": 0,
             "output_tokens": 0, "session_id": "abcdefgh12345678",
             "git_branch": "b", "skill": "s", "is_sidechain": False, "agent_type": None},
        ]
        const_n = 2
        # Act
        result = csa.top_turns(records, const_n)
        # Assert
        self.assertEqual(len(result), const_n)
        self.assertEqual(result[0]["timestamp"], "t2")
        self.assertEqual(result[1]["timestamp"], "t3")
        self.assertEqual(result[0]["session_suffix"], "12345678")


if __name__ == "__main__":
    unittest.main()
