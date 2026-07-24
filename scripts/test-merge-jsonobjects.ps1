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

Write-Host "---"
if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail test(s)"; exit 1 }
Write-Host "OK: all Merge-JsonObjects tests pass"; exit 0
