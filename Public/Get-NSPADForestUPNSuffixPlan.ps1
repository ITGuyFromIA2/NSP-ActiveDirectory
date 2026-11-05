function Get-NSPADForestUPNSuffixPlan {
    <#
    .SYNOPSIS
        Plans one additive forest UPN suffix from supplied forest facts without directory access.
    .DESCRIPTION
        Domain DNS roots already qualify, as do existing alternate suffixes. A missing name
        produces an additive plan. No forest, user, Microsoft 365 or DNS change occurs here.
    .EXAMPLE
        Get-NSPADForestUPNSuffixPlan -ForestInfo $forest -Suffix new.example
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.ForestUPNSuffixPlan')]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$ForestInfo,
        [Parameter(Mandatory)][ValidateScript({ Test-NSPADAddressDomain $_ })][string]$Suffix
    )
    if (-not $ForestInfo.ForestDNSRoot -or -not $ForestInfo.RootDomainDN -or -not $ForestInfo.ConfigurationDN -or
        -not $ForestInfo.Server -or [guid]$ForestInfo.ConfigurationGUID -eq [guid]::Empty -or
        $ForestInfo.DomainDNSRoots -inotcontains $ForestInfo.ForestDNSRoot -or
        $ForestInfo.ConfigurationDN -ine "CN=Configuration,$($ForestInfo.RootDomainDN)") {
        throw 'ForestInfo requires consistent forest identity, configuration GUID, domain roots and server.'
    }
    $suffixValue = $Suffix.ToLowerInvariant()
    $before = [string[]]@($ForestInfo.AlternateUPNSuffixes | Sort-Object -Unique)
    $available = [string[]]@(@($ForestInfo.DomainDNSRoots) + @($before) | Sort-Object -Unique)
    $kind = if ($ForestInfo.DomainDNSRoots -icontains $suffixValue) { 'Domain' }
            elseif ($before -icontains $suffixValue) { 'Alternate' } else { 'Missing' }
    [pscustomobject]@{
        PSTypeName='NSP.ActiveDirectory.ForestUPNSuffixPlan'
        ForestDNSRoot=[string]$ForestInfo.ForestDNSRoot; RootDomainDN=[string]$ForestInfo.RootDomainDN
        ConfigurationDN=[string]$ForestInfo.ConfigurationDN; ConfigurationGUID=[guid]$ForestInfo.ConfigurationGUID
        Server=[string]$ForestInfo.Server; Suffix=$suffixValue; Availability=$kind
        DomainDNSRoots=[string[]]@($ForestInfo.DomainDNSRoots | Sort-Object -Unique)
        Before=$before
        After=[string[]]@(@($before) + $(if ($kind -eq 'Missing') { $suffixValue }) | Where-Object { $_ } | Sort-Object -Unique)
        Changed=($available -inotcontains $suffixValue); Blocked=$false; Reasons=[string[]]@()
    }
}
