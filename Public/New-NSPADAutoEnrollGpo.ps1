function New-NSPADAutoEnrollGpo {
    <#
    .SYNOPSIS
        Creates (or reuses) a dedicated certificate auto-enrollment GPO, sets its values
        (Get-NSPADAutoEnrollGpoPlan), and links it at the domain root. Dry-run aware.
    .DESCRIPTION
        A dedicated GPO, so the Default Domain Policy is left alone. Re-running updates the values
        and skips the link if it is already there.

        It throws, and changes nothing, when the GroupPolicy module is missing or the domain's
        distinguished name cannot be read (pass -DomainDn). It throws after trying every value
        when any value could not be set, and does not link the GPO in that case.
    .PARAMETER Server
        A domain controller. The domain read, the GPO read and create, every value and the link all
        go to it. Default: each cmdlet picks one.
    .EXAMPLE
        New-NSPADAutoEnrollGpo -GpoName 'NSP - Certificate Auto-Enrollment'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$GpoName = 'NSP - Certificate Auto-Enrollment',
        [switch]$IncludeComputerConfig,
        [string]$DomainDn,
        [ValidateNotNullOrEmpty()][string]$Server
    )
    if (-not $PSCmdlet.ShouldProcess("$GpoName", 'Create the certificate auto-enrollment GPO and link it at the domain root')) { return }
    Use-NSPADDependency
    Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy'
    $srv = Get-NSPADServerSplat -Server $Server
    if (-not $DomainDn) {
        try { $DomainDn = "$((Get-ADDomain @srv -ErrorAction Stop).DistinguishedName)" } catch {
            # Fall back to the logon domain only when there is one. Under SYSTEM or a local account
            # the variable is empty, and a link target of 'DC=' must never be built from it.
            if ($env:USERDNSDOMAIN) { $DomainDn = 'DC=' + ($env:USERDNSDOMAIN -replace '\.', ',DC=') }
        }
    }
    if ($DomainDn -notmatch '^\s*DC=[^,=\s]+') {
        throw "The domain's distinguished name could not be read (Get-ADDomain) - pass -DomainDn. Nothing was changed."
    }

    $existing = Get-GPO -Name $GpoName @srv -ErrorAction SilentlyContinue
    if (-not $existing) {
        Invoke-NSPStep -Description "Create GPO '$GpoName'" `
            -Commands @("New-GPO -Name '$GpoName'$(Format-NSPADServerArg $Server)") `
            -Action { New-GPO -Name $GpoName @srv | Out-Null } | Out-Null
    } else {
        Write-Host "  GPO '$GpoName' already exists - updating its values." -ForegroundColor Gray
    }

    # Every value is attempted, so one failure does not hide the others; then any failure stops the
    # command before the link, so a half-set GPO is never linked and never looks like success.
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($v in (Get-NSPADAutoEnrollGpoPlan -IncludeComputerConfig:$IncludeComputerConfig)) {
        $step = Invoke-NSPStep -Description "Set $($v.Hive) value $($v.ValueName) = $($v.Value)" `
            -Commands @("Set-GPRegistryValue -Name '$GpoName' -Key '$($v.Key)' -ValueName $($v.ValueName) -Type $($v.Type) -Value $($v.Value)$(Format-NSPADServerArg $Server)") `
            -Action { Set-GPRegistryValue -Name $GpoName -Key $v.Key -ValueName $v.ValueName -Type $v.Type -Value $v.Value @srv -ErrorAction Stop | Out-Null } -ContinueOnError
        if ($step -and $step.Error) { $failed.Add("$($v.Hive) $($v.ValueName): $($step.Error)") }
    }
    if ($failed.Count) {
        throw "GPO '$GpoName': $($failed.Count) value(s) could not be set, so the GPO was not linked. $($failed -join ' | ')"
    }

    New-NSPADGpoLink -GpoName $GpoName -TargetDN $DomainDn @srv
}
