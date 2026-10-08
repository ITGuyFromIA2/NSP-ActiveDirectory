<#
    WMI filters through ADSI - no third-party module (replaces BW.Utils.GroupPolicy.WMIFilter).
    A WMI filter is an msWMI-Som object in CN=SOM,CN=WMIPolicy,CN=System,<domain DN>:
        msWMI-Name   the filter name             msWMI-Parm1  its description
        msWMI-Parm2  the queries, encoded below   msWMI-ID     "{GUID}" (also the object's CN)
        msWMI-Author, msWMI-CreationDate, msWMI-ChangeDate (yyyyMMddHHmmss.ffffff-000, UTC)
    msWMI-Parm2 is "<count>;" followed, per query, by "3;10;<query length>;WQL;<namespace>;<query>;".
    A GPO points at its filter through gPCWQLFilter = "[<dns domain>;{ID};0]".
#>

function ConvertTo-NSPADWmiParm2 {
    # PURE. Query strings -> msWMI-Parm2.
    param([Parameter(Mandatory)][string[]]$Query, [string]$Namespace = 'root\CIMv2')
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("$($Query.Count);")
    foreach ($q in $Query) { [void]$sb.Append("3;10;$($q.Length);WQL;$Namespace;$q;") }
    return $sb.ToString()
}

function ConvertFrom-NSPADWmiParm2 {
    # PURE. msWMI-Parm2 -> the query strings (namespace dropped). Reads by the encoded lengths, so a
    # ';' inside a query is safe.
    param([AllowEmptyString()][string]$Parm2)
    if ([string]::IsNullOrWhiteSpace($Parm2)) { return @() }
    $i = $Parm2.IndexOf(';')
    $count = [int]$Parm2.Substring(0, $i)
    $pos = $i + 1
    $out = New-Object Collections.Generic.List[string]
    for ($n = 0; $n -lt $count; $n++) {
        $parts = @()
        for ($k = 0; $k -lt 5; $k++) { $j = $Parm2.IndexOf(';', $pos); $parts += $Parm2.Substring($pos, $j - $pos); $pos = $j + 1 }
        $len = [int]$parts[2]
        $out.Add($Parm2.Substring($pos, $len))
        $pos += $len + 1
    }
    return $out.ToArray()
}

function Get-NSPADWmiSomEntry {
    # Every msWMI-Som object in the domain as plain objects (Name, Description, Query, Id, DN).
    param([Parameter(Mandatory)][string]$DomainDN)
    $root = [ADSI]"LDAP://CN=SOM,CN=WMIPolicy,CN=System,$DomainDN"
    $searcher = New-Object DirectoryServices.DirectorySearcher($root, '(objectClass=msWMI-Som)')
    foreach ($p in 'msWMI-Name', 'msWMI-Parm1', 'msWMI-Parm2', 'msWMI-ID', 'distinguishedName') { [void]$searcher.PropertiesToLoad.Add($p) }
    foreach ($r in $searcher.FindAll()) {
        [pscustomobject]@{
            Name        = "$($r.Properties['mswmi-name'])"
            Description = "$($r.Properties['mswmi-parm1'])"
            Query       = @(ConvertFrom-NSPADWmiParm2 -Parm2 "$($r.Properties['mswmi-parm2'])")
            Id          = "$($r.Properties['mswmi-id'])"
            DN          = "$($r.Properties['distinguishedname'])"
        }
    }
}

function Save-NSPADWmiSomEntry {
    # Creates (no -DN) or updates (-DN of an existing filter) one msWMI-Som object.
    param(
        [Parameter(Mandatory)][string]$DomainDN, [Parameter(Mandatory)][string]$DnsRoot,
        [Parameter(Mandatory)][string]$Name, [string]$Description, [Parameter(Mandatory)][string[]]$Query, [string]$DN
    )
    $now = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff') + '-000'
    $parm2 = ConvertTo-NSPADWmiParm2 -Query $Query
    if ($DN) {
        $entry = [ADSI]"LDAP://$DN"
        $entry.Put('msWMI-Parm1', $(if ($Description) { $Description } else { ' ' }))
        $entry.Put('msWMI-Parm2', $parm2)
        $entry.Put('msWMI-ChangeDate', $now)
        $entry.SetInfo()
        return "$DN"
    }
    $id = '{' + ([guid]::NewGuid().ToString().ToUpperInvariant()) + '}'
    $container = [ADSI]"LDAP://CN=SOM,CN=WMIPolicy,CN=System,$DomainDN"
    $entry = $container.Create('msWMI-Som', "CN=$id")
    $entry.Put('msWMI-Name', $Name)
    $entry.Put('msWMI-Parm1', $(if ($Description) { $Description } else { ' ' }))
    $entry.Put('msWMI-Parm2', $parm2)
    $entry.Put('msWMI-Author', "$env:USERNAME@$DnsRoot")
    $entry.Put('msWMI-ID', $id)
    $entry.Put('instanceType', 4)
    $entry.Put('showInAdvancedViewOnly', 'TRUE')
    $entry.Put('msWMI-CreationDate', $now)
    $entry.Put('msWMI-ChangeDate', $now)
    $entry.SetInfo()
    return "CN=$id,CN=SOM,CN=WMIPolicy,CN=System,$DomainDN"
}

function Set-NSPADGpoWqlFilterAttribute {
    # Points a GPO (by its {GUID}) at a WMI filter id, or clears it with an empty -WmiFilterId.
    param([Parameter(Mandatory)][string]$DomainDN, [Parameter(Mandatory)][string]$DnsRoot, [Parameter(Mandatory)][string]$GpoGuid, [AllowEmptyString()][string]$WmiFilterId)
    $entry = [ADSI]"LDAP://CN={$($GpoGuid.Trim('{}'))},CN=Policies,CN=System,$DomainDN"
    if ($WmiFilterId) { $entry.Put('gPCWQLFilter', "[$DnsRoot;$WmiFilterId;0]") } else { $entry.PutEx(1, 'gPCWQLFilter', $null) }
    $entry.SetInfo()
}
