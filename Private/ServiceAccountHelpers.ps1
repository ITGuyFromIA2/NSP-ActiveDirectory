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

