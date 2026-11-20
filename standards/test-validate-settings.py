#!/usr/bin/env python3
"""Unit tests for validate-settings.py, the guard on what the team settings
file may grant. Each test writes its own settings file to a temp directory and
runs the validator's main() against it. Run:
    python3 standards/test-validate-settings.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
_spec = importlib.util.spec_from_file_location("validate_settings", HERE / "validate-settings.py")
validate_settings = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate_settings)

OUTPUT_ASK = [f"Bash(git {family} *--output*)" for family in
              ("log", "diff", "show", "rev-list", "shortlog", "diff-tree", "diff-index", "blame")]


def run_validator(path) -> tuple[int, str]:
    """Run main() against a settings path; return (exit code, printed output)."""
    out = io.StringIO()
    argv = sys.argv
    sys.argv = ["validate-settings.py", str(path)]
    try:
        with contextlib.redirect_stdout(out):
            rc = validate_settings.main()
    finally:
        sys.argv = argv
    return rc, out.getvalue()


class ValidateSettingsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def validate(self, settings) -> tuple[int, str]:
        path = Path(self._tmp.name) / "settings.json"
        path.write_text(json.dumps(settings), encoding="utf-8")
        return run_validator(path)

    def validate_allow(self, *allow, ask=()) -> tuple[int, str]:
        return self.validate({"permissions": {"allow": list(allow), "ask": list(ask), "deny": []}})

    # --- the committed file and file errors -----------------------------------

    def test_main_committedSettings_passes(self):
        exit_ok = 0
        # Act
        rc, out = run_validator(HERE / "settings.json")
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_missingFile_fails(self):
        exit_fail = 1
        # Arrange
        path = Path(self._tmp.name) / "absent.json"
        # Act
        rc, out = run_validator(path)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("cannot read/parse", out)

    def test_main_invalidJson_fails(self):
        exit_fail = 1
        # Arrange
        path = Path(self._tmp.name) / "settings.json"
        path.write_text("{ not json", encoding="utf-8")
        # Act
        rc, out = run_validator(path)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("cannot read/parse", out)

    # --- keys a team file must not set ----------------------------------------

    def test_main_bypassPermissionsDefaultMode_fails(self):
        exit_fail = 1
        # Arrange
        settings = {"permissions": {"defaultMode": "bypassPermissions", "allow": []}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("permissions.defaultMode", out)

    def test_main_additionalDirectories_fails(self):
        exit_fail = 1
        # Arrange
        settings = {"permissions": {"additionalDirectories": ["/"], "allow": []}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("permissions.additionalDirectories", out)

    def test_main_codeRunningTopLevelKeys_fail(self):
        exit_fail = 1
        for key, value in (("hooks", {"SessionStart": []}), ("env", {"ANTHROPIC_BASE_URL": "x"}),
                           ("apiKeyHelper", "x"), ("statusLine", {"type": "command"})):
            with self.subTest(key=key):
                # Arrange
                settings = {key: value, "permissions": {"allow": []}}
                # Act
                rc, out = self.validate(settings)
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn(f"top-level key '{key}'", out)

    def test_main_emptyAttribution_passes(self):
        exit_ok = 0
        # Arrange
        settings = {"permissions": {"allow": []}, "attribution": {"commit": "", "pr": ""}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_attributionWithUnknownKeyOrNonString_fails(self):
        exit_fail = 1
        for attribution in ({"commit": "", "sessionUrl": True}, {"commit": 1}, "none"):
            with self.subTest(attribution=attribution):
                # Arrange
                settings = {"permissions": {"allow": []}, "attribution": attribution}
                # Act
                rc, _ = self.validate(settings)
                # Assert
                self.assertEqual(exit_fail, rc)

    def test_main_permissionsListNotAList_fails(self):
        exit_fail = 1
        # Arrange
        settings = {"permissions": {"allow": "Bash(git status:*)"}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("'permissions.allow' is not a list", out)

    # --- rule types -----------------------------------------------------------

    def test_main_unparseableBashEntry_fails(self):
        exit_fail = 1
        # Act
        rc, out = self.validate_allow("Bash(sort -o /etc/passwd")
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("unparseable Bash rule", out)

    def test_main_unvettedRuleTypes_fail(self):
        exit_fail = 1
        for entry in ("Write(**)", "Write(/tmp/pastedlog-*)", "Read(//**)",
                      "WebFetch(domain:example.com)", "Edit(**)", "Edit(//**)"):
            with self.subTest(entry=entry):
                # Act
                rc, _ = self.validate_allow(entry)
                # Assert
                self.assertEqual(exit_fail, rc)

    def test_main_reviewedEditRules_pass(self):
        exit_ok = 0
        # Act
        rc, out = self.validate_allow("Edit(//tmp/pastedlog-*)", "Edit(.claude-scratch/**)")
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_summary_countsOnlyCheckedEntriesByType(self):
        # Act
        _, out = self.validate_allow("Bash(git status:*)", "mcp__newrelic__get_entity",
                                     "Edit(.claude-scratch/**)")
        # Assert
        self.assertIn("3 allow entries checked (1 Bash, 1 MCP, 1 path)", out)

    def test_main_malformedAskEntry_fails(self):
        exit_fail = 1
        # Act
        rc, out = self.validate_allow("Bash(git status:*)", ask=["Bash(git log", ""])
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("not a well-formed permission rule", out)

    # --- Bash entries ---------------------------------------------------------

    def test_main_knownDangerousBashEntries_fail(self):
        exit_fail = 1
        for entry in ("Bash(sort:*)", "Bash(git:*)", "Bash(git worktree:*)", "Bash(python:*)",
                      "Bash(git worktree add:*)", "Bash(git config --list:*)"):
            with self.subTest(entry=entry):
                # Act
                rc, _ = self.validate_allow(entry)
                # Assert
                self.assertEqual(exit_fail, rc)

    def test_main_writeAndExecCommandsFromIssue206_fail(self):
        exit_fail = 1
        for entry in ("Bash(git difftool:*)", "Bash(gh auth:*)", "Bash(az pipelines:*)",
                      "Bash(sed:*)", "Bash(find:*)", "Bash(awk:*)", "Bash(git format-patch:*)",
                      "Bash(git cherry-pick:*)", "Bash(git fetch:*)", "Bash(pwsh:*)"):
            with self.subTest(entry=entry):
                # Act
                rc, _ = self.validate_allow(entry)
                # Assert
                self.assertEqual(exit_fail, rc)

    def test_main_wildcardInsideBashRule_fails(self):
        exit_fail = 1
        for entry in ("Bash(git c*)", "Bash(git * status)", "Bash(*)"):
            with self.subTest(entry=entry):
                # Act
                rc, out = self.validate_allow(entry)
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn("wildcard inside the rule", out)

    def test_main_gitConfigReadForms_pass(self):
        exit_ok = 0
        # Act
        rc, out = self.validate_allow("Bash(git config --get:*)", "Bash(git config --get-all:*)",
                                      "Bash(git config --get-regexp:*)")
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_ghAuthStatusWithWildcard_fails(self):
        exit_fail = 1
        for entry in ("Bash(gh auth status:*)", "Bash(gh auth status *)"):
            with self.subTest(entry=entry):
                # Act
                rc, out = self.validate_allow(entry)
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn("show-token", out)

    def test_main_ghAuthStatusExact_passes(self):
        exit_ok = 0
        # Act
        rc, out = self.validate_allow("Bash(gh auth status)")
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_outputFlagFamilyWithoutAskRule_fails(self):
        exit_fail = 1
        for family in ("log", "diff", "show", "rev-list", "shortlog", "diff-tree", "diff-index"):
            with self.subTest(family=family):
                # Act
                rc, out = self.validate_allow(f"Bash(git {family}:*)")
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn(f"Bash(git {family} *--output*)", out)

    def test_main_outputFlagFamilyWithAskRule_passes(self):
        exit_ok = 0
        # Act
        rc, out = self.validate_allow("Bash(git log:*)", ask=["Bash(git log *--output*)"])
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_blameWithOnlyOutputAskRule_failsForContents(self):
        exit_fail = 1
        # Act
        rc, out = self.validate_allow("Bash(git blame:*)", ask=["Bash(git blame *--output*)"])
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("Bash(git blame *--con*)", out)

    def test_main_askRuleSatisfiedByDeny_passes(self):
        exit_ok = 0
        # Arrange
        settings = {"permissions": {"allow": ["Bash(git log:*)"], "deny": ["Bash(git log *--output*)"]}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_ok, rc, out)

    # --- MCP entries ----------------------------------------------------------

    def test_main_mcpWildcardMutatingOrUnknown_fails(self):
        exit_fail = 1
        for entry in ("mcp__azure-devops__*", "mcp__azure-devops__wit_update_work_item",
                      "mcp__azure-devops__wit_get_something_new"):
            with self.subTest(entry=entry):
                # Act
                rc, _ = self.validate_allow(entry)
                # Assert
                self.assertEqual(exit_fail, rc)

    def test_main_attachmentToolThatWritesFiles_fails(self):
        exit_fail = 1
        # Act
        rc, out = self.validate_allow("mcp__azure-devops__wit_get_work_item_attachment")
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("KNOWN_SAFE_MCP", out)

    def test_main_committedSettings_revokesRemovedGrantsWithAskRules(self):
        # Arrange: setup-env only adds entries, so a grant removed from allow
        # stays on synced machines unless an ask rule overrides it.
        settings = json.loads((HERE / "settings.json").read_text(encoding="utf-8"))
        ask = set(settings["permissions"]["ask"])
        # Assert
        for rule in ("Bash(git config --list *)", "Bash(gh auth status *t*)",
                     "mcp__azure-devops__wit_get_work_item_attachment"):
            self.assertIn(rule, ask)


if __name__ == "__main__":
    unittest.main(verbosity=1)
