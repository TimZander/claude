# Unit tests for scripts/Set-AzDevOpsDefaultOrg.ps1, the step setup-env.ps1
# runs to set the Azure DevOps CLI default organization, plus tests of the
# setup-env.ps1 wiring. az is replaced by a stub script (SETUP_ENV_AZ, or a
# stub named az.ps1 alone on PATH) that logs its arguments, so the real Azure
# CLI and its config are never touched. Runs on Windows PowerShell 5.1 and
# PowerShell 7. In CI (CI=true) a skipped test counts as a failure.
#
# scripts/test_set-az-default-org.sh holds the same cases for the bash twin;
# keep the two suites in step. The bash suite also covers two cases this one
# cannot: stdin closed for az (the in-process stub cannot observe native
# stdin) and the team org being equal in both setup-env scripts.
#
# Run: pwsh scripts/test-set-azdevopsdefaultorg.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Set-AzDevOpsDefaultOrg.ps1')
$RepoRoot = Split-Path $PSScriptRoot -Parent
$TeamOrg = 'https://dev.azure.com/bgvone'

$script:fail = 0
$script:pass = 0
$script:skip = 0
$script:testsRun = 0

# --- helpers -----------------------------------------------------------------

function Chk($cond, $d) {
    if ($cond) { Write-Host "  ok: $d"; $script:pass++ } else { Write-Host "  FAIL: $d"; $script:fail++ }
}
function Skip-Test($why) {
    if ($env:CI -eq 'true') { Write-Host "  FAIL (skipped in CI): $why"; $script:fail++; return }
    Write-Host "  SKIP: $why"; $script:skip++
}

$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('az-org-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null

# The stub answers `extension show`, `devops configure --list` and
# `devops configure --defaults` from STUB_* variables, logs every call, and
# writes STUB_STDERR to the error stream (stderr's in-process twin).
$StubSource = @'
Add-Content -LiteralPath $env:STUB_LOG -Value ($args -join ' ')
if ($env:STUB_STDERR) { Write-Error $env:STUB_STDERR }
if ($args[0] -eq 'extension') { exit [int]$env:STUB_EXT_RC }
if ($args[0] -eq 'devops' -and $args[2] -eq '--list') {
    if ($env:STUB_LIST) { $env:STUB_LIST -split "`n" }
    exit [int]$env:STUB_LIST_RC
}
if ($args[0] -eq 'devops') { exit [int]$env:STUB_SET_RC }
exit 99
'@
$Stub = Join-Path $Root 'az-stub.ps1'
Set-Content -LiteralPath $Stub -Encoding ascii -Value $StubSource
$StubDir = Join-Path $Root 'bin'
New-Item -ItemType Directory -Path $StubDir | Out-Null
Set-Content -LiteralPath (Join-Path $StubDir 'az.ps1') -Encoding ascii -Value $StubSource

$StubVars = 'SETUP_ENV_AZ', 'STUB_LOG', 'STUB_EXT_RC', 'STUB_LIST', 'STUB_LIST_RC', 'STUB_SET_RC', 'STUB_STDERR', 'PATH'

# Runs the function with the given environment (SETUP_ENV_AZ defaults to the
# stub) and organization; sets Out (host output), Warn (warnings), Err (an
# exception, or $null) and Log (the stub's calls).
function Invoke-Sut([hashtable] $stubEnv = @{}, [string] $organization = $TeamOrg) {
    $log = Join-Path $Root ('log-' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $log -Value '' -Encoding ascii
    $saved = @{}
    foreach ($name in $StubVars) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $script:Err = $null
    $records = @()
    try {
        $env:SETUP_ENV_AZ = $Stub
        $env:STUB_LOG = $log
        foreach ($name in $stubEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $stubEnv[$name]) }
        $records = @(Set-AzDevOpsDefaultOrg -Organization $organization 3>&1 6>&1)
    }
    catch {
        $script:Err = $_
    }
    finally {
        foreach ($name in $StubVars) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $script:Out = ($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] } |
        ForEach-Object { "$_" }) -join "`n"
    $script:Warn = ($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
        ForEach-Object { $_.Message }) -join "`n"
    $script:Log = Get-Content -LiteralPath $log -Raw
    if ($null -eq $script:Log) { $script:Log = '' }
    if ($null -eq $script:Out) { $script:Out = '' }
    if ($null -eq $script:Warn) { $script:Warn = '' }
}

# --- usage -------------------------------------------------------------------

function SetAzDevOpsDefaultOrg_EmptyOrganization_Throws {
    # Arrange
    $empty = ''
    # Act
    Invoke-Sut @{} $empty
    # Assert
    Chk ($null -ne $Err) 'an empty organization is refused'
    Chk ($Log -notmatch 'extension show') 'az is never run'
}

# --- finding az --------------------------------------------------------------

function SetAzDevOpsDefaultOrg_AzMissing_SkipsWithoutError {
    # Arrange
    $missing = Join-Path $Root 'no-such-az'
    # Act
    Invoke-Sut @{ SETUP_ENV_AZ = $missing }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out -match 'Azure CLI not found') 'says az is missing'
}

function SetAzDevOpsDefaultOrg_AzOverridden_SaysWhichAzRuns {
    # Act
    Invoke-Sut
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out.Contains("Using az from SETUP_ENV_AZ: $Stub")) 'names the override'
}

function SetAzDevOpsDefaultOrg_NoOverride_RunsAzFromPath {
    # Arrange: SETUP_ENV_AZ unset and PATH holding only the stub named az.ps1,
    # so no real az can be found.
    $stubEnv = @{ SETUP_ENV_AZ = $null; PATH = $StubDir }
    # Act
    Invoke-Sut $stubEnv
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains('extension show --name azure-devops')) 'runs the az found on PATH'
    Chk (-not $Out.Contains('SETUP_ENV_AZ')) 'does not claim an override'
}

# --- the extension -----------------------------------------------------------

function SetAzDevOpsDefaultOrg_ExtensionMissing_SkipsWithoutConfiguring {
    # Arrange
    $rcFailure = '1'
    $azMessage = "extension 'azure-devops' is not installed"
    # Act
    Invoke-Sut @{ STUB_EXT_RC = $rcFailure; STUB_STDERR = $azMessage }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains('extension show --name azure-devops')) 'checks the extension'
    Chk ($Out.Contains('az extension add --name azure-devops')) 'names the install command'
    Chk ($Out.Contains($azMessage)) "shows az's own message"
    Chk ($Log -notmatch 'devops configure') 'never runs devops configure'
}

# --- reading the current default ---------------------------------------------

function SetAzDevOpsDefaultOrg_NoDefault_SetsTeamOrg {
    # Arrange: what az prints on Windows when no organization is set.
    $listing = "`r`n[defaults]`r`norganization = `r`nproject = `r`n`r`nUse git alias = No`r`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains('devops configure --list')) 'reads the defaults'
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
    Chk ($Out.Contains("Set the Azure DevOps default organization to $TeamOrg")) 'reports it'
}

function SetAzDevOpsDefaultOrg_EmptyListing_SetsTeamOrg {
    # Arrange
    $listing = ''
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

function SetAzDevOpsDefaultOrg_NoOrganizationLine_SetsTeamOrg {
    # Arrange
    $listing = "[defaults]`nproject = P`n`nUse git alias = No`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

function SetAzDevOpsDefaultOrg_WhitespaceOnlyValue_SetsTeamOrg {
    # Arrange
    $listing = "[defaults]`norganization =`t  `r`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

function SetAzDevOpsDefaultOrg_LookalikeKeys_AreNotTheDefault {
    # Arrange
    $listing = "[defaults]`norganizations = https://dev.azure.com/x`n# organization = https://dev.azure.com/y`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

function SetAzDevOpsDefaultOrg_IndentedOrganizationLine_IsRead {
    # Arrange
    $other = 'https://dev.azure.com/someone-else'
    $listing = "[defaults]`n   organization = $other`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Out.Contains("Keeping your Azure DevOps default organization $other")) "keeps the developer's org"
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_SeveralOrganizationLines_FirstWins {
    # Arrange
    $first = 'https://dev.azure.com/someone-else'
    $listing = "[defaults]`norganization = $first`n[other]`norganization = $TeamOrg`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Out.Contains("Keeping your Azure DevOps default organization $first")) 'keeps the first org'
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

# --- an existing default -----------------------------------------------------

function SetAzDevOpsDefaultOrg_SameOrgDifferentCaseAndSlashes_DoesNotConfigure {
    # Arrange
    $listing = "[defaults]`r`norganization = https://dev.azure.com/BGVONE// `r`nproject = P`r`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains('devops configure --list')) 'reads the defaults'
    Chk ($Out -match 'already') 'says it is already set'
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_ArgumentWithTrailingSlashAndCase_MatchesCurrent {
    # Arrange
    $listing = "[defaults]`norganization = $TeamOrg`n"
    $organization = 'https://DEV.azure.com/bgvone/'
    # Act
    Invoke-Sut @{ STUB_LIST = $listing } $organization
    # Assert
    Chk ($Out -match 'already') 'says it is already set'
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_OtherOrg_KeepsIt {
    # Arrange
    $other = 'https://dev.azure.com/someone-else'
    $listing = "[defaults]`norganization = $other`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains('devops configure --list')) 'reads the defaults'
    Chk ($Out.Contains("Keeping your Azure DevOps default organization $other")) "keeps the developer's org"
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

# --- az failures -------------------------------------------------------------

function SetAzDevOpsDefaultOrg_ListFails_SkipsAndShowsAzError {
    # Arrange
    $rcFailure = '1'
    $azMessage = 'config file is corrupt'
    # Act
    Invoke-Sut @{ STUB_LIST_RC = $rcFailure; STUB_STDERR = $azMessage }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains('devops configure --list')) 'reads the defaults'
    Chk ($Warn -match 'Could not read') 'warns'
    Chk ($Warn.Contains($azMessage)) "shows az's own message"
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_ListFailsWithOrganizationLine_SkipsWithoutConfiguring {
    # Arrange
    $rcFailure = '1'
    $listing = "[defaults]`norganization = `n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing; STUB_LIST_RC = $rcFailure }
    # Assert
    Chk ($Warn -match 'Could not read') 'warns'
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_SetFails_WarnsWithoutError {
    # Arrange
    $rcFailure = '1'
    # Act
    Invoke-Sut @{ STUB_SET_RC = $rcFailure }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'tries to set the team org'
    Chk ($Warn -match 'Could not set') 'warns'
    Chk ($Warn.Contains("az devops configure --defaults organization=$TeamOrg")) 'tells the developer the command to run'
    Chk (-not $Out.Contains('Set the Azure DevOps default organization')) 'does not claim success'
}

function SetAzDevOpsDefaultOrg_AzWarnsOnStderr_StillSetsTeamOrg {
    # Arrange
    $azWarning = 'WARNING: telemetry notice'
    # Act
    Invoke-Sut @{ STUB_STDERR = $azWarning }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
    Chk ($Out.Contains("Set the Azure DevOps default organization to $TeamOrg")) 'reports success'
}

# --- setup-env.ps1 wiring ------------------------------------------------------

# Runs setup-env.ps1 in a child process with every home-like variable pointing
# at a fresh temp dir and az stubbed; sets SetupOut, SetupRc and SetupLog, or
# returns $false when the child does not see the temp home.
function Invoke-Setup([hashtable] $stubEnv = @{}) {
    $fakeHome = Join-Path $Root ('home-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') | Out-Null
    $log = Join-Path $Root ('setup-log-' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $log -Value '' -Encoding ascii
    $exe = (Get-Process -Id $PID).Path
    $names = @('HOME', 'USERPROFILE', 'AZURE_CONFIG_DIR', 'GIT_CONFIG_GLOBAL', 'SETUP_ENV_AZ', 'STUB_LOG') + @($stubEnv.Keys)
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:HOME = $fakeHome
        $env:USERPROFILE = $fakeHome
        $env:AZURE_CONFIG_DIR = Join-Path $fakeHome '.azure'
        $env:GIT_CONFIG_GLOBAL = Join-Path $fakeHome '.gitconfig'
        $env:SETUP_ENV_AZ = $Stub
        $env:STUB_LOG = $log
        foreach ($name in $stubEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $stubEnv[$name]) }
        # Guard: never run setup unless the child really sees the temp home.
        $childHome = (& $exe -NoProfile -Command '$HOME' | Out-String).Trim()
        if ($childHome -ne $fakeHome) {
            Skip-Test "child PowerShell does not use the temp home ($childHome)"
            return $false
        }
        $script:SetupOut = (& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'setup-env.ps1') 2>&1 | Out-String)
        $script:SetupRc = $LASTEXITCODE
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $script:SetupLog = Get-Content -LiteralPath $log -Raw
    if ($null -eq $script:SetupLog) { $script:SetupLog = '' }
    return $true
}

function SetupEnv_NoAzDefault_SetsTeamOrg {
    # Arrange
    $exitOk = 0
    # Act
    if (-not (Invoke-Setup)) { return }
    # Assert
    Chk ($SetupRc -eq $exitOk) "setup exits $exitOk"
    Chk ($SetupOut -match '=== Azure DevOps CLI ===') 'runs the az step'
    Chk ($SetupLog.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

function SetupEnv_AzStepCannotRun_SetupStillCompletes {
    # Arrange
    $exitOk = 0
    $rcFailure = '1'
    # Act
    if (-not (Invoke-Setup @{ STUB_EXT_RC = $rcFailure })) { return }
    # Assert
    Chk ($SetupRc -eq $exitOk) "setup exits $exitOk"
    Chk ($SetupOut -match 'Could not confirm the azure-devops az extension') 'reports the skip'
    Chk ($SetupOut -match '=== Setup complete ===') 'finishes'
    Chk ($SetupLog -notmatch '--defaults') 'never sets a default'
}

# --- run ----------------------------------------------------------------------

try {
    foreach ($file in @((Join-Path $PSScriptRoot 'Set-AzDevOpsDefaultOrg.ps1'), (Join-Path $RepoRoot 'setup-env.ps1'))) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref] $tokens, [ref] $errors) | Out-Null
        Chk (@($errors).Count -eq 0) "$(Split-Path $file -Leaf) parses"
    }
    $tests = Get-ChildItem function: |
        Where-Object { $_.Name -match '^(SetAzDevOpsDefaultOrg|SetupEnv)_' } |
        Sort-Object Name
    foreach ($test in $tests) {
        Write-Host $test.Name
        & $test.Name
        $script:testsRun++
    }
    if ($script:testsRun -eq 0) { Chk $false 'test functions were found' }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $Root
}

Write-Host '---'
Write-Host "Ran: $script:testsRun  Passed: $script:pass  Failed: $script:fail  Skipped: $script:skip"
if ($script:fail -gt 0) { exit 1 }
exit 0
