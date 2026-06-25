#!/usr/bin/env bash
# Regression guard for issue #157 — the `git config` GET footgun.
#
# Bug: placing a read flag AFTER the key (`git config user.email --get`)
# makes git parse the flag as the VALUE and silently *set* the key to the
# literal string `--get` (exit 0, no output). In a worktree this writes to
# the shared common .git/config and corrupts the author identity for every
# worktree of the repo. The safe form puts the flag first: `git config
# --get user.email`.
#
# What this guards: scans all tracked files for the dangerous ordering
# `git config <key> --get` and fails if any reappear. This is the only
# testable surface — the fix itself is documentation/prompt-template text,
# which the team Unit Test Standards exempt, but a grep guard is cheap
# insurance against the pattern creeping back into a skill or script.
#
# Known limitation (no silent cap): the pattern allows leading dash-flags
# before the key (e.g. `git config --global KEY --get` is caught) but does
# not attempt to model every git-config invocation. It targets the simple,
# recurring form our tooling actually uses.
#
# Allowlist: a line that intentionally *documents* the bad form (a teaching
# counter-example) can opt out by including the marker `footgun-allow` on the
# same line — e.g. an HTML comment in a markdown doc.
#
# Invoke: bash scripts/test_no-git-config-get-footgun.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF_REL="scripts/$(basename "$0")"

# ERE for the dangerous ordering: `git config`, optional leading dash-flags,
# then a key token that does NOT start with `-`, then a `--get*` read flag.
# Matches `git config user.email --get`; does NOT match the safe
# `git config --get user.email` (the token after `git config ` is a dash-flag).
PATTERN='git config([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]-][^[:space:]]*[[:space:]]+--get'

fail=0
pass=0

assert() {
    local cond="$1" label="$2"
    if [ "$cond" -eq 0 ]; then
        pass=$((pass + 1)); echo "  PASS $label"
    else
        fail=$((fail + 1)); echo "  FAIL $label"
    fi
}

echo "1) this guard parses as valid bash"
if bash -n "$0"; then
    pass=$((pass + 1)); echo "  PASS bash -n parses the guard"
else
    fail=$((fail + 1)); echo "  FAIL bash -n reported a syntax error"
fi

echo "2) regex sanity: dangerous form is detected"
printf '%s\n' 'git config user.email --get' | grep -Eq "$PATTERN"
assert $? "key-before-flag ordering matches the pattern"

echo "3) regex sanity: leading flags before the key still caught"
printf '%s\n' 'git config --global user.email --get' | grep -Eq "$PATTERN"
assert $? "'--global KEY --get' matches the pattern"

echo "4) regex sanity: safe form is NOT a false positive"
if printf '%s\n' 'git config --get user.email' | grep -Eq "$PATTERN"; then
    fail=$((fail + 1)); echo "  FAIL safe 'git config --get user.email' wrongly matched"
else
    pass=$((pass + 1)); echo "  PASS safe flag-before-key form is ignored"
fi

echo "5) regex sanity: plain set is NOT a false positive"
if printf '%s\n' 'git config user.email "you@example.com"' | grep -Eq "$PATTERN"; then
    fail=$((fail + 1)); echo "  FAIL plain set wrongly matched"
else
    pass=$((pass + 1)); echo "  PASS plain 'git config <key> <value>' is ignored"
fi

echo "6) repo scan: no tracked file uses the dangerous ordering"
# git grep searches tracked files in the working tree. Exclude this guard,
# which embeds the dangerous string as test fixtures above, and drop any line
# carrying the `footgun-allow` marker (intentional teaching counter-examples).
matches="$(cd "$REPO_ROOT" && git grep -nE "$PATTERN" -- ":!$SELF_REL" 2>/dev/null | grep -v 'footgun-allow')"
if [ -z "$matches" ]; then
    pass=$((pass + 1)); echo "  PASS no occurrences in tracked files"
else
    fail=$((fail + 1)); echo "  FAIL dangerous ordering found:"
    printf '%s\n' "$matches" | sed 's/^/    /'
fi

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
