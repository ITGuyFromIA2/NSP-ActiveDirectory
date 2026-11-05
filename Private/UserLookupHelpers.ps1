function Get-NSPADForestDomainInfo {
    # Read every domain NC in the selected forest, excluding external references, application
    # partitions and pre-created (not yet active) domains. No GC partial attribute set is used.
    param([Parameter(Mandatory)][string]$Server, [int]$PageSize = 500)
    $seed = Get-NSPADDomainInfo -Server $Server
    if (-not $seed.ConfigurationDN) { throw 'The seed domain has no ConfigurationDN; forest discovery cannot continue.' }
    $refs = @(Read-NSPADLdap -Server $seed.Server -SearchBase "CN=Partitions,$($seed.ConfigurationDN)" -Scope OneLevel -Filter '(&(objectClass=crossRef)(systemFlags:1.2.840.113556.1.4.803:=3)(!(enabled=FALSE)))' -Property nCName,dnsRoot -PageSize $PageSize)
    if (-not $refs.Count) { throw 'No forest domain crossRefs are visible; refusing an empty forest inventory.' }
    $domains = @{}
    foreach ($ref in $refs) {
        $dn = [string]$ref['ncname']
        $dns = [string]$ref['dnsroot']
        if (-not $dn -or -not $dns) { throw 'A forest domain crossRef is missing nCName or dnsRoot.' }
        if ($domains.ContainsKey($dn)) { throw 'Multiple forest domain crossRefs have the same naming context.' }
        $dc = Find-NSPADDomainController -DomainName $dns
        $domain = Get-NSPADDomainInfo -Server $dc
        if ($domain.DistinguishedName -ne $dn -or $domain.DNSRoot -ne $dns -or $domain.ConfigurationDN -ne $seed.ConfigurationDN) {
            throw "Forest domain discovery resolved a different domain or forest for $dns."
        }
        $domains[$dn] = $domain
    }
    if (-not $domains.ContainsKey([string]$seed.DistinguishedName)) { throw 'The seed domain is absent from forest discovery.' }
    # Keep discovery order for predictable inventory output.
    foreach ($ref in $refs) { $domains[[string]$ref['ncname']] }
}

function ConvertTo-NSPADOptionalInt64 {
    # LDAP Integer8 values normally arrive as Int64. Retain exact integer text too, but never
    # coerce missing, floating point, Boolean or multi-valued data to a plausible zero/flag.
    param([AllowNull()]$Value)
    if ($null -eq $Value -or $Value -is [array] -or $Value -is [bool] -or
        $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $null }
    $number = [long]0
    if ([long]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return $null
}

function ConvertTo-NSPADUser {
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)]$DomainInfo)
    foreach ($required in 'distinguishedname', 'objectguid', 'objectsid', 'useraccountcontrol') {
        if (-not $Entry.ContainsKey($required) -or $null -eq $Entry[$required]) {
            throw "LDAP user result is missing $required; identity and enabled state must be readable."
        }
    }
    $passwordTime = $null
    $passwordState = 'Unknown'
    $mustChange = $null
    $fileTime = ConvertTo-NSPADOptionalInt64 -Value $Entry['pwdlastset']
    if ($null -ne $fileTime) {
        if ($fileTime -eq 0) {
            $passwordState = 'Zero'
            $mustChange = [bool](-not ([int]$Entry['useraccountcontrol'] -band 0x10000))
        } elseif ($fileTime -gt 0) {
            try {
                $passwordTime = [datetime]::FromFileTimeUtc($fileTime)
                $passwordState = 'Known'
                $mustChange = $false
            } catch [ArgumentOutOfRangeException] {
                # Optional corrupt/unreadable metadata must not invent a timestamp or status.
                $passwordTime = $null
            }
        }
    }
    [pscustomobject]@{
        PSTypeName           = 'NSP.ActiveDirectory.User'
        DistinguishedName    = [string]$Entry['distinguishedname']
        SamAccountName       = [string]$Entry['samaccountname']
        UserPrincipalName    = [string]$Entry['userprincipalname']
        DisplayName          = [string]$Entry['displayname']
        GivenName            = [string]$Entry['givenname']
        Surname              = [string]$Entry['sn']
        Mail                 = [string]$Entry['mail']
        ProxyAddresses       = [string[]]@($Entry['proxyaddresses'] | Where-Object { $null -ne $_ })
        ObjectGUID           = [guid]::new([byte[]]$Entry['objectguid'])
        ConsistencyGuidBytes = if ($Entry['ms-ds-consistencyguid']) { , [byte[]]$Entry['ms-ds-consistencyguid'] } else { $null }
        ObjectSID            = [Security.Principal.SecurityIdentifier]::new([byte[]]$Entry['objectsid'], 0).Value
        Enabled              = [bool](-not ([int]$Entry['useraccountcontrol'] -band 2))
        DomainDNSRoot        = [string]$DomainInfo.DNSRoot
        Server               = [string]$DomainInfo.Server
        PasswordLastSetUtc    = $passwordTime
        PasswordLastSetState  = $passwordState
        PasswordMustChangeAtNextLogon = $mustChange
        MsExchRecipientTypeDetails = ConvertTo-NSPADOptionalInt64 -Value $Entry['msexchrecipienttypedetails']
    }
}
