function Get-NSPADOrganizationalUnitChild {
    <#
    .SYNOPSIS
        Lists the OUs directly under -SearchBase (one level). Blank -SearchBase is the domain root.
        Returns SearchBase (resolved) and Children.
    .EXAMPLE
        (Get-NSPADOrganizationalUnitChild).Children | Select-Object Name, DistinguishedName
    #>
    [CmdletBinding()]
    param(
        [string]$SearchBase,
        [string]$Server,
        [System.Management.Automation.PSCredential]$Credential
    )
    Assert-NSPADCommand Get-ADOrganizationalUnit
    $adParams = @{ ErrorAction = 'Stop' }
    if ($Server) { $adParams['Server'] = $Server }
    if ($Credential) { $adParams['Credential'] = $Credential }

    $base = if ($SearchBase) { $SearchBase } else { (Get-ADDomain @adParams).DistinguishedName }
    $children = @(Get-ADOrganizationalUnit -SearchBase $base -SearchScope OneLevel -Filter * @adParams | Sort-Object -Property Name)
    return [pscustomobject]@{ SearchBase = $base; Children = $children }
}
