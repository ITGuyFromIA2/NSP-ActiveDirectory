function Get-NSPADWmiFilter {
    <#
    .SYNOPSIS
        The WMI filters in this domain: Name, Description, Query (one or more WQL strings), Id, DN.
    .DESCRIPTION
        Read straight from AD (msWMI-Som objects) - no third-party module. -Name filters by name
        (wildcards allowed).
    .PARAMETER Name
        Filter name, wildcards allowed. Default: all.
    .EXAMPLE
        Get-NSPADWmiFilter -Name 'NSP_AT*' | Format-Table Name, Query
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Name = '*')
    $domain = Get-ADDomain -ErrorAction Stop
    Get-NSPADWmiSomEntry -DomainDN "$($domain.DistinguishedName)" | Where-Object { $_.Name -like $Name } |
        ForEach-Object { $_.PSObject.TypeNames.Insert(0, 'NSP.ActiveDirectory.WmiFilter'); $_ }
}
