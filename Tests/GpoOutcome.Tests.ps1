<#
    Pester 5. What Import-NSPADGpoBackup and New-NSPADAutoEnrollGpo report, and when they stop.
    A caller that is not a person at a menu has only the result and the exception to go by, so:
      - a lookup that can fail must fail BEFORE anything is written;
      - the result must say what the directory holds, not what was asked for;
      - a failed step must throw, not print.
    No real AD, GPO or LDAP is touched: the AD/GPO cmdlets are stubbed when RSAT is missing and
    mocked inside the module; the ADSI helpers are mocked. The mocks keep a small fake directory
    ($Directory) so a read after a write sees the write.
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
        'Get-ADDomain'        = 'param()'
        'Import-GPO'          = 'param($BackupId, $Path, $TargetName, [switch]$CreateIfNeeded)'
        'Get-GPO'             = 'param($Name)'
        'New-GPO'             = 'param($Name)'
        'Set-GPRegistryValue' = 'param($Name, $Key, $ValueName, $Type, $Value)'
        'Get-GPInheritance'   = 'param($Target)'
        'New-GPLink'          = 'param($Name, $Target, $LinkEnabled)'
    }
    $script:stubbed = @()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) `$null"))
            $script:stubbed += $name
        }
    }
    $script:RealUserDnsDomain = $env:USERDNSDOMAIN
    $script:BackupGuid = '{11111111-2222-3333-4444-555555555555}'
    $script:GpoName = 'NSP - TLS1 - Enable TLS 1.2'
    $script:FilterName = 'NSP_AT - All Servers'

    function script:New-FakeGpoBackup([string]$Root) {
        $guidDir = Join-Path $Root $script:BackupGuid
        New-Item -ItemType Directory -Path $guidDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'manifest.xml') -Value "<Backups><BackupInst><GPODisplayName><![CDATA[$script:GpoName]]></GPODisplayName></BackupInst></Backups>"
        Set-Content -LiteralPath (Join-Path $guidDir 'bkupInfo.xml') -Value "<BackupInst xmlns=`"http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest`"><GPOGuid><![CDATA[{AAAA}]]></GPOGuid><GPODomain><![CDATA[contoso.com]]></GPODomain><GPODomainController><![CDATA[DC.contoso.com]]></GPODomainController><BackupTime><![CDATA[2026-01-01T00:00:00]]></BackupTime><ID><![CDATA[$script:BackupGuid]]></ID><GPODisplayName><![CDATA[$script:GpoName]]></GPODisplayName></BackupInst>"
        Set-Content -LiteralPath (Join-Path $guidDir 'gpreport.xml') -Value '<r>contoso.com CONTOSO</r>'
        return $Root
    }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    $env:USERDNSDOMAIN = $script:RealUserDnsDomain
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.ActiveDirectory, NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Import-NSPADGpoBackup: stops before writing, reports what the directory holds' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        $script:Directory = @{ Imported = $false; Filter = $null; Linked = $false; FiltersThatExist = @($script:FilterName) }
        $script:Backup = New-FakeGpoBackup (Join-Path $TestDrive ('b_' + [guid]::NewGuid().ToString('N')))
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Write-Warning { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'dc01.example.test'; DNSRoot = 'example.test'; NetBIOSName = 'EXAMPLE'; DistinguishedName = 'DC=example,DC=test' } }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { foreach ($f in $script:Directory.FiltersThatExist) { [pscustomobject]@{ Name = $f; Id = '{F1}' } } }
        Mock -ModuleName NSP.ActiveDirectory Import-GPO { $script:Directory.Imported = $true }
        Mock -ModuleName NSP.ActiveDirectory Get-GPO {
            if (-not $script:Directory.Imported) { return $null }
            [pscustomobject]@{ DisplayName = $Name; Id = [guid]'22222222-2222-2222-2222-222222222222'; WmiFilter = $(if ($script:Directory.Filter) { [pscustomobject]@{ Name = $script:Directory.Filter } }) }
        }
        Mock -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute { $script:Directory.Filter = $script:FilterName }
        Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { [pscustomobject]@{ GpoLinks = @($(if ($script:Directory.Linked) { [pscustomobject]@{ DisplayName = $script:GpoName } })) } }
        Mock -ModuleName NSP.ActiveDirectory New-GPLink { $script:Directory.Linked = $true }
    }
    AfterEach { Set-NSPDryRun -Enabled $true -Confirm:$false }

    It 'imports nothing when the WMI filter does not exist' {
        $Directory.FiltersThatExist = @()
        { Import-NSPADGpoBackup -Path $Backup -WmiFilterName $FilterName -Confirm:$false } | Should -Throw '*does not exist*Nothing was imported*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0 -Exactly
        $Directory.Imported | Should -BeFalse
    }

    It 'imports nothing when the WMI filter does not exist, whatever the dry-run setting' {
        Set-NSPDryRun -Enabled $false -Confirm:$false
        $Directory.FiltersThatExist = @('Some other filter')
        { Import-NSPADGpoBackup -Path $Backup -WmiFilterName $FilterName -LinkAtDomainRoot -Confirm:$false } | Should -Throw '*Nothing was imported*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
    }

    It 'imports nothing when the domain''s <Missing> name is empty' -ForEach @(
        @{ Missing = 'PDCEmulator' }, @{ Missing = 'DNSRoot' }, @{ Missing = 'NetBIOSName' }
    ) {
        $domain = [pscustomobject]@{ PDCEmulator = 'dc01.example.test'; DNSRoot = 'example.test'; NetBIOSName = 'EXAMPLE'; DistinguishedName = 'DC=example,DC=test' }
        $domain.$Missing = ''
        $script:BrokenDomain = $domain
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { $script:BrokenDomain }
        { Import-NSPADGpoBackup -Path $Backup -Confirm:$false } | Should -Throw '*nothing was imported*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0 -Exactly
    }

    It 'imports nothing when the domain cannot be read' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { throw 'Unable to contact the server.' }
        { Import-NSPADGpoBackup -Path $Backup -LinkAtDomainRoot -Confirm:$false } | Should -Throw '*Unable to contact*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0 -Exactly
    }

    It 'with dry run on, imports the GPO and reports no filter and no link' {
        Get-NSPDryRun | Should -BeTrue
        $r = Import-NSPADGpoBackup -Path $Backup -WmiFilterName $FilterName -LinkAtDomainRoot -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 1 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
        $r.GpoName | Should -Be $GpoName
        $r.WmiFilter | Should -BeNullOrEmpty
        $r.Linked | Should -BeFalse
    }

    It 'with dry run off, reports the filter and the link it read back' {
        Set-NSPDryRun -Enabled $false -Confirm:$false
        $r = Import-NSPADGpoBackup -Path $Backup -WmiFilterName $FilterName -LinkAtDomainRoot -Confirm:$false
        $r.WmiFilter | Should -Be $FilterName
        $r.Linked | Should -BeTrue
        $r.Linked | Should -BeOfType [bool]
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 1 -Exactly -ParameterFilter { $Target -eq 'DC=example,DC=test' }
    }

    It 'reports Linked False when the link step ran but the link is not there' {
        Set-NSPDryRun -Enabled $false -Confirm:$false
        Mock -ModuleName NSP.ActiveDirectory New-GPLink { }      # reports success, writes nothing
        $r = Import-NSPADGpoBackup -Path $Backup -LinkAtDomainRoot -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 1 -Exactly
        $r.Linked | Should -BeFalse
    }

    It 'reports no filter when the filter step ran but the GPO does not carry it' {
        Set-NSPDryRun -Enabled $false -Confirm:$false
        Mock -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute { }      # reports success, writes nothing
        $r = Import-NSPADGpoBackup -Path $Backup -WmiFilterName $FilterName -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute -Times 1 -Exactly
        $r.WmiFilter | Should -BeNullOrEmpty
    }

    It 'still returns a result, with a warning and Linked False, when the link cannot be read back' {
        Set-NSPDryRun -Enabled $false -Confirm:$false
        Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { throw 'The server is not operational.' }
        $r = Import-NSPADGpoBackup -Path $Backup -LinkAtDomainRoot -Confirm:$false
        $r.GpoName | Should -Be $GpoName
        $r.Linked | Should -BeFalse
        Should -Invoke -ModuleName NSP.ActiveDirectory Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*could not be read back*' }
    }

    It 'reads nothing back that was not asked for' {
        $r = Import-NSPADGpoBackup -Path $Backup -Confirm:$false
        $r.WmiFilter | Should -BeNullOrEmpty
        $r.Linked | Should -BeFalse
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-GPInheritance -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry -Times 0 -Exactly
    }

    It '-WhatIf still reads and writes nothing' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { throw 'must not be read' }
        Import-NSPADGpoBackup -Path $Backup -WmiFilterName $FilterName -LinkAtDomainRoot -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-ADDomain -Times 0 -Exactly
    }
}

Describe 'New-NSPADAutoEnrollGpo: fails loudly' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        $script:Attempted = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { [pscustomobject]@{ DistinguishedName = 'DC=example,DC=test' } }
        Mock -ModuleName NSP.ActiveDirectory Get-GPO { $null }
        Mock -ModuleName NSP.ActiveDirectory New-GPO { }
        Mock -ModuleName NSP.ActiveDirectory Set-GPRegistryValue { $script:Attempted.Add($ValueName) }
        Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { [pscustomobject]@{ GpoLinks = @() } }
        Mock -ModuleName NSP.ActiveDirectory New-GPLink { }
        Set-NSPDryRun -Enabled $false -Confirm:$false
    }
    AfterEach {
        Set-NSPDryRun -Enabled $true -Confirm:$false
        $env:USERDNSDOMAIN = $script:RealUserDnsDomain
    }

    It 'throws when the GroupPolicy module is missing, and changes nothing' {
        Mock -ModuleName NSP.ActiveDirectory Assert-NSPADCommand { throw 'The GroupPolicy module (RSAT) is not available on this machine' } -ParameterFilter { $Name -eq 'Get-GPO' }
        { New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -Confirm:$false } | Should -Throw '*GroupPolicy module*'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPO -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
    }

    It 'throws, and changes nothing, when the domain cannot be read and there is no logon domain' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { throw 'Unable to contact the server.' }
        $env:USERDNSDOMAIN = ''
        { New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -Confirm:$false } | Should -Throw '*pass -DomainDn*'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPO -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-GPRegistryValue -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
    }

    It 'throws when the domain read gives an empty name' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { [pscustomobject]@{ DistinguishedName = '' } }
        { New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -Confirm:$false } | Should -Throw '*pass -DomainDn*'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPO -Times 0 -Exactly
    }

    It 'still falls back to the logon domain when there is one' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { throw 'Unable to contact the server.' }
        $env:USERDNSDOMAIN = 'example.test'
        New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 1 -Exactly -ParameterFilter { $Target -eq 'DC=example,DC=test' }
    }

    It 'tries every value, then throws and does not link, when one value cannot be set' {
        Mock -ModuleName NSP.ActiveDirectory Set-GPRegistryValue {
            $script:Attempted.Add($ValueName)
            if ($script:Attempted.Count -eq 1) { throw 'Access is denied.' }
        }
        { New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -DomainDn 'DC=example,DC=test' -Confirm:$false } | Should -Throw '*1 value(s) could not be set*not linked*Access is denied*'
        $Attempted.Count | Should -Be 3
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
    }

    It 'asks each value step to stop on an error the cmdlet would only have written' {
        New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -DomainDn 'DC=example,DC=test' -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-GPRegistryValue -Times 3 -Exactly -ParameterFilter { $ErrorActionPreference -eq 'Stop' -or $PesterBoundParameters.ErrorAction -eq 'Stop' }
    }

    It 'sets and links when nothing fails' {
        New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -DomainDn 'DC=example,DC=test' -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPO -Times 1 -Exactly
        $Attempted.Count | Should -Be 3
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 1 -Exactly
    }

    It 'with dry run on, changes nothing and does not throw' {
        Set-NSPDryRun -Enabled $true -Confirm:$false
        { New-NSPADAutoEnrollGpo -GpoName 'Test GPO' -DomainDn 'DC=example,DC=test' -Confirm:$false } | Should -Not -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPO -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-GPRegistryValue -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 0 -Exactly
    }
}
