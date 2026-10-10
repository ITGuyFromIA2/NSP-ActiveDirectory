function Get-NSPADComputer {
    <#
    .SYNOPSIS
        A computer account by name - DN, DNS host name, SID - over LDAP, without the AD module or AD Web Services.
    .DESCRIPTION
        Matches sAMAccountName (<Name>$). Returns nothing when there is no such computer. Reads from
        -DomainInfo's DC (from Get-NSPADDomainInfo) when given, else locates one.
    .EXAMPLE
        Get-NSPADComputer -Name $env:COMPUTERNAME
    .EXAMPLE
        $domain = Get-NSPADDomainInfo; Get-NSPADComputer -Name 'APP01' -DomainInfo $domain | Select-Object DistinguishedName
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.Computer')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Name,
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo
    )

    begin { if (-not $DomainInfo) { $DomainInfo = Get-NSPADDomainInfo } }
    process {
        $account = "$($Name.TrimEnd('$'))`$"
        $escaped = $account -replace '([\\*()])', '\$1'
        $found = @(Read-NSPADLdap -Server $DomainInfo.Server -SearchBase $DomainInfo.DistinguishedName -Filter "(&(objectCategory=computer)(sAMAccountName=$escaped))" -Property 'distinguishedName', 'dNSHostName', 'objectSid')
        foreach ($entry in $found) {
            [pscustomobject]@{
                PSTypeName        = 'NSP.ActiveDirectory.Computer'
                Name              = $Name.TrimEnd('$')
                DistinguishedName = [string]$entry['distinguishedname']
                DNSHostName       = [string]$entry['dnshostname']
                SID               = if ($entry['objectsid']) { [Security.Principal.SecurityIdentifier]::new([byte[]]$entry['objectsid'], 0).Value } else { $null }
            }
        }
    }
}
