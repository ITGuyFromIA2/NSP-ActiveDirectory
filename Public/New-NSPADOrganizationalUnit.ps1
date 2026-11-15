function New-NSPADOrganizationalUnit {
    <#
    .SYNOPSIS
        Creates OU -Name directly under -Path unless it already exists, and returns its DN either
        way. Idempotent; dry-run aware (Invoke-NSPStep).
    .PARAMETER Server
        A domain controller. The existence check and the create both go to it. Default: the AD
        module picks one for each cmdlet.
        A blank value (empty or whitespace only) is refused before anything is read or written.
    .PARAMETER AsResult
        Return an NSP.ActiveDirectory.WriteOutcome instead of the DN (see "Write outcomes" in
        the README). An expected directory failure comes back as Outcome Failed with an
        ErrorCode instead of an exception, so CHECK Outcome. It is the module's own observation,
        not management-plane verification. AlreadyPresent also requires a planned -Description to match.
        The outcome carries no error text, but a failed write step still prints the directory's own
        error on the host (NSP.Toolkit's Invoke-NSPStep), so a transcript of a failed write can hold it.
    .EXAMPLE
        New-NSPADOrganizationalUnit -Name VPNGroups -Path 'OU=Clients,DC=example,DC=com'
    .EXAMPLE
        New-NSPADOrganizationalUnit -Name VPNGroups -Path 'OU=Clients,DC=example,DC=com' -Server 'dc01.example.com'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    [OutputType('NSP.ActiveDirectory.WriteOutcome')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description,
        [ValidateNotNullOrEmpty()][ValidateScript({ Test-NSPADServerArgument $_ })][string]$Server,
        [switch]$AsResult
    )
    if ($AsResult) { return (Invoke-NSPADOrganizationalUnitOutcome -Cmdlet $PSCmdlet -Name $Name -Path $Path -Description $Description -Server $Server) }
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
