function Remove-NSPADDisabledUserGroupMembership {
    <#
    .SYNOPSIS
        Parks disabled user accounts: adds each to a holding group, makes that their primary group,
        and removes them from every other group. Returns one row per change.
    .DESCRIPTION
        For each disabled user (optionally only under -SearchBase):
          1. add it to -HoldingGroup (which must exist) if it isn't a member;
          2. set its primary group to -HoldingGroup (so it can leave Domain Users);
          3. remove it from every other group it is a direct member of.
        ConfirmImpact is High - expect a confirmation prompt per change unless -Confirm:$false;
        -WhatIf shows everything it would do. Rows: User, Action (AddToHoldingGroup /
        SetPrimaryGroup / RemoveFromGroup), Group, Result (Done / AlreadyDone / WhatIf / Failed: ...).
        One failed change doesn't stop the rest.
    .PARAMETER HoldingGroup
        The group disabled accounts are parked in, e.g. 'DisabledUsers'.
    .PARAMETER SearchBase
        Only users under this OU / container.
    .PARAMETER KeepGroup
        Groups to leave the user in (name or sAMAccountName), besides the holding group.
    .EXAMPLE
        Remove-NSPADDisabledUserGroupMembership -HoldingGroup DisabledUsers -WhatIf
    .EXAMPLE
        Remove-NSPADDisabledUserGroupMembership -HoldingGroup DisabledUsers -Confirm:$false |
            Export-Csv C:\Admin\DisabledUserCleanup.csv -NoTypeInformation
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$HoldingGroup,
        [string]$SearchBase,
        [string[]]$KeepGroup = @()
    )
    Assert-NSPADCommand Get-ADPrincipalGroupMembership -ModuleHint 'ActiveDirectory (RSAT)'
    $holding = Get-ADGroup -Identity $HoldingGroup -Properties primaryGroupToken -ErrorAction Stop
    $holdingMembers = @(Get-ADGroupMember -Identity $holding -ErrorAction Stop | ForEach-Object { "$($_.DistinguishedName)" })
    $query = @{ Filter = 'Enabled -eq $false'; Properties = @('PrimaryGroupID'); ErrorAction = 'Stop' }
    if ($SearchBase) { $query.SearchBase = $SearchBase }

    function Step($user, $action, $group, [scriptblock]$change, [bool]$done) {
        $result = if ($done) { 'AlreadyDone' }
                  elseif (-not $PSCmdlet.ShouldProcess("$($user.SamAccountName)", "$action $group")) { 'WhatIf' }
                  else { try { & $change; 'Done' } catch { "Failed: $($_.Exception.Message)" } }
        [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.MembershipChange'; User = "$($user.SamAccountName)"; Action = $action; Group = $group; Result = $result }
    }

    foreach ($user in @(Get-ADUser @query)) {
        Step $user 'AddToHoldingGroup' "$($holding.Name)" { Add-ADGroupMember -Identity $holding -Members $user -ErrorAction Stop } ($holdingMembers -contains "$($user.DistinguishedName)")
        Step $user 'SetPrimaryGroup' "$($holding.Name)" { Set-ADUser -Identity $user -Replace @{ primaryGroupID = $holding.primaryGroupToken } -ErrorAction Stop } ("$($user.PrimaryGroupID)" -eq "$($holding.primaryGroupToken)")
        foreach ($g in @(Get-ADPrincipalGroupMembership -Identity $user -ErrorAction Stop)) {
            if ("$($g.DistinguishedName)" -eq "$($holding.DistinguishedName)") { continue }
            if ($KeepGroup -contains "$($g.Name)" -or $KeepGroup -contains "$($g.SamAccountName)") { continue }
            $grp = $g
            Step $user 'RemoveFromGroup' "$($g.Name)" { Remove-ADGroupMember -Identity $grp -Members $user -Confirm:$false -ErrorAction Stop } $false
        }
    }
}
