<#
    Pester 5. The KDS root key: the read (Get-NSPADKdsRootKeyStatus), the gated create
    (New-NSPADKdsRootKey) and what New-NSPADServiceAccount -WhatIf does without one.
    No real directory is touched: the LDAP reader and Add-KdsRootKey are mocked. $Keys is the fake
    list of keys in the forest, so a read after a create sees the new key.
#>

BeforeAll {
    $toolkits = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $bootstrap = @($env:NSP_ECOSYSTEM_ROOT, $toolkits, (Split-Path -Parent $toolkits)) | Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'NSP-Bootstrap\NSP.Bootstrap.psd1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $bootstrap) { throw 'NSP-Bootstrap checkout not found next to this repository (or set NSP_ECOSYSTEM_ROOT).' }
    Import-Module $bootstrap -Force -Global -ErrorAction Stop
    foreach ($m in 'NSP-Console\NSP.Console.psd1', 'NSP-Toolkit\NSP.Toolkit.psd1') { Import-Module (Join-Path $toolkits $m) -Force -Global -ErrorAction Stop }
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force -ErrorAction Stop

    $script:stubbed = @()
    foreach ($name in 'Add-KdsRootKey', 'New-ADServiceAccount') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] param(`$EffectiveTime, `$Name) throw 'Stand-in for $name was called without a mock.'"))
            $script:stubbed += $name
        }
    }
    $script:domain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'contoso.example'; NetBIOSName = 'CONTOSO'; DistinguishedName = 'DC=contoso,DC=example'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example'; Server = 'dc02.contoso.example' }
    function script:New-FakeKey([datetime]$StartUtc) { @{ cn = [guid]::NewGuid().ToString(); 'mskds-usestarttime' = $StartUtc.ToFileTimeUtc() } }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.ActiveDirectory, NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Get-NSPADKdsRootKeyStatus' {
    BeforeEach {
        $script:Keys = New-Object System.Collections.ArrayList
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { $script:Keys.ToArray() }
    }

    It 'reports NoneVisible on a forest with no key' {
        $s = Get-NSPADKdsRootKeyStatus -DomainInfo $domain
        $s.Status | Should -Be 'NoneVisible'
        $s.Visible | Should -Be 0
        $s.Usable | Should -Be 0
        $s.EarliestUseUtc | Should -BeNullOrEmpty
        $s.Server | Should -Be 'dc02.contoso.example'
    }

    It 'reports NotYetUsable, with the start time, for a key that has not started' {
        $start = [DateTime]::UtcNow.AddHours(10)
        [void]$Keys.Add((New-FakeKey $start))
        $s = Get-NSPADKdsRootKeyStatus -DomainInfo $domain
        $s.Status | Should -Be 'NotYetUsable'
        $s.Visible | Should -Be 1
        $s.Usable | Should -Be 0
        ([datetime]$s.EarliestUseUtc - $start).Duration().TotalSeconds | Should -BeLessThan 1
    }

    It 'reports Usable once one key has started' {
        [void]$Keys.Add((New-FakeKey ([DateTime]::UtcNow.AddHours(10))))
        [void]$Keys.Add((New-FakeKey ([DateTime]::UtcNow.AddHours(-1))))
        $s = Get-NSPADKdsRootKeyStatus -DomainInfo $domain
        $s.Status | Should -Be 'Usable'
        $s.Visible | Should -Be 2
        $s.Usable | Should -Be 1
    }

    It 'reads the forest configuration partition on the located DC, one level' {
        Get-NSPADKdsRootKeyStatus -DomainInfo $domain | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 1 -Exactly -ParameterFilter {
            $Server -eq 'dc02.contoso.example' -and $Scope -eq 'OneLevel' -and
            $SearchBase -eq 'CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,CN=Configuration,DC=contoso,DC=example'
        }
    }

    It 'returns CannotRead, without throwing, when the read fails' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { throw 'There is no such object on the server.' }
        $s = Get-NSPADKdsRootKeyStatus -DomainInfo $domain
        $s.Status | Should -Be 'CannotRead'
        $s.Detail | Should -BeLike '*no such object*'
        $s.Usable | Should -Be 0
    }

    It 'looks the domain up when none is passed' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo { $script:domain }
        (Get-NSPADKdsRootKeyStatus).Status | Should -Be 'NoneVisible'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -Times 1 -Exactly
    }
}

Describe 'New-NSPADKdsRootKey' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        $script:Keys = New-Object System.Collections.ArrayList
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Use-NSPADDependency { }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { $script:Keys.ToArray() }
        Mock -ModuleName NSP.ActiveDirectory Add-KdsRootKey { [void]$script:Keys.Add((New-FakeKey ([datetime]$EffectiveTime).ToUniversalTime())) }
        Set-NSPDryRun -Enabled $false -Confirm:$false
    }
    AfterEach { Set-NSPDryRun -Enabled $true -Confirm:$false }

    It 'has no default for the start time' {
        $parameter = (Get-Command New-NSPADKdsRootKey).Parameters['EffectiveTime']
        @($parameter.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory }).Count | Should -BeGreaterThan 0
    }

    It 'refuses a start time in the past, and reads and changes nothing' {
        { New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(-10) -DomainInfo $domain -Confirm:$false } | Should -Throw '*in the past*Nothing was changed*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 0 -Exactly
    }

    It 'creates a key with the given start time and reports it after reading it back' {
        $when = (Get-Date).AddHours(10)
        $s = New-NSPADKdsRootKey -EffectiveTime $when -DomainInfo $domain -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 1 -Exactly -ParameterFilter { $EffectiveTime -eq $when }
        $s.Created | Should -BeTrue
        $s.Visible | Should -Be 1
        $s.Status | Should -Be 'NotYetUsable'
    }

    It 'accepts a start time of now' {
        $s = New-NSPADKdsRootKey -EffectiveTime (Get-Date) -DomainInfo $domain -Confirm:$false
        $s.Created | Should -BeTrue
    }

    It 'creates nothing when a key already exists' {
        [void]$Keys.Add((New-FakeKey ([DateTime]::UtcNow.AddDays(-30))))
        $s = New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(10) -DomainInfo $domain -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 0 -Exactly
        $s.Created | Should -BeFalse
        $s.Status | Should -Be 'Usable'
    }

    It 'creates nothing when the keys cannot be read' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { throw 'Access is denied.' }
        { New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(10) -DomainInfo $domain -Confirm:$false } | Should -Throw '*could not be read*none was created*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 0 -Exactly
    }

    It 'creates nothing in a dry run' {
        Set-NSPDryRun -Enabled $true -Confirm:$false
        $s = New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(10) -DomainInfo $domain -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 0 -Exactly
        $s.Created | Should -BeFalse
        $s.Visible | Should -Be 0
    }

    It 'creates nothing under -WhatIf' {
        $s = New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(10) -DomainInfo $domain -WhatIf
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 0 -Exactly
        $s.Created | Should -BeFalse
    }

    It 'throws when the create ran but no key can be seen afterwards' {
        Mock -ModuleName NSP.ActiveDirectory Add-KdsRootKey { }      # reports success, writes nothing
        { New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(10) -DomainInfo $domain -Confirm:$false } | Should -Throw '*no KDS root key is visible*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Add-KdsRootKey -Times 1 -Exactly
    }

    It 'lets a create failure reach the caller' {
        Mock -ModuleName NSP.ActiveDirectory Add-KdsRootKey { throw 'The request is not supported.' }
        { New-NSPADKdsRootKey -EffectiveTime (Get-Date).AddHours(10) -DomainInfo $domain -Confirm:$false } | Should -Throw '*not supported*'
    }
}

Describe 'New-NSPADServiceAccount -WhatIf on a forest that is not ready' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Write-Warning { }
        Mock -ModuleName NSP.ActiveDirectory Use-NSPADDependency { }
        Mock -ModuleName NSP.ActiveDirectory New-ADServiceAccount { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { [pscustomobject]@{ Name = 'APP01'; DistinguishedName = 'CN=APP01,OU=Servers,DC=contoso,DC=example'; SID = 'S-1-5-21-1-2-3-1105' } }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }      # no KDS root key
        Set-NSPDryRun -Enabled $false -Confirm:$false
    }
    AfterEach { Set-NSPDryRun -Enabled $true -Confirm:$false }

    It 'warns about the missing KDS root key instead of throwing, and creates nothing' {
        { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $domain -WhatIf } | Should -Not -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like 'Preview:*KDS root key*' }
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 0 -Exactly
    }

    It 'warns about a missing computer and the missing key in one preview' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { }
        { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01', 'APP02' -DomainInfo $domain -WhatIf } | Should -Not -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Write-Warning -Times 2 -Exactly -ParameterFilter { $Message -like "Preview: no computer account*" }
        Should -Invoke -ModuleName NSP.ActiveDirectory Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like 'Preview:*KDS root key*' }
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 0 -Exactly
    }

    It 'without -WhatIf, a missing KDS root key still stops the command' {
        { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $domain -Confirm:$false } | Should -Throw '*Add-KdsRootKey*'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 0 -Exactly
    }

    It 'without -WhatIf, a missing computer still stops the command' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { }
        { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $domain -Confirm:$false } | Should -Throw "*No computer account 'APP01'*"
    }
}
