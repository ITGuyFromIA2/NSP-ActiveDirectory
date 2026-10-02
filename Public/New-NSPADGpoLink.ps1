function New-NSPADGpoLink {
    <#
    .SYNOPSIS
        Links an existing GPO at -TargetDN unless it is already linked there. Idempotent; dry-run
        aware (Invoke-NSPStep).
    .DESCRIPTION
        Only the link - building the GPO's content (New-GPO + Set-GPRegistryValue, or Import-GPO)
        stays with the caller.
    .EXAMPLE
        New-NSPADGpoLink -GpoName 'NSP - Certificate Auto-Enrollment' -TargetDN 'DC=example,DC=com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$TargetDN
    )
    Use-NSPADDependency
    Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy'
    $existingLinks = @()
    try {
        $existingLinks = @((Get-GPInheritance -Target $TargetDN -ErrorAction Stop).GpoLinks | Where-Object { $_.DisplayName -eq $GpoName })
    } catch {
        # A bad -TargetDN surfaces as New-GPLink's own clearer error below.
        Write-Verbose "Get-GPInheritance failed for ${TargetDN}: $_"
    }
    if ($existingLinks.Count -gt 0) {
        Write-Host "  '$GpoName' is already linked at '$TargetDN' - skipping." -ForegroundColor Gray
        return
    }
    Invoke-NSPStep -Description "Link GPO '$GpoName' at $TargetDN" `
        -Commands @("New-GPLink -Name '$GpoName' -Target '$TargetDN' -LinkEnabled Yes") `
        -Action {
            try {
                New-GPLink -Name $GpoName -Target $TargetDN -LinkEnabled Yes | Out-Null
            } catch {
                if ($_.Exception.Message -notmatch 'already linked|already exists') { throw }
            }
        } -ContinueOnError | Out-Null
}
