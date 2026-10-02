function New-NSPADGroup {
    <#
    .SYNOPSIS
        Creates AD group -Name in OU -Path unless a group with that sAMAccountName already exists,
        and returns its DN either way. Idempotent; dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        The existence check is by sAMAccountName (LDAP filter), not display name, so a same-named
        group in another OU is never mistaken for this one. In DRY RUN the returned DN is the
        predicted one, for planning and display only.
    .EXAMPLE
        New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPNGroups,DC=example,DC=com' -Description 'VPN users'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$GroupScope = 'Global',
        [ValidateSet('Security', 'Distribution')][string]$GroupCategory = 'Security',
        [string]$SamAccountName,
        [string]$Description
    )
    Use-NSPADDependency
    Assert-NSPADCommand Get-ADGroup
    $sam = if ($SamAccountName) { $SamAccountName } else { $Name -replace '[^A-Za-z0-9_\-]', '' }
    $existing = Get-ADGroup -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Group '$sam' already exists ($($existing.DistinguishedName)) - skipping create." -ForegroundColor Gray
        return $existing.DistinguishedName
    }
    $result = Invoke-NSPStep -Description "Create AD group '$Name' ($GroupScope $GroupCategory) under $Path" `
        -Commands @("New-ADGroup -Name '$Name' -SamAccountName '$sam' -GroupScope $GroupScope -GroupCategory $GroupCategory -Path '$Path'") `
        -Action {
            $params = @{ Name = $Name; SamAccountName = $sam; GroupScope = $GroupScope; GroupCategory = $GroupCategory; Path = $Path; PassThru = $true }
            if ($Description) { $params['Description'] = $Description }
            (New-ADGroup @params).DistinguishedName
        }
    if ($result.Ran) { return $result.Output }
    return "CN=$Name,$Path"
}
