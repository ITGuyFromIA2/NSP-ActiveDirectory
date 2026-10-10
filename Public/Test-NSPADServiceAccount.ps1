function Test-NSPADServiceAccount {
    <#
    .SYNOPSIS
        Checks a gMSA is ready to use on a computer: it exists, is enabled, the computer may retrieve its password, and (locally) it is installed.
    .DESCRIPTION
        The first three checks are LDAP reads, so they work without the AD module or AD Web Services.
        "May retrieve" counts the computer itself and any group it is in (its tokenGroups), so a gMSA
        allowed through a group of servers passes too.

        Installed is only checked for this computer, and only when the AD module is present
        (Test-ADServiceAccount); otherwise it is $null and not counted against Ready. Problems lists
        what is missing, one line each. Read-only.
    .EXAMPLE
        Test-NSPADServiceAccount -Name 'svc_transfer'
    .EXAMPLE
        Test-NSPADServiceAccount -Name 'svc_transfer' -ComputerName 'APP02' | Select-Object Ready, Problems
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.ServiceAccountTest')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ComputerName = $env:COMPUTERNAME,
        [PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo
    )

    if (-not $DomainInfo) { $DomainInfo = Get-NSPADDomainInfo }
    $problems = [System.Collections.Generic.List[string]]::new()
    $result = [ordered]@{
        PSTypeName = 'NSP.ActiveDirectory.ServiceAccountTest'
        Name = $Name.TrimEnd('$'); ComputerName = $ComputerName; Exists = $false; Enabled = $false
        ComputerAllowed = $false; Installed = $null; Ready = $false; Problems = @(); Account = $null
    }

    $account = Get-NSPADServiceAccount -Name $Name -DomainInfo $DomainInfo
    if (-not $account) {
        $problems.Add("No gMSA named '$($result.Name)' in $($DomainInfo.DNSRoot).")
    } else {
        $result.Account = $account
        $result.Exists = $true
        $result.Enabled = [bool]$account.Enabled
        if (-not $account.Enabled) { $problems.Add("$($account.Logon) is disabled.") }

        $computer = Get-NSPADComputer -Name $ComputerName -DomainInfo $DomainInfo
        if (-not $computer) {
            $problems.Add("No computer account '$ComputerName' in $($DomainInfo.DNSRoot).")
        } else {
            $groups = @(Read-NSPADLdap -Server $DomainInfo.Server -SearchBase $computer.DistinguishedName -Scope Base -Property 'tokenGroups' -MultiValued 'tokenGroups')[0]
            $sids = @($computer.SID) + @(@($groups['tokengroups']) | Where-Object { $_ } | ForEach-Object { [Security.Principal.SecurityIdentifier]::new([byte[]]$_, 0).Value })
            $allowed = @($account.AllowedPrincipals | Where-Object { $sids -contains $_.Sid })
            $result.ComputerAllowed = $allowed.Count -gt 0
            if (-not $result.ComputerAllowed) {
                $problems.Add("$ComputerName may not retrieve the password (allowed: $(@($account.AllowedPrincipals.Name) -join ', ')).")
            }
        }

        if ($ComputerName -eq $env:COMPUTERNAME -and (Get-Command Test-ADServiceAccount -ErrorAction SilentlyContinue)) {
            $result.Installed = [bool](Test-ADServiceAccount -Identity $result.Name -ErrorAction SilentlyContinue)
            if (-not $result.Installed) { $problems.Add("$($account.Logon) is not installed on this computer (Install-NSPADServiceAccount).") }
        }
    }

    $result.Problems = @($problems)
    $result.Ready = ($problems.Count -eq 0)
    [pscustomobject]$result
}
