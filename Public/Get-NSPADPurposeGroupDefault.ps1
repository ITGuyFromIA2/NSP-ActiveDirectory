function Get-NSPADPurposeGroupDefault {
    <#
    .SYNOPSIS
        The default VPNFW purpose groups (DC comms, SMB, RDP, DNS): Key, DefaultName, AnswersField
        (the client answer that overrides the name) and Always (DNS is only created when
        VPNFW_DNS_Mode is Universal). Pure data - a new purpose group is a new row here.
    .EXAMPLE
        Get-NSPADPurposeGroupDefault
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Key = 'DCComms'; DefaultName = 'VPNFW_Internal_DCComms'; AnswersField = 'VPNFW_DCComms_GroupName'; Always = $true }
        [pscustomobject]@{ Key = 'SMB'; DefaultName = 'VPNFW_Internal_SMBComms'; AnswersField = 'VPNFW_SMB_GroupName'; Always = $true }
        [pscustomobject]@{ Key = 'RDS'; DefaultName = 'VPNFW_Internal_RDP_Network'; AnswersField = 'VPNFW_RDS_GroupName'; Always = $true }
        [pscustomobject]@{ Key = 'DNS'; DefaultName = 'VPNFW_DNS_Group'; AnswersField = 'VPNFW_DNS_GroupName'; Always = $false }
    )
}
