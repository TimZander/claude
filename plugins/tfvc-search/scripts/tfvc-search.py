#!/usr/bin/env python3
"""
tfvc-search: search and read Azure DevOps TFVC content via REST.

Subcommands:
    grep   Recursive regex search under a TFVC scope path
    read   Fetch the full content of a single TFVC item
    ls     List files/folders under a TFVC path

Auth: picks up existing `az` CLI credentials via
`az account get-access-token --resource <ADO>`. Run `az login` first if unauthenticated.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from fnmatch import fnmatch
from functools import lru_cache
from pathlib import Path

ADO_RESOURCE_ID = "499b84ac-1321-427f-aa17-267ca6975798"
DEFAULT_API_VERSION = "7.1"
DEFAULT_HTTP_TIMEOUT = 30


@lru_cache(maxsize=1)
def get_access_token():
    try:
        result = subprocess.run(
            [
                "az", "account", "get-access-token",
                "--resource", ADO_RESOURCE_ID,
                "--query", "accessToken",
                "-o", "tsv",
            ],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()
    except FileNotFoundError:
        sys.exit("Error: 'az' CLI not found in PATH. Install the Azure CLI or ensure 'az' is available.")
    except subprocess.CalledProcessError as e:
        sys.exit(
            "Error: 'az account get-access-token' failed.\n"
            f"stderr: {e.stderr.strip()}\n"
            "Hint: run 'az login' if you are not authenticated."
        )


def _tfvc_items_base_url(org, project):
    """Build the /_apis/tfvc/items base URL with org and project URL-encoded."""
    return (
        f"https://dev.azure.com/{urllib.parse.quote(org, safe='')}"
        f"/{urllib.parse.quote(project, safe='')}/_apis/tfvc/items"
    )


def _ado_request(url, accept, *, fatal=True):
    """GET a TFVC URL. Returns response bytes on success, or None on error when fatal=False.
    When fatal=True (default), exits the process on any HTTP/network error."""
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {get_access_token()}",
            "Accept": accept,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_HTTP_TIMEOUT) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        msg = f"Error: TFVC API call failed: {e.code} {e.reason}\nURL: {url}\nResponse: {body}"
    except urllib.error.URLError as e:
        msg = f"Error: TFVC API call failed to reach server: {e.reason}\nURL: {url}"
    if fatal:
        sys.exit(msg)
    print(msg, file=sys.stderr)
    return None


def tfvc_items_list(org, project, scope_path, recursion_level):
    """Enumerate items under a scope. Returns list of item dicts with at least 'path' and 'isFolder'."""
    base_url = _tfvc_items_base_url(org, project)
    query = urllib.parse.urlencode({
        "scopePath": scope_path,
        "recursionLevel": recursion_level,
        "api-version": DEFAULT_API_VERSION,
    })
    data = json.loads(_ado_request(f"{base_url}?{query}", "application/json").decode("utf-8"))
    return data.get("value", [])


def tfvc_item_content(org, project, path, *, fatal=True):
    """Fetch raw content of a single TFVC item. Returns decoded text, or None when fatal=False and the fetch fails."""
    base_url = _tfvc_items_base_url(org, project)
    query = urllib.parse.urlencode({"path": path, "api-version": DEFAULT_API_VERSION})
    raw = _ado_request(f"{base_url}?{query}", "text/plain", fatal=fatal)
    if raw is None:
        return None
    return _decode_content(raw)


def _decode_content(raw):
    """Decode TFVC content bytes — handles UTF-8 default and UTF-16 BOM fallback for SQL scripts."""
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        # 'utf-16' autodetects LE/BE from the BOM and strips it
        return raw.decode("utf-16", errors="replace")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace")


def mirror_lookup(mirror, mirror_prefix, tfvc_path):
    """Return local Path for a TFVC path if the mirror has it, else None."""
    if not (mirror and mirror_prefix):
        return None
    if not tfvc_path.startswith(mirror_prefix):
        return None
    rel = tfvc_path[len(mirror_prefix):].lstrip("/\\")
    local = Path(mirror) / rel
    return local if local.is_file() else None


def _paths_equal_ci(a, b):
    """Compare TFVC paths case-insensitively and ignoring trailing slashes.

    ADO normalizes scope paths in responses but the exact shape (case, trailing slash)
    varies across endpoints and API versions — normalize both sides to be safe.
    """
    return a.rstrip("/").lower() == b.rstrip("/").lower()


def cmd_ls(args):
    items = tfvc_items_list(
        args.org, args.project, args.scope,
        "Full" if args.recursive else "OneLevel",
    )
    for item in items:
        path = item.get("path", "")
        # The scope itself is included in the response — skip it to mirror 'ls' semantics.
        if _paths_equal_ci(path, args.scope):
            continue
        suffix = "/" if item.get("isFolder") else ""
        print(f"{path}{suffix}")


def cmd_read(args):
    local = mirror_lookup(args.mirror, args.mirror_prefix, args.path)
    if local is not None:
        sys.stdout.write(_decode_content(local.read_bytes()))
        return
    sys.stdout.write(tfvc_item_content(args.org, args.project, args.path))


def cmd_grep(args):
    try:
        pattern = re.compile(args.pattern)
    except re.error as e:
        sys.exit(f"Error: invalid regex {args.pattern!r}: {e}")

    # Fast path: if mirror covers the full scope, walk it directly (no REST)
    if args.mirror and args.mirror_prefix and args.scope.startswith(args.mirror_prefix):
        scope_rel = args.scope[len(args.mirror_prefix):].lstrip("/\\")
        root = Path(args.mirror) / scope_rel if scope_rel else Path(args.mirror)
        if root.is_dir():
            _grep_local(root, args, pattern)
            return

    # REST path: enumerate, then fetch each file, preferring mirror on a per-file basis.
    # Per-file failures (404 from a race, 403 on an ACL'd file) log to stderr and skip
    # rather than aborting the whole operation — partial results beat total failure.
    items = tfvc_items_list(args.org, args.project, args.scope, "Full")
    for item in items:
        if item.get("isFolder"):
            continue
        path = item.get("path", "")
        if args.file_glob and not fnmatch(Path(path).name, args.file_glob):
            continue
        local = mirror_lookup(args.mirror, args.mirror_prefix, path)
        if local:
            content = _decode_content(local.read_bytes())
        else:
            content = tfvc_item_content(args.org, args.project, path, fatal=False)
            if content is None:
                continue
        _emit_matches(path, content, pattern)


def _grep_local(root, args, pattern):
    """Walk a local mirror directly and emit TFVC-style paths."""
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if args.file_glob and not fnmatch(name, args.file_glob):
                continue
            f = Path(dirpath) / name
            try:
                content = _decode_content(f.read_bytes())
            except OSError:
                continue
            rel = f.relative_to(args.mirror).as_posix()
            tfvc_path = f"{args.mirror_prefix.rstrip('/')}/{rel}"
            _emit_matches(tfvc_path, content, pattern)


def _emit_matches(path, content, pattern):
    for i, line in enumerate(content.splitlines(), start=1):
        if pattern.search(line):
            print(f"{path}:{i}:{line}")


def build_parser():
    parser = argparse.ArgumentParser(
        prog="tfvc-search",
        description="Search and read Azure DevOps TFVC content without a local workspace.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(p, *, need_scope):
        p.add_argument("--org", required=True, help="ADO organization name (e.g. 'myorg') or full URL")
        p.add_argument("--project", required=True, help="ADO project name")
        if need_scope:
            p.add_argument("--scope", required=True, help="TFVC scope path (e.g. '$/Foo/Bar')")
        p.add_argument("--mirror", help="Optional local directory mirroring a TFVC subtree; prefer over REST when the file is present")
        p.add_argument("--mirror-prefix", help="TFVC path that the mirror's root maps to (required with --mirror)")

    p_grep = sub.add_parser("grep", help="Recursive regex search under a TFVC scope")
    add_common(p_grep, need_scope=True)
    p_grep.add_argument("--pattern", required=True, help="Python regex to search for")
    p_grep.add_argument("--file-glob", help="Filter filenames by glob (e.g. '*.sql')")
    p_grep.set_defaults(func=cmd_grep)

    p_read = sub.add_parser("read", help="Read content of a single TFVC item")
    add_common(p_read, need_scope=False)
    p_read.add_argument("--path", required=True, help="TFVC item path (e.g. '$/Foo/Bar/File.sql')")
    p_read.set_defaults(func=cmd_read)

    p_ls = sub.add_parser("ls", help="List items under a TFVC path")
    add_common(p_ls, need_scope=True)
    p_ls.add_argument("--recursive", action="store_true", help="Recurse into subfolders")
    p_ls.set_defaults(func=cmd_ls)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if bool(args.mirror) != bool(args.mirror_prefix):
        parser.error("--mirror and --mirror-prefix must be given together")

    if args.mirror:
        args.mirror = args.mirror.rstrip("/\\")

    # Accept either 'myorg' or 'https://dev.azure.com/myorg'
    if args.org.startswith(("http://", "https://")):
        args.org = args.org.rstrip("/").rsplit("/", 1)[-1]

    args.func(args)


if __name__ == "__main__":
    main()
