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

###############################################################################
# 3. Team settings sync
###############################################################################

Write-Host '=== Team Settings ==='

$SettingsSource = Join-Path (Join-Path $RepoRoot 'standards') 'settings.json'
$SettingsTarget = Join-Path $ClaudeDir 'settings.json'

function Merge-JsonObjects {
    param(
        [Parameter(Mandatory)] $Base,
        [Parameter(Mandatory)] $Override
    )

    if ($Base -is [System.Management.Automation.PSCustomObject] -and
        $Override -is [System.Management.Automation.PSCustomObject]) {
        $Result = [PSCustomObject]@{}
        $AllKeys = @(($Base.PSObject.Properties.Name + $Override.PSObject.Properties.Name) | Sort-Object -Unique)
        foreach ($Key in $AllKeys) {
            $HasBase = $null -ne ($Base.PSObject.Properties | Where-Object { $_.Name -eq $Key })
            $HasOverride = $null -ne ($Override.PSObject.Properties | Where-Object { $_.Name -eq $Key })
            if ($HasBase -and $HasOverride) {
                $Result | Add-Member -NotePropertyName $Key -NotePropertyValue (
                    Merge-JsonObjects -Base $Base.$Key -Override $Override.$Key
                )
            }
            elseif ($HasOverride) {
                $Result | Add-Member -NotePropertyName $Key -NotePropertyValue $Override.$Key
            }
            else {
                $Result | Add-Member -NotePropertyName $Key -NotePropertyValue $Base.$Key
            }
        }
        return $Result
    }
    elseif ($Base -is [System.Collections.IEnumerable] -and $Base -isnot [string] -and
            $Override -is [System.Collections.IEnumerable] -and $Override -isnot [string]) {
        $Combined = @($Base) + @($Override) | Sort-Object -Unique
        return @($Combined)
    }
    else {
        return $Override
    }
}

if (-not (Test-Path $SettingsSource)) {
    Write-Host "No standards/settings.json found — skipping settings sync."
}
else {
    $TeamSettings = Get-Content -Path $SettingsSource -Raw | ConvertFrom-Json

    if (-not (Test-Path $SettingsTarget)) {
        Copy-Item -Path $SettingsSource -Destination $SettingsTarget
        Write-Host "Created $SettingsTarget with team settings."
    }
    else {
        $ExistingSettings = Get-Content -Path $SettingsTarget -Raw | ConvertFrom-Json
        $Merged = Merge-JsonObjects -Base $TeamSettings -Override $ExistingSettings
        $MergedJson = $Merged | ConvertTo-Json -Depth 10

        $ExistingJson = Get-Content -Path $SettingsTarget -Raw
        if ($MergedJson.Trim() -eq $ExistingJson.Trim()) {
            Write-Host "Settings in $SettingsTarget are already up to date."
        }
        else {
            Set-Content -Path $SettingsTarget -Value $MergedJson -NoNewline
            Write-Host "Merged team settings into $SettingsTarget."
        }
    }
}

Write-Host ''
Write-Host '=== Setup complete ==='
