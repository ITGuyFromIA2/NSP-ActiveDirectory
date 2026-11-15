function New-NSPADGroup {
    <#
    .SYNOPSIS
        Creates AD group -Name in OU -Path unless a group with that sAMAccountName already exists,
        and returns its DN either way. Idempotent; dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        The existence check is by sAMAccountName (LDAP filter), not display name, so a same-named
        group in another OU is never mistaken for this one. In DRY RUN the returned DN is the
        predicted one, for planning and display only.
    .PARAMETER Server
        A domain controller. The existence check and the create both go to it. Default: the AD
        module picks one for each cmdlet.
        A blank value (empty or whitespace only) is refused before anything is read or written.
    .PARAMETER AsResult
        Return an NSP.ActiveDirectory.WriteOutcome instead of the DN. An expected directory failure
        comes back as Outcome Failed with an ErrorCode instead of an exception, so CHECK Outcome.
        A group with the same sAMAccountName but another DN, scope or category is Failed/Conflict,
        not AlreadyPresent. The module's own observation, not management-plane verification.
        The outcome carries no error text, but a failed write step still prints the directory's own
        error on the host (NSP.Toolkit's Invoke-NSPStep), so a transcript of a failed write can hold it.
    .EXAMPLE
        New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPNGroups,DC=example,DC=com' -Description 'VPN users'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    [OutputType('NSP.ActiveDirectory.WriteOutcome')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$GroupScope = 'Global',
        [ValidateSet('Security', 'Distribution')][string]$GroupCategory = 'Security',
        [string]$SamAccountName,
        [string]$Description,
        [ValidateNotNullOrEmpty()][ValidateScript({ Test-NSPADServerArgument $_ })][string]$Server,
        [switch]$AsResult
    )
    if ($AsResult) { return (Invoke-NSPADGroupOutcome -Cmdlet $PSCmdlet -Name $Name -Path $Path -GroupScope $GroupScope -GroupCategory $GroupCategory -SamAccountName $SamAccountName -Description $Description -Server $Server) }
    if (-not $PSCmdlet.ShouldProcess("CN=$Name,$Path", 'Create the group if it is missing')) { return "CN=$Name,$Path" }
    Use-NSPADDependency
    Assert-NSPADCommand Get-ADGroup
    $srv = Get-NSPADServerSplat -Server $Server
    $sam = if ($SamAccountName) { $SamAccountName } else { $Name -replace '[^A-Za-z0-9_\-]', '' }
    $existing = Get-ADGroup -LDAPFilter "(sAMAccountName=$sam)" @srv -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Group '$sam' already exists ($($existing.DistinguishedName)) - skipping create." -ForegroundColor Gray
        return $existing.DistinguishedName
    }
    $result = Invoke-NSPStep -Description "Create AD group '$Name' ($GroupScope $GroupCategory) under $Path" `
        -Commands @("New-ADGroup -Name '$Name' -SamAccountName '$sam' -GroupScope $GroupScope -GroupCategory $GroupCategory -Path '$Path'$(Format-NSPADServerArg $Server)") `
        -Action {
            $params = @{ Name = $Name; SamAccountName = $sam; GroupScope = $GroupScope; GroupCategory = $GroupCategory; Path = $Path; PassThru = $true } + $srv
            if ($Description) { $params['Description'] = $Description }
            (New-ADGroup @params).DistinguishedName
        }
    if ($result.Ran) { return $result.Output }
    return "CN=$Name,$Path"
}
