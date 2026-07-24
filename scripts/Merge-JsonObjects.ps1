# Deep-merge two objects parsed from JSON via ConvertFrom-Json.
# Team settings are the base; user settings override. Objects merge key-by-key,
# arrays are unioned (order-preserving, case-sensitive dedup), scalars take the
# override value.
#
# Dot-source this file to use Merge-JsonObjects with no side effects
# (see scripts/test-merge-jsonobjects.ps1 and scripts/test-setup-env-integration.ps1).
#
# Correctness notes (all verified on PowerShell 5.1 — see issue #201):
#  - Both `.Name` accesses are wrapped in @(): a single-property object returns
#    `.Name` as a SCALAR string, and `"permissions" + <names[]>` would then be
#    STRING concatenation, collapsing every key into one garbage key.
#  - Array results are returned with the unary comma operator (`,`): PowerShell
#    unwraps a single-element array on `return`, which ConvertTo-Json then writes
#    as a bare scalar — corrupting e.g. a one-rule `deny` into a string.
#  - A `$null` value on either side is healed (not fatal): `[Parameter(Mandatory)]`
#    would reject a null override (e.g. a corrupted `"permissions": null`) and
#    abort the whole sync.
#  - Union is case-SENSITIVE and order-preserving: `Sort-Object -Unique` is
#    case-insensitive (drops case-distinct permission rules) and alphabetizes
#    (destroys curated grouping and breaks the caller's idempotency check).

function Merge-JsonObjects {
    param($Base, $Override)

    # Heal nulls toward the non-null side; a null override keeps the base value.
    if ($null -eq $Override) { return $Base }
    if ($null -eq $Base) { return $Override }

    if ($Base -is [System.Management.Automation.PSCustomObject] -and
        $Override -is [System.Management.Automation.PSCustomObject]) {
        $Result = [PSCustomObject]@{}
        $AllKeys = @(@($Base.PSObject.Properties.Name) + @($Override.PSObject.Properties.Name) | Sort-Object -Unique)
        foreach ($Key in $AllKeys) {
            # A real settings key is a camelCase identifier and never contains
            # whitespace. A whitespace key is the corruption signature from an
            # earlier buggy sync — skip it so this run heals the file.
            if ($Key -match '\s') {
                Write-Warning "Skipping corrupted settings key (contains whitespace): '$Key'"
                continue
            }
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
        # Order-preserving, case-sensitive union: keep base items in order, then
        # append override items not already present. (Settings arrays are string
        # arrays; the dedup key is the item's string form.)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in (@($Base) + @($Override))) {
            if ($seen.Add([string]$item)) { $list.Add($item) }
        }
        # Unary comma prevents PowerShell from unwrapping a single-element array
        # on return (which would serialize as a scalar and corrupt the schema).
        return , $list.ToArray()
    }
    else {
        return $Override
    }
}
