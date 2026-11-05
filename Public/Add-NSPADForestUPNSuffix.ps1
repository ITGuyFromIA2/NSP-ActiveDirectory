function Add-NSPADForestUPNSuffix {
    <#
    .SYNOPSIS
        Previews a forest suffix plan; explicitly applies one additive change and verifies it.
    .DESCRIPTION
        Apply requires RSAT's Set-ADForest and separate owner authorization for the live forest.
        Rereads the pinned DC before and after confirmation, checks configuration GUID and
        snapshot, adds only the selected suffix and verifies on that DC. Never replaces the
        suffix list, changes a user, verifies an Entra domain or starts synchronization.
    .EXAMPLE
        Add-NSPADForestUPNSuffix -Plan $plan
    .EXAMPLE
        Add-NSPADForestUPNSuffix -Plan $plan -Apply
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType('NSP.ActiveDirectory.ForestUPNSuffixResult')]
    param([Parameter(Mandatory)][ValidateNotNull()]$Plan, [switch]$Apply)
    if ($Plan.Blocked) { throw 'Suffix plan is blocked.' }
    if (-not $Apply -or $WhatIfPreference) {
        if ($Apply) { [void]$PSCmdlet.ShouldProcess($Plan.ForestDNSRoot, "Add UPN suffix $($Plan.Suffix)") }
        return [pscustomobject]@{PSTypeName='NSP.ActiveDirectory.ForestUPNSuffixResult'; Result='Preview'; Plan=$Plan}
    }
    $ErrorActionPreference = 'Stop'
    $current = Get-NSPADForestInfo -Server $Plan.Server
    $fresh = Get-NSPADForestUPNSuffixPlan -ForestInfo $current -Suffix $Plan.Suffix
    Assert-NSPADForestSuffixPlanCurrent -Plan $Plan -Current $fresh
    if (-not $fresh.Changed) {
        return [pscustomobject]@{PSTypeName='NSP.ActiveDirectory.ForestUPNSuffixResult'; Result='AlreadyAvailable'; ForestInfo=$current; Suffix=$fresh.Suffix}
    }
    Assert-NSPADCommand -Name Set-ADForest
    $result = 'Skipped'
    $message = ''
    $observed = $null
    if ($PSCmdlet.ShouldProcess("$($fresh.ForestDNSRoot) on $($fresh.Server)", "Add UPN suffix $($fresh.Suffix)")) {
        # Do not hold a stale snapshot while an operator is deciding at a confirmation prompt.
        $current = Get-NSPADForestInfo -Server $fresh.Server
        $latest = Get-NSPADForestUPNSuffixPlan -ForestInfo $current -Suffix $fresh.Suffix
        Assert-NSPADForestSuffixPlanCurrent -Plan $Plan -Current $latest
        $writeStarted = $false
        try {
            $writeStarted = $true
            Set-ADForest -Identity $latest.ForestDNSRoot -Server $latest.Server -UPNSuffixes @{Add=$latest.Suffix} -ErrorAction Stop
            $observed = Get-NSPADForestInfo -Server $latest.Server
            $missingBefore = @($latest.Before | Where-Object { $observed.AlternateUPNSuffixes -inotcontains $_ })
            if ($observed.ConfigurationGUID -eq $latest.ConfigurationGUID -and
                $observed.ConfigurationDN -ieq $latest.ConfigurationDN -and
                $observed.AvailableUPNSuffixes -icontains $latest.Suffix -and $missingBefore.Count -eq 0) {
                $result = 'Verified'
            } else { $result='VerificationFailed'; $message='Read-back did not verify the selected suffix on the same forest.' }
        } catch {
            $result = if ($writeStarted) { 'WriteUnverified' } else { 'Failed' }
            $message = $_.Exception.Message
        }
    }
    [pscustomobject]@{
        PSTypeName='NSP.ActiveDirectory.ForestUPNSuffixResult'; Result=$result; Message=$message
        ForestDNSRoot=$fresh.ForestDNSRoot; ConfigurationGUID=$fresh.ConfigurationGUID
        Server=$fresh.Server; Suffix=$fresh.Suffix; Before=$fresh.Before; After=$fresh.After
        Observed=$observed; TimestampUtc=[datetime]::UtcNow
    }
}
