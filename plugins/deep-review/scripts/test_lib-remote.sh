#!/usr/bin/env bash
set -uo pipefail

# test_lib-remote.sh — unit tests for the shared remote-URL parsing library.
#
# These functions are pure, so this suite needs no git fixtures, no network and
# no CLI stubs, and finishes in about a second. test_resolve-pr.sh exercises the
# same code end to end through the resolver, which is slow enough (minutes on
# Git Bash) that it cannot afford to enumerate branches. This is where branch
# coverage lives; that is where integration coverage lives.
#
# Run: bash test_lib-remote.sh

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/lib-remote.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# Compare a function's stdout against an expectation.
assert_out() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" == "$expected" ]]; then ok; else
        bad "$label: expected '$expected', got '$actual'"
    fi
}

assert_rc() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$actual" == "$expected" ]]; then ok; else
        bad "$label: expected exit $expected, got $actual"
    fi
}

echo "test_lib-remote.sh"

# ── The library's own contract ───────────────────────────────────────
# Sourcing must be silent. Anything the lib prints lands in resolve-pr.sh's
# KEY=value stream ahead of HOST=, corrupting a contract its caller parses.
lib_stdout=$(. "$LIB" 2>/dev/null; printf '')
assert_out "" "$lib_stdout" "sourcing the lib emits nothing on stdout"

bash -n "$LIB" 2>/dev/null
assert_rc 0 $? "the lib parses"

# shellcheck source=lib-remote.sh
. "$LIB"

for fn in remote_host host_kind equals_ignoring_case ado_org_name ado_org_url \
          repo_name_from_url url_after_host url_owner_repo reference_scope \
          urls_same_scope; do
    if declare -F "$fn" >/dev/null 2>&1; then ok; else
        bad "the lib defines $fn"
    fi
done

# ── remote_host ──────────────────────────────────────────────────────
assert_out "github.com"     "$(remote_host 'https://github.com/o/r.git')"        "remote_host: https"
assert_out "github.com"     "$(remote_host 'git@github.com:o/r.git')"            "remote_host: scp-style"
assert_out "ssh.dev.azure.com" "$(remote_host 'ssh://git@ssh.dev.azure.com:22/v3/org/p/r')" "remote_host: ssh with port"
assert_out "www.github.com" "$(remote_host 'https://www.github.com/o/r')"        "remote_host: subdomain preserved"
assert_out ""               "$(remote_host '')"                                  "remote_host: empty input"

# ── host_kind ────────────────────────────────────────────────────────
# Every arm, including the two the integration suite cannot reach: no fixture
# repo uses a github SUBDOMAIN as its origin, so `*.github.com` was previously
# deletable with the whole suite still green.
assert_out "github"  "$(host_kind 'https://github.com/o/r.git')"        "host_kind: github.com"
assert_out "github"  "$(host_kind 'https://www.github.com/o/r')"        "host_kind: *.github.com"
assert_out "github"  "$(host_kind 'https://a.b.github.com/o/r')"        "host_kind: deep subdomain"
assert_out "github"  "$(host_kind 'git@github.com:o/r.git')"            "host_kind: scp-style"
assert_out "azdo"    "$(host_kind 'https://dev.azure.com/org/p/_git/r')" "host_kind: dev.azure.com"
assert_out "azdo"    "$(host_kind 'git@ssh.dev.azure.com:v3/org/p/r')"  "host_kind: ssh.dev.azure.com"
assert_out "azdo"    "$(host_kind 'https://org.visualstudio.com/p/_git/r')" "host_kind: *.visualstudio.com"
assert_out "unknown" "$(host_kind 'https://gitlab.com/o/r.git')"        "host_kind: unrelated host"
assert_out "unknown" "$(host_kind '')"                                  "host_kind: empty is unknown, matching the initializer"
# The substring trap the host-component match exists to defeat.
assert_out "unknown" "$(host_kind 'https://gitlab.com/me/github.com-mirror.git')" "host_kind: github.com in a PATH is not a github host"

# ── equals_ignoring_case ─────────────────────────────────────────────
if equals_ignoring_case "AbC" "aBc"; then ok; else bad "equals_ignoring_case: differing case matches"; fi
if equals_ignoring_case "abc" "abd"; then bad "equals_ignoring_case: different strings must not match"; else ok; fi

# The option must be restored, whichever way it started. Deleting the restore
# used to leave the whole suite green because nothing downstream depended on it.
shopt -u nocasematch
equals_ignoring_case a A >/dev/null
if shopt -q nocasematch; then bad "equals_ignoring_case: leaked nocasematch ON"; else ok; fi

shopt -s nocasematch
equals_ignoring_case a b >/dev/null
if shopt -q nocasematch; then ok; else bad "equals_ignoring_case: failed to restore nocasematch that was already ON"; fi
shopt -u nocasematch

# `shopt -p <name>` exits 1 when the option is UNSET, so capturing it without
# `|| true` made a BARE call fatal under `set -e` — the shell died before the
# comparison ran. The library advertises itself as safe to share; this pins it.
bash -c "set -euo pipefail; . '$LIB'; equals_ignoring_case A a; echo reached" >/dev/null 2>&1
assert_rc 0 $? "equals_ignoring_case: a bare call survives set -e"

# ── ado_org_name ─────────────────────────────────────────────────────
assert_out "myorg" "$(ado_org_name 'git@ssh.dev.azure.com:v3/myorg/proj/repo')"        "ado_org_name: scp v3"
assert_out "myorg" "$(ado_org_name 'ssh://git@ssh.dev.azure.com:22/v3/myorg/proj/repo')" "ado_org_name: ssh v3 with explicit port"
# vs-ssh must beat the generic visualstudio.com arm or the org reads "vs-ssh".
assert_out "myorg" "$(ado_org_name 'git@vs-ssh.visualstudio.com:v3/myorg/proj/repo')"  "ado_org_name: vs-ssh precedence"
assert_out "myorg" "$(ado_org_name 'https://dev.azure.com/myorg/proj/_git/repo')"      "ado_org_name: dev.azure.com"
assert_out "myorg" "$(ado_org_name 'https://myorg.visualstudio.com/proj/_git/repo')"   "ado_org_name: legacy visualstudio.com"
ado_org_name 'https://github.com/o/r' >/dev/null 2>&1
assert_rc 1 $? "ado_org_name: non-ADO URL returns 1"

# ── ado_org_url ──────────────────────────────────────────────────────
assert_out "https://dev.azure.com/myorg"      "$(ado_org_url 'https://dev.azure.com/myorg/p/_git/r')" "ado_org_url: dev.azure.com"
assert_out "https://myorg.visualstudio.com"   "$(ado_org_url 'https://myorg.visualstudio.com/p/_git/r')" "ado_org_url: legacy dialect preserved"
# vs-ssh is an ssh HOST, not the org's web host — it must not become the URL.
assert_out "https://dev.azure.com/myorg"      "$(ado_org_url 'git@vs-ssh.visualstudio.com:v3/myorg/p/r')" "ado_org_url: vs-ssh excluded from the legacy arm"
ado_org_url 'https://github.com/o/r' >/dev/null 2>&1
assert_rc 1 $? "ado_org_url: propagates ado_org_name's failure"

# ── repo_name_from_url ───────────────────────────────────────────────
assert_out "repo" "$(repo_name_from_url 'https://github.com/o/repo')"      "repo_name_from_url: plain"
assert_out "repo" "$(repo_name_from_url 'https://github.com/o/repo.git')"  "repo_name_from_url: .git stripped"
assert_out "repo" "$(repo_name_from_url 'https://github.com/o/repo/')"     "repo_name_from_url: trailing slash stripped"

# ── url_after_host ───────────────────────────────────────────────────
assert_out "o/r"        "$(url_after_host 'https://github.com/o/r.git')"      "url_after_host: https, .git stripped"
assert_out "o/r"        "$(url_after_host 'git@github.com:o/r.git')"          "url_after_host: scp-style"
assert_out "o/r"        "$(url_after_host 'https://user@github.com/o/r')"     "url_after_host: userinfo"
assert_out "o/r"        "$(url_after_host 'https://github.com/o/r?tab=x')"    "url_after_host: query string dropped"
assert_out "o/r"        "$(url_after_host 'https://github.com/o/r#frag')"     "url_after_host: fragment dropped"
assert_out "o/r"        "$(url_after_host 'https://github.com/o/r/')"         "url_after_host: trailing slash"
assert_out ""           "$(url_after_host 'https://github.com')"              "url_after_host: no path"
# The regression the authority-first split exists to prevent: stripping `*@`
# from the whole string let a later @ in the PATH eat everything before it.
assert_out "o/r/tree/main/@types" "$(url_after_host 'https://github.com/o/r/tree/main/@types')" "url_after_host: @ in the path is not userinfo"

# ── url_owner_repo ───────────────────────────────────────────────────
assert_out "o/r" "$(url_owner_repo 'https://github.com/o/r.git')"        "url_owner_repo: happy path"
assert_out "o/r" "$(url_owner_repo 'https://github.com//o/r')"           "url_owner_repo: doubled slash collapsed"
assert_out "o/r" "$(url_owner_repo 'https://github.com/o/r/issues/42')"  "url_owner_repo: extra segments ignored"
url_owner_repo 'https://github.com/only-one' >/dev/null 2>&1
assert_rc 1 $? "url_owner_repo: a single path segment returns 1"
url_owner_repo 'https://github.com' >/dev/null 2>&1
assert_rc 1 $? "url_owner_repo: no path returns 1"

# ── reference_scope ──────────────────────────────────────────────────
# The host family is an ARGUMENT now, not a global — that is what let this move
# into a shared library at all.
assert_out "github.com/o/r" "$(reference_scope 'https://github.com/o/r' github)"     "reference_scope: github"
assert_out "github.com/o/r" "$(reference_scope 'https://www.github.com/o/r' github)" "reference_scope: *.github.com normalized to the bare host"
assert_out "myorg"          "$(reference_scope 'https://dev.azure.com/myorg/p/_git/r' azdo)" "reference_scope: azdo compares organizations"
reference_scope 'https://github.com/only-one' github >/dev/null 2>&1
assert_rc 1 $? "reference_scope: unparsable owner/repo returns 1"

# ── urls_same_scope ──────────────────────────────────────────────────
ORIGIN='https://github.com/TimZander/claude.git'
urls_same_scope 'https://github.com/TimZander/claude/issues/42' "$ORIGIN" github
assert_rc 0 $? "urls_same_scope: same repo"
urls_same_scope 'https://github.com/TIMZANDER/Claude/issues/42' "$ORIGIN" github
assert_rc 0 $? "urls_same_scope: casing ignored"
urls_same_scope 'https://github.com/someone-else/other/issues/42' "$ORIGIN" github
assert_rc 1 $? "urls_same_scope: foreign repo is 1, not 2"
urls_same_scope 'https://gitlab.com/TimZander/claude/issues/42' "$ORIGIN" github
assert_rc 1 $? "urls_same_scope: same owner/repo on another host is foreign"
# 2 is "we cannot tell", and must never be reported as the user's fault.
urls_same_scope 'https://github.com/TimZander/claude/issues/42' '' github
assert_rc 2 $? "urls_same_scope: no comparison URL is 2, not 1"
urls_same_scope 'https://dev.azure.com/myorg/p/_workitems/edit/7' 'https://gitlab.com/x/y' azdo
assert_rc 2 $? "urls_same_scope: unparsable comparison URL is 2, not 1"
urls_same_scope 'https://dev.azure.com/MYORG/p/_workitems/edit/7' 'https://dev.azure.com/myorg/p/_git/r' azdo
assert_rc 0 $? "urls_same_scope: ADO org casing ignored"
urls_same_scope 'https://dev.azure.com/otherorg/p/_workitems/edit/7' 'https://dev.azure.com/myorg/p/_git/r' azdo
assert_rc 1 $? "urls_same_scope: different ADO org is foreign"

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
