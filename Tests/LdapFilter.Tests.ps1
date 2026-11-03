Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force
}
Describe 'RFC 4515 assertion values' {
    InModuleScope NSP.ActiveDirectory {
        It 'escapes literal special characters including NUL in the correct order' {
            ConvertTo-NSPADLdapFilterValue -Value ("a\*(b)`0") | Should -Be 'a\5c\2a\28b\29\00'
        }
        It 'preserves only intentionally requested asterisk wildcards' {
            ConvertTo-NSPADLdapFilterValue -Value '*a\(b)*' -AllowWildcard | Should -Be '*a\5c\28b\29*'
        }
        It 'treats a supplied escape sequence as literal data' {
            ConvertTo-NSPADLdapFilterValue -Value '\2a' -AllowWildcard | Should -Be '\5c2a'
        }
        It 'keeps Unicode and ordinary characters unchanged' {
            ConvertTo-NSPADLdapFilterValue -Value 'Zoë? [Example]' | Should -Be 'Zoë? [Example]'
        }
        It 'allows an empty assertion value' {
            ConvertTo-NSPADLdapFilterValue -Value '' | Should -Be ''
        }
    }
}
