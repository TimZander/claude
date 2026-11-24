# Unit tests for scripts/Set-AzDevOpsDefaultOrg.ps1, the step setup-env.ps1
# runs to set the Azure DevOps CLI default organization, plus one test of the
# setup-env.ps1 wiring. az is replaced by a stub script (SETUP_ENV_AZ) that
# logs its arguments, so the real Azure CLI and its config are never touched.
# Runs on Windows PowerShell 5.1 and PowerShell 7.
#
# scripts/test_set-az-default-org.sh holds the same cases for the bash twin;
# keep the two suites in step.
#
# Run: pwsh scripts/test-set-azdevopsdefaultorg.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Set-AzDevOpsDefaultOrg.ps1')
$RepoRoot = Split-Path $PSScriptRoot -Parent
$TeamOrg = 'https://dev.azure.com/bgvone'

$script:fail = 0
$script:pass = 0
$script:skip = 0

# --- helpers -----------------------------------------------------------------

function Chk($cond, $d) {
    if ($cond) { Write-Host "  ok: $d"; $script:pass++ } else { Write-Host "  FAIL: $d"; $script:fail++ }
}
function Skip-Test($why) { Write-Host "  SKIP: $why"; $script:skip++ }

$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('az-org-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null

# The stub answers `extension show`, `devops configure --list` and
# `devops configure --defaults` from STUB_* variables and logs every call.
$Stub = Join-Path $Root 'az-stub.ps1'
Set-Content -LiteralPath $Stub -Encoding ascii -Value @'
Add-Content -LiteralPath $env:STUB_LOG -Value ($args -join ' ')
if ($args[0] -eq 'extension') { exit [int]$env:STUB_EXT_RC }
if ($args[0] -eq 'devops' -and $args[2] -eq '--list') {
    if ($env:STUB_LIST) { $env:STUB_LIST -split "`n" }
    exit [int]$env:STUB_LIST_RC
}
if ($args[0] -eq 'devops') { exit [int]$env:STUB_SET_RC }
exit 99
'@

$StubVars = 'SETUP_ENV_AZ', 'STUB_LOG', 'STUB_EXT_RC', 'STUB_LIST', 'STUB_LIST_RC', 'STUB_SET_RC'

# Runs the function against the stub with the given STUB_* values; sets Out
# (host and warning output), Err and Log (the stub's calls).
function Invoke-Sut([hashtable] $stubEnv = @{}) {
    $log = Join-Path $Root ('log-' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $log -Value '' -Encoding ascii
    $saved = @{}
    foreach ($name in $StubVars) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $script:Err = $null
    $script:Out = ''
    try {
        $env:SETUP_ENV_AZ = $Stub
        $env:STUB_LOG = $log
        foreach ($name in $stubEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $stubEnv[$name]) }
        $script:Out = (Set-AzDevOpsDefaultOrg -Organization $TeamOrg 3>&1 6>&1 | ForEach-Object { "$_" }) -join "`n"
    }
    catch {
        $script:Err = $_
    }
    finally {
        foreach ($name in $StubVars) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $script:Log = Get-Content -LiteralPath $log -Raw
    if ($null -eq $script:Log) { $script:Log = '' }
}

# --- tests ---------------------------------------------------------------------

function SetAzDevOpsDefaultOrg_AzMissing_SkipsWithoutError {
    # Arrange
    $saved = $env:SETUP_ENV_AZ
    # Act
    try {
        $env:SETUP_ENV_AZ = Join-Path $Root 'no-such-az'
        $out = (Set-AzDevOpsDefaultOrg -Organization $TeamOrg 6>&1 | ForEach-Object { "$_" }) -join "`n"
    }
    finally {
        $env:SETUP_ENV_AZ = $saved
    }
    # Assert
    Chk ($out -match 'Azure CLI not found') 'says az is missing'
}

function SetAzDevOpsDefaultOrg_ExtensionMissing_SkipsWithoutConfiguring {
    # Act
    Invoke-Sut @{ STUB_EXT_RC = '1' }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out -match 'az extension add --name azure-devops') 'names the install command'
    Chk ($Log -notmatch 'devops configure') 'never runs devops configure'
}

function SetAzDevOpsDefaultOrg_NoDefault_SetsTeamOrg {
    # Arrange: what az prints on Windows when no organization is set.
    $listing = "`r`n[defaults]`r`norganization = `r`nproject = `r`n`r`nUse git alias = No`r`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
    Chk ($Out.Contains("Set the Azure DevOps default organization to $TeamOrg")) 'reports it'
}

function SetAzDevOpsDefaultOrg_EmptyListing_SetsTeamOrg {
    # Act
    Invoke-Sut @{}
    # Assert
    Chk ($Log.Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

function SetAzDevOpsDefaultOrg_SameOrgDifferentCaseAndSlash_DoesNotConfigure {
    # Arrange
    $listing = "[defaults]`r`norganization = https://dev.azure.com/BGVONE/ `r`nproject = P`r`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out -match 'already') 'says it is already set'
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_OtherOrg_KeepsIt {
    # Arrange
    $listing = "[defaults]`norganization = https://dev.azure.com/someone-else`n"
    # Act
    Invoke-Sut @{ STUB_LIST = $listing }
    # Assert
    Chk ($Out.Contains('Keeping your Azure DevOps default organization https://dev.azure.com/someone-else')) "keeps the developer's org"
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_ListFails_SkipsWithoutConfiguring {
    # Act
    Invoke-Sut @{ STUB_LIST_RC = '1' }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out -match 'Could not read') 'warns'
    Chk ($Log -notmatch '--defaults') 'never sets a default'
}

function SetAzDevOpsDefaultOrg_SetFails_WarnsWithoutError {
    # Act
    Invoke-Sut @{ STUB_SET_RC = '1' }
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out.Contains("az devops configure --defaults organization=$TeamOrg")) 'tells the developer the command to run'
}

# --- setup-env.ps1 wiring ------------------------------------------------------

function SetupEnv_NoAzDefault_SetsTeamOrg {
    # Arrange: run setup-env.ps1 in a child process whose home is a temp dir.
    $fakeHome = Join-Path $Root 'setup-home'
    New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') | Out-Null
    $log = Join-Path $Root 'setup-log'
    Set-Content -LiteralPath $log -Value '' -Encoding ascii
    $exe = (Get-Process -Id $PID).Path
    $names = 'HOME', 'USERPROFILE', 'GIT_CONFIG_GLOBAL', 'SETUP_ENV_AZ', 'STUB_LOG'
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:HOME = $fakeHome
        $env:USERPROFILE = $fakeHome
        $env:GIT_CONFIG_GLOBAL = Join-Path $fakeHome '.gitconfig'
        $env:SETUP_ENV_AZ = $Stub
        $env:STUB_LOG = $log
        # Guard: never run setup unless the child really sees the temp home.
        $childHome = (& $exe -NoProfile -Command '$HOME' | Out-String).Trim()
        if ($childHome -ne $fakeHome) {
            Skip-Test "child PowerShell does not use the temp home ($childHome)"
            return
        }
        # Act
        $out = (& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'setup-env.ps1') 2>&1 | Out-String)
        $rc = $LASTEXITCODE
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    # Assert
    Chk ($rc -eq 0) 'setup exits 0'
    Chk ($out -match '=== Azure DevOps CLI ===') 'runs the az step'
    Chk ((Get-Content -LiteralPath $log -Raw).Contains("devops configure --defaults organization=$TeamOrg")) 'sets the team org'
}

# --- run ----------------------------------------------------------------------

try {
    $tests = Get-ChildItem function: |
        Where-Object { $_.Name -match '^(SetAzDevOpsDefaultOrg|SetupEnv)_' } |
        Sort-Object Name
    foreach ($test in $tests) {
        Write-Host $test.Name
        & $test.Name
    }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $Root
}

Write-Host '---'
Write-Host "Passed: $script:pass  Failed: $script:fail  Skipped: $script:skip"
if ($script:fail -gt 0) { exit 1 }
exit 0
