function Compare-NSPADGroupMembership {
    <#
    .SYNOPSIS
        Compares the members of two AD groups: one row per account, saying whether it is in the
        reference group, the difference group, or both.
    .DESCRIPTION
        Matches on sAMAccountName. -Recursive expands nested groups first. Read-only. Typical use:
        checking an old VPN group against its replacement before switching over, then feeding the
        ReferenceOnly rows to Add-ADGroupMember.
    .PARAMETER ReferenceGroup
        Group identity (name, sAMAccountName, DN or GUID).
    .PARAMETER DifferenceGroup
        The group to compare it with.
    .PARAMETER Recursive
        Include members of nested groups.
    .EXAMPLE
        Compare-NSPADGroupMembership -ReferenceGroup 'SSLVPN Users' -DifferenceGroup 'IKEv2_InternalUsers' |
            Where-Object Side -eq 'ReferenceOnly'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ReferenceGroup,
        [Parameter(Mandatory)][string]$DifferenceGroup,
        [switch]$Recursive
    )
    Assert-NSPADCommand Get-ADGroupMember -ModuleHint 'ActiveDirectory (RSAT)'
    $ref = @(Get-ADGroupMember -Identity $ReferenceGroup -Recursive:$Recursive -ErrorAction Stop)
    $dif = @(Get-ADGroupMember -Identity $DifferenceGroup -Recursive:$Recursive -ErrorAction Stop)
    $byName = [ordered]@{}
    foreach ($m in $ref) { $byName["$($m.SamAccountName)"] = [pscustomobject]@{ SamAccountName = "$($m.SamAccountName)"; Name = "$($m.Name)"; ObjectClass = "$($m.objectClass)"; InReference = $true; InDifference = $false } }
    foreach ($m in $dif) {
        $key = "$($m.SamAccountName)"
        if ($byName.Contains($key)) { $byName[$key].InDifference = $true }
        else { $byName[$key] = [pscustomobject]@{ SamAccountName = $key; Name = "$($m.Name)"; ObjectClass = "$($m.objectClass)"; InReference = $false; InDifference = $true } }
    }
    foreach ($row in $byName.Values) {
        $side = if ($row.InReference -and $row.InDifference) { 'Both' } elseif ($row.InReference) { 'ReferenceOnly' } else { 'DifferenceOnly' }
        $row | Add-Member -NotePropertyName Side -NotePropertyValue $side -PassThru |
            Add-Member -TypeName 'NSP.ActiveDirectory.GroupComparison' -PassThru
    }
}
