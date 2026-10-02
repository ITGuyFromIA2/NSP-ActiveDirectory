function Get-NSPADScaffoldPlan {
    <#
    .SYNOPSIS
        Builds the VPN group/OU scaffold plan under -BaseOU: VPNGroups\ with the main VPN group, and
        VPNGroups\FWRules\ with the VPNFW purpose groups. Pure - creates nothing.
    .DESCRIPTION
        Uses the client's answers when given: Auth_UserGroup_Value (the real AD group - not
        Auth_UserGroup_Name, the FortiGate-side label), each VPNFW_*_GroupName, and VPNFW_DNS_Mode
        (the DNS group is only planned when Universal). Anything missing or blank falls back to the
        generic defaults (IKEv2_InternalUsers and Get-NSPADPurposeGroupDefault).
    .PARAMETER ClientAnswers
        The client's answers (saved AD answers, or a ClientAnswers file), or $null.
    .PARAMETER BaseOU
        DN of the OU everything is created under.
    .EXAMPLE
        Get-NSPADScaffoldPlan -ClientAnswers (Get-NSPToolAnswers -Tool AD) -BaseOU 'OU=Example,DC=example,DC=com'
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$ClientAnswers,
        [Parameter(Mandatory)][string]$BaseOU
    )

    $mainGroupName = Get-NSPADAnswerValue -Answers $ClientAnswers -Field 'Auth_UserGroup_Value'
    if (-not $mainGroupName) { $mainGroupName = 'IKEv2_InternalUsers' }
    $dnsMode = Get-NSPADAnswerValue -Answers $ClientAnswers -Field 'VPNFW_DNS_Mode'
    if (-not $dnsMode) { $dnsMode = 'Universal' }

    $purposeGroups = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($def in Get-NSPADPurposeGroupDefault) {
        if (-not $def.Always -and $def.Key -eq 'DNS' -and $dnsMode -ne 'Universal') { continue }
        $name = Get-NSPADAnswerValue -Answers $ClientAnswers -Field $def.AnswersField
        if (-not $name) { $name = $def.DefaultName }
        $purposeGroups.Add([pscustomobject]@{ Key = $def.Key; Name = $name })
    }

    return [pscustomobject]@{
        BaseOU        = $BaseOU
        VpnGroupsOU   = "OU=VPNGroups,$BaseOU"
        FwRulesOU     = "OU=FWRules,OU=VPNGroups,$BaseOU"
        MainGroupName = $mainGroupName
        PurposeGroups = @($purposeGroups)
    }
}
