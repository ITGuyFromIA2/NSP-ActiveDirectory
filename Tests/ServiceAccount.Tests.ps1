<#
    Pester 5. gMSA lookups and creation with LDAP mocked (Read-NSPADLdap) and the AD cmdlets stubbed
    where RSAT is absent. msDS-GroupMSAMembership values are real security descriptors built here.
#>

BeforeAll {
    $toolkits = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $toolkits 'NSP-Toolkit\NSP.Toolkit.psd1') -Force -Global -ErrorAction Stop
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force -ErrorAction Stop

    $script:stubbed = @()
    foreach ($stub in @{ 'New-ADServiceAccount' = 'param($Name, $DNSHostName, $Enabled, $PrincipalsAllowedToRetrieveManagedPassword, $ManagedPasswordIntervalInDays, $KerberosEncryptionType, $Server, $Description)'; 'Install-ADServiceAccount' = 'param($Identity)'; 'Test-ADServiceAccount' = 'param($Identity)' }.GetEnumerator()) {
        if (-not (Get-Command $stub.Key -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$($stub.Key)" -Value ([scriptblock]::Create("[CmdletBinding()] $($stub.Value) `$null"))
            $script:stubbed += $stub.Key
        }
    }

    function ConvertTo-TestSidBytes { param([string]$Sid) $s = [Security.Principal.SecurityIdentifier]::new($Sid); $b = [byte[]]::new($s.BinaryLength); $s.GetBinaryForm($b, 0); , $b }
    function ConvertTo-TestMembership {
        param([string[]]$Sid)
        $sd = New-Object System.DirectoryServices.ActiveDirectorySecurity
        $sd.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach ($s in $Sid) { $sd.AddAccessRule([System.DirectoryServices.ActiveDirectoryAccessRule]::new([Security.Principal.SecurityIdentifier]::new($s), 'GenericAll', 'Allow')) }
        , $sd.GetSecurityDescriptorBinaryForm()
    }
    $script:domain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'contoso.example'; NetBIOSName = 'CONTOSO'; DistinguishedName = 'DC=contoso,DC=example'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example'; Server = 'dc02.contoso.example' }
    $script:computer = 'APP01'
    $script:appSid = 'S-1-5-21-1-2-3-1105'
    $script:groupSid = 'S-1-5-21-1-2-3-2001'
    $script:gmsa = @{ distinguishedname = 'CN=svc_job,CN=Managed Service Accounts,DC=contoso,DC=example'; dnshostname = 'svc_job.contoso.example'; useraccountcontrol = 4096; objectsid = (ConvertTo-TestSidBytes 'S-1-5-21-1-2-3-3001'); 'msds-managedpasswordinterval' = 30; 'msds-groupmsamembership' = (ConvertTo-TestMembership $script:groupSid) }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Set-NSPDryRun -Enabled $true
}

Describe 'Get-NSPADServiceAccount' {
    It 'returns the gMSA with its logon name, enabled state, interval, and allowed principals' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { $script:gmsa }
        $a = Get-NSPADServiceAccount -Name 'svc_job' -DomainInfo $script:domain
        $a.Logon | Should -Be 'CONTOSO\svc_job$'
        $a.Enabled | Should -BeTrue
        $a.PasswordIntervalDays | Should -Be 30
        $a.SID | Should -Be 'S-1-5-21-1-2-3-3001'
        @($a.AllowedPrincipals.Sid) | Should -Be @($script:groupSid)
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Filter -eq '(&(objectClass=msDS-GroupManagedServiceAccount)(sAMAccountName=svc_job$))' }
    }
    It 'returns nothing when there is no such gMSA' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }
        Get-NSPADServiceAccount -Name 'nope' -DomainInfo $script:domain | Should -BeNullOrEmpty
    }
}

Describe 'Test-NSPADServiceAccount' {
    BeforeEach {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { [pscustomobject]@{ Name = 'APP01'; DistinguishedName = 'CN=APP01,OU=Servers,DC=contoso,DC=example'; SID = $script:appSid } }
    }
    It 'passes when the computer is allowed through a group it is in' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Filter -like '*msDS-GroupManagedServiceAccount*' } { $script:gmsa }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Property -contains 'tokenGroups' } { @{ tokengroups = @((ConvertTo-TestSidBytes $script:groupSid), (ConvertTo-TestSidBytes 'S-1-5-21-1-2-3-515')) } }
        $t = Test-NSPADServiceAccount -Name 'svc_job' -ComputerName $script:computer -DomainInfo $script:domain
        $t.Exists | Should -BeTrue
        $t.ComputerAllowed | Should -BeTrue
        $t.Installed | Should -BeNullOrEmpty -Because 'install state is only checked for this computer'
        $t.Ready | Should -BeTrue
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Scope -eq 'Base' -and $MultiValued -contains 'tokenGroups' }
    }
    It 'lists what is wrong when the account is disabled and the computer is not allowed' {
        $disabled = $script:gmsa.Clone(); $disabled.useraccountcontrol = 4098
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Filter -like '*msDS-GroupManagedServiceAccount*' } { $disabled }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Property -contains 'tokenGroups' } { @{ tokengroups = @(, (ConvertTo-TestSidBytes 'S-1-5-21-1-2-3-515')) } }
        $t = Test-NSPADServiceAccount -Name 'svc_job' -ComputerName $script:computer -DomainInfo $script:domain
        $t.Ready | Should -BeFalse
        ($t.Problems -join "`n") | Should -BeLike '*is disabled*'
        ($t.Problems -join "`n") | Should -BeLike '*APP01 may not retrieve the password*'
    }
    It 'reports a missing gMSA' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }
        (Test-NSPADServiceAccount -Name 'nope' -ComputerName $script:computer -DomainInfo $script:domain).Problems | Should -Be @("No gMSA named 'nope' in contoso.example.")
    }
}

Describe 'New-NSPADServiceAccount' {
    BeforeEach {
        Mock -ModuleName NSP.ActiveDirectory Use-NSPADDependency { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADComputer { [pscustomobject]@{ Name = 'APP01'; DistinguishedName = 'CN=APP01,OU=Servers,DC=contoso,DC=example'; SID = $script:appSid } }
        Mock -ModuleName NSP.ActiveDirectory New-ADServiceAccount { }
        Set-NSPDryRun -Enabled $false
    }
    AfterEach { Set-NSPDryRun -Enabled $true }

    It 'creates the gMSA on the located DC with AES only and the computer as allowed principal' {
        $script:created = $false
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { if ($script:created) { [pscustomobject]@{ Name = 'svc_new'; Logon = 'CONTOSO\svc_new$' } } }
        Mock -ModuleName NSP.ActiveDirectory New-ADServiceAccount { $script:created = $true }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADKdsRootKeyStatus { [pscustomobject]@{ Visible = 1; Usable = 1 } }
        $a = New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -Description 'Nightly' -DomainInfo $script:domain -Confirm:$false
        $a.Logon | Should -Be 'CONTOSO\svc_new$'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 1 -ParameterFilter {
            $Name -eq 'svc_new' -and $DNSHostName -eq 'svc_new.contoso.example' -and $Server -eq 'dc02.contoso.example' -and
            @($PrincipalsAllowedToRetrieveManagedPassword) -contains 'CN=APP01,OU=Servers,DC=contoso,DC=example' -and
            (@($KerberosEncryptionType) -join ',') -eq 'AES128,AES256' -and $ManagedPasswordIntervalInDays -eq 30 -and $Description -eq 'Nightly'
        }
    }
    It 'returns an existing gMSA unchanged' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { [pscustomobject]@{ Name = 'svc_job'; Logon = 'CONTOSO\svc_job$'; DistinguishedName = 'CN=svc_job'; AllowedPrincipals = @([pscustomobject]@{ Sid = $script:appSid }) } }
        (New-NSPADServiceAccount -Name 'svc_job' -AllowedComputer 'APP01' -DomainInfo $script:domain -Confirm:$false).Name | Should -Be 'svc_job'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 0
    }
    It 'refuses without a usable KDS root key, and explains how to make one' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADKdsRootKeyStatus { [pscustomobject]@{ Visible = 0; Usable = 0 } }
        { New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $script:domain -Confirm:$false } | Should -Throw '*Add-KdsRootKey*'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 0
    }
    It 'changes nothing in DRY RUN' {
        Set-NSPDryRun -Enabled $true
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADServiceAccount { }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADKdsRootKeyStatus { [pscustomobject]@{ Visible = 1; Usable = 1 } }
        New-NSPADServiceAccount -Name 'svc_new' -AllowedComputer 'APP01' -DomainInfo $script:domain -Confirm:$false 6>$null | Should -BeNullOrEmpty
        Should -Invoke -ModuleName NSP.ActiveDirectory New-ADServiceAccount -Times 0
    }
}

Describe 'Install-NSPADServiceAccount' {
    It 'installs, then reports the Test-ADServiceAccount result' {
        Mock -ModuleName NSP.ActiveDirectory Use-NSPADDependency { }
        Mock -ModuleName NSP.ActiveDirectory Install-ADServiceAccount { }
        Mock -ModuleName NSP.ActiveDirectory Test-ADServiceAccount { $true }
        Set-NSPDryRun -Enabled $false
        try { Install-NSPADServiceAccount -Name 'svc_job$' -Confirm:$false | Should -BeTrue } finally { Set-NSPDryRun -Enabled $true }
        Should -Invoke -ModuleName NSP.ActiveDirectory Install-ADServiceAccount -Times 1 -ParameterFilter { $Identity -eq 'svc_job' }
    }
}
