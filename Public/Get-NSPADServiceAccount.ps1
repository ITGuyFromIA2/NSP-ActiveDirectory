function Get-NSPADServiceAccount {
    <#
    .SYNOPSIS
        A group managed service account (gMSA) and who may use it, over LDAP - no AD module or AD Web Services.
    .DESCRIPTION
        Returns the account's DN, DNS host name, enabled state, SID, its logon name for scheduled
        tasks and services (DOMAIN\name$), the password change interval, and AllowedPrincipals:
        the computers and groups allowed to retrieve its password (msDS-GroupMSAMembership).
        Returns nothing when there is no such gMSA.
    .EXAMPLE
        Get-NSPADServiceAccount -Name 'svc_transfer'
    .EXAMPLE
        (Get-NSPADServiceAccount -Name 'svc_transfer').AllowedPrincipals
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.ServiceAccount')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Name,
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo
    )

    begin { if (-not $DomainInfo) { $DomainInfo = Get-NSPADDomainInfo } }
    process {
        $bare = $Name.TrimEnd('$')
        $escaped = "$bare`$" -replace '([\\*()])', '\$1'
        $props = 'distinguishedName', 'dNSHostName', 'userAccountControl', 'objectSid', 'msDS-GroupMSAMembership', 'msDS-ManagedPasswordInterval', 'description'
        foreach ($entry in @(Read-NSPADLdap -Server $DomainInfo.Server -SearchBase $DomainInfo.DistinguishedName -Filter "(&(objectClass=msDS-GroupManagedServiceAccount)(sAMAccountName=$escaped))" -Property $props)) {
            [pscustomobject]@{
                PSTypeName           = 'NSP.ActiveDirectory.ServiceAccount'
                Name                 = $bare
                Logon                = "$($DomainInfo.NetBIOSName)\$bare`$"
                DistinguishedName    = [string]$entry['distinguishedname']
                DNSHostName          = [string]$entry['dnshostname']
                Enabled              = -not ([int]$entry['useraccountcontrol'] -band 2)
                SID                  = if ($entry['objectsid']) { [Security.Principal.SecurityIdentifier]::new([byte[]]$entry['objectsid'], 0).Value } else { $null }
                PasswordIntervalDays = if ($entry['msds-managedpasswordinterval']) { [int]$entry['msds-managedpasswordinterval'] } else { $null }
                AllowedPrincipals    = @(ConvertFrom-NSPADGmsaMembership -Descriptor ([byte[]]$entry['msds-groupmsamembership']))
                Description          = [string]$entry['description']
            }
        }
    }
}
