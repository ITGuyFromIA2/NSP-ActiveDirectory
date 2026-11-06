BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
    function Get-ProxyAdditionUser {
        [pscustomobject]@{ObjectGUID=[guid]'11111111-1111-1111-1111-111111111111';ObjectSID='S-1-5-21-1-2-3-1001';DomainDNSRoot='old.example';Server='dc01.old.example';SamAccountName='user1';UserPrincipalName='user1@old.example';Mail='user1@old.example';ProxyAddresses=@('SMTP:user1@old.example','SPO:existing-opaque-value')}
    }
}
Describe 'Explicit additional proxy planning' {
    It 'preserves actual Before and literal non-SMTP values without replacing the selected primary' {
        $user=Get-ProxyAdditionUser
        $map=@{};$map[$user.ObjectGUID.ToString()]=@('SMTP:other@new.example','SIP:user1@new.example','X500:/o=Example/ou=Cloud/cn=one')
        $plan=Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map
        $plan.Before.ProxyAddresses | Should -Be $user.ProxyAddresses
        $plan.After.ProxyAddresses | Should -Contain 'smtp:other@new.example'
        @($plan.After.ProxyAddresses|Where-Object {$_ -cmatch '^SMTP:'}).Count | Should -Be 1
        $plan.After.ProxyAddresses | Should -Contain 'SPO:existing-opaque-value'
        $plan.After.ProxyAddresses | Should -Contain 'SIP:user1@new.example'
        $user.ProxyAddresses.Count | Should -Be 2
    }
    It 'rejects additions to an unselected or absent AD GUID' {
        $user=Get-ProxyAdditionUser
        $map=@{'22222222-2222-2222-2222-222222222222'=@('smtp:other@new.example')}
        {Get-NSPADUserAddressPlan -User $user -Identity $user.ObjectGUID -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map} | Should -Throw '*selected*'
    }
    It 'rejects malformed and multiline proxy additions' {
        $user=Get-ProxyAdditionUser
        foreach($value in @('not-an-address',"SIP:user1@new.example`r`nOTHER:injected")){
            $map=@{};$map[$user.ObjectGUID.ToString()]=@($value)
            {Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map} | Should -Throw '*invalid protocol*'
        }
    }
    It 'retains one primary when an added address differs only by prefix/case' {
        $user=Get-ProxyAdditionUser
        $map=@{};$map[$user.ObjectGUID.ToString()]=@('SMTP:USER1@new.example','smtp:user1@NEW.example')
        $plan=Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map
        @($plan.After.ProxyAddresses|Where-Object {$_ -ieq 'smtp:user1@new.example'}).Count | Should -Be 1
        $plan.After.ProxyAddresses | Should -Contain 'SMTP:user1@new.example'
    }
    It 'supports a deserialized GUID-keyed policy object' {
        $user=Get-ProxyAdditionUser
        $map=@{};$map[$user.ObjectGUID.ToString()]=@('SIP:user1@new.example')
        $saved=$map|ConvertTo-Json -Depth 5|ConvertFrom-Json
        (Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $saved).After.ProxyAddresses | Should -Contain 'SIP:user1@new.example'
    }
    It 'still honors explicit legacy removals for additional values' {
        $user=Get-ProxyAdditionUser
        $map=@{};$map[$user.ObjectGUID.ToString()]=@('X500:/o=Example/cn=one')
        $plan=Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map -RemoveAddressType X500
        $plan.After.ProxyAddresses | Should -Not -Contain 'X500:/o=Example/cn=one'
    }
}

Describe 'Proxy addition collision and selection guards' {
    It 'rejects a trailing line feed in a literal proxy value' {
        $user = Get-ProxyAdditionUser
        $map = @{}; $map[$user.ObjectGUID.ToString()] = @("SIP:user1@new.example`n")
        { Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map } | Should -Throw '*invalid protocol*'
    }
    It 'blocks a literal <Protocol> addition claimed by an unselected user' -TestCases @(
        @{Protocol='SIP'; Value='SIP:shared@new.example'},
        @{Protocol='X500'; Value='X500:/o=Example/ou=Cloud/cn=shared'},
        @{Protocol='SMTP'; Value='smtp:shared@new.example'}
    ) {
        param($Protocol, $Value)
        $user = Get-ProxyAdditionUser
        $other = Get-ProxyAdditionUser
        $other.ObjectGUID = [guid]'22222222-2222-2222-2222-222222222222'
        $other.ObjectSID = 'S-1-5-21-1-2-3-1002'
        $other.SamAccountName = 'user2'
        $other.UserPrincipalName = 'user2@old.example'
        $other.Mail = 'user2@old.example'
        $other.ProxyAddresses = @($Value.ToLowerInvariant())
        $map = @{}; $map[$user.ObjectGUID.ToString()] = @($Value)
        $plan = Get-NSPADUserAddressPlan -User @($user,$other) -Identity $user.ObjectGUID -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map
        $plan.Blocked | Should -BeTrue
        $plan.Reasons | Should -Contain 'Address or account-name collision in supplied inventory.'
    }
    It 'blocks the same non-SMTP addition proposed for two selected users' {
        $user = Get-ProxyAdditionUser
        $other = Get-ProxyAdditionUser
        $other.ObjectGUID = [guid]'22222222-2222-2222-2222-222222222222'
        $other.ObjectSID = 'S-1-5-21-1-2-3-1002'
        $other.SamAccountName = 'user2'
        $other.UserPrincipalName = 'user2@old.example'
        $other.Mail = 'user2@old.example'
        $other.ProxyAddresses = @('SMTP:user2@old.example')
        $map = @{}
        $map[$user.ObjectGUID.ToString()] = @('SIP:shared@new.example')
        $map[$other.ObjectGUID.ToString()] = @('sip:SHARED@new.example')
        $plans = @(Get-NSPADUserAddressPlan -User @($user,$other) -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map)
        @($plans | Where-Object Blocked).Count | Should -Be 2
    }
    It 'refuses additions assigned to a skipped user' {
        $user = Get-ProxyAdditionUser
        $map = @{}; $map[$user.ObjectGUID.ToString()] = @('SIP:user1@new.example')
        { Get-NSPADUserAddressPlan -User $user -SkipIdentity $user.ObjectGUID -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map } | Should -Throw '*non-skipped*'
    }
    It 'rejects duplicate GUID keys written using distinct valid formats' {
        $user = Get-ProxyAdditionUser
        $map = @{}
        $map[$user.ObjectGUID.ToString('D')] = @('SIP:user1@new.example')
        $map[$user.ObjectGUID.ToString('B')] = @('smtp:alias@new.example')
        { Get-NSPADUserAddressPlan -User $user -OldDomain old.example -NewDomain new.example -AdditionalProxyAddresses $map } | Should -Throw '*Duplicate GUID*'
    }
}
