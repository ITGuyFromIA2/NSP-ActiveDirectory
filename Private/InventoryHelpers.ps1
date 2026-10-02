# Helpers for Get-NSPADVpnInventory. The pure ones are tested directly; the LDAP wrappers are thin
# so tests can replace them.

$script:ADInvEnrollGuid     = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
$script:ADInvAutoEnrollGuid = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
$script:ADInvClientAuthEku  = '1.3.6.1.5.5.7.3.2'
# Built-in v2 templates that carry Client Authentication but are never VPN user templates.
$script:ADInvSkipTemplates  = @('DomainControllerAuthentication', 'KerberosAuthentication', 'DirectoryEmailReplication')

function ConvertFrom-ADTemplatePeriod {
    # pKIExpirationPeriod / pKIOverlapPeriod (8-byte little-endian, negative 100-ns ticks) -> whole days.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Count -ne 8) { return $null }
    [int][math]::Round([math]::Abs([BitConverter]::ToInt64($Bytes, 0)) / 864000000000)
}

function Get-ADTameMyCertsOuStamp {
    # The OU= value a TameMyCerts policy XML forces into the subject (OutboundSubjectRule with Field
    # organizationalUnitName), or $null when the policy sets none.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$XmlText)
    try { [xml]$policy = $XmlText } catch { return $null }
    foreach ($rule in @($policy.SelectNodes("//*[local-name()='OutboundSubjectRule']"))) {
        $field = $rule.SelectSingleNode("*[local-name()='Field']")
        $value = $rule.SelectSingleNode("*[local-name()='Value']")
        if ($field -and $value -and $field.InnerText.Trim() -eq 'organizationalUnitName') { return $value.InnerText.Trim() }
    }
    $null
}

function Get-ADNpsGroupSids {
    # Every SID named by a USERNTGROUPS(...) condition in ias.xml text. Reads the condition strings
    # only - never the RADIUS client entries (which hold shared secrets).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$IasText)
    $sids = New-Object System.Collections.Generic.List[string]
    foreach ($condition in [regex]::Matches($IasText, 'USERNTGROUPS\(([^)]*)\)')) {
        foreach ($quoted in [regex]::Matches($condition.Groups[1].Value, '(?:"|&quot;)(S-1-[0-9-]+)(?:"|&quot;)')) {
            if (-not $sids.Contains($quoted.Groups[1].Value)) { $sids.Add($quoted.Groups[1].Value) }
        }
    }
    @($sids)
}

function Test-ADInvOrdinaryDomainSid {
    # True for a domain account SID with RID 1000+ (created by an admin); false for well-known and
    # built-in principals (Domain Admins 512, Domain Computers 515, RAS and IAS Servers 553, ...).
    param([AllowEmptyString()][string]$Sid)
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-(\d+)$') { return $false }
    [int64]$Matches[1] -ge 1000
}

function Get-ADTemplateAccess {
    # Splits template ACEs into Enroll and AutoEnroll principal lists. GenericAll grants both; an
    # ExtendedRight ACE grants the right its ObjectType names (an empty ObjectType = all).
    param([AllowEmptyCollection()][object[]]$Rule = @())
    $enroll = [ordered]@{}
    $autoEnroll = [ordered]@{}
    foreach ($ace in $Rule) {
        if (-not $ace.Allow) { continue }
        $all = $ace.Rights -match 'GenericAll'
        $extended = $ace.Rights -match 'ExtendedRight'
        $anyRight = $extended -and ([guid]$ace.ObjectType -eq [guid]::Empty)
        $principal = [pscustomobject]@{ Name = $ace.Name; Sid = $ace.Sid }
        if ($all -or $anyRight -or ($extended -and [guid]$ace.ObjectType -eq $script:ADInvEnrollGuid)) { $enroll[$ace.Sid] = $principal }
        if ($all -or $anyRight -or ($extended -and [guid]$ace.ObjectType -eq $script:ADInvAutoEnrollGuid)) { $autoEnroll[$ace.Sid] = $principal }
    }
    [pscustomobject]@{ Enroll = @($enroll.Values); AutoEnroll = @($autoEnroll.Values) }
}

function Get-ADInvNamingContext {
    $rootDse = [ADSI]'LDAP://RootDSE'
    $dnsDomain = try { [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name } catch { $env:USERDNSDOMAIN }
    [pscustomobject]@{
        Default       = [string]$rootDse.defaultNamingContext[0]
        Configuration = [string]$rootDse.configurationNamingContext[0]
        DnsDomain     = $dnsDomain
    }
}

function Search-ADInvDirectory {
    # Paged LDAP search returning one hashtable per result: property name (lower case) -> value array.
    param(
        [Parameter(Mandatory)][string]$SearchBase,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][string[]]$Property
    )
    # A '/' inside a DN (e.g. an OU named "Sales/Ops") must be escaped in an LDAP:// path.
    $searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$($SearchBase -replace '/', '\/')", $Filter)
    $searcher.PageSize = 500
    foreach ($name in $Property) { [void]$searcher.PropertiesToLoad.Add($name) }
    $results = $searcher.FindAll()
    try {
        foreach ($result in $results) {
            $item = @{}
            foreach ($name in $result.Properties.PropertyNames) { $item[$name.ToLowerInvariant()] = @($result.Properties[$name]) }
            $item
        }
    } finally { $results.Dispose() }
}

function Get-ADInvAccessRule {
    # The explicit and inherited access rules on one AD object, as plain objects for Get-ADTemplateAccess.
    param([Parameter(Mandatory)][string]$DistinguishedName)
    $entry = [ADSI]"LDAP://$DistinguishedName"
    foreach ($rule in $entry.psbase.ObjectSecurity.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        $name = try { $rule.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { $sid }
        @{ Sid = $sid; Name = $name; Allow = $rule.AccessControlType -eq 'Allow'; Rights = [string]$rule.ActiveDirectoryRights; ObjectType = $rule.ObjectType }
    }
}

function Get-ADInvTameMyCertsDirectory {
    # The TameMyCerts PolicyDirectory from this machine's CA registry, or $null.
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    if (-not (Test-Path $root)) { return $null }
    foreach ($ca in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        $key = Join-Path $ca.PSPath 'PolicyModules\TameMyCerts.Policy'
        $value = try { (Get-ItemProperty -Path $key -Name PolicyDirectory -ErrorAction Stop).PolicyDirectory } catch { $null }
        if ($value) { return $value }
    }
    $null
}

function Get-NSPADModuleVersion {
    return [string]$ExecutionContext.SessionState.Module.Version
}
