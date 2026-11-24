#!/usr/bin/env bash
# Unit tests for scripts/set-az-default-org.sh, the step setup-env.sh runs to
# set the Azure DevOps CLI default organization, plus tests of the setup-env.sh
# wiring. az is replaced by a stub (SETUP_ENV_AZ, or a stub named `az` first on
# PATH) that logs its arguments, so the real Azure CLI and its config are never
# touched.
#
# scripts/test-set-azdevopsdefaultorg.ps1 holds the same cases for the
# PowerShell twin; keep the two suites in step. Two cases are bash-only: stdin
# closed for az (a native-process property the in-process PowerShell stub
# cannot observe) and the team org being equal in both setup-env scripts.
#
# Invoke: bash scripts/test_set-az-default-org.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$SCRIPT_DIR/set-az-default-org.sh"
TEAM_ORG="https://dev.azure.com/bgvone"

fail=0
pass=0
tests_run=0

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
# `devops configure --defaults` from STUB_* variables, logs every call, writes
# STUB_STDERR to stderr on every call, and logs whether stdin held data.
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
STUB="$STUB_BIN/az"
cat > "$STUB" <<'ENDOFSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if read -r -t 1 _; then echo "stdin=data" >> "$STUB_LOG"; else echo "stdin=empty" >> "$STUB_LOG"; fi
if [ -n "${STUB_STDERR-}" ]; then printf '%s\n' "$STUB_STDERR" >&2; fi
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

# Runs the script against the stub. SUT_ORG (default TEAM_ORG) is the argument;
# extra NAME=value pairs go to the stub. Sets OUT (stdout), ERR (stderr), RC
# and LOG (the stub's calls).
run_sut() {
    local log="$TEST_TMPDIR/log.$RANDOM$RANDOM" err="$TEST_TMPDIR/err.$RANDOM$RANDOM"
    : > "$log"
    OUT="$(env SETUP_ENV_AZ="$STUB" STUB_LOG="$log" "$@" bash "$SUT" "${SUT_ORG:-$TEAM_ORG}" 2>"$err" </dev/null)"
    RC=$?
    ERR="$(cat "$err")"
    LOG="$(cat "$log")"
}

# --- usage -------------------------------------------------------------------

SetAzDefaultOrg_NoArgument_ExitsWithUsageError() {
    # Arrange
    local -r exit_usage=2
    # Act
    local out rc
    out="$(bash "$SUT" 2>&1)"
    rc=$?
    # Assert
    check "exits $exit_usage" [ "$rc" -eq "$exit_usage" ]
    check "prints usage" contains "$out" "usage:"
}

SetAzDefaultOrg_EmptyArgument_ExitsWithUsageError() {
    # Arrange
    local -r exit_usage=2
    # Act
    local out rc
    out="$(bash "$SUT" '' 2>&1)"
    rc=$?
    # Assert
    check "exits $exit_usage" [ "$rc" -eq "$exit_usage" ]
    check "prints usage" contains "$out" "usage:"
}

SetAzDefaultOrg_TwoArguments_ExitsWithUsageError() {
    # Arrange
    local -r exit_usage=2
    # Act
    local out rc
    out="$(bash "$SUT" "$TEAM_ORG" extra 2>&1)"
    rc=$?
    # Assert
    check "exits $exit_usage" [ "$rc" -eq "$exit_usage" ]
    check "prints usage" contains "$out" "usage:"
}

# --- finding az --------------------------------------------------------------

SetAzDefaultOrg_AzMissing_SkipsAndExitsZero() {
    # Arrange
    local -r exit_ok=0
    local missing="$TEST_TMPDIR/no-such-az"
    # Act
    local out rc
    out="$(SETUP_ENV_AZ="$missing" bash "$SUT" "$TEAM_ORG" 2>&1)"
    rc=$?
    # Assert
    check "exits $exit_ok" [ "$rc" -eq "$exit_ok" ]
    check "says az is missing" contains "$out" "Azure CLI not found"
}

SetAzDefaultOrg_AzOverridden_SaysWhichAzRuns() {
    # Arrange
    local -r exit_ok=0
    # Act
    run_sut
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "names the override" contains "$OUT" "Using az from SETUP_ENV_AZ: $STUB"
}

SetAzDefaultOrg_NoOverride_RunsAzFromPath() {
    # Arrange: SETUP_ENV_AZ unset, the stub named `az` first on PATH.
    local -r exit_ok=0
    local log="$TEST_TMPDIR/path-log"
    : > "$log"
    # Act
    local out rc
    out="$(env -u SETUP_ENV_AZ PATH="$STUB_BIN:$PATH" STUB_LOG="$log" bash "$SUT" "$TEAM_ORG" 2>&1 </dev/null)"
    rc=$?
    # Assert
    check "exits $exit_ok" [ "$rc" -eq "$exit_ok" ]
    check "runs the az found on PATH" contains "$(cat "$log")" "extension show --name azure-devops"
    check "does not claim an override" not_contains "$out" "SETUP_ENV_AZ"
}

# --- the extension -----------------------------------------------------------

SetAzDefaultOrg_ExtensionMissing_SkipsWithoutConfiguring() {
    # Arrange
    local -r exit_ok=0 rc_failure=1
    local -r az_message="extension 'azure-devops' is not installed"
    # Act
    run_sut STUB_EXT_RC="$rc_failure" STUB_STDERR="$az_message"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "checks the extension" contains "$LOG" "extension show --name azure-devops"
    check "names the install command" contains "$OUT" "az extension add --name azure-devops"
    check "shows az's own message" contains "$OUT" "$az_message"
    check "never runs devops configure" not_contains "$LOG" "devops configure"
}

# --- reading the current default ---------------------------------------------

SetAzDefaultOrg_NoDefault_SetsTeamOrg() {
    # Arrange: what az prints on Windows when no organization is set.
    local -r exit_ok=0
    local -r listing='\r\n[defaults]\r\norganization = \r\nproject = \r\n\r\nUse git alias = No\r\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "reads the defaults" contains "$LOG" "devops configure --list"
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
    check "reports it" contains "$OUT" "Set the Azure DevOps default organization to $TEAM_ORG"
}

SetAzDefaultOrg_EmptyListing_SetsTeamOrg() {
    # Arrange
    local -r listing=''
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
}

SetAzDefaultOrg_NoOrganizationLine_SetsTeamOrg() {
    # Arrange
    local -r listing='[defaults]\nproject = P\n\nUse git alias = No\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
}

SetAzDefaultOrg_WhitespaceOnlyValue_SetsTeamOrg() {
    # Arrange
    local -r listing='[defaults]\norganization =\t  \r\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
}

SetAzDefaultOrg_LookalikeKeys_AreNotTheDefault() {
    # Arrange
    local -r listing='[defaults]\norganizations = https://dev.azure.com/x\n# organization = https://dev.azure.com/y\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
}

SetAzDefaultOrg_IndentedOrganizationLine_IsRead() {
    # Arrange
    local -r other="https://dev.azure.com/someone-else"
    local -r listing="[defaults]\n   organization = $other\n"
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "keeps the developer's org" contains "$OUT" "Keeping your Azure DevOps default organization $other"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_SeveralOrganizationLines_FirstWins() {
    # Arrange
    local -r first="https://dev.azure.com/someone-else"
    local -r listing="[defaults]\norganization = $first\n[other]\norganization = $TEAM_ORG\n"
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "keeps the first org" contains "$OUT" "Keeping your Azure DevOps default organization $first"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

# --- an existing default -----------------------------------------------------

SetAzDefaultOrg_SameOrgDifferentCaseAndSlashes_DoesNotConfigure() {
    # Arrange
    local -r exit_ok=0
    local -r listing='[defaults]\r\norganization = https://dev.azure.com/BGVONE// \r\nproject = P\r\n'
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "reads the defaults" contains "$LOG" "devops configure --list"
    check "says it is already set" contains "$OUT" "already"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_ArgumentWithTrailingSlashAndCase_MatchesCurrent() {
    # Arrange
    local -r listing="[defaults]\norganization = $TEAM_ORG\n"
    # Act
    SUT_ORG="https://DEV.azure.com/bgvone/" run_sut STUB_LIST="$listing"
    # Assert
    check "says it is already set" contains "$OUT" "already"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_OtherOrg_KeepsIt() {
    # Arrange
    local -r exit_ok=0
    local -r other="https://dev.azure.com/someone-else"
    local -r listing="[defaults]\norganization = $other\n"
    # Act
    run_sut STUB_LIST="$listing"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "reads the defaults" contains "$LOG" "devops configure --list"
    check "keeps the developer's org" contains "$OUT" "Keeping your Azure DevOps default organization $other"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

# --- az failures -------------------------------------------------------------

SetAzDefaultOrg_ListFails_SkipsAndShowsAzError() {
    # Arrange
    local -r exit_ok=0 rc_failure=1
    local -r az_message="config file is corrupt"
    # Act
    run_sut STUB_LIST_RC="$rc_failure" STUB_STDERR="$az_message"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "reads the defaults" contains "$LOG" "devops configure --list"
    check "warns on stderr" contains "$ERR" "could not read"
    check "shows az's own message" contains "$ERR" "$az_message"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_ListFailsWithOrganizationLine_SkipsWithoutConfiguring() {
    # Arrange
    local -r rc_failure=1
    local -r listing='[defaults]\norganization = \n'
    # Act
    run_sut STUB_LIST="$listing" STUB_LIST_RC="$rc_failure"
    # Assert
    check "warns on stderr" contains "$ERR" "could not read"
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetAzDefaultOrg_SetFails_WarnsOnStderrAndExitsZero() {
    # Arrange
    local -r exit_ok=0 rc_failure=1
    # Act
    run_sut STUB_SET_RC="$rc_failure"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "tries to set the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
    check "warns on stderr" contains "$ERR" "could not set"
    check "tells the developer the command to run" contains "$ERR" "az devops configure --defaults organization=$TEAM_ORG"
    check "does not claim success" not_contains "$OUT" "Set the Azure DevOps default organization"
}

SetAzDefaultOrg_AzWarnsOnStderr_StillSetsTeamOrg() {
    # Arrange
    local -r exit_ok=0
    local -r az_warning="WARNING: telemetry notice"
    # Act
    run_sut STUB_STDERR="$az_warning"
    # Assert
    check "exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
    check "reports success" contains "$OUT" "Set the Azure DevOps default organization to $TEAM_ORG"
}

SetAzDefaultOrg_StdinHasData_AzGetsNone() {
    # Arrange: a "y" waiting on stdin that a prompting az could consume.
    local log="$TEST_TMPDIR/stdin-log"
    : > "$log"
    # Act
    printf 'y\n' | SETUP_ENV_AZ="$STUB" STUB_LOG="$log" bash "$SUT" "$TEAM_ORG" >/dev/null 2>&1
    # Assert
    check "az reads no stdin" not_contains "$(cat "$log")" "stdin=data"
    check "az ran" contains "$(cat "$log")" "stdin=empty"
}

# --- setup-env.sh wiring -------------------------------------------------------

# Runs setup-env.sh against the stub with every home-like variable pointing at
# a fresh temp dir. Sets OUT (stdout+stderr), RC and LOG.
run_setup() {
    local home="$TEST_TMPDIR/home.$RANDOM$RANDOM" log="$TEST_TMPDIR/setup-log.$RANDOM$RANDOM"
    mkdir -p "$home/.claude"
    : > "$log"
    OUT="$(env HOME="$home" USERPROFILE="$home" AZURE_CONFIG_DIR="$home/.azure" \
        GIT_CONFIG_GLOBAL="$home/.gitconfig" SETUP_ENV_AZ="$STUB" STUB_LOG="$log" "$@" \
        bash "$REPO_ROOT/setup-env.sh" 2>&1 </dev/null)"
    RC=$?
    LOG="$(cat "$log")"
}

SetupEnv_NoAzDefault_SetsTeamOrg() {
    # Arrange
    local -r exit_ok=0
    # Act
    run_setup STUB_LIST=''
    # Assert
    check "setup exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "runs the az step" contains "$OUT" "=== Azure DevOps CLI ==="
    check "sets the team org" contains "$LOG" "devops configure --defaults organization=$TEAM_ORG"
}

SetupEnv_AzStepCannotRun_SetupStillCompletes() {
    # Arrange
    local -r exit_ok=0 rc_failure=1
    # Act
    run_setup STUB_EXT_RC="$rc_failure"
    # Assert
    check "setup exits $exit_ok" [ "$RC" -eq "$exit_ok" ]
    check "reports the skip" contains "$OUT" "Could not confirm the azure-devops az extension"
    check "finishes" contains "$OUT" "=== Setup complete ==="
    check "never sets a default" not_contains "$LOG" "--defaults"
}

SetupEnv_TeamOrg_IsTheSameInBothScripts() {
    # Arrange
    local sh_org ps_org
    # Act
    sh_org="$(sed -n 's/^TEAM_ADO_ORG="\(.*\)"$/\1/p' "$REPO_ROOT/setup-env.sh")"
    ps_org="$(sed -n "s/^\\\$TeamAdoOrg = '\\(.*\\)'.*$/\\1/p" "$REPO_ROOT/setup-env.ps1" | tr -d '\r')"
    # Assert
    check "setup-env.sh names the team org" [ "$sh_org" = "$TEAM_ORG" ]
    check "setup-env.ps1 names the same org" [ "$ps_org" = "$sh_org" ]
}

# --- run ----------------------------------------------------------------------

bash -n "$SUT"
check "set-az-default-org.sh parses as valid bash" [ $? -eq 0 ]

for test_name in $(declare -F | awk '{ print $3 }' | grep -E '^(SetAzDefaultOrg|SetupEnv)_'); do
    echo "$test_name"
    "$test_name"
    tests_run=$((tests_run + 1))
done

if [ "$tests_run" -eq 0 ]; then
    fail_check "no test functions were found"
fi

echo ""
echo "Ran: $tests_run  Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
