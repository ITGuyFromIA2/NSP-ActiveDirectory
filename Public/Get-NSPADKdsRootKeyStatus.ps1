function Get-NSPADKdsRootKeyStatus {
    <#
    .SYNOPSIS
        Says whether the forest has a KDS root key that group managed service accounts can use yet.
        Read-only, over LDAP.
    .DESCRIPTION
        A gMSA cannot be created until the forest has a KDS root key whose start time has passed.
        A new forest has none. This reads the msKds-ProvRootKey objects under CN=Master Root Keys
        in the configuration partition and reports:

          Status         Usable        at least one key's start time has passed
                         NotYetUsable  keys exist, none has started yet (see EarliestUseUtc)
                         NoneVisible   no key was returned
                         CannotRead    the read failed (see Detail)
          Visible        how many keys were returned
          Usable         how many of them have started
          EarliestUseUtc the earliest start time among the keys, in UTC

        Reading these objects needs Domain Admin-level rights. NoneVisible can therefore also
        mean "this account is not allowed to see them"; the function cannot tell the two apart.
        It never throws for a failed read: check Status.

        Usable means msKds-UseStartTime has passed. Domain controllers may wait about 10 more
        hours before they use the key (inferred from Microsoft's lab advice; not yet measured), so
        a gMSA create can still fail just after a key turns Usable.
    .PARAMETER DomainInfo
        A Get-NSPADDomainInfo result, to reuse the domain controller it found. Default: look one up.
    .EXAMPLE
        Get-NSPADKdsRootKeyStatus | Select-Object Status, Visible, Usable, EarliestUseUtc
    .EXAMPLE
        if ((Get-NSPADKdsRootKeyStatus -DomainInfo $domain).Status -ne 'Usable') { 'gMSA steps must wait' }
    #>
    [CmdletBinding()]
    [OutputType('NSP.ActiveDirectory.KdsRootKeyStatus')]
    param([PSTypeName('NSP.ActiveDirectory.DomainInfo')]$DomainInfo)

    if (-not $DomainInfo) { $DomainInfo = Get-NSPADDomainInfo }
    $result = [ordered]@{
        PSTypeName = 'NSP.ActiveDirectory.KdsRootKeyStatus'
        Status = 'NoneVisible'; Visible = 0; Usable = 0; EarliestUseUtc = $null
        Server = "$($DomainInfo.Server)"; Detail = $null
    }
    try {
        # The forest's configuration partition (from RootDSE), not one built from the domain DN: a child domain's differs.
        $keys = @(Read-NSPADLdap -Server $DomainInfo.Server -SearchBase "CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,$($DomainInfo.ConfigurationDN)" `
                -Filter '(objectClass=msKds-ProvRootKey)' -Property 'cn', 'msKds-UseStartTime' -Scope OneLevel)
    } catch {
        $result.Status = 'CannotRead'
        $result.Detail = $_.Exception.Message
        return [pscustomobject]$result
    }
    $now = [DateTime]::UtcNow
    $starts = @($keys | Where-Object { $_['mskds-usestarttime'] } | ForEach-Object { [DateTime]::FromFileTimeUtc([int64]$_['mskds-usestarttime']) } | Sort-Object)
    $result.Visible = $keys.Count
    $result.Usable = @($starts | Where-Object { $_ -le $now }).Count
    if ($starts.Count) { $result.EarliestUseUtc = $starts[0] }
    $result.Status = if ($result.Usable) { 'Usable' } elseif ($result.Visible) { 'NotYetUsable' } else { 'NoneVisible' }
    [pscustomobject]$result
}
