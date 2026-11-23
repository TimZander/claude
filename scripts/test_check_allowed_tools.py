#!/usr/bin/env python3
"""Unit tests for scripts/check-allowed-tools.py. Run:
    python3 scripts/test_check_allowed_tools.py     (python / py on Windows)
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("check_allowed_tools", HERE / "check-allowed-tools.py")
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)


def frontmatter(tools: str, key: str = "allowed-tools") -> str:
    return f"---\nname: x\n{key}: {tools}\n---\n\nBody.\n"


class ToolGrantsTests(unittest.TestCase):
    def test_toolGrants_inlineListWithSpecifiers_keepsEachEntryWhole(self):
        # Arrange
        text = frontmatter("Read, Bash(gh pr view *), Bash(az boards work-item show *), Agent")
        # Act
        entries = checker.tool_grants(text)
        # Assert
        self.assertEqual(["Read", "Bash(gh pr view *)", "Bash(az boards work-item show *)", "Agent"], entries)

    def test_toolGrants_otherYamlForms_parseToTheSameEntries(self):
        # Arrange
        cases = {
            "flow list": frontmatter("[Bash, Read]"),
            "quoted list": frontmatter('"Bash, Read"'),
            "quoted entries": frontmatter("'Bash', \"Read\""),
            "trailing comment": frontmatter("Bash, Read # pre-approved"),
            "block list": "---\nname: x\nallowed-tools:\n  - Bash\n  # a comment\n  - Read\n---\nBody\n",
            "byte-order mark": "﻿" + frontmatter("Bash, Read"),
            "crlf": "---\r\nname: x\r\nallowed-tools: Bash, Read\r\n---\r\nBody\r\n",
            "trailing space on fence": "--- \nname: x\nallowed-tools: Bash, Read\n---  \nBody\n",
        }
        for name, text in cases.items():
            with self.subTest(form=name):
                # Act
                entries = checker.tool_grants(text)
                # Assert
                self.assertEqual(["Bash", "Read"], entries)

    def test_toolGrants_noFrontmatterOrNoKeyOrOnlyInBody_returnsNone(self):
        # Arrange
        cases = ["No frontmatter here.", "---\nname: x\n---\nBody\n",
                 "---\nname: x\n---\nallowed-tools: Bash\n", "---\nname: x\nallowed-tools: Bash\nno closing fence\n"]
        for text in cases:
            with self.subTest(text=text):
                # Act
                entries = checker.tool_grants(text)
                # Assert
                self.assertIsNone(entries)

    def test_toolGrants_emptyValue_returnsNoEntries(self):
        # Arrange
        text = "---\nname: x\nallowed-tools:\n---\nBody\n"
        # Act
        entries = checker.tool_grants(text)
        # Assert
        self.assertEqual([], entries)

    def test_toolGrants_duplicateKey_raises(self):
        # Arrange
        text = "---\nname: x\nallowed-tools: Read\nallowed-tools: Bash\n---\nBody\n"
        # Act / Assert
        with self.assertRaises(checker.FrontmatterError):
            checker.tool_grants(text)

    def test_toolGrants_agentToolsKey_isRead(self):
        # Arrange
        text = frontmatter("Bash, Read", key="tools")
        # Act
        entries = checker.tool_grants(text, "tools")
        # Assert
        self.assertEqual(["Bash", "Read"], entries)


class IsBroadTests(unittest.TestCase):
    def test_isBroad_grantsThatAllowAnyCommandOrUrl_areBroad(self):
        # Arrange
        for entry in ("Bash", "bash", "WebFetch", "webfetch", "Bash()", "Bash(*)", "Bash(:*)",
                      "Bash(* --output*)", "Bash(bash *deep-review*/scripts/resolve-pr.sh *)",
                      "Bash(bash scripts/sdd/*)", "Bash(sh -c *)", "Bash(python3 *)", "Bash(/usr/bin/env *)",
                      "Bash(pwsh.exe *)", "WebFetch(*)", "WebFetch(domain:*)"):
            with self.subTest(entry=entry):
                # Act
                broad = checker.is_broad(entry)
                # Assert
                self.assertTrue(broad)

    def test_isBroad_specificGrants_areNotBroad(self):
        # Arrange
        for entry in ("Read", "Agent", "Bash(gh pr view *)", "Bash(git log:*)", "Bash(git status)",
                      "WebFetch(domain:docs.example.com)", "mcp__azure-devops__wit_get_work_item"):
            with self.subTest(entry=entry):
                # Act
                broad = checker.is_broad(entry)
                # Assert
                self.assertFalse(broad)


class CheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        (self.root / "plugins").mkdir()

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self, baseline=frozenset()) -> list[str]:
        with mock.patch.object(checker, "BASELINE", set(baseline)):
            return checker.check(self.root)

    def test_check_newBroadGrantAnywhere_fails(self):
        expected_count = 1
        # Arrange
        cases = {
            "plugins/a/commands/a.md": frontmatter("Bash, Read"),
            "plugins/b/commands/sub/b.md": frontmatter("Read, WebFetch"),
            "plugins/c/skills/s/SKILL.md": frontmatter("Bash(*)"),
            "plugins/d/agents/d.md": frontmatter("Bash, Read", key="tools"),
            "external_plugins/e/commands/e.md": frontmatter("Bash"),
        }
        for rel, text in cases.items():
            with self.subTest(rel=rel):
                self.write(rel, text)
                # Act
                problems = self.run_check()
                # Assert
                self.assertEqual(expected_count, len(problems), problems)
                self.assertIn(f"{rel}: grants", problems[0])
                (self.root / rel).unlink()

    def test_check_bothBroadToolsInOneFile_namesBoth(self):
        # Arrange
        rel = "plugins/a/commands/a.md"
        self.write(rel, frontmatter("Bash, Read, WebFetch"))
        # Act
        problems = self.run_check()
        # Assert
        self.assertIn(f"{rel}: grants Bash, WebFetch", problems[0])

    def test_check_scopedGrants_pass(self):
        # Arrange
        self.write("plugins/ok/commands/ok.md", frontmatter("Read, Bash(gh pr view *), Agent"))
        # Act
        problems = self.run_check()
        # Assert
        self.assertEqual([], problems)

    def test_check_fileWithoutGrants_passes(self):
        # Arrange
        self.write("plugins/none/commands/none.md", "---\nname: none\n---\nBody\n")
        # Act
        problems = self.run_check()
        # Assert
        self.assertEqual([], problems)

    def test_check_grandfatheredFileStillBroad_passes(self):
        # Arrange
        rel = "plugins/old/commands/old.md"
        self.write(rel, frontmatter("Bash"))
        # Act
        problems = self.run_check({rel})
        # Assert
        self.assertEqual([], problems)

    def test_check_grandfatheredFileNarrowed_failsUntilRemovedFromBaseline(self):
        # Arrange
        rel = "plugins/old/commands/old.md"
        self.write(rel, frontmatter("Bash(git log:*)"))
        # Act
        problems = self.run_check({rel})
        # Assert
        self.assertEqual([f"{rel}: no longer grants a broad tool - remove it from BASELINE"], problems)

    def test_check_baselineEntryForMissingFile_fails(self):
        # Arrange
        rel = "plugins/gone/commands/gone.md"
        # Act
        problems = self.run_check({rel})
        # Assert
        self.assertEqual([f"{rel}: listed in BASELINE but does not exist - remove it"], problems)

    def test_check_unreadableFrontmatter_fails(self):
        # Arrange
        dup = "plugins/dup/commands/dup.md"
        self.write(dup, "---\nallowed-tools: Read\nallowed-tools: Bash\n---\n")
        bad = self.root / "plugins/bad/commands/bad.md"
        bad.parent.mkdir(parents=True)
        bad.write_bytes(b"---\nallowed-tools: \xff\n---\n")
        # Act
        problems = self.run_check()
        # Assert
        self.assertTrue(any(p.startswith(f"{dup}: cannot read") for p in problems), problems)
        self.assertTrue(any(p.startswith("plugins/bad/commands/bad.md: cannot read") for p in problems), problems)


class MainTests(unittest.TestCase):
    def run_main(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        saved = sys.argv
        sys.argv = ["check-allowed-tools.py", *map(str, argv)]
        try:
            with contextlib.redirect_stdout(out):
                rc = checker.main()
        finally:
            sys.argv = saved
        return rc, out.getvalue()

    def test_main_rootWithoutPlugins_failsWithUsageError(self):
        exit_usage = 2
        # Arrange
        with tempfile.TemporaryDirectory() as empty:
            # Act
            rc, out = self.run_main(empty)
        # Assert
        self.assertEqual(exit_usage, rc)
        self.assertIn("has no plugins/ directory", out)

    def test_main_newBroadGrant_exitsOneAndListsIt(self):
        exit_fail = 1
        # Arrange
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "plugins/a/commands/a.md"
            path.parent.mkdir(parents=True)
            path.write_text(frontmatter("Bash"), encoding="utf-8")
            # Act
            with mock.patch.object(checker, "BASELINE", set()):
                rc, out = self.run_main(tmp)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("plugins/a/commands/a.md: grants Bash", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
