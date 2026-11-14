<#
    Pester 5. Rank 4: the opt-in -AsResult outcome (NSP.ActiveDirectory.WriteOutcome), against the
    contract agreed with the Catalyst on 2026-11-14:
      - Created/Updated only after a fresh read matched; AlreadyPresent only when identity AND
        planned properties match; ObservedTarget only from a read.
      - Expected failures come back as Failed + a closed ErrorCode; ambiguity and bugs still throw.
      - No exception text on the object or on the host; never an MP-4 step result.
      - Previewed (dry run / -WhatIf) and Skipped (declined confirmation) are distinct.
      - Without -AsResult nothing changes.
    No real AD, GPO or LDAP is touched: cmdlets are stubbed when RSAT is missing and mocked
    inside the module against a small fake directory ($script:D), so a read after a write sees it.
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
        'Get-ADOrganizationalUnit' = 'param($Identity, $Properties, $Server)'
        'New-ADOrganizationalUnit' = 'param($Name, $Path, $Description, $Server)'
        'Get-ADGroup'              = 'param($Identity, $LDAPFilter, $Server)'
        'New-ADGroup'              = 'param($Name, $SamAccountName, $GroupScope, $GroupCategory, $Path, $Description, [switch]$PassThru, $Server)'
        'Get-ADGroupMember'        = 'param($Identity, $Server)'
        'Add-ADGroupMember'        = 'param($Identity, $Members, $Server)'
        'Import-GPO'               = 'param($BackupId, $Path, $TargetName, [switch]$CreateIfNeeded, $Server)'
        'Get-GPO'                  = 'param($Name, $Server)'
        'New-GPO'                  = 'param($Name, $Server)'
        'Set-GPRegistryValue'      = 'param($Name, $Key, $ValueName, $Type, $Value, $Server)'
        'Get-GPRegistryValue'      = 'param($Name, $Key, $ValueName, $Server)'
        'Get-GPInheritance'        = 'param($Target, $Server)'
        'New-GPLink'               = 'param($Name, $Target, $LinkEnabled, $Server)'
        'New-ADServiceAccount'     = 'param($Name, $DNSHostName, $Enabled, $PrincipalsAllowedToRetrieveManagedPassword, $ManagedPasswordIntervalInDays, $KerberosEncryptionType, $Server, $Description)'
        'Install-ADServiceAccount' = 'param($Identity)'
        'Test-ADServiceAccount'    = 'param($Identity)'
    }
    $script:stubbed = @()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) `$null"))
            $script:stubbed += $name
        }
    }
    if (-not ('NSPTestFake.ADIdentityNotFoundException' -as [type])) {
        Add-Type -TypeDefinition 'namespace NSPTestFake { public class ADIdentityNotFoundException : System.Exception { public ADIdentityNotFoundException(string m) : base(m) { } } }'
    }

    $script:DC = 'dc02.contoso.example'
    $script:Secret = 'SECRET-DETAIL-7f3a: CN=Payroll Admins,OU=Hidden,DC=contoso,DC=example'
    $script:GpoName = 'NSP - TLS1 - Enable TLS 1.2'
    $script:FilterName = 'NSP_AT - All Servers'
    $script:BackupGuid = '{11111111-2222-3333-4444-555555555555}'
    $script:Domain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc02.contoso.example'; PDCEmulator = 'dc01.contoso.example'; DNSRoot = 'contoso.example'; NetBIOSName = 'CONTOSO'; DistinguishedName = 'DC=contoso,DC=example'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example' }

    function script:New-FakeGpoBackup([string]$Root) {
        $guidDir = Join-Path $Root $script:BackupGuid
        New-Item -ItemType Directory -Path $guidDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'manifest.xml') -Value "<Backups><BackupInst><GPODisplayName><![CDATA[$script:GpoName]]></GPODisplayName></BackupInst></Backups>"
        Set-Content -LiteralPath (Join-Path $guidDir 'bkupInfo.xml') -Value "<BackupInst xmlns=`"http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest`"><GPOGuid><![CDATA[{AAAA}]]></GPOGuid><GPODomain><![CDATA[contoso.com]]></GPODomain><GPODomainController><![CDATA[DC.contoso.com]]></GPODomainController><BackupTime><![CDATA[2026-01-01T00:00:00]]></BackupTime><ID><![CDATA[$script:BackupGuid]]></ID><GPODisplayName><![CDATA[$script:GpoName]]></GPODisplayName></BackupInst>"
        Set-Content -LiteralPath (Join-Path $guidDir 'gpreport.xml') -Value '<r>contoso.com CONTOSO</r>'
        return $Root
    }
    # A cmdlet stand-in whose ShouldProcess answers no, as a declined -Confirm prompt does.
    function script:New-DecliningCmdlet { $o = [pscustomobject]@{}; $o | Add-Member ScriptMethod ShouldProcess { param($a, $b) $false }; $o }

    function script:Initialize-FakeDirectory {
        $script:D = @{
            OUs = @{}; Groups = @{}; Members = @{}; Links = @{}; Gpos = @{}; GpoFilter = @{}; Values = @{}
            Filters = @{}; Gmsa = @{}; Installed = @{}; KdsKeys = 0
            DropWrites = $false; FailWrites = $false; NonTerminatingWrite = $false
        }
        $script:Calls = New-Object System.Collections.Generic.List[object]
        Mock -ModuleName NSP.ActiveDirectory Write-Host { $script:Host_ += "$Object`n" }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Write-Warning { }
        Mock -ModuleName NSP.ActiveDirectory Use-NSPADDependency { }
        $script:Host_ = ''

        # A write mock calls this first: fail, fail softly (non-terminating), or drop the write.
        function script:Invoke-FakeWrite([string]$Cmd, $Server, [scriptblock]$Apply) {
            $script:Calls.Add([pscustomobject]@{ Cmd = $Cmd; Server = "$Server" })
            if ($script:D.FailWrites) { throw $script:Secret }
            if ($script:D.NonTerminatingWrite) { Write-Error $script:Secret; return }
            if (-not $script:D.DropWrites) { & $Apply }
        }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-ADDomain'; Server = "$Server" }); $script:Domain }
        Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-ADOrganizationalUnit'; Server = "$Server" })
            if ($script:D.OUs.ContainsKey("$Identity")) { return $script:D.OUs["$Identity"] }
            throw (New-Object NSPTestFake.ADIdentityNotFoundException 'Directory object not found')
        }
        Mock -ModuleName NSP.ActiveDirectory New-ADOrganizationalUnit { Invoke-FakeWrite 'New-ADOrganizationalUnit' $Server { $script:D.OUs["OU=$Name,$Path"] = [pscustomobject]@{ DistinguishedName = "OU=$Name,$Path"; Description = $Description } } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroup {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-ADGroup'; Server = "$Server" })
            foreach ($g in $script:D.Groups.Values) { if ($LDAPFilter -like "*(sAMAccountName=$($g.SamAccountName))*") { $g } }
        }
        Mock -ModuleName NSP.ActiveDirectory New-ADGroup { Invoke-FakeWrite 'New-ADGroup' $Server { $script:D.Groups[$SamAccountName] = [pscustomobject]@{ SamAccountName = $SamAccountName; DistinguishedName = "CN=$Name,$Path"; GroupScope = $GroupScope; GroupCategory = $GroupCategory } } }
        Mock -ModuleName NSP.ActiveDirectory Get-ADGroupMember {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-ADGroupMember'; Server = "$Server" })
            foreach ($m in @($script:D.Members["$Identity"])) { if ($m) { [pscustomobject]@{ DistinguishedName = $m; SamAccountName = ''; Name = '' } } }
        }
        Mock -ModuleName NSP.ActiveDirectory Add-ADGroupMember { Invoke-FakeWrite 'Add-ADGroupMember' $Server { $script:D.Members["$Identity"] = @($script:D.Members["$Identity"]) + "$Members" } }
        Mock -ModuleName NSP.ActiveDirectory Get-GPO {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-GPO'; Server = "$Server" })
            if (-not $script:D.Gpos.ContainsKey("$Name")) { return $null }
            [pscustomobject]@{ DisplayName = "$Name"; Id = [guid]'22222222-2222-2222-2222-222222222222'; WmiFilter = $(if ($script:D.GpoFilter["$Name"]) { [pscustomobject]@{ Name = $script:D.GpoFilter["$Name"] } }) }
        }
        Mock -ModuleName NSP.ActiveDirectory New-GPO { Invoke-FakeWrite 'New-GPO' $Server { $script:D.Gpos["$Name"] = $true } }
        Mock -ModuleName NSP.ActiveDirectory Import-GPO { Invoke-FakeWrite 'Import-GPO' $Server { $script:D.Gpos["$TargetName"] = $true } }
        Mock -ModuleName NSP.ActiveDirectory Set-GPRegistryValue { Invoke-FakeWrite 'Set-GPRegistryValue' $Server { $script:D.Values["$Name|$Key|$ValueName"] = "$Value" } }
        Mock -ModuleName NSP.ActiveDirectory Get-GPRegistryValue {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-GPRegistryValue'; Server = "$Server" })
            $k = "$Name|$Key|$ValueName"
            if ($script:D.Values.ContainsKey($k)) { [pscustomobject]@{ Value = $script:D.Values[$k] } }
        }
        Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-GPInheritance'; Server = "$Server" })
            [pscustomobject]@{ GpoLinks = @(foreach ($n in @($script:D.Links["$Target"])) { if ($n) { [pscustomobject]@{ DisplayName = $n } } }) }
        }
        Mock -ModuleName NSP.ActiveDirectory New-GPLink { Invoke-FakeWrite 'New-GPLink' $Server { $script:D.Links["$Target"] = @($script:D.Links["$Target"]) + "$Name" } }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADWmiSomEntry {
            $script:Calls.Add([pscustomobject]@{ Cmd = 'Get-NSPADWmiSomEntry'; Server = "$Server" })
            foreach ($f in $script:D.Filters.Values) { $f }
        }
        Mock -ModuleName NSP.ActiveDirectory Save-NSPADWmiSomEntry { Invoke-FakeWrite 'Save-NSPADWmiSomEntry' $Server { $script:D.Filters[$Name] = [pscustomobject]@{ Name = $Name; Id = '{F1}'; Query = @($Query); Description = "$Description"; DN = "CN={F1},CN=SOM,CN=WMIPolicy,CN=System,$DomainDN" } } }
        Mock -ModuleName NSP.ActiveDirectory Set-NSPADGpoWqlFilterAttribute {
            Invoke-FakeWrite 'Set-NSPADGpoWqlFilterAttribute' $Server {
                $n = @($script:D.Gpos.Keys)[0]
                $script:D.GpoFilter[$n] = $(if ($WmiFilterId) { @($script:D.Filters.Values | Where-Object Id -eq $WmiFilterId)[0].Name } else { $null })
            }
        }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo { $script:Domain }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { if ($Name -eq 'APP01') { [pscustomobject]@{ Name = 'APP01'; DistinguishedName = 'CN=APP01,DC=contoso,DC=example'; SID = 'S-1-5-21-1-2-3-1105' } } }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { $script:D.Gmsa["$Name"] }
        Mock -ModuleName NSP.ActiveDirectory New-ADServiceAccount {
            Invoke-FakeWrite 'New-ADServiceAccount' $Server { $script:D.Gmsa["$Name"] = [pscustomobject]@{ DistinguishedName = "CN=$Name,CN=Managed Service Accounts,DC=contoso,DC=example"; AllowedPrincipals = @([pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1105' }) } }
        }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADKdsRootKeyStatus { [pscustomobject]@{ Status = $(if ($script:D.KdsKeys) { 'Usable' } else { 'NoneVisible' }); Visible = $script:D.KdsKeys; Usable = $script:D.KdsKeys } }
        Mock -ModuleName NSP.ActiveDirectory Add-KdsRootKey { Invoke-FakeWrite 'Add-KdsRootKey' $null { $script:D.KdsKeys++ } }
        Mock -ModuleName NSP.ActiveDirectory Install-ADServiceAccount { Invoke-FakeWrite 'Install-ADServiceAccount' $null { $script:D.Installed["$Identity"] = $true } }
        Mock -ModuleName NSP.ActiveDirectory Test-ADServiceAccount { [bool]$script:D.Installed["$Identity"] }
    }

    # The contract as a test oracle: every property and invariant, on any outcome.
    function script:Assert-OutcomeContract($o) {
        $o.PSObject.TypeNames[0] | Should -Be 'NSP.ActiveDirectory.WriteOutcome'
        @($o.PSObject.Properties.Name) | Should -Be @('Operation', 'Target', 'Outcome', 'ObservedTarget', 'ObservedMatch', 'Server', 'ErrorCode')
        @('Created', 'Updated', 'AlreadyPresent', 'Previewed', 'Skipped', 'Failed') | Should -Contain $o.Outcome
        if (@('Created', 'Updated', 'AlreadyPresent') -contains $o.Outcome) { $o.ObservedMatch | Should -BeTrue; $o.ObservedTarget | Should -Not -BeNullOrEmpty; $o.ErrorCode | Should -BeNullOrEmpty }
        else { $o.ObservedMatch | Should -BeFalse }
        if ($o.Outcome -eq 'Failed') { $o.ErrorCode | Should -Not -BeNullOrEmpty } else { $o.ErrorCode | Should -BeNullOrEmpty }
        if (@('Previewed', 'Skipped') -contains $o.Outcome) { $o.ObservedTarget | Should -BeNullOrEmpty }
        ($o | ConvertTo-Json -Depth 4) | Should -Not -Match 'SECRET-DETAIL'
    }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.ActiveDirectory, NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'The outcome contract itself' {
    It 'refuses a success outcome without a matching read' {
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Created -ObservedTarget '' -ObservedMatch $true } } | Should -Throw '*matching directory read*'
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome AlreadyPresent -ObservedTarget 'T' -ObservedMatch $false } } | Should -Throw '*matching directory read*'
    }
    It 'refuses Failed without a code, a code on success, an unknown code, and an unknown outcome' {
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Failed } } | Should -Throw '*Failed needs a code*'
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Created -ObservedTarget T -ObservedMatch $true -ErrorCode WriteFailed } } | Should -Throw '*only Failed may have one*'
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Failed -ErrorCode StepFailed } } | Should -Throw '*not one of*'
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Applied -ObservedTarget T -ObservedMatch $true } } | Should -Throw '*not one of*'
    }
    It 'refuses an ObservedTarget on Previewed or Skipped, and ObservedMatch on Failed' {
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Previewed -ObservedTarget T } } | Should -Throw '*nothing was read*'
        { InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Failed -ErrorCode Conflict -ObservedMatch $true } } | Should -Throw '*cannot have ObservedMatch*'
    }
    It 'is never an MP-4 step result: no verified field, no Applied outcome' {
        $o = InModuleScope NSP.ActiveDirectory { New-NSPADWriteOutcome -Operation X -Target T -Outcome Failed -ErrorCode WriteFailed }
        $json = $o | ConvertTo-Json
        $json | Should -Not -Match '"verified"'
        $o.Outcome | Should -Not -Be 'Applied'
        $o.ObservedMatch | Should -BeFalse
    }
}

Describe 'What becomes a result and what still throws' {
    BeforeEach { Mock -ModuleName NSP.ActiveDirectory Write-Host { $script:Host_ += "$Object`n" }; $script:Host_ = '' }
    It 'maps the phase of a directory failure to its code' {
        foreach ($p in @(@('Precondition', 'PreconditionFailed'), @('Write', 'WriteFailed'), @('ReadBack', 'ReadBackFailed'))) {
            $r = InModuleScope NSP.ActiveDirectory -Parameters @{ P = $p[0] } { param($P) Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) $c.Phase = $P; throw 'directory said no' } }
            $r.Outcome | Should -Be 'Failed'
            $r.ErrorCode | Should -Be $p[1]
        }
    }
    It 'keeps an explicit code whatever the phase' {
        $r = InModuleScope NSP.ActiveDirectory { Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) $c.Phase = 'Write'; throw (New-NSPADCodedError NotFound 'gone') } }
        $r.ErrorCode | Should -Be 'NotFound'
    }
    It 'rethrows ambiguous targeting (a terminating error) instead of returning Failed' {
        { InModuleScope NSP.ActiveDirectory { Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) throw (New-NSPADTerminatingError 'two DCs') } } } | Should -Throw '*two DCs*'
    }
    It 'rethrows a programmer error (method on null) instead of returning Failed' {
        { InModuleScope NSP.ActiveDirectory { Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) $c.Phase = 'Write'; $n = $null; $n.Foo() } } } | Should -Throw
    }
    It 'rethrows when a body leaks extra output (a module bug), instead of guessing' {
        { InModuleScope NSP.ActiveDirectory { Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) 'stray'; @{ Outcome = 'Previewed' } } } } | Should -Throw '*not one hashtable*'
    }
    It 'puts no exception text on the object or on the host' {
        $secret = $script:Secret
        $r = InModuleScope NSP.ActiveDirectory -Parameters @{ S = $secret } { param($S) Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) $c.Phase = 'Write'; throw $S } }
        ($r | ConvertTo-Json) | Should -Not -Match 'SECRET-DETAIL'
        ($r | Out-String) | Should -Not -Match 'SECRET-DETAIL'
        $script:Host_ | Should -Not -Match 'SECRET-DETAIL'
        $script:Host_ | Should -Match 'WriteFailed'
    }
    It 'says on the host that a read-back failure may leave the change made' {
        $null = InModuleScope NSP.ActiveDirectory { Invoke-NSPADOutcome -Operation X -Target T -Body { param($c) $c.Phase = 'ReadBack'; throw 'not visible' } }
        $script:Host_ | Should -Match 'may already have been made'
    }
}

Describe '-AsResult on each write function' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Initialize-FakeDirectory
        Set-NSPDryRun -Enabled $false -Confirm:$false
    }
    AfterEach { Set-NSPDryRun -Enabled $true -Confirm:$false }

    Context 'New-NSPADOrganizationalUnit' {
        BeforeEach { $script:Ou = @{ Name = 'VPN'; Path = 'DC=contoso,DC=example' } }
        It 'Created, from a read after the write' {
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Created'
            $r.ObservedTarget | Should -Be 'OU=VPN,DC=contoso,DC=example'
            @($script:Calls.Cmd) | Select-Object -Last 1 | Should -Be 'Get-ADOrganizationalUnit'
        }
        It 'AlreadyPresent on a re-run, with nothing written' {
            $null = New-NSPADOrganizationalUnit @script:Ou -AsResult
            $script:Calls.Clear()
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'AlreadyPresent'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-ADOrganizationalUnit'
        }
        It 'Failed/Conflict when it exists with a different planned description' {
            $null = New-NSPADOrganizationalUnit @script:Ou -Description 'old' -AsResult
            $r = New-NSPADOrganizationalUnit @script:Ou -Description 'new' -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'Conflict'
        }
        It 'Failed/ReadBackFailed when the write reports success but nothing is there' {
            $script:D.DropWrites = $true
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'ReadBackFailed'
        }
        It 'Failed/WriteFailed when the write throws' {
            $script:D.FailWrites = $true
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'WriteFailed'
        }
        It 'asks the write cmdlet to stop on any error, and a soft (non-terminating) failure is never Created' {
            $script:EA = $null
            Mock -ModuleName NSP.ActiveDirectory New-ADOrganizationalUnit { $script:EA = "$($PesterBoundParameters['ErrorAction'])"; Write-Error 'soft failure' -ErrorAction Continue 2>$null }
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Failed'
            # A real cmdlet turns its own non-terminating error into an exception under -ErrorAction
            # Stop (WriteFailed); this mock cannot, so the read-back is what catches it here.
            @('WriteFailed', 'ReadBackFailed') | Should -Contain $r.ErrorCode
            $script:EA | Should -Be 'Stop'
        }
        It 'Failed/PreconditionFailed when the existence check cannot reach the directory' {
            Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit { throw 'Unable to contact the server.' }
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'PreconditionFailed'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-ADOrganizationalUnit'
        }
        It 'Previewed in a dry run, with nothing written' {
            Set-NSPDryRun -Enabled $true -Confirm:$false
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Previewed'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-ADOrganizationalUnit'
        }
        It 'Previewed under -WhatIf, with nothing read or written' {
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult -WhatIf
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Previewed'
            $script:Calls.Count | Should -Be 0
        }
        It 'Skipped (not Previewed) when the confirmation is declined' {
            $c = New-DecliningCmdlet
            $r = InModuleScope NSP.ActiveDirectory -Parameters @{ C = $c } { param($C) Invoke-NSPADOrganizationalUnitOutcome -Cmdlet $C -Name 'VPN' -Path 'DC=contoso,DC=example' }
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Skipped'
        }
        It 'reports the DC, and every call used it' {
            $r = New-NSPADOrganizationalUnit @script:Ou -AsResult -Server $script:DC
            $r.Server | Should -Be $script:DC
            @($script:Calls | Where-Object { $_.Server -ne $script:DC }) | Should -BeNullOrEmpty
        }
        It 'reports no DC when none was pinned' {
            (New-NSPADOrganizationalUnit @script:Ou -AsResult).Server | Should -BeNullOrEmpty
        }
        It 'without -AsResult still returns the DN string' {
            # The default path reads with -ErrorAction SilentlyContinue and expects $null for a
            # missing OU (backlog item A1); give it that, as the existing suite does.
            Mock -ModuleName NSP.ActiveDirectory Get-ADOrganizationalUnit { $null }
            $r = New-NSPADOrganizationalUnit @script:Ou
            $r | Should -BeOfType [string]
            $r | Should -Be 'OU=VPN,DC=contoso,DC=example'
        }
    }

    Context 'New-NSPADGroup' {
        It 'Created, then AlreadyPresent' {
            $a = New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'
            $b = New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $b; $b.Outcome | Should -Be 'AlreadyPresent'
        }
        It 'Failed/Conflict when the name exists in another OU (finding N4)' {
            $script:D.Groups['Administrators'] = [pscustomobject]@{ SamAccountName = 'Administrators'; DistinguishedName = 'CN=Administrators,CN=Builtin,DC=contoso,DC=example'; GroupScope = 'DomainLocal'; GroupCategory = 'Security' }
            $r = New-NSPADGroup -Name 'Administrators' -Path 'OU=VPN,DC=contoso,DC=example' -GroupScope DomainLocal -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'Conflict'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-ADGroup'
        }
        It 'Failed/Conflict when it exists with another scope' {
            $null = New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' -AsResult
            (New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' -GroupScope Universal -AsResult).ErrorCode | Should -Be 'Conflict'
        }
        It 'Failed/ReadBackFailed when the group cannot be seen after the create' {
            $script:D.DropWrites = $true
            (New-NSPADGroup -Name 'VPN_Staff' -Path 'OU=VPN,DC=contoso,DC=example' -AsResult).ErrorCode | Should -Be 'ReadBackFailed'
        }
    }

    Context 'Add-NSPADGroupMember' {
        It 'Created, then AlreadyPresent, then ReadBackFailed for a dropped add' {
            $g = 'CN=G,DC=contoso,DC=example'
            $a = Add-NSPADGroupMember -GroupIdentity $g -MemberIdentity 'CN=U,DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'
            (Add-NSPADGroupMember -GroupIdentity $g -MemberIdentity 'CN=U,DC=contoso,DC=example' -AsResult).Outcome | Should -Be 'AlreadyPresent'
            $script:D.DropWrites = $true
            (Add-NSPADGroupMember -GroupIdentity $g -MemberIdentity 'CN=V,DC=contoso,DC=example' -AsResult).ErrorCode | Should -Be 'ReadBackFailed'
        }
    }

    Context 'New-NSPADGpoLink' {
        It 'Created, then AlreadyPresent' {
            $a = New-NSPADGpoLink -GpoName 'NSP - X' -TargetDN 'DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'
            (New-NSPADGpoLink -GpoName 'NSP - X' -TargetDN 'DC=contoso,DC=example' -AsResult).Outcome | Should -Be 'AlreadyPresent'
        }
        It 'Failed/ReadBackFailed when the link does not appear' {
            $script:D.DropWrites = $true
            (New-NSPADGpoLink -GpoName 'NSP - X' -TargetDN 'DC=contoso,DC=example' -AsResult).ErrorCode | Should -Be 'ReadBackFailed'
        }
    }

    Context 'Set-NSPADGpoWmiFilter' {
        BeforeEach {
            $script:D.Gpos[$script:GpoName] = $true
            $script:D.Filters[$script:FilterName] = [pscustomobject]@{ Name = $script:FilterName; Id = '{F1}'; Query = @('q'); Description = 'd'; DN = 'CN={F1}' }
        }
        It 'Updated, then AlreadyPresent' {
            $a = Set-NSPADGpoWmiFilter -GpoName $script:GpoName -WmiFilterName $script:FilterName -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Updated'
            (Set-NSPADGpoWmiFilter -GpoName $script:GpoName -WmiFilterName $script:FilterName -AsResult).Outcome | Should -Be 'AlreadyPresent'
        }
        It 'Failed/NotFound for a filter that does not exist, with nothing written' {
            $r = Set-NSPADGpoWmiFilter -GpoName $script:GpoName -WmiFilterName 'Nope' -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'NotFound'
            @($script:Calls.Cmd) | Should -Not -Contain 'Set-NSPADGpoWqlFilterAttribute'
        }
        It 'AlreadyPresent for -Clear on a GPO with no filter' {
            (Set-NSPADGpoWmiFilter -GpoName $script:GpoName -Clear -AsResult).Outcome | Should -Be 'AlreadyPresent'
        }
    }

    Context 'New-NSPADWmiFilter' {
        It 'Created, AlreadyPresent, then Updated when the query drifts' {
            $f = [pscustomobject]@{ Name = 'F'; Expression = @('SELECT 1'); Description = 'd' }
            $a = $f | New-NSPADWmiFilter -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'
            ($f | New-NSPADWmiFilter -AsResult).Outcome | Should -Be 'AlreadyPresent'
            $f.Expression = @('SELECT 2')
            ($f | New-NSPADWmiFilter -AsResult).Outcome | Should -Be 'Updated'
        }
    }

    Context 'Import-NSPADGpoBackup' {
        BeforeEach {
            $script:D.Filters[$script:FilterName] = [pscustomobject]@{ Name = $script:FilterName; Id = '{F1}'; Query = @('q'); Description = 'd'; DN = 'CN={F1}' }
            $script:B = New-FakeGpoBackup (Join-Path $TestDrive ('b_' + [guid]::NewGuid().ToString('N')))
        }
        It 'Created when no GPO of that name existed, with filter and link read back' {
            $r = Import-NSPADGpoBackup -Path $script:B -WmiFilterName $script:FilterName -LinkAtDomainRoot -AsResult
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Created'
            $r.ObservedTarget | Should -Be $script:GpoName
        }
        It 'Updated when Import-GPO overwrote an existing GPO' {
            $script:D.Gpos[$script:GpoName] = $true
            (Import-NSPADGpoBackup -Path $script:B -AsResult).Outcome | Should -Be 'Updated'
        }
        It 'Previewed in a dry run, and Import-GPO is NOT called (one gate in this mode)' {
            Set-NSPDryRun -Enabled $true -Confirm:$false
            $r = Import-NSPADGpoBackup -Path $script:B -LinkAtDomainRoot -AsResult
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Previewed'
            @($script:Calls.Cmd) | Should -Not -Contain 'Import-GPO'
        }
        It 'Failed/NotFound for a missing filter, before Import-GPO' {
            $r = Import-NSPADGpoBackup -Path $script:B -WmiFilterName 'Nope' -AsResult
            $r.ErrorCode | Should -Be 'NotFound'
            @($script:Calls.Cmd) | Should -Not -Contain 'Import-GPO'
        }
        It 'Failed/ReadBackFailed when the link is not there afterwards' {
            Mock -ModuleName NSP.ActiveDirectory New-GPLink { }
            $r = Import-NSPADGpoBackup -Path $script:B -LinkAtDomainRoot -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'ReadBackFailed'
        }
    }

    Context 'New-NSPADAutoEnrollGpo' {
        It 'Created, then AlreadyPresent with nothing written' {
            $a = New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -DomainDn 'DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'
            $script:Calls.Clear()
            $b = New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -DomainDn 'DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $b; $b.Outcome | Should -Be 'AlreadyPresent'
            @($script:Calls.Cmd) | Should -Not -Contain 'Set-GPRegistryValue'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-GPLink'
        }
        It 'Updated when one value drifted' {
            $null = New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -DomainDn 'DC=contoso,DC=example' -AsResult
            $k = @($script:D.Values.Keys)[0]; $script:D.Values[$k] = 'drifted'
            (New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -DomainDn 'DC=contoso,DC=example' -AsResult).Outcome | Should -Be 'Updated'
        }
        It 'Failed/WriteFailed when a value cannot be set, and the GPO is not linked' {
            Mock -ModuleName NSP.ActiveDirectory Set-GPRegistryValue { throw $script:Secret }
            $r = New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -DomainDn 'DC=contoso,DC=example' -AsResult
            Assert-OutcomeContract $r
            $r.ErrorCode | Should -Be 'WriteFailed'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-GPLink'
        }
        It 'Failed/PreconditionFailed without a domain name, and never guesses from the logon domain' {
            Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { throw 'Unable to contact the server.' }
            $saved = $env:USERDNSDOMAIN
            try {
                $env:USERDNSDOMAIN = 'contoso.example'
                $r = New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -AsResult
                $r.ErrorCode | Should -Be 'PreconditionFailed'
                @($script:Calls.Cmd) | Should -Not -Contain 'New-GPO'
            } finally { $env:USERDNSDOMAIN = $saved }
        }
        It 'Previewed in a dry run' {
            Set-NSPDryRun -Enabled $true -Confirm:$false
            (New-NSPADAutoEnrollGpo -GpoName 'NSP - Auto' -DomainDn 'DC=contoso,DC=example' -AsResult).Outcome | Should -Be 'Previewed'
            @($script:Calls.Cmd) | Should -Not -Contain 'New-GPO'
        }
    }

    Context 'New-NSPADServiceAccount' {
        BeforeEach { $script:D.KdsKeys = 1 }
        It 'Created, then AlreadyPresent, and reports the DC it used' {
            $a = New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -AsResult
            Assert-OutcomeContract $a
            $a.Outcome | Should -Be 'Created'
            $a.Server | Should -Be 'dc02.contoso.example'
            (New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -AsResult).Outcome | Should -Be 'AlreadyPresent'
        }
        It 'Failed/Conflict when it exists without every planned computer' {
            $script:D.Gmsa['svc_new'] = [pscustomobject]@{ DistinguishedName = 'CN=svc_new'; AllowedPrincipals = @([pscustomobject]@{ Sid = 'S-1-5-21-9-9-9-9' }) }
            (New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -AsResult).ErrorCode | Should -Be 'Conflict'
        }
        It 'Failed/NotFound for a missing computer' {
            (New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'NOPE01' -AsResult).ErrorCode | Should -Be 'NotFound'
        }
        It 'Failed/PreconditionFailed with no usable KDS root key' {
            $script:D.KdsKeys = 0
            (New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -AsResult).ErrorCode | Should -Be 'PreconditionFailed'
        }
        It 'Previewed under -WhatIf even with a computer and the KDS key missing' {
            $script:D.KdsKeys = 0
            $r = New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'NOPE01' -AsResult -WhatIf
            Assert-OutcomeContract $r
            $r.Outcome | Should -Be 'Previewed'
        }
        It 'still THROWS when -Server and -DomainInfo name different DCs' {
            $d = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc01.contoso.example'; DNSRoot = 'contoso.example' }
            { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $d -Server $script:DC -AsResult } | Should -Throw '*different domain controllers*'
        }
    }

    Context 'Install-NSPADServiceAccount (local)' {
        It 'Created, then AlreadyPresent; Server is always empty' {
            $a = Install-NSPADServiceAccount -Name 'svc_job' -AsResult
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'; $a.Server | Should -BeNullOrEmpty
            (Install-NSPADServiceAccount -Name 'svc_job' -AsResult).Outcome | Should -Be 'AlreadyPresent'
        }
        It 'Failed/ReadBackFailed when the account does not test good after the install' {
            $script:D.DropWrites = $true
            (Install-NSPADServiceAccount -Name 'svc_job' -AsResult).ErrorCode | Should -Be 'ReadBackFailed'
        }
    }

    Context 'New-NSPADKdsRootKey' {
        It 'Created when none existed, then AlreadyPresent; Server is always empty' {
            $a = New-NSPADKdsRootKey -EffectiveTime (Get-Date) -AsResult -Confirm:$false
            Assert-OutcomeContract $a; $a.Outcome | Should -Be 'Created'; $a.Server | Should -BeNullOrEmpty
            (New-NSPADKdsRootKey -EffectiveTime (Get-Date) -AsResult -Confirm:$false).Outcome | Should -Be 'AlreadyPresent'
        }
        It 'Failed/PreconditionFailed when the keys cannot be read' {
            Mock -ModuleName NSP.ActiveDirectory Get-NSPADKdsRootKeyStatus { [pscustomobject]@{ Status = 'CannotRead'; Visible = 0; Usable = 0 } }
            (New-NSPADKdsRootKey -EffectiveTime (Get-Date) -AsResult -Confirm:$false).ErrorCode | Should -Be 'PreconditionFailed'
        }
        It 'still THROWS for a start time in the past (parameter validation)' {
            { New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddDays(-1) -AsResult -Confirm:$false } | Should -Throw '*in the past*'
        }
    }
}
