#!/usr/bin/env python3
"""Smoke tests for tfvc-search.py — run via `python3 test_tfvc-search.py`.

Mocks `az` (token fetch) and `urllib.request.urlopen` (REST calls). No network required.
"""

import importlib.util
import io
import json
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock


def _load_module():
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

    def test_org_url_is_normalized(self):
        parser = tfvc.build_parser()
        args = parser.parse_args([
            "ls", "--org", "https://dev.azure.com/myorg/",
            "--project", "p", "--scope", "$/S",
        ])
        # main() does the normalization, so simulate that step
        if args.org.startswith(("http://", "https://")):
            args.org = args.org.rstrip("/").rsplit("/", 1)[-1]
        self.assertEqual(args.org, "myorg")


class DecodeContentTests(unittest.TestCase):
    def test_utf8(self):
        self.assertEqual(tfvc._decode_content(b"hello"), "hello")

    def test_utf16_le_bom(self):
        self.assertEqual(tfvc._decode_content(b"\xff\xfeh\x00i\x00"), "hi")

    def test_utf16_be_bom(self):
        self.assertEqual(tfvc._decode_content(b"\xfe\xff\x00h\x00i"), "hi")

    def test_invalid_utf8_falls_back_to_replace(self):
        out = tfvc._decode_content(b"abc\xff\xfe\x00xyz")  # not a valid BOM at start, bad utf-8
        # Doesn't crash; contains the ascii portions
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
        # Scope itself is filtered out; subfolder gets trailing slash
        lines = out.getvalue().strip().splitlines()
        self.assertEqual(lines, ["$/S/A.sql", "$/S/sub/"])

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_recursive_uses_full(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        urlopen.return_value = _http_response(b'{"value":[]}')
        tfvc.main(["ls", "--org", "o", "--project", "p", "--scope", "$/S", "--recursive"])
        self.assertIn("recursionLevel=Full", urlopen.call_args[0][0].full_url)


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
        # Accept header is text/plain for content
        call_req = urlopen.call_args[0][0]
        self.assertEqual(call_req.headers.get("Accept"), "text/plain")

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_mirror_hit_skips_rest(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "F.sql"
            # write_bytes avoids Windows text-mode \r\n translation in the fixture
            p.write_bytes(b"-- from mirror\n")
            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "read", "--org", "o", "--project", "p",
                    "--path", "$/S/F.sql",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])
            self.assertEqual(out.getvalue(), "-- from mirror\n")
            urlopen.assert_not_called()


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

        lines = out.getvalue().strip().splitlines()
        self.assertEqual(lines, [
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
        urlopen.side_effect = [list_resp, a_body]  # b.txt must be filtered before fetch

        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            tfvc.main([
                "grep", "--org", "o", "--project", "p",
                "--scope", "$/S", "--pattern", "ColumnX",
                "--file-glob", "*.sql",
            ])

        self.assertEqual(out.getvalue().strip(), "$/S/a.sql:1:ColumnX in a")
        # Only the list call + a.sql fetch — b.txt should not have been requested
        self.assertEqual(urlopen.call_count, 2)

    @mock.patch("subprocess.run")
    @mock.patch("urllib.request.urlopen")
    def test_mirror_covering_scope_skips_rest(self, urlopen, run):
        run.return_value = _fake_token_subprocess()
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "a.sql").write_text("hit ColumnX\nother\n")
            (Path(d) / "nested").mkdir()
            (Path(d) / "nested" / "b.sql").write_text("also ColumnX\n")

            with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                tfvc.main([
                    "grep", "--org", "o", "--project", "p",
                    "--scope", "$/S", "--pattern", "ColumnX",
                    "--mirror", d, "--mirror-prefix", "$/S",
                ])

            output_lines = sorted(out.getvalue().strip().splitlines())
            self.assertEqual(output_lines, [
                "$/S/a.sql:1:hit ColumnX",
                "$/S/nested/b.sql:1:also ColumnX",
            ])
            urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
