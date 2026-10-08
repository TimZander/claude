# Integration test for the settings-sync pipeline (issue #201). Mirrors
# setup-env.ps1's read -> Merge-JsonObjects -> ConvertTo-Json -Depth 10 ->
# Set-Content -> re-read against temp files, using the REAL team settings.json
# (a single-top-level-key object — the corruption trigger). Guards the file
# round-trip that the in-memory unit test can't reach. Run:
#   pwsh scripts/test-setup-env-integration.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Merge-JsonObjects.ps1')
$RepoRoot = Split-Path $PSScriptRoot -Parent
$SettingsSource = Join-Path (Join-Path $RepoRoot 'standards') 'settings.json'

$script:fail = 0
function Chk($cond, $d) { if ($cond) { Write-Host "  ok: $d" } else { Write-Host "  FAIL: $d"; $script:fail++ } }

# Replicate setup-env.ps1's merge+write to a temp target; return the written text.
function Invoke-Sync($userJson) {
    $t = Join-Path ([System.IO.Path]::GetTempPath()) ("itest-" + [guid]::NewGuid().ToString('N') + ".json")
    $userJson | Set-Content -Path $t -Encoding utf8
    $team = Get-Content -Path $SettingsSource -Raw | ConvertFrom-Json
    $existing = Get-Content -Path $t -Raw | ConvertFrom-Json
    $merged = Merge-JsonObjects -Base $team -Override $existing 3>$null
    $json = $merged | ConvertTo-Json -Depth 10
    Set-Content -Path $t -Value $json -NoNewline -Encoding utf8
    $raw = Get-Content -Path $t -Raw
    Remove-Item -Force $t
    return $raw
}

# 1. Realistically-corrupted user file: prior garbage key + a single-element deny
#    + personal allow + scalar/plugin prefs.
$raw = Invoke-Sync @'
{
  "permissions garbage key": null,
  "permissions": { "allow": ["Bash(dotnet test *)"], "deny": ["Bash(rm -rf:*)"] },
  "enabledPlugins": { "deep-review@tzander-skills": true },
  "tui": "dark"
}
'@
$back = $raw | ConvertFrom-Json
Chk ($null -ne $back) "written file is valid JSON"
Chk (@($back.PSObject.Properties.Name | Where-Object { $_ -match '\s' }).Count -eq 0) "no whitespace/garbage key in output"
Chk ($back.permissions.allow.Count -ge 95) "team allow entries present (count=$($back.permissions.allow.Count))"
Chk (@($back.permissions.allow) -contains 'Bash(dotnet test *)') "personal allow entry preserved (union)"
Chk ($raw -match '"deny":\s*\[') "single-element deny stays an ARRAY (not collapsed to scalar)"
Chk ($back.tui -eq 'dark') "scalar pref preserved"
Chk ($back.enabledPlugins.'deep-review@tzander-skills' -eq $true) "enabledPlugins preserved"

# 2. Idempotency: re-syncing an already-synced file is a no-op (no churn).
$raw2 = Invoke-Sync $raw
Chk ($raw2.Trim() -eq $raw.Trim()) "second sync is idempotent (no churn/reorder loop)"

# 3. A null permissions value heals to the team allowlist instead of crashing.
$raw3 = Invoke-Sync '{ "permissions": null, "tui": "x" }'
$b3 = $raw3 | ConvertFrom-Json
Chk ($b3.permissions.allow.Count -ge 95) "null permissions heals to the team allowlist (no crash)"

Write-Host "---"
if ($script:fail -gt 0) { Write-Host "INTEGRATION FAILED: $script:fail check(s)"; exit 1 }
Write-Host "OK: full sync pipeline is correct, non-lossy, and idempotent"; exit 0
