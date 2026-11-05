function Get-NSPADAddressState {
    param($User)
    [pscustomobject][ordered]@{
        SamAccountName = [string]$User.SamAccountName
        UserPrincipalName = [string]$User.UserPrincipalName
        Mail = [string]$User.Mail
        ProxyAddresses = [string[]]@($User.ProxyAddresses)
    }
}

function ConvertTo-NSPADAddressStateKey {
    param($State)
    # Canonical order and exact casing: SMTP: and smtp: have different meanings.
    $copy = Get-NSPADAddressState $State
    $copy.ProxyAddresses = [string[]]@($copy.ProxyAddresses | Sort-Object -CaseSensitive)
    ConvertTo-Json -InputObject $copy -Depth 4 -Compress
}

function Test-NSPADAddressDomain {
    param([string]$Domain)
    $Domain.Length -le 253 -and $Domain -match '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+$' -and
        @($Domain.Split('.') | Where-Object { $_.Length -gt 63 }).Count -eq 0
}

function Test-NSPADSimpleMailAddress {
    param([string]$Address)
    # Deliberately conservative; unusual/quoted/Unicode local parts need manual review.
    $parts = $Address.Split('@')
    $parts.Count -eq 2 -and $parts[0].Length -ge 1 -and $parts[0].Length -le 64 -and
        $parts[0] -match '^[a-zA-Z0-9!#$%&''+\-/=?^_`{|}~]+(?:\.[a-zA-Z0-9!#$%&''+\-/=?^_`{|}~]+)*$' -and
        (Test-NSPADAddressDomain $parts[1]) -and $Address.Length -le 254
}

function Get-NSPADAddressClaim {
    param($User)
    if ($User.UserPrincipalName) { 'address:' + $User.UserPrincipalName.ToLowerInvariant() }
    if ($User.Mail) { 'address:' + $User.Mail.ToLowerInvariant() }
    foreach ($proxy in $User.ProxyAddresses) {
        if ($proxy -imatch '^smtp:(.+)$') { 'address:' + $proxy.Substring(5).ToLowerInvariant() }
    }
    if ($User.SamAccountName) { 'sam:' + $User.DomainDNSRoot.ToLowerInvariant() + ':' + $User.SamAccountName.ToLowerInvariant() }
}

function Read-NSPADAddressState {
    param([guid]$ObjectGUID, [string]$Server)
    $guidFilter = -join ($ObjectGUID.ToByteArray() | ForEach-Object { '\' + $_.ToString('x2') })
    $domain = Get-NSPADDomainInfo -Server $Server
    $rows = @(Read-NSPADLdap -Server $Server -SearchBase $domain.DistinguishedName -Filter "(&(objectCategory=person)(objectClass=user)(objectGUID=$guidFilter))" -Property 'samAccountName','userPrincipalName','mail','proxyAddresses','objectSid' -MultiValued proxyAddresses)
    if ($rows.Count -ne 1) { throw 'GUID no longer resolves to exactly one user.' }
    $row = $rows[0]
    $sid = if ($row.objectsid -is [Security.Principal.SecurityIdentifier]) { $row.objectsid.Value } else {
        [Security.Principal.SecurityIdentifier]::new([byte[]]$row.objectsid, 0).Value
    }
    [pscustomobject]@{
        ObjectSID = $sid
        State = [pscustomobject]@{
            SamAccountName=[string]$row.samaccountname; UserPrincipalName=[string]$row.userprincipalname
            Mail=[string]$row.mail; ProxyAddresses=[string[]]@($row.proxyaddresses)
        }
    }
}
