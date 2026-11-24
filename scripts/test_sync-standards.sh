#!/usr/bin/env bash
# Unit tests for scripts/sync-standards.sh, the team-standards splice that
# setup-env.sh runs against ~/.claude/CLAUDE.md, plus one test of how
# setup-env.sh reacts when the splice refuses. Every test works in its own
# temp directory; nothing under the real home directory is touched.
#
# scripts/test-sync-teamstandards.ps1 holds the same cases for the PowerShell
# twin; keep the two suites in step.
#
# Invoke: bash scripts/test_sync-standards.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SCRIPT_DIR/sync-standards.sh"

START='<!-- TEAM-STANDARDS:tzander-skills:START -->'
END='<!-- TEAM-STANDARDS:tzander-skills:END -->'
BOM=$'\xEF\xBB\xBF'

fail=0
pass=0
skip=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- helpers -----------------------------------------------------------------

pass_check() { pass=$((pass + 1)); echo "  PASS $1"; }
fail_check() { fail=$((fail + 1)); echo "  FAIL $1"; }

check() {
    local label="$1"; shift
    if "$@"; then pass_check "$label"; else fail_check "$label"; fi
}

# Fresh case directory; sets CASE, TARGET and STANDARDS and writes the
# standards file with the given text plus a final newline.
new_case() {
    CASE="$TEST_TMPDIR/$1"
    mkdir -p "$CASE"
    TARGET="$CASE/CLAUDE.md"
    STANDARDS="$CASE/standards.md"
    printf '%s\n' "$2" > "$STANDARDS"
}

# Runs the sync; sets OUT (stdout+stderr) and RC.
run_sync() {
    OUT="$(bash "$SYNC" "$TARGET" "$STANDARDS" 2>&1)"
    RC=$?
}

# Passes when the file's bytes equal the printf-format expansion of $2.
file_is() {
    local file="$1" format="$2"; shift 2
    printf "$format" "$@" > "$CASE/expected"
    cmp -s "$file" "$CASE/expected"
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Asserts a refusal: the given exit code, the "Nothing was changed" message,
# a byte-identical target and no backup.
assert_refused() {
    local label="$1" expected_rc="$2"
    check "$label: exits $expected_rc" [ "$RC" -eq "$expected_rc" ]
    check "$label: says nothing was changed" contains "$OUT" "Nothing was changed"
    check "$label: target unchanged" cmp -s "$TARGET" "$CASE/before"
    check "$label: no backup written" [ ! -e "$TARGET.team-sync.bak" ]
}

# --- argument handling -------------------------------------------------------

SyncStandards_NoArguments_ExitsWithUsageError() {
    local -r exit_usage=2
    # Act
    bash "$SYNC" >/dev/null 2>&1
    local rc=$?
    # Assert
    check "no arguments exits $exit_usage" [ "$rc" -eq "$exit_usage" ]
}

SyncStandards_OneArgument_ExitsWithUsageError() {
    local -r exit_usage=2
    # Arrange
    new_case one-arg 'rule one'
    # Act
    bash "$SYNC" "$TARGET" >/dev/null 2>&1
    local rc=$?
    # Assert
    check "one argument exits $exit_usage" [ "$rc" -eq "$exit_usage" ]
    check "one argument creates no target" [ ! -e "$TARGET" ]
}

SyncStandards_MissingStandardsFile_ExitsWithUsageError() {
    local -r exit_usage=2
    # Arrange
    new_case missing-standards 'rule one'
    rm -f "$STANDARDS"
    # Act
    run_sync
    # Assert
    check "exits $exit_usage" [ "$RC" -eq "$exit_usage" ]
    check "names the missing file" contains "$OUT" "standards file not found"
    check "creates no target" [ ! -e "$TARGET" ]
}

SyncStandards_StandardsContainMarker_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case standards-marker "rule one
$END"
    printf 'mine\n%s\nold\n%s\n' "$START" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "marker in standards" "$exit_refused"
}

# --- create and append -------------------------------------------------------

SyncStandards_MissingTargetAndDirectory_CreatesFileWithBlock() {
    # Arrange
    new_case create 'rule one'
    TARGET="$CASE/nested/dir/CLAUDE.md"
    # Act
    run_sync
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "file is exactly the block" file_is "$TARGET" '%s\nrule one\n%s\n' "$START" "$END"
}

SyncStandards_EmptyTarget_AppendsBlockWithoutSeparator() {
    # Arrange
    new_case append-empty 'rule one'
    : > "$TARGET"
    # Act
    run_sync
    # Assert
    check "reports append" contains "$OUT" "Appended"
    check "file is exactly the block" file_is "$TARGET" '%s\nrule one\n%s\n' "$START" "$END"
}

SyncStandards_TargetWithoutFinalNewline_AppendsAfterOneBlankLine() {
    # Arrange
    new_case append-no-newline 'rule one'
    printf 'mine' > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n\n%s\nrule one\n%s\n' "$START" "$END"
}

SyncStandards_TargetEndingInNewline_AppendsAfterOneBlankLine() {
    # Arrange
    new_case append-newline 'rule one'
    printf 'mine\n' > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n\n%s\nrule one\n%s\n' "$START" "$END"
}

SyncStandards_TargetEndingInBlankLine_AppendsWithoutExtraBlankLine() {
    # Arrange
    new_case append-blank 'rule one'
    printf 'mine\n\n' > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n\n%s\nrule one\n%s\n' "$START" "$END"
}

# --- update ------------------------------------------------------------------

# Regression: a re-run used to drop every line above START.
SyncStandards_PersonalNotesAboveBlock_KeptAcrossReruns() {
    # Arrange
    new_case personal-above 'rule one'
    printf '# My notes\nkeep me\n' > "$TARGET"
    bash "$SYNC" "$TARGET" "$STANDARDS" >/dev/null 2>&1
    printf 'rule two\n' > "$STANDARDS"
    # Act
    run_sync
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "reports update" contains "$OUT" "Updated"
    check "file is exact" file_is "$TARGET" '# My notes\nkeep me\n\n%s\nrule two\n%s\n' "$START" "$END"
    # Act again
    run_sync
    # Assert again
    check "third run is a no-op" contains "$OUT" "already up to date"
}

SyncStandards_ContentAfterEndWithoutFinalNewline_KeptExactly() {
    # Arrange
    new_case personal-below 'rule two'
    printf 'top\n%s\nrule one\n%s\nbottom note' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact, no newline added" file_is "$TARGET" 'top\n%s\nrule two\n%s\nbottom note' "$START" "$END"
}

SyncStandards_StartFirstAndEndLastWithoutNewline_UpdatesBlock() {
    # Arrange
    new_case whole-file 'rule two'
    printf '%s\nrule one\n%s' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exactly the new block" file_is "$TARGET" '%s\nrule two\n%s\n' "$START" "$END"
}

SyncStandards_EmptyBlock_FillsBlock() {
    # Arrange
    new_case empty-block 'rule one'
    printf 'mine\n%s\n%s\n' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n%s\nrule one\n%s\n' "$START" "$END"
}

SyncStandards_UnchangedStandards_WritesNothing() {
    # Arrange
    new_case noop 'rule one'
    printf 'mine\n\n%s\nrule one\n%s\n' "$START" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    check "reports up to date" contains "$OUT" "already up to date"
    check "file bytes unchanged" cmp -s "$TARGET" "$CASE/before"
    check "no backup written" [ ! -e "$TARGET.team-sync.bak" ]
}

SyncStandards_OldPowerShellBlockFormat_IsNoOp() {
    # Arrange: the old PowerShell sync left a blank line before END.
    new_case old-ps-format 'rule one'
    printf 'mine\n%s\nrule one\n\n%s' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "trailing blank line in the old block is not a change" contains "$OUT" "already up to date"
}

SyncStandards_Update_BacksUpPreviousFileOverwritingOldBackup() {
    # Arrange
    new_case backup 'rule two'
    printf 'mine\n%s\nrule one\n%s\n' "$START" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    printf 'stale backup\n' > "$TARGET.team-sync.bak"
    # Act
    run_sync
    # Assert
    check "backup matches the previous file" cmp -s "$TARGET.team-sync.bak" "$CASE/before"
    check "reports the backup path" contains "$OUT" "team-sync.bak"
}

SyncStandards_Update_PrintsChangePreview() {
    # Arrange
    new_case preview 'rule two'
    printf '%s\nrule one\n%s\n' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "shows the removed line" contains "$OUT" "  - rule one"
    check "shows the added line" contains "$OUT" "  + rule two"
}

SyncStandards_Update_KeepsFileMode() {
    local -r private_mode='-rw-------'
    # Arrange
    new_case mode 'rule two'
    printf '%s\nrule one\n%s\n' "$START" "$END" > "$TARGET"
    chmod 600 "$TARGET"
    local before
    before="$(ls -l "$TARGET" | cut -c1-10)"
    if [ "$before" != "$private_mode" ]; then
        skip=$((skip + 1)); echo "  SKIP file modes are not supported here"
        return
    fi
    # Act
    run_sync
    # Assert
    check "mode stays $private_mode" [ "$(ls -l "$TARGET" | cut -c1-10)" = "$private_mode" ]
}

SyncStandards_SymlinkedTarget_UpdatesLinkTargetAndKeepsLink() {
    # Arrange
    new_case symlink 'rule two'
    printf 'mine\n%s\nrule one\n%s\n' "$START" "$END" > "$CASE/real.md"
    ln -s "$CASE/real.md" "$TARGET" 2>/dev/null
    if [ ! -L "$TARGET" ]; then
        skip=$((skip + 1)); echo "  SKIP symlinks cannot be created here"
        return
    fi
    # Act
    run_sync
    # Assert
    check "target is still a symlink" [ -L "$TARGET" ]
    check "linked file got the update" file_is "$CASE/real.md" 'mine\n%s\nrule two\n%s\n' "$START" "$END"
}

# --- refusals ------------------------------------------------------------------

SyncStandards_MissingEnd_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case missing-end 'rule two'
    printf 'mine\n%s\nrule one\nafter\n' "$START" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "missing END" "$exit_refused"
}

SyncStandards_MissingStart_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case missing-start 'rule two'
    printf 'mine\nrule one\n%s\nafter\n' "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "missing START" "$exit_refused"
}

SyncStandards_DuplicateStart_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case dup-start 'rule two'
    printf '%s\nx\n%s\ny\n%s\n' "$START" "$START" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "duplicate START" "$exit_refused"
}

SyncStandards_DuplicateEnd_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case dup-end 'rule two'
    printf '%s\nx\n%s\ny\n%s\n' "$START" "$END" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "duplicate END" "$exit_refused"
}

SyncStandards_EndBeforeStart_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case reversed 'rule two'
    printf '%s\nrule one\n%s\n' "$END" "$START" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "END before START" "$exit_refused"
}

SyncStandards_StartInsideOtherText_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case inline-start 'rule two'
    printf 'see %s here\n%s\nrule one\n%s\n' "$START" "$START" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "inline START" "$exit_refused"
}

SyncStandards_EndInsideOtherText_RefusesWithoutWriting() {
    local -r exit_refused=1
    # Arrange
    new_case inline-end 'rule two'
    printf '%s\nrule one\n%s\nsee %s here\n' "$START" "$END" "$END" > "$TARGET"
    cp "$TARGET" "$CASE/before"
    # Act
    run_sync
    # Assert
    assert_refused "inline END" "$exit_refused"
}

# --- line endings and encodings ----------------------------------------------

SyncStandards_CrlfTarget_KeepsPersonalCrlfAndRerunIsNoOp() {
    # Arrange
    new_case crlf 'rule two'
    printf 'mine\r\n%s\r\nrule one\r\n%s\r\ntail\r\n' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert: the team block itself is written with LF.
    check "file is exact" file_is "$TARGET" 'mine\r\n%s\nrule two\n%s\ntail\r\n' "$START" "$END"
    # Act again
    run_sync
    # Assert again
    check "re-run is a no-op" contains "$OUT" "already up to date"
}

SyncStandards_CrlfStandards_WritesLfBlockAndRerunIsNoOp() {
    # Arrange
    new_case crlf-standards 'unused'
    printf 'rule one\r\nrule two\r\n' > "$STANDARDS"
    printf 'mine\n' > "$TARGET"
    # Act
    run_sync
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n\n%s\nrule one\nrule two\n%s\n' "$START" "$END"
    check "re-run is a no-op" contains "$OUT" "already up to date"
}

SyncStandards_StandardsWithTrailingBlankLines_RerunIsNoOp() {
    # Arrange
    new_case trailing-blank-standards 'unused'
    printf 'rule one\n\n\n' > "$STANDARDS"
    printf 'mine\n' > "$TARGET"
    # Act
    run_sync
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n\n%s\nrule one\n%s\n' "$START" "$END"
    check "re-run is a no-op" contains "$OUT" "already up to date"
}

SyncStandards_BomBeforeStartOnFirstLine_UpdatesAndKeepsBom() {
    # Arrange
    new_case bom-target 'rule two'
    printf '%s%s\nrule one\n%s\nafter\n' "$BOM" "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "file is exact, BOM kept" file_is "$TARGET" '%s%s\nrule two\n%s\nafter\n' "$BOM" "$START" "$END"
}

SyncStandards_BomInStandards_KeptOutOfBlock() {
    # Arrange
    new_case bom-standards 'unused'
    printf '%srule one\n' "$BOM" > "$STANDARDS"
    printf 'mine\n' > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact, no BOM inside the block" file_is "$TARGET" 'mine\n\n%s\nrule one\n%s\n' "$START" "$END"
}

SyncStandards_ReplacementTokensInStandards_WrittenLiterallyWithoutGrowth() {
    # Arrange
    new_case tokens 'cost is $$5 and $& and $_ and \1'
    printf 'mine\n%s\nold\n%s\n' "$START" "$END" > "$TARGET"
    # Act
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" 'mine\n%s\n%s\n%s\n' "$START" 'cost is $$5 and $& and $_ and \1' "$END"
    # Act again
    cp "$TARGET" "$CASE/first"
    run_sync
    # Assert again
    check "re-run is a no-op" contains "$OUT" "already up to date"
    check "file does not grow" cmp -s "$TARGET" "$CASE/first"
}

SyncStandards_NonAsciiText_RoundTripsUnchanged() {
    # Arrange
    local -r rule='rule — with “quotes” → ✅'
    local -r note='café notes'
    new_case unicode "$rule"
    printf '%s\n' "$note" > "$TARGET"
    # Act
    run_sync
    run_sync
    # Assert
    check "file is exact" file_is "$TARGET" '%s\n\n%s\n%s\n%s\n' "$note" "$START" "$rule" "$END"
    check "re-run is a no-op" contains "$OUT" "already up to date"
}

SyncStandards_RepositoryStandardsFile_SyncsAndRerunIsNoOp() {
    # Arrange
    new_case repo-standards 'unused'
    STANDARDS="$REPO_ROOT/standards/CLAUDE.md"
    printf 'mine\n' > "$TARGET"
    # Act
    run_sync
    run_sync
    # Assert
    check "real standards sync cleanly" contains "$OUT" "already up to date"
}

# --- setup-env.sh wiring -------------------------------------------------------

SetupEnv_DamagedMarkers_SyncsSettingsAndExitsNonZero() {
    local -r exit_failed=1
    # Arrange
    local home="$TEST_TMPDIR/setup-home"
    mkdir -p "$home/.claude"
    printf 'mine\n%s\nrule one\n' "$START" > "$home/.claude/CLAUDE.md"
    cp "$home/.claude/CLAUDE.md" "$TEST_TMPDIR/setup-before"
    # Act
    local out rc
    # SETUP_ENV_AZ names no command, so the az step skips instead of running the real CLI.
    out="$(HOME="$home" GIT_CONFIG_GLOBAL="$home/.gitconfig" SETUP_ENV_AZ="$TEST_TMPDIR/no-such-az" \
        bash "$REPO_ROOT/setup-env.sh" 2>&1)"
    rc=$?
    # Assert
    check "setup exits $exit_failed" [ "$rc" -eq "$exit_failed" ]
    check "CLAUDE.md untouched" cmp -s "$home/.claude/CLAUDE.md" "$TEST_TMPDIR/setup-before"
    check "settings step still ran" [ -f "$home/.claude/settings.json" ]
    check "reports the failure at the end" contains "$out" "finished with errors"
}

# --- run ----------------------------------------------------------------------

bash -n "$SYNC"
check "sync-standards.sh parses as valid bash" [ $? -eq 0 ]

for test_name in $(declare -F | awk '{ print $3 }' | grep -E '^(SyncStandards|SetupEnv)_'); do
    echo "$test_name"
    "$test_name"
done

echo ""
echo "Passed: $pass  Failed: $fail  Skipped: $skip"
[ "$fail" -eq 0 ]
