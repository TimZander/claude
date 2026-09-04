# lib-remote.sh — Git remote URL parsing, shared by this plugin's scripts.
#
# SOURCE this file; do not execute it. It defines functions and nothing else:
# no top-level statements, no shell options, no output. The sourcing script
# owns `set -euo pipefail` — a library that sets shell options changes the
# behaviour of whoever sourced it, which is not its call to make.
#
#   SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/lib-remote.sh"
#
# SCOPE: every function here is PURE — it takes a URL as "$1" and reads no
# global state. That is what makes them safe to share. Anything that compares
# a reference against *this* review's origin (reference_scope,
# reference_url_is_local) stays in resolve-pr.sh, because it depends on that
# script's notion of which repository is under review.
#
# Why a sourced file rather than a second copy: resolve-pr.sh's own note above
# `remote_host` says host detection was "copied rather than sourced — plugins
# are installed independently and must stand alone". That constraint is about
# reaching ACROSS plugin boundaries, and it still holds: this file ships inside
# deep-review/scripts/, so deep-review remains self-contained and installable on
# its own. A different plugin still cannot source this — it would have to vendor
# its own copy or shell out to a deep-review script.

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
        github.com|*.github.com)                        printf 'github' ;;
        dev.azure.com|ssh.dev.azure.com|*.visualstudio.com) printf 'azdo' ;;
        *)                                              printf 'unknown' ;;
    esac
}

# Case-insensitive string equality, without lowercasing.
#
# An earlier version ran both operands through `printf | tr`. That is one FORK
# PER CALL, and locality is checked up to three times per invocation — on Git
# Bash, where process creation is expensive, it added minutes to the test suite.
# `nocasematch` does the same job in-process. It is a shell-global option, so it
# is restored immediately; `shopt -p` reproduces the prior state exactly whether
# it was set or unset.
equals_ignoring_case() {
    local restore
    restore=$(shopt -p nocasematch)
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

# The repository name from a remote (last path segment, minus .git).
origin_repo_name() {
    local url="${1%/}"
    url="${url%.git}"
    printf '%s' "${url##*/}"
}

# Path portion of a URL, host stripped. scp-style remotes (git@host:path) are
# normalized to host/path first so both forms compare segment-wise.
url_after_host() {
    local url="$1" authority path
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
    authority="${url%%/*}"
    if [[ "$url" == */* ]]; then
        path="${url#*/}"
    else
        path=""
    fi
    authority="${authority#*@}"
    : "$authority"          # parsed for correctness; only the path is returned
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
