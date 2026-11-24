#!/usr/bin/env bash
# Unit tests for scripts/set-az-default-org.sh, the step setup-env.sh runs to
# set the Azure DevOps CLI default organization, plus one test of the
# setup-env.sh wiring. az is replaced by a stub (SETUP_ENV_AZ) that logs its
# arguments, so the real Azure CLI and its config are never touched.
#
# scripts/test-set-azdevopsdefaultorg.ps1 holds the same cases for the
# PowerShell twin; keep the two suites in step.
#
# Invoke: bash scripts/test_set-az-default-org.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$SCRIPT_DIR/set-az-default-org.sh"
TEAM_ORG="https://dev.azure.com/bgvone"

fail=0
pass=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- helpers -----------------------------------------------------------------

pass_check() { pass=$((pass + 1)); echo "  PASS $1"; }
fail_check() { fail=$((fail + 1)); echo "  FAIL $1"; }

check() {
    local label="$1"; shift
    if "$@"; then pass_check "$label"; else fail_check "$label"; fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { ! contains "$1" "$2"; }

# The stub answers `extension show`, `devops configure --list` and
# `devops configure --defaults` from STUB_* variables and logs every call.
STUB="$TEST_TMPDIR/az"
cat > "$STUB" <<'ENDOFSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
    "extension show") exit "${STUB_EXT_RC:-0}" ;;
    "devops configure")
        if [ "$3" = "--list" ]; then
            printf '%b' "${STUB_LIST-}"
            exit "${STUB_LIST_RC:-0}"
        fi
        exit "${STUB_SET_RC:-0}" ;;
esac
exit 99
ENDOFSTUB
chmod +x "$STUB"

# Fresh stub state for one test; extra NAME=value pairs go to the stub.
# Sets OUT (stdout+stderr), RC and LOG (the stub's calls).
run_sut() {
    local log="$TEST_TMPDIR/log.$RANDOM$RANDOM"
    : > "$log"
    OUT="$(env SETUP_ENV_AZ="$STUB" STUB_LOG="$log" "$@" bash "$SUT" "$TEAM_ORG" 2>&1)"
    RC=$?
    LOG="$(cat "$log")"
}

# --- tests ---------------------------------------------------------------------

SetAzDefaultOrg_NoArgument_ExitsWithUsageError() {
    local -r exit_usage=2
    # Act
    local out rc
    out="$(bash "$SUT" 2>&1)"
    rc=$?
    # Assert
    check "exits $exit_usage" [ "$rc" -eq "$exit_usage" ]
    check "prints usage" contains "$out" "usage:"
}

SetAzDefaultOrg_AzMissing_SkipsAndExitsZero() {
    # Act
    local out rc
    out="$(SETUP_ENV_AZ="$TEST_TMPDIR/no-such-az" bash "$SUT" "$TEAM_ORG" 2>&1)"
    rc=$?
    # Assert
    check "exits 0" [ "$rc" -eq 0 ]
    check "says az is missing" contains "$out" "Azure CLI not found"
}

SetAzDefaultOrg_ExtensionMissing_SkipsWithoutConfiguring() {
    # Act
    run_sut STUB_EXT_RC=1
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "names the install command" contains "$OUT" "az extension add --name azure-devops"
    check "never runs devops configure" not_contains "$LOG" "devops configure"
}

SetAzDefaultOrg_NoDefault_SetsTeamOrg() {
    # Arrange: what az prints on Windows when no organization is set.
    local -r listing='\r\n[defaults]\r\norganization = \r\nproject = \r\n\r\nUse git alias = No\r\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
    check "reports it" contains "$OUT" "Set the Azure DevOps default organization to $TEAM_ORG"
}

SetAzDefaultOrg_EmptyListing_SetsTeamOrg() {
    # Act
    run_sut STUB_LIST=''
    # Assert
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
}

SetAzDefaultOrg_SameOrgDifferentCaseAndSlash_DoesNotConfigure() {
    # Arrange
    local -r listing='[defaults]\r\norganization = https://dev.azure.com/BGVONE/ \r\nproject = P\r\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "says it is already set" contains "$OUT" "already"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_OtherOrg_KeepsIt() {
    # Arrange
    local -r listing='[defaults]\norganization = https://dev.azure.com/someone-else\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "keeps the developer's org" contains "$OUT" "Keeping your Azure DevOps default organization https://dev.azure.com/someone-else"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_ListFails_SkipsWithoutConfiguring() {
    # Act
    run_sut STUB_LIST_RC=1
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "warns" contains "$OUT" "could not read"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_SetFails_WarnsAndExitsZero() {
    # Act
    run_sut STUB_LIST='' STUB_SET_RC=1
    # Assert
    check "exits 0" [ "$RC" -eq 0 ]
    check "tells the developer the command to run" contains "$OUT" "az devops configure --defaults organization=$TEAM_ORG"
}

# --- setup-env.sh wiring -------------------------------------------------------

SetupEnv_NoAzDefault_SetsTeamOrg() {
    # Arrange
    local home="$TEST_TMPDIR/setup-home"
    mkdir -p "$home/.claude"
    local log="$TEST_TMPDIR/setup-log"
    : > "$log"
    # Act
    local out rc
    out="$(HOME="$home" GIT_CONFIG_GLOBAL="$home/.gitconfig" SETUP_ENV_AZ="$STUB" STUB_LOG="$log" \
        STUB_LIST='' bash "$REPO_ROOT/setup-env.sh" 2>&1)"
    rc=$?
    # Assert
    check "setup exits 0" [ "$rc" -eq 0 ]
    check "runs the az step" contains "$out" "=== Azure DevOps CLI ==="
    check "sets the team org" contains "$(cat "$log")" "devops configure --defaults organization=$TEAM_ORG"
}

# --- run ----------------------------------------------------------------------

bash -n "$SUT"
check "set-az-default-org.sh parses as valid bash" [ $? -eq 0 ]

for test_name in $(declare -F | awk '{ print $3 }' | grep -E '^(SetAzDefaultOrg|SetupEnv)_'); do
    echo "$test_name"
    "$test_name"
done

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
