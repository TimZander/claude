# Unit tests for scripts/Sync-TeamStandards.ps1, the team-standards splice that
# setup-env.ps1 runs against ~/.claude/CLAUDE.md, plus one test of how
# setup-env.ps1 reacts when the splice refuses. Every test works in its own
# temp directory; nothing under the real home directory is touched. Runs on
# Windows PowerShell 5.1 and PowerShell 7.
#
# scripts/test_sync-standards.sh holds the same cases for the bash twin; keep
# the two suites in step. This file is ASCII-only on purpose: Windows
# PowerShell 5.1 reads a BOM-less script as ANSI, so non-ASCII test text is
# built from code points.
#
# Run: pwsh scripts/test-sync-teamstandards.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sync-TeamStandards.ps1')
$RepoRoot = Split-Path $PSScriptRoot -Parent

$Start = '<!-- TEAM-STANDARDS:tzander-skills:START -->'
$End = '<!-- TEAM-STANDARDS:tzander-skills:END -->'
$BomText = [string][char]0xFEFF
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:fail = 0
$script:pass = 0
$script:skip = 0

# --- helpers -----------------------------------------------------------------

function Chk($cond, $d) {
    if ($cond) { Write-Host "  ok: $d"; $script:pass++ } else { Write-Host "  FAIL: $d"; $script:fail++ }
}
function Skip-Test($why) { Write-Host "  SKIP: $why"; $script:skip++ }

$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-std-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null

# Fresh case directory; sets Case, Target and Standards and writes the
# standards file with the given text plus a final newline.
function New-Case($name, $standards) {
    $script:Case = Join-Path $Root $name
    New-Item -ItemType Directory -Path $script:Case | Out-Null
    $script:Target = Join-Path $script:Case 'CLAUDE.md'
    $script:Standards = Join-Path $script:Case 'standards.md'
    [System.IO.File]::WriteAllText($script:Standards, $standards + "`n", $Utf8NoBom)
}
function Set-Text($path, $text) { [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
# Reads raw bytes as UTF-8 so a BOM shows up as U+FEFF instead of vanishing.
function Get-Raw($path) { return $Utf8NoBom.GetString([System.IO.File]::ReadAllBytes($path)) }
function Get-Bytes($path) { return [System.IO.File]::ReadAllBytes($path) }
function Test-SameBytes($a, $b) { return [Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b) }

# Runs the sync; sets Out (host output, one record per line) and Err.
function Invoke-Sync {
    $script:Err = $null
    $script:Out = ''
    try {
        # Join records by hand: Out-String wraps long lines at the console width,
        # which splits messages that carry long temp paths.
        $script:Out = (Sync-TeamStandards -TargetFile $script:Target -StandardsFile $script:Standards 6>&1 |
            ForEach-Object { "$_" }) -join "`n"
    }
    catch {
        $script:Err = $_.Exception.Message
    }
}

# Asserts a refusal: an error that says nothing changed, identical bytes, no backup.
function Assert-Refused($label, $before) {
    Chk ($null -ne $script:Err) "${label}: throws"
    Chk ($script:Err -match 'Nothing was changed') "${label}: says nothing was changed"
    Chk (Test-SameBytes (Get-Bytes $script:Target) $before) "${label}: target unchanged"
    Chk (-not (Test-Path -LiteralPath "$($script:Target).team-sync.bak")) "${label}: no backup written"
}

# --- argument handling -------------------------------------------------------

function SyncTeamStandards_MissingStandardsFile_Throws {
    # Arrange
    New-Case 'missing-standards' 'rule one'
    Remove-Item -LiteralPath $Standards
    # Act
    Invoke-Sync
    # Assert
    Chk ($Err -match 'Standards file not found') 'names the missing file'
    Chk (-not (Test-Path -LiteralPath $Target)) 'creates no target'
}

function SyncTeamStandards_StandardsContainMarker_RefusesWithoutWriting {
    # Arrange
    New-Case 'standards-marker' "rule one`n$End"
    Set-Text $Target "mine`n$Start`nold`n$End`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'marker in standards' $before
}

# --- create and append -------------------------------------------------------

function SyncTeamStandards_MissingTargetAndDirectory_CreatesFileWithBlock {
    # Arrange
    New-Case 'create' 'rule one'
    $script:Target = Join-Path (Join-Path (Join-Path $Case 'nested') 'dir') 'CLAUDE.md'
    # Act
    Invoke-Sync
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ((Get-Raw $Target) -ceq "$Start`nrule one`n$End`n") 'file is exactly the block'
}

function SyncTeamStandards_EmptyTarget_AppendsBlockWithoutSeparator {
    # Arrange
    New-Case 'append-empty' 'rule one'
    Set-Text $Target ''
    # Act
    Invoke-Sync
    # Assert
    Chk ($Out -match 'Appended') 'reports append'
    Chk ((Get-Raw $Target) -ceq "$Start`nrule one`n$End`n") 'file is exactly the block'
}

function SyncTeamStandards_TargetWithoutFinalNewline_AppendsAfterOneBlankLine {
    # Arrange
    New-Case 'append-no-newline' 'rule one'
    Set-Text $Target 'mine'
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n`n$Start`nrule one`n$End`n") 'file is exact'
}

function SyncTeamStandards_TargetEndingInNewline_AppendsAfterOneBlankLine {
    # Arrange
    New-Case 'append-newline' 'rule one'
    Set-Text $Target "mine`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n`n$Start`nrule one`n$End`n") 'file is exact'
}

function SyncTeamStandards_TargetEndingInBlankLine_AppendsWithoutExtraBlankLine {
    # Arrange
    New-Case 'append-blank' 'rule one'
    Set-Text $Target "mine`n`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n`n$Start`nrule one`n$End`n") 'file is exact'
}

# --- update ------------------------------------------------------------------

# Regression: the bash sync used to drop every line above START on a re-run.
function SyncTeamStandards_PersonalNotesAboveBlock_KeptAcrossReruns {
    # Arrange
    New-Case 'personal-above' 'rule one'
    Set-Text $Target "# My notes`nkeep me`n"
    Invoke-Sync
    Set-Text $Standards "rule two`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ($Out -match 'Updated') 'reports update'
    Chk ((Get-Raw $Target) -ceq "# My notes`nkeep me`n`n$Start`nrule two`n$End`n") 'file is exact'
    # Act again
    Invoke-Sync
    # Assert again
    Chk ($Out -match 'already up to date') 'third run is a no-op'
}

function SyncTeamStandards_ContentAfterEndWithoutFinalNewline_KeptExactly {
    # Arrange
    New-Case 'personal-below' 'rule two'
    Set-Text $Target "top`n$Start`nrule one`n$End`nbottom note"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "top`n$Start`nrule two`n$End`nbottom note") 'file is exact, no newline added'
}

function SyncTeamStandards_StartFirstAndEndLastWithoutNewline_UpdatesBlock {
    # Arrange
    New-Case 'whole-file' 'rule two'
    Set-Text $Target "$Start`nrule one`n$End"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "$Start`nrule two`n$End`n") 'file is exactly the new block'
}

function SyncTeamStandards_EmptyBlock_FillsBlock {
    # Arrange
    New-Case 'empty-block' 'rule one'
    Set-Text $Target "mine`n$Start`n$End`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n$Start`nrule one`n$End`n") 'file is exact'
}

function SyncTeamStandards_UnchangedStandards_WritesNothing {
    # Arrange
    New-Case 'noop' 'rule one'
    Set-Text $Target "mine`n`n$Start`nrule one`n$End`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Chk ($Out -match 'already up to date') 'reports up to date'
    Chk (Test-SameBytes (Get-Bytes $Target) $before) 'file bytes unchanged'
    Chk (-not (Test-Path -LiteralPath "$Target.team-sync.bak")) 'no backup written'
}

function SyncTeamStandards_OldPowerShellBlockFormat_IsNoOp {
    # Arrange: the old PowerShell sync left a blank line before END.
    New-Case 'old-ps-format' 'rule one'
    Set-Text $Target "mine`n$Start`nrule one`n`n$End"
    # Act
    Invoke-Sync
    # Assert
    Chk ($Out -match 'already up to date') 'trailing blank line in the old block is not a change'
}

function SyncTeamStandards_Update_BacksUpPreviousFileOverwritingOldBackup {
    # Arrange
    New-Case 'backup' 'rule two'
    Set-Text $Target "mine`n$Start`nrule one`n$End`n"
    $before = Get-Bytes $Target
    Set-Text "$Target.team-sync.bak" "stale backup`n"
    # Act
    Invoke-Sync
    # Assert
    Chk (Test-SameBytes (Get-Bytes "$Target.team-sync.bak") $before) 'backup matches the previous file'
    Chk ($Out -match 'team-sync\.bak') 'reports the backup path'
}

function SyncTeamStandards_Update_PrintsChangePreview {
    # Arrange
    New-Case 'preview' 'rule two'
    Set-Text $Target "$Start`nrule one`n$End`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ($Out.Contains('  - rule one')) 'shows the removed line'
    Chk ($Out.Contains('  + rule two')) 'shows the added line'
}

function SyncTeamStandards_SymlinkedTarget_UpdatesLinkTargetAndKeepsLink {
    # Arrange
    New-Case 'symlink' 'rule two'
    $real = Join-Path $Case 'real.md'
    Set-Text $real "mine`n$Start`nrule one`n$End`n"
    try {
        New-Item -ItemType SymbolicLink -Path $Target -Target $real -ErrorAction Stop | Out-Null
    }
    catch {
        Skip-Test 'symlinks cannot be created here'
        return
    }
    # Act
    Invoke-Sync
    # Assert
    $item = Get-Item -LiteralPath $Target -Force
    Chk ($null -ne $item.LinkType) 'target is still a symlink'
    Chk ((Get-Raw $real) -ceq "mine`n$Start`nrule two`n$End`n") 'linked file got the update'
}

# --- refusals ------------------------------------------------------------------

function SyncTeamStandards_MissingEnd_RefusesWithoutWriting {
    # Arrange
    New-Case 'missing-end' 'rule two'
    Set-Text $Target "mine`n$Start`nrule one`nafter`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'missing END' $before
}

function SyncTeamStandards_MissingStart_RefusesWithoutWriting {
    # Arrange
    New-Case 'missing-start' 'rule two'
    Set-Text $Target "mine`nrule one`n$End`nafter`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'missing START' $before
}

function SyncTeamStandards_DuplicateStart_RefusesWithoutWriting {
    # Arrange
    New-Case 'dup-start' 'rule two'
    Set-Text $Target "$Start`nx`n$Start`ny`n$End`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'duplicate START' $before
}

function SyncTeamStandards_DuplicateEnd_RefusesWithoutWriting {
    # Arrange
    New-Case 'dup-end' 'rule two'
    Set-Text $Target "$Start`nx`n$End`ny`n$End`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'duplicate END' $before
}

function SyncTeamStandards_EndBeforeStart_RefusesWithoutWriting {
    # Arrange
    New-Case 'reversed' 'rule two'
    Set-Text $Target "$End`nrule one`n$Start`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'END before START' $before
}

function SyncTeamStandards_StartInsideOtherText_RefusesWithoutWriting {
    # Arrange
    New-Case 'inline-start' 'rule two'
    Set-Text $Target "see $Start here`n$Start`nrule one`n$End`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'inline START' $before
}

function SyncTeamStandards_EndInsideOtherText_RefusesWithoutWriting {
    # Arrange
    New-Case 'inline-end' 'rule two'
    Set-Text $Target "$Start`nrule one`n$End`nsee $End here`n"
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'inline END' $before
}

function SyncTeamStandards_NonUtf8Target_RefusesWithoutWriting {
    $eAcuteCp1252 = 0xE9
    # Arrange: "caf<e-acute> notes" saved as Windows-1252, which is not valid UTF-8.
    New-Case 'non-utf8' 'rule two'
    $ascii = [System.Text.Encoding]::ASCII
    $bytes = $ascii.GetBytes('caf') + [byte]$eAcuteCp1252 + $ascii.GetBytes(" notes`n$Start`nrule one`n$End`n")
    [System.IO.File]::WriteAllBytes($Target, [byte[]]$bytes)
    $before = Get-Bytes $Target
    # Act
    Invoke-Sync
    # Assert
    Assert-Refused 'non-UTF-8 target' $before
    Chk ($Err -match 'not valid UTF-8') 'says the file is not UTF-8'
}

# --- line endings and encodings ----------------------------------------------

function SyncTeamStandards_CrlfTarget_KeepsPersonalCrlfAndRerunIsNoOp {
    # Arrange
    New-Case 'crlf' 'rule two'
    Set-Text $Target "mine`r`n$Start`r`nrule one`r`n$End`r`ntail`r`n"
    # Act
    Invoke-Sync
    # Assert: the team block itself is written with LF.
    Chk ((Get-Raw $Target) -ceq "mine`r`n$Start`nrule two`n$End`ntail`r`n") 'file is exact'
    # Act again
    Invoke-Sync
    # Assert again
    Chk ($Out -match 'already up to date') 're-run is a no-op'
}

function SyncTeamStandards_CrlfStandards_WritesLfBlockAndRerunIsNoOp {
    # Arrange
    New-Case 'crlf-standards' 'unused'
    Set-Text $Standards "rule one`r`nrule two`r`n"
    Set-Text $Target "mine`n"
    # Act
    Invoke-Sync
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n`n$Start`nrule one`nrule two`n$End`n") 'file is exact'
    Chk ($Out -match 'already up to date') 're-run is a no-op'
}

function SyncTeamStandards_StandardsWithTrailingBlankLines_RerunIsNoOp {
    # Arrange
    New-Case 'trailing-blank-standards' 'unused'
    Set-Text $Standards "rule one`n`n`n"
    Set-Text $Target "mine`n"
    # Act
    Invoke-Sync
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n`n$Start`nrule one`n$End`n") 'file is exact'
    Chk ($Out -match 'already up to date') 're-run is a no-op'
}

function SyncTeamStandards_BomBeforeStartOnFirstLine_UpdatesAndKeepsBom {
    # Arrange
    New-Case 'bom-target' 'rule two'
    Set-Text $Target "$BomText$Start`nrule one`n$End`nafter`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ((Get-Raw $Target) -ceq "$BomText$Start`nrule two`n$End`nafter`n") 'file is exact, BOM kept'
}

function SyncTeamStandards_BomInStandards_KeptOutOfBlock {
    # Arrange
    New-Case 'bom-standards' 'unused'
    Set-Text $Standards "${BomText}rule one`n"
    Set-Text $Target "mine`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n`n$Start`nrule one`n$End`n") 'file is exact, no BOM inside the block'
}

function SyncTeamStandards_ReplacementTokensInStandards_WrittenLiterallyWithoutGrowth {
    # Arrange
    New-Case 'tokens' 'cost is $$5 and $& and $_ and $1'
    Set-Text $Target "mine`n$Start`nold`n$End`n"
    # Act
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "mine`n$Start`ncost is `$`$5 and `$& and `$_ and `$1`n$End`n") 'file is exact'
    # Act again
    $first = Get-Bytes $Target
    Invoke-Sync
    # Assert again
    Chk ($Out -match 'already up to date') 're-run is a no-op'
    Chk (Test-SameBytes (Get-Bytes $Target) $first) 'file does not grow'
}

function SyncTeamStandards_NonAsciiText_RoundTripsUnchanged {
    # Arrange
    $rule = 'rule ' + [char]0x2014 + ' with ' + [char]0x201C + 'quotes' + [char]0x201D + ' ' + [char]0x2192
    $note = 'caf' + [char]0x00E9 + ' notes'
    New-Case 'unicode' $rule
    Set-Text $Target "$note`n"
    # Act
    Invoke-Sync
    Invoke-Sync
    # Assert
    Chk ((Get-Raw $Target) -ceq "$note`n`n$Start`n$rule`n$End`n") 'file is exact'
    Chk ($Out -match 'already up to date') 're-run is a no-op'
}

function SyncTeamStandards_RepositoryStandardsFile_SyncsAndRerunIsNoOp {
    # Arrange
    New-Case 'repo-standards' 'unused'
    $script:Standards = Join-Path (Join-Path $RepoRoot 'standards') 'CLAUDE.md'
    Set-Text $Target "mine`n"
    # Act
    Invoke-Sync
    Invoke-Sync
    # Assert
    Chk ($null -eq $Err) 'no error'
    Chk ($Out -match 'already up to date') 'real standards sync cleanly'
}

# --- setup-env.ps1 wiring ------------------------------------------------------

function SetupEnv_DamagedMarkers_SyncsSettingsAndExitsNonZero {
    $exitFailed = 1
    # Arrange: run setup-env.ps1 in a child process whose home is a temp dir.
    $fakeHome = Join-Path $Root 'setup-home'
    $claude = Join-Path $fakeHome '.claude'
    New-Item -ItemType Directory -Path $claude | Out-Null
    $target = Join-Path $claude 'CLAUDE.md'
    Set-Text $target "mine`n$Start`nrule one`n"
    $before = Get-Bytes $target
    $exe = (Get-Process -Id $PID).Path
    $saved = @{ HOME = $env:HOME; USERPROFILE = $env:USERPROFILE; GIT_CONFIG_GLOBAL = $env:GIT_CONFIG_GLOBAL; SETUP_ENV_AZ = $env:SETUP_ENV_AZ }
    try {
        $env:HOME = $fakeHome
        $env:USERPROFILE = $fakeHome
        $env:GIT_CONFIG_GLOBAL = Join-Path $fakeHome '.gitconfig'
        # Names no command, so the az step skips instead of running the real CLI.
        $env:SETUP_ENV_AZ = Join-Path $fakeHome 'no-such-az'
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
        $env:HOME = $saved.HOME
        $env:USERPROFILE = $saved.USERPROFILE
        $env:GIT_CONFIG_GLOBAL = $saved.GIT_CONFIG_GLOBAL
        $env:SETUP_ENV_AZ = $saved.SETUP_ENV_AZ
    }
    # Assert
    Chk ($rc -eq $exitFailed) "setup exits $exitFailed"
    Chk (Test-SameBytes (Get-Bytes $target) $before) 'CLAUDE.md untouched'
    Chk (Test-Path -LiteralPath (Join-Path $claude 'settings.json')) 'settings step still ran'
    Chk ($out -match 'finished with errors') 'reports the failure at the end'
}

# --- run ----------------------------------------------------------------------

try {
    $tests = Get-ChildItem function: |
        Where-Object { $_.Name -match '^(SyncTeamStandards|SetupEnv)_' } |
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
