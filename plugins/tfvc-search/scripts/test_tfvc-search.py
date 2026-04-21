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
import urllib.parse
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
    def test_no_subcommand_errors(self):
        with self.assertRaises(SystemExit):
            tfvc.main([])

    def test_grep_requires_pattern(self):
        with self.assertRaises(SystemExit):
            tfvc.main(["grep", "--org", "o", "--project", "p", "--scope", "$/S"])

    def test_mirror_without_prefix_errors(self):
        with self.assertRaises(SystemExit):
            tfvc.main([
                "read", "--org", "o", "--project", "p",
                "--path", "$/S/F.sql", "--mirror", "/tmp/m",
            ])

    def test_mirror_prefix_without_mirror_errors(self):
        with self.assertRaises(SystemExit):
            tfvc.main([
                "read", "--org", "o", "--project", "p",
                "--path", "$/S/F.sql", "--mirror-prefix", "$/S",
            ])

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_org_url_is_normalized_at_runtime(self, urlopen, run):
        # Functional check: pass a full dev.azure.com URL and verify the request URL
        # built by main() uses only the org name, not the full URL.
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        tfvc.main([
            "ls", "--org", "https://dev.azure.com/myorg/",
            "--project", "p", "--scope", "$/S",
        ])
        called_url = urlopen.call_args[0][0].full_url
        self.assertTrue(
            called_url.startswith("https://dev.azure.com/myorg/p/_apis/tfvc/items?"),
            f"Expected normalized org in URL, got: {called_url}",
        )


class DecodeContentTests(unittest.TestCase):
    def test_utf8(self):
        self.assertEqual(tfvc._decode_content(b"hello"), "hello")

    def test_utf16_le_bom(self):
        self.assertEqual(tfvc._decode_content(b"\xff\xfeh\x00i\x00"), "hi")

    def test_utf16_be_bom(self):
        self.assertEqual(tfvc._decode_content(b"\xfe\xff\x00h\x00i"), "hi")

    def test_invalid_utf8_falls_back_to_replace(self):
        out = tfvc._decode_content(b"abc\xff\xfe\x00xyz")  # not a valid BOM at start, bad utf-8
        self.assertIn("abc", out)


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


class AuthTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("subprocess.run", side_effect=FileNotFoundError())
    def test_missing_az_cli_exits_with_hint(self, _run):
        # Any REST call triggers token fetch, which should exit clearly.
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
        lines = out.getvalue().strip().splitlines()
        self.assertEqual(lines, ["$/S/A.sql", "$/S/sub/"])

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
        # ADO sometimes returns the scope folder with a trailing slash; make sure
        # the filter still skips it rather than emitting a spurious scope entry.
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
        # TFVC is case-insensitive; ADO's response may differ in casing from the caller's scope.
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
        self.assertIn("Connection timed out", str(cm.exception))

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_project_with_spaces_is_url_encoded(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b"")
        tfvc.main(["read", "--org", "o", "--project", "BGV Databases", "--path", "$/S/F.sql"])
        called_url = urlopen.call_args[0][0].full_url
        self.assertIn("/BGV%20Databases/", called_url)
        self.assertNotIn("BGV Databases", called_url)  # raw space should not appear


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
        self.assertEqual(urlopen.call_count, 2)  # list + a.sql; b.txt never fetched

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
    def test_invalid_regex_exits_with_friendly_error(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        # urlopen shouldn't be called because the regex fails to compile first
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
        # File a.sql 403s (policy/ACL), b.sql succeeds.
        # The whole grep must NOT abort — b.sql should still be searched.
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

        # b.sql match is printed; a.sql failure is in stderr but didn't abort.
        self.assertEqual(out.getvalue().strip(), "$/S/b.sql:1:ColumnX is here")
        self.assertIn("403", err.getvalue())
        self.assertIn("Forbidden", err.getvalue())

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_list_call_failure_is_fatal(self, urlopen, run):
        # If the enumeration itself fails, there's nothing to grep — abort.
        run.return_value = _fake_token_subprocess()
        urlopen.side_effect = _http_error(code=401, reason="Unauthorized", body=b"")
        with self.assertRaises(SystemExit):
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "anything",
            ])


class TimeoutTests(unittest.TestCase):
    def setUp(self):
        tfvc.get_access_token.cache_clear()

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_urlopen_is_called_with_timeout(self, urlopen, run):
        # Belt-and-suspenders: ensure we never call urlopen without a timeout,
        # or the script can hang indefinitely on network hiccups.
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S"])
        _, kwargs = urlopen.call_args
        self.assertIn("timeout", kwargs)
        self.assertIsNotNone(kwargs["timeout"])
        self.assertGreater(kwargs["timeout"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
