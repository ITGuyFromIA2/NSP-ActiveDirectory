function Get-NSPADUser {
    <#
    .SYNOPSIS
        Reads typed user identities through paged LDAP without RSAT or AD Web Services.
    .DESCRIPTION
        Identity is an exact sAMAccountName. Filter is an assertion value searched across
        sAMAccountName, UPN, displayName, mail and proxyAddresses; only asterisks are wildcards.
        All enumerates users. Every mode uses paging (500 by default).

        DomainInfo pins a previously selected domain/DC. Server discovers a domain; when both
        are given, the server must belong to that domain. SearchBase must be within that domain.
        A domain search does not follow referrals.

        Forest is a separate scope, requires a seed Server and cannot take DomainInfo or
        SearchBase. It discovers active domain naming contexts in that forest and reads each
        over LDAP using its own DC. Identical sAMAccountNames in different domains are returned
        separately. Directory errors terminate; discard partial output after a failed inventory.
        Visibility depends on directory permissions, including access to all domain crossRefs.

        ConsistencyGuidBytes contains raw bytes or null when absent/unreadable; null does not
        establish a source-anchor strategy. No directory writes or account changes occur.
    .PARAMETER Identity
        Exact sAMAccountName, with LDAP metacharacters treated literally.
    .PARAMETER Filter
        Wildcard assertion value, not a raw LDAP filter. Only * is a wildcard.
    .PARAMETER All
        Read all user objects in the chosen scope.
    .PARAMETER DomainInfo
        Domain and DC returned by Get-NSPADDomainInfo.
    .PARAMETER SearchBase
        Domain DN or an OU/container DN within that domain.
    .PARAMETER Server
        Domain server, or required forest seed DC. Global-catalog ports are not supported.
    .PARAMETER Forest
        Explicitly enumerate every active domain in the seed DC's forest.
    .PARAMETER PageSize
        LDAP page size, from 1 to 1000; defaults to 500. Does not limit the total result count.
    .EXAMPLE
        Get-NSPADUser -Identity 'one' -DomainInfo (Get-NSPADDomainInfo -Server 'dc01.contoso.example')
    .EXAMPLE
        Get-NSPADUser -Filter '*example*' -Server 'dc01.contoso.example'
    .EXAMPLE
        Get-NSPADUser -All -SearchBase 'OU=People,DC=contoso,DC=example' -Server 'dc01.contoso.example'
    .EXAMPLE
        Get-NSPADUser -All -Forest -Server 'dc01.contoso.example'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Identity')]
    [OutputType('NSP.ActiveDirectory.User')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Identity')]
        [Parameter(Mandatory, ParameterSetName = 'ForestIdentity')]
        [ValidateNotNullOrEmpty()][string]$Identity,
        [Parameter(Mandatory, ParameterSetName = 'Filter')]
        [Parameter(Mandatory, ParameterSetName = 'ForestFilter')]
        [ValidateNotNullOrEmpty()][string]$Filter,
        [Parameter(Mandatory, ParameterSetName = 'All')]
        [Parameter(Mandatory, ParameterSetName = 'ForestAll')]
        [switch]$All,
        [Parameter(ParameterSetName = 'Identity')]
        [Parameter(ParameterSetName = 'Filter')]
        [Parameter(ParameterSetName = 'All')]
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo,
        [Parameter(ParameterSetName = 'Identity')]
        [Parameter(ParameterSetName = 'Filter')]
        [Parameter(ParameterSetName = 'All')]
        [ValidateNotNullOrEmpty()][string]$SearchBase,
        [Parameter(ParameterSetName = 'Identity')]
        [Parameter(ParameterSetName = 'Filter')]
        [Parameter(ParameterSetName = 'All')]
        [Parameter(Mandatory, ParameterSetName = 'ForestIdentity')]
        [Parameter(Mandatory, ParameterSetName = 'ForestFilter')]
        [Parameter(Mandatory, ParameterSetName = 'ForestAll')]
        [ValidateNotNullOrEmpty()][string]$Server,
        [Parameter(Mandatory, ParameterSetName = 'ForestIdentity')]
        [Parameter(Mandatory, ParameterSetName = 'ForestFilter')]
        [Parameter(Mandatory, ParameterSetName = 'ForestAll')]
        [switch]$Forest,
        [ValidateRange(1, 1000)][int]$PageSize = 500
    )
    $ErrorActionPreference = 'Stop'
    if ($PSBoundParameters.ContainsKey('All') -and -not $All) { throw '-All must be true.' }
    if ($PSBoundParameters.ContainsKey('Forest') -and -not $Forest) { throw '-Forest must be true.' }
    if ($Server -match '[:/\\]') { throw 'Server must be a DC or domain DNS name, without a protocol or port.' }

    $query = '(&(objectCategory=person)(objectClass=user)'
    if ($PSBoundParameters.ContainsKey('Identity')) {
        $value = ConvertTo-NSPADLdapFilterValue -Value $Identity
        $query += "(sAMAccountName=$value)"
    } elseif ($PSBoundParameters.ContainsKey('Filter')) {
        $value = ConvertTo-NSPADLdapFilterValue -Value $Filter -AllowWildcard
        $query += '(|' + ((@('sAMAccountName','userPrincipalName','displayName','mail','proxyAddresses') | ForEach-Object { "($_=$value)" }) -join '') + ')'
    }
    $query += ')'

    $domains = if ($Forest) {
        @(Get-NSPADForestDomainInfo -Server $Server -PageSize $PageSize)
    } else {
        if ($Server -or -not $DomainInfo) {
            $selected = Get-NSPADDomainInfo -Server $Server
            if ($DomainInfo -and ($DomainInfo.DistinguishedName -ne $selected.DistinguishedName -or $DomainInfo.DNSRoot -ne $selected.DNSRoot)) {
                throw 'Server resolves a different domain than DomainInfo.'
            }
            $DomainInfo = $selected
        }
        @($DomainInfo)
    }
    foreach ($domain in $domains) {
        if (-not $domain.Server -or -not $domain.DistinguishedName -or -not $domain.DNSRoot) {
            throw 'DomainInfo must contain Server, DistinguishedName and DNSRoot.'
        }
        $base = if ($SearchBase) { $SearchBase } else { [string]$domain.DistinguishedName }
        $domainDn = [string]$domain.DistinguishedName
        if ($base -ne $domainDn -and -not $base.EndsWith(",$domainDn", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SearchBase must be within the selected domain naming context.'
        }
        $entries = @(Read-NSPADLdap -Server $domain.Server -SearchBase $base -Filter $query -PageSize $PageSize -Property distinguishedName,sAMAccountName,userPrincipalName,displayName,givenName,sn,mail,proxyAddresses,objectGUID,mS-DS-ConsistencyGuid,objectSid,userAccountControl -MultiValued proxyAddresses)
        if ($PSBoundParameters.ContainsKey('Identity') -and $entries.Count -gt 1) { throw 'LDAP returned multiple users for an exact identity in one domain.' }
        foreach ($entry in $entries) { ConvertTo-NSPADUser -Entry $entry -DomainInfo $domain }
    }
}
