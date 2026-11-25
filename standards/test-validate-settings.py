#!/usr/bin/env python3
"""Unit tests for validate-settings.py, the guard on what the team settings
file may grant, and for the Bash rule matcher in allowlist_common.py that
models how Claude Code applies those rules. Run:
    python3 standards/test-validate-settings.py     (python / py on Windows)
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
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
_spec = importlib.util.spec_from_file_location("validate_settings", HERE / "validate-settings.py")
vs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vs)

from allowlist_common import bash_rule_matches  # noqa: E402


def run_validator(*argv) -> tuple[int, str]:
    """Run main() with the given arguments; return (exit code, printed output)."""
    out = io.StringIO()
    saved = sys.argv
    sys.argv = ["validate-settings.py", *map(str, argv)]
    try:
        with contextlib.redirect_stdout(out):
            rc = vs.main()
    finally:
        sys.argv = saved
    return rc, out.getvalue()


def committed_settings() -> dict:
    return json.loads((HERE / "settings.json").read_text(encoding="utf-8"))


class ValidatorTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "settings.json"

    def validate(self, settings) -> tuple[int, str]:
        self.path.write_text(json.dumps(settings), encoding="utf-8")
        return run_validator(self.path)

    def validate_allow(self, *allow, ask=(), deny=()) -> tuple[int, str]:
        """Validate a file with the given allow rules plus every POLICY_ASK rule."""
        settings = {"permissions": {"allow": list(allow),
                                    "ask": list(vs.POLICY_ASK) + list(ask),
                                    "deny": list(deny)}}
        return self.validate(settings)


class MainTests(ValidatorTestCase):
    def test_main_committedSettings_passes(self):
        exit_ok = 0
        # Arrange
        path = HERE / "settings.json"
        # Act
        rc, out = run_validator(path)
        # Assert
        self.assertEqual(exit_ok, rc, out)

    def test_main_noArgument_validatesCommittedSettings(self):
        exit_ok = 0
        # Arrange: no path argument, as CI runs it
        # Act
        rc, out = run_validator()
        # Assert
        self.assertEqual(exit_ok, rc, out)
        self.assertIn("allow entries checked", out)

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
        self.path.write_text("{ not json", encoding="utf-8")
        # Act
        rc, out = run_validator(self.path)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("cannot read/parse", out)

    def test_main_invalidUtf8_failsWithMessage(self):
        exit_fail = 1
        # Arrange
        self.path.write_bytes(b'{"permissions": {"allow": ["\xe9"]}}')
        # Act
        rc, out = run_validator(self.path)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("cannot read/parse", out)

    def test_main_duplicateKey_fails(self):
        exit_fail = 1
        # Arrange: a reader that keeps the first key would see the dangerous mode
        self.path.write_text('{"permissions": {"defaultMode": "bypassPermissions"}, '
                             '"permissions": {"allow": []}}', encoding="utf-8")
        # Act
        rc, out = run_validator(self.path)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("duplicate key 'permissions'", out)

    def test_main_validMix_summaryCountsEachType(self):
        exit_ok = 0
        policy_count = len(vs.POLICY_ASK)
        # Arrange
        allow = ["Bash(git status:*)", "Bash(gh pr view:*)", "mcp__newrelic__get_entity"]
        # Act
        rc, out = self.validate_allow(*allow)
        # Assert
        self.assertEqual(exit_ok, rc, out)
        self.assertIn(f"3 allow entries checked (2 Bash, 1 MCP, 0 path), {policy_count} ask, 0 deny", out)

    def test_main_rejectedEntry_isNotReportedAsChecked(self):
        exit_fail = 1
        # Arrange
        allow = ["Bash(git status:*)", "Bash(sort -o /etc/passwd"]
        # Act
        rc, out = self.validate_allow(*allow)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertNotIn("allow entries checked", out)


class StructureTests(ValidatorTestCase):
    def test_checkStructure_bypassPermissionsDefaultMode_fails(self):
        exit_fail = 1
        # Arrange
        settings = {"permissions": {"defaultMode": "bypassPermissions", "allow": []}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("'permissions.defaultMode' is not allowed", out)

    def test_checkStructure_additionalDirectories_fails(self):
        exit_fail = 1
        # Arrange
        settings = {"permissions": {"additionalDirectories": ["/"], "allow": []}}
        # Act
        rc, out = self.validate(settings)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("'permissions.additionalDirectories' is not allowed", out)

    def test_checkStructure_codeRunningTopLevelKeys_fail(self):
        exit_fail = 1
        # Arrange
        cases = {"hooks": {"SessionStart": []}, "env": {"ANTHROPIC_BASE_URL": "x"},
                 "apiKeyHelper": "x", "statusLine": {"type": "command"}}
        for key, value in cases.items():
            with self.subTest(key=key):
                # Act
                rc, out = self.validate({key: value, "permissions": {"allow": []}})
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn(f"top-level key '{key}' is not allowed", out)

    def test_checkStructure_schemaKey_isAllowed(self):
        # Arrange
        settings = {"$schema": "https://json.schemastore.org/claude-code-settings.json",
                    "permissions": {"allow": []}}
        # Act
        violations = vs.check_structure(settings)
        # Assert
        self.assertEqual([], violations)

    def test_checkStructure_attributionEmptyStringsOrFalse_isAllowed(self):
        # Arrange
        for attribution in ({"commit": "", "pr": ""}, False):
            with self.subTest(attribution=attribution):
                # Act
                violations = vs.check_structure({"attribution": attribution})
                # Assert
                self.assertEqual([], violations)

    def test_checkStructure_badAttribution_reportsWhy(self):
        # Arrange
        cases = {
            "unknown key": ({"commit": "", "sessionUrl": True}, "'attribution.sessionUrl' is not allowed"),
            "commit not a string": ({"commit": 1}, "'attribution.commit' must be a string"),
            "pr not a string": ({"pr": None}, "'attribution.pr' must be a string"),
            "string": ("none", "'attribution' must be an object or false"),
            "true": (True, "'attribution' must be an object or false"),
        }
        for name, (attribution, expected) in cases.items():
            with self.subTest(name=name):
                # Act
                violations = vs.check_structure({"attribution": attribution})
                # Assert
                self.assertTrue(any(expected in v for v in violations), violations)

    def test_checkStructure_topLevelNotObject_fails(self):
        # Arrange
        for data in ([], "x", 1):
            with self.subTest(data=data):
                # Act
                violations = vs.check_structure(data)
                # Assert
                self.assertEqual(["top level is not a JSON object"], violations)

    def test_main_permissionsNotObject_fails(self):
        exit_fail = 1
        # Arrange
        for permissions in ([], "x", None):
            with self.subTest(permissions=permissions):
                # Act
                rc, out = self.validate({"permissions": permissions})
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn("'permissions' is not an object", out)

    def test_checkStructure_ruleListNotAList_fails(self):
        # Arrange
        for key in ("allow", "ask", "deny"):
            with self.subTest(key=key):
                # Act
                violations = vs.check_structure({"permissions": {key: "Bash(git status:*)"}})
                # Assert
                self.assertIn(f"'permissions.{key}' is not a list", violations)


class AllowEntryTests(ValidatorTestCase):
    def test_checkAllowEntry_notANonEmptyString_isInvalid(self):
        # Arrange
        for entry in (1, None, ""):
            with self.subTest(entry=entry):
                # Act
                kind, reason = vs.check_allow_entry(entry)
                # Assert
                self.assertEqual(("invalid", "not a non-empty string"), (kind, reason))

    def test_checkAllowEntry_unparseableBash_fails(self):
        # Arrange
        for entry in ("Bash(sort -o /etc/passwd", "Bash()", "Bash(:*)"):
            with self.subTest(entry=entry):
                # Act
                _, reason = vs.check_allow_entry(entry)
                # Assert
                self.assertEqual("unparseable Bash rule", reason)

    def test_checkAllowEntry_writeRule_explainsItIsIgnored(self):
        # Arrange
        entry = "Write(/tmp/pastedlog-*)"
        # Act
        _, reason = vs.check_allow_entry(entry)
        # Assert
        self.assertIn("ignores Write(...)", reason)

    def test_checkAllowEntry_unvettedRuleTypes_fail(self):
        # Arrange
        for entry in ("Read(//**)", "WebFetch(domain:example.com)", "Glob(**)", "Agent"):
            with self.subTest(entry=entry):
                # Act
                _, reason = vs.check_allow_entry(entry)
                # Assert
                self.assertIn("rule type this guard cannot vet", reason)

    def test_checkAllowEntry_anyEditRule_failsWhileNoneIsReviewed(self):
        # Arrange: includes the two scratch rules this change dropped
        for entry in ("Edit(**)", "Edit(//tmp/pastedlog-*)", "Edit(.claude-scratch/**)"):
            with self.subTest(entry=entry):
                # Act
                _, reason = vs.check_allow_entry(entry)
                # Assert
                self.assertIn("KNOWN_SAFE_PATH_RULES", reason)

    def test_checkAllowEntry_ghAuthStatusExact_passes(self):
        # Arrange
        entry = "Bash(gh auth status)"
        # Act
        _, reason = vs.check_allow_entry(entry)
        # Assert
        self.assertIsNone(reason)

    def test_checkAllowEntry_ghAuthStatusWithWildcardOrArguments_fails(self):
        # Arrange
        for entry in ("Bash(gh auth status:*)", "Bash(gh auth status *)", "Bash(gh auth status -t)",
                      "Bash(gh auth status --show-token)", "Bash(gh auth status -h github.com:*)",
                      "Bash(GH auth status -t)"):
            with self.subTest(entry=entry):
                # Act
                _, reason = vs.check_allow_entry(entry)
                # Assert
                self.assertIn("show-token", reason)


class BashTests(unittest.TestCase):
    def test_checkBash_everyWriteCapableKey_isRejectedExactAndAsPrefix(self):
        # Arrange: some keys hit an earlier, more specific reason; any reason is a rejection
        for key in vs.WRITE_CAPABLE:
            with self.subTest(key=key):
                # Act
                reason = vs.check_bash(key)
                # Assert
                self.assertIsNotNone(reason)

    def test_checkBash_issue206Commands_areRejected(self):
        # Arrange
        for cmd in ("git difftool", "gh auth", "az pipelines", "sed", "find", "awk",
                    "git format-patch", "git cherry-pick", "git fetch", "pwsh"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIsNotNone(reason)

    def test_checkBash_azDevopsExtensionRead_isRejectedForRemoteDetection(self):
        # Arrange
        for cmd in ("az boards work-item show", "az boards query", "az repos pr show",
                    "az repos pr list", "az pipelines runs list", "az devops project list",
                    "az artifacts universal download"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIn("--detect false", reason)

    def test_checkBash_azCoreRead_isAllowed(self):
        # Arrange
        for cmd in ("az account show", "az account list", "az extension list", "az version"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIsNone(reason)

    def test_checkBash_familyRootOrGlobalOption_isRejected(self):
        # Arrange
        cases = {"git": "bare command-family root", "git -C": "global option", "git -c": "global option",
                 "git --no-pager": "global option", "git -P log": "global option", "gh -R": "global option"}
        for cmd, expected in cases.items():
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIn(expected, reason)

    def test_checkBash_versionFlags_areAllowed(self):
        # Arrange
        for cmd in vs.GLOBAL_OPTION_OK:
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIsNone(reason)

    def test_checkBash_caseOrPathOrExeVariant_isRejected(self):
        # Arrange
        for cmd in ("SORT", "Python", "python.exe", "cmd.exe", "powershell.exe", "/usr/bin/sort",
                    "C:\\Windows\\System32\\cmd.exe", "Git push"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIsNotNone(reason)

    def test_checkBash_wildcardInsideRule_isRejected(self):
        # Arrange
        for cmd in ("git c*", "git * status", "*"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIn("wildcard inside the rule", reason)

    def test_checkBash_shortNonWordPrefix_isAllowedBecauseMatchingIsWordBounded(self):
        # Arrange: `Bash(git c:*)` means `git c *`, which never matches `git commit`
        for cmd in ("git c", "gh pr m"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIsNone(reason)
                self.assertFalse(bash_rule_matches(f"Bash({cmd}:*)", "git commit -m x"))

    def test_checkBash_gitConfigReadForms_pass(self):
        # Arrange
        for cmd in ("git config --get", "git config --get-all"):
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIsNone(reason)

    def test_checkBash_gitConfigListOrRegexp_isRejectedAsDisclosure(self):
        # Arrange
        cases = {"git config --list": "credentials", "git config --get-regexp": "dumps the whole config"}
        for cmd, expected in cases.items():
            with self.subTest(cmd=cmd):
                # Act
                reason = vs.check_bash(cmd)
                # Assert
                self.assertIn(expected, reason)


class RequiredAskTests(ValidatorTestCase):
    def test_main_familyWithoutItsAskRules_fails(self):
        exit_fail = 1
        for family, rules in vs.REQUIRED_ASK.items():
            with self.subTest(family=family):
                # Arrange
                allow = f"Bash({family}:*)"
                # Act
                rc, out = self.validate_allow(allow)
                # Assert
                self.assertEqual(exit_fail, rc)
                for rule in rules:
                    self.assertIn(rule, out)

    def test_main_familyWithItsAskRules_passes(self):
        exit_ok = 0
        for family, rules in vs.REQUIRED_ASK.items():
            with self.subTest(family=family):
                # Arrange
                allow = f"Bash({family}:*)"
                # Act
                rc, out = self.validate_allow(allow, ask=rules)
                # Assert
                self.assertEqual(exit_ok, rc, out)

    def test_main_subcommandFormOfFamily_stillNeedsAskRule(self):
        exit_fail = 1
        # Arrange
        allow = "Bash(git log --oneline:*)"
        # Act
        rc, out = self.validate_allow(allow)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("Bash(git * --output*)", out)

    def test_main_blameWithOnlyOutputRule_failsForContents(self):
        exit_fail = 1
        # Arrange
        allow = "Bash(git blame:*)"
        # Act
        rc, out = self.validate_allow(allow, ask=["Bash(git * --output*)"])
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("Bash(git blame *--con*)", out)

    def test_main_askRuleForOtherFamily_doesNotSatisfy(self):
        exit_fail = 1
        # Arrange
        allow = "Bash(git config --get:*)"
        # Act
        rc, out = self.validate_allow(allow, ask=["Bash(git * --output*)"])
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("Bash(git config *--file*)", out)

    def test_main_requiredRuleInDeny_satisfies(self):
        exit_ok = 0
        # Arrange
        allow = "Bash(git log:*)"
        # Act
        rc, out = self.validate_allow(allow, deny=["Bash(git * --output*)"])
        # Assert
        self.assertEqual(exit_ok, rc, out)


class PolicyAskTests(ValidatorTestCase):
    def test_main_anyPolicyRuleMissing_fails(self):
        exit_fail = 1
        for rule, reason in vs.POLICY_ASK.items():
            with self.subTest(rule=rule):
                # Arrange
                settings = committed_settings()
                settings["permissions"]["ask"].remove(rule)
                # Act
                rc, out = self.validate(settings)
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn(reason, out)


class AskDenyShapeTests(ValidatorTestCase):
    def test_main_malformedAskOrDenyEntry_fails(self):
        exit_fail = 1
        for key in ("ask", "deny"):
            for entry in ("Bash(git log", "", 1, {}, "Bash(x)\n", "Bash(a) Bash(b)", "Bash(a(b))"):
                with self.subTest(key=key, entry=entry):
                    # Arrange
                    extra = {key: [entry]}
                    # Act
                    rc, out = self.validate_allow("Bash(git status:*)", **extra)
                    # Assert
                    self.assertEqual(exit_fail, rc)
                    self.assertIn("not a well-formed permission rule", out)

    def test_main_writeRuleInAskOrDeny_fails(self):
        exit_fail = 1
        for key in ("ask", "deny"):
            with self.subTest(key=key):
                # Arrange
                extra = {key: ["Write(/etc/**)"]}
                # Act
                rc, out = self.validate_allow("Bash(git status:*)", **extra)
                # Assert
                self.assertEqual(exit_fail, rc)
                self.assertIn("ignores Write(...)", out)

    def test_main_askRuleEndingInColonStarAfterWildcard_fails(self):
        exit_fail = 1
        # Arrange: meant as "contains ' :'", but a trailing :* is the prefix suffix
        ask = ["Bash(git *push * :*)"]
        # Act
        rc, out = self.validate_allow("Bash(git status:*)", ask=ask)
        # Assert
        self.assertEqual(exit_fail, rc)
        self.assertIn("trailing `:*` is read as the prefix suffix", out)

    def test_main_wellFormedAskEntries_pass(self):
        exit_ok = 0
        # Arrange
        ask = ["mcp__azure-devops__wit_update_work_item", "mcp__server__*", "WebFetch", "Edit(//etc/**)"]
        # Act
        rc, out = self.validate_allow("Bash(git status:*)", ask=ask)
        # Assert
        self.assertEqual(exit_ok, rc, out)


class McpTests(unittest.TestCase):
    def test_checkMcp_wildcard_isRejectedAsWildcard(self):
        # Arrange
        entry = "mcp__azure-devops__*"
        # Act
        reason = vs.check_mcp(entry)
        # Assert
        self.assertIn("wildcard MCP grant", reason)

    def test_checkMcp_unreviewedTool_isRejected(self):
        # Arrange
        for entry in ("mcp__azure-devops__wit_get_something_new",
                      "mcp__azure-devops__wit_get_work_item_attachment",
                      "mcp__azure-devops__wit_update_work_item"):
            with self.subTest(entry=entry):
                # Act
                reason = vs.check_mcp(entry)
                # Assert
                self.assertIn("KNOWN_SAFE_MCP", reason)

    def test_checkMcp_mutatingNameAddedToReviewedSet_isFlagged(self):
        # Arrange
        entry = "mcp__azure-devops__wit_update_work_item"
        with mock.patch.object(vs, "KNOWN_SAFE_MCP", vs.KNOWN_SAFE_MCP | {entry}):
            # Act
            reason = vs.check_mcp(entry)
        # Assert
        self.assertIn("looks mutating", reason)

    def test_checkMcp_reviewedTool_passes(self):
        # Arrange
        entry = "mcp__newrelic__get_entity"
        # Act
        reason = vs.check_mcp(entry)
        # Assert
        self.assertIsNone(reason)


class RuleMatcherTests(unittest.TestCase):
    def test_bashRuleMatches_documentedSemantics(self):
        # Arrange: (rule, command, expected) from the Claude Code permissions docs
        cases = [
            ("Bash(git log *)", "git log", True),
            ("Bash(git log *)", "git log --oneline", True),
            ("Bash(git log:*)", "git log --oneline", True),
            ("Bash(ls *)", "lsof", False),
            ("Bash(ls*)", "lsof", True),
            ("Bash(git * main)", "git push origin main", True),
            ("Bash(git log *--output*)", "git log", False),
            ("Bash(gh auth status)", "gh auth status -t", False),
            ("mcp__x__y", "mcp__x__y", False),
        ]
        for rule, command, expected in cases:
            with self.subTest(rule=rule, command=command):
                # Act
                matched = bash_rule_matches(rule, command)
                # Assert
                self.assertEqual(expected, matched)


class CommittedAskRuleTests(unittest.TestCase):
    def setUp(self):
        self.ask = [r for r in committed_settings()["permissions"]["ask"] if r.startswith("Bash(")]

    def prompts(self, command: str) -> bool:
        return any(bash_rule_matches(rule, command) for rule in self.ask)

    def test_askRules_dangerousCommandForms_prompt(self):
        # Arrange
        commands = [
            "git log --output=x", "git log -p --output x", "git -C . log --output=x",
            "git --no-pager diff --output x", "git diff-files --output=x", "git range-diff --output=x a b",
            "git whatchanged --output=x", "git blame --output=x a.txt",
            "git blame --contents f a.txt", "git blame --cont=f a.txt", "git -C . blame --con f a.txt",
            "git config --get --file ~/.pypirc pypi.password", "git config -f ~/.x --get k",
            "git config --get -f ~/.x k", "git config --get --blob HEAD:x k",
            "git config --get remote.origin.url",
            "git config --list", "git config -l", "git config --global --list", "git config --global -l",
            "gh auth status -t", "gh auth status --show-token", "gh auth status -ht",
            "git push --force", "git push --force-with-lease origin x", "git push -f",
            "git push origin -f", "git push -uf origin x", "git push origin +main",
            'git push o "+HEAD:x"', "git push --mirror", "git push origin --delete x",
            "git push -d origin x", "git push --no-verify origin main",
            "git -C . push --force", "git commit --amend", "git commit --am -m x",
            "git commit -a --amend --no-edit", "git -C . commit --amend",
        ]
        for command in commands:
            with self.subTest(command=command):
                # Act
                prompted = self.prompts(command)
                # Assert
                self.assertTrue(prompted)

    def test_askRules_routineCommands_doNotPrompt(self):
        # Arrange
        commands = [
            "git log --oneline", "git -C . log --oneline", "git diff --stat", "git show HEAD",
            "git blame a.txt", "git describe --contains HEAD", "git config --get user.email",
            "gh auth status", "git push origin feature-foo",
            "git push -u origin branches/206-settings-lockdown", "git push origin HEAD:refs/heads/x",
            "git commit -m x", 'git -C /repo commit -m "Opt out" -- CLAUDE.md',
        ]
        for command in commands:
            with self.subTest(command=command):
                # Act
                prompted = self.prompts(command)
                # Assert
                self.assertFalse(prompted)

    def test_askRules_azOrgOrGhOtherHost_prompt(self):
        # Arrange
        commands = [
            "az boards work-item show --id 5 --org https://example.invalid",
            "az boards work-item show --id 5 --org=http://127.0.0.1:9",
            "az boards query --wiql x --organization https://example.invalid",
            "az repos pr show --id 1 --orga https://example.invalid",
            "az repos pr list --org https://dev.azure.com.example.invalid/x",
            "az pipelines runs list --org https://bgvone.visualstudio.com@example.invalid",
            "az pipelines show --id 1 --org 'https://example.invalid'",
            "gh pr view 12 -R example.invalid/o/r", "gh pr view -Rexample.invalid/o/r 12",
            "gh pr view 12 --repo example.invalid/o/r", "gh pr view 12 --repo=example.invalid/o/r",
            "gh pr view 12 -R git@example.invalid:o/r", "gh run view 5 -R https://example.invalid/o/r",
            "gh issue view https://example.invalid/o/r/issues/1",
            "gh pr view HTTPS://example.invalid/o/r/pull/1", "gh pr diff http://example.invalid/o/r/pull/1",
            "gh repo view example.invalid/o/r", "gh repo view https://example.invalid/o/r",
            "gh release view v1 --repo example.invalid/o/r", "gh label list -R example.invalid/o/r",
        ]
        for command in commands:
            with self.subTest(command=command):
                # Act
                prompted = self.prompts(command)
                # Assert
                self.assertTrue(prompted)

    def test_askRules_azWithTeamOrg_stillPromptsBecauseOneValueCannotBeExempted(self):
        # Arrange: ask is checked before allow and a glob cannot say "anything but X",
        # so the team's own org prompts too; omit --org to run without a prompt.
        commands = [
            "az boards work-item show --id 5 --org https://dev.azure.com/bgvone",
            "az repos pr show --id 1 --organization https://bgvone.visualstudio.com",
        ]
        for command in commands:
            with self.subTest(command=command):
                # Act
                prompted = self.prompts(command)
                # Assert
                self.assertTrue(prompted)

    def test_askRules_azDevopsExtensionCommands_promptWithOrWithoutDetectFalse(self):
        # Arrange: without --detect false these contact a host taken from the git
        # remotes; a glob cannot tell the two forms apart, so both prompt.
        commands = [
            "az boards work-item show --id 5", "az boards work-item show --id 5 -o json",
            "az boards work-item show --id 5 --detect false -o json",
            "az boards query --wiql \"SELECT [System.Id] FROM WorkItems\"",
            "az repos pr show --id 1", "az repos pr list --status active",
            "az pipelines show --id 1", "az pipelines runs show --id 1",
            "az pipelines runs list --top 5", "az devops project list",
            "az artifacts universal download --name x --version 1 --path .",
            "az --only-show-errors boards work-item show --id 5",
        ]
        for command in commands:
            with self.subTest(command=command):
                # Act
                prompted = self.prompts(command)
                # Assert
                self.assertTrue(prompted)

    def test_askRules_removedAzGrants_areRevoked(self):
        # Arrange: setup-env merges by union, so these old grants stay on synced
        # machines; an ask rule must match every command they allowed.
        removed = ["az boards work-item show", "az boards query", "az repos pr show",
                   "az repos pr list", "az pipelines show", "az pipelines runs show",
                   "az pipelines runs list"]
        for prefix in removed:
            with self.subTest(prefix=prefix):
                # Act
                prompted = self.prompts(prefix + " --id 1")
                # Assert
                self.assertTrue(prompted)
                self.assertNotIn(f"Bash({prefix}:*)", committed_settings()["permissions"]["allow"])

    def test_askRules_routineAzAndGhReads_doNotPrompt(self):
        # Arrange
        commands = [
            "az account show", "az account list -o table", "az extension list -o table",
            "az --version", "az version",
            "gh pr view 12", "gh pr view 12 -R TimZander/claude",
            "gh pr view 12 --repo TimZander/claude --json body --jq .body",
            "gh pr view 12 --repo=TimZander/claude", "gh pr list --author @me",
            "gh issue list --assignee @me", "gh issue view 7 --comments",
            "gh repo view TimZander/claude", "gh repo view", "gh run list -R TimZander/claude",
            "gh pr checks 12", "gh search issues \"settings lockdown\" --repo TimZander/claude",
        ]
        for command in commands:
            with self.subTest(command=command):
                # Act
                prompted = self.prompts(command)
                # Assert
                self.assertFalse(prompted)


if __name__ == "__main__":
    unittest.main(verbosity=1)
