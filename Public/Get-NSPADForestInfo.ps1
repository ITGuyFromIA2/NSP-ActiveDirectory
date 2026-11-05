function Get-NSPADForestInfo {
    <#
    .SYNOPSIS
        Reads forest identity, domain DNS roots and alternate UPN suffixes over LDAP.
    .DESCRIPTION
        No RSAT or ADWS required. Domain DNS roots are valid implicit suffixes; uPNSuffixes
        on the Partitions container supplies alternate names. AvailableUPNSuffixes is their
        distinct union. Visibility is bounded by directory permissions: a missing optional
        attribute cannot be distinguished from one hidden by an ACL. No changes occur.
    .EXAMPLE
        Get-NSPADForestInfo -Server dc01.contoso.example
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.ForestInfo')]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Server)
    $ErrorActionPreference = 'Stop'
    if ($Server -match '[:/\\]') { throw 'Server must be a DC DNS name without protocol or port.' }
    $dc = Find-NSPADDomainController -Server $Server
    $root = Read-NSPADRootDse -Server $dc
    $rootDn = [string]$root['rootdomainnamingcontext']
    $configDn = [string]$root['configurationnamingcontext']
    if (-not $rootDn -or $configDn -ine "CN=Configuration,$rootDn") { throw 'RootDSE forest naming contexts are missing or inconsistent.' }
    $configuration = @(Read-NSPADLdap -Server $dc -SearchBase $configDn -Scope Base -Property objectGUID)
    $partitions = @(Read-NSPADLdap -Server $dc -SearchBase "CN=Partitions,$configDn" -Scope Base -Property uPNSuffixes -MultiValued uPNSuffixes)
    if ($configuration.Count -ne 1 -or -not $configuration[0]['objectguid'] -or $partitions.Count -ne 1) {
        throw 'Required forest configuration or Partitions object could not be read.'
    }
    $configGuid = [guid]::new([byte[]]$configuration[0]['objectguid'])
    if ($configGuid -eq [guid]::Empty) { throw 'Forest configuration GUID is empty.' }
    $domains = @(Get-NSPADForestDomainInfo -Server $dc)
    $forestRoot = @($domains | Where-Object DistinguishedName -IEQ $rootDn)
    if ($forestRoot.Count -ne 1) { throw 'The forest root domain is absent or ambiguous.' }
    foreach ($domain in $domains) {
        if ($domain.ConfigurationDN -ine $configDn -or -not (Test-NSPADAddressDomain $domain.DNSRoot)) {
            throw 'Domain discovery returned inconsistent forest facts.'
        }
    }
    $dnsRoots = [string[]]@($domains | ForEach-Object { $_.DNSRoot.ToLowerInvariant() } | Sort-Object -Unique)
    $alternates = [string[]]@($partitions[0]['upnsuffixes'] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    [pscustomobject]@{
        PSTypeName='NSP.ActiveDirectory.ForestInfo'; ForestDNSRoot=[string]$forestRoot[0].DNSRoot
        RootDomainDN=$rootDn; ConfigurationDN=$configDn; ConfigurationGUID=$configGuid; Server=[string]$dc
        DomainDNSRoots=$dnsRoots; AlternateUPNSuffixes=$alternates
        AvailableUPNSuffixes=[string[]]@(@($dnsRoots) + @($alternates) | Sort-Object -Unique)
    }
}
