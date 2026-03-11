<#
.SYNOPSIS
    Syncs team standards into ~/.claude/.

.DESCRIPTION
    1. CLAUDE.md — upserts a managed section (between markers) into
       ~/.claude/CLAUDE.md, preserving personal content outside the markers.
    2. settings.json — deep-merges standards/settings.json into
       ~/.claude/settings.json (arrays are unioned, objects are merged;
       personal entries are never removed).
#>

$ErrorActionPreference = 'Stop'

$StartMarker = '<!-- TEAM-STANDARDS:tzander-skills:START -->'
$EndMarker = '<!-- TEAM-STANDARDS:tzander-skills:END -->'

# Resolve paths
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StandardsFile = Join-Path (Join-Path $RepoRoot 'standards') 'CLAUDE.md'
$ClaudeDir = Join-Path $HOME '.claude'
$TargetFile = Join-Path $ClaudeDir 'CLAUDE.md'

# Read the canonical standards
if (-not (Test-Path $StandardsFile)) {
    Write-Error "Standards file not found: $StandardsFile"
    exit 1
}
$StandardsContent = Get-Content -Path $StandardsFile -Raw

# Build the managed section
$ManagedSection = @"
$StartMarker
$StandardsContent
$EndMarker
"@

# Ensure ~/.claude directory exists
if (-not (Test-Path $ClaudeDir)) {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
}

if (-not (Test-Path $TargetFile)) {
    # No existing file — create it with just the managed section
    Set-Content -Path $TargetFile -Value $ManagedSection -NoNewline
    Write-Host "Created $TargetFile with team standards."
}
else {
    $ExistingContent = Get-Content -Path $TargetFile -Raw

    if ($ExistingContent -match [regex]::Escape($StartMarker)) {
        # Markers exist — replace the managed section in-place
        $Pattern = [regex]::Escape($StartMarker) + '[\s\S]*?' + [regex]::Escape($EndMarker)
        $UpdatedContent = [regex]::Replace($ExistingContent, $Pattern, $ManagedSection)

        if ($UpdatedContent -eq $ExistingContent) {
            Write-Host "Team standards in $TargetFile are already up to date."
        }
        else {
            Set-Content -Path $TargetFile -Value $UpdatedContent -NoNewline
            Write-Host "Updated team standards in $TargetFile."
        }
    }
    else {
        # No markers — append the managed section
        $Separator = "`n`n"
        if ($ExistingContent -and -not $ExistingContent.EndsWith("`n")) {
            $Separator = "`n`n"
        }
        elseif ($ExistingContent -and $ExistingContent.EndsWith("`n`n")) {
            $Separator = ""
        }
        elseif ($ExistingContent -and $ExistingContent.EndsWith("`n")) {
            $Separator = "`n"
        }
        $AppendedContent = $ExistingContent + $Separator + $ManagedSection
        Set-Content -Path $TargetFile -Value $AppendedContent -NoNewline
        Write-Host "Appended team standards to $TargetFile."
    }
}

# ── settings.json sync ──────────────────────────────────────────────────────

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
        # Union arrays and deduplicate
        $Combined = @($Base) + @($Override) | Sort-Object -Unique
        return @($Combined)
    }
    else {
        # Scalar: override wins
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
