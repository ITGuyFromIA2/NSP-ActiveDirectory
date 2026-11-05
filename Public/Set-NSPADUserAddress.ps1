function Set-NSPADUserAddress {
    <#
    .SYNOPSIS
        Previews address plans; explicitly applies reviewed plans with forest refresh and read-back.
    .DESCRIPTION
        Preview is the default. Apply requires RSAT and reads the seed forest again, regenerating
        every proposal and checking GUID, SID, domain, server, source values and collisions before
        the first write. One policy per batch. Each user is confirmed, read again on the pinned
        server, written by GUID and read back. No sync cycle is started. Results can contain PII;
        store them outside source control. This is not a transaction; retain every result.
    .EXAMPLE
        Set-NSPADUserAddress -Plan $plan
    .EXAMPLE
        Set-NSPADUserAddress -Plan $plan -Apply
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('NSP.ActiveDirectory.UserAddressResult')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Plan,
        [switch]$Apply
    )
    $ids = @{}
    foreach ($entry in $Plan) {
        $id = [guid]$entry.ObjectGUID
        if ($id -eq [guid]::Empty -or $ids.ContainsKey($id.ToString())) { throw 'Empty or duplicate plan GUID.' }
        $ids[$id.ToString()] = $true
        if ($entry.Blocked) { throw 'A plan is blocked; resolve its reasons and regenerate the batch.' }
    }
    if (-not $Apply -or $WhatIfPreference) {
        foreach ($entry in $Plan) {
            if ($Apply) { [void]$PSCmdlet.ShouldProcess($entry.ObjectGUID, 'Apply user address plan') }
            [pscustomobject]@{ PSTypeName='NSP.ActiveDirectory.UserAddressResult'; ObjectGUID=$entry.ObjectGUID; Result='Preview'; Plan=$entry }
        }
        return
    }
    Assert-NSPADCommand -Name Set-ADUser
    $policyKey = ConvertTo-Json -InputObject $Plan[0].Policy -Depth 4 -Compress
    foreach ($entry in $Plan) {
        if ((ConvertTo-Json -InputObject $entry.Policy -Depth 4 -Compress) -cne $policyKey) { throw 'Use one policy per batch.' }
    }
    $options = @{}
    foreach ($property in $Plan[0].Policy.PSObject.Properties) { $options[$property.Name] = $property.Value }
    # A terminating forest read invalidates the entire inventory; no writes have begun.
    $inventory = @(Get-NSPADUser -All -Forest -Server $Plan[0].Server -ErrorAction Stop)
    $fresh = @(Get-NSPADUserAddressPlan -User $inventory -Identity @($Plan | ForEach-Object { [guid]$_.ObjectGUID }) @options)
    $currentPlans = @{}
    foreach ($entry in $fresh) { $currentPlans[$entry.ObjectGUID.ToString()] = $entry }
    foreach ($entry in $Plan) {
        $current = $currentPlans[([guid]$entry.ObjectGUID).ToString()]
        if ($null -eq $current -or $current.Blocked -or $entry.ObjectSID -cne $current.ObjectSID -or
            $entry.DomainDNSRoot -ine $current.DomainDNSRoot -or $entry.Server -ine $current.Server -or
            (ConvertTo-NSPADAddressStateKey $entry.Before) -cne (ConvertTo-NSPADAddressStateKey $current.Before) -or
            (ConvertTo-NSPADAddressStateKey $entry.After) -cne (ConvertTo-NSPADAddressStateKey $current.After)) {
            throw 'Plan is stale, modified or blocked by the refreshed inventory; regenerate and review it.'
        }
    }
    $upnChanges = @($fresh | Where-Object { $_.Before.UserPrincipalName -cne $_.After.UserPrincipalName })
    if ($upnChanges.Count) {
        $forestInfo = Get-NSPADForestInfo -Server $Plan[0].Server -ErrorAction Stop
        foreach ($change in $upnChanges) {
            $suffix = $change.After.UserPrincipalName.Split('@')[-1]
            if ($forestInfo.AvailableUPNSuffixes -inotcontains $suffix) {
                throw 'Target UPN suffix is unavailable in the forest. Separately plan and explicitly add it, then refresh and review the user plan.'
            }
        }
    }
    foreach ($entry in $Plan) {
        $result = 'Unchanged'
        $message = ''
        $observed = $null
        $current = $currentPlans[([guid]$entry.ObjectGUID).ToString()]
        if ($current.Changed) {
            if ($PSCmdlet.ShouldProcess("$($entry.ObjectGUID) on $($entry.Server)", 'Apply reviewed UPN, mail, proxy and account-name changes')) {
                $writeStarted = $false
                try {
                    $before = Read-NSPADAddressState -ObjectGUID $entry.ObjectGUID -Server $entry.Server
                    if ($before.ObjectSID -cne $entry.ObjectSID -or
                        (ConvertTo-NSPADAddressStateKey $before.State) -cne (ConvertTo-NSPADAddressStateKey $entry.Before)) {
                        throw 'User changed after preflight; regenerate the stale plan.'
                    }
                    $replace = @{}
                    $clear = @()
                    foreach ($name in 'SamAccountName','UserPrincipalName','Mail') {
                        if ($current.Before.$name -cne $current.After.$name) {
                            if ($current.After.$name) { $replace[$name.ToLowerInvariant()] = $current.After.$name }
                            else { $clear += $name.ToLowerInvariant() }
                        }
                    }
                    $oldProxies = ConvertTo-Json -InputObject @($current.Before.ProxyAddresses | Sort-Object -CaseSensitive) -Compress
                    $newProxies = ConvertTo-Json -InputObject @($current.After.ProxyAddresses | Sort-Object -CaseSensitive) -Compress
                    if ($oldProxies -cne $newProxies) {
                        if ($current.After.ProxyAddresses.Count) { $replace.proxyaddresses = [string[]]$current.After.ProxyAddresses }
                        else { $clear += 'proxyaddresses' }
                    }
                    $write = @{ Identity=[guid]$entry.ObjectGUID; Server=$entry.Server; ErrorAction='Stop' }
                    if ($replace.Count) { $write.Replace = $replace }
                    if ($clear.Count) { $write.Clear = $clear }
                    $writeStarted = $true
                    Set-ADUser @write
                    $observed = Read-NSPADAddressState -ObjectGUID $entry.ObjectGUID -Server $entry.Server
                    if ($observed.ObjectSID -ceq $entry.ObjectSID -and
                        (ConvertTo-NSPADAddressStateKey $observed.State) -ceq (ConvertTo-NSPADAddressStateKey $current.After)) {
                        $result = 'Verified'
                    } else { $result = 'VerificationFailed'; $message = 'Read-back differs; inspect this user before retrying.' }
                } catch {
                    $result = if ($writeStarted) { 'WriteUnverified' } else { 'Failed' }
                    $message = $_.Exception.Message
                }
            } else { $result = 'Skipped' }
        }
        [pscustomobject]@{
            PSTypeName='NSP.ActiveDirectory.UserAddressResult'; ObjectGUID=$entry.ObjectGUID
            Server=$entry.Server; Result=$result; Message=$message
            Before=$entry.Before; After=$current.After; Observed=$observed
            TimestampUtc=[datetime]::UtcNow
        }
        # Stop the batch after any uncertain outcome. Already emitted results remain available.
        if ($result -in 'Failed','WriteUnverified','VerificationFailed') { return }
    }
}
