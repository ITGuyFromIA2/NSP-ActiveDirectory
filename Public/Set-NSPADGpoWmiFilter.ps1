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
    .PARAMETER Server
        A domain controller. The domain read, the GPO read, the filter lookup and the ADSI write
        all go to it. Default: each cmdlet picks one, and ADSI binds serverless.
        A blank value (empty or whitespace only) is refused before anything is read or written.
    .PARAMETER AsResult
        Return an NSP.ActiveDirectory.WriteOutcome instead of nothing (Updated, or AlreadyPresent
        when the GPO already has that setting). A missing filter is Failed/NotFound. CHECK Outcome.
        The module's own observation, not management-plane verification.
        The outcome carries no error text, but a failed write step still prints the directory's own
        error on the host (NSP.Toolkit's Invoke-NSPStep), so a transcript of a failed write can hold it.
    .EXAMPLE
        Set-NSPADGpoWmiFilter -GpoName 'NSP - TLS1 - Enable TLS 1.2' -WmiFilterName 'NSP_AT - All Servers'
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Set')]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory, ParameterSetName = 'Set')][string]$WmiFilterName,
        [Parameter(Mandatory, ParameterSetName = 'Clear')][switch]$Clear,
        [ValidateNotNullOrEmpty()][ValidateScript({ Test-NSPADServerArgument $_ })][string]$Server,
        [switch]$AsResult
    )
    if ($AsResult) { return (Invoke-NSPADGpoWmiFilterOutcome -Cmdlet $PSCmdlet -GpoName $GpoName -WmiFilterName $WmiFilterName -Clear ([bool]$Clear) -Server $Server) }
    $action = if ($Clear) { 'Remove the WMI filter' } else { "Apply WMI filter '$WmiFilterName'" }
    if (-not $PSCmdlet.ShouldProcess($GpoName, $action)) { return }
    Use-NSPADDependency
    Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy (RSAT)'
    $srv = Get-NSPADServerSplat -Server $Server
    $domain = Get-ADDomain @srv -ErrorAction Stop
    $gpo = Get-GPO -Name $GpoName @srv -ErrorAction Stop
    $id = ''
    if (-not $Clear) {
        $filter = Get-NSPADWmiSomEntry -DomainDN "$($domain.DistinguishedName)" -Server $Server | Where-Object { $_.Name -eq $WmiFilterName } | Select-Object -First 1
        if (-not $filter) { throw "WMI filter '$WmiFilterName' does not exist in $($domain.DNSRoot) - create it first (New-NSPADWmiFilter)." }
        $id = $filter.Id
        if ($gpo.WmiFilter -and "$($gpo.WmiFilter.Name)" -eq $WmiFilterName) {
            Write-Host "  '$GpoName' already uses WMI filter '$WmiFilterName' - skipping." -ForegroundColor Gray
            return
        }
    }
    Invoke-NSPStep -Description "$action on GPO '$GpoName'" `
        -Commands @("[ADSI] gPCWQLFilter on $(Get-NSPADAdsiPath -DistinguishedName "CN={$($gpo.Id)},CN=Policies,CN=System,$($domain.DistinguishedName)" -Server $Server) = $(if ($id) { "[$($domain.DNSRoot);$id;0]" } else { '<cleared>' })") `
        -Action { Set-NSPADGpoWqlFilterAttribute -DomainDN "$($domain.DistinguishedName)" -DnsRoot "$($domain.DNSRoot)" -GpoGuid "$($gpo.Id)" -WmiFilterId $id -Server $Server } | Out-Null
}
