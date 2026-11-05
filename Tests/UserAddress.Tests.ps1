BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
    function New-AddressFixture {
        param([int]$Number = 1)
        [pscustomobject]@{
            PSTypeName = 'NSP.ActiveDirectory.User'
            ObjectGUID = [guid](('00000000-0000-0000-0000-{0:d12}' -f $Number))
            ObjectSID = "S-1-5-21-1-2-3-$($Number + 1000)"
            DistinguishedName = "CN=User$Number,DC=old,DC=example"
            SamAccountName = "user$Number"; GivenName = 'Alex'; Surname = "Example$Number"
            UserPrincipalName = "user$Number@old.example"; Mail = "user$Number@old.example"
            ProxyAddresses = [string[]]@("SMTP:user$Number@old.example", 'X500:/o=Example/ou=Legacy/cn=one')
            DomainDNSRoot = 'old.example'; Server = 'dc01.old.example'; Enabled = $true
        }
    }
}
Describe 'User address application (offline fakes)' {
    BeforeAll {
        # Supply a seam even on hosts without RSAT; no real directory cmdlet is invoked.
        & (Get-Module NSP.ActiveDirectory) {
            function script:Set-ADUser { param($Identity,$Server,$Replace,$Clear,$ErrorAction) }
        }
    }
    BeforeEach {
        $script:current = New-AddressFixture
        $script:addressPlan = Get-NSPADUserAddressPlan -User $script:current -OldDomain old.example -NewDomain new.example
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo { [pscustomobject]@{AvailableUPNSuffixes=@('old.example','new.example')} }
        Mock -ModuleName NSP.ActiveDirectory Assert-NSPADCommand {}
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADUser { $script:current }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo {
            [pscustomobject]@{ DistinguishedName='DC=old,DC=example' }
        }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap {
            @{
                samaccountname=$script:current.SamAccountName; userprincipalname=$script:current.UserPrincipalName
                mail=$script:current.Mail; proxyaddresses=$script:current.ProxyAddresses
                objectsid=([Security.Principal.SecurityIdentifier]::new($script:current.ObjectSID))
            }
        }
        Mock -ModuleName NSP.ActiveDirectory Set-ADUser {
            foreach ($name in $Replace.Keys) { $script:current.$name = $Replace[$name] }
            foreach ($name in $Clear) { $script:current.$name = @() }
        }
    }
    It 'previews by default without any directory read or write' {
        (Set-NSPADUserAddress -Plan $script:addressPlan).Result | Should -Be 'Preview'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADUser -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'performs no read or write with Apply WhatIf' {
        Set-NSPADUserAddress -Plan $script:addressPlan -Apply -WhatIf
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADUser -Times 0 -Exactly
    }
    It 'rejects stale source state before writing' {
        $script:current.Mail = 'changed@old.example'
        { Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false } | Should -Throw '*stale*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'blocks a changed UPN when its suffix is missing on premises' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo { [pscustomobject]@{AvailableUPNSuffixes=@('old.example')} }
        { Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false } | Should -Throw '*suffix*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'does not require an email-only target domain to be a forest UPN suffix' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo { throw 'No forest facts should be requested' }
        $script:addressPlan = Get-NSPADUserAddressPlan -User $script:current -OldDomain old.example -NewDomain new.example -UpdateUPN:$false
        (Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false).Result | Should -Be 'Verified'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo -Times 0 -Exactly
    }
    It 'rejects a tampered proposed value' {
        $script:addressPlan.After.Mail = 'tampered@new.example'
        { Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'blocks new collisions from the refreshed inventory' {
        $other = New-AddressFixture 2; $other.Mail = 'user1@new.example'
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADUser { @($script:current,$other) }
        { Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'uses GUID identity, pinned server and verifies the result' {
        $result = Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false
        $result.Result | Should -Be 'Verified'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $script:current.ObjectGUID -and $Server -eq 'dc01.old.example' -and
            $Replace.userprincipalname -eq 'user1@new.example'
        }
    }
    It 'reports readback failure without claiming a verified write' {
        Mock -ModuleName NSP.ActiveDirectory Set-ADUser {}
        (Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false).Result | Should -Be 'VerificationFailed'
    }
    It 'rejects duplicate plans before writing' {
        { Set-NSPADUserAddress -Plan @($script:addressPlan,$script:addressPlan) -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'writes only attributes that actually change' {
        $script:addressPlan = Get-NSPADUserAddressPlan -User $script:current -OldDomain old.example -NewDomain new.example -UpdateMail:$false -UpdateUPN:$false
        (Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false).Result | Should -Be 'Verified'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 1 -Exactly -ParameterFilter {
            $Replace.Count -eq 1 -and $Replace.ContainsKey('proxyaddresses')
        }
    }
    It 'clears an empty proxy list using Clear rather than Replace with an empty array' {
        $script:current.ProxyAddresses = @('smtp:alias@routing.example')
        $script:addressPlan = Get-NSPADUserAddressPlan -User $script:current -OldDomain old.example -NewDomain new.example -UpdatePrimarySmtp:$false -PreserveOldAddress:$false -RemoveAliasDomain routing.example
        (Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false).Result | Should -Be 'Verified'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 1 -Exactly -ParameterFilter { $Clear -contains 'proxyaddresses' }
    }
    It 'stops after an uncertain write and never reports it as verified' {
        Mock -ModuleName NSP.ActiveDirectory Set-ADUser { throw 'Fake write failure' }
        (Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false).Result | Should -Be 'WriteUnverified'
    }
    It 'refuses a changed stable SID at preflight' {
        $script:current.ObjectSID = 'S-1-5-21-1-2-3-9999'
        { Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
    It 'refuses a user edit after forest preflight at the immediate reread' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap {
            @{samaccountname='user1'; userprincipalname='late@old.example'; mail='user1@old.example'; proxyaddresses=@(); objectsid=([Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001'))}
        }
        (Set-NSPADUserAddress -Plan $script:addressPlan -Apply -Confirm:$false).Result | Should -Be 'Failed'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADUser -Times 0 -Exactly
    }
}
Describe 'User address migration planning (offline)' {
    BeforeEach { $script:u = New-AddressFixture }
    It 'preserves the input and aliases while replacing a suffix literally' {
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example
        $p.PSObject.TypeNames[0] | Should -Be 'NSP.ActiveDirectory.UserAddressPlan'
        $p.After.UserPrincipalName | Should -Be 'user1@new.example'
        $p.After.Mail | Should -Be 'user1@new.example'
        $p.After.ProxyAddresses | Should -Contain 'SMTP:user1@new.example'
        $p.After.ProxyAddresses | Should -Contain 'smtp:user1@old.example'
        $p.After.ProxyAddresses | Should -Contain 'X500:/o=Example/ou=Legacy/cn=one'
        $u.UserPrincipalName | Should -Be 'user1@old.example'
        $u.ProxyAddresses.Count | Should -Be 2
        $p.Blocked | Should -BeFalse
    }
    It 'generates <Format>' -ForEach @(
        @{Format='FLast'; Expected='aexample1'}, @{Format='First.Last'; Expected='alex.example1'},
        @{Format='LastF'; Expected='example1a'}, @{Format='SamAccountName'; Expected='user1'}
    ) {
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -Format $Format -ChangeSamAccountName
        $p.After.UserPrincipalName | Should -Be "$Expected@new.example"
        $p.After.SamAccountName | Should -Be $Expected
    }
    It 'blocks absent names instead of inventing NA identities' {
        $u.GivenName = ''
        (Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -Format FLast).Blocked | Should -BeTrue
    }
    It 'preserves unrelated UPNs and mail as a blocking review case' {
        $u.Mail = 'one@other.example'
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example
        $p.Blocked | Should -BeTrue
        $p.After.Mail | Should -Be 'one@other.example'
    }
    It 'does not treat a dot in a domain as regex syntax' {
        $u.UserPrincipalName = 'user1@oldXexample'
        (Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example).Blocked | Should -BeTrue
    }
    It 'keeps mail blank unless creation is requested' {
        $u.Mail = ''
        (Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example).After.Mail | Should -Be ''
        (Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -CreateMailIfEmpty).After.Mail | Should -Be 'user1@new.example'
    }
    It 'allows UPN and mail changes to be controlled independently' {
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -UpdateUPN:$false -UpdateMail:$false
        $p.After.UserPrincipalName | Should -Be $u.UserPrincipalName
        $p.After.Mail | Should -Be $u.Mail
        $p.After.ProxyAddresses | Should -Contain 'SMTP:user1@new.example'
    }
    It 'can preserve the primary SMTP while updating UPN and mail' {
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -UpdatePrimarySmtp:$false
        $p.After.UserPrincipalName | Should -Be 'user1@new.example'
        $p.After.ProxyAddresses | Should -Contain 'SMTP:user1@old.example'
        $p.After.ProxyAddresses | Should -Not -Contain 'SMTP:user1@new.example'
    }
    It 'keeps skipped accounts as collision candidates' {
        $other = New-AddressFixture 2; $other.Mail = 'user1@new.example'
        $plans = @(Get-NSPADUserAddressPlan -User @($u,$other) -SkipIdentity $other.ObjectGUID -OldDomain old.example -NewDomain new.example)
        $plans.Count | Should -Be 1
        $plans[0].Blocked | Should -BeTrue
    }
    It 'creates an absent primary SMTP address' {
        $u.ProxyAddresses = @()
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example
        $p.After.ProxyAddresses | Should -Contain 'SMTP:user1@new.example'
    }
    It 'only removes explicitly selected alias domains and address types' {
        $u.ProxyAddresses += @('smtp:alias@old.example','smtp:route@routing.example','X400:c=EX;a= ;p=Example')
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -ConvertAliasDomain -RemoveAliasDomain routing.example -RemoveAddressType X400 -PreserveOldAddress:$false
        $p.After.ProxyAddresses | Should -Contain 'smtp:alias@new.example'
        $p.After.ProxyAddresses | Should -Not -Contain 'smtp:alias@old.example'
        $p.After.ProxyAddresses | Should -Not -Contain 'smtp:route@routing.example'
        $p.After.ProxyAddresses | Should -Contain 'X500:/o=Example/ou=Legacy/cn=one'
        @($p.After.ProxyAddresses | Where-Object { $_ -clike 'X400:*' }).Count | Should -Be 0
    }
    It 'promotes the target alias and deduplicates exact addresses without substring matching' {
        $u.ProxyAddresses += @('smtp:USER1@new.example','smtp:ab@new.example','smtp:b@new.example')
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example
        @($p.After.ProxyAddresses | Where-Object { $_ -ieq 'smtp:user1@new.example' }).Count | Should -Be 1
        @($p.After.ProxyAddresses | Where-Object { $_ -clike 'SMTP:*' }).Count | Should -Be 1
        $p.After.ProxyAddresses | Should -Contain 'smtp:ab@new.example'
        $p.After.ProxyAddresses | Should -Contain 'smtp:b@new.example'
    }
    It 'blocks multiple or unrelated existing primary SMTP addresses' {
        $u.ProxyAddresses += 'SMTP:other@other.example'
        (Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example).Blocked | Should -BeTrue
    }
    It 'is idempotent after migration' {
        $p = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example
        foreach ($name in 'SamAccountName','UserPrincipalName','Mail','ProxyAddresses') { $u.$name = $p.After.$name }
        $again = Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example
        $again.Changed | Should -BeFalse
        $again.Blocked | Should -BeFalse
    }
    It 'detects proposed collisions with unselected inventory users' {
        $other = New-AddressFixture 2
        $other.ProxyAddresses = @('SMTP:user1@new.example')
        $p = Get-NSPADUserAddressPlan -User @($u,$other) -Identity $u.ObjectGUID -OldDomain old.example -NewDomain new.example
        @($p).Count | Should -Be 1
        $p.Blocked | Should -BeTrue
    }
    It 'detects collisions between generated proposals' {
        $other = New-AddressFixture 2; $other.Surname = $u.Surname
        $plans = @(Get-NSPADUserAddressPlan -User @($u,$other) -OldDomain old.example -NewDomain new.example -Format First.Last)
        @($plans | Where-Object Blocked).Count | Should -Be 2
    }
    It 'rejects incomplete identity and duplicate inventory GUIDs' {
        { Get-NSPADUserAddressPlan -User @($u,$u) -OldDomain old.example -NewDomain new.example } | Should -Throw
        $u.ObjectGUID = [guid]::Empty
        { Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example } | Should -Throw
    }
    It 'rejects unknown selections and unsafe domains' {
        { Get-NSPADUserAddressPlan -User $u -Identity ([guid]::NewGuid()) -OldDomain old.example -NewDomain new.example } | Should -Throw
        { Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain 'bad@example' } | Should -Throw
    }
    It 'blocks generated sAMAccountNames longer than twenty characters' {
        $u.Surname = 'averylongsurnameexample'
        (Get-NSPADUserAddressPlan -User $u -OldDomain old.example -NewDomain new.example -Format First.Last -ChangeSamAccountName).Blocked | Should -BeTrue
    }
}
