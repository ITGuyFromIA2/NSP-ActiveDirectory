<#
    Pester 5. Ported from NSP-FGTIPSecTools' ADManager.Chassis / ADManager.VpnInventory /
    ADProvisioning tests. No real AD, GPO or LDAP is touched: AD/GPO cmdlets are stubbed as global
    functions where the machine lacks RSAT and mocked inside the module, and the LDAP wrappers are
    mocked. NSP_TOOLKIT_ROOT points the work folder at $TestDrive.
#>

BeforeAll {
    # Sibling checkouts first, so the module's on-demand loader finds them already loaded.
    $toolkits = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path (Split-Path -Parent $toolkits) 'NSP-Bootstrap\NSP.Bootstrap.psd1') -Force -Global -ErrorAction Stop
    foreach ($m in 'NSP-Console\NSP.Console.psd1', 'NSP-Toolkit\NSP.Toolkit.psd1', 'NSP-ClientScripts\NSP.ClientScripts.psd1') {
        Import-Module (Join-Path $toolkits $m) -Force -Global -ErrorAction Stop
    }
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force -ErrorAction Stop

    # RSAT may be absent on the test host: give Pester real commands (with the parameters the module
    # passes) to mock.
    $stubs = [ordered]@{
        'Get-ADOrganizationalUnit' = 'param($Identity, $SearchBase, $SearchScope, $Filter)'
        'New-ADOrganizationalUnit' = 'param($Name, $Path, $Description)'
        'Get-ADGroup'              = 'param($Identity, $LDAPFilter, $Filter, $SearchBase, $SearchScope)'
        'New-ADGroup'              = 'param($Name, $SamAccountName, $GroupScope, $GroupCategory, $Path, $Description, [switch]$PassThru)'
        'Get-ADGroupMember'        = 'param($Identity)'
        'Add-ADGroupMember'        = 'param($Identity, $Members)'
        'Get-ADDomain'             = 'param()'
        'Get-GPO'                  = 'param($Name)'
        'New-GPO'                  = 'param($Name)'
        'Set-GPRegistryValue'      = 'param($Name, $Key, $ValueName, $Type, $Value)'
        'Get-GPInheritance'        = 'param($Target)'
        'New-GPLink'               = 'param($Name, $Target, $LinkEnabled)'
    }
    $script:stubbed = @()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) `$null"))
            $script:stubbed += $name
        }
    }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.ActiveDirectory, NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'NSP.ActiveDirectory' {

    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
    }

    Context 'Scaffold plan (pure)' {
        It 'has four purpose groups; DNS is conditional' {
            $d = @(Get-NSPADPurposeGroupDefault)
            $d.Count | Should -Be 4
            ($d | Where-Object Key -eq 'RDS').DefaultName | Should -Be 'VPNFW_Internal_RDP_Network'
            ($d | Where-Object Key -eq 'DNS').Always | Should -BeFalse
        }

        It 'uses generic defaults with no client answers' {
            $p = Get-NSPADScaffoldPlan -ClientAnswers $null -BaseOU 'OU=Clients,DC=example,DC=test'
            $p.MainGroupName | Should -Be 'IKEv2_InternalUsers'
            $p.VpnGroupsOU | Should -Be 'OU=VPNGroups,OU=Clients,DC=example,DC=test'
            $p.FwRulesOU | Should -Be 'OU=FWRules,OU=VPNGroups,OU=Clients,DC=example,DC=test'
            @($p.PurposeGroups).Count | Should -Be 4
        }

        It 'uses the client answers, and drops DNS unless the mode is Universal' {
            $answers = [pscustomobject]@{ Auth_UserGroup_Value = 'IKEv2_Example_Users'; VPNFW_DCComms_GroupName = 'VPNFW_Example_DC'; VPNFW_DNS_Mode = 'PerGroup' }
            $p = Get-NSPADScaffoldPlan -ClientAnswers $answers -BaseOU 'OU=Clients,DC=example,DC=test'
            $p.MainGroupName | Should -Be 'IKEv2_Example_Users'
            ($p.PurposeGroups | Where-Object Key -eq 'DCComms').Name | Should -Be 'VPNFW_Example_DC'
            @($p.PurposeGroups).Count | Should -Be 3
            @($p.PurposeGroups | Where-Object Key -eq 'DNS').Count | Should -Be 0
        }

        It 'falls back when an answer is present but blank' {
            (Get-NSPADScaffoldPlan -ClientAnswers ([pscustomobject]@{ Auth_UserGroup_Value = '' }) -BaseOU 'DC=x').MainGroupName | Should -Be 'IKEv2_InternalUsers'
        }
    }

    Context 'Provisioning primitives (dry run and apply)' {
        BeforeEach {
            Mock -ModuleName NSP.Toolkit Write-Host { }
            Mock -ModuleName NSP.ActiveDirectory Write-Host { }
            $script:created = New-Object System.Collections.Generic.List[string]
            Mock -ModuleName NSP.ActiveDirectory New-ADOrganizationalUnit { $script:created.Add("OU:$Name|$Path") }
            Mock -ModuleName NSP.ActiveDirectory New-ADGroup { $script:created.Add("GROUP:$Name|$Path"); [pscustomobject]@{ DistinguishedName = "CN=$Name,$Path" } }
        }
        AfterEach { Set-NSPDryRun -Enabled $true }

        It 'creates the whole scaffold once, then nothing on a re-run' {
            Set-NSPDryRun -Enabled $false
            Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit { $null }
            Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { $null }
            $plan = Get-NSPADScaffoldPlan -ClientAnswers $null -BaseOU 'OU=Clients,DC=example,DC=test'
            New-NSPADVpnGroupScaffold -Plan $plan
            @($script:created | Where-Object { $_ -like 'OU:*' }).Count | Should -Be 2
            @($script:created | Where-Object { $_ -like 'GROUP:*' }).Count | Should -Be 5
            $script:created | Should -Contain 'GROUP:IKEv2_InternalUsers|OU=VPNGroups,OU=Clients,DC=example,DC=test'
            $script:created | Should -Contain 'GROUP:VPNFW_Internal_DCComms|OU=FWRules,OU=VPNGroups,OU=Clients,DC=example,DC=test'

            $script:created.Clear()
            Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = 'x' } }
            Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { [pscustomobject]@{ DistinguishedName = 'x' } }
            New-NSPADVpnGroupScaffold -Plan $plan
            $script:created.Count | Should -Be 0
        }

        It 'changes nothing in dry run and predicts the DN' {
            Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { $null }
            New-NSPADGroup -Name 'VPN Staff' -Path 'OU=X,DC=example,DC=test' | Should -Be 'CN=VPN Staff,OU=X,DC=example,DC=test'
            $script:created.Count | Should -Be 0
        }

        It 'checks group existence by a sanitized sAMAccountName' {
            Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { $null }
            New-NSPADGroup -Name 'VPN Staff (all)' -Path 'OU=X' | Out-Null
            Should -Invoke -ModuleName NSP.ActiveDirectory Get-ADGroup -ParameterFilter { $LDAPFilter -eq '(sAMAccountName=VPNStaffall)' }
        }

        It 'skips nesting a group that is already a member' {
            Set-NSPDryRun -Enabled $false
            Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { [pscustomobject]@{ DistinguishedName = 'CN=M'; SamAccountName = 'M'; Name = 'M' } }
            Mock -ModuleName NSP.ActiveDirectory Add-ADGroupMember { }
            Add-NSPADGroupMember -GroupIdentity 'CN=G' -MemberIdentity 'CN=M'
            Should -Invoke -ModuleName NSP.ActiveDirectory Add-ADGroupMember -Times 0 -Exactly
            Add-NSPADGroupMember -GroupIdentity 'CN=G' -MemberIdentity 'CN=Other'
            Should -Invoke -ModuleName NSP.ActiveDirectory Add-ADGroupMember -Times 1 -Exactly
        }

        It 'creates, sets and links the auto-enroll GPO' {
            Set-NSPDryRun -Enabled $false
            Mock -ModuleName NSP.ActiveDirectory Get-GPO { $null }
            Mock -ModuleName NSP.ActiveDirectory New-GPO { }
            Mock -ModuleName NSP.ActiveDirectory Set-GPRegistryValue { }
            Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { [pscustomobject]@{ GpoLinks = @() } }
            Mock -ModuleName NSP.ActiveDirectory New-GPLink { }
            New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -DomainDn 'DC=example,DC=test'
            Should -Invoke -ModuleName NSP.ActiveDirectory New-GPO -Times 1 -Exactly
            Should -Invoke -ModuleName NSP.ActiveDirectory Set-GPRegistryValue -Times 3 -Exactly
            Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 1 -Exactly -ParameterFilter { $Target -eq 'DC=example,DC=test' }
        }

        It 'does not relink a GPO that is already linked' {
            Set-NSPDryRun -Enabled $false
            Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { [pscustomobject]@{ GpoLinks = @([pscustomobject]@{ DisplayName = 'Test GPO' }) } }
            Mock -ModuleName NSP.ActiveDirectory New-GPLink { }
            New-NSPADGpoLink -GpoName 'Test GPO' -TargetDN 'DC=x'
            Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
        }
    }

    Context 'GPO and WMI data (pure)' {
        It 'carries the captured auto-enroll values' {
            $g = @(Get-NSPADAutoEnrollGpoPlan)
            $g.Count | Should -Be 3
            ($g | Where-Object ValueName -eq 'AEPolicy').Value | Should -Be 7
            ($g | Where-Object ValueName -eq 'AEPolicy').Key | Should -Be 'HKCU\Software\Policies\Microsoft\Cryptography\AutoEnrollment'
            @(Get-NSPADAutoEnrollGpoPlan -IncludeComputerConfig).Count | Should -Be 6
        }
        It 'lists the six well-known WMI filters' {
            $f = @(Get-NSPADWellKnownWmiFilter)
            $f.Count | Should -Be 6
            @(($f | Where-Object Name -eq 'NSP_AT - All NON-PDC Domain Controllers').Expression).Count | Should -Be 2
        }
    }

    Context 'Inventory helpers (pure)' {
        It 'decodes template periods' {
            InModuleScope NSP.ActiveDirectory {
                ConvertFrom-ADTemplatePeriod -Bytes ([BitConverter]::GetBytes([int64](-365 * 864000000000))) | Should -Be 365
                ConvertFrom-ADTemplatePeriod -Bytes ([byte[]](1, 2)) | Should -BeNullOrEmpty
            }
        }
        It 'reads TameMyCerts OU stamps and NPS SIDs' {
            InModuleScope NSP.ActiveDirectory {
                $xml = '<CertificateRequestPolicy><OutboundSubject><OutboundSubjectRule><Field>organizationalUnitName</Field><Value>vpn-staff</Value></OutboundSubjectRule></OutboundSubject></CertificateRequestPolicy>'
                Get-ADTameMyCertsOuStamp -XmlText $xml | Should -Be 'vpn-staff'
                Get-ADTameMyCertsOuStamp -XmlText 'not xml' | Should -BeNullOrEmpty
                $ias = 'USERNTGROUPS("S-1-5-21-1-2-3-3001") USERNTGROUPS(&quot;S-1-5-21-1-2-3-3002&quot;;&quot;S-1-5-21-1-2-3-3001&quot;)'
                (@(Get-ADNpsGroupSids -IasText $ias) -join ',') | Should -Be 'S-1-5-21-1-2-3-3001,S-1-5-21-1-2-3-3002'
            }
        }
        It 'classifies enroll rights and ordinary SIDs' {
            InModuleScope NSP.ActiveDirectory {
                $access = Get-ADTemplateAccess -Rule @(
                    @{ Sid = 'S-1-5-11'; Name = 'Authenticated Users'; Allow = $true; Rights = 'GenericRead'; ObjectType = [guid]::Empty }
                    @{ Sid = 'S-A'; Name = 'EX\AutoGroup'; Allow = $true; Rights = 'ExtendedRight'; ObjectType = $script:ADInvAutoEnrollGuid }
                    @{ Sid = 'S-D'; Name = 'EX\Domain Admins'; Allow = $true; Rights = 'ExtendedRight'; ObjectType = [guid]::Empty }
                    @{ Sid = 'S-X'; Name = 'EX\Denied'; Allow = $false; Rights = 'ExtendedRight'; ObjectType = $script:ADInvEnrollGuid }
                )
                (($access.AutoEnroll | ForEach-Object Name) -join ',') | Should -Be 'EX\AutoGroup,EX\Domain Admins'
                (($access.Enroll | ForEach-Object Name) -join ',') | Should -Be 'EX\Domain Admins'
                Test-ADInvOrdinaryDomainSid -Sid 'S-1-5-21-1-2-3-12632' | Should -BeTrue
                Test-ADInvOrdinaryDomainSid -Sid 'S-1-5-21-1-2-3-512' | Should -BeFalse
                Test-ADInvOrdinaryDomainSid -Sid 'S-1-5-18' | Should -BeFalse
            }
        }
    }

    Context 'Get-NSPADVpnInventory against a mocked directory' {
        BeforeAll {
            $script:year = [BitConverter]::GetBytes([int64](-365 * 864000000000))
            $script:sixWeeks = [BitConverter]::GetBytes([int64](-42 * 864000000000))
            $sidBytes = { param([string]$Sid) $s = New-Object System.Security.Principal.SecurityIdentifier($Sid); $b = New-Object byte[] $s.BinaryLength; $s.GetBinaryForm($b, 0); , $b }
            $dc = 'DC=example,DC=test'
            $script:staffDn = "CN=IKEv2_Staff,OU=VPN,$dc"; $script:smbDn = "CN=VPNFW_Internal_SMBComms,OU=VPN,$dc"
            $sslDn = "CN=SSLVPN_Users,OU=VPN,$dc"; $subDn = "CN=Staff_Contractors,OU=VPN,$dc"
            $group = {
                param($Dn, $Name, $Sid, $MemberOf)
                $item = @{ distinguishedname = @($Dn); samaccountname = @($Name); objectsid = @(, (& $sidBytes $Sid)); objectclass = @('top', 'group') }
                if (@($MemberOf).Count) { $item['memberof'] = @($MemberOf) }
                $item
            }
            $user = { param($Dn, $Name, $Uac) @{ distinguishedname = @($Dn); samaccountname = @($Name); objectsid = @(, (& $sidBytes 'S-1-5-21-1-2-3-9999')); objectclass = @('top', 'person', 'user'); useraccountcontrol = @($Uac) } }
            $script:dir = @{
                Staff = & $group $staffDn 'IKEv2_Staff' 'S-1-5-21-1-2-3-3001' @($smbDn)
                Smb   = & $group $smbDn 'VPNFW_Internal_SMBComms' 'S-1-5-21-1-2-3-3100' @()
                Ssl   = & $group $sslDn 'SSLVPN_Users' 'S-1-5-21-1-2-3-3002' @()
                Sub   = & $group $subDn 'Staff_Contractors' 'S-1-5-21-1-2-3-3003' @($staffDn)
                Alice = & $user "CN=Alice,$dc" 'alice' 512
                Bob   = & $user "CN=Bob,$dc" 'bob' 514
            }
            $script:policyXml = '<CertificateRequestPolicy><OutboundSubject><OutboundSubjectRule><Field>organizationalUnitName</Field><Value>vpn-staff</Value></OutboundSubjectRule></OutboundSubject></CertificateRequestPolicy>'
            $script:iasText = 'USERNTGROUPS("S-1-5-21-1-2-3-3002")'
        }

        BeforeEach {
            $script:tmcDir = Join-Path $TestDrive ('tmc_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:tmcDir | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:tmcDir 'NSPIKEv2Staff.xml'), $script:policyXml)
            $script:iasPath = Join-Path $script:tmcDir 'ias.xml'
            [IO.File]::WriteAllText($script:iasPath, $script:iasText)

            Mock -ModuleName NSP.ActiveDirectory Get-ADInvNamingContext { [pscustomobject]@{ Default = 'DC=example,DC=test'; Configuration = 'CN=Configuration,DC=example,DC=test'; DnsDomain = 'example.test' } }
            Mock -ModuleName NSP.ActiveDirectory Get-ADInvTameMyCertsDirectory { $script:tmcDir }
            Mock -ModuleName NSP.ActiveDirectory Get-ADInvAccessRule {
                if ($DistinguishedName -like 'CN=NSPIKEv2Staff,*') { @{ Sid = 'S-1-5-21-1-2-3-3001'; Name = 'EX\IKEv2_Staff'; Allow = $true; Rights = 'ExtendedRight'; ObjectType = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2' } }
            }
            Mock -ModuleName NSP.ActiveDirectory Search-ADInvDirectory {
                if ([string]::IsNullOrEmpty($SearchBase)) { throw "empty SearchBase (filter $Filter)" }
                switch -Regex ($Filter) {
                    'pKIEnrollmentService' { return @{ cn = @('Example-CA'); certificatetemplates = @('NSPIKEv2Staff', 'User') } }
                    'pKICertificateTemplate' {
                        $t = { param($Name, $Schema, $Eku) @{ cn = @($Name); displayname = @("$Name display"); distinguishedname = @("CN=$Name,CN=Certificate Templates"); 'mspki-template-schema-version' = @($Schema); pkiextendedkeyusage = @($Eku); pkiexpirationperiod = @(, $script:year); pkioverlapperiod = @(, $script:sixWeeks); 'mspki-certificate-name-flag' = @(1) } }
                        return @((& $t 'NSPIKEv2Staff' 2 '1.3.6.1.5.5.7.3.2'), (& $t 'DomainControllerAuthentication' 2 '1.3.6.1.5.5.7.3.2'), (& $t 'WebServer' 2 '1.3.6.1.5.5.7.3.1'), (& $t 'User' 1 '1.3.6.1.5.5.7.3.2'))
                    }
                    'sAMAccountName=IKEv2\*' { return @($script:dir.Staff, $script:dir.Smb) }
                    'objectSid=S-1-5-21-1-2-3-3002' { return @($script:dir.Ssl) }
                    'objectSid=S-1-5-21-1-2-3-3001' { return @($script:dir.Staff) }
                    'objectCategory=group\)\(memberOf=CN=IKEv2_Staff' { return @($script:dir.Sub) }
                    '^\(objectCategory=group\)$' { if ($SearchBase -eq $script:smbDn) { return @($script:dir.Smb) }; return }
                    '1\.2\.840\.113556\.1\.4\.1941:=CN=IKEv2_Staff' { return @($script:dir.Alice, $script:dir.Bob) }
                    '^\(memberOf=CN=IKEv2_Staff' { return @($script:dir.Alice, $script:dir.Sub) }
                    default { return }
                }
            }
        }

        It 'collects templates, groups, nesting and users' {
            $inv = Get-NSPADVpnInventory -GroupPattern 'IKEv2*' -NpsConfigPath $script:iasPath
            $inv.SchemaVersion | Should -Be 1
            $inv.Domain | Should -Be 'example.test'
            $inv.Tool | Should -Match '^NSP\.ActiveDirectory '
            $templates = @($inv.Templates)
            (($templates | ForEach-Object Name) -join ',') | Should -Be 'NSPIKEv2Staff'
            $templates[0].ValidityDays | Should -Be 365
            $templates[0].RenewalDays | Should -Be 42
            $templates[0].OuStamp | Should -Be 'vpn-staff'
            (@($templates[0].AutoEnroll) | ForEach-Object Name) | Should -Be 'EX\IKEv2_Staff'
            $inv.TameMyCerts.Source | Should -Be 'CA registry'

            $byName = @{}; foreach ($g in $inv.Groups) { $byName[$g.Name] = $g }
            $byName.ContainsKey('SSLVPN_Users') | Should -BeTrue
            $byName.ContainsKey('Staff_Contractors') | Should -BeTrue
            $staff = $byName['IKEv2_Staff']
            $staff.Sid | Should -Be 'S-1-5-21-1-2-3-3001'
            (@($staff.MemberOf) | ForEach-Object Name) | Should -Be 'VPNFW_Internal_SMBComms'
            @($byName['VPNFW_Internal_SMBComms'].MemberOf).Count | Should -Be 0
            ((@($staff.Members) | ForEach-Object { "$($_.Name):$($_.Class)" }) -join ',') | Should -Be 'alice:user,Staff_Contractors:group'
            ((@($staff.RecursiveUsers) | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ',') | Should -Be 'alice=True,bob=False'
        }

        It 'writes a hand-off by default and the bare inventory with -Format Legacy' {
            $r = Export-NSPADVpnInventory -Company 'Example Co' -GroupPattern 'IKEv2*' -NpsConfigPath $script:iasPath
            Split-Path -Leaf $r.Path | Should -Be 'ExampleCo_AD_Response.json'
            $h = Import-NSPHandoff -Path $r.Path -Tool AD -Kind Response
            $h.HashValid | Should -BeTrue
            $h.Payload.SchemaVersion | Should -Be 1
            @($h.Payload.Templates)[0].OuStamp | Should -Be 'vpn-staff'

            $l = Export-NSPADVpnInventory -Format Legacy -OutputDirectory $script:tmcDir -GroupPattern 'IKEv2*' -NpsConfigPath $script:iasPath
            Split-Path -Leaf $l.Path | Should -Match '^ADInventory_example\.test_\d{8}_\d{6}\.json$'
            (Import-NSPHandoff -Path $l.Path).LegacyFormat | Should -Be 'ADInventory'
        }
    }

    Context 'Start-NSPADManager seeding and New-NSPADShim' {
        It 'merges seed answers into the work folder with -SeedOnly' {
            Mock -ModuleName NSP.Toolkit Write-Host { }
            Start-NSPADManager -SeedAnswersJson '{"CompanyName":"Example Co","Auth_UserGroup_Value":"VPN_Staff"}' -SeedOnly
            (Get-NSPToolAnswers -Tool AD).Auth_UserGroup_Value | Should -Be 'VPN_Staff'
        }

        It 'writes a launcher that parses and carries the answers' {
            $p = Join-Path $TestDrive 'AD-Manager.ps1'
            $f = New-NSPADShim -Answers @{ CompanyName = 'Example Co'; Auth_UserGroup_Value = 'VPN_Staff' } -Path $p -GeneratedBy 'test' -Force
            $f | Should -BeOfType [IO.FileInfo]
            $text = Get-Content -LiteralPath $p -Raw
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$parseErrors) | Out-Null
            $parseErrors | Should -BeNullOrEmpty
            $text | Should -Match "EntryFunction\s+= 'Start-NSPADManager'"
            $text | Should -Match 'Prepared for: Example Co'
            $text | Should -Match '"Auth_UserGroup_Value":\s+"VPN_Staff"'
        }

        It 'accepts answers as a JSON string and refuses invalid JSON' {
            { New-NSPADShim -Answers '{ nope' -Path (Join-Path $TestDrive 'x.ps1') } | Should -Throw '*not valid JSON*'
            New-NSPADShim -Answers '{"CompanyName":"J"}' -Path (Join-Path $TestDrive 'j.ps1') | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Open-NSPOutputFolder' {
    BeforeEach {
        $script:SavedNoExplorer = $env:NSP_NO_EXPLORER
        $env:NSP_NO_EXPLORER = $null
        Mock -ModuleName NSP.ActiveDirectory Start-Process { }
        $script:Dir = Join-Path $TestDrive ('out_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        $script:File = Join-Path $Dir 'Contoso_AD_Response.json'
        '{}' | Set-Content -LiteralPath $File
    }
    AfterEach { $env:NSP_NO_EXPLORER = $script:SavedNoExplorer }

    It 'opens Explorer on the folder the hand-back file is in' {
        InModuleScope NSP.ActiveDirectory -Parameters @{ F = $File } { param($F) Open-NSPOutputFolder -Path $F }
        Should -Invoke -ModuleName NSP.ActiveDirectory Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'explorer.exe' -and "$ArgumentList" -eq ('"{0}"' -f $Dir)
        }
    }
    It 'does nothing for a folder that was never written (dry run)' {
        InModuleScope NSP.ActiveDirectory -Parameters @{ F = (Join-Path $TestDrive 'missing\x.json') } { param($F) Open-NSPOutputFolder -Path $F }
        Should -Invoke -ModuleName NSP.ActiveDirectory Start-Process -Times 0
    }
    It 'does nothing with NSP_NO_EXPLORER=1' {
        $env:NSP_NO_EXPLORER = '1'
        InModuleScope NSP.ActiveDirectory -Parameters @{ F = $File } { param($F) Open-NSPOutputFolder -Path $F }
        Should -Invoke -ModuleName NSP.ActiveDirectory Start-Process -Times 0
    }
}