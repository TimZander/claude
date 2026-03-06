#!/usr/bin/env python3
"""Tests for har_parse.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

from har_parse import (
    parse_body,
    headers_to_dict,
    extract_string_values,
    find_value_in_request,
    analyze_har,
    _is_static_asset,
)


# ---------------------------------------------------------------------------
# Helper to build minimal HAR structures
# ---------------------------------------------------------------------------

def _make_entry(method="GET", url="https://api.example.com/v1/resource",
                req_headers=None, req_body=None, req_mime=None,
                status=200, status_text="OK",
                resp_headers=None, resp_body=None, resp_mime="application/json",
                time_ms=50, post_data_params=None):
    entry = {
        "request": {
            "method": method,
            "url": url,
            "headers": req_headers or [],
        },
        "response": {
            "status": status,
            "statusText": status_text,
            "headers": resp_headers or [],
            "content": {
                "mimeType": resp_mime,
            },
        },
        "time": time_ms,
    }
    if req_body is not None:
        post_data = {"text": req_body}
        if req_mime:
            post_data["mimeType"] = req_mime
        entry["request"]["postData"] = post_data
    elif post_data_params is not None:
        post_data = {"params": post_data_params}
        if req_mime:
            post_data["mimeType"] = req_mime
        entry["request"]["postData"] = post_data
    if resp_body is not None:
        if isinstance(resp_body, str):
            entry["response"]["content"]["text"] = resp_body
        else:
            entry["response"]["content"]["text"] = json.dumps(resp_body)
    return entry


def _make_har(*entries):
    return {"log": {"entries": list(entries)}}


# ===========================================================================
# parse_body
# ===========================================================================

class TestParseBody(unittest.TestCase):
    def test_ParseBody_ValidJson_ReturnsParsedDict(self):
        result = parse_body('{"key": "value"}')
        self.assertEqual(result, {"key": "value"})

    def test_ParseBody_ValidJsonArray_ReturnsParsedList(self):
        result = parse_body('[1, 2, 3]')
        self.assertEqual(result, [1, 2, 3])

    def test_ParseBody_InvalidJson_ReturnsRawText(self):
        result = parse_body("not json at all")
        self.assertEqual(result, "not json at all")

    def test_ParseBody_NoneInput_ReturnsNone(self):
        result = parse_body(None)
        self.assertIsNone(result)

    def test_ParseBody_EmptyString_ReturnsNone(self):
        result = parse_body("")
        self.assertIsNone(result)

    def test_ParseBody_WhitespaceOnly_ReturnsNone(self):
        result = parse_body("   \n  ")
        self.assertIsNone(result)

    def test_ParseBody_LongText_TruncatesWithMessage(self):
        max_length = 100
        long_text = "x" * 200

        result = parse_body(long_text, max_length=max_length)

        self.assertTrue(result.startswith("x" * max_length))
        self.assertIn("truncated", result)
        self.assertIn("200 chars total", result)

    def test_ParseBody_TextAtMaxLength_NoTruncation(self):
        max_length = 100
        text = "x" * max_length

        result = parse_body(text, max_length=max_length)

        self.assertEqual(result, text)


# ===========================================================================
# headers_to_dict
# ===========================================================================

class TestHeadersToDict(unittest.TestCase):
    def test_HeadersToDict_SingleHeaders_ReturnsFlatDict(self):
        headers = [
            {"name": "Content-Type", "value": "application/json"},
            {"name": "Authorization", "value": "Bearer tok123"},
        ]

        result = headers_to_dict(headers)

        self.assertEqual(result, {
            "Content-Type": "application/json",
            "Authorization": "Bearer tok123",
        })

    def test_HeadersToDict_DuplicateHeaders_ReturnsList(self):
        headers = [
            {"name": "Set-Cookie", "value": "a=1"},
            {"name": "Set-Cookie", "value": "b=2"},
        ]

        result = headers_to_dict(headers)

        self.assertEqual(result, {"Set-Cookie": ["a=1", "b=2"]})

    def test_HeadersToDict_TripleDuplicate_AppendsList(self):
        headers = [
            {"name": "X-Custom", "value": "first"},
            {"name": "X-Custom", "value": "second"},
            {"name": "X-Custom", "value": "third"},
        ]

        result = headers_to_dict(headers)

        self.assertEqual(result, {"X-Custom": ["first", "second", "third"]})

    def test_HeadersToDict_EmptyInput_ReturnsEmptyDict(self):
        result = headers_to_dict([])
        self.assertEqual(result, {})

    def test_HeadersToDict_MissingNameKey_SkipsEntry(self):
        headers = [
            {"value": "orphan_value"},
            {"name": "Valid", "value": "ok"},
        ]

        result = headers_to_dict(headers)

        self.assertEqual(result, {"Valid": "ok"})

    def test_HeadersToDict_MissingValueKey_SkipsEntry(self):
        headers = [
            {"name": "Orphan"},
            {"name": "Valid", "value": "ok"},
        ]

        result = headers_to_dict(headers)

        self.assertEqual(result, {"Valid": "ok"})


# ===========================================================================
# extract_string_values
# ===========================================================================

class TestExtractStringValues(unittest.TestCase):
    def test_ExtractStringValues_FlatDict_ExtractsLongStrings(self):
        min_length = 16
        obj = {"token": "abcdefghijklmnop", "short": "abc"}

        result = extract_string_values(obj)

        self.assertIn("abcdefghijklmnop", result)
        self.assertNotIn("abc", result)

    def test_ExtractStringValues_FlatDict_SkipsShortStrings(self):
        min_length = 16
        obj = {"token": "x" * (min_length - 1)}

        result = extract_string_values(obj)

        self.assertEqual(len(result), 0)

    def test_ExtractStringValues_NestedDict_ExtractsRecursively(self):
        obj = {"data": {"inner": {"token": "longtoken1234abcdef"}}}

        result = extract_string_values(obj)

        self.assertIn("longtoken1234abcdef", result)

    def test_ExtractStringValues_ListItems_ExtractsFromList(self):
        obj = ["longvalue1234abcd", "short"]

        result = extract_string_values(obj)

        self.assertIn("longvalue1234abcd", result)
        self.assertNotIn("short", result)

    def test_ExtractStringValues_MaxDepthExceeded_StopsRecursing(self):
        max_depth = 2
        obj = {"a": {"b": {"c": "deep_value_string_long"}}}

        result = extract_string_values(obj, max_depth=max_depth)

        self.assertNotIn("deep_value_string_long", result)

    def test_ExtractStringValues_ListCappedAt50_IgnoresExcess(self):
        list_cap = 50
        excess = 60
        obj = [f"value_{i:020d}" for i in range(excess)]

        result = extract_string_values(obj)

        self.assertIn(f"value_{0:020d}", result)
        self.assertIn(f"value_{list_cap - 1:020d}", result)
        self.assertNotIn(f"value_{list_cap:020d}", result)

    def test_ExtractStringValues_HtmlLikeStrings_Excluded(self):
        obj = {"markup": "<div>some html content here</div>"}

        result = extract_string_values(obj)

        self.assertEqual(len(result), 0)

    def test_ExtractStringValues_Urls_Included(self):
        obj = {"next": "https://api.example.com/page/2"}

        result = extract_string_values(obj)

        self.assertIn("https://api.example.com/page/2", result)

    def test_ExtractStringValues_VeryLongString_Excluded(self):
        limit = 4000
        obj = {"blob": "x" * (limit + 1)}

        result = extract_string_values(obj)

        self.assertEqual(len(result), 0)

    def test_ExtractStringValues_StringAtMaxLength_Included(self):
        limit = 4000
        obj = {"blob": "x" * limit}

        result = extract_string_values(obj)

        self.assertIn("x" * limit, result)


# ===========================================================================
# find_value_in_request
# ===========================================================================

class TestFindValueInRequest(unittest.TestCase):
    def test_FindValueInRequest_InUrl_ReturnsUrl(self):
        value = "token12345"
        url = "https://api.example.com/resource?token=token12345"

        result = find_value_in_request(value, url, {}, "")

        self.assertEqual(result, ["url"])

    def test_FindValueInRequest_InHeader_ReturnsHeaderName(self):
        value = "Bearer_token_value"
        headers = {"Authorization": "Bearer Bearer_token_value"}

        result = find_value_in_request(value, "https://example.com", headers, "")

        self.assertEqual(result, ["header:Authorization"])

    def test_FindValueInRequest_InBody_ReturnsBody(self):
        value = "session_id_12345"
        body = '{"session": "session_id_12345"}'

        result = find_value_in_request(value, "https://example.com", {}, body)

        self.assertEqual(result, ["body"])

    def test_FindValueInRequest_InMultipleLocations_ReturnsAll(self):
        value = "shared_value_abc"
        url = "https://example.com/shared_value_abc"
        headers = {"X-Token": "shared_value_abc"}
        body = '{"id": "shared_value_abc"}'

        result = find_value_in_request(value, url, headers, body)

        self.assertIn("url", result)
        self.assertIn("header:X-Token", result)
        self.assertIn("body", result)

    def test_FindValueInRequest_NotFound_ReturnsEmpty(self):
        result = find_value_in_request(
            "missing_value", "https://example.com", {"X-Other": "nope"}, "no match"
        )

        self.assertEqual(result, [])

    def test_FindValueInRequest_EmptyBody_NoBodyMatch(self):
        result = find_value_in_request("some_token", "https://example.com", {}, "")

        self.assertNotIn("body", result)


# ===========================================================================
# _is_static_asset
# ===========================================================================

class TestIsStaticAsset(unittest.TestCase):
    def test_IsStaticAsset_ImagePng_ReturnsTrue(self):
        entry = {"response": {"content": {"mimeType": "image/png"}}}
        self.assertTrue(_is_static_asset(entry))

    def test_IsStaticAsset_ApplicationJson_ReturnsFalse(self):
        entry = {"response": {"content": {"mimeType": "application/json"}}}
        self.assertFalse(_is_static_asset(entry))

    def test_IsStaticAsset_TextCss_ReturnsTrue(self):
        entry = {"response": {"content": {"mimeType": "text/css"}}}
        self.assertTrue(_is_static_asset(entry))

    def test_IsStaticAsset_MimeWithCharset_StillMatches(self):
        entry = {"response": {"content": {"mimeType": "text/css; charset=utf-8"}}}
        self.assertTrue(_is_static_asset(entry))

    def test_IsStaticAsset_EmptyMime_ReturnsFalse(self):
        entry = {"response": {"content": {"mimeType": ""}}}
        self.assertFalse(_is_static_asset(entry))

    def test_IsStaticAsset_NoContentKey_ReturnsFalse(self):
        entry = {"response": {}}
        self.assertFalse(_is_static_asset(entry))

    def test_IsStaticAsset_FontWoff2_ReturnsTrue(self):
        entry = {"response": {"content": {"mimeType": "font/woff2"}}}
        self.assertTrue(_is_static_asset(entry))


# ===========================================================================
# analyze_har — core behavior
# ===========================================================================

class TestAnalyzeHar(unittest.TestCase):
    def test_AnalyzeHar_EmptyEntries_ReturnsError(self):
        har = _make_har()

        result = analyze_har(har)

        self.assertIn("error", result)
        self.assertIn("No entries", result["error"])

    def test_AnalyzeHar_SingleGetRequest_CorrectSummary(self):
        entry = _make_entry()
        har = _make_har(entry)

        result = analyze_har(har)

        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertIn("api.example.com", result["summary"]["domains"])
        self.assertEqual(result["summary"]["methods"]["GET"], 1)
        self.assertEqual(result["summary"]["status_codes"][200], 1)

    def test_AnalyzeHar_QueryParams_Extracted(self):
        entry = _make_entry(url="https://api.example.com/search?q=test&page=1")
        har = _make_har(entry)

        result = analyze_har(har)
        call = result["calls"][0]

        self.assertEqual(call["request"]["query_params"]["q"], "test")
        self.assertEqual(call["request"]["query_params"]["page"], "1")

    def test_AnalyzeHar_DuplicateQueryParams_PreservedAsList(self):
        # Arrange
        entry = _make_entry(url="https://api.example.com/search?id=1&id=2&id=3")
        har = _make_har(entry)

        # Act
        result = analyze_har(har)
        call = result["calls"][0]

        # Assert
        self.assertEqual(call["request"]["query_params"]["id"], ["1", "2", "3"])

    def test_AnalyzeHar_QueryParamsStrippedFromUrl(self):
        entry = _make_entry(url="https://api.example.com/search?q=test")
        har = _make_har(entry)

        result = analyze_har(har)
        call = result["calls"][0]

        self.assertNotIn("?", call["url"])
        self.assertEqual(call["url"], "https://api.example.com/search")

    def test_AnalyzeHar_ZeroTimingMs_Preserved(self):
        entry = _make_entry(time_ms=0)
        har = _make_har(entry)

        result = analyze_har(har)

        self.assertEqual(result["calls"][0]["time_ms"], 0)

    def test_AnalyzeHar_RequestBody_Included(self):
        body = json.dumps({"username": "test", "password": "secret"})
        entry = _make_entry(
            method="POST", req_body=body, req_mime="application/json"
        )
        har = _make_har(entry)

        result = analyze_har(har)
        call = result["calls"][0]

        self.assertEqual(call["request"]["body"], {"username": "test", "password": "secret"})
        self.assertEqual(call["request"]["content_type"], "application/json")

    def test_AnalyzeHar_ResponseBody_Included(self):
        resp = {"id": 42, "name": "widget"}
        entry = _make_entry(resp_body=resp)
        har = _make_har(entry)

        result = analyze_har(har)
        call = result["calls"][0]

        self.assertEqual(call["response"]["body"], resp)


# ===========================================================================
# analyze_har — domain filter
# ===========================================================================

class TestAnalyzeHarDomainFilter(unittest.TestCase):
    def test_AnalyzeHar_DomainFilter_KeepsMatchingEntries(self):
        match = _make_entry(url="https://api.example.com/data")
        no_match = _make_entry(url="https://cdn.other.com/image.png",
                               resp_mime="application/json")
        har = _make_har(match, no_match)

        result = analyze_har(har, domain_filter="api.example.com")

        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertIn("api.example.com", result["summary"]["domains"])

    def test_AnalyzeHar_DomainFilter_CaseInsensitive(self):
        entry = _make_entry(url="https://API.Example.COM/data")
        har = _make_har(entry)

        result = analyze_har(har, domain_filter="api.example.com")

        self.assertEqual(result["summary"]["total_requests"], 1)

    def test_AnalyzeHar_DomainFilter_NoMatches_ReturnsError(self):
        entry = _make_entry(url="https://other.com/data")
        har = _make_har(entry)

        result = analyze_har(har, domain_filter="api.example.com")

        self.assertIn("error", result)
        self.assertIn("api.example.com", result["error"])


# ===========================================================================
# analyze_har — static asset filtering
# ===========================================================================

class TestAnalyzeHarStaticFiltering(unittest.TestCase):
    def test_AnalyzeHar_SkipsImageEntries(self):
        api_entry = _make_entry(url="https://api.example.com/data")
        img_entry = _make_entry(
            url="https://cdn.example.com/logo.png", resp_mime="image/png"
        )
        har = _make_har(api_entry, img_entry)

        result = analyze_har(har)

        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertEqual(result["summary"]["skipped_static_assets"], 1)

    def test_AnalyzeHar_SkipsCssAndJs(self):
        api_entry = _make_entry()
        css_entry = _make_entry(url="https://cdn.example.com/style.css",
                                resp_mime="text/css")
        js_entry = _make_entry(url="https://cdn.example.com/app.js",
                               resp_mime="application/javascript")
        har = _make_har(api_entry, css_entry, js_entry)

        result = analyze_har(har)

        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertEqual(result["summary"]["skipped_static_assets"], 2)

    def test_AnalyzeHar_NoStaticAssets_NoSkippedKey(self):
        entry = _make_entry()
        har = _make_har(entry)

        result = analyze_har(har)

        self.assertNotIn("skipped_static_assets", result["summary"])


# ===========================================================================
# analyze_har — dependency detection
# ===========================================================================

class TestAnalyzeHarDependencies(unittest.TestCase):
    def test_AnalyzeHar_TokenInResponseUsedInNextHeader_DetectedAsDependency(self):
        token = "eyJhbGciOiJSUzI1NiJ9.longtoken"
        login_resp = {"access_token": token}
        login = _make_entry(
            method="POST",
            url="https://api.example.com/auth/login",
            resp_body=login_resp,
        )
        api_call = _make_entry(
            url="https://api.example.com/v1/users",
            req_headers=[{"name": "Authorization", "value": f"Bearer {token}"}],
        )
        har = _make_har(login, api_call)

        result = analyze_har(har)

        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_call"], 0)
        self.assertEqual(dep["from_field"], "access_token")
        self.assertEqual(dep["to_call"], 1)
        self.assertIn("header:Authorization", dep["used_in"])

    def test_AnalyzeHar_IdInResponseUsedInNextUrl_DetectedAsDependency(self):
        resource_id = "res_abc123def456"
        create_resp = {"id": resource_id}
        create = _make_entry(
            method="POST",
            url="https://api.example.com/v1/resources",
            resp_body=create_resp,
        )
        fetch = _make_entry(
            url=f"https://api.example.com/v1/resources/{resource_id}",
        )
        har = _make_har(create, fetch)

        result = analyze_har(har)

        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_call"], 0)
        self.assertEqual(dep["to_call"], 1)
        self.assertIn("url", dep["used_in"])

    def test_AnalyzeHar_ValueInResponseUsedInNextBody_DetectedAsDependency(self):
        csrf_token = "csrf_xxxxxxxxxxxx"
        page_resp = {"csrf": csrf_token}
        page = _make_entry(url="https://app.example.com/form", resp_body=page_resp)
        submit = _make_entry(
            method="POST",
            url="https://app.example.com/submit",
            req_body=json.dumps({"csrf": csrf_token, "data": "hello"}),
        )
        har = _make_har(page, submit)

        result = analyze_har(har)

        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_call"], 0)
        self.assertEqual(dep["to_call"], 1)
        self.assertIn("body", dep["used_in"])

    def test_AnalyzeHar_SetCookieHeader_DetectedAsDependency(self):
        # The full Set-Cookie value is tracked, so the Cookie header must
        # contain it as a substring for dependency detection to match.
        cookie_value = "session=sess_abcdef123456"
        login = _make_entry(
            method="POST",
            url="https://api.example.com/login",
            resp_headers=[{"name": "Set-Cookie", "value": cookie_value}],
        )
        api_call = _make_entry(
            url="https://api.example.com/data",
            req_headers=[{"name": "Cookie", "value": cookie_value}],
        )
        har = _make_har(login, api_call)

        result = analyze_har(har)

        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_field"], "response_header:Set-Cookie")

    def test_AnalyzeHar_MultipleSetCookieHeaders_AllTracked(self):
        # Arrange
        cookie_a = "session=sess_abcdef123456"
        cookie_b = "csrf=csrf_token_xyz98765"
        login = _make_entry(
            method="POST",
            url="https://api.example.com/login",
            resp_headers=[
                {"name": "Set-Cookie", "value": cookie_a},
                {"name": "Set-Cookie", "value": cookie_b},
            ],
        )
        api_call = _make_entry(
            url="https://api.example.com/data",
            req_headers=[
                {"name": "Cookie", "value": f"{cookie_a}; {cookie_b}"},
            ],
        )
        har = _make_har(login, api_call)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertIn("dependencies", result)
        dep_values = {d["value_preview"] for d in result["dependencies"]}
        self.assertIn(cookie_a, dep_values)
        self.assertIn(cookie_b, dep_values)

    def test_AnalyzeHar_NoDependencies_KeyOmitted(self):
        entry1 = _make_entry(url="https://api.example.com/a", resp_body={"x": "short"})
        entry2 = _make_entry(url="https://api.example.com/b")
        har = _make_har(entry1, entry2)

        result = analyze_har(har)

        self.assertNotIn("dependencies", result)

    def test_AnalyzeHar_ListResponseBody_DependencyTracked(self):
        # Arrange
        resource_id = "resource_id_abcdef1234"
        first = _make_entry(
            url="https://api.example.com/v1/resources",
            resp_body=[{"id": resource_id, "name": "widget"}],
        )
        second = _make_entry(
            url=f"https://api.example.com/v1/resources/{resource_id}",
        )
        har = _make_har(first, second)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_field"], "response_body[]")
        self.assertIn("url", dep["used_in"])

    def test_AnalyzeHar_UrlDependency_Detected(self):
        redirect_url = "https://api.example.com/v2/redirect-target"
        resp = {"next_url": redirect_url}
        first = _make_entry(
            url="https://api.example.com/v1/start",
            resp_body=resp,
        )
        second = _make_entry(url=redirect_url)
        har = _make_har(first, second)

        result = analyze_har(har)

        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_field"], "next_url")
        self.assertIn("url", dep["used_in"])

    def test_AnalyzeHar_DependencyValuePreview_TruncatedAt80(self):
        preview_limit = 80
        long_token = "t" * 100
        login = _make_entry(
            method="POST",
            url="https://api.example.com/auth",
            resp_body={"token": long_token},
        )
        api_call = _make_entry(
            url="https://api.example.com/data",
            req_headers=[{"name": "Authorization", "value": long_token}],
        )
        har = _make_har(login, api_call)

        result = analyze_har(har)

        dep = result["dependencies"][0]
        self.assertEqual(len(dep["value_preview"]), preview_limit + len("..."))
        self.assertTrue(dep["value_preview"].endswith("..."))


# ===========================================================================
# analyze_har — postData.params fallback
# ===========================================================================

class TestAnalyzeHarFormData(unittest.TestCase):
    def test_AnalyzeHar_PostDataParams_FallbackWhenNoText(self):
        params = [
            {"name": "username", "value": "admin"},
            {"name": "password", "value": "secret123"},
        ]
        entry = _make_entry(
            method="POST",
            url="https://app.example.com/login",
            post_data_params=params,
            req_mime="application/x-www-form-urlencoded",
        )
        har = _make_har(entry)

        result = analyze_har(har)
        call = result["calls"][0]

        self.assertEqual(call["request"]["body"], "username=admin&password=secret123")
        self.assertEqual(call["request"]["content_type"], "application/x-www-form-urlencoded")

    def test_AnalyzeHar_PostDataTextPreferred_OverParams(self):
        entry = _make_entry(
            method="POST",
            url="https://app.example.com/api",
            req_body='{"key": "value"}',
            req_mime="application/json",
        )
        # Manually add params that should be ignored
        entry["request"]["postData"]["params"] = [
            {"name": "ignored", "value": "data"},
        ]
        har = _make_har(entry)

        result = analyze_har(har)
        call = result["calls"][0]

        self.assertEqual(call["request"]["body"], {"key": "value"})


# ===========================================================================
# analyze_har — HAR without "log" wrapper
# ===========================================================================

class TestAnalyzeHarNoLogWrapper(unittest.TestCase):
    def test_AnalyzeHar_NoLogKey_FallsBackToRoot(self):
        har = {
            "entries": [
                _make_entry(),
            ]
        }

        result = analyze_har(har)

        self.assertEqual(result["summary"]["total_requests"], 1)


# ===========================================================================
# analyze_har — startedDateTime sorting
# ===========================================================================

class TestAnalyzeHarSorting(unittest.TestCase):
    def test_AnalyzeHar_OutOfOrderEntries_SortedByStartedDateTime(self):
        # Arrange — second entry has earlier timestamp but appears later in array
        token = "auth_token_xyz12345"
        login = _make_entry(
            method="POST",
            url="https://api.example.com/login",
            resp_body={"token": token},
        )
        login["startedDateTime"] = "2024-01-01T00:00:01.000Z"

        api_call = _make_entry(
            url="https://api.example.com/data",
            req_headers=[{"name": "Authorization", "value": f"Bearer {token}"}],
        )
        api_call["startedDateTime"] = "2024-01-01T00:00:02.000Z"

        # Put them in reverse order in the array
        har = _make_har(api_call, login)

        # Act
        result = analyze_har(har)

        # Assert — sorting restores correct order, so dependency is detected
        self.assertEqual(result["calls"][0]["url"], "https://api.example.com/login")
        self.assertEqual(result["calls"][1]["url"], "https://api.example.com/data")
        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_call"], 0)
        self.assertEqual(dep["to_call"], 1)


# ===========================================================================
# analyze_har — postData null
# ===========================================================================

class TestAnalyzeHarPostDataNull(unittest.TestCase):
    def test_AnalyzeHar_PostDataNull_DoesNotCrash(self):
        # Arrange
        entry = _make_entry()
        entry["request"]["postData"] = None
        har = _make_har(entry)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertNotIn("body", result["calls"][0]["request"])


# ===========================================================================
# analyze_har — response content text null
# ===========================================================================

class TestAnalyzeHarResponseTextNull(unittest.TestCase):
    def test_AnalyzeHar_ResponseTextNull_DoesNotCrash(self):
        # Arrange — HAR has "text": null instead of omitting the key
        entry = _make_entry()
        entry["response"]["content"]["text"] = None
        har = _make_har(entry)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertNotIn("body", result["calls"][0]["response"])


# ===========================================================================
# analyze_har — malformed entries
# ===========================================================================

class TestAnalyzeHarMalformedEntries(unittest.TestCase):
    def test_AnalyzeHar_MissingRequestKey_DoesNotCrash(self):
        # Arrange
        entry = {"response": {"status": 200, "statusText": "OK", "headers": [],
                               "content": {"mimeType": "application/json"}}}
        har = _make_har(entry)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertEqual(result["calls"][0]["method"], "UNKNOWN")

    def test_AnalyzeHar_MissingResponseKey_DoesNotCrash(self):
        # Arrange
        entry = {"request": {"method": "GET",
                              "url": "https://api.example.com/test",
                              "headers": []}}
        har = _make_har(entry)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertEqual(result["summary"]["total_requests"], 1)
        self.assertEqual(result["calls"][0]["response"]["status"], 0)


# ===========================================================================
# analyze_har — timing absent
# ===========================================================================

class TestAnalyzeHarTimingAbsent(unittest.TestCase):
    def test_AnalyzeHar_NoTimeField_TimeMsOmitted(self):
        # Arrange
        entry = _make_entry()
        del entry["time"]
        har = _make_har(entry)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertNotIn("time_ms", result["calls"][0])


# ===========================================================================
# analyze_har — case-insensitive header dependency detection
# ===========================================================================

class TestAnalyzeHarHeaderCaseDependency(unittest.TestCase):
    def test_AnalyzeHar_LowercaseSetCookie_DetectedAsDependency(self):
        # Arrange
        cookie_value = "session=sess_abcdef123456"
        login = _make_entry(
            method="POST",
            url="https://api.example.com/login",
            resp_headers=[{"name": "set-cookie", "value": cookie_value}],
        )
        api_call = _make_entry(
            url="https://api.example.com/data",
            req_headers=[{"name": "Cookie", "value": cookie_value}],
        )
        har = _make_har(login, api_call)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_field"], "response_header:set-cookie")

    def test_AnalyzeHar_MixedCaseLocation_DetectedAsDependency(self):
        # Arrange
        redirect_url = "https://api.example.com/v2/final-destination"
        first = _make_entry(
            url="https://api.example.com/v1/start",
            resp_headers=[{"name": "LOCATION", "value": redirect_url}],
        )
        second = _make_entry(url=redirect_url)
        har = _make_har(first, second)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_field"], "response_header:LOCATION")


# ===========================================================================
# analyze_har — string response body dependency tracking
# ===========================================================================

class TestAnalyzeHarStringResponseBody(unittest.TestCase):
    def test_AnalyzeHar_PlainStringResponseBody_DependencyTracked(self):
        # Arrange
        token = "plain_text_token_value_12345"
        first = _make_entry(
            url="https://api.example.com/token",
            resp_body=token,
            resp_mime="text/plain",
        )
        second = _make_entry(
            url="https://api.example.com/data",
            req_headers=[{"name": "Authorization", "value": token}],
        )
        har = _make_har(first, second)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertIn("dependencies", result)
        dep = result["dependencies"][0]
        self.assertEqual(dep["from_call"], 0)
        self.assertEqual(dep["from_field"], "response_body")
        self.assertEqual(dep["to_call"], 1)

    def test_AnalyzeHar_ShortStringResponseBody_NotTracked(self):
        # Arrange
        short_token = "short_value"
        first = _make_entry(
            url="https://api.example.com/token",
            resp_body=short_token,
            resp_mime="text/plain",
        )
        second = _make_entry(
            url="https://api.example.com/data",
            req_headers=[{"name": "Authorization", "value": short_token}],
        )
        har = _make_har(first, second)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertNotIn("dependencies", result)


# ===========================================================================
# analyze_har — dedup allows distinct values from same field
# ===========================================================================

class TestAnalyzeHarDedupDistinctValues(unittest.TestCase):
    def test_AnalyzeHar_TwoValuesFromSameField_BothRecorded(self):
        # Arrange
        access_token = "access_token_abcdef12"
        refresh_token = "refresh_token_xyz98765"
        login = _make_entry(
            method="POST",
            url="https://api.example.com/auth",
            resp_body={"tokens": {"access": access_token, "refresh": refresh_token}},
        )
        api_call = _make_entry(
            url="https://api.example.com/data",
            req_headers=[
                {"name": "Authorization", "value": f"Bearer {access_token}"},
                {"name": "X-Refresh", "value": refresh_token},
            ],
        )
        har = _make_har(login, api_call)

        # Act
        result = analyze_har(har)

        # Assert
        self.assertIn("dependencies", result)
        dep_values = {d["value_preview"] for d in result["dependencies"]}
        self.assertIn(access_token, dep_values)
        self.assertIn(refresh_token, dep_values)
        self.assertEqual(len(result["dependencies"]), 2)


# ===========================================================================
# analyze_har — dependency detection warning for large inputs
# ===========================================================================

class TestAnalyzeHarDependencyWarning(unittest.TestCase):
    def test_AnalyzeHar_LargeInput_WarnsToStderr(self):
        # Arrange — generate enough entries and response values to exceed
        # the 5,000,000 iteration threshold.  Each entry produces one
        # token-like response value (length >= 16), so we need
        # response_values * calls > 5_000_000.  With N entries that gives
        # roughly N * N / 2; N = 3200 → ~5.12M.
        threshold_iteration_count = 5_000_000
        entry_count = 3200
        entries = []
        for i in range(entry_count):
            entries.append(_make_entry(
                url=f"https://api.example.com/v1/item{i}",
                resp_body={"token": f"tok_{i:020d}"},
            ))
        har = _make_har(*entries)

        # Act — capture stderr via CLI to verify the warning is printed
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            json.dump(har, f)
            tmp_path = f.name

        try:
            proc = subprocess.run(
                [sys.executable,
                 os.path.join(os.path.dirname(__file__), "har_parse.py"),
                 tmp_path],
                capture_output=True, text=True, timeout=120,
            )
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Warning", proc.stderr)
        self.assertIn("--filter", proc.stderr)

    def test_AnalyzeHar_SmallInput_NoWarning(self):
        # Arrange — a small HAR should not trigger the warning
        entries = [
            _make_entry(
                url="https://api.example.com/v1/a",
                resp_body={"token": "abcdefghijklmnop"},
            ),
            _make_entry(url="https://api.example.com/v1/b"),
        ]
        har = _make_har(*entries)

        # Act
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            json.dump(har, f)
            tmp_path = f.name

        try:
            proc = subprocess.run(
                [sys.executable,
                 os.path.join(os.path.dirname(__file__), "har_parse.py"),
                 tmp_path],
                capture_output=True, text=True,
            )
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stderr, "")


# ===========================================================================
# main() — CLI integration tests
# ===========================================================================

class TestMainCli(unittest.TestCase):
    _SCRIPT = os.path.join(os.path.dirname(__file__), "har_parse.py")

    def _run(self, *args):
        return subprocess.run(
            [sys.executable, self._SCRIPT, *args],
            capture_output=True, text=True,
        )

    def test_Main_NoArgs_ExitsWithUsageError(self):
        # Act
        proc = self._run()

        # Assert
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Usage", proc.stderr)

    def test_Main_FileNotFound_ExitsWithError(self):
        # Act
        proc = self._run("/nonexistent/path/file.har")

        # Assert
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("File not found", proc.stderr)

    def test_Main_InvalidJson_ExitsWithError(self):
        # Arrange
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            f.write("not valid json {{{")
            tmp_path = f.name

        # Act
        try:
            proc = self._run(tmp_path)
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Invalid JSON", proc.stderr)

    def test_Main_FilterWithoutValue_ExitsWithError(self):
        # Arrange
        har = _make_har(_make_entry())
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            json.dump(har, f)
            tmp_path = f.name

        # Act
        try:
            proc = self._run(tmp_path, "--filter")
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--filter requires", proc.stderr)

    def test_Main_UnknownArgument_ExitsWithError(self):
        # Arrange
        har = _make_har(_make_entry())
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            json.dump(har, f)
            tmp_path = f.name

        # Act
        try:
            proc = self._run(tmp_path, "--bogus")
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Unknown argument", proc.stderr)

    def test_Main_ValidHar_OutputsJson(self):
        # Arrange
        har = _make_har(_make_entry())
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            json.dump(har, f)
            tmp_path = f.name

        # Act
        try:
            proc = self._run(tmp_path)
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertEqual(proc.returncode, 0)
        result = json.loads(proc.stdout)
        self.assertEqual(result["summary"]["total_requests"], 1)

    def test_Main_ValidHarWithFilter_OutputsFilteredJson(self):
        # Arrange
        har = _make_har(
            _make_entry(url="https://api.example.com/data"),
            _make_entry(url="https://cdn.other.com/stuff"),
        )
        with tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False) as f:
            json.dump(har, f)
            tmp_path = f.name

        # Act
        try:
            proc = self._run(tmp_path, "--filter", "api.example.com")
        finally:
            os.unlink(tmp_path)

        # Assert
        self.assertEqual(proc.returncode, 0)
        result = json.loads(proc.stdout)
        self.assertEqual(result["summary"]["total_requests"], 1)


if __name__ == "__main__":
    unittest.main()
