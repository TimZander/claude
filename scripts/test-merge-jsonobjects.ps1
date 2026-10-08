# Regression tests for Merge-JsonObjects (issue #201). Run:
#   powershell -File scripts/test-merge-jsonobjects.ps1
# Exit 0 on pass, 1 on failure.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Merge-JsonObjects.ps1')

$script:fail = 0
function Assert($cond, $desc) {
    if ($cond) { Write-Host "  ok: $desc" }
    else { Write-Host "  FAIL: $desc"; $script:fail++ }
}

# Case 1 — THE #201 REGRESSION: a base with a single top-level key must not
# collapse every key into one space-joined garbage key.
$base = '{ "permissions": { "allow": ["a"] } }' | ConvertFrom-Json
$over = '{ "permissions": { "allow": ["b"] }, "enabledPlugins": { "x": true }, "tui": "dark" }' | ConvertFrom-Json
$m = Merge-JsonObjects -Base $base -Override $over
$keys = @($m.PSObject.Properties.Name)
Assert (@($keys | Where-Object { $_ -match '\s' }).Count -eq 0) "no whitespace/garbage key is produced"
Assert (($keys -contains 'permissions') -and ($keys -contains 'enabledPlugins') -and ($keys -contains 'tui')) "all real top-level keys survive"
Assert ((@($m.permissions.allow) -contains 'a') -and (@($m.permissions.allow) -contains 'b')) "permissions.allow is unioned (base + override)"
Assert ($m.tui -eq 'dark') "scalar override value preserved"
Assert ($m.enabledPlugins.x -eq $true) "nested override object preserved"

# Case 2 — scalar override wins on conflict.
$b2 = '{ "k": "base" }' | ConvertFrom-Json
$o2 = '{ "k": "over" }' | ConvertFrom-Json
Assert ((Merge-JsonObjects -Base $b2 -Override $o2).k -eq 'over') "override wins on scalar conflict"

# Case 3 — arrays union and dedup.
$b3 = '{ "a": ["x","y"] }' | ConvertFrom-Json
$o3 = '{ "a": ["y","z"] }' | ConvertFrom-Json
$m3 = @((Merge-JsonObjects -Base $b3 -Override $o3).a)
Assert (($m3.Count -eq 3) -and ($m3 -contains 'x') -and ($m3 -contains 'z')) "arrays unioned and deduped"

# Case 4 — a pre-corrupted whitespace key is dropped (auto-heal); clean keys survive.
$b4 = '{ "permissions": { "allow": [] } }' | ConvertFrom-Json
$o4 = '{ "a b c": null, "tui": "x" }' | ConvertFrom-Json
$m4 = @((Merge-JsonObjects -Base $b4 -Override $o4 3>$null).PSObject.Properties.Name)
Assert (-not ($m4 -contains 'a b c')) "pre-corrupted whitespace key is dropped"
Assert ($m4 -contains 'tui') "clean keys survive the guard"

# Case 5 — a single-element merged array stays an array (regression: PowerShell
# unwraps a 1-element array on return, which ConvertTo-Json writes as a scalar).
$b5 = '{ "permissions": { "allow": [], "deny": [] } }' | ConvertFrom-Json
$o5 = '{ "permissions": { "deny": ["only-one"] } }' | ConvertFrom-Json
$deny = (Merge-JsonObjects -Base $b5 -Override $o5).permissions.deny
Assert (($deny -is [array]) -and (@($deny).Count -eq 1)) "single-element merged array stays an array"

# Case 6 — a null override on a shared key heals to base instead of crashing.
$b6 = '{ "permissions": { "allow": ["keep"] } }' | ConvertFrom-Json
$o6 = '{ "permissions": null }' | ConvertFrom-Json
$m6 = Merge-JsonObjects -Base $b6 -Override $o6
Assert (@($m6.permissions.allow) -contains 'keep') "null override heals to base (no crash)"

# Case 7 — union is case-SENSITIVE (Claude Code matchers are case-sensitive).
$b7 = '{ "a": ["Bash(git log:*)"] }' | ConvertFrom-Json
$o7 = '{ "a": ["bash(GIT LOG:*)"] }' | ConvertFrom-Json
Assert (@((Merge-JsonObjects -Base $b7 -Override $o7).a).Count -eq 2) "case-distinct entries are both kept"

# Case 8 — union preserves order (base first, then new override entries) and dedups.
$b8 = '{ "a": ["z","m"] }' | ConvertFrom-Json
$o8 = '{ "a": ["m","new"] }' | ConvertFrom-Json
$m8 = @((Merge-JsonObjects -Base $b8 -Override $o8).a)
Assert (($m8.Count -eq 3) -and ($m8[0] -eq 'z') -and ($m8[-1] -eq 'new')) "union preserves order and dedups"

# Case 9 — the @() fix holds at deeper single-key nesting.
$b9 = '{ "a": { "b": { "c": ["x"] } } }' | ConvertFrom-Json
$o9 = '{ "a": { "b": { "c": ["y"] } } }' | ConvertFrom-Json
$m9 = Merge-JsonObjects -Base $b9 -Override $o9
$m9keys = @($m9.PSObject.Properties.Name)
Assert ((@($m9keys | Where-Object { $_ -match '\s' }).Count -eq 0) -and (@($m9.a.b.c) -contains 'x')) "no corruption at deep single-key nesting"

Write-Host "---"
if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail test(s)"; exit 1 }
Write-Host "OK: all Merge-JsonObjects tests pass"; exit 0
