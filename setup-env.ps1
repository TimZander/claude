<#
.SYNOPSIS
    Bootstraps the developer's local environment.

.DESCRIPTION
    1. Installs global git hooks via core.hooksPath
    2. Syncs team standards into ~/.claude/CLAUDE.md

    Safe to re-run — updates in place without duplication.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

###############################################################################
# 1. Global git hooks
###############################################################################

$HooksDir = Join-Path $HOME '.git-hooks'
$HooksManifest = Join-Path (Join-Path $RepoRoot 'hooks') 'hooks.json'

Write-Host '=== Git Hooks ==='

if (-not (Test-Path $HooksManifest)) {
    Write-Warning "Hooks manifest not found: $HooksManifest"
}
else {
    if (-not (Test-Path $HooksDir)) {
        New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null
    }

    $Manifest = Get-Content -Path $HooksManifest -Raw | ConvertFrom-Json

    foreach ($Hook in $Manifest.hooks) {
        # Skip disabled hooks (enabled defaults to true)
        if ($null -ne $Hook.enabled -and $Hook.enabled -eq $false) {
            continue
        }

        $SourcePath = Join-Path (Join-Path $RepoRoot 'hooks') $Hook.source
        $TargetPath = Join-Path $HooksDir $Hook.name

        if (-not (Test-Path $SourcePath)) {
            Write-Warning "Hook source not found: $SourcePath"
            continue
        }

        $SourceContent = Get-Content -Path $SourcePath -Raw
        $NeedsUpdate = $true
        $Action = 'Installed'

        if (Test-Path $TargetPath) {
            $TargetContent = Get-Content -Path $TargetPath -Raw
            if ($SourceContent -eq $TargetContent) {
                Write-Host "Hook '$($Hook.name)' is already up to date."
                $NeedsUpdate = $false
            }
            else {
                $Action = 'Updated'
            }
        }

        if ($NeedsUpdate) {
            Copy-Item -Path $SourcePath -Destination $TargetPath -Force
            Write-Host "$Action hook '$($Hook.name)'."
        }
    }

    # Set core.hooksPath globally (use forward slashes for git compatibility)
    $CurrentHooksPath = git config --global core.hooksPath 2>$null
    $HooksDirForGit = $HooksDir -replace '\\', '/'
    if ($CurrentHooksPath -eq $HooksDirForGit -or $CurrentHooksPath -eq $HooksDir) {
        Write-Host "Global core.hooksPath already set to $HooksDir"
    }
    else {
        git config --global core.hooksPath $HooksDirForGit
        Write-Host "Set global core.hooksPath to $HooksDir"
    }
}

Write-Host ''

###############################################################################
# 2. Team standards sync
###############################################################################

Write-Host '=== Team Standards ==='

$StandardsFile = Join-Path (Join-Path $RepoRoot 'standards') 'CLAUDE.md'
$ClaudeDir = Join-Path $HOME '.claude'
$TargetFile = Join-Path $ClaudeDir 'CLAUDE.md'
$StandardsFailed = $false

if (-not (Test-Path $ClaudeDir)) {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
}

if (-not (Test-Path $StandardsFile)) {
    Write-Warning "Standards file not found: $StandardsFile"
}
else {
    # The splice lives in its own script so it can be tested in isolation
    # (scripts/test-sync-teamstandards.ps1). When it refuses (damaged
    # markers), the settings sync below is independent, so carry on and fail
    # at the end.
    . (Join-Path (Join-Path $RepoRoot 'scripts') 'Sync-TeamStandards.ps1')
    try {
        Sync-TeamStandards -TargetFile $TargetFile -StandardsFile $StandardsFile
    }
    catch {
        $StandardsFailed = $true
        Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Team standards were not synced; continuing with the remaining steps.' -ForegroundColor Red
    }
}

Write-Host ''

###############################################################################
# 3. Team settings sync
###############################################################################

Write-Host '=== Team Settings ==='

$SettingsSource = Join-Path (Join-Path $RepoRoot 'standards') 'settings.json'
$SettingsTarget = Join-Path $ClaudeDir 'settings.json'

if (-not (Test-Path $SettingsSource)) {
    Write-Host "No standards/settings.json found - skipping settings sync."
}
else {
    $TeamSettings = Get-Content -Path $SettingsSource -Raw | ConvertFrom-Json

    if (-not (Test-Path $SettingsTarget)) {
        Copy-Item -Path $SettingsSource -Destination $SettingsTarget
        Write-Host "Created $SettingsTarget with team settings."
    }
    else {
        # Merge-JsonObjects lives in its own dot-sourceable script so it can be
        # unit-tested in isolation (scripts/test-merge-jsonobjects.ps1). See #201.
        . (Join-Path (Join-Path $RepoRoot 'scripts') 'Merge-JsonObjects.ps1')
        $ExistingSettings = Get-Content -Path $SettingsTarget -Raw | ConvertFrom-Json
        $Merged = Merge-JsonObjects -Base $TeamSettings -Override $ExistingSettings
        $MergedJson = $Merged | ConvertTo-Json -Depth 10

        $ExistingJson = Get-Content -Path $SettingsTarget -Raw
        if ($MergedJson.Trim() -eq $ExistingJson.Trim()) {
            Write-Host "Settings in $SettingsTarget are already up to date."
        }
        else {
            Set-Content -Path $SettingsTarget -Value $MergedJson -NoNewline -Encoding utf8
            Write-Host "Merged team settings into $SettingsTarget."
        }
    }
}

Write-Host ''
if ($StandardsFailed) {
    Write-Host '=== Setup finished with errors: team standards were not synced (see above) ===' -ForegroundColor Red
    exit 1
}
Write-Host '=== Setup complete ==='
