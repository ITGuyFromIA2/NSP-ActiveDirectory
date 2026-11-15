function New-NSPADServiceAccount {
    <#
    .SYNOPSIS
        Creates a gMSA that the given computers may use, unless it already exists. Idempotent; dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        Checks first, over LDAP: an existing gMSA of that name is returned unchanged (with a warning
        if the allowed computers differ); the forest needs a usable KDS root key (one is created with
        Add-KdsRootKey on a DC, and gMSAs can use it about 10 hours later). A KDS key that can't be
        seen may mean this account can't read it - -SkipKdsCheck goes ahead anyway. Get-NSPADKdsRootKeyStatus
        reads the key; New-NSPADKdsRootKey creates one.

        Under -WhatIf a missing computer account or KDS root key is reported as a warning and the
        preview goes on, so one preview lists everything that is missing. Without -WhatIf both
        still stop the command before anything is created.

        The account is created with New-ADServiceAccount (AD module) against the DC that
        Get-NSPADDomainInfo found: AES Kerberos only, enabled, the allowed computers as
        PrincipalsAllowedToRetrieveManagedPassword. Then install it on each of those computers
        (Install-NSPADServiceAccount) - a fresh gMSA can take a few minutes to replicate.
    .PARAMETER Server
        A domain controller. The domain lookup, every check and the create all go to it. With
        -DomainInfo as well, both must name the same DC, or the command stops before anything is
        read or written.
        A blank value (empty or whitespace only) is refused before anything is read or written.
    .PARAMETER DomainInfo
        A Get-NSPADDomainInfo result, to reuse the DC it found. Default: look one up (on -Server
        when given).
    .PARAMETER AsResult
        Return an NSP.ActiveDirectory.WriteOutcome instead of the ServiceAccount object. An existing
        gMSA that does not list every planned computer is Failed/Conflict, not AlreadyPresent; a
        missing computer is Failed/NotFound; no usable KDS key is Failed/PreconditionFailed.
        -Server and -DomainInfo naming different DCs still throws. CHECK Outcome. The module's
        own observation, not management-plane verification.
        The outcome carries no error text, but a failed write step still prints the directory's own
        error on the host (NSP.Toolkit's Invoke-NSPStep), so a transcript of a failed write can hold it.
    .EXAMPLE
        Set-NSPDryRun -Enabled $false
        New-NSPADServiceAccount -Name 'svc_transfer' -AllowedComputer 'APP01' -Description 'Runs the nightly file transfer'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('NSP.ActiveDirectory.ServiceAccount')]
    param(
        [Parameter(Mandatory)][ValidateLength(1, 15)][ValidatePattern('^[A-Za-z0-9_-]+\$?$')][string]$Name,
        [Parameter(Mandatory)][string[]]$AllowedComputer,
        [string]$Description,
        [string]$DNSHostName,
        [ValidateRange(1, 3650)][int]$PasswordIntervalDays = 30,
        [switch]$SkipKdsCheck,
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo,
        [ValidateNotNullOrEmpty()][ValidateScript({ Test-NSPADServerArgument $_ })][string]$Server,
        [switch]$AsResult
    )
    if ($AsResult) {
        return (Invoke-NSPADServiceAccountOutcome -Cmdlet $PSCmdlet -Name $Name -AllowedComputer $AllowedComputer -Description $Description -DNSHostName $DNSHostName `
                -PasswordIntervalDays $PasswordIntervalDays -SkipKdsCheck ([bool]$SkipKdsCheck) -DomainInfo $DomainInfo -Server $Server)
    }

    $bare = $Name.TrimEnd('$')
    $DomainInfo = Resolve-NSPADDomainInfoForServer -DomainInfo $DomainInfo -Server $Server

    # Under -WhatIf a missing computer or KDS root key is a finding to show, not a reason to stop:
    # a preview of a forest that is still being built should list everything that is not there yet.
    $preview = [bool]$WhatIfPreference
    $computers = @(foreach ($c in $AllowedComputer) {
        $found = Get-NSPADComputer -Name $c -DomainInfo $DomainInfo
        if (-not $found) {
            if (-not $preview) { throw "No computer account '$c' in $($DomainInfo.DNSRoot)." }
            Write-Warning "Preview: no computer account '$c' in $($DomainInfo.DNSRoot). The real run would stop here."
            continue
        }
        $found
    })

    $existing = Get-NSPADServiceAccount -Name $bare -DomainInfo $DomainInfo
    if ($existing) {
        $missing = @($computers | Where-Object { @($existing.AllowedPrincipals.Sid) -notcontains $_.SID } | ForEach-Object Name)
        if ($missing.Count) { Write-Warning "$($existing.Logon) already exists and does not list $($missing -join ', ') directly as allowed to retrieve its password (a group may still grant it - see Test-NSPADServiceAccount)." }
        Write-Host "  gMSA '$bare' already exists ($($existing.DistinguishedName)) - skipping create." -ForegroundColor Gray
        return $existing
    }

    if (-not $SkipKdsCheck) {
        $kds = Get-NSPADKdsRootKeyStatus -DomainInfo $DomainInfo
        if (-not $kds.Usable) {
            $why = if ($kds.Visible) { 'the KDS root key is not usable yet (gMSAs can use it about 10 hours after Add-KdsRootKey)' } else { 'no KDS root key is visible - create one on a DC (Add-KdsRootKey -EffectiveImmediately, then wait about 10 hours), or pass -SkipKdsCheck if this account just cannot read it' }
            if (-not $preview) { throw "Can't create gMSA '$bare': $why." }
            Write-Warning "Preview: can't create gMSA '$bare': $why. The real run would stop here."
        }
    }

    $hostName = if ($DNSHostName) { $DNSHostName } else { "$bare.$($DomainInfo.DNSRoot)" }
    if (-not $PSCmdlet.ShouldProcess("$($DomainInfo.NetBIOSName)\$bare`$", "Create gMSA usable by $(@($computers.Name) -join ', ')")) { return }
    Use-NSPADDependency
    Assert-NSPADCommand New-ADServiceAccount

    $principalDns = @($computers.DistinguishedName)
    $result = Invoke-NSPStep -Description "Create gMSA '$bare' (usable by $(@($computers.Name) -join ', ')) on $($DomainInfo.Server)" `
        -Commands @("New-ADServiceAccount -Name '$bare' -DNSHostName '$hostName' -PrincipalsAllowedToRetrieveManagedPassword <$($computers.Count) computer(s)> -ManagedPasswordIntervalInDays $PasswordIntervalDays -KerberosEncryptionType AES128,AES256 -Server '$($DomainInfo.Server)'") `
        -Action {
            $params = @{
                Name = $bare; DNSHostName = $hostName; Enabled = $true
                PrincipalsAllowedToRetrieveManagedPassword = $principalDns
                ManagedPasswordIntervalInDays = $PasswordIntervalDays
                KerberosEncryptionType = 'AES128', 'AES256'
                Server = $DomainInfo.Server
            }
            if ($Description) { $params.Description = $Description }
            New-ADServiceAccount @params
        }
    if ($result.Ran) { return (Get-NSPADServiceAccount -Name $bare -DomainInfo $DomainInfo) }
}
