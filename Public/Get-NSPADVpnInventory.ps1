function Get-NSPADVpnInventory {
    <#
    .SYNOPSIS
        Collects the AD side of an IKEv2 VPN deployment - VPN groups (members, nesting, SIDs),
        client-authentication certificate templates (Enroll/AutoEnroll groups), and TameMyCerts OU
        stamps - into the SchemaVersion 1 object NSP.FortiGate's VPN report reads. Read-only.

    .DESCRIPTION
        Groups are seeded from -GroupPattern name matches, every SID an NPS policy names in ias.xml,
        and the ordinary domain groups granted Enroll/AutoEnroll on a collected template; then widened
        to their direct parents and every nested member group. Templates are schema v2+ with Client
        Authentication (or matching -TemplatePattern).

        Queries AD over LDAP (ADSI - no RSAT needed). Run it on the CA/NPS server when possible:
        ias.xml and the TameMyCerts policy folder are then found automatically.

        SchemaVersion 1 contract (NSP.FortiGate reads these names; add fields freely, but renaming or
        removing one is a SchemaVersion bump): SchemaVersion, Generated, Domain, ComputerName, Tool,
        Groups[], Templates[], TameMyCerts, Sources.

    .PARAMETER GroupPattern
        sAMAccountName wildcards seeding the group list.

    .PARAMETER TemplatePattern
        Collect templates matching this name instead of the client-auth rule.

    .PARAMETER NpsConfigPath
        ias.xml to read NPS group SIDs from (defaults to this machine's, when it is the NPS server).

    .PARAMETER PolicyDirectory
        TameMyCerts policy folder (defaults to the one in this machine's CA registry).

    .EXAMPLE
        $inv = Get-NSPADVpnInventory -GroupPattern 'VPN*'
        $inv.Groups | Select-Object Name, RecursiveUserCount
    #>
    [CmdletBinding()]
    param(
        [string[]]$GroupPattern = @('IKEv2*', 'VPNFW*', 'FGT*'),
        [string]$TemplatePattern,
        [string]$NpsConfigPath,
        [string]$PolicyDirectory
    )

    $context = Get-ADInvNamingContext
    $sidOf = { param($Item) if ($Item['objectsid']) { (New-Object System.Security.Principal.SecurityIdentifier([byte[]]$Item['objectsid'][0], 0)).Value } }
    $groupProperties = @('samaccountname', 'distinguishedname', 'objectsid', 'description', 'memberof')
    $escapeLdap = { param([string]$Text) ($Text -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29') }

    if (-not $NpsConfigPath) {
        $local = Join-Path $env:SystemRoot 'System32\ias\ias.xml'
        if (Test-Path $local) { $NpsConfigPath = $local }
    }
    $npsSids = @()
    if ($NpsConfigPath -and (Test-Path -LiteralPath $NpsConfigPath)) {
        $npsSids = Get-ADNpsGroupSids -IasText (Get-Content -LiteralPath $NpsConfigPath -Raw)
    }

    # Templates first: their Enroll/AutoEnroll groups are group seeds too.
    $templateBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$($context.Configuration)"
    $publishers = @(Search-ADInvDirectory -SearchBase "CN=Enrollment Services,CN=Public Key Services,CN=Services,$($context.Configuration)" -Filter '(objectClass=pKIEnrollmentService)' -Property 'cn', 'certificatetemplates')
    $templateItems = @(Search-ADInvDirectory -SearchBase $templateBase -Filter '(objectClass=pKICertificateTemplate)' -Property 'cn', 'displayname', 'distinguishedname', 'mspki-cert-template-oid', 'mspki-template-schema-version', 'pkiexpirationperiod', 'pkioverlapperiod', 'mspki-certificate-name-flag', 'pkiextendedkeyusage', 'mspki-certificate-application-policy')

    if (-not $PolicyDirectory) {
        $PolicyDirectory = Get-ADInvTameMyCertsDirectory
        $tmcSource = if ($PolicyDirectory) { 'CA registry' } else { $null }
    } else { $tmcSource = 'parameter' }
    $stamps = [ordered]@{}
    if ($PolicyDirectory -and (Test-Path -LiteralPath $PolicyDirectory)) {
        foreach ($file in Get-ChildItem -LiteralPath $PolicyDirectory -Filter '*.xml' -File) {
            $ou = Get-ADTameMyCertsOuStamp -XmlText (Get-Content -LiteralPath $file.FullName -Raw)
            $stamps[$file.BaseName] = [pscustomobject]@{ Template = $file.BaseName; OuValue = $ou; File = $file.Name }
        }
    }

    $templates = foreach ($item in $templateItems) {
        $name = [string]$item['cn'][0]
        $ekus = @($item['pkiextendedkeyusage']) + @($item['mspki-certificate-application-policy'])
        $schema = if ($item['mspki-template-schema-version']) { [int]$item['mspki-template-schema-version'][0] } else { 1 }
        $wanted = if ($TemplatePattern) { $name -like $TemplatePattern } else { $ekus -contains $script:ADInvClientAuthEku -and $schema -ge 2 -and $script:ADInvSkipTemplates -notcontains $name }
        if (-not $wanted -and -not $stamps.Contains($name)) { continue }
        $flags = if ($item['mspki-certificate-name-flag']) { [int64]$item['mspki-certificate-name-flag'][0] } else { 0 }
        $access = Get-ADTemplateAccess -Rule @(Get-ADInvAccessRule -DistinguishedName ([string]$item['distinguishedname'][0]))
        [pscustomobject]@{
            Name                    = $name
            DisplayName             = [string]($item['displayname'] | Select-Object -First 1)
            Oid                     = [string]($item['mspki-cert-template-oid'] | Select-Object -First 1)
            SchemaVersion           = $schema
            ValidityDays            = ConvertFrom-ADTemplatePeriod -Bytes ($item['pkiexpirationperiod'] | Select-Object -First 1)
            RenewalDays             = ConvertFrom-ADTemplatePeriod -Bytes ($item['pkioverlapperiod'] | Select-Object -First 1)
            NameFlags               = ('0x{0:X8}' -f ($flags -band 0xFFFFFFFF))
            EnrolleeSuppliesSubject = [bool]($flags -band 1)
            Enroll                  = $access.Enroll
            AutoEnroll              = $access.AutoEnroll
            PublishedOn             = @($publishers | Where-Object { @($_['certificatetemplates']) -contains $name } | ForEach-Object { [string]$_['cn'][0] })
            OuStamp                 = if ($stamps.Contains($name)) { $stamps[$name].OuValue } else { $null }
        }
    }
    $templates = @($templates)

    # Group seeds: name patterns, NPS SIDs, template enrollment groups.
    $groups = [ordered]@{}
    $addGroup = {
        param($Item)
        $dn = [string]$Item['distinguishedname'][0]
        if (-not $groups.Contains($dn)) { $groups[$dn] = $Item }
    }
    $patternFilter = '(&(objectCategory=group)(|' + (($GroupPattern | ForEach-Object { "(sAMAccountName=$($_ -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29'))" }) -join '') + '))'
    foreach ($item in Search-ADInvDirectory -SearchBase $context.Default -Filter $patternFilter -Property $groupProperties) { & $addGroup $item }
    # Template ACLs also grant Domain Admins, Domain Computers, RAS and IAS Servers and similar
    # built-ins; seeding from those pulls half the directory in. Only ordinary domain groups (RID
    # 1000+) seed from templates; NPS SIDs are always deliberate.
    $templateSids = @($templates | ForEach-Object { $_.Enroll; $_.AutoEnroll } | ForEach-Object Sid | Where-Object { Test-ADInvOrdinaryDomainSid -Sid $_ })
    $seedSids = @($npsSids) + $templateSids
    foreach ($sid in ($seedSids | Select-Object -Unique)) {
        foreach ($item in Search-ADInvDirectory -SearchBase $context.Default -Filter "(&(objectCategory=group)(objectSid=$sid))" -Property $groupProperties) { & $addGroup $item }
    }
    # Widen: direct parents of every seed, then every nested member group below any of them.
    foreach ($dn in @($groups.Keys)) {
        # A group nested in nothing has no memberOf attribute at all.
        foreach ($parent in @($groups[$dn]['memberof'] | Where-Object { $_ })) {
            foreach ($item in Search-ADInvDirectory -SearchBase ([string]$parent) -Filter '(objectCategory=group)' -Property $groupProperties) { & $addGroup $item }
        }
    }
    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]@($groups.Keys))
    while ($queue.Count) {
        $dn = $queue.Dequeue()
        foreach ($item in Search-ADInvDirectory -SearchBase $context.Default -Filter "(&(objectCategory=group)(memberOf=$(& $escapeLdap $dn)))" -Property $groupProperties) {
            $childDn = [string]$item['distinguishedname'][0]
            if (-not $groups.Contains($childDn)) { & $addGroup $item; $queue.Enqueue($childDn) }
        }
    }

    $memberProperties = @('samaccountname', 'distinguishedname', 'objectsid', 'objectclass', 'useraccountcontrol')
    $enabledOf = { param($Item) if ($Item['useraccountcontrol']) { -not ([int]$Item['useraccountcontrol'][0] -band 2) } else { $null } }
    $groupList = foreach ($dn in $groups.Keys) {
        $item = $groups[$dn]
        $escaped = & $escapeLdap $dn
        $members = @(Search-ADInvDirectory -SearchBase $context.Default -Filter "(memberOf=$escaped)" -Property $memberProperties | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_['samaccountname'][0]; Class = [string]@($_['objectclass'])[-1]; Sid = & $sidOf $_; DistinguishedName = [string]$_['distinguishedname'][0]; Enabled = & $enabledOf $_ }
            })
        # LDAP_MATCHING_RULE_IN_CHAIN: every user reached through any depth of nesting.
        $users = @(Search-ADInvDirectory -SearchBase $context.Default -Filter "(&(objectCategory=person)(objectClass=user)(memberOf:1.2.840.113556.1.4.1941:=$escaped))" -Property $memberProperties | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_['samaccountname'][0]; DistinguishedName = [string]$_['distinguishedname'][0]; Enabled = & $enabledOf $_ }
            })
        [pscustomobject]@{
            Name               = [string]$item['samaccountname'][0]
            Sid                = & $sidOf $item
            DistinguishedName  = $dn
            Description        = [string]($item['description'] | Select-Object -First 1)
            MemberOf           = @(foreach ($parent in @($item['memberof'] | Where-Object { $_ })) {
                    $parentItem = if ($groups.Contains([string]$parent)) { $groups[[string]$parent] } else { $null }
                    $parentName = if ($parentItem) { [string]$parentItem['samaccountname'][0] } else { ([string]$parent -replace '^CN=([^,]+),.*$', '$1') }
                    $parentSid = if ($parentItem) { & $sidOf $parentItem } else { $null }
                    [pscustomobject]@{ Name = $parentName; Sid = $parentSid; DistinguishedName = [string]$parent }
                })
            Members            = $members
            RecursiveUsers     = $users
            RecursiveUserCount = $users.Count
        }
    }

    [pscustomobject]@{
        SchemaVersion = 1
        Generated     = (Get-Date).ToString('o')
        Domain        = $context.DnsDomain
        ComputerName  = $env:COMPUTERNAME
        Tool          = "NSP.ActiveDirectory $(Get-NSPADModuleVersion)"
        Groups        = @($groupList)
        Templates     = $templates
        TameMyCerts   = [pscustomobject]@{ PolicyDirectory = $PolicyDirectory; Source = $tmcSource; Policies = @($stamps.Values) }
        Sources       = [pscustomobject]@{ NpsConfigPath = $NpsConfigPath; GroupPattern = $GroupPattern; TemplatePattern = $TemplatePattern }
    }
}
