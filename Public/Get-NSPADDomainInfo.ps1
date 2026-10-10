function Get-NSPADDomainInfo {
    <#
    .SYNOPSIS
        This computer's domain - DNS and NetBIOS names, DN, PDC emulator - read over LDAP from a responsive DC, without the AD module or AD Web Services.
    .DESCRIPTION
        For tools that need a few domain facts and shouldn't fail because RSAT is missing, AD Web
        Services is broken, or one DC is sick: Get-ADDomain needs all three to be fine.

        Without -Server the DC locator picks a DC (forcing rediscovery, so a DC that went bad since
        the last lookup isn't reused). -Server pins one. The DC that answered is returned as
        Server; pass it on (Get-NSPADComputer -DomainInfo, or -Server to AD cmdlets) to keep later
        reads on the same DC. PDCEmulator is $null if its server object can't be read.
    .EXAMPLE
        Get-NSPADDomainInfo
    .EXAMPLE
        $domain = Get-NSPADDomainInfo -Server 'dc02.contoso.example'
        "$($domain.NetBIOSName)\svc_job`$"
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.DomainInfo')]
    param([string]$Server)

    $dc = Find-NSPADDomainController -Server $Server
    $rootDse = Read-NSPADRootDse -Server $dc
    $domainDn = [string]$rootDse['defaultnamingcontext']
    $configDn = [string]$rootDse['configurationnamingcontext']
    $crossRef = @(Read-NSPADLdap -Server $dc -SearchBase "CN=Partitions,$configDn" -Filter "(&(objectClass=crossRef)(nCName=$domainDn))" -Property 'nETBIOSName', 'dnsRoot')[0]

    # fSMORoleOwner on the domain object is the PDC's 'NTDS Settings' DN; its parent is the server object.
    $pdc = $null
    try {
        $owner = [string]@(Read-NSPADLdap -Server $dc -SearchBase $domainDn -Scope Base -Property 'fSMORoleOwner')[0]['fsmoroleowner']
        $serverDn = $owner.Substring($owner.IndexOf(',') + 1)
        $pdc = [string]@(Read-NSPADLdap -Server $dc -SearchBase $serverDn -Scope Base -Property 'dNSHostName')[0]['dnshostname']
    } catch { Write-Verbose "PDC emulator not resolved: $($_.Exception.Message)" }

    [pscustomobject]@{
        PSTypeName        = 'NSP.ActiveDirectory.DomainInfo'
        DNSRoot           = [string]$crossRef['dnsroot']
        NetBIOSName       = [string]$crossRef['netbiosname']
        DistinguishedName = $domainDn
        ConfigurationDN   = $configDn
        PDCEmulator       = if ($pdc) { $pdc } else { $null }
        Server            = $dc
    }
}
