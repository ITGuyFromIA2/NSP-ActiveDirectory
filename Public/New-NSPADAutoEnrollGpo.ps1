function New-NSPADAutoEnrollGpo {
    <#
    .SYNOPSIS
        Creates (or reuses) a dedicated certificate auto-enrollment GPO, sets its values
        (Get-NSPADAutoEnrollGpoPlan), and links it at the domain root. Dry-run aware.
    .DESCRIPTION
        A dedicated GPO, so the Default Domain Policy is left alone. Re-running updates the values
        and skips the link if it is already there.
    .EXAMPLE
        New-NSPADAutoEnrollGpo -GpoName 'NSP - Certificate Auto-Enrollment'
    #>
    [CmdletBinding()]
    param(
        [string]$GpoName = 'NSP - Certificate Auto-Enrollment',
        [switch]$IncludeComputerConfig,
        [string]$DomainDn
    )
    Use-NSPADDependency
    if (-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)) {
        Write-Host '  GroupPolicy module not available - run Install-NSPADPrerequisite (menu 1),' -ForegroundColor Red
        Write-Host '  or run this on a server with RSAT-GPMC.' -ForegroundColor Red
        return
    }
    if (-not $DomainDn) {
        try { $DomainDn = (Get-ADDomain -ErrorAction Stop).DistinguishedName } catch {
            $DomainDn = 'DC=' + ($env:USERDNSDOMAIN -replace '\.', ',DC=')
        }
    }

    $existing = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Invoke-NSPStep -Description "Create GPO '$GpoName'" `
            -Commands @("New-GPO -Name '$GpoName'") `
            -Action { New-GPO -Name $GpoName | Out-Null } | Out-Null
    } else {
        Write-Host "  GPO '$GpoName' already exists - updating its values." -ForegroundColor Gray
    }

    foreach ($v in (Get-NSPADAutoEnrollGpoPlan -IncludeComputerConfig:$IncludeComputerConfig)) {
        Invoke-NSPStep -Description "Set $($v.Hive) value $($v.ValueName) = $($v.Value)" `
            -Commands @("Set-GPRegistryValue -Name '$GpoName' -Key '$($v.Key)' -ValueName $($v.ValueName) -Type $($v.Type) -Value $($v.Value)") `
            -Action { Set-GPRegistryValue -Name $GpoName -Key $v.Key -ValueName $v.ValueName -Type $v.Type -Value $v.Value | Out-Null } -ContinueOnError | Out-Null
    }

    New-NSPADGpoLink -GpoName $GpoName -TargetDN $DomainDn
}
