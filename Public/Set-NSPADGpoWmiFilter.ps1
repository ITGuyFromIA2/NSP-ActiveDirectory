function Set-NSPADGpoWmiFilter {
    <#
    .SYNOPSIS
        Applies a WMI filter to a GPO (or removes it with -Clear). Dry-run aware (Invoke-NSPStep) and
        supports -WhatIf.
    .DESCRIPTION
        Sets the GPO's gPCWQLFilter attribute through ADSI - no third-party module. The filter must
        already exist (New-NSPADWmiFilter). Does nothing when the GPO already uses that filter.
    .PARAMETER GpoName
        The GPO's display name.
    .PARAMETER WmiFilterName
        The WMI filter's name.
    .PARAMETER Clear
        Remove the GPO's WMI filter instead.
    .EXAMPLE
        Set-NSPADGpoWmiFilter -GpoName 'NSP - TLS1 - Enable TLS 1.2' -WmiFilterName 'NSP_AT - All Servers'
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Set')]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory, ParameterSetName = 'Set')][string]$WmiFilterName,
        [Parameter(Mandatory, ParameterSetName = 'Clear')][switch]$Clear
    )
    $action = if ($Clear) { 'Remove the WMI filter' } else { "Apply WMI filter '$WmiFilterName'" }
    if (-not $PSCmdlet.ShouldProcess($GpoName, $action)) { return }
    Use-NSPADDependency
    Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy (RSAT)'
    $domain = Get-ADDomain -ErrorAction Stop
    $gpo = Get-GPO -Name $GpoName -ErrorAction Stop
    $id = ''
    if (-not $Clear) {
        $filter = Get-NSPADWmiSomEntry -DomainDN "$($domain.DistinguishedName)" | Where-Object { $_.Name -eq $WmiFilterName } | Select-Object -First 1
        if (-not $filter) { throw "WMI filter '$WmiFilterName' does not exist in $($domain.DNSRoot) - create it first (New-NSPADWmiFilter)." }
        $id = $filter.Id
        if ($gpo.WmiFilter -and "$($gpo.WmiFilter.Name)" -eq $WmiFilterName) {
            Write-Host "  '$GpoName' already uses WMI filter '$WmiFilterName' - skipping." -ForegroundColor Gray
            return
        }
    }
    Invoke-NSPStep -Description "$action on GPO '$GpoName'" `
        -Commands @("[ADSI] gPCWQLFilter on CN={$($gpo.Id)},CN=Policies,CN=System,$($domain.DistinguishedName) = $(if ($id) { "[$($domain.DNSRoot);$id;0]" } else { '<cleared>' })") `
        -Action { Set-NSPADGpoWqlFilterAttribute -DomainDN "$($domain.DistinguishedName)" -DnsRoot "$($domain.DNSRoot)" -GpoGuid "$($gpo.Id)" -WmiFilterId $id } | Out-Null
}
