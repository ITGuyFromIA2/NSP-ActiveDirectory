function New-NSPADVpnGroupScaffold {
    <#
    .SYNOPSIS
        Creates what a Get-NSPADScaffoldPlan plan describes: the VPNGroups and FWRules OUs, the main
        VPN group and every purpose group. Idempotent (re-running creates only what is missing);
        dry-run aware.
    .EXAMPLE
        Get-NSPADScaffoldPlan -ClientAnswers $answers -BaseOU $ou | New-NSPADVpnGroupScaffold
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Plan)
    process {
        New-NSPADOrganizationalUnit -Name 'VPNGroups' -Path $Plan.BaseOU -Description 'VPN group scaffold (NSP.ActiveDirectory)' | Out-Null
        New-NSPADGroup -Name $Plan.MainGroupName -Path $Plan.VpnGroupsOU -Description 'Main VPN user group (NSP.ActiveDirectory)' | Out-Null
        New-NSPADOrganizationalUnit -Name 'FWRules' -Path $Plan.VpnGroupsOU -Description 'VPNFW purpose groups (NSP.ActiveDirectory)' | Out-Null
        foreach ($pg in $Plan.PurposeGroups) {
            New-NSPADGroup -Name $pg.Name -Path $Plan.FwRulesOU -Description "VPNFW purpose group - $($pg.Key) (NSP.ActiveDirectory)" | Out-Null
        }
    }
}
