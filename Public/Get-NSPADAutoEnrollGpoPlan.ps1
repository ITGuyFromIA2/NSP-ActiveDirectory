function Get-NSPADAutoEnrollGpoPlan {
    <#
    .SYNOPSIS
        The registry values the certificate auto-enrollment GPO carries: User-config
        AutoEnrollment AEPolicy=7, OfflineExpirationPercent=10, OfflineExpirationStoreNames=MY.
        Pure data: Hive, Key, ValueName, Type, Value.
    .DESCRIPTION
        AEPolicy 7 = enrolled + renew/update/remove-revoked + update-templates. On a domain-joined
        machine that alone gives standard AD-based enrollment; a custom CEP server would be added by
        hand in GPMC.
    .PARAMETER IncludeComputerConfig
        Also set the same values in Computer config (VPN user certs live in CurrentUser, so off by default).
    .EXAMPLE
        Get-NSPADAutoEnrollGpoPlan | Format-Table
    #>
    [CmdletBinding()]
    param([switch]$IncludeComputerConfig)

    $base = 'Software\Policies\Microsoft\Cryptography\AutoEnrollment'
    $vals = @(
        [pscustomobject]@{ Hive = 'User'; Key = "HKCU\$base"; ValueName = 'AEPolicy'; Type = 'DWord'; Value = 7 }
        [pscustomobject]@{ Hive = 'User'; Key = "HKCU\$base"; ValueName = 'OfflineExpirationPercent'; Type = 'DWord'; Value = 10 }
        [pscustomobject]@{ Hive = 'User'; Key = "HKCU\$base"; ValueName = 'OfflineExpirationStoreNames'; Type = 'String'; Value = 'MY' }
    )
    if ($IncludeComputerConfig) {
        $vals += @(
            [pscustomobject]@{ Hive = 'Computer'; Key = "HKLM\$base"; ValueName = 'AEPolicy'; Type = 'DWord'; Value = 7 }
            [pscustomobject]@{ Hive = 'Computer'; Key = "HKLM\$base"; ValueName = 'OfflineExpirationPercent'; Type = 'DWord'; Value = 10 }
            [pscustomobject]@{ Hive = 'Computer'; Key = "HKLM\$base"; ValueName = 'OfflineExpirationStoreNames'; Type = 'String'; Value = 'MY' }
        )
    }
    return $vals
}
