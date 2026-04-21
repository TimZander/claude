#!/usr/bin/env python3
"""Smoke tests for tfvc-search.py — run via `python test_tfvc-search.py`.

Mocks `az` (token fetch) and `urllib.request.urlopen` (REST calls). No network required.
"""

import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


def _load_module():
    # Filename has a hyphen, so import via spec rather than `import tfvc_search`.
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("tfvc_search", here / "tfvc-search.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tfvc = _load_module()


def _fake_token_subprocess():
    result = mock.Mock()
    result.stdout = "FAKE_TOKEN\n"
    result.returncode = 0
    return result


def _http_response(body_bytes):
    resp = mock.MagicMock()
    resp.__enter__.return_value = resp
    resp.read.return_value = body_bytes
    return resp


def _http_error(code=500, reason="Server Error", body=b""):
    return urllib.error.HTTPError(
        url="https://example.com",
        code=code,
        msg=reason,
        hdrs={},
        fp=io.BytesIO(body),
    )


class CliValidationTests(unittest.TestCase):
    # argparse writes validation errors to stderr and exits with code 2. Assertions
    # check stderr content (not just "any SystemExit") so a regression where the
    # exit happens for an unrelated reason (e.g., az-not-found) would fail the test.

    def test_no_subcommand_errors(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err, self.assertRaises(SystemExit):
            tfvc.main([])
        self.assertIn("required", err.getvalue().lower())

    def test_grep_requires_pattern(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err, self.assertRaises(SystemExit):
            tfvc.main(["grep", "--org", "o", "--project", "p", "--scope", "$/S"])
        self.assertIn("--pattern", err.getvalue())

    def test_mirror_without_prefix_errors(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err, self.assertRaises(SystemExit):
            tfvc.main([
                "read", "--org", "o", "--project", "p",
                "--path", "$/S/F.sql", "--mirror", "/tmp/m",
            ])
        self.assertIn("--mirror and --mirror-prefix", err.getvalue())

    def test_mirror_prefix_without_mirror_errors(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err, self.assertRaises(SystemExit):
            tfvc.main([
                "read", "--org", "o", "--project", "p",
                "--path", "$/S/F.sql", "--mirror-prefix", "$/S",
            ])
        self.assertIn("--mirror and --mirror-prefix", err.getvalue())


class MsysMangleTests(unittest.TestCase):
    """_check_msys_mangle rejects both mangled shapes and runs before other validation."""

    def test_dollar_preserved_form_is_rejected(self):
        # Form 1: bash preserved '$', MSYS rewrote to '$C:/...'.
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$C:/Program Files/Git/Foo"])
        self.assertIn("MSYS_NO_PATHCONV=1", str(cm.exception))

    def test_dollar_stripped_form_is_rejected(self):
        # Form 2: bash ate '$' as undefined variable (empty), leaving '/Foo',
        # which MSYS then rewrote to 'C:/Program Files/Git/Foo' (no '$').
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "C:/Program Files/Git/Foo/Bar"])
        self.assertIn("MSYS_NO_PATHCONV=1", str(cm.exception))

    def test_path_flag_is_checked(self):
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["read", "--org", "o", "--project", "p", "--path", "$C:/Program Files/Git/Foo/F.sql"])
        self.assertIn("--path", str(cm.exception))

    def test_mirror_prefix_flag_is_checked(self):
        # --mirror-prefix is the third TFVC-path flag; make sure the check loop hits it too.
        with self.assertRaises(SystemExit) as cm:
            tfvc.main([
                "ls", "--org", "o", "--project", "p", "--scope", "$/S",
                "--mirror", "/tmp/m", "--mirror-prefix", "$C:/mangled",
            ])
        self.assertIn("--mirror-prefix", str(cm.exception))

    def test_valid_tfvc_path_passes_through(self):
        # Negative: a correctly-formed '$/Foo/Bar' must NOT trigger the check.
        # We mock the backends so the call goes through to a successful ls.
        with mock.patch("subprocess.run") as run, mock.patch("urllib.request.urlopen") as urlopen:
            run.return_value = _fake_token_subprocess()
            urlopen.return_value = _http_response(b'{"value":[]}')
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/Foo/Bar"])
            urlopen.assert_called_once()

    def test_msys_check_runs_before_mirror_symmetry_check(self):
        # If the user passes a mangled --mirror-prefix AND forgets --mirror, they should
        # see the specific MSYS hint rather than the generic "must be given together" error.
        with self.assertRaises(SystemExit) as cm:
            tfvc.main([
                "ls", "--org", "o", "--project", "p", "--scope", "$/S",
                "--mirror-prefix", "$C:/mangled",
            ])
        # Expect MSYS message, not the symmetry message.
        msg = str(cm.exception)
        self.assertIn("MSYS_NO_PATHCONV=1", msg)
        self.assertNotIn("must be given together", msg)


class OrgNormalizationTests(unittest.TestCase):
    """_normalize_org extracts the org from bare names, modern URLs, and legacy URLs."""

    def test_bare_org_unchanged(self):
        self.assertEqual(tfvc._normalize_org("myorg"), "myorg")

    def test_modern_url_single_path(self):
        self.assertEqual(tfvc._normalize_org("https://dev.azure.com/myorg"), "myorg")

    def test_modern_url_trailing_slash(self):
        self.assertEqual(tfvc._normalize_org("https://dev.azure.com/myorg/"), "myorg")

    def test_modern_url_with_project_takes_first_segment(self):
        # Critical regression: a user pasting a full browser URL would previously have
        # been silently normalized to 'myproject'. Now it's correctly 'myorg'.
        self.assertEqual(
            tfvc._normalize_org("https://dev.azure.com/myorg/myproject"),
            "myorg",
        )

    def test_modern_url_with_deep_path(self):
        self.assertEqual(
            tfvc._normalize_org("https://dev.azure.com/myorg/myproject/_git/repo"),
            "myorg",
        )

    def test_legacy_visualstudio_com_url(self):
        self.assertEqual(
            tfvc._normalize_org("https://myorg.visualstudio.com/"),
            "myorg",
        )

    def test_legacy_visualstudio_com_url_with_path(self):
        self.assertEqual(
            tfvc._normalize_org("https://myorg.visualstudio.com/myproject/_apis/tfvc"),
            "myorg",
        )

    def test_http_not_https(self):
        self.assertEqual(tfvc._normalize_org("http://dev.azure.com/myorg/"), "myorg")

    def test_unknown_url_shape_passes_through(self):
        # If we don't recognize the host, leave as-is — the REST call will surface the mistake.
        weird = "https://example.com/something"
        self.assertEqual(tfvc._normalize_org(weird), weird)


class PathIsUnderTests(unittest.TestCase):
    def test_exact_equality(self):
        self.assertTrue(tfvc._path_is_under("$/Foo/Bar", "$/Foo/Bar"))

    def test_descendant(self):
        self.assertTrue(tfvc._path_is_under("$/Foo/Bar/baz.sql", "$/Foo/Bar"))

    def test_string_prefix_but_not_path_prefix_rejected(self):
        # The critical bug fix: '$/Foobar' is a string prefix of '$/Foo' but NOT a path descendant.
        self.assertFalse(tfvc._path_is_under("$/Foobar", "$/Foo"))
        self.assertFalse(tfvc._path_is_under("$/Foobar/file.sql", "$/Foo"))

    def test_case_insensitive_equality(self):
        # TFVC is case-insensitive on Windows-backed ADO.
        self.assertTrue(tfvc._path_is_under("$/FOO/BAR", "$/foo/bar"))

    def test_case_insensitive_descendant(self):
        self.assertTrue(tfvc._path_is_under("$/foo/BAR/File.sql", "$/FOO/bar"))

    def test_trailing_slash_tolerance(self):
        self.assertTrue(tfvc._path_is_under("$/Foo/", "$/Foo"))
        self.assertTrue(tfvc._path_is_under("$/Foo", "$/Foo/"))

    def test_unrelated_paths(self):
        self.assertFalse(tfvc._path_is_under("$/Bar/baz.sql", "$/Foo"))


class DecodeContentTests(unittest.TestCase):
    def test_utf8(self):
        self.assertEqual(tfvc._decode_content(b"hello"), "hello")

    def test_utf8_bom_stripped(self):
        # UTF-8 BOM must be stripped so line-anchored regex (e.g. `^CREATE`) matches line 1.
        self.assertEqual(tfvc._decode_content(b"\xef\xbb\xbfCREATE PROC Foo\n"), "CREATE PROC Foo\n")

    def test_utf16_le_bom(self):
        self.assertEqual(tfvc._decode_content(b"\xff\xfeh\x00i\x00"), "hi")

    def test_utf16_be_bom(self):
        self.assertEqual(tfvc._decode_content(b"\xfe\xff\x00h\x00i"), "hi")

    def test_invalid_utf8_falls_back_to_replace(self):
        out = tfvc._decode_content(b"abc\x80\x81xyz")  # invalid UTF-8, no BOM at start
        self.assertIn("abc", out)
        self.assertIn("xyz", out)


class MirrorLookupTests(unittest.TestCase):
    def test_miss_when_mirror_not_set(self):
        self.assertIsNone(tfvc.mirror_lookup(None, None, "$/S/F.sql"))

    def test_miss_when_path_outside_prefix(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(tfvc.mirror_lookup(d, "$/OTHER", "$/S/F.sql"))

    def test_hit_when_file_exists(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sub" / "F.sql"
            p.parent.mkdir(parents=True)
            p.write_text("contents")
            got = tfvc.mirror_lookup(d, "$/S", "$/S/sub/F.sql")
            self.assertEqual(got, p)

    def test_miss_when_file_absent(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(tfvc.mirror_lookup(d, "$/S", "$/S/absent.sql"))

    def test_case_insensitive_match(self):
        # Mirror prefix in one case, TFVC path in another — should still hit.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sub" / "F.sql"
            p.parent.mkdir(parents=True)
            p.write_text("contents")
            got = tfvc.mirror_lookup(d, "$/s", "$/S/sub/F.sql")
            self.assertEqual(got, p)

    def test_string_prefix_boundary_mismatch_rejected(self):
        # '$/Foobar' is a string prefix of '$/Foo' but should not resolve to the mirror.
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "bar" / "F.sql").parent.mkdir(parents=True)
            (Path(d) / "bar" / "F.sql").write_text("x")
            # If the old buggy logic stripped "$/Foo" from "$/Foobar/F.sql" it would
            # look for `d/bar/F.sql` and (coincidentally) find it. Case-boundary check
            # prevents that.
            self.assertIsNone(tfvc.mirror_lookup(d, "$/Foo", "$/Foobar/F.sql"))


class AuthTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("shutil.which", return_value=None)
    def test_missing_az_cli_exits_with_hint(self, _which):
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S"])
        self.assertIn("'az' CLI not found", str(cm.exception))

    @mock.patch("subprocess.run")
    def test_az_login_required_exits_with_hint(self, run):
        run.side_effect = subprocess.CalledProcessError(
            returncode=1, cmd=["az"], stderr="Please run 'az login' to setup account.\n",
        )
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S"])
        self.assertIn("az login", str(cm.exception))


class CmdLsTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_non_recursive_uses_onelevel(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(json.dumps({
            "value": [
                {"path": "$/S", "isFolder": True},
                {"path": "$/S/A.sql", "isFolder": False},
                {"path": "$/S/sub", "isFolder": True},
            ],
        }).encode())

        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S"])

        called_url = urlopen.call_args[0][0].full_url
        self.assertIn("recursionLevel=OneLevel", called_url)
        self.assertEqual(out.getvalue().strip().splitlines(), ["$/S/A.sql", "$/S/sub/"])

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_recursive_uses_full(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S", "--recursive"])
        self.assertIn("recursionLevel=Full", urlopen.call_args[0][0].full_url)

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_scope_with_trailing_slash_is_filtered(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(json.dumps({
            "value": [
                {"path": "$/S/", "isFolder": True},
                {"path": "$/S/A.sql", "isFolder": False},
            ],
        }).encode())
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S"])
        self.assertEqual(out.getvalue().strip().splitlines(), ["$/S/A.sql"])

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_scope_filter_is_case_insensitive(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(json.dumps({
            "value": [
                {"path": "$/FOO", "isFolder": True},
                {"path": "$/FOO/A.sql", "isFolder": False},
            ],
        }).encode())
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/foo"])
        self.assertEqual(out.getvalue().strip().splitlines(), ["$/FOO/A.sql"])


class CmdReadTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_rest_path(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b"SELECT 1;\n")
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main(["read", "--org", "o", "--project", "p", "--path", "$/S/F.sql"])
        self.assertEqual(out.getvalue(), "SELECT 1;\n")
        self.assertEqual(urlopen.call_args[0][0].headers.get("Accept"), "text/plain")

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_mirror_hit_skips_rest(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "F.sql").write_bytes(b"-- from mirror\n")
            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "read", "--org", "o", "--project", "p",
                    "--path", "$/S/F.sql",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])
            self.assertEqual(out.getvalue(), "-- from mirror\n")
            urlopen.assert_not_called()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_mirror_miss_falls_back_to_rest(self, urlopen, run):
        # With --mirror set but the file not on disk, fall through to REST.
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b"from rest\n")
        with tempfile.TemporaryDirectory() as d:
            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "read", "--org", "o", "--project", "p",
                    "--path", "$/S/absent.sql",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])
            self.assertEqual(out.getvalue(), "from rest\n")
            urlopen.assert_called_once()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_http_404_exits_fatally(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.side_effect = _http_error(code=404, reason="Not Found", body=b'{"message":"not found"}')
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["read", "--org", "o", "--project", "p", "--path", "$/S/missing.sql"])
        msg = str(cm.exception)
        self.assertIn("404", msg)
        self.assertIn("Not Found", msg)

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_url_error_exits_with_network_hint(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.side_effect = urllib.error.URLError("Connection timed out")
        with self.assertRaises(SystemExit) as cm:
            tfvc.main(["read", "--org", "o", "--project", "p", "--path", "$/S/F.sql"])
        self.assertIn("failed to reach server", str(cm.exception))

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_project_with_spaces_is_url_encoded(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b"")
        tfvc.main(["read", "--org", "o", "--project", "BGV Databases", "--path", "$/S/F.sql"])
        called_url = urlopen.call_args[0][0].full_url
        self.assertIn("/BGV%20Databases/", called_url)
        self.assertNotIn("BGV Databases", called_url)


class CmdGrepTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_rest_emits_path_line_text(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        list_resp = _http_response(json.dumps({
            "value": [
                {"path": "$/S/a.sql", "isFolder": False},
                {"path": "$/S/b.txt", "isFolder": False},
            ],
        }).encode())
        a_body = _http_response(b"line one\nhas ColumnX here\nline three\n")
        b_body = _http_response(b"ColumnX also in b\n")
        urlopen.side_effect = [list_resp, a_body, b_body]

        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "ColumnX",
            ])

        self.assertEqual(out.getvalue().strip().splitlines(), [
            "$/S/a.sql:2:has ColumnX here",
            "$/S/b.txt:1:ColumnX also in b",
        ])

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_file_glob_narrows(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        list_resp = _http_response(json.dumps({
            "value": [
                {"path": "$/S/a.sql", "isFolder": False},
                {"path": "$/S/b.txt", "isFolder": False},
            ],
        }).encode())
        a_body = _http_response(b"ColumnX in a\n")
        urlopen.side_effect = [list_resp, a_body]

        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "ColumnX",
                "--file-glob", "*.sql",
            ])

        self.assertEqual(out.getvalue().strip(), "$/S/a.sql:1:ColumnX in a")
        self.assertEqual(urlopen.call_count, 2)

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_mirror_covering_scope_skips_rest(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.sql").write_bytes(b"hit ColumnX\nother\n")
            (Path(d) / "nested").mkdir()
            (Path(d) / "nested" / "b.sql").write_bytes(b"also ColumnX\n")

            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "grep", "--org", "o", "--project", "p",
                    "--scope", "$/S", "--pattern", "ColumnX",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])

            self.assertEqual(sorted(out.getvalue().strip().splitlines()), [
                "$/S/a.sql:1:hit ColumnX",
                "$/S/nested/b.sql:1:also ColumnX",
            ])
            urlopen.assert_not_called()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_fast_path_rejects_non_boundary_prefix_match(self, urlopen, run):
        # The regression: '$/Foobar' scope with '$/Foo' mirror prefix used to take the
        # fast path (string-startswith true) and walk $MIRROR looking for nonexistent
        # children, emitting nothing when it should have fallen through to REST.
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')  # REST enumeration returns empty
        with tempfile.TemporaryDirectory() as d:
            # Put a file under the mirror that would've matched if the bug existed.
            (Path(d) / "F.sql").write_bytes(b"ColumnX\n")
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/Foobar", "--pattern", "ColumnX",
                "--mirror", d, "--mirror-prefix", "$/Foo",
            ])
            # If the fast path was (incorrectly) taken, urlopen would NOT be called.
            # The fix causes the fast path to be rejected → REST call happens.
            urlopen.assert_called_once()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_fast_path_case_insensitive(self, urlopen, run):
        # Mirror prefix and scope differ in case — fast path should still engage.
        run.return_value = _fake_token_subprocess()
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.sql").write_bytes(b"hit ColumnX\n")
            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "grep", "--org", "o", "--project", "p",
                    "--scope", "$/FOO", "--pattern", "ColumnX",
                    "--mirror", d, "--mirror-prefix", "$/foo",
                ])
            self.assertIn("ColumnX", out.getvalue())
            urlopen.assert_not_called()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_invalid_regex_exits_with_friendly_error(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        with self.assertRaises(SystemExit) as cm:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "(unclosed",
            ])
        self.assertIn("invalid regex", str(cm.exception))
        urlopen.assert_not_called()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_empty_scope_produces_no_output(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "anything",
            ])
        self.assertEqual(out.getvalue(), "")

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_per_file_http_error_is_logged_and_skipped(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        list_resp = _http_response(json.dumps({
            "value": [
                {"path": "$/S/a.sql", "isFolder": False},
                {"path": "$/S/b.sql", "isFolder": False},
            ],
        }).encode())
        a_error = _http_error(code=403, reason="Forbidden", body=b'{"message":"forbidden"}')
        b_body = _http_response(b"ColumnX is here\n")
        urlopen.side_effect = [list_resp, a_error, b_body]

        with mock.patch("sys.stdout", new_callable=io.StringIO) as out, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "ColumnX",
            ])

        self.assertEqual(out.getvalue().strip(), "$/S/b.sql:1:ColumnX is here")
        self.assertIn("403", err.getvalue())

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_list_call_failure_is_fatal(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.side_effect = _http_error(code=401, reason="Unauthorized", body=b"")
        with self.assertRaises(SystemExit) as cm:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "anything",
            ])
        # Tighten: assert the error refers to the 401, not just any SystemExit.
        self.assertIn("401", str(cm.exception))

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_grep_local_honors_file_glob(self, urlopen, run):
        # Local fast-path + --file-glob: ensure the glob filter applies during os.walk.
        run.return_value = _fake_token_subprocess()
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.sql").write_bytes(b"ColumnX here\n")
            (Path(d) / "b.txt").write_bytes(b"ColumnX here too\n")
            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "grep", "--org", "o", "--project", "p",
                    "--scope", "$/S", "--pattern", "ColumnX",
                    "--file-glob", "*.sql",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])
            output = out.getvalue()
            self.assertIn("a.sql", output)
            self.assertNotIn("b.txt", output)
            urlopen.assert_not_called()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_fast_path_stale_mirror_falls_back_with_warning(self, urlopen, run):
        # Mirror prefix claims to cover scope but the target directory doesn't exist
        # on disk — should emit a stderr warning AND fall through to REST.
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        with tempfile.TemporaryDirectory() as d:
            # Note: no `sub/` directory created.
            with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
                tfvc.main([
                    "grep", "--org", "o", "--project", "p",
                    "--scope", "$/S/sub", "--pattern", "anything",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])
            self.assertIn("Stale mirror", err.getvalue())
            urlopen.assert_called_once()


class TimeoutTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_urlopen_is_called_with_expected_timeout(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S"])
        _, kwargs = urlopen.call_args
        # Tighten: assert the actual configured value, not just "> 0".
        self.assertEqual(kwargs.get("timeout"), tfvc.DEFAULT_HTTP_TIMEOUT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
