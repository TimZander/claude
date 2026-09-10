# shellcheck shell=bash
# lib-remote.sh — Git remote URL parsing and scope comparison, shared by this
# plugin's scripts.
#
# SOURCE this file; do not execute it. It defines functions and nothing else:
# no top-level statements, no shell options, no output. The sourcing script
# owns `set -euo pipefail` — a library that sets shell options changes the
# behaviour of whoever sourced it, which is not its call to make. It has no
# shebang and mode 644 by design, so it cannot be run by accident.
#
#   SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/lib-remote.sh"
#
# SCOPE: no function here reads a global. Everything it needs arrives as an
# argument — including the host classification, which callers pass in rather
# than the library reading a `HOST` global. That is what makes these safe to
# share between scripts that have no other state in common.
#
# CALLING CONSTRAINT — `equals_ignoring_case` and `urls_same_scope` return
# non-zero to mean "no", not "error". Under `set -e` a BARE call therefore
# aborts the shell. Call them in conditional context (`if f …`, `f … || rc=$?`),
# which is how every current caller uses them.

# Extract the host component from a git remote URL, handling https://,
# ssh://, and scp-style (git@host:path) forms.
remote_host() {
    local url="$1"
    url="${url#*://}"   # strip scheme
    url="${url#*@}"     # strip userinfo
    url="${url%%[:/]*}" # keep up to the first : or /
    printf '%s' "$url"
}

# Classify a remote URL as github|azdo|unknown.
#
# Matched on the URL's HOST COMPONENT rather than as a substring of the whole
# URL: a substring test misclassifies e.g.
# https://gitlab.com/me/github.com-mirror.git.
#
# `unknown` is not an error at this level. Only operations that reach a PR or
# work-item API need a known host, so that requirement belongs at those call
# sites, not here.
host_kind() {
    case "$(remote_host "$1")" in
        github.com|*.github.com)
            printf 'github' ;;
        dev.azure.com|ssh.dev.azure.com|*.visualstudio.com)
            printf 'azdo' ;;
        *)
            printf 'unknown' ;;
    esac
}

# Case-insensitive string equality, without lowercasing. Takes two arbitrary
# strings — the one function here that is not about URLs.
#
# An earlier version ran both operands through `printf | tr`. That is one FORK
# PER CALL, and locality is checked up to three times per invocation — on Git
# Bash, where process creation is expensive, it added minutes to the test suite.
# `nocasematch` does the same job in-process. It is a shell-global option, so it
# is restored immediately; `shopt -p` reproduces the prior state exactly whether
# it was set or unset.
#
# `|| true` on the capture: `shopt -p <name>` exits 1 when the option is UNSET,
# which is the common case. Without it the assignment carries that status and a
# bare call under `set -e` kills the shell before the comparison ever runs.
equals_ignoring_case() {
    local restore
    restore=$(shopt -p nocasematch || true)
    shopt -s nocasematch
    if [[ "$1" == "$2" ]]; then
        eval "$restore"
        return 0
    fi
    eval "$restore"
    return 1
}

# The ADO organization NAME, reconciled across every remote dialect. The v3 ssh
# forms must be matched BEFORE the generic visualstudio.com arm, or
# vs-ssh.visualstudio.com yields the org "vs-ssh".
ado_org_name() {
    local url="$1"
    # `[:/]` alone rejected an explicit port — ssh://git@ssh.dev.azure.com:22/v3/…
    # matched no arm, and since the host classification is decided on the host
    # alone that turned a legitimate remote into a hard failure on the PR path.
    if [[ "$url" =~ (ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)(:[0-9]+)?[:/]v3/([^/]+) ]]; then
        printf '%s' "${BASH_REMATCH[3]}"
    elif [[ "$url" =~ dev\.azure\.com/([^/]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ([A-Za-z0-9_-]+)\.visualstudio\.com ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# The organization URL `az --org` needs. Preserves each dialect's own form:
# a legacy <org>.visualstudio.com remote keeps that host.
ado_org_url() {
    local url="$1" org
    org=$(ado_org_name "$url") || return 1
    if [[ "$url" =~ \.visualstudio\.com ]] && [[ ! "$url" =~ vs-ssh\.visualstudio\.com ]]; then
        printf 'https://%s.visualstudio.com' "$org"
    else
        printf 'https://dev.azure.com/%s' "$org"
    fi
}

# The repository name from a URL (last path segment, minus .git). Named for what
# it takes, not for who happens to pass it: in a shared library "origin" would be
# a promise the argument cannot keep.
repo_name_from_url() {
    local url="${1%/}"
    url="${url%.git}"
    printf '%s' "${url##*/}"
}

# Path portion of a URL, host stripped. scp-style remotes (git@host:path) are
# normalized to host/path first so both forms compare segment-wise.
url_after_host() {
    local url="$1" path
    if [[ "$url" != *://* ]]; then
        url="${url/:/\/}"   # scp-style: first colon becomes the path separator
    else
        url="${url#*://}"
    fi
    url="${url%%\?*}"       # drop a query string
    url="${url%%#*}"        # drop a fragment
    # Split the authority off FIRST, then strip userinfo inside it. Stripping
    # `*@` from the whole string instead let any later `@` in the path eat
    # everything before it — `.../tree/main/@types` came back as `types`.
    if [[ "$url" == */* ]]; then
        path="${url#*/}"
    else
        path=""
    fi
    path="${path%/}"
    printf '%s' "${path%.git}"
}

# owner/repo — GitHub numbers issues per REPOSITORY, so both segments matter.
url_owner_repo() {
    local path parts IFS='/'
    path=$(url_after_host "$1")
    # Collapse repeated slashes: `github.com//owner/repo/...` otherwise yields an
    # empty first field and a legitimate same-repo reference is refused.
    while [[ "$path" == *//* ]]; do
        path="${path//\/\//\/}"
    done
    path="${path#/}"
    read -r -a parts <<< "$path"
    # Test the elements with :- defaults rather than ${#parts[@]}: on bash 3.2
    # (macOS) `read -a` can leave the array unset when the input is empty, and
    # ${#parts[@]} is then an unbound-variable error under `set -u`.
    if [[ -z "${parts[0]:-}" || -z "${parts[1]:-}" ]]; then
        return 1
    fi
    printf '%s/%s' "${parts[0]}" "${parts[1]}"
}

# A canonical identity for "which repository/organization does this number
# belong to", comparable across dialects and casing.
#
#   $1  the URL to identify
#   $2  the host family to interpret it as: github|azdo|unknown
#
# $2 is the ORIGIN's classification, not the URL's own — deliberately. The
# question being answered is "is this reference about the repo under review",
# so an ADO repo compares organizations and a GitHub repo compares owner/repo.
# Classifying each URL independently would be a different (and arguably better)
# design; it is not this one, and changing it is a behaviour change, not a move.
#
# ADO goes through ado_org_name rather than a raw host comparison. Comparing
# hosts rejected `git@ssh.dev.azure.com:v3/<org>/...` against the very
# work-item URL the ADO web UI produces for that same org — and a legacy
# <org>.visualstudio.com remote against a dev.azure.com URL, which are the same
# organization spelled two ways.
reference_scope() {
    local url="$1" kind="${2:-unknown}" host owner_repo org
    if [[ "$kind" == "azdo" ]]; then
        # Assign first, then print: `printf "$(f)" || return 1` would bind the
        # || to printf, which succeeds on empty input, silently making an
        # underivable org compare equal to another underivable one.
        org=$(ado_org_name "$url") || return 1
        printf '%s' "$org"
        return 0
    fi
    host=$(remote_host "$url")
    # Same `*.github.com` tolerance host_kind applies above — an exact-match
    # guard here rejected www.github.com while detection accepted it. Keep the
    # two in step; they are adjacent in this file so the pairing stays visible.
    # Normalize to the bare host rather than stripping one label — `${host#*.}`
    # turned a.b.github.com into b.github.com, which still would not match.
    case "$host" in
        *.github.com) host="github.com" ;;
    esac
    owner_repo=$(url_owner_repo "$url") || return 1
    printf '%s/%s' "$host" "$owner_repo"
}

# Do two URLs name the same repository/organization?
#
#   $1  the reference URL under test
#   $2  the URL to compare it against (in practice, origin)
#   $3  the host family, as for reference_scope
#
# Distinguishes WHOSE fault a "no" is, because the two are not the same claim
# and only one of them is about the user's input:
#   0  — yes, same scope
#   1  — the reference names somewhere else. The user's URL is foreign.
#   2  — the COMPARISON url could not be identified (absent, or unparsable).
#        Nothing can be said about the reference either way, and blaming it
#        would be a confident false statement — an earlier version reported a
#        perfectly ordinary same-repo URL as "pointed at another repository"
#        purely because the repo had no origin remote.
#
# Returns non-zero to mean "no", so call it in conditional context under set -e.
urls_same_scope() {
    local ref_url="$1" against_url="$2" kind="${3:-unknown}" ref_scope against_scope
    [[ -n "$against_url" ]] || return 2
    against_scope=$(reference_scope "$against_url" "$kind") || return 2
    [[ -n "$against_scope" ]] || return 2
    ref_scope=$(reference_scope "$ref_url" "$kind") || return 1
    [[ -n "$ref_scope" ]] || return 1
    equals_ignoring_case "$ref_scope" "$against_scope"
}
