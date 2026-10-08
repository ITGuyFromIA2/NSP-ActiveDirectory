function New-NSPADWmiFilter {
    <#
    .SYNOPSIS
        Creates one WMI filter, or updates it when its queries or description have drifted; does
        nothing when it already matches. Dry-run aware (Invoke-NSPStep) and supports -WhatIf.
    .DESCRIPTION
        Writes the msWMI-Som object straight through ADSI (WmiFilterHelpers.ps1) - no third-party
        module and no Set-ADSystemOnlyChange toggling; Install-NSPADWmiFilterModule is no longer needed.
    .PARAMETER Filter
        One row from Get-NSPADWellKnownWmiFilter, or any object with Name, Expression (one or more
        WQL strings), Description.
    .EXAMPLE
        Get-NSPADWellKnownWmiFilter | New-NSPADWmiFilter
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, ValueFromPipeline)]$Filter)
    process {
        if (-not $PSCmdlet.ShouldProcess("$($Filter.Name)", 'Create the WMI filter if it is missing')) { return }
        Use-NSPADDependency
        $domain = Get-ADDomain -ErrorAction Stop
        $domainDn = "$($domain.DistinguishedName)"
        $want = @($Filter.Expression)
        $existing = Get-NSPADWmiSomEntry -DomainDN $domainDn | Where-Object { $_.Name -eq $Filter.Name } | Select-Object -First 1
        if ($existing -and -not (Compare-Object -ReferenceObject @($existing.Query) -DifferenceObject $want -SyncWindow 0) -and "$($existing.Description)".Trim() -eq "$($Filter.Description)".Trim()) {
            Write-Host "  WMI filter '$($Filter.Name)' already exists and matches - skipping." -ForegroundColor Gray
            return
        }
        $verb = if ($existing) { 'Update' } else { 'Create' }
        $dn = if ($existing) { $existing.DN } else { $null }
        Invoke-NSPStep -Description "$verb WMI filter '$($Filter.Name)'" `
            -Commands @("[ADSI] msWMI-Som under CN=SOM,CN=WMIPolicy,CN=System,$domainDn  (msWMI-Parm2 = $(ConvertTo-NSPADWmiParm2 -Query $want))") `
            -Action { Save-NSPADWmiSomEntry -DomainDN $domainDn -DnsRoot "$($domain.DNSRoot)" -Name $Filter.Name -Description $Filter.Description -Query $want -DN $dn } | Out-Null
    }
}
