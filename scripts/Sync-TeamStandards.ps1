# Splices the team standards into the developer's CLAUDE.md, between the
# TEAM-STANDARDS START and END markers. Dot-sourced by setup-env.ps1 and by
# scripts/test-sync-teamstandards.ps1.
#
# Everything outside the marked block belongs to the developer and is kept
# byte for byte. The function throws (file untouched) unless the target holds
# exactly one START and one END marker line, START first. Before replacing an
# existing file it saves the previous version to <target>.team-sync.bak.
#
# The standards text is inserted with plain string concatenation, never as a
# regex replacement, so '$_', '$&' and '$$' in the standards stay literal.

function Sync-TeamStandards {
    param(
        [Parameter(Mandatory = $true)] [string] $TargetFile,
        [Parameter(Mandatory = $true)] [string] $StandardsFile
    )

    $StartMarker = '<!-- TEAM-STANDARDS:tzander-skills:START -->'
    $EndMarker = '<!-- TEAM-STANDARDS:tzander-skills:END -->'
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # .NET file APIs resolve relative paths against the process directory, not
    # PowerShell's location, so make both paths absolute first.
    $TargetFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetFile)
    $StandardsFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StandardsFile)

    if (-not (Test-Path -LiteralPath $StandardsFile -PathType Leaf)) {
        throw "Standards file not found: $StandardsFile"
    }

    $StandardsContent = ([System.IO.File]::ReadAllText($StandardsFile) -replace "`r", '').TrimEnd("`n")
    $ManagedSection = $StartMarker + "`n" + $StandardsContent + "`n" + $EndMarker

    $TargetDir = Split-Path -Parent $TargetFile
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $TargetFile)) {
        [System.IO.File]::WriteAllText($TargetFile, $ManagedSection + "`n", $Utf8NoBom)
        Write-Host "Created $TargetFile with team standards."
        return
    }

    $ExistingContent = [System.IO.File]::ReadAllText($TargetFile)
    # Each element keeps its own trailing CR, so joining with LF restores the
    # original bytes exactly.
    $Lines = $ExistingContent -split "`n"

    $StartIndexes = @()
    $EndIndexes = @()
    $BadLines = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i].TrimEnd("`r")
        foreach ($Marker in @($StartMarker, $EndMarker)) {
            if ($Line.Contains($Marker)) {
                if ($Line -ne $Marker) {
                    $BadLines += ($i + 1)
                }
                elseif ($Marker -eq $StartMarker) {
                    $StartIndexes += $i
                }
                else {
                    $EndIndexes += $i
                }
            }
        }
    }

    $Remedy = "Nothing was changed. Fix the markers in $TargetFile by hand, or delete the whole " +
        'team-standards block (markers included) to have it re-appended, then re-run setup.'

    if ($BadLines.Count -gt 0) {
        throw "A team-standards marker in $TargetFile is not on a line of its own (line $($BadLines -join ', ')). $Remedy"
    }

    if ($StartIndexes.Count -eq 0 -and $EndIndexes.Count -eq 0) {
        # No team block yet: append one after the developer's own content.
        $Separator = ''
        if ($ExistingContent.Length -gt 0) {
            if ($ExistingContent.EndsWith("`n`n")) {
                $Separator = ''
            }
            elseif ($ExistingContent.EndsWith("`n")) {
                $Separator = "`n"
            }
            else {
                $Separator = "`n`n"
            }
        }
        # Append rather than rewrite, so the developer's bytes are never re-written.
        [System.IO.File]::AppendAllText($TargetFile, $Separator + $ManagedSection + "`n", $Utf8NoBom)
        Write-Host "Appended team standards to $TargetFile."
        return
    }

    if ($StartIndexes.Count -ne 1 -or $EndIndexes.Count -ne 1 -or $StartIndexes[0] -ge $EndIndexes[0]) {
        throw ("$TargetFile has $($StartIndexes.Count) START and $($EndIndexes.Count) END team-standards " +
            "marker(s); expected exactly one of each, START first. $Remedy")
    }

    $StartIndex = $StartIndexes[0]
    $EndIndex = $EndIndexes[0]

    $OldLines = @()
    for ($i = $StartIndex + 1; $i -lt $EndIndex; $i++) {
        $OldLines += $Lines[$i].TrimEnd("`r")
    }
    $OldSection = ($OldLines -join "`n").TrimEnd("`n")

    if ($OldSection -ceq $StandardsContent) {
        Write-Host "Team standards in $TargetFile are already up to date."
        return
    }

    $NewLines = $StandardsContent -split "`n"
    $Diff = Compare-Object -ReferenceObject @($OldSection -split "`n") -DifferenceObject $NewLines -CaseSensitive
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

    $Builder = New-Object System.Text.StringBuilder
    if ($StartIndex -gt 0) {
        [void]$Builder.Append(($Lines[0..($StartIndex - 1)] -join "`n"))
        [void]$Builder.Append("`n")
    }
    [void]$Builder.Append($ManagedSection)
    if ($EndIndex -lt $Lines.Count - 1) {
        [void]$Builder.Append("`n")
        [void]$Builder.Append(($Lines[($EndIndex + 1)..($Lines.Count - 1)] -join "`n"))
    }
    else {
        [void]$Builder.Append("`n")
    }

    # Stage next to the target, then swap it in with File.Replace, which also
    # writes the backup of the previous version.
    $StagedFile = Join-Path $TargetDir ('.claude-md-sync.' + [guid]::NewGuid().ToString('N'))
    $BackupFile = "$TargetFile.team-sync.bak"
    try {
        [System.IO.File]::WriteAllText($StagedFile, $Builder.ToString(), $Utf8NoBom)
        [System.IO.File]::Replace($StagedFile, $TargetFile, $BackupFile)
    }
    finally {
        if (Test-Path -LiteralPath $StagedFile) {
            Remove-Item -LiteralPath $StagedFile -Force
        }
    }
    Write-Host "Updated team standards in $TargetFile (previous version saved to $BackupFile)."
}
