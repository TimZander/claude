# Splices the team standards into the developer's CLAUDE.md, between the
# TEAM-STANDARDS START and END markers. Dot-sourced by setup-env.ps1 and by
# scripts/test-sync-teamstandards.ps1. The bash twin is scripts/sync-standards.sh,
# and the two must behave the same.
#
# Everything outside the marked block belongs to the developer and is kept
# byte for byte, including a leading UTF-8 BOM and a missing final newline.
# The target must be UTF-8: anything else is refused rather than re-encoded,
# because re-encoding would rewrite the developer's own text. The function
# throws (file untouched) unless the target holds exactly one START and one
# END marker line, START first. Before an update it copies the previous
# version to <target>.team-sync.bak, then rewrites the target in place, so a
# symlinked target keeps its link and the file keeps its permissions.
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
    $Bom = [byte[]](0xEF, 0xBB, 0xBF)
    # Throws on invalid bytes instead of silently substituting U+FFFD.
    $StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

    # .NET file APIs resolve relative paths against the process directory, not
    # PowerShell's location, so make both paths absolute first.
    $TargetFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetFile)
    $StandardsFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StandardsFile)

    if (-not (Test-Path -LiteralPath $StandardsFile -PathType Leaf)) {
        throw "Standards file not found: $StandardsFile"
    }

    $StandardsContent = ([System.IO.File]::ReadAllText($StandardsFile) -replace "`r", '').TrimEnd("`n")

    # A marker inside the standards would be copied into every developer's
    # file, where every later run would refuse it as damage.
    if ($StandardsContent.Contains($StartMarker) -or $StandardsContent.Contains($EndMarker)) {
        throw "$StandardsFile contains a team-standards marker line; it must not. Nothing was changed. Remove the marker text from the standards file."
    }

    $ManagedSection = $StartMarker + "`n" + $StandardsContent + "`n" + $EndMarker

    $TargetDir = Split-Path -Parent $TargetFile
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $TargetFile)) {
        [System.IO.File]::WriteAllBytes($TargetFile, $StrictUtf8.GetBytes($ManagedSection + "`n"))
        Write-Host "Created $TargetFile with team standards."
        return
    }

    $Bytes = [System.IO.File]::ReadAllBytes($TargetFile)
    $HasBom = $Bytes.Length -ge 3 -and $Bytes[0] -eq $Bom[0] -and $Bytes[1] -eq $Bom[1] -and $Bytes[2] -eq $Bom[2]
    $Offset = 0
    if ($HasBom) {
        $Offset = 3
    }
    try {
        $ExistingContent = $StrictUtf8.GetString($Bytes, $Offset, $Bytes.Length - $Offset)
    }
    catch {
        # PowerShell wraps the DecoderFallbackException in a
        # MethodInvocationException, so match on any failure here.
        throw ("$TargetFile is not valid UTF-8, so it cannot be updated without rewriting your own text. " +
            'Nothing was changed. Re-save the file as UTF-8, then re-run setup.')
    }

    # Each element keeps its own trailing CR, so joining with LF restores the
    # original text exactly.
    $Lines = $ExistingContent -split "`n"

    $StartIndexes = @()
    $EndIndexes = @()
    $BadLines = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i].TrimEnd("`r")
        $IsBad = $false
        if ($Line.Contains($StartMarker)) {
            if ($Line -ceq $StartMarker) {
                $StartIndexes += $i
            }
            else {
                $IsBad = $true
            }
        }
        if ($Line.Contains($EndMarker)) {
            if ($Line -ceq $EndMarker) {
                $EndIndexes += $i
            }
            else {
                $IsBad = $true
            }
        }
        if ($IsBad) {
            $BadLines += ($i + 1)
        }
    }

    $Remedy = "Nothing was changed. Fix the markers in $TargetFile by hand, or delete the whole " +
        'team-standards block (markers included) to have it re-appended, then re-run setup.'

    if ($BadLines.Count -gt 0) {
        throw "A team-standards marker in $TargetFile is not on a line of its own (line $($BadLines -join ',')). $Remedy"
    }

    if ($StartIndexes.Count -eq 0 -and $EndIndexes.Count -eq 0) {
        # No team block yet: append one after the developer's own content,
        # separated by exactly one blank line.
        $Separator = ''
        if ($Bytes.Length -gt 0) {
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
        $Stream = [System.IO.File]::Open($TargetFile, [System.IO.FileMode]::Append)
        try {
            $Appended = $StrictUtf8.GetBytes($Separator + $ManagedSection + "`n")
            $Stream.Write($Appended, 0, $Appended.Length)
        }
        finally {
            $Stream.Dispose()
        }
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
    Write-Host 'Changes:'
    foreach ($d in $Diff) {
        if ($d.SideIndicator -eq '=>') {
            Write-Host "  + $($d.InputObject)"
        }
        else {
            Write-Host "  - $($d.InputObject)"
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

    $UpdatedBytes = $StrictUtf8.GetBytes($Builder.ToString())
    if ($HasBom) {
        $UpdatedBytes = $Bom + $UpdatedBytes
    }

    # Back up, then rewrite in place: writing through the existing file keeps a
    # symlink pointing where it did and keeps the file's permissions.
    $BackupFile = "$TargetFile.team-sync.bak"
    [System.IO.File]::Copy($TargetFile, $BackupFile, $true)
    [System.IO.File]::WriteAllBytes($TargetFile, [byte[]]$UpdatedBytes)
    Write-Host "Updated team standards in $TargetFile (previous version saved to $BackupFile)."
}
