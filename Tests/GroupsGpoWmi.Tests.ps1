<#
    Pester 5. NSP.ActiveDirectory 0.1.4 additions: group-membership tools (from PoSHRepo's ADGroups
    scripts), the GPO catalog / portable export / import (from ExportGPO + ReplaceImportGPO), and WMI
    filters through ADSI. No real AD, GPO or LDAP is touched: AD/GPO cmdlets are stubbed when RSAT is
    missing and mocked inside the module; the ADSI wrappers are mocked.
#>

BeforeAll {
    $toolkits = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $bootstrap = @($env:NSP_ECOSYSTEM_ROOT, $toolkits, (Split-Path -Parent $toolkits)) | Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'NSP-Bootstrap\NSP.Bootstrap.psd1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $bootstrap) { throw 'NSP-Bootstrap checkout not found next to this repository (or set NSP_ECOSYSTEM_ROOT).' }
    Import-Module $bootstrap -Force -Global -ErrorAction Stop
    foreach ($m in 'NSP-Console\NSP.Console.psd1', 'NSP-Toolkit\NSP.Toolkit.psd1') { Import-Module (Join-Path $toolkits $m) -Force -Global -ErrorAction Stop }
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force -ErrorAction Stop

    $stubs = [ordered]@{
        'Get-ADGroupMember'              = 'param($Identity, [switch]$Recursive)'
        'Get-ADUser'                     = 'param($Identity, $Filter, $Properties, $SearchBase)'
        'Get-ADGroup'                    = 'param($Identity, $Properties)'
        'Get-ADPrincipalGroupMembership' = 'param($Identity)'
        'Add-ADGroupMember'              = 'param($Identity, $Members)'
        'Remove-ADGroupMember'           = 'param($Identity, $Members, [switch]$Confirm)'
        'Set-ADUser'                     = 'param($Identity, $Replace)'
        'Get-ADDomain'                   = 'param()'
        'Backup-GPO'                     = 'param($Name, $Path, $Comment)'
        'Import-GPO'                     = 'param($BackupId, $Path, $TargetName, [switch]$CreateIfNeeded)'
        'Get-GPO'                        = 'param($Name)'
        'Get-GPInheritance'              = 'param($Target)'
        'New-GPLink'                     = 'param($Name, $Target, $LinkEnabled)'
    }
    $script:stubbed = @()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) `$null"))
            $script:stubbed += $name
        }
    }
    function script:New-Member($sam, $class = 'user') { [pscustomobject]@{ SamAccountName = $sam; Name = $sam; objectClass = $class; DistinguishedName = "CN=$sam,OU=Users,DC=contoso,DC=local" } }
    function script:New-Group($name) { [pscustomobject]@{ Name = $name; SamAccountName = $name; DistinguishedName = "CN=$name,OU=Groups,DC=contoso,DC=local" } }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.ActiveDirectory, NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Group membership tools' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
    }

    It 'Compare-NSPADGroupMembership sorts members into Both / ReferenceOnly / DifferenceOnly' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { if ($Identity -eq 'Old') { New-Member 'alice'; New-Member 'bob' } else { New-Member 'bob'; New-Member 'carol' } }
        $r = @(Compare-NSPADGroupMembership -ReferenceGroup 'Old' -DifferenceGroup 'New')
        ($r | Where-Object SamAccountName -eq 'alice').Side | Should -Be 'ReferenceOnly'
        ($r | Where-Object SamAccountName -eq 'bob').Side | Should -Be 'Both'
        ($r | Where-Object SamAccountName -eq 'carol').Side | Should -Be 'DifferenceOnly'
        Compare-NSPADGroupMembership -ReferenceGroup 'Old' -DifferenceGroup 'New' -Recursive | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-ADGroupMember -ParameterFilter { $Recursive }
    }

    It 'Test-NSPADUserGroupMembership reports member / not member / group not found' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADUser { [pscustomobject]@{ SamAccountName = 'jdoe' } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { switch ($Identity) { 'VPN' { New-Member 'jdoe' } 'RDP' { New-Member 'other' } default { throw 'not found' } } }
        $r = @(Test-NSPADUserGroupMembership -User jdoe -Group 'VPN', 'RDP', 'Nope')
        ($r | Where-Object Group -eq 'VPN').IsMember | Should -BeTrue
        ($r | Where-Object Group -eq 'RDP').IsMember | Should -BeFalse
        ($r | Where-Object Group -eq 'Nope').Found | Should -BeFalse
    }

    It 'Copy-NSPADUserGroupMembership adds only missing groups, never the primary group or excluded ones' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADUser { [pscustomobject]@{ SamAccountName = $Identity; PrimaryGroup = 'CN=Domain Users,OU=Groups,DC=contoso,DC=local' } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADPrincipalGroupMembership {
            if ($Identity.SamAccountName -eq 'src') { New-Group 'Domain Users'; New-Group 'VPN'; New-Group 'Finance'; New-Group 'Admins' } else { New-Group 'Domain Users'; New-Group 'VPN' }
        }
        Mock -ModuleName NSP.ActiveDirectory Add-ADGroupMember { }
        $r = @(Copy-NSPADUserGroupMembership -SourceUser src -TargetUser dst -ExcludeGroup 'Admins' -Confirm:$false)
        ($r | Where-Object Group -eq 'Finance').Result | Should -Be 'Added'
        ($r | Where-Object Group -eq 'VPN').Result | Should -Be 'AlreadyMember'
        ($r | Where-Object Group -eq 'Admins').Result | Should -Be 'Skipped'
        ($r | Where-Object Group -eq 'Domain Users').Result | Should -Be 'Skipped'
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-ADGroupMember -Times 1 -Exactly
        Copy-NSPADUserGroupMembership -SourceUser src -TargetUser dst -WhatIf | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-ADGroupMember -Times 1 -Exactly
    }

    It 'Remove-NSPADDisabledUserGroupMembership parks a disabled user and strips its other groups' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { [pscustomobject]@{ Name = 'DisabledUsers'; DistinguishedName = 'CN=DisabledUsers,OU=Groups,DC=contoso,DC=local'; primaryGroupToken = 1234 } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADUser { [pscustomobject]@{ SamAccountName = 'gone'; DistinguishedName = 'CN=gone,OU=Users,DC=contoso,DC=local'; PrimaryGroupID = 513 } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADPrincipalGroupMembership { New-Group 'VPN'; New-Group 'Payroll'; [pscustomobject]@{ Name = 'DisabledUsers'; SamAccountName = 'DisabledUsers'; DistinguishedName = 'CN=DisabledUsers,OU=Groups,DC=contoso,DC=local' } }
        Mock -ModuleName NSP.ActiveDirectory Add-ADGroupMember { }
        Mock -ModuleName NSP.ActiveDirectory Set-ADUser { }
        Mock -ModuleName NSP.ActiveDirectory Remove-ADGroupMember { }
        $r = @(Remove-NSPADDisabledUserGroupMembership -HoldingGroup DisabledUsers -KeepGroup 'Payroll' -Confirm:$false)
        ($r | Where-Object Action -eq 'AddToHoldingGroup').Result | Should -Be 'Done'
        ($r | Where-Object Action -eq 'SetPrimaryGroup').Result | Should -Be 'Done'
        @($r | Where-Object Action -eq 'RemoveFromGroup').Group | Should -Be @('VPN')
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 1 -Exactly -ParameterFilter { $Replace.primaryGroupID -eq 1234 }
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-ADUser -ParameterFilter { $Filter -eq 'Enabled -eq $false' }
    }

    It 'Remove-NSPADDisabledUserGroupMembership -WhatIf changes nothing' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { [pscustomobject]@{ Name = 'DisabledUsers'; DistinguishedName = 'CN=DisabledUsers'; primaryGroupToken = 1234 } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADUser { [pscustomobject]@{ SamAccountName = 'gone'; DistinguishedName = 'CN=gone'; PrimaryGroupID = 513 } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADPrincipalGroupMembership { New-Group 'VPN' }
        Mock -ModuleName NSP.ActiveDirectory Add-ADGroupMember { }
        Mock -ModuleName NSP.ActiveDirectory Set-ADUser { }
        Mock -ModuleName NSP.ActiveDirectory Remove-ADGroupMember { }
        $r = @(Remove-NSPADDisabledUserGroupMembership -HoldingGroup DisabledUsers -WhatIf)
        @($r | Where-Object Result -ne 'WhatIf').Count | Should -Be 0
        Should -Invoke -ModuleName NSP.ActiveDirectory Remove-ADGroupMember -Times 0
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0
    }

    It 'Export-NSPADGroupMembershipReport writes one CSV per group and archives the previous run' {
        $dir = Join-Path $TestDrive ('rep_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'old.csv') -Value 'x'
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { New-Member 'alice'; New-Member 'PC01$' 'computer' }
        Mock -ModuleName NSP.ActiveDirectory Get-ADUser { [pscustomobject]@{ GivenName = 'Alice'; Surname = 'Example'; UserPrincipalName = 'alice@contoso.local'; SamAccountName = 'alice' } }
        $files = @(Export-NSPADGroupMembershipReport -Group 'All Staff' -Path $dir)
        $files.Count | Should -Be 1
        $rows = @(Import-Csv -LiteralPath $files[0].FullName)
        $rows.Count | Should -Be 1
        $rows[0].UserPrincipalName | Should -Be 'alice@contoso.local'
        Test-Path -LiteralPath (Join-Path $dir 'PastReports\old.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'old.csv') | Should -BeFalse
    }
}

Describe 'GPO backups' {
    BeforeAll {
        # A minimal portable backup: manifest.xml + {GUID}\bkupInfo.xml (hidden) / Backup.xml / gpreport.xml.
        function script:New-FakeGpoBackup([string]$Root, [string]$Name = 'NSP - TLS1 - Enable TLS 1.2') {
            $guidDir = Join-Path $Root '{11111111-2222-3333-4444-555555555555}'
            New-Item -ItemType Directory -Path $guidDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Root 'manifest.xml') -Value "<Backups><BackupInst><GPODisplayName><![CDATA[$Name]]></GPODisplayName><GPODomainController><![CDATA[DC.contoso.com]]></GPODomainController></BackupInst></Backups>"
            $info = Join-Path $guidDir 'bkupInfo.xml'
            Set-Content -LiteralPath $info -Value "<BackupInst xmlns=`"http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest`"><GPOGuid><![CDATA[{AAAA}]]></GPOGuid><GPODomain><![CDATA[contoso.com]]></GPODomain><GPODomainController><![CDATA[DC.contoso.com]]></GPODomainController><BackupTime><![CDATA[2026-01-01T00:00:00]]></BackupTime><ID><![CDATA[{11111111-2222-3333-4444-555555555555}]]></ID><GPODisplayName><![CDATA[$Name]]></GPODisplayName></BackupInst>"
            (Get-Item -LiteralPath $info).Attributes = 'Hidden'
            [IO.File]::WriteAllText((Join-Path $guidDir 'Backup.xml'), '<x>\\CONTOSO\SYSVOL\contoso.com\Policies on DC.contoso.com</x>', [Text.Encoding]::Unicode)
            Set-Content -LiteralPath (Join-Path $guidDir 'gpreport.xml') -Value '<r>contoso.com CONTOSO</r>'
            return $Root
        }
    }
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'dc01.fabrikam.local'; DNSRoot = 'fabrikam.local'; NetBIOSName = 'FABRIKAM'; DistinguishedName = 'DC=fabrikam,DC=local' } }
    }

    It 'replaces DC, DNS and NetBIOS names in that order (pure)' {
        $to = [ordered]@{ Pdc = 'dc01.fabrikam.local'; Dns = 'fabrikam.local'; NetBios = 'FABRIKAM' }
        $out = InModuleScope NSP.ActiveDirectory -Parameters @{ T = $to } { param($T) Convert-NSPADGpoBackupText -Text 'DC.contoso.com | contoso.com | CONTOSO\x' -From $script:NSPADGpoPlaceholder -To $T }
        $out | Should -Be 'dc01.fabrikam.local | fabrikam.local | FABRIKAM\x'
    }

    It 'Get-NSPADGpoCatalog finds hidden bkupInfo.xml backups and zips, with their category' {
        $cat = Join-Path $TestDrive ('cat_' + [guid]::NewGuid().ToString('N'))
        New-FakeGpoBackup (Join-Path $cat 'TLS\TLS1') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $cat 'Zips') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cat 'Zips\Old.zip') -Value 'x'
        $c = @(Get-NSPADGpoCatalog -Path $cat)
        $b = $c | Where-Object Kind -eq 'Backup'
        $b.DisplayName | Should -Be 'NSP - TLS1 - Enable TLS 1.2'
        $b.Category | Should -Be 'TLS'
        $b.BackupId | Should -Be '{11111111-2222-3333-4444-555555555555}'
        ($c | Where-Object Kind -eq 'Zip').DisplayName | Should -Be 'Old'
    }

    It 'Import-NSPADGpoBackup imports a converted COPY - the catalog files never change' {
        $src = New-FakeGpoBackup (Join-Path $TestDrive ('src_' + [guid]::NewGuid().ToString('N')))
        $before = Get-Content -LiteralPath (Join-Path $src '{11111111-2222-3333-4444-555555555555}\gpreport.xml') -Raw
        $script:imported = $null
        Mock -ModuleName NSP.ActiveDirectory Import-GPO {
            $script:imported = Get-Content -LiteralPath (Join-Path $Path '{11111111-2222-3333-4444-555555555555}\gpreport.xml') -Raw
            $script:importedBackup = [IO.File]::ReadAllText((Join-Path $Path '{11111111-2222-3333-4444-555555555555}\Backup.xml'))
            $script:importArgs = @{ BackupId = $BackupId; TargetName = $TargetName }
        }
        Mock -ModuleName NSP.ActiveDirectory Get-GPO { [pscustomobject]@{ DisplayName = $Name } }
        $r = Import-NSPADGpoBackup -Path $src -Confirm:$false
        $r.GpoName | Should -Be 'NSP - TLS1 - Enable TLS 1.2'
        $script:importArgs.BackupId | Should -Be '{11111111-2222-3333-4444-555555555555}'
        $script:imported | Should -Match 'fabrikam\.local FABRIKAM'
        $script:importedBackup | Should -Match '\\\\FABRIKAM\\SYSVOL\\fabrikam\.local\\Policies on dc01\.fabrikam\.local' -Because 'UTF-16 Backup.xml keeps its encoding and is converted'
        (Get-Content -LiteralPath (Join-Path $src '{11111111-2222-3333-4444-555555555555}\gpreport.xml') -Raw) | Should -Be $before
    }

    It 'Import-NSPADGpoBackup -WhatIf imports nothing' {
        $src = New-FakeGpoBackup (Join-Path $TestDrive ('wi_' + [guid]::NewGuid().ToString('N')))
        Mock -ModuleName NSP.ActiveDirectory Import-GPO { }
        Import-NSPADGpoBackup -Path $src -WhatIf | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0
    }

    It 'Export-NSPADGpoBackup -Genericize puts the placeholders into the backup' {
        $out = Join-Path $TestDrive ('exp_' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName NSP.ActiveDirectory Backup-GPO {
            $g = Join-Path $Path '{99999999-2222-3333-4444-555555555555}'
            New-Item -ItemType Directory -Path $g -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $g 'gpreport.xml') -Value '<r>dc01.fabrikam.local fabrikam.local FABRIKAM</r>'
        }
        $dir = @(Export-NSPADGpoBackup -Name 'Test GPO' -Path $out -Genericize -Confirm:$false)
        $dir[0].Name | Should -Be 'Test GPO'
        (Get-Content -LiteralPath (Join-Path $dir[0].FullName '{99999999-2222-3333-4444-555555555555}\gpreport.xml') -Raw) | Should -Match 'DC\.contoso\.com contoso\.com contoso'
    }
}

Describe 'WMI filters through ADSI' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { [pscustomobject]@{ DNSRoot = 'contoso.local'; DistinguishedName = 'DC=contoso,DC=local' } }
    }
    AfterEach { Set-NSPDryRun -Enabled $true }

    It 'encodes and decodes msWMI-Parm2 (one and several queries, a ";" inside a query)' {
        InModuleScope NSP.ActiveDirectory {
            $one = ConvertTo-NSPADWmiParm2 -Query 'select * from Win32_OperatingSystem WHERE (ProductType = "2")'
            $one | Should -Be '1;3;10;61;WQL;root\CIMv2;select * from Win32_OperatingSystem WHERE (ProductType = "2");'
            $two = ConvertTo-NSPADWmiParm2 -Query 'Select * from A', 'select * from B where X = ";"'
            @(ConvertFrom-NSPADWmiParm2 -Parm2 $two) | Should -Be @('Select * from A', 'select * from B where X = ";"')
            @(ConvertFrom-NSPADWmiParm2 -Parm2 '') | Should -HaveCount 0
        }
    }

    It 'New-NSPADWmiFilter creates a missing filter, skips a matching one, updates a drifted one' {
        Set-NSPDryRun -Enabled $false
        Mock -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry { 'CN={X}' }
        $f = (Get-NSPADWellKnownWmiFilter)[0]
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { }
        New-NSPADWmiFilter -Filter $f
        Should -Invoke -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry -Times 1 -Exactly -ParameterFilter { $Name -eq $f.Name -and -not $DN -and @($Query)[0] -eq @($f.Expression)[0] }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { [pscustomobject]@{ Name = $f.Name; Description = $f.Description; Query = @($f.Expression); Id = '{X}'; DN = 'CN={X},CN=SOM' } }
        New-NSPADWmiFilter -Filter $f
        Should -Invoke -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry -Times 1 -Exactly
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { [pscustomobject]@{ Name = $f.Name; Description = 'old'; Query = @('select 1'); Id = '{X}'; DN = 'CN={X},CN=SOM' } }
        New-NSPADWmiFilter -Filter $f
        Should -Invoke -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry -Times 1 -Exactly -ParameterFilter { $DN -eq 'CN={X},CN=SOM' }
    }

    It 'New-NSPADWmiFilter writes nothing in dry run or with -WhatIf' {
        Mock -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { }
        New-NSPADWmiFilter -Filter (Get-NSPADWellKnownWmiFilter)[0]
        Set-NSPDryRun -Enabled $false
        New-NSPADWmiFilter -Filter (Get-NSPADWellKnownWmiFilter)[0] -WhatIf
        Should -Invoke -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry -Times 0
    }

    It 'Set-NSPADGpoWmiFilter points the GPO at the filter id, and refuses an unknown filter' {
        Set-NSPDryRun -Enabled $false
        Mock -ModuleName NSP.ActiveDirectory Get-GPO { [pscustomobject]@{ Id = [guid]'aaaaaaaa-0000-0000-0000-000000000001'; WmiFilter = $null } }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { [pscustomobject]@{ Name = 'NSP_AT - All Servers'; Id = '{F1}' } }
        Mock -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute { }
        Set-NSPADGpoWmiFilter -GpoName 'Test GPO' -WmiFilterName 'NSP_AT - All Servers'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute -Times 1 -Exactly -ParameterFilter { $WmiFilterId -eq '{F1}' -and $GpoGuid -eq 'aaaaaaaa-0000-0000-0000-000000000001' -and $DnsRoot -eq 'contoso.local' }
        { Set-NSPADGpoWmiFilter -GpoName 'Test GPO' -WmiFilterName 'Missing' } | Should -Throw '*does not exist*'
    }

    It 'the AD Manager menu no longer installs BW.Utils' {
        $src = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'Private\MenuHandlers.ps1') -Raw
        $src | Should -Not -Match '(?m)^\s*Install-NSPADWmiFilterModule'
    }
}
