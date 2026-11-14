function New-NSPADKdsRootKey {
    <#
    .SYNOPSIS
        Creates the forest's KDS root key, which group managed service accounts need, unless one
        already exists. Run it on a domain controller. Dry-run aware (Invoke-NSPStep); supports -WhatIf.
    .DESCRIPTION
        A KDS root key is forest-wide and is not meant to be removed, so this does as little as it can:

          - If any KDS root key is already visible, it creates nothing and returns the status.
          - -EffectiveTime is mandatory. There is no default, and a time in the past is refused.
            Domain controllers wait about 10 hours after the effective time before they use a key,
            so that every DC has it first. A start time 10 hours in the past skips that wait.
            Skipping it is a decision for whoever owns the forest, and this function does not make
            it for them. Usual value: (Get-Date), which is accepted, and then about 10 hours'
            wait. (Get-Date).AddHours(10) would wait about 20 hours.
            (Inferred from Microsoft's lab advice to back-date by 10 hours; not yet measured.)
          - After the step runs it reads the key back and throws if none is visible.

        Returns the status object of Get-NSPADKdsRootKeyStatus with one more property, Created
        (True only when this call created a key and then saw it). In a dry run or under -WhatIf
        nothing is created and Created is False.
    .PARAMETER EffectiveTime
        The key's effective time; DCs start using it about 10 hours later. Must not be in the past
        (five minutes of grace).
    .PARAMETER DomainInfo
        A Get-NSPADDomainInfo result, to reuse the domain controller it found. Default: look one up.
    .EXAMPLE
        Set-NSPDryRun -Enabled $false
        New-NSPADKdsRootKey -EffectiveTime (Get-Date)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('NSP.ActiveDirectory.KdsRootKeyStatus')]
    param(
        [Parameter(Mandatory)][datetime]$EffectiveTime,
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo
    )

    # Five minutes of grace covers a caller that computed "now" a moment ago, and clock drift.
    if ($EffectiveTime.ToUniversalTime() -lt [DateTime]::UtcNow.AddMinutes(-5)) {
        throw "EffectiveTime $($EffectiveTime.ToString('u')) is in the past. A back-dated KDS root key skips the wait that lets every domain controller receive it; this command does not create one. Nothing was changed."
    }
    if (-not $DomainInfo) { $DomainInfo = Get-NSPADDomainInfo }

    $status = Get-NSPADKdsRootKeyStatus -DomainInfo $DomainInfo
    if ($status.Status -eq 'CannotRead') { throw "The KDS root keys could not be read, so none was created: $($status.Detail)" }
    if ($status.Visible -gt 0) {
        Write-Host "  The forest already has $($status.Visible) KDS root key(s) - not creating another." -ForegroundColor Gray
        $status | Add-Member -NotePropertyName Created -NotePropertyValue $false
        return $status
    }

    if ($PSCmdlet.ShouldProcess("forest of $($DomainInfo.DNSRoot)", "Create a KDS root key usable from $($EffectiveTime.ToString('u'))")) {
        Use-NSPADDependency
        if (-not (Get-Command Add-KdsRootKey -ErrorAction SilentlyContinue)) {
            throw 'Add-KdsRootKey is not available on this machine. Run this on a domain controller. Nothing was changed.'
        }
        $step = Invoke-NSPStep -Description "Create a KDS root key usable from $($EffectiveTime.ToString('u'))" `
            -Commands @("Add-KdsRootKey -EffectiveTime '$($EffectiveTime.ToString('o'))'") `
            -Action { Add-KdsRootKey -EffectiveTime $EffectiveTime -ErrorAction Stop | Out-Null }
        if ($step -and $step.Ran) {
            $after = Get-NSPADKdsRootKeyStatus -DomainInfo $DomainInfo
            if ($after.Visible -lt 1) {
                throw "Add-KdsRootKey ran without an error, but no KDS root key is visible on $($DomainInfo.Server)$(if ($after.Detail) { " ($($after.Detail))" }). Check on the domain controller before running this again."
            }
            $after | Add-Member -NotePropertyName Created -NotePropertyValue $true
            return $after
        }
    }
    $status | Add-Member -NotePropertyName Created -NotePropertyValue $false
    $status
}
