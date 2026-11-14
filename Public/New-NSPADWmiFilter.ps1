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
    .PARAMETER Server
        A domain controller. The domain read, the filter lookup and the ADSI write all go to it.
        Default: Get-ADDomain picks one, and ADSI binds serverless.
    .EXAMPLE
        Get-NSPADWellKnownWmiFilter | New-NSPADWmiFilter
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Filter,
        [ValidateNotNullOrEmpty()][string]$Server
    )
    process {
        if (-not $PSCmdlet.ShouldProcess("$($Filter.Name)", 'Create the WMI filter if it is missing')) { return }
        Use-NSPADDependency
        $srv = Get-NSPADServerSplat -Server $Server
        $domain = Get-ADDomain @srv -ErrorAction Stop
        $domainDn = "$($domain.DistinguishedName)"
        $want = @($Filter.Expression)
        $existing = Get-NSPADWmiSomEntry -DomainDN $domainDn -Server $Server | Where-Object { $_.Name -eq $Filter.Name } | Select-Object -First 1
        if ($existing -and -not (Compare-Object -ReferenceObject @($existing.Query) -DifferenceObject $want -SyncWindow 0) -and "$($existing.Description)".Trim() -eq "$($Filter.Description)".Trim()) {
            Write-Host "  WMI filter '$($Filter.Name)' already exists and matches - skipping." -ForegroundColor Gray
            return
        }
        $verb = if ($existing) { 'Update' } else { 'Create' }
        $dn = if ($existing) { $existing.DN } else { $null }
        Invoke-NSPStep -Description "$verb WMI filter '$($Filter.Name)'" `
            -Commands @("[ADSI] msWMI-Som under $(Get-NSPADAdsiPath -DistinguishedName "CN=SOM,CN=WMIPolicy,CN=System,$domainDn" -Server $Server)  (msWMI-Parm2 = $(ConvertTo-NSPADWmiParm2 -Query $want))") `
            -Action { Save-NSPADWmiSomEntry -DomainDN $domainDn -DnsRoot "$($domain.DNSRoot)" -Name $Filter.Name -Description $Filter.Description -Query $want -DN $dn -Server $Server } | Out-Null
    }
}
