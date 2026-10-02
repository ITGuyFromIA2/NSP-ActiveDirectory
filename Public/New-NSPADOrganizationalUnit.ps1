function New-NSPADOrganizationalUnit {
    <#
    .SYNOPSIS
        Creates OU -Name directly under -Path unless it already exists, and returns its DN either
        way. Idempotent; dry-run aware (Invoke-NSPStep).
    .EXAMPLE
        New-NSPADOrganizationalUnit -Name VPNGroups -Path 'OU=Clients,DC=example,DC=com'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description
    )
    if (-not $PSCmdlet.ShouldProcess("OU=$Name,$Path", 'Create the organizational unit if it is missing')) { return "OU=$Name,$Path" }
    Use-NSPADDependency
    Assert-NSPADCommand Get-ADOrganizationalUnit
    $dn = "OU=$Name,$Path"
    $existing = Get-ADOrganizationalUnit -Identity $dn -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  OU '$dn' already exists - skipping create." -ForegroundColor Gray
        return $dn
    }
    Invoke-NSPStep -Description "Create OU '$Name' under $Path" `
        -Commands @("New-ADOrganizationalUnit -Name '$Name' -Path '$Path'") `
        -Action {
            $params = @{ Name = $Name; Path = $Path }
            if ($Description) { $params['Description'] = $Description }
            New-ADOrganizationalUnit @params
        } | Out-Null
    return $dn
}
