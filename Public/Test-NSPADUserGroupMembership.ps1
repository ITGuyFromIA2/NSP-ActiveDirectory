function Test-NSPADUserGroupMembership {
    <#
    .SYNOPSIS
        Whether a user is a member of each of the given groups - one row per group.
    .DESCRIPTION
        Read-only. Direct membership by default; -Recursive also counts membership through nested
        groups. A group that can't be found is reported (Found = $false), not thrown.
    .PARAMETER User
        The user's sAMAccountName (or any identity Get-ADUser accepts).
    .PARAMETER Group
        One or more group identities.
    .PARAMETER Recursive
        Count membership through nested groups.
    .EXAMPLE
        Test-NSPADUserGroupMembership -User jdoe -Group 'VPN Users', 'Remote Desktop Users' | Format-Table
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string[]]$Group,
        [switch]$Recursive
    )
    Assert-NSPADCommand Get-ADGroupMember -ModuleHint 'ActiveDirectory (RSAT)'
    $sam = "$((Get-ADUser -Identity $User -ErrorAction Stop).SamAccountName)"
    foreach ($g in $Group) {
        $members = $null
        $found = $true
        try { $members = @(Get-ADGroupMember -Identity $g -Recursive:$Recursive -ErrorAction Stop) } catch { $found = $false }
        [pscustomobject]@{
            PSTypeName = 'NSP.ActiveDirectory.MembershipTest'
            User       = $sam
            Group      = $g
            Found      = $found
            IsMember   = [bool]($found -and @($members | Where-Object { "$($_.SamAccountName)" -eq $sam }).Count)
        }
    }
}
