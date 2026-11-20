# Smoke test for scripts/Sync-TeamStandards.ps1, the team-standards splice
# that setup-env.ps1 runs against ~/.claude/CLAUDE.md. Every case works on
# temp files; nothing under the real home directory is touched. Runs on
# Windows PowerShell 5.1 and PowerShell 7. Run:
#   pwsh scripts/test-sync-teamstandards.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sync-TeamStandards.ps1')

$Start = '<!-- TEAM-STANDARDS:tzander-skills:START -->'
$End = '<!-- TEAM-STANDARDS:tzander-skills:END -->'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:fail = 0
$script:pass = 0
function Chk($cond, $d) {
    if ($cond) { Write-Host "  ok: $d"; $script:pass++ } else { Write-Host "  FAIL: $d"; $script:fail++ }
}

$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-std-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null

function New-Case($name, $standards) {
    $dir = Join-Path $Root $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:Target = Join-Path $dir 'CLAUDE.md'
    $script:Standards = Join-Path $dir 'standards.md'
    [System.IO.File]::WriteAllText($script:Standards, $standards + "`n", $Utf8NoBom)
    return $dir
}
function Set-Target($text) { [System.IO.File]::WriteAllText($script:Target, $text, $Utf8NoBom) }
function Get-Target { return [System.IO.File]::ReadAllText($script:Target) }

# Runs the sync; returns the host output as one string and the error (if any).
function Invoke-Sync {
    $script:Err = $null
    try {
        # Join records by hand: Out-String wraps long lines at the console width,
        # which splits messages that carry long temp paths.
        $script:Out = (Sync-TeamStandards -TargetFile $script:Target -StandardsFile $script:Standards 6>&1 |
            ForEach-Object { "$_" }) -join "`n"
    }
    catch {
        $script:Out = ''
        $script:Err = $_.Exception.Message
    }
}

try {
    Write-Host '1) creates the file when it is missing'
    New-Case 'create' 'rule one' | Out-Null
    Invoke-Sync
    Chk ($null -eq $Err) 'no error'
    Chk ((Get-Target) -ceq "$Start`nrule one`n$End`n") 'file holds the managed block'

    Write-Host '2) regression: personal notes above the block survive re-runs'
    New-Case 'personal-above' 'rule one' | Out-Null
    Set-Target "# My notes`nkeep me`n"
    Invoke-Sync
    Chk ($Out -match 'Appended') 'first run appends'
    [System.IO.File]::WriteAllText($Standards, "rule two`n", $Utf8NoBom)
    Invoke-Sync
    Chk ($Out -match 'Updated') 'second run updates'
    Chk ((Get-Target) -ceq "# My notes`nkeep me`n`n$Start`nrule two`n$End`n") 'personal content kept, standards replaced'
    Invoke-Sync
    Chk ($Out -match 'already up to date') 'third run is a no-op'

    Write-Host '3) content after the END marker is kept'
    New-Case 'personal-below' 'rule two' | Out-Null
    Set-Target "top`n$Start`nrule one`n$End`nbottom note"
    Invoke-Sync
    Chk ((Get-Target) -ceq "top`n$Start`nrule two`n$End`nbottom note") 'file is exactly top + new block + bottom'

    Write-Host '4) unchanged standards: no write, no backup'
    New-Case 'noop' 'rule one' | Out-Null
    Set-Target "mine`n`n$Start`nrule one`n$End`n"
    $Before = Get-Target
    Invoke-Sync
    Chk ($Out -match 'already up to date') 'reports up to date'
    Chk ((Get-Target) -ceq $Before) 'file unchanged'
    Chk (-not (Test-Path "$Target.team-sync.bak")) 'no backup written'

    Write-Host '5) a section written by the old PowerShell sync (blank line before END) is not churned'
    New-Case 'old-ps-format' 'rule one' | Out-Null
    Set-Target "mine`n$Start`nrule one`n`n$End"
    Invoke-Sync
    Chk ($Out -match 'already up to date') 'trailing blank line in the old block is not a change'

    Write-Host '6) an update leaves a backup of the previous file'
    $Dir = New-Case 'backup' 'rule two'
    Set-Target "mine`n$Start`nrule one`n$End`n"
    $Before = Get-Target
    Invoke-Sync
    Chk ((Test-Path "$Target.team-sync.bak") -and ([System.IO.File]::ReadAllText("$Target.team-sync.bak") -ceq $Before)) 'backup matches the previous file'
    Chk (@(Get-ChildItem -Force -LiteralPath $Dir | Where-Object { $_.Name -like '.claude-md-sync.*' }).Count -eq 0) 'no staging file left behind'

    function Test-Refusal($label) {
        $before = Get-Target
        Invoke-Sync
        Chk ($null -ne $Err) "${label}: throws"
        Chk ($Err -match 'Nothing was changed') "${label}: says nothing was changed"
        Chk ((Get-Target) -ceq $before) "${label}: file unchanged"
        Chk (-not (Test-Path "$Target.team-sync.bak")) "${label}: no backup written"
    }

    Write-Host '7) missing END marker is refused (used to report "up to date" forever)'
    New-Case 'missing-end' 'rule two' | Out-Null
    Set-Target "mine`n$Start`nrule one`nafter`n"
    Test-Refusal 'missing END'

    Write-Host '8) missing START marker is refused'
    New-Case 'missing-start' 'rule two' | Out-Null
    Set-Target "mine`nrule one`n$End`n"
    Test-Refusal 'missing START'

    Write-Host '9) duplicate START marker is refused'
    New-Case 'dup-start' 'rule two' | Out-Null
    Set-Target "$Start`nx`n$Start`ny`n$End`n"
    Test-Refusal 'duplicate START'

    Write-Host '10) END before START is refused'
    New-Case 'reversed' 'rule two' | Out-Null
    Set-Target "$End`nrule one`n$Start`n"
    Test-Refusal 'END before START'

    Write-Host '11) a marker inside other text is refused'
    New-Case 'inline' 'rule two' | Out-Null
    Set-Target "see $Start here`n$Start`nrule one`n$End`n"
    Test-Refusal 'inline marker'

    Write-Host '12) CRLF file: markers found, personal CRLF lines kept'
    New-Case 'crlf' 'rule two' | Out-Null
    Set-Target "mine`r`n$Start`r`nrule one`r`n$End`r`ntail`r`n"
    Invoke-Sync
    Chk ($null -eq $Err) 'no error'
    # The team block itself is written with LF; only the developer's lines keep CRLF.
    Chk ((Get-Target) -ceq "mine`r`n$Start`nrule two`n$End`ntail`r`n") 'personal CRLF bytes kept, block replaced'

    Write-Host '13) regression: replacement tokens in the standards stay literal'
    New-Case 'tokens' 'cost is $$5 and $& and $_ and $1' | Out-Null
    Set-Target "mine`n$Start`nold`n$End`n"
    Invoke-Sync
    Chk ((Get-Target) -ceq "mine`n$Start`ncost is `$`$5 and `$& and `$_ and `$1`n$End`n") 'tokens written literally'
    $Size = (Get-Target).Length
    Invoke-Sync
    Chk ($Out -match 'already up to date') 'second run is a no-op'
    Chk ((Get-Target).Length -eq $Size) 'file does not grow'

    Write-Host '14) non-ASCII text survives the round trip'
    # Built from code points so this file stays ASCII (PowerShell 5.1 reads a
    # BOM-less script as ANSI).
    $Rule = 'rule ' + [char]0x2014 + ' with ' + [char]0x201C + 'quotes' + [char]0x201D + ' ' + [char]0x2192
    $Note = 'caf' + [char]0x00E9 + ' notes'
    New-Case 'unicode' $Rule | Out-Null
    Set-Target "$Note`n"
    Invoke-Sync
    Invoke-Sync
    $Text = Get-Target
    Chk ($Text.Contains($Note) -and $Text.Contains($Rule)) 'UTF-8 content intact'
    Chk ($Out -match 'already up to date') 'second run is a no-op'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $Root
}

Write-Host '---'
Write-Host "Passed: $script:pass  Failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
exit 0
