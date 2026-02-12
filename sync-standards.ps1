<#
.SYNOPSIS
    Syncs team coding standards into ~/.claude/CLAUDE.md.

.DESCRIPTION
    Reads standards/CLAUDE.md from this repository and upserts a managed section
    into the user's ~/.claude/CLAUDE.md, preserving any personal content outside
    the markers.
#>

$ErrorActionPreference = 'Stop'

$StartMarker = '<!-- TEAM-STANDARDS:tzander-skills:START -->'
$EndMarker = '<!-- TEAM-STANDARDS:tzander-skills:END -->'

# Resolve paths
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StandardsFile = Join-Path $RepoRoot 'standards' 'CLAUDE.md'
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
