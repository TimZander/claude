# Sets the Azure DevOps CLI's default organization when none is set, so the
# team's az commands can run with `--detect false` and no --org. The team
# settings make every `az ... --org` ask (POLICY_ASK in
# standards/validate-settings.py). Dot-sourced by setup-env.ps1 and by
# scripts/test-set-azdevopsdefaultorg.ps1. The bash twin is
# scripts/set-az-default-org.sh; keep the two in step.
#
# A default the developer already set is kept, whatever it is. Setup never
# fails here: a missing Azure CLI or azure-devops extension, or an az call
# that fails, is reported (with az's own message) and skipped.
#
# Every az call gets empty stdin, so a prompt (an auto-upgrade question, say)
# cannot block setup behind captured output. The extension is checked before
# any `az devops` call because az would otherwise offer to install it, which
# is a prompt too.
#
# SETUP_ENV_AZ names the az executable to run instead of `az`. It exists for
# the tests, which point it at a stub; setup says when it is in effect.

function Set-AzDevOpsDefaultOrg {
    param(
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Organization
    )

    # Windows PowerShell 5.1 turns native stderr into a terminating error when
    # setup-env.ps1's 'Stop' preference is in effect; az writes warnings there.
    $ErrorActionPreference = 'Continue'

    $Az = 'az'
    if (-not [string]::IsNullOrEmpty($env:SETUP_ENV_AZ)) {
        $Az = $env:SETUP_ENV_AZ
        Write-Host "Using az from SETUP_ENV_AZ: $Az"
    }

    # Applications and scripts only: an `az` alias or function from the
    # developer's profile is not the Azure CLI.
    $AzCommand = Get-Command $Az -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $AzCommand) {
        Write-Host 'Azure CLI not found - skipping. Install it, then re-run setup to set the default organization.'
        return
    }

    # Runs az with empty stdin; returns its exit code and its output, stderr
    # included, as text lines. $LASTEXITCODE is reset first so a call that
    # never starts cannot report the previous command's success.
    function Invoke-AzQuiet([string[]] $AzArgs) {
        $global:LASTEXITCODE = 1
        $lines = @($null | & $AzCommand @AzArgs 2>&1 | ForEach-Object { "$_" })
        return @{ ExitCode = $LASTEXITCODE; Output = $lines }
    }

    $Extension = Invoke-AzQuiet @('extension', 'show', '--name', 'azure-devops')
    if ($Extension.ExitCode -ne 0) {
        Write-Host 'Could not confirm the azure-devops az extension is installed - skipping.'
        Write-Host "Install it with 'az extension add --name azure-devops', then re-run setup."
        Write-Host "az said: $($Extension.Output -join ' ')"
        return
    }

    $Listing = Invoke-AzQuiet @('devops', 'configure', '--list')
    if ($Listing.ExitCode -ne 0) {
        Write-Warning 'Could not read the Azure DevOps CLI defaults - skipping.'
        Write-Warning "az said: $($Listing.Output -join ' ')"
        return
    }

    # `organization = <url>`; an unset default prints an empty value. Output
    # is split again in case az (or a wrapper) returned it as one string.
    $Current = ''
    foreach ($Line in @($Listing.Output -join "`n" -split "`r?`n")) {
        if ($Line -match '^\s*organization\s*=\s*(.*?)\s*$') {
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

    $Set = Invoke-AzQuiet @('devops', 'configure', '--defaults', "organization=$Organization")
    if ($Set.ExitCode -eq 0) {
        Write-Host "Set the Azure DevOps default organization to $Organization"
    }
    else {
        Write-Warning 'Could not set the Azure DevOps default organization.'
        Write-Warning "az said: $($Set.Output -join ' ')"
        Write-Warning "Run 'az devops configure --defaults organization=$Organization' yourself."
    }
}
