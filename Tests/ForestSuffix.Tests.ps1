BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
    function New-ForestFixture {
        [pscustomobject]@{
            PSTypeName='NSP.ActiveDirectory.ForestInfo'; ForestDNSRoot='old.example'
            RootDomainDN='DC=old,DC=example'; ConfigurationDN='CN=Configuration,DC=old,DC=example'
            ConfigurationGUID=[guid]'11111111-2222-3333-4444-555555555555'; Server='dc01.old.example'
            DomainDNSRoots=[string[]]@('old.example','child.old.example')
            AlternateUPNSuffixes=[string[]]@('existing.example')
            AvailableUPNSuffixes=[string[]]@('old.example','child.old.example','existing.example')
        }
    }
}

Describe 'Forest facts over LDAP (offline)' {
    BeforeEach {
        Mock -ModuleName NSP.ActiveDirectory Find-NSPADDomainController { 'dc01.old.example' }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADRootDse {
            @{rootdomainnamingcontext='DC=old,DC=example'; configurationnamingcontext='CN=Configuration,DC=old,DC=example'}
        }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestDomainInfo {
            [pscustomobject]@{DNSRoot='old.example'; DistinguishedName='DC=old,DC=example'; ConfigurationDN='CN=Configuration,DC=old,DC=example'}
            [pscustomobject]@{DNSRoot='child.old.example'; DistinguishedName='DC=child,DC=old,DC=example'; ConfigurationDN='CN=Configuration,DC=old,DC=example'}
        }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap {
            if ($SearchBase -like 'CN=Partitions,*') { @{upnsuffixes=@('existing.example','EXISTING.EXAMPLE')} }
            else { @{objectguid=([guid]'11111111-2222-3333-4444-555555555555').ToByteArray()} }
        }
    }
    It 'returns root/child domain suffixes separately from configured alternates' {
        $f = Get-NSPADForestInfo -Server dc01.old.example
        $f.PSObject.TypeNames[0] | Should -Be 'NSP.ActiveDirectory.ForestInfo'
        $f.ForestDNSRoot | Should -Be 'old.example'
        $f.ConfigurationGUID | Should -Be ([guid]'11111111-2222-3333-4444-555555555555')
        $f.DomainDNSRoots.Count | Should -Be 2
        $f.AlternateUPNSuffixes.Count | Should -Be 1
        $f.AvailableUPNSuffixes.Count | Should -Be 3
        ,$f.AlternateUPNSuffixes | Should -BeOfType ([string[]])
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 1 -Exactly -ParameterFilter {
            $Scope -eq 'Base' -and $SearchBase -like 'CN=Partitions,*' -and $MultiValued -contains 'uPNSuffixes'
        }
    }
    It 'keeps an absent alternate list as an empty typed array' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $SearchBase -like 'CN=Partitions,*' } { @{} }
        $f = Get-NSPADForestInfo -Server dc01.old.example
        ,$f.AlternateUPNSuffixes | Should -BeOfType ([string[]])
        $f.AlternateUPNSuffixes.Count | Should -Be 0
        $f.AvailableUPNSuffixes.Count | Should -Be 2
    }
    It 'terminates on unreadable forest objects' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { throw 'Fake access denied' }
        { Get-NSPADForestInfo -Server dc01.old.example } | Should -Throw
    }
    It 'rejects inconsistent domain forest identity' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestDomainInfo {
            [pscustomobject]@{DNSRoot='old.example';DistinguishedName='DC=old,DC=example';ConfigurationDN='CN=Configuration,DC=other,DC=example'}
        }
        { Get-NSPADForestInfo -Server dc01.old.example } | Should -Throw
    }
    It 'rejects missing root facts or configuration GUID' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADRootDse { @{} }
        { Get-NSPADForestInfo -Server dc01.old.example } | Should -Throw
    }
}

Describe 'Forest UPN suffix planning and application (offline)' {
    BeforeAll {
        & (Get-Module NSP.ActiveDirectory) {
            function script:Set-ADForest { param($Identity,$Server,$UPNSuffixes,$ErrorAction) }
        }
    }
    BeforeEach {
        $script:forest = New-ForestFixture
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo { $script:forest }
        Mock -ModuleName NSP.ActiveDirectory Assert-NSPADCommand {}
        Mock -ModuleName NSP.ActiveDirectory Set-ADForest {
            $script:forest.AlternateUPNSuffixes += [string]$UPNSuffixes.Add
            $script:forest.AvailableUPNSuffixes += [string]$UPNSuffixes.Add
        }
    }
    It 'plans exactly one additive suffix without changing the input' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix NEW.example
        $p.PSObject.TypeNames[0] | Should -Be 'NSP.ActiveDirectory.ForestUPNSuffixPlan'
        $p.Suffix | Should -Be 'new.example'
        $p.Changed | Should -BeTrue
        $p.Before | Should -Be @('existing.example')
        $p.After | Should -Contain 'new.example'
        $script:forest.AlternateUPNSuffixes.Count | Should -Be 1
    }
    It 'treats <Suffix> as already available' -ForEach @(
        @{Suffix='OLD.EXAMPLE'}, @{Suffix='child.old.example'}, @{Suffix='Existing.Example'}
    ) {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix $Suffix
        $p.Changed | Should -BeFalse
        (Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false).Result | Should -Be 'AlreadyAvailable'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 0 -Exactly
    }
    It 'rejects @, wildcard and LDAP syntax in a suffix' {
        foreach ($suffix in '@new.example','*.example','new.example)(x=*)') {
            { Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix $suffix } | Should -Throw
        }
    }
    It 'requires stable forest identity in the supplied facts' {
        $script:forest.ConfigurationGUID = [guid]::Empty
        { Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example } | Should -Throw
    }
    It 'previews with no directory read or write by default or Apply WhatIf' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        (Add-NSPADForestUPNSuffix -Plan $p).Result | Should -Be 'Preview'
        Add-NSPADForestUPNSuffix -Plan $p -Apply -WhatIf
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo -Times 0 -Exactly
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 0 -Exactly
    }
    It 'adds only the selected suffix by forest identity on the pinned server, then verifies' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        (Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false).Result | Should -Be 'Verified'
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'old.example' -and $Server -eq 'dc01.old.example' -and
            $UPNSuffixes.Count -eq 1 -and $UPNSuffixes.Add -eq 'new.example'
        }
        $script:forest.AlternateUPNSuffixes | Should -Contain 'existing.example'
    }
    It 'refuses a recreated forest with the same DNS name' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        $script:forest.ConfigurationGUID = [guid]::NewGuid()
        { Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 0 -Exactly
    }
    It 'refuses stale before state or altered proposed state' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        $p.After += 'unreviewed.example'
        { Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 0 -Exactly
    }
    It 'refuses concurrent configuration edits before the write' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        $script:forest.AlternateUPNSuffixes += 'concurrent.example'
        { Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 0 -Exactly
    }
    It 'reports an unverified write without claiming success' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        Mock -ModuleName NSP.ActiveDirectory Set-ADForest { throw 'Fake write failure' }
        (Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false).Result | Should -Be 'WriteUnverified'
    }
    It 'reports absent readback as verification failure' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        Mock -ModuleName NSP.ActiveDirectory Set-ADForest {}
        (Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false).Result | Should -Be 'VerificationFailed'
    }
    It 'does not claim verification if previous suffixes disappeared' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        Mock -ModuleName NSP.ActiveDirectory Set-ADForest {
            $script:forest.AlternateUPNSuffixes = @('new.example')
            $script:forest.AvailableUPNSuffixes = @('old.example','child.old.example','new.example')
        }
        (Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false).Result | Should -Be 'VerificationFailed'
    }
    It 'rejects an edit between preflight and the immediate pre-write read' {
        $p = Get-NSPADForestUPNSuffixPlan -ForestInfo $script:forest -Suffix new.example
        $script:reads=0
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADForestInfo {
            $script:reads++
            if ($script:reads -gt 1) { $script:forest.AlternateUPNSuffixes += 'late.example' }
            $script:forest
        }
        { Add-NSPADForestUPNSuffix -Plan $p -Apply -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName NSP.ActiveDirectory Set-ADForest -Times 0 -Exactly
    }
}
