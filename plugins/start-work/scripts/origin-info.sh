#!/usr/bin/env bash
# Classify a git remote URL for start-work: which source it belongs to and, for Azure
# DevOps, its organization and project.
#
# Usage:
#   origin-info.sh [<remote-url>]
#
# With no argument it reads `git remote get-url origin` in the current directory.
#
# Prints exactly these lines on stdout (exit 0):
#   SOURCE=github|ado|other|none
#   ORG=<organization>      (ado only; empty when not found)
#   PROJECT=<project>       (ado only; empty when not found)
#
# The URL itself is never printed: a remote can carry a user name and a password or
# token in its userinfo, and nothing here may echo it.
#
# Exit codes: 0 on success (including SOURCE=other and SOURCE=none), 2 for a usage error.

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [<remote-url>]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    URL="$1"
else
    URL="$(git remote get-url origin 2>/dev/null || true)"
fi

emit() {
    echo "SOURCE=$1"
    if [ "$1" = "ado" ]; then
        echo "ORG=$2"
        echo "PROJECT=$3"
    fi
    exit 0
}

if [ -z "$URL" ]; then
    emit none
fi

# A URL with a newline or other control character is not something to parse.
if [[ $URL =~ [[:cntrl:]] ]]; then
    emit other
fi

# Split into authority and path.
#   scheme://[userinfo@]host[:port]/path
#   [userinfo@]host:path            (scp-like, no scheme)
SCHEME_PATTERN='^[A-Za-z][A-Za-z0-9+.-]*://'
if [[ $URL =~ $SCHEME_PATTERN ]]; then
    rest="${URL#*://}"
    authority="${rest%%/*}"
    if [ "$authority" = "$rest" ]; then
        path=""
    else
        path="${rest#*/}"
    fi
    # The host follows the LAST "@" in the authority, after any user name and
    # password or token.
    host="${authority##*@}"
    # Drop a port (or a bracketed IPv6 literal's port).
    host="${host%%:*}"
else
    case "$URL" in
        *:*) ;;
        *) emit other ;; # a local path
    esac
    before="${URL%%:*}"
    path="${URL#*:}"
    host="${before##*@}"
fi

host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"  # hosts compare case-insensitively
# Drop a query or fragment, and trailing slashes.
path="${path%%[?#]*}"
while [ "${path%/}" != "$path" ]; do path="${path%/}"; done

# Percent-decode one value; refuse a result with control characters.
decode() {
    # Double any backslash first, so printf %b decodes only the %XX escapes.
    local v="${1//\\/\\\\}"
    v="$(printf '%b' "${v//%/\\x}")"
    if [[ $v =~ [[:cntrl:]] ]]; then
        printf ''
    else
        printf '%s' "$v"
    fi
}

# The first four path segments (no arrays: an empty array under `set -u` fails on
# bash 3.2, which macOS ships).
IFS='/' read -r p0 p1 p2 p3 _ <<<"$path" || true

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# "v3/<org>/<project>/<repo>" (the Azure DevOps SSH form).
ado_ssh() {
    if [ "$p0" = "v3" ] && [ -n "$p1" ] && [ -n "$p2" ] && [ -n "$p3" ]; then
        emit ado "$(decode "$p1")" "$(decode "$p2")"
    fi
    emit ado "" ""
}

# "[DefaultCollection/][<project>/]_git/<repo>" after the organization; with no
# project segment the project has the repository's name.
ado_git_path() { # $1 org, $2-$5 the next path segments
    local org="$1" a="${2:-}" b="${3:-}" c="${4:-}" d="${5:-}"
    if [ "$(lower "$a")" = "defaultcollection" ]; then
        a="$b"; b="$c"; c="$d"
    fi
    if [ -n "$a" ] && [ "$a" != "_git" ] && [ "$b" = "_git" ] && [ -n "$c" ]; then
        emit ado "$(decode "$org")" "$(decode "$a")"
    fi
    if [ "$a" = "_git" ] && [ -n "$b" ]; then
        emit ado "$(decode "$org")" "$(decode "${b%.git}")"
    fi
    emit ado "$(decode "$org")" ""
}

case "$host" in
    github.com | ssh.github.com)
        emit github
        ;;
    ssh.dev.azure.com | vs-ssh.visualstudio.com)
        ado_ssh
        ;;
    dev.azure.com)
        if [ -n "$p0" ]; then
            IFS='/' read -r _ q1 q2 q3 q4 _ <<<"$path" || true
            ado_git_path "$p0" "$q1" "$q2" "$q3" "$q4"
        fi
        emit ado "" ""
        ;;
    *.visualstudio.com)
        ado_git_path "${host%.visualstudio.com}" "$p0" "$p1" "$p2" "$p3"
        ;;
    *)
        emit other
        ;;
esac
