Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
}

Describe 'LDAP paging and lifetime (offline)' {
    InModuleScope NSP.ActiveDirectory {
        BeforeEach {
            $script:entryDisposed = $false
            $script:searcherDisposed = $false
            $script:resultsDisposed = $false
            $script:root = [pscustomobject]@{}
            $script:root | Add-Member ScriptMethod Dispose { $script:entryDisposed = $true }
            $script:results = [System.Collections.ArrayList]::new()
            Add-Member -InputObject $script:results -MemberType ScriptMethod -Name Dispose -Value { $script:resultsDisposed = $true }
            $script:searcher = [pscustomobject]@{
                PageSize = 0; SizeLimit = 0; ServerTimeLimit = [timespan]::Zero
                SearchScope = ''; ReferralChasing = ''; PropertiesToLoad = [System.Collections.ArrayList]::new()
            }
            $script:searcher | Add-Member ScriptMethod FindAll { ,$script:results }
            $script:searcher | Add-Member ScriptMethod Dispose { $script:searcherDisposed = $true }
            Mock New-NSPADLdapEntry { $script:root }
            Mock New-NSPADLdapSearcher { $script:searcher }
        }
        It 'pages by default while preserving scalar binary and multivalue semantics' {
            $bytes = [byte[]](0..15)
            $props = @{ objectguid = @(,$bytes); proxyaddresses = @('SMTP:one@contoso.example', 'smtp:two@contoso.example'); displayname = @('One') }
            $props | Add-Member NoteProperty PropertyNames @('objectguid', 'proxyaddresses', 'displayname')
            [void]$script:results.Add([pscustomobject]@{ Properties = $props })
            $r = @(Read-NSPADLdap -Server 'dc.contoso.example' -SearchBase 'DC=contoso,DC=example' -Property objectGUID,proxyAddresses,displayName -MultiValued proxyAddresses)
            $script:searcher.PageSize | Should -Be 500
            $script:searcher.ReferralChasing | Should -Be 'None'
            $r.Count | Should -Be 1
            , $r[0].objectguid | Should -BeOfType ([byte[]])
            [Convert]::ToBase64String($r[0].objectguid) | Should -Be ([Convert]::ToBase64String($bytes))
            $r[0].proxyaddresses.Count | Should -Be 2
            $r[0].displayname | Should -Be 'One'
            $script:entryDisposed | Should -BeTrue
            $script:searcherDisposed | Should -BeTrue
            $script:resultsDisposed | Should -BeTrue
        }
        It 'sets explicit page size, size limit, time limit and Base scope' {
            Read-NSPADLdap -Server 'dc.contoso.example' -SearchBase 'DC=contoso,DC=example' -Property tokenGroups -MultiValued tokenGroups -PageSize 200 -SizeLimit 25 -ServerTimeLimit ([timespan]::FromSeconds(9)) -Scope Base
            $script:searcher.PageSize | Should -Be 200
            $script:searcher.SizeLimit | Should -Be 25
            $script:searcher.ServerTimeLimit.TotalSeconds | Should -Be 9
            $script:searcher.SearchScope | Should -Be 'Base'
        }
        It 'returns more than the usual unpaged 1000-object ceiling without a client cap' {
            foreach ($i in 1..1205) {
                $props = @{ name = @("User$i") }
                $props | Add-Member NoteProperty PropertyNames @('name')
                [void]$script:results.Add([pscustomobject]@{ Properties = $props })
            }
            $items = @(Read-NSPADLdap -Server dc -SearchBase 'DC=contoso,DC=example' -Property name)
            $items.Count | Should -Be 1205
            $items[1204].name | Should -Be 'User1205'
            $script:searcher.PageSize | Should -Be 500
            $script:searcher.SizeLimit | Should -Be 0
        }
        It 'disposes the entry and searcher when FindAll fails' {
            $script:searcher | Add-Member ScriptMethod FindAll { throw 'offline search failure' } -Force
            { Read-NSPADLdap -Server 'dc.contoso.example' -SearchBase 'DC=contoso,DC=example' -Property name } | Should -Throw '*offline search failure*'
            $script:entryDisposed | Should -BeTrue
            $script:searcherDisposed | Should -BeTrue
        }
        It 'disposes the entry when searcher construction fails' {
            Mock New-NSPADLdapSearcher { throw 'offline construction failure' }
            { Read-NSPADLdap -Server 'dc.contoso.example' -SearchBase 'DC=contoso,DC=example' -Property name } | Should -Throw '*offline construction failure*'
            $script:entryDisposed | Should -BeTrue
        }
        It 'rejects unpaged and invalid limits before opening LDAP' {
            { Read-NSPADLdap -Server dc -SearchBase dc=x -Property name -PageSize 0 } | Should -Throw
            { Read-NSPADLdap -Server dc -SearchBase dc=x -Property name -SizeLimit -1 } | Should -Throw
            { Read-NSPADLdap -Server dc -SearchBase dc=x -Property name -ServerTimeLimit ([timespan]::FromSeconds(-1)) } | Should -Throw
            Should -Invoke New-NSPADLdapEntry -Times 0 -Exactly
        }
    }
}
