# Deep-merge two objects parsed from JSON via ConvertFrom-Json.
# Team settings are the base; user settings override. Objects merge key-by-key,
# arrays are unioned (deduped), scalars take the override value.
#
# Dot-source this file to use Merge-JsonObjects with no side effects
# (see scripts/test-merge-jsonobjects.ps1).
#
# CRITICAL: both `.Name` accesses are wrapped in @(). When an object has a
# SINGLE property, PowerShell returns its `.Name` as a scalar string, not an
# array — and `"permissions" + <names[]>` is then STRING concatenation, which
# collapses every key into one space-joined garbage key and wipes the real
# settings. standards/settings.json has exactly one top-level key
# (`permissions`), so this hit every Windows sync. See issue #201.

function Merge-JsonObjects {
    param(
        [Parameter(Mandatory)] $Base,
        [Parameter(Mandatory)] $Override
    )

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
        $Combined = @($Base) + @($Override) | Sort-Object -Unique
        return @($Combined)
    }
    else {
        return $Override
    }
}
