<#
    Pester 5. Rank 5: -Server on the write functions. With -Server, EVERY directory call a function
    makes - existence check, write, read-back, and the calls of the functions it delegates to - goes
    to that one domain controller. Without -Server, no call is given one (behaviour unchanged).

    No real AD, GPO or LDAP is touched. AD/GPO cmdlets are stubbed (with a Server parameter) when
    RSAT is missing and mocked inside the module; every mock records the Server it was given.
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
        'Get-ADDomain'             = 'param($Server)'
        'Get-ADOrganizationalUnit' = 'param($Identity, $Server)'
        'New-ADOrganizationalUnit' = 'param($Name, $Path, $Description, $Server)'
        'Get-ADGroup'              = 'param($Identity, $LDAPFilter, $Server)'
        'New-ADGroup'              = 'param($Name, $SamAccountName, $GroupScope, $GroupCategory, $Path, $Description, [switch]$PassThru, $Server)'
        'Get-ADGroupMember'        = 'param($Identity, $Server)'
        'Add-ADGroupMember'        = 'param($Identity, $Members, $Server)'
        'Import-GPO'               = 'param($BackupId, $Path, $TargetName, [switch]$CreateIfNeeded, $Server)'
        'Get-GPO'                  = 'param($Name, $Server)'
        'New-GPO'                  = 'param($Name, $Server)'
        'Set-GPRegistryValue'      = 'param($Name, $Key, $ValueName, $Type, $Value, $Server)'
        'Get-GPInheritance'        = 'param($Target, $Server)'
        'New-GPLink'               = 'param($Name, $Target, $LinkEnabled, $Server)'
    }
    $script:stubbed = @()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) `$null"))
            $script:stubbed += $name
        }
    }

    $script:DC = 'dc02.contoso.example'
    $script:DomainObj = [pscustomobject]@{ PDCEmulator = 'dc01.contoso.example'; DNSRoot = 'contoso.example'; NetBIOSName = 'CONTOSO'; DistinguishedName = 'DC=contoso,DC=example' }
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

    # Every directory call the module made, as Cmd + the Server it was given ('' for none).
    function script:Add-Call([string]$Cmd, $Server) { $script:Calls.Add([pscustomobject]@{ Cmd = $Cmd; Server = "$Server" }) }
    function script:Get-CalledCommands { @($script:Calls | ForEach-Object Cmd | Select-Object -Unique) }
    function script:Get-CallsOffTarget([string]$Expected) { @($script:Calls | Where-Object { $_.Server -ne $Expected }) }

    # One set of recording mocks for every directory touch point the write functions use.
    function script:Initialize-DirectoryMocks {
        $script:Calls = New-Object System.Collections.Generic.List[object]
        $script:Dir = @{ Gpo = $false; Linked = $false; Filter = $null }
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Write-Warning { }
        Mock -ModuleName NSP.ActiveDirectory Use-NSPADDependency { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { Add-Call 'Get-ADDomain' $Server; $script:DomainObj }
        Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit { Add-Call 'Get-ADOrganizationalUnit' $Server; $null }
        Mock -ModuleName NSP.ActiveDirectory New-ADOrganizationalUnit { Add-Call 'New-ADOrganizationalUnit' $Server }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroup { Add-Call 'Get-ADGroup' $Server; $null }
        Mock -ModuleName NSP.ActiveDirectory New-ADGroup { Add-Call 'New-ADGroup' $Server; [pscustomobject]@{ DistinguishedName = "CN=$Name,$Path" } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember { Add-Call 'Get-ADGroupMember' $Server }
        Mock -ModuleName NSP.ActiveDirectory Add-ADGroupMember { Add-Call 'Add-ADGroupMember' $Server }
        Mock -ModuleName NSP.ActiveDirectory Import-GPO { Add-Call 'Import-GPO' $Server; $script:Dir.Gpo = $true }
        Mock -ModuleName NSP.ActiveDirectory Get-GPO {
            Add-Call 'Get-GPO' $Server
            if (-not $script:Dir.Gpo) { return $null }
            [pscustomobject]@{ DisplayName = $Name; Id = [guid]'22222222-2222-2222-2222-222222222222'; WmiFilter = $(if ($script:Dir.Filter) { [pscustomobject]@{ Name = $script:Dir.Filter } }) }
        }
        Mock -ModuleName NSP.ActiveDirectory New-GPO { Add-Call 'New-GPO' $Server; $script:Dir.Gpo = $true }
        Mock -ModuleName NSP.ActiveDirectory Set-GPRegistryValue { Add-Call 'Set-GPRegistryValue' $Server }
        Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { Add-Call 'Get-GPInheritance' $Server; [pscustomobject]@{ GpoLinks = @($(if ($script:Dir.Linked) { [pscustomobject]@{ DisplayName = $script:GpoName } })) } }
        Mock -ModuleName NSP.ActiveDirectory New-GPLink { Add-Call 'New-GPLink' $Server; $script:Dir.Linked = $true }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry { Add-Call 'Get-NSPADWmiSomEntry' $Server; [pscustomobject]@{ Name = $script:FilterName; Id = '{F1}'; Query = @('SELECT * FROM Win32_OperatingSystem'); Description = 'd'; DN = 'CN={F1},CN=SOM,CN=WMIPolicy,CN=System,DC=contoso,DC=example' } }
        Mock -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry { Add-Call 'Save-NSPADWmiSomEntry' $Server }
        Mock -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute { Add-Call 'Set-NSPADGpoWqlFilterAttribute' $Server; $script:Dir.Filter = $script:FilterName }
    }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.ActiveDirectory, NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Server targeting helpers' {
    It 'Get-NSPADServerSplat is empty for no server and trims a named one' {
        InModuleScope NSP.ActiveDirectory {
            (Get-NSPADServerSplat -Server '').Count | Should -Be 0
            (Get-NSPADServerSplat -Server '   ').Count | Should -Be 0
            (Get-NSPADServerSplat).Count | Should -Be 0
            (Get-NSPADServerSplat -Server ' dc02.contoso.example ').Server | Should -Be 'dc02.contoso.example'
        }
    }
    It 'Get-NSPADAdsiPath binds serverless without a server and to the DC with one' {
        InModuleScope NSP.ActiveDirectory {
            Get-NSPADAdsiPath -DistinguishedName 'CN=X,DC=contoso,DC=example' | Should -Be 'LDAP://CN=X,DC=contoso,DC=example'
            Get-NSPADAdsiPath -DistinguishedName 'CN=X,DC=contoso,DC=example' -Server 'dc02.contoso.example' | Should -Be 'LDAP://dc02.contoso.example/CN=X,DC=contoso,DC=example'
        }
    }
    It 'Format-NSPADServerArg shows the DC in a preview line only when one is named' {
        InModuleScope NSP.ActiveDirectory {
            Format-NSPADServerArg -Server '' | Should -Be ''
            Format-NSPADServerArg -Server 'dc02' | Should -Be " -Server 'dc02'"
        }
    }
}

Describe 'Resolve-NSPADDomainInfoForServer' {
    BeforeEach {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo { [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = $(if ($Server) { $Server } else { 'located.contoso.example' }); DNSRoot = 'contoso.example' } }
    }
    It 'looks the domain up on -Server when only -Server is given' {
        $r = InModuleScope NSP.ActiveDirectory { Resolve-NSPADDomainInfoForServer -Server 'dc02.contoso.example' }
        $r.Server | Should -Be 'dc02.contoso.example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc02.contoso.example' }
    }
    It 'uses the DC locator when neither is given' {
        $r = InModuleScope NSP.ActiveDirectory { Resolve-NSPADDomainInfoForServer }
        $r.Server | Should -Be 'located.contoso.example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -Times 1 -Exactly -ParameterFilter { -not $Server }
    }
    It 'accepts -DomainInfo and -Server that name the same DC, without another lookup' {
        $d = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc02.contoso.example' }
        $r = InModuleScope NSP.ActiveDirectory -Parameters @{ D = $d } { param($D) Resolve-NSPADDomainInfoForServer -DomainInfo $D -Server 'DC02.contoso.example' }
        $r | Should -Be $d
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -Times 0 -Exactly
    }
    It 'refuses -DomainInfo and -Server that name different DCs' {
        $d = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc01.contoso.example' }
        { InModuleScope NSP.ActiveDirectory -Parameters @{ D = $d } { param($D) Resolve-NSPADDomainInfoForServer -DomainInfo $D -Server 'dc02.contoso.example' } } |
            Should -Throw '*name different domain controllers*'
    }
}

Describe 'Every directory call goes to -Server, and none is pinned without it' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Initialize-DirectoryMocks
        Set-NSPDryRun -Enabled $false -Confirm:$false
    }
    AfterEach { Set-NSPDryRun -Enabled $true -Confirm:$false }

    # Each case: the function call (with and without -Server) and the commands it must reach.
    $cases = @(
        @{ Fn = 'New-NSPADOrganizationalUnit'; Expect = @('Get-ADOrganizationalUnit', 'New-ADOrganizationalUnit')
            Run = { param($s) New-NSPADOrganizationalUnit -Name 'VPN' -Path 'DC=contoso,DC=example' @s } }
        @{ Fn = 'New-NSPADGroup'; Expect = @('Get-ADGroup', 'New-ADGroup')
            Run = { param($s) New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' @s } }
        @{ Fn = 'Add-NSPADGroupMember'; Expect = @('Get-ADGroupMember', 'Add-ADGroupMember')
            Run = { param($s) Add-NSPADGroupMember -GroupIdentity 'CN=G,DC=contoso,DC=example' -MemberIdentity 'CN=U,DC=contoso,DC=example' @s } }
        @{ Fn = 'New-NSPADGpoLink'; Expect = @('Get-GPInheritance', 'New-GPLink')
            Run = { param($s) New-NSPADGpoLink -GpoName 'NSP - X' -TargetDN 'DC=contoso,DC=example' @s } }
        @{ Fn = 'Set-NSPADGpoWmiFilter'; Expect = @('Get-ADDomain', 'Get-GPO', 'Get-NSPADWmiSomEntry', 'Set-NSPADGpoWqlFilterAttribute')
            Run = { param($s) $script:Dir.Gpo = $true; Set-NSPADGpoWmiFilter -GpoName 'NSP - X' -WmiFilterName $script:FilterName @s } }
        @{ Fn = 'New-NSPADWmiFilter'; Expect = @('Get-ADDomain', 'Get-NSPADWmiSomEntry', 'Save-NSPADWmiSomEntry')
            Run = { param($s) [pscustomobject]@{ Name = $script:FilterName; Expression = @('SELECT * FROM Win32_ComputerSystem'); Description = 'changed' } | New-NSPADWmiFilter @s } }
        @{ Fn = 'New-NSPADAutoEnrollGpo'; Expect = @('Get-ADDomain', 'Get-GPO', 'New-GPO', 'Set-GPRegistryValue', 'Get-GPInheritance', 'New-GPLink')
            Run = { param($s) New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' @s } }
        @{ Fn = 'Import-NSPADGpoBackup'; Expect = @('Get-ADDomain', 'Get-NSPADWmiSomEntry', 'Import-GPO', 'Get-GPO', 'Set-NSPADGpoWqlFilterAttribute', 'Get-GPInheritance', 'New-GPLink')
            Run = { param($s) $b = New-FakeGpoBackup (Join-Path $TestDrive ('b_' + [guid]::NewGuid().ToString('N'))); Import-NSPADGpoBackup -Path $b -WmiFilterName $script:FilterName -LinkAtDomainRoot @s } }
    )

    It '<Fn> -Server sends every call to that DC' -TestCases $cases {
        param($Fn, $Expect, $Run)
        $null = & $Run @{ Server = $script:DC }
        foreach ($c in $Expect) { Get-CalledCommands | Should -Contain $c -Because "$Fn must reach $c" }
        $off = Get-CallsOffTarget $script:DC
        $off | Should -BeNullOrEmpty -Because "every call must go to $($script:DC); these did not: $(($off | ForEach-Object { "$($_.Cmd)=[$($_.Server)]" }) -join ', ')"
    }

    It '<Fn> without -Server pins no call (behaviour unchanged)' -TestCases $cases {
        param($Fn, $Expect, $Run)
        $null = & $Run @{}
        foreach ($c in $Expect) { Get-CalledCommands | Should -Contain $c }
        Get-CallsOffTarget '' | Should -BeNullOrEmpty
    }

    It '<Fn> rejects an empty -Server before touching the directory' -TestCases $cases {
        param($Fn, $Expect, $Run)
        { & $Run @{ Server = '' } } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }

    It 'Import-NSPADGpoBackup reads its result back from the same DC it wrote to' {
        $b = New-FakeGpoBackup (Join-Path $TestDrive ('b_' + [guid]::NewGuid().ToString('N')))
        $r = Import-NSPADGpoBackup -Path $b -WmiFilterName $script:FilterName -LinkAtDomainRoot -Server $script:DC
        $r.Linked | Should -BeTrue
        $r.WmiFilter | Should -Be $script:FilterName
        # The last two directory calls are the read-backs: Get-GPO, then Get-GPInheritance.
        $all = $script:Calls.ToArray()
        $tail = $all[($all.Count - 2)..($all.Count - 1)]
        ($tail | ForEach-Object { "$($_.Cmd)@$($_.Server)" }) -join ', ' | Should -Be "Get-GPO@$($script:DC), Get-GPInheritance@$($script:DC)"
    }
}

Describe 'A DC that cannot be reached stops the command before any write' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Initialize-DirectoryMocks
        Set-NSPDryRun -Enabled $false -Confirm:$false
        $script:Down = 'Unable to contact the server. This may be because this server does not exist, it is currently down, or it does not have the Active Directory Web Services running.'
    }
    AfterEach { Set-NSPDryRun -Enabled $true -Confirm:$false }

    It 'New-NSPADOrganizationalUnit: a failed existence check on the DC throws and creates nothing' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit { Add-Call 'Get-ADOrganizationalUnit' $Server; throw $script:Down }
        { New-NSPADOrganizationalUnit -Name 'VPN' -Path 'DC=contoso,DC=example' -Server $script:DC } | Should -Throw '*Unable to contact the server*'
        Get-CalledCommands | Should -Not -Contain 'New-ADOrganizationalUnit'
    }
    It 'New-NSPADGroup: a failed create on the DC reaches the caller' {
        Mock -ModuleName NSP.ActiveDirectory New-ADGroup { Add-Call 'New-ADGroup' $Server; throw $script:Down }
        { New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' -Server $script:DC } | Should -Throw '*Unable to contact the server*'
    }
    It 'Set-NSPADGpoWmiFilter: a failed domain read on the DC throws and writes nothing' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { Add-Call 'Get-ADDomain' $Server; throw $script:Down }
        { Set-NSPADGpoWmiFilter -GpoName 'NSP - X' -WmiFilterName $script:FilterName -Server $script:DC } | Should -Throw '*Unable to contact the server*'
        Get-CalledCommands | Should -Not -Contain 'Set-NSPADGpoWqlFilterAttribute'
    }
    It 'Import-NSPADGpoBackup: a failed domain read on the DC throws before Import-GPO' {
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { Add-Call 'Get-ADDomain' $Server; throw $script:Down }
        $b = New-FakeGpoBackup (Join-Path $TestDrive ('b_' + [guid]::NewGuid().ToString('N')))
        { Import-NSPADGpoBackup -Path $b -Server $script:DC } | Should -Throw '*Unable to contact the server*'
        Get-CalledCommands | Should -Not -Contain 'Import-GPO'
    }
    It 'New-NSPADAutoEnrollGpo: a failed domain read on the DC, with no logon domain, throws before New-GPO' {
        $saved = $env:USERDNSDOMAIN
        try {
            $env:USERDNSDOMAIN = $null
            Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { Add-Call 'Get-ADDomain' $Server; throw $script:Down }
            { New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -Server $script:DC } | Should -Throw '*pass -DomainDn*'
            Get-CalledCommands | Should -Not -Contain 'New-GPO'
        } finally { $env:USERDNSDOMAIN = $saved }
    }
}

Describe 'New-NSPADServiceAccount -Server' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Write-Warning { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo { [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = $(if ($Server) { $Server } else { 'located.contoso.example' }); DNSRoot = 'contoso.example'; NetBIOSName = 'CONTOSO'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example' } }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { [pscustomobject]@{ Name = 'APP01'; DistinguishedName = 'CN=APP01,DC=contoso,DC=example'; SID = 'S-1-5-21-1-2-3-1105' } }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }
    }

    It 'looks the domain up on -Server, and every check uses that DC' {
        New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -Server $script:DC -WhatIf 3>$null | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -Times 1 -Exactly -ParameterFilter { $Server -eq $script:DC }
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADComputer -Times 1 -Exactly -ParameterFilter { $DomainInfo.Server -eq $script:DC }
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount -Times 1 -Exactly -ParameterFilter { $DomainInfo.Server -eq $script:DC }
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Server -ne $script:DC } -Times 0 -Exactly
    }

    It 'stops before any read when -Server and -DomainInfo name different DCs' {
        $d = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc01.contoso.example'; DNSRoot = 'contoso.example' }
        { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $d -Server $script:DC } | Should -Throw '*name different domain controllers*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADComputer -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 0 -Exactly
    }
}

Describe 'ADSI binds carry -Server' {
    It 'Get-NSPADWmiSomEntry binds the SOM container on the DC' {
        Mock -ModuleName NSP.ActiveDirectory New-NSPADDirectoryEntry { throw "bound:$Server|$DistinguishedName" }
        { InModuleScope NSP.ActiveDirectory { Get-NSPADWmiSomEntry -DomainDN 'DC=contoso,DC=example' -Server 'dc02.contoso.example' } } |
            Should -Throw 'bound:dc02.contoso.example|CN=SOM,CN=WMIPolicy,CN=System,DC=contoso,DC=example'
    }
    It 'Save-NSPADWmiSomEntry updates the filter on the DC' {
        $script:Bound = @()
        Mock -ModuleName NSP.ActiveDirectory New-NSPADDirectoryEntry {
            $script:Bound += "$Server|$DistinguishedName"
            $o = [pscustomobject]@{}
            $o | Add-Member ScriptMethod Put { param($n, $v) }
            $o | Add-Member ScriptMethod SetInfo { }
            $o
        }
        InModuleScope NSP.ActiveDirectory { Save-NSPADWmiSomEntry -DomainDN 'DC=contoso,DC=example' -DnsRoot 'contoso.example' -Name 'F' -Query 'SELECT 1' -DN 'CN={F1},CN=SOM,CN=WMIPolicy,CN=System,DC=contoso,DC=example' -Server 'dc02.contoso.example' } | Out-Null
        $script:Bound | Should -Be @('dc02.contoso.example|CN={F1},CN=SOM,CN=WMIPolicy,CN=System,DC=contoso,DC=example')
    }
    It 'Set-NSPADGpoWqlFilterAttribute writes the GPO object on the DC' {
        $script:Bound = @()
        Mock -ModuleName NSP.ActiveDirectory New-NSPADDirectoryEntry {
            $script:Bound += "$Server|$DistinguishedName"
            $o = [pscustomobject]@{}
            $o | Add-Member ScriptMethod Put { param($n, $v) }
            $o | Add-Member ScriptMethod SetInfo { }
            $o
        }
        InModuleScope NSP.ActiveDirectory { Set-NSPADGpoWqlFilterAttribute -DomainDN 'DC=contoso,DC=example' -DnsRoot 'contoso.example' -GpoGuid '{22222222-2222-2222-2222-222222222222}' -WmiFilterId '{F1}' -Server 'dc02.contoso.example' }
        $script:Bound | Should -Be @('dc02.contoso.example|CN={22222222-2222-2222-2222-222222222222},CN=Policies,CN=System,DC=contoso,DC=example')
    }
}
