#!/usr/bin/env python3
"""Unit tests for scripts/check-allowed-tools.py. Run:
    python3 scripts/test_check_allowed_tools.py     (python / py on Windows)
"""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("check_allowed_tools", HERE / "check-allowed-tools.py")
cat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cat)


def frontmatter(tools: str) -> str:
    return f"---\nname: x\nallowed-tools: {tools}\n---\n\nBody.\n"


class AllowedToolsTests(unittest.TestCase):
    def test_allowedTools_specifierWithCommas_staysOneEntry(self):
        # Arrange
        text = frontmatter("Read, Bash(gh pr view *), Bash(az boards work-item show *), Agent")
        # Act
        entries = cat.allowed_tools(text)
        # Assert
        self.assertEqual(["Read", "Bash(gh pr view *)", "Bash(az boards work-item show *)", "Agent"], entries)

    def test_allowedTools_noFrontmatterOrNoKey_returnsNone(self):
        # Arrange
        for text in ("No frontmatter here.", "---\nname: x\n---\nBody\n"):
            with self.subTest(text=text):
                # Act
                entries = cat.allowed_tools(text)
                # Assert
                self.assertIsNone(entries)

    def test_allowedTools_crlfFrontmatter_isRead(self):
        # Arrange
        text = "---\r\nname: x\r\nallowed-tools: Bash, Read\r\n---\r\nBody\r\n"
        # Act
        entries = cat.allowed_tools(text)
        # Assert
        self.assertEqual(["Bash", "Read"], entries)

    def test_broadGrants_onlyBareBashAndWebFetchCount(self):
        # Arrange
        entries = ["Bash", "WebFetch", "Bash(git log:*)", "Read", "WebFetch(domain:example.com)"]
        # Act
        broad = cat.broad_grants(entries)
        # Assert
        self.assertEqual(["Bash", "WebFetch"], broad)


class CheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_check_newCommandWithBareBash_fails(self):
        # Arrange
        rel = "plugins/new/commands/new.md"
        self.write(rel, frontmatter("Bash, Read"))
        # Act
        with mock.patch.object(cat, "BASELINE", set()):
            problems = cat.check(self.root)
        # Assert
        self.assertEqual(1, len(problems))
        self.assertIn(f"{rel}: grants Bash", problems[0])

    def test_check_newSkillWithWebFetch_fails(self):
        # Arrange
        rel = "plugins/new/skills/s/SKILL.md"
        self.write(rel, frontmatter("Read, WebFetch"))
        # Act
        with mock.patch.object(cat, "BASELINE", set()):
            problems = cat.check(self.root)
        # Assert
        self.assertIn(f"{rel}: grants WebFetch", problems[0])

    def test_check_scopedGrants_pass(self):
        # Arrange
        self.write("plugins/ok/commands/ok.md", frontmatter("Read, Bash(gh pr view *), Agent"))
        self.write("plugins/none/commands/none.md", "---\nname: none\n---\nBody\n")
        # Act
        with mock.patch.object(cat, "BASELINE", set()):
            problems = cat.check(self.root)
        # Assert
        self.assertEqual([], problems)

    def test_check_grandfatheredFileStillBroad_passes(self):
        # Arrange
        rel = "plugins/old/commands/old.md"
        self.write(rel, frontmatter("Bash"))
        # Act
        with mock.patch.object(cat, "BASELINE", {rel}):
            problems = cat.check(self.root)
        # Assert
        self.assertEqual([], problems)

    def test_check_grandfatheredFileNarrowed_failsUntilRemovedFromBaseline(self):
        # Arrange
        rel = "plugins/old/commands/old.md"
        self.write(rel, frontmatter("Bash(git log:*)"))
        # Act
        with mock.patch.object(cat, "BASELINE", {rel}):
            problems = cat.check(self.root)
        # Assert
        self.assertEqual([f"{rel}: no longer grants a broad tool - remove it from BASELINE"], problems)

    def test_check_baselineEntryForMissingFile_fails(self):
        # Arrange
        rel = "plugins/gone/commands/gone.md"
        # Act
        with mock.patch.object(cat, "BASELINE", {rel}):
            problems = cat.check(self.root)
        # Assert
        self.assertEqual([f"{rel}: listed in BASELINE but does not exist - remove it"], problems)

    def test_check_repository_passes(self):
        # Arrange
        root = HERE.parent
        # Act
        problems = cat.check(root)
        # Assert
        self.assertEqual([], problems)

    def test_check_deepReview_isNotGrandfathered(self):
        # Arrange
        rel = "plugins/deep-review/commands/deep-review.md"
        # Act
        entries = cat.allowed_tools((HERE.parent / rel).read_text(encoding="utf-8"))
        # Assert
        self.assertNotIn(rel, cat.BASELINE)
        self.assertEqual([], cat.broad_grants(entries))


if __name__ == "__main__":
    unittest.main(verbosity=1)
