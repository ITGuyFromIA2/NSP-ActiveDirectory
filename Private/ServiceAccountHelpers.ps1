# gMSA helpers for Get/Test/New-NSPADServiceAccount. LDAP only (through Read-NSPADLdap).

function ConvertFrom-NSPADGmsaMembership {
    # msDS-GroupMSAMembership is a security descriptor: its Allow entries are the principals that may
    # retrieve the managed password. Returns one @{ Sid; Name } per allowed principal.
    param([byte[]]$Descriptor)
    if (-not $Descriptor) { return }
    $sd = New-Object System.DirectoryServices.ActiveDirectorySecurity
    $sd.SetSecurityDescriptorBinaryForm($Descriptor)
    foreach ($rule in $sd.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        $sid = $rule.IdentityReference.Value
        $name = try { $rule.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { $sid }
        [pscustomobject]@{ Sid = $sid; Name = $name }
    }
}

function Get-NSPADKdsRootKeyStatus {
    # Whether the forest has a KDS root key gMSAs can use (msKds-ProvRootKey objects under
    # CN=Master Root Keys). Reading them needs Domain Admin-level rights: none visible can also mean
    # "not allowed to see", which the caller reports as such.
    param([Parameter(Mandatory)]$DomainInfo)
    # The forest's configuration partition (from RootDSE), not one built from the domain DN: a child domain's differs.
    $configDn = $DomainInfo.ConfigurationDN
    $keys = @(Read-NSPADLdap -Server $DomainInfo.Server -SearchBase "CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,$configDn" `
            -Filter '(objectClass=msKds-ProvRootKey)' -Property 'cn', 'msKds-UseStartTime' -Scope OneLevel)
    $usable = @($keys | Where-Object { $_['mskds-usestarttime'] -and [DateTime]::FromFileTimeUtc([int64]$_['mskds-usestarttime']) -le [DateTime]::UtcNow })
    [pscustomobject]@{ Visible = $keys.Count; Usable = $usable.Count }
}
