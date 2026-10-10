function New-NSPADServiceAccount {
    <#
    .SYNOPSIS
        Creates a gMSA that the given computers may use, unless it already exists. Idempotent; dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        Checks first, over LDAP: an existing gMSA of that name is returned unchanged (with a warning
        if the allowed computers differ); the forest needs a usable KDS root key (one is created with
        Add-KdsRootKey on a DC, and gMSAs can use it about 10 hours later). A KDS key that can't be
        seen may mean this account can't read it - -SkipKdsCheck goes ahead anyway.

        The account is created with New-ADServiceAccount (AD module) against the DC that
        Get-NSPADDomainInfo found: AES Kerberos only, enabled, the allowed computers as
        PrincipalsAllowedToRetrieveManagedPassword. Then install it on each of those computers
        (Install-NSPADServiceAccount) - a fresh gMSA can take a few minutes to replicate.
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
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo
    )

    $bare = $Name.TrimEnd('$')
    if (-not $DomainInfo) { $DomainInfo = Get-NSPADDomainInfo }

    $computers = foreach ($c in $AllowedComputer) {
        $found = Get-NSPADComputer -Name $c -DomainInfo $DomainInfo
        if (-not $found) { throw "No computer account '$c' in $($DomainInfo.DNSRoot)." }
        $found
    }

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
            throw "Can't create gMSA '$bare': $why."
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
