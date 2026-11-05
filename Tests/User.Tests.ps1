BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
}

Describe 'Get-NSPADUser domain queries (offline)' {
    BeforeAll {
        $script:domain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'contoso.example'; DistinguishedName = 'DC=contoso,DC=example'; Server = 'dc01.contoso.example'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example' }
        $script:guid = [guid]'00112233-4455-6677-8899-aabbccddeeff'
        $sid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1105')
        $script:sidBytes = [byte[]]::new($sid.BinaryLength)
        $sid.GetBinaryForm($script:sidBytes, 0)
    }
    BeforeEach {
        $script:user = @{
            distinguishedname = 'CN=One,OU=People,DC=contoso,DC=example'; samaccountname = 'one'
            userprincipalname = 'one@contoso.example'; displayname = 'One Example'; givenname = 'One'
            sn = 'Example'; mail = 'one@contoso.example'; proxyaddresses = @('SMTP:one@contoso.example', 'smtp:alias@contoso.example')
            objectguid = $script:guid.ToByteArray(); 'ms-ds-consistencyguid' = [byte[]](15..0)
            objectsid = $script:sidBytes; useraccountcontrol = 512
        }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo { $script:domain }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { $script:user }
    }
    It 'exports the reader and returns exactly the typed contract' {
        $u = Get-NSPADUser -Identity one -DomainInfo $script:domain
        $u.PSObject.TypeNames[0] | Should -Be 'NSP.ActiveDirectory.User'
        @($u.PSObject.Properties.Name | Sort-Object) | Should -Be @('DistinguishedName','SamAccountName','UserPrincipalName','DisplayName','GivenName','Surname','Mail','ProxyAddresses','ObjectGUID','ConsistencyGuidBytes','ObjectSID','Enabled','DomainDNSRoot','Server','PasswordLastSetUtc','PasswordLastSetState','PasswordMustChangeAtNextLogon','MsExchRecipientTypeDetails' | Sort-Object)
        $u.ObjectGUID | Should -BeOfType ([guid])
        $u.ObjectGUID | Should -Be $script:guid
        , $u.ConsistencyGuidBytes | Should -BeOfType ([byte[]])
        [Convert]::ToBase64String($u.ConsistencyGuidBytes) | Should -Be ([Convert]::ToBase64String([byte[]](15..0)))
        $u.ObjectSID | Should -BeOfType ([string])
        $u.ObjectSID | Should -Be 'S-1-5-21-1-2-3-1105'
        $u.Enabled | Should -BeOfType ([bool])
        $u.Enabled | Should -BeTrue
        , $u.ProxyAddresses | Should -BeOfType ([string[]])
        $u.ProxyAddresses.Count | Should -Be 2
        $u.DomainDNSRoot | Should -Be 'contoso.example'
        $u.Server | Should -Be 'dc01.contoso.example'
        $u.Surname | Should -Be 'Example'
        $u.DisplayName | Should -Be 'One Example'
        $u.GivenName | Should -Be 'One'
        $u.Mail | Should -Be 'one@contoso.example'
        $u.UserPrincipalName | Should -Be 'one@contoso.example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -Times 0 -Exactly
    }
    It 'uses an exact escaped identity assertion, including a literal asterisk and NUL' {
        Get-NSPADUser -Identity ("a*)(|(x=*))\`0") -DomainInfo $script:domain
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 1 -Exactly -ParameterFilter {
            $Filter -eq '(&(objectCategory=person)(objectClass=user)(sAMAccountName=a\2a\29\28|\28x=\2a\29\29\5c\00))' -and $PageSize -gt 0
        }
    }
    It 'always exposes the optional fields and keeps absent values unknown' {
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        $u.PasswordLastSetState | Should -Be 'Unknown'
        ($null -eq $u.PasswordLastSetUtc) | Should -BeTrue
        ($null -eq $u.PasswordMustChangeAtNextLogon) | Should -BeTrue
        ($null -eq $u.MsExchRecipientTypeDetails) | Should -BeTrue
        @($u.PSObject.Properties.Name) | Should -Contain 'PasswordLastSetUtc'
        @($u.PSObject.Properties.Name) | Should -Contain 'MsExchRecipientTypeDetails'
    }
    It 'converts a positive FILETIME to the exact UTC instant' {
        $instant = [datetime]::SpecifyKind([datetime]'2026-01-02T03:04:05', [DateTimeKind]::Utc)
        $script:user.pwdlastset = $instant.ToFileTimeUtc()
        $u = Get-NSPADUser -Identity one -DomainInfo $script:domain
        $u.PasswordLastSetUtc | Should -BeOfType ([datetime])
        $u.PasswordLastSetUtc.Ticks | Should -Be $instant.Ticks
        $u.PasswordLastSetUtc.Kind | Should -Be ([DateTimeKind]::Utc)
        $u.PasswordLastSetState | Should -Be 'Known'
        $u.PasswordMustChangeAtNextLogon | Should -BeOfType ([bool])
        $u.PasswordMustChangeAtNextLogon | Should -BeFalse
    }
    It 'handles pwdLastSet zero with never-expires flag <NeverExpires>' -ForEach @(
        @{NeverExpires=$false; Uac=512; Expected=$true},
        @{NeverExpires=$true; Uac=66048; Expected=$false}
    ) {
        $script:user.pwdlastset = [long]0
        $script:user.useraccountcontrol = $Uac
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        $u.PasswordLastSetState | Should -Be 'Zero'
        ($null -eq $u.PasswordLastSetUtc) | Should -BeTrue
        $u.PasswordMustChangeAtNextLogon | Should -BeOfType ([bool])
        $u.PasswordMustChangeAtNextLogon | Should -Be $Expected
    }
    It 'keeps invalid password metadata unknown: <Label>' -ForEach @(
        @{Label='null'; Value=$null}, @{Label='blank'; Value=''}, @{Label='negative'; Value=[long]-1},
        @{Label='out-of-range FILETIME'; Value=[long]::MaxValue}, @{Label='overflow'; Value='9223372036854775808'},
        @{Label='not numeric'; Value='unknown'}, @{Label='fraction'; Value='1.5'}, @{Label='boolean'; Value=$false}
    ) {
        $script:user.pwdlastset = $Value
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        $u.PasswordLastSetState | Should -Be 'Unknown'
        ($null -eq $u.PasswordLastSetUtc) | Should -BeTrue
        ($null -eq $u.PasswordMustChangeAtNextLogon) | Should -BeTrue
    }
    It 'preserves recipient Int64 values including zero and large flags: <Value>' -ForEach @(
        @{Value=[long]0}, @{Value=[long]2}, @{Value=[long]34359738368}, @{Value=[long]::MaxValue}, @{Value='34359738368'}
    ) {
        $script:user.msexchrecipienttypedetails = $Value
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        $u.MsExchRecipientTypeDetails | Should -BeOfType ([long])
        $u.MsExchRecipientTypeDetails | Should -Be ([long]$Value)
    }
    It 'keeps malformed recipient metadata null: <Label>' -ForEach @(
        @{Label='null'; Value=$null}, @{Label='empty'; Value=''}, @{Label='bad text'; Value='unknown'},
        @{Label='overflow'; Value='9223372036854775808'}, @{Label='fraction'; Value=1.5}, @{Label='boolean'; Value=$true}
    ) {
        $script:user.msexchrecipienttypedetails = $Value
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        ($null -eq $u.MsExchRecipientTypeDetails) | Should -BeTrue
    }
    It 'requests optional LDAP metadata for every domain query mode' {
        Get-NSPADUser -Identity one -DomainInfo $script:domain
        Get-NSPADUser -Filter '*one*' -DomainInfo $script:domain
        Get-NSPADUser -All -DomainInfo $script:domain
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 3 -Exactly -ParameterFilter {
            $Property -contains 'pwdLastSet' -and $Property -contains 'msExchRecipientTypeDetails'
        }
    }
    It 'searches all five attributes with intentional wildcard positions, escaping injection' {
        Get-NSPADUser -Filter '*one*)(mail=*)' -DomainInfo $script:domain
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter {
            $Filter -eq '(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=*one*\29\28mail=*\29)(userPrincipalName=*one*\29\28mail=*\29)(displayName=*one*\29\28mail=*\29)(mail=*one*\29\28mail=*\29)(proxyAddresses=*one*\29\28mail=*\29)))'
        }
    }
    It 'enumerates all users with paging and the required binary/multi-valued attributes' {
        Get-NSPADUser -All -DomainInfo $script:domain -PageSize 250 -SearchBase 'OU=People,DC=contoso,DC=example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 1 -Exactly -ParameterFilter {
            $Filter -eq '(&(objectCategory=person)(objectClass=user))' -and $PageSize -eq 250 -and
            $SearchBase -eq 'OU=People,DC=contoso,DC=example' -and $Server -eq 'dc01.contoso.example' -and
            $MultiValued -contains 'proxyAddresses' -and $Property -contains 'objectGUID' -and $Property -contains 'mS-DS-ConsistencyGuid'
        }
    }
    It 'returns arrays for a single proxy or no proxies and null for missing anchor bytes' {
        $script:user.proxyaddresses = @('SMTP:one@contoso.example')
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        , $u.ProxyAddresses | Should -BeOfType ([string[]])
        $u.ProxyAddresses.Count | Should -Be 1
        $script:user.Remove('proxyaddresses')
        $script:user.Remove('ms-ds-consistencyguid')
        $script:user.useraccountcontrol = 514
        $u = Get-NSPADUser -All -DomainInfo $script:domain
        , $u.ProxyAddresses | Should -BeOfType ([string[]])
        $u.ProxyAddresses.Count | Should -Be 0
        ($null -eq $u.ConsistencyGuidBytes) | Should -BeTrue
        $u.Enabled | Should -BeFalse
    }
    It 'returns every candidate for a broad filter and none when not found' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { $script:user; $script:user }
        @(Get-NSPADUser -Filter '*one*' -DomainInfo $script:domain).Count | Should -Be 2
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }
        @(Get-NSPADUser -Identity missing -DomainInfo $script:domain).Count | Should -Be 0
    }
    It 'refuses duplicate exact identities within a domain' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { $script:user; $script:user }
        { Get-NSPADUser -Identity one -DomainInfo $script:domain } | Should -Throw '*multiple*'
    }
    It 'discovers the selected server and validates it against supplied domain information' {
        $u = Get-NSPADUser -All -Server 'dc01.contoso.example'
        $u.DomainDNSRoot | Should -Be 'contoso.example'
        Should -Invoke -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -ParameterFilter { $Server -eq 'dc01.contoso.example' }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo { [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'other.example'; DistinguishedName = 'DC=other,DC=example'; Server = 'dc.other.example' } }
        { Get-NSPADUser -All -Server 'dc.other.example' -DomainInfo $script:domain } | Should -Throw '*domain*'
    }
    It 'refuses search bases outside the chosen domain and incomplete domain objects' {
        { Get-NSPADUser -All -DomainInfo $script:domain -SearchBase 'DC=other,DC=example' } | Should -Throw '*SearchBase*'
        $bad = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; Server = 'dc.contoso.example' }
        { Get-NSPADUser -All -DomainInfo $bad } | Should -Throw '*DomainInfo*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 0 -Exactly
    }
    It 'fails when stable identity or account status attributes are missing' -ForEach @('objectguid','objectsid','useraccountcontrol','distinguishedname') {
        $script:user.Remove($_)
        { Get-NSPADUser -All -DomainInfo $script:domain } | Should -Throw
    }
    It 'propagates LDAP errors instead of representing failure as an empty inventory' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { throw 'offline denied' }
        { Get-NSPADUser -All -DomainInfo $script:domain } | Should -Throw '*offline denied*'
    }
    It 'requires exactly one query mode and rejects false All and Forest switches' {
        { Get-NSPADUser -Identity one -All -DomainInfo $script:domain } | Should -Throw
        { Get-NSPADUser -All:$false -DomainInfo $script:domain } | Should -Throw
        { Get-NSPADUser -All -Forest:$false -Server dc } | Should -Throw
        { Get-NSPADUser -All -PageSize 0 -DomainInfo $script:domain } | Should -Throw
    }
}

Describe 'Get-NSPADUser explicit forest scope (offline)' {
    BeforeAll {
        $script:forestDomain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'contoso.example'; DistinguishedName = 'DC=contoso,DC=example'; Server = 'dc01.contoso.example'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example' }
        $script:childDomain = [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'child.contoso.example'; DistinguishedName = 'DC=child,DC=contoso,DC=example'; Server = 'dc01.child.contoso.example'; ConfigurationDN = 'CN=Configuration,DC=contoso,DC=example' }
        $sid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1105')
        $script:forestSidBytes = [byte[]]::new($sid.BinaryLength); $sid.GetBinaryForm($script:forestSidBytes, 0)
    }
    BeforeEach {
        Mock -ModuleName NSP.ActiveDirectory Find-NSPADDomainController { "dc01.$DomainName" }
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo {
            if ($Server -eq 'dc01.child.contoso.example') { $script:childDomain } else { $script:forestDomain }
        }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap {
            if ($SearchBase -like 'CN=Partitions,*') {
                @{ ncname = 'DC=contoso,DC=example'; dnsroot = 'contoso.example' }
                @{ ncname = 'DC=child,DC=contoso,DC=example'; dnsroot = 'child.contoso.example' }
            } else {
                @{ distinguishedname = "CN=One,$SearchBase"; samaccountname = 'one'; objectguid = ([guid]::NewGuid()).ToByteArray(); objectsid = $script:forestSidBytes; useraccountcontrol = 512 }
            }
        }
    }
    It 'enumerates domain crossRefs and reads each domain using its own DC and provenance' {
        $users = @(Get-NSPADUser -All -Forest -Server 'dc01.contoso.example' -PageSize 100)
        $users.Count | Should -Be 2
        $users.DomainDNSRoot | Should -Be @('contoso.example','child.contoso.example')
        $users.Server | Should -Be @('dc01.contoso.example','dc01.child.contoso.example')
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 1 -Exactly -ParameterFilter {
            $SearchBase -eq 'CN=Partitions,CN=Configuration,DC=contoso,DC=example' -and
            $Filter -eq '(&(objectClass=crossRef)(systemFlags:1.2.840.113556.1.4.803:=3)(!(enabled=FALSE)))' -and $PageSize -eq 100
        }
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 1 -Exactly -ParameterFilter { $SearchBase -eq 'DC=child,DC=contoso,DC=example' -and $Server -eq 'dc01.child.contoso.example' -and $PageSize -eq 100 }
    }
    It 'supports exact identity and wildcard filter in the forest parameter sets' {
        @(Get-NSPADUser -Identity one -Forest -Server dc).Count | Should -Be 2
        @(Get-NSPADUser -Filter '*one*' -Forest -Server dc).Count | Should -Be 2
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADLdap -Times 4 -Exactly -ParameterFilter {
            $SearchBase -notlike 'CN=Partitions,*' -and $Property -contains 'pwdLastSet' -and $Property -contains 'msExchRecipientTypeDetails'
        }
    }
    It 'cannot combine forest search with a single domain or OU scope' {
        { Get-NSPADUser -All -Forest -Server dc -DomainInfo $script:forestDomain } | Should -Throw
        { Get-NSPADUser -All -Forest -Server dc -SearchBase 'DC=contoso,DC=example' } | Should -Throw
    }
    It 'fails when no domain crossRefs are visible' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*domain*'
    }
    It 'refuses discovery that resolves a different domain or forest configuration' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -ParameterFilter { $Server -eq 'dc01.child.contoso.example' } { $script:forestDomain }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*domain*'
    }
    It 'stops on domain failure rather than silently omitting it' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap -ParameterFilter { $Server -eq 'dc01.child.contoso.example' } { throw 'offline domain unavailable' }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*offline domain unavailable*'
    }
    It 'uses the domain DC locator for every forest domain' {
        Get-NSPADUser -All -Forest -Server dc
        Should -Invoke -ModuleName NSP.ActiveDirectory Find-NSPADDomainController -Times 1 -Exactly -ParameterFilter { $DomainName -eq 'child.contoso.example' }
        Should -Invoke -ModuleName NSP.ActiveDirectory Find-NSPADDomainController -Times 1 -Exactly -ParameterFilter { $DomainName -eq 'contoso.example' }
    }
    It 'refuses a domain with a different forest ConfigurationDN' {
        Mock -ModuleName NSP.ActiveDirectory Get-NSPADDomainInfo -ParameterFilter { $Server -eq 'dc01.child.contoso.example' } {
            [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.DomainInfo'; DNSRoot = 'child.contoso.example'; DistinguishedName = 'DC=child,DC=contoso,DC=example'; Server = 'dc01.child.contoso.example'; ConfigurationDN = 'CN=Configuration,DC=other,DC=example' }
        }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*forest*'
    }
    It 'rejects missing, duplicate or incomplete domain references' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { @{ ncname = 'DC=contoso,DC=example' } }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*missing*'
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { @{ ncname = 'DC=contoso,DC=example'; dnsroot = 'contoso.example' }; @{ ncname = 'DC=contoso,DC=example'; dnsroot = 'contoso.example' } }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*Multiple*'
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADLdap { @{ ncname = 'DC=child,DC=contoso,DC=example'; dnsroot = 'child.contoso.example' } }
        { Get-NSPADUser -All -Forest -Server dc } | Should -Throw '*seed domain*'
    }
}
