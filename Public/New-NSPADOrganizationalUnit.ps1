function New-NSPADOrganizationalUnit {
    <#
    .SYNOPSIS
        Creates OU -Name directly under -Path unless it already exists, and returns its DN either
        way. Idempotent; dry-run aware (Invoke-NSPStep).
    .PARAMETER Server
        A domain controller. The existence check and the create both go to it. Default: the AD
        module picks one for each cmdlet.
    .EXAMPLE
        New-NSPADOrganizationalUnit -Name VPNGroups -Path 'OU=Clients,DC=example,DC=com'
    .EXAMPLE
        New-NSPADOrganizationalUnit -Name VPNGroups -Path 'OU=Clients,DC=example,DC=com' -Server 'dc01.example.com'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description,
        [ValidateNotNullOrEmpty()][string]$Server
    )
    if (-not $PSCmdlet.ShouldProcess("OU=$Name,$Path", 'Create the organizational unit if it is missing')) { return "OU=$Name,$Path" }
    Use-NSPADDependency
    Assert-NSPADCommand Get-ADOrganizationalUnit
    $srv = Get-NSPADServerSplat -Server $Server
    $dn = "OU=$Name,$Path"
    $existing = Get-ADOrganizationalUnit -Identity $dn @srv -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  OU '$dn' already exists - skipping create." -ForegroundColor Gray
        return $dn
    }
    Invoke-NSPStep -Description "Create OU '$Name' under $Path" `
        -Commands @("New-ADOrganizationalUnit -Name '$Name' -Path '$Path'$(Format-NSPADServerArg $Server)") `
        -Action {
            $params = @{ Name = $Name; Path = $Path } + $srv
            if ($Description) { $params['Description'] = $Description }
            New-ADOrganizationalUnit @params
        } | Out-Null
    return $dn
}
