function Copy-NSPADUserGroupMembership {
    <#
    .SYNOPSIS
        Adds -TargetUser to every group -SourceUser is a direct member of (apart from the primary
        group and any -ExcludeGroup). Returns one row per group: Added, AlreadyMember or Skipped.
    .DESCRIPTION
        Supports -WhatIf / -Confirm. Groups the target is already in are left alone. Nothing is
        removed from the target.
    .PARAMETER SourceUser
        The user to copy group memberships from.
    .PARAMETER TargetUser
        The user to add to those groups.
    .PARAMETER ExcludeGroup
        Group names (or sAMAccountNames) not to copy.
    .EXAMPLE
        Copy-NSPADUserGroupMembership -SourceUser jdoe -TargetUser asmith -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SourceUser,
        [Parameter(Mandatory)][string]$TargetUser,
        [string[]]$ExcludeGroup = @()
    )
    Assert-NSPADCommand Get-ADPrincipalGroupMembership -ModuleHint 'ActiveDirectory (RSAT)'
    $source = Get-ADUser -Identity $SourceUser -Properties PrimaryGroup -ErrorAction Stop
    $target = Get-ADUser -Identity $TargetUser -Properties PrimaryGroup -ErrorAction Stop
    $have = @(Get-ADPrincipalGroupMembership -Identity $target -ErrorAction Stop | ForEach-Object { "$($_.DistinguishedName)" })
    foreach ($g in @(Get-ADPrincipalGroupMembership -Identity $source -ErrorAction Stop)) {
        $status = if ("$($g.DistinguishedName)" -eq "$($source.PrimaryGroup)" -or $ExcludeGroup -contains "$($g.Name)" -or $ExcludeGroup -contains "$($g.SamAccountName)") { 'Skipped' }
                  elseif ($have -contains "$($g.DistinguishedName)") { 'AlreadyMember' }
                  elseif ($PSCmdlet.ShouldProcess("$($g.Name)", "Add $($target.SamAccountName)")) {
                      Add-ADGroupMember -Identity $g -Members $target -ErrorAction Stop
                      'Added'
                  } else { 'WhatIf' }
        [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.MembershipChange'; User = "$($target.SamAccountName)"; Group = "$($g.Name)"; GroupDN = "$($g.DistinguishedName)"; Result = $status }
    }
}
