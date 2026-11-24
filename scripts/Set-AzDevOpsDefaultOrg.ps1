# Sets the Azure DevOps CLI's default organization when none is set, so the
# team's az commands can leave out --org. The team settings make every
# `az ... --org` prompt (POLICY_ASK in standards/validate-settings.py), and
# without --org az takes the organization from the repository's remote or
# from this default. Dot-sourced by setup-env.ps1 and by
# scripts/test-set-azdevopsdefaultorg.ps1. The bash twin is
# scripts/set-az-default-org.sh; keep the two in step.
#
# A default the developer already set is kept, whatever it is. Setup never
# fails here: a missing Azure CLI or azure-devops extension, or an az call
# that fails, is reported and skipped.
#
# SETUP_ENV_AZ names the az executable to run instead of `az` (tests use a stub).

function Set-AzDevOpsDefaultOrg {
    param(
        [Parameter(Mandatory = $true)] [string] $Organization
    )

    # Windows PowerShell 5.1 turns native stderr into a terminating error when
    # setup-env.ps1's 'Stop' preference is in effect; az writes warnings there.
    $ErrorActionPreference = 'Continue'

    $Az = 'az'
    if (-not [string]::IsNullOrEmpty($env:SETUP_ENV_AZ)) {
        $Az = $env:SETUP_ENV_AZ
    }

    if ($null -eq (Get-Command $Az -ErrorAction SilentlyContinue)) {
        Write-Host 'Azure CLI not found - skipping. Install it, then re-run setup to set the default organization.'
        return
    }

    & $Az extension show --name azure-devops 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'The azure-devops az extension is not installed - skipping.'
        Write-Host "Install it with 'az extension add --name azure-devops', then re-run setup."
        return
    }

    $Listing = & $Az devops configure --list 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Could not read the Azure DevOps CLI defaults - skipping.'
        return
    }

    # `organization = <url>`; an unset default prints an empty value.
    $Current = ''
    foreach ($Line in @($Listing)) {
        if ("$Line" -match '^\s*organization\s*=\s*(.*?)\s*$') {
            $Current = $Matches[1]
            break
        }
    }

    if ($Current -ne '') {
        if ($Current.TrimEnd('/') -eq $Organization.TrimEnd('/')) {
            Write-Host "Azure DevOps default organization is already $Current"
        }
        else {
            Write-Host "Keeping your Azure DevOps default organization $Current (the team's is $Organization)."
        }
        return
    }

    & $Az devops configure --defaults "organization=$Organization" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Set the Azure DevOps default organization to $Organization"
    }
    else {
        Write-Warning 'Could not set the Azure DevOps default organization.'
        Write-Warning "Run 'az devops configure --defaults organization=$Organization' yourself."
    }
}
