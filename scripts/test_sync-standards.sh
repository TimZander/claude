#!/usr/bin/env bash
# Smoke test for scripts/sync-standards.sh, the team-standards splice that
# setup-env.sh runs against ~/.claude/CLAUDE.md. Every case works on temp
# files; nothing under the real home directory is touched.
#
# The core regression: a re-run used to drop every line above the START
# marker, deleting the developer's own notes.
#
# Invoke: bash scripts/test_sync-standards.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC="$SCRIPT_DIR/sync-standards.sh"

START='<!-- TEAM-STANDARDS:tzander-skills:START -->'
END='<!-- TEAM-STANDARDS:tzander-skills:END -->'

fail=0
pass=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

check() {
    local label="$1"; shift
    if "$@"; then
        pass=$((pass + 1)); echo "  PASS $label"
    else
        fail=$((fail + 1)); echo "  FAIL $label"
    fi
}

# Fresh case directory with a standards file holding $1.
new_case() {
    CASE="$TEST_TMPDIR/$1"
    mkdir -p "$CASE"
    TARGET="$CASE/CLAUDE.md"
    STANDARDS="$CASE/standards.md"
    printf '%s\n' "$2" > "$STANDARDS"
}

run_sync() {
    OUT="$(bash "$SYNC" "$TARGET" "$STANDARDS" 2>&1)"
    RC=$?
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
file_has() { grep -qF -- "$2" "$1"; }
count_lines() { grep -cxF -- "$2" "$1"; }

echo "1) usage error without arguments"
bash "$SYNC" >/dev/null 2>&1
check "exits 2 with no arguments" [ $? -eq 2 ]
bash -n "$SYNC"
check "sync-standards.sh parses as valid bash" [ $? -eq 0 ]

echo "2) creates the file when it is missing"
new_case create 'rule one'
run_sync
check "exit 0" [ "$RC" -eq 0 ]
check "file holds the managed block" [ "$(cat "$TARGET")" = "$START
rule one
$END" ]

echo "3) regression: personal notes above the block survive re-runs"
new_case personal-above 'rule one'
printf '# My notes\nkeep me\n' > "$TARGET"
run_sync
check "first run appends" contains "$OUT" "Appended"
printf 'rule two\n' > "$STANDARDS"
run_sync
check "second run exits 0" [ "$RC" -eq 0 ]
check "second run updates" contains "$OUT" "Updated"
check "personal heading kept" file_has "$TARGET" "# My notes"
check "personal line kept" file_has "$TARGET" "keep me"
check "new standards present" file_has "$TARGET" "rule two"
check "old standards gone" [ "$(grep -cxF 'rule one' "$TARGET")" -eq 0 ]
run_sync
check "third run is a no-op" contains "$OUT" "already up to date"
check "personal line still kept after third run" file_has "$TARGET" "keep me"

echo "4) content after the END marker is kept"
new_case personal-below 'rule two'
printf 'top\n%s\nrule one\n%s\nbottom note\n' "$START" "$END" > "$TARGET"
run_sync
check "exit 0" [ "$RC" -eq 0 ]
check "file is exactly top + new block + bottom" [ "$(cat "$TARGET")" = "top
$START
rule two
$END
bottom note" ]

echo "5) unchanged standards: no write, no backup"
new_case noop 'rule one'
printf 'mine\n\n%s\nrule one\n%s\n' "$START" "$END" > "$TARGET"
cp "$TARGET" "$CASE/before"
run_sync
check "reports up to date" contains "$OUT" "already up to date"
check "file bytes unchanged" cmp -s "$TARGET" "$CASE/before"
check "no backup written" [ ! -e "$TARGET.team-sync.bak" ]

echo "6) an update leaves a backup of the previous file"
new_case backup 'rule two'
printf 'mine\n%s\nrule one\n%s\n' "$START" "$END" > "$TARGET"
cp "$TARGET" "$CASE/before"
run_sync
check "backup matches the previous file" cmp -s "$TARGET.team-sync.bak" "$CASE/before"
check "no staging file left behind" [ -z "$(ls -A "$CASE" | grep '^\.claude-md-sync')" ]

# Damaged markers: each case must exit 1 and leave the file byte-identical.
expect_refusal() {
    local label="$1"
    cp "$TARGET" "$CASE/before"
    run_sync
    check "$label: exits 1" [ "$RC" -eq 1 ]
    check "$label: file unchanged" cmp -s "$TARGET" "$CASE/before"
    check "$label: no backup written" [ ! -e "$TARGET.team-sync.bak" ]
    check "$label: says nothing was changed" contains "$OUT" "Nothing was changed"
}

echo "7) missing END marker is refused"
new_case missing-end 'rule two'
printf 'mine\n%s\nrule one\nafter\n' "$START" > "$TARGET"
expect_refusal "missing END"

echo "8) missing START marker is refused"
new_case missing-start 'rule two'
printf 'mine\nrule one\n%s\nafter\n' "$END" > "$TARGET"
expect_refusal "missing START"

echo "9) duplicate START marker is refused"
new_case dup-start 'rule two'
printf '%s\nx\n%s\ny\n%s\n' "$START" "$START" "$END" > "$TARGET"
expect_refusal "duplicate START"

echo "10) END before START is refused"
new_case reversed 'rule two'
printf '%s\nrule one\n%s\n' "$END" "$START" > "$TARGET"
expect_refusal "END before START"

echo "11) a marker inside other text is refused"
new_case inline 'rule two'
printf 'see %s here\n%s\nrule one\n%s\n' "$START" "$START" "$END" > "$TARGET"
expect_refusal "inline marker"

echo "12) CRLF file: markers found, personal CRLF lines kept"
new_case crlf 'rule two'
printf 'mine\r\n%s\r\nrule one\r\n%s\r\ntail\r\n' "$START" "$END" > "$TARGET"
run_sync
check "exit 0" [ "$RC" -eq 0 ]
check "personal CRLF line kept byte for byte" [ "$(head -c 6 "$TARGET" | od -An -c | tr -d ' \n')" = 'mine\r\n' ]
check "trailing CRLF line kept byte for byte" [ "$(tail -c 6 "$TARGET" | od -An -c | tr -d ' \n')" = 'tail\r\n' ]
check "trailing line kept" file_has "$TARGET" "tail"
check "exactly one START after update" [ "$(count_lines "$TARGET" "$START")" -eq 1 ]
check "new standards present" file_has "$TARGET" "rule two"

echo "13) replacement-token text in the standards stays literal"
new_case tokens 'cost is $$5 and $& and $_ and \1'
printf 'mine\n%s\nold\n%s\n' "$START" "$END" > "$TARGET"
run_sync
check "literal tokens written" file_has "$TARGET" 'cost is $$5 and $& and $_ and \1'
run_sync
check "second run is a no-op" contains "$OUT" "already up to date"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
