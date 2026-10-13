#!/usr/bin/env bash
# Smoke test for cloud/setup.sh and its profiles.
#
# Runs setup.sh against stub claude/apt-get/npm/gh/openspec binaries that only
# record their arguments, so nothing is installed and root is not needed.
#
# What's NOT covered: cloud/bootstrap.sh's clone (needs network) and real
# installs. Verify those by starting a cloud session and reading
# /root/setup-script.log.
#
# Invoke: bash cloud/test_setup.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$SCRIPT_DIR/setup.sh"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"

fail=0
pass=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

ok()  { pass=$((pass + 1)); echo "  PASS $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; }

assert_equal() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "want: $1"$'\n'"got:  $2"; fi
}
assert_contains() {
    case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "missing: $2"$'\n'"in: $1" ;; esac
}
assert_not_contains() {
    case "$1" in *"$2"*) bad "$3" "unexpected: $2" ;; *) ok "$3" ;; esac
}

# make_stubs <dir> <cmd>... — each stub appends "<cmd> <args>" to $CALLS.
make_stubs() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local cmd
    for cmd in "$@"; do
        printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$cmd" > "$dir/$cmd"
        chmod +x "$dir/$cmd"
    done
}

# run_setup <case-name> <stub-cmds> <setup-args>... — sets OUT, CODE, CALLS_TXT, CASE.
run_setup() {
    CASE="$TEST_TMPDIR/$1"; local stubs="$2"; shift 2
    mkdir -p "$CASE/apt"
    touch "$CASE/apt/deadsnakes-ppa.list" "$CASE/apt/ondrej-php.list" "$CASE/apt/keep.list"
    # shellcheck disable=SC2086
    make_stubs "$CASE/bin" $stubs
    export CALLS="$CASE/calls.txt"
    : > "$CALLS"
    OUT="$(PATH="$CASE/bin:/usr/bin:/bin" \
        CLOUD_SETUP_CLAUDE_HOME="$CASE/claude-home" \
        CLOUD_SETUP_APT_SOURCES_DIR="$CASE/apt" \
        GH_TOKEN="" GITHUB_TOKEN="" \
        bash "$SETUP" "$@" 2>&1)"
    CODE=$?
    CALLS_TXT="$(cat "$CALLS")"
}

echo "usage errors"
run_setup no-profile "" 
assert_equal 2 "$CODE" "no profile exits 2"
assert_contains "$OUT" "Available profiles" "no profile lists profiles"
assert_contains "$OUT" "  sdd" "profile list includes sdd"
run_setup bad-profile "" nope
assert_equal 2 "$CODE" "unknown profile exits 2"
assert_equal "" "$CALLS_TXT" "unknown profile runs nothing"

echo "default profile"
run_setup default "claude apt-get npm gh" default
assert_equal 0 "$CODE" "exits 0"
assert_contains "$CALLS_TXT" "claude plugin marketplace add TimZander/claude" "adds marketplace"
assert_not_contains "$CALLS_TXT" "TimZander/claude#" "no ref pins nothing"
assert_contains "$CALLS_TXT" "claude plugin install deep-review@tzander-skills" "installs deep-review"
assert_contains "$CALLS_TXT" "apt-get install -y -qq gh" "installs gh"
assert_not_contains "$CALLS_TXT" "npm install" "no npm install"
assert_equal "keep.list" "$(ls "$CASE/apt")" "removes only the broken PPAs"
if cmp -s "$REPO_ROOT/standards/CLAUDE.md" "$CASE/claude-home/CLAUDE.md"; then
    ok "copies team standards"
else
    bad "copies team standards"
fi
assert_not_contains "$OUT" "WARNING" "no warnings"

echo "ref"
run_setup ref "claude apt-get npm gh" default "$REPO_ROOT" my-branch
assert_contains "$CALLS_TXT" "claude plugin marketplace add TimZander/claude#my-branch" "installs plugins from the ref"

echo "sdd profile"
run_setup sdd "claude apt-get npm gh openspec" sdd
assert_equal 0 "$CODE" "exits 0"
assert_contains "$CALLS_TXT" "npm install -g --no-fund --no-audit @fission-ai/openspec@latest" "installs OpenSpec"
assert_contains "$OUT" "openspec: " "verifies openspec"
assert_not_contains "$OUT" "WARNING" "no warnings"

echo "missing tools are warnings, not failures"
run_setup sdd-missing "apt-get" sdd
assert_equal 0 "$CODE" "exits 0"
assert_contains "$OUT" "WARNING: claude not on PATH" "warns on missing claude"
assert_contains "$OUT" "WARNING: npm not on PATH" "warns on missing npm"
assert_contains "$OUT" "WARNING: openspec missing" "warns on missing openspec"

echo "profiles"
for profile in "$SCRIPT_DIR"/profiles/*.sh; do
    name="$(basename "$profile" .sh)"
    PLUGINS=""
    # shellcheck source=/dev/null
    . "$profile"
    for p in $PLUGINS; do
        if grep -q "\"name\": \"$p\"" "$MARKETPLACE"; then
            ok "$name: $p is in the marketplace"
        else
            bad "$name: $p is not in the marketplace"
        fi
    done
done
boot_profile="$(sed -n 's/^PROFILE="\([^"]*\)".*/\1/p' "$SCRIPT_DIR/bootstrap.sh")"
if [ -f "$SCRIPT_DIR/profiles/${boot_profile}.sh" ]; then
    ok "bootstrap.sh PROFILE '$boot_profile' exists"
else
    bad "bootstrap.sh PROFILE '$boot_profile' exists"
fi
assert_contains "$(cat "$SCRIPT_DIR/bootstrap.sh")" 'setup.sh" "$PROFILE" "$SRC" "$REF"' "bootstrap.sh passes REF to setup.sh"
if bash -n "$SCRIPT_DIR/bootstrap.sh"; then ok "bootstrap.sh syntax"; else bad "bootstrap.sh syntax"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
