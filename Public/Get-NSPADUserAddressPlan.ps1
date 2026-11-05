function Get-NSPADUserAddressPlan {
    <#
    .SYNOPSIS
        Plans UPN, mail, primary SMTP, alias and optional sAMAccountName migration without directory access.
    .DESCRIPTION
        Supply a complete forest inventory of NSP.ActiveDirectory.User objects for collision review.
        Identity selects GUIDs to change; other users remain collision candidates. The input is never
        mutated. Existing aliases and X400/X500 addresses are preserved unless explicitly removed.
        This plan does not verify UPN suffix configuration, Exchange policy or directory permissions.
    .EXAMPLE
        $plan = Get-NSPADUserAddressPlan -User $inventory -OldDomain old.example -NewDomain new.example -Format First.Last
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.UserAddressPlan')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$User,
        [guid[]]$Identity,
        [guid[]]$SkipIdentity = @(),
        [Parameter(Mandatory)][ValidateScript({ Test-NSPADAddressDomain $_ })][string]$OldDomain,
        [Parameter(Mandatory)][ValidateScript({ Test-NSPADAddressDomain $_ })][string]$NewDomain,
        [ValidateSet('ReplaceSuffix','SamAccountName','FLast','First.Last','LastF')][string]$Format = 'ReplaceSuffix',
        [switch]$ChangeSamAccountName,
        [switch]$CreateMailIfEmpty,
        [bool]$UpdateUPN = $true,
        [bool]$UpdateMail = $true,
        [bool]$UpdatePrimarySmtp = $true,
        [bool]$PreserveOldAddress = $true,
        [switch]$ConvertAliasDomain,
        [string[]]$RemoveAliasDomain = @(),
        [ValidateSet('X400','X500')][string[]]$RemoveAddressType = @()
    )
    foreach ($domain in $RemoveAliasDomain) {
        if (-not (Test-NSPADAddressDomain $domain)) { throw 'RemoveAliasDomain must contain DNS domains without @.' }
        if ($domain -ieq $NewDomain) { throw 'Cannot remove aliases from the target domain.' }
    }
    if ($OldDomain -ieq $NewDomain) { throw 'OldDomain and NewDomain must differ.' }
    $byId = @{}
    foreach ($item in $User) {
        $id = [guid]$item.ObjectGUID
        if ($id -eq [guid]::Empty -or -not $item.ObjectSID -or -not $item.DomainDNSRoot -or -not $item.Server) {
            throw 'Inventory requires nonempty GUID, SID, domain and server provenance.'
        }
        if ($byId.ContainsKey($id.ToString())) { throw 'Duplicate GUID in inventory.' }
        $byId[$id.ToString()] = $item
    }
    foreach ($id in @(@($Identity) + @($SkipIdentity) | Where-Object { $null -ne $_ })) {
        if (-not $byId.ContainsKey($id.ToString())) { throw 'Selected or skipped GUID is absent from inventory.' }
    }
    $policy = [ordered]@{
        OldDomain = $OldDomain; NewDomain = $NewDomain; Format = $Format
        ChangeSamAccountName = [bool]$ChangeSamAccountName; CreateMailIfEmpty = [bool]$CreateMailIfEmpty
        UpdateUPN = $UpdateUPN; UpdateMail = $UpdateMail; UpdatePrimarySmtp = $UpdatePrimarySmtp
        PreserveOldAddress = $PreserveOldAddress; ConvertAliasDomain = [bool]$ConvertAliasDomain
        RemoveAliasDomain = [string[]]$RemoveAliasDomain; RemoveAddressType = [string[]]$RemoveAddressType
    }
    $plans = @{}
    foreach ($item in $User) {
        $id = [guid]$item.ObjectGUID
        if (($PSBoundParameters.ContainsKey('Identity') -and $id -notin $Identity) -or $id -in $SkipIdentity) { continue }
        $before = Get-NSPADAddressState $item
        $after = Get-NSPADAddressState $item
        $reasons = [Collections.Generic.List[string]]::new()
        $local = ''
        if ($Format -eq 'ReplaceSuffix') {
            $parts = $before.UserPrincipalName.Split('@')
            if ($parts.Count -ne 2 -or ($parts[1] -ine $OldDomain -and $parts[1] -ine $NewDomain)) {
                $reasons.Add('UPN has an unexpected suffix or is missing.')
            } else { $local = $parts[0] }
        } elseif ($Format -eq 'SamAccountName') { $local = $before.SamAccountName }
        elseif ([string]::IsNullOrWhiteSpace($item.GivenName) -or [string]::IsNullOrWhiteSpace($item.Surname)) {
            $reasons.Add('Name generation requires both given name and surname.')
        } else {
            $local = switch ($Format) {
                FLast { $item.GivenName.Substring(0,1) + $item.Surname }
                'First.Last' { $item.GivenName + '.' + $item.Surname }
                LastF { $item.Surname + $item.GivenName.Substring(0,1) }
            }
        }
        $target = ($local + '@' + $NewDomain).ToLowerInvariant()
        if (-not (Test-NSPADSimpleMailAddress $target)) { $reasons.Add('Generated address requires manual review; no automatic transliteration or truncation.') }
        if ($reasons.Count -eq 0) {
            if ($UpdateUPN) { $after.UserPrincipalName = $target }
            if ($ChangeSamAccountName) {
                if ($local.Length -gt 20 -or $local -match '["/\\\[\]:;|=,+*?<>\s]' -or $local.EndsWith('.')) {
                    $reasons.Add('Generated sAMAccountName is invalid or exceeds twenty characters.')
                } else { $after.SamAccountName = $local.ToLowerInvariant() }
            }
            if (-not $UpdateMail) {
                # Deliberate preservation is independent of the UPN and primary SMTP choices.
            } elseif (-not $before.Mail) {
                if ($CreateMailIfEmpty) { $after.Mail = $target }
            } elseif ($before.Mail -ieq $target -or $before.Mail.EndsWith('@' + $OldDomain, [StringComparison]::OrdinalIgnoreCase)) {
                $after.Mail = $target
            } else { $reasons.Add('Mail is outside the old domain and differs from the target.') }

            $primaries = @($before.ProxyAddresses | Where-Object { $_.StartsWith('SMTP:', [StringComparison]::Ordinal) })
            if ($primaries.Count -gt 1) { $reasons.Add('Multiple primary SMTP addresses require review.') }
            foreach ($primary in $primaries) {
                if ($primary.Substring(5) -ine $target -and -not $primary.EndsWith('@' + $OldDomain, [StringComparison]::OrdinalIgnoreCase)) {
                    $reasons.Add('Primary SMTP is outside the old domain and differs from the target.')
                }
            }
            $proxies = [Collections.Generic.List[string]]::new()
            if ($UpdatePrimarySmtp) { $proxies.Add('SMTP:' + $target) }
            else { foreach ($primary in $primaries) { $proxies.Add($primary) } }
            foreach ($proxy in $before.ProxyAddresses) {
                if ($proxy -imatch '^smtp:') {
                    $address = $proxy.Substring(5)
                    if (-not (Test-NSPADSimpleMailAddress $address)) { $reasons.Add('An existing SMTP proxy requires manual review.'); continue }
                    if (($UpdatePrimarySmtp -and $address -ieq $target) -or (-not $UpdatePrimarySmtp -and $proxy -cin $primaries)) { continue }
                    $domain = $address.Split('@')[1]
                    if ($RemoveAliasDomain -icontains $domain) { continue }
                    if ($ConvertAliasDomain -and $domain -ieq $OldDomain) {
                        $proxies.Add('smtp:' + $address.Split('@')[0] + '@' + $NewDomain)
                        if (-not $PreserveOldAddress) { continue }
                    }
                    if (-not $PreserveOldAddress -and ($domain -ieq $OldDomain -or $proxy -cin $primaries)) { continue }
                    $proxies.Add('smtp:' + $address)
                } else {
                    $type = $proxy.Split(':')[0]
                    if ($type -notin $RemoveAddressType) { $proxies.Add($proxy) }
                }
            }
            if ($PreserveOldAddress -and $before.UserPrincipalName -ine $target -and (Test-NSPADSimpleMailAddress $before.UserPrincipalName)) {
                $oldUpnDomain = $before.UserPrincipalName.Split('@')[1]
                if ($RemoveAliasDomain -inotcontains $oldUpnDomain) { $proxies.Add('smtp:' + $before.UserPrincipalName) }
            }
            $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $after.ProxyAddresses = [string[]]@($proxies | Where-Object { $unique.Add($_) })
        }
        $plans[$id.ToString()] = [pscustomobject]@{
            PSTypeName = 'NSP.ActiveDirectory.UserAddressPlan'; ObjectGUID = $id
            ObjectSID = [string]$item.ObjectSID; DomainDNSRoot = [string]$item.DomainDNSRoot
            Server = [string]$item.Server; Before = $before; After = $after
            Policy = [pscustomobject]$policy; Reasons = $reasons; Blocked = $false; Changed = $false
        }
    }
    # Reserve both existing and proposed claims. Even another selected user cannot free an
    # address during this batch: the writer never depends on a particular execution order.
    $claims = @{}
    foreach ($item in $User) {
        $id = ([guid]$item.ObjectGUID).ToString()
        $states = @($item)
        if ($plans.ContainsKey($id)) {
            $state = $plans[$id].After | Select-Object *, @{n='DomainDNSRoot';e={$item.DomainDNSRoot}}
            $states += $state
        }
        foreach ($state in $states) {
            foreach ($claim in @(Get-NSPADAddressClaim $state)) {
                if (-not $claims.ContainsKey($claim)) { $claims[$claim] = @{} }
                $claims[$claim][$id] = $true
            }
        }
    }
    foreach ($item in $User) {
        $id = ([guid]$item.ObjectGUID).ToString()
        if (-not $plans.ContainsKey($id)) { continue }
        $plan = $plans[$id]
        $state = $plan.After | Select-Object *, @{n='DomainDNSRoot';e={$plan.DomainDNSRoot}}
        foreach ($claim in @(Get-NSPADAddressClaim $state)) {
            if ($claims[$claim].Count -gt 1) { $plan.Reasons.Add('Address or account-name collision in supplied inventory.'); break }
        }
        $plan.Blocked = $plan.Reasons.Count -gt 0
        $plan.Changed = (ConvertTo-NSPADAddressStateKey $plan.Before) -cne (ConvertTo-NSPADAddressStateKey $plan.After)
        $plan.Reasons = [string[]]@($plan.Reasons)
        $plan
    }
}
