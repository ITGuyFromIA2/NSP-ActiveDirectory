<#
    Pester 5. Get-NSPADDomainInfo / Get-NSPADComputer with the DC locator and LDAP mocked. The last
    Describe reads the real domain (read-only) when this machine is domain-joined, and is skipped
    otherwise.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force -ErrorAction Stop
}

Describe 'Get-NSPADDomainInfo (mocked)' {
    BeforeEach {
        Mock -ModuleName NSP.ActiveDirectory Find-NSPADDomainController { if ($Server) { $Server } else { 'dc02.contoso.example' } }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADRootDse { @{ defaultnamingcontext = 'DC=contoso,DC=example'; configurationnamingcontext = 'CN=Configuration,DC=contoso,DC=example' } }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap {
            switch -Wildcard ($SearchBase) {
                'CN=Partitions,*' { @{ netbiosname = 'CONTOSO'; dnsroot = 'contoso.example' } }
                'DC=contoso,DC=example' { @{ fsmoroleowner = 'CN=NTDS Settings,CN=DC01,CN=Servers,CN=HQ,CN=Sites,CN=Configuration,DC=contoso,DC=example' } }
                'CN=DC01,CN=Servers,*' { @{ dnshostname = 'dc01.contoso.example' } }
            }
        }
    }

    It 'returns the names, DN, PDC emulator, and the DC that answered' {
        $d = Get-NSPADDomainInfo
        $d.DNSRoot | Should -Be 'contoso.example'
        $d.NetBIOSName | Should -Be 'CONTOSO'
        $d.DistinguishedName | Should -Be 'DC=contoso,DC=example'
        $d.PDCEmulator | Should -Be 'dc01.contoso.example'
        $d.Server | Should -Be 'dc02.contoso.example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $SearchBase -like 'CN=Partitions,*' -and $Filter -eq '(&(objectClass=crossRef)(nCName=DC=contoso,DC=example))' }
    }
    It 'reads every value from a pinned -Server' {
        (Get-NSPADDomainInfo -Server 'dc03.contoso.example').Server | Should -Be 'dc03.contoso.example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADRootDse -Times 1 -Exactly -ParameterFilter { $Server -eq 'dc03.contoso.example' }
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 3 -Exactly -ParameterFilter { $Server -eq 'dc03.contoso.example' }
    }
    It 'still answers when the PDC server object cannot be read' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $SearchBase -like 'CN=DC01,*' } { throw 'access denied' }
        (Get-NSPADDomainInfo).PDCEmulator | Should -BeNullOrEmpty
    }
}

Describe 'Get-NSPADComputer (mocked)' {
    BeforeAll {
        $script:domain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc02.contoso.example'; DistinguishedName = 'DC=contoso,DC=example' }
        $script:sid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1105')
        $script:sidBytes = [byte[]]::new($script:sid.BinaryLength); $script:sid.GetBinaryForm($script:sidBytes, 0)
    }
    It 'finds the computer by sAMAccountName and converts its SID' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { @{ distinguishedname = 'CN=APP01,OU=Servers,DC=contoso,DC=example'; dnshostname = 'app01.contoso.example'; objectsid = $script:sidBytes } }
        $c = Get-NSPADComputer -Name 'APP01' -DomainInfo $script:domain
        $c.DistinguishedName | Should -Be 'CN=APP01,OU=Servers,DC=contoso,DC=example'
        $c.SID | Should -Be 'S-1-5-21-1-2-3-1105'
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Filter -eq '(&(objectCategory=computer)(sAMAccountName=APP01$))' -and $Server -eq 'dc02.contoso.example' }
    }
    It 'returns nothing for an unknown computer and escapes filter characters' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }
        Get-NSPADComputer -Name 'bad*(name)' -DomainInfo $script:domain | Should -BeNullOrEmpty
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Filter -eq '(&(objectCategory=computer)(sAMAccountName=bad\*\(name\)$))' }
    }
}

Describe 'Domain lookups against this machine''s domain (read-only)' {
    BeforeAll {
        $script:joined = try { [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { $false }
    }
    It 'reads the real domain and this computer without the AD module' {
        if (-not $script:joined) { Set-ItResult -Skipped -Because 'this machine is not domain-joined'; return }
        $d = Get-NSPADDomainInfo
        $d.DNSRoot | Should -Not -BeNullOrEmpty
        $d.NetBIOSName | Should -Not -BeNullOrEmpty
        $d.DistinguishedName | Should -BeLike 'DC=*'
        $c = Get-NSPADComputer -Name $env:COMPUTERNAME -DomainInfo $d
        $c.DistinguishedName | Should -BeLike "CN=$env:COMPUTERNAME,*"
        $c.SID | Should -BeLike 'S-1-5-21-*'
    }
}
