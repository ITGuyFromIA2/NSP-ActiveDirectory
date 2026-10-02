function New-NSPADWmiFilter {
    <#
    .SYNOPSIS
        Creates one WMI filter, or updates it when its expression or description has drifted;
        does nothing when it already matches. Dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        Needs Install-NSPADWmiFilterModule first. The write is bracketed by
        Set-ADSystemOnlyChange -Enable/-Disable: msWMI-Som is a system-only class and the write fails
        without it.
    .PARAMETER Filter
        One row from Get-NSPADWellKnownWmiFilter, or any object with Name, Expression, Description.
    .EXAMPLE
        Get-NSPADWellKnownWmiFilter | ForEach-Object { New-NSPADWmiFilter -Filter $_ }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Filter)
    process {
        Use-NSPADDependency
        Assert-NSPADCommand Get-GPWmiFilter -ModuleHint 'BW.Utils.GroupPolicy.WMIFilter (Install-NSPADWmiFilterModule)'
        $existing = Get-GPWmiFilter -Name $Filter.Name -ErrorAction SilentlyContinue
        $expressionMatches = $false
        if ($existing) {
            $existingExpr = @($existing.Filters.filter)
            $wantExpr = @($Filter.Expression)
            $diff = Compare-Object -ReferenceObject $existingExpr -DifferenceObject $wantExpr -SyncWindow 0
            $expressionMatches = (-not $diff) -and ($existing.Description -eq $Filter.Description)
        }
        if ($expressionMatches) {
            Write-Host "  WMI filter '$($Filter.Name)' already exists and matches - skipping." -ForegroundColor Gray
            return
        }
        $verb = if ($existing) { 'Update' } else { 'Create' }
        $cmdVerb = if ($existing) { 'Set' } else { 'New' }
        Invoke-NSPStep -Description "$verb WMI filter '$($Filter.Name)'" `
            -Commands @("$cmdVerb-GPWmiFilter -Name '$($Filter.Name)' -Filters <from New-WmiFilterList> -Description '$($Filter.Description)'") `
            -Action {
                Set-ADSystemOnlyChange -Enable -ComputerName $env:COMPUTERNAME
                try {
                    $newFilterList = New-WmiFilterList -Filter $Filter.Expression
                    if ($existing) {
                        Set-GPWmiFilter -Name $Filter.Name -Filters $newFilterList -Description $Filter.Description -Confirm:$false
                    } else {
                        New-GPWmiFilter -Name $Filter.Name -Filters $newFilterList -Description $Filter.Description
                    }
                } finally {
                    Set-ADSystemOnlyChange -Disable -ComputerName $env:COMPUTERNAME
                }
            } | Out-Null
    }
}
