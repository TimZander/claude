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
$HooksManifest = Join-Path $RepoRoot 'hooks' 'hooks.json'

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

        $SourcePath = Join-Path $RepoRoot 'hooks' $Hook.source
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

$StartMarker = '<!-- TEAM-STANDARDS:tzander-skills:START -->'
$EndMarker = '<!-- TEAM-STANDARDS:tzander-skills:END -->'

$StandardsFile = Join-Path (Join-Path $RepoRoot 'standards') 'CLAUDE.md'
$ClaudeDir = Join-Path $HOME '.claude'
$TargetFile = Join-Path $ClaudeDir 'CLAUDE.md'

if (-not (Test-Path $StandardsFile)) {
    Write-Warning "Standards file not found: $StandardsFile"
}
else {
    $StandardsContent = Get-Content -Path $StandardsFile -Raw

    $ManagedSection = @"
$StartMarker
$StandardsContent
$EndMarker
"@

    if (-not (Test-Path $ClaudeDir)) {
        New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
    }

    if (-not (Test-Path $TargetFile)) {
        Set-Content -Path $TargetFile -Value $ManagedSection -NoNewline
        Write-Host "Created $TargetFile with team standards."
    }
    else {
        $ExistingContent = Get-Content -Path $TargetFile -Raw

        if ($ExistingContent -match [regex]::Escape($StartMarker)) {
            $Pattern = [regex]::Escape($StartMarker) + '[\s\S]*?' + [regex]::Escape($EndMarker)

            $OldSectionPattern = [regex]::Escape($StartMarker) + '\r?\n([\s\S]*?)\r?\n' + [regex]::Escape($EndMarker)
            $OldSection = [regex]::Match($ExistingContent, $OldSectionPattern).Groups[1].Value

            $UpdatedContent = [regex]::Replace($ExistingContent, $Pattern, $ManagedSection)

            if ($UpdatedContent -eq $ExistingContent) {
                Write-Host "Team standards in $TargetFile are already up to date."
            }
            else {
                $OldLines = $OldSection -split '\r?\n'
                $NewLines = $StandardsContent.TrimEnd() -split '\r?\n'
                $Diff = Compare-Object -ReferenceObject $OldLines -DifferenceObject $NewLines
                if ($Diff) {
                    Write-Host 'Changes:'
                    foreach ($d in $Diff) {
                        if ($d.SideIndicator -eq '=>') {
                            Write-Host "  + $($d.InputObject)"
                        }
                        else {
                            Write-Host "  - $($d.InputObject)"
                        }
                    }
                }

                Set-Content -Path $TargetFile -Value $UpdatedContent -NoNewline
                Write-Host "Updated team standards in $TargetFile."
            }
        }
        else {
            $Separator = "`n`n"
            if ($ExistingContent -and -not $ExistingContent.EndsWith("`n")) {
                $Separator = "`n`n"
            }
            elseif ($ExistingContent -and $ExistingContent.EndsWith("`n`n")) {
                $Separator = ''
            }
            elseif ($ExistingContent -and $ExistingContent.EndsWith("`n")) {
                $Separator = "`n"
            }
            $AppendedContent = $ExistingContent + $Separator + $ManagedSection
            Set-Content -Path $TargetFile -Value $AppendedContent -NoNewline
            Write-Host "Appended team standards to $TargetFile."
        }
    }
}

Write-Host ''
Write-Host '=== Setup complete ==='
