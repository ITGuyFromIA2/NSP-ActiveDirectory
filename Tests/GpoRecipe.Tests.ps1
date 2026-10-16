<#
    Pester 5. NSP.ActiveDirectory 0.1.7: GPO recipes (Get-/Import-NSPADGpoRecipe) and the Huntress
    recipe. No real AD, GPO or file share is touched: GPO/AD cmdlets are stubbed when RSAT is missing
    and mocked inside the module; share and ACL helpers run against TestDrive or are mocked.
#>

BeforeAll {
    $toolkits = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $bootstrap = @($env:NSP_ECOSYSTEM_ROOT, $toolkits, (Split-Path -Parent $toolkits)) | Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'NSP-Bootstrap\NSP.Bootstrap.psd1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $bootstrap) { throw 'NSP-Bootstrap checkout not found next to this repository (or set NSP_ECOSYSTEM_ROOT).' }
    Import-Module $bootstrap -Force -Global -ErrorAction Stop
    foreach ($m in 'NSP-Console\NSP.Console.psd1', 'NSP-Toolkit\NSP.Toolkit.psd1', 'NSP-ClientScripts\NSP.ClientScripts.psd1') {
        Import-Module (Join-Path $toolkits $m) -Force -Global -ErrorAction Stop
    }
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.ActiveDirectory.psd1') -Force -ErrorAction Stop

    $stubs = [ordered]@{
        'Get-ADDomain'      = 'param()'
        'Import-GPO'        = 'param($BackupId, $Path, $TargetName, [switch]$CreateIfNeeded)'
        'Get-GPO'           = 'param($Name)'
        'Get-GPInheritance' = 'param($Target)'
        'New-GPLink'        = 'param($Name, $Target, $LinkEnabled)'
    }
    $script:stubbed = @()
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) `$null"))
            $script:stubbed += $name
        }
    }
    $script:AccountKey = '0123456789abcdef' * 2
    function script:New-TestSecureString([string]$Text) {
        $s = New-Object Security.SecureString
        foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }
        return $s
    }
    function script:Get-Sid([Security.AccessControl.FileSystemSecurity]$Acl) {
        @($Acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
    }
}

AfterAll {
    foreach ($name in @($script:stubbed)) { if ($name) { Remove-Item -Path "function:\$name" -ErrorAction SilentlyContinue } }
    Remove-Module NSP.ActiveDirectory -Force -ErrorAction SilentlyContinue
}

Describe 'The Huntress recipe' {
    It 'is listed, with its GPO backup' {
        $r = Get-NSPADGpoRecipe -Name Huntress
        $r.GpoName | Should -Be 'NSP - Deploy Huntress'
        $r.Payload.ClientScriptRecipe | Should -Be 'HuntressInstaller'
        @($r.Prompts.Name) | Should -Be @('OrganizationKey', 'AccountKey')
        Test-Path -LiteralPath (Join-Path $r.BackupPath 'manifest.xml') | Should -BeTrue
    }

    It 'has a GPO backup with only the scheduled task, pointing at the script token' {
        $r = Get-NSPADGpoRecipe -Name Huntress
        $files = @(Get-ChildItem -LiteralPath $r.BackupPath -Recurse -Force -File)
        foreach ($f in $files | Where-Object Extension -eq '.xml') { { [xml](Get-Content -LiteralPath $f.FullName -Raw) } | Should -Not -Throw }
        $files.Name | Should -Not -Contain 'Files.xml'
        $task = Get-Content -LiteralPath ($files | Where-Object Name -eq 'ScheduledTasks.xml').FullName -Raw
        $task | Should -Match '-File &quot;__NSP_HUNTRESS_SCRIPT__&quot;'
        $task | Should -Match 'NT AUTHORITY\\System'
        foreach ($trigger in 'RegistrationTrigger', 'SessionStateChangeTrigger', 'BootTrigger', 'CalendarTrigger') { $task | Should -Match "<$trigger>" -Because 'servers nobody logs into retry at startup and daily' }
        $task | Should -Match '<WakeToRun>false</WakeToRun>'
        $backup = Get-Content -LiteralPath ($files | Where-Object Name -eq 'Backup.xml').FullName -Raw
        $backup | Should -Not -Match 'Preferences\\Files'
        $backup | Should -Not -Match '7150F9BF-48AD-4DA4-A49C-29EF4A8369BA' -Because 'the Files preference extension is gone'
        foreach ($f in $files) {
            Get-Content -LiteralPath $f.FullName -Raw | Should -Not -Match 'C:\\Admin' -Because "$($f.Name) should carry no old local paths"
        }
    }
}

Describe 'GPO recipe helpers' {
    It 'expands {Name} values and refuses an unknown one (pure)' {
        InModuleScope NSP.ActiveDirectory {
            Expand-NSPADGpoRecipeText -Text '{ShareRoot}\x.ps1' -Values @{ ShareRoot = '\\fs\s$' } | Should -Be '\\fs\s$\x.ps1'
            { Expand-NSPADGpoRecipeText -Text '{Nope}' -Values @{} } | Should -Throw '*{Nope}*'
        }
    }

    It 'sets up the share folder: Authenticated Users read, Users removed, report folders writable' {
        $root = Join-Path $TestDrive 'share\Huntress'
        New-Item -ItemType Directory -Path (Split-Path -Parent $root) -Force | Out-Null
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        InModuleScope NSP.ActiveDirectory -Parameters @{ Root = $root } { param($Root) Initialize-NSPADGpoRecipeShare -ShareRoot $Root -ReportFolders 'Status', 'Transcripts' }
        Test-Path -LiteralPath (Join-Path $root 'Status') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'Transcripts') | Should -BeTrue
        $acl = Get-Acl -LiteralPath $root
        $acl.AreAccessRulesProtected | Should -BeTrue
        Get-Sid $acl | Should -Contain 'S-1-5-11'
        Get-Sid $acl | Should -Not -Contain 'S-1-5-32-545'
        $write = @((Get-Acl -LiteralPath (Join-Path $root 'Status')).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
            Where-Object { $_.IdentityReference.Value -eq 'S-1-5-11' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData) })
        $write.Count | Should -Be 1
        # Re-running is harmless.
        { InModuleScope NSP.ActiveDirectory -Parameters @{ Root = $root } { param($Root) Initialize-NSPADGpoRecipeShare -ShareRoot $Root -ReportFolders 'Status' } } | Should -Not -Throw
    }

    It 'refuses a share folder whose parent does not exist' {
        $root = Join-Path $TestDrive 'missing\Huntress'
        { InModuleScope NSP.ActiveDirectory -Parameters @{ Root = $root } { param($Root) Initialize-NSPADGpoRecipeShare -ShareRoot $Root } } | Should -Throw '*not reachable*'
    }

    It 'writes the payload readable only by SYSTEM, admins, domain computers and DCs' {
        $path = Join-Path $TestDrive 'payload.ps1'
        InModuleScope NSP.ActiveDirectory -Parameters @{ P = $path } { param($P) Write-NSPADGpoRecipePayload -Path $P -Text 'secret script' -DomainSid 'S-1-5-21-1-2-3' }
        $acl = Get-Acl -LiteralPath $path
        try {
            $acl.AreAccessRulesProtected | Should -BeTrue
            @(Get-Sid $acl | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-21-1-2-3-512', 'S-1-5-21-1-2-3-515', 'S-1-5-21-1-2-3-516', 'S-1-5-32-544', 'S-1-5-9')
            Get-Content -LiteralPath $path -Raw | Should -Be 'secret script'
        } finally {
            # Hand the file back to the test account (an owner can always rewrite the DACL) so TestDrive cleans up.
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow')))
            Set-Acl -LiteralPath $path -AclObject $acl
        }
    }
}

Describe 'Import-NSPADGpoRecipe' {
    BeforeEach {
        $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
        Set-NSPDryRun -Enabled $true -Confirm:$false
        Mock -ModuleName NSP.ActiveDirectory Write-Host { }
        Mock -ModuleName NSP.ActiveDirectory Read-Host { throw 'Read-Host should not be called' }
        Mock -ModuleName NSP.ActiveDirectory Import-NSPToolkitModule { }
        Mock -ModuleName NSP.ActiveDirectory Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'dc01.fabrikam.local'; DNSRoot = 'fabrikam.local'; NetBIOSName = 'FABRIKAM'; DistinguishedName = 'DC=fabrikam,DC=local'; DomainSID = 'S-1-5-21-7-8-9' } }
        Mock -ModuleName NSP.ActiveDirectory Initialize-NSPADGpoRecipeShare { }
        $script:payload = $null
        Mock -ModuleName NSP.ActiveDirectory Write-NSPADGpoRecipePayload { $script:payload = @{ Path = $Path; Text = $Text; DomainSid = $DomainSid } }
        $script:task = $null
        Mock -ModuleName NSP.ActiveDirectory Import-GPO {
            $script:task = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Path -Recurse -Filter 'ScheduledTasks.xml').FullName -Raw
            $script:importTarget = $TargetName
        }
        Mock -ModuleName NSP.ActiveDirectory Get-GPO { [pscustomobject]@{ DisplayName = $Name } }
        # Links exist only once New-GPLink really ran - the recipe reads them back.
        $script:links = [Collections.Generic.List[object]]::new()
        Mock -ModuleName NSP.ActiveDirectory Get-GPInheritance { [pscustomobject]@{ GpoLinks = @($script:links | Where-Object Target -eq $Target) } }
        Mock -ModuleName NSP.ActiveDirectory New-GPLink { $script:links.Add([pscustomobject]@{ DisplayName = $Name; Target = $Target }) }
        $script:values = @{ OrganizationKey = 'Fabrikam'; AccountKey = (New-TestSecureString $AccountKey) }
    }
    AfterEach { Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue }

    It 'deploys: share, locked-down script, GPO pointing at it, linked at the domain root' {
        $r = Import-NSPADGpoRecipe -Recipe Huntress -Action Deploy -Scope All -FileShareRoot '\\fileserver\GPO_Share$\Huntress\' -Values $values -Confirm:$false
        Should -Invoke -ModuleName NSP.ActiveDirectory Initialize-NSPADGpoRecipeShare -Times 1 -ParameterFilter { $ShareRoot -eq '\\fileserver\GPO_Share$\Huntress' -and ($ReportFolders -join ',') -eq 'Status,Transcripts' }
        $payload.Path | Should -Be '\\fileserver\GPO_Share$\Huntress\HuntressInstall.ps1'
        $payload.DomainSid | Should -Be 'S-1-5-21-7-8-9'
        $payload.Text | Should -Match ([regex]::Escape("`$ReportDirectory       = '\\fileserver\GPO_Share`$\Huntress'"))
        $payload.Text | Should -Match ([regex]::Escape("[string]`$OrganizationKey = 'Fabrikam'"))
        $payload.Text | Should -Match $AccountKey
        $task | Should -Match ([regex]::Escape('-File &quot;\\fileserver\GPO_Share$\Huntress\HuntressInstall.ps1&quot;'))
        $importTarget | Should -Be 'NSP - Deploy Huntress'
        Should -Invoke -ModuleName NSP.ActiveDirectory New-GPLink -Times 1 -ParameterFilter { $Name -eq 'NSP - Deploy Huntress' -and $Target -eq 'DC=fabrikam,DC=local' }
        $r.Linked | Should -BeTrue
        $r.PayloadPath | Should -Be '\\fileserver\GPO_Share$\Huntress\HuntressInstall.ps1'
        Get-NSPDryRun | Should -BeTrue -Because "the caller's dry-run setting comes back"
    }

    It 'does not trust a Linked flag the link never backed (the dry-run link bug)' {
        Mock -ModuleName NSP.ActiveDirectory Import-NSPADGpoBackup { [pscustomobject]@{ GpoName = $TargetName; Linked = $true } }
        { Import-NSPADGpoRecipe -Recipe Huntress -FileShareRoot '\\fileserver\s$\Huntress' -Values $values -Confirm:$false } | Should -Throw '*not linked*New-NSPADGpoLink*'
    }

    It 'goes by the link in AD, whatever Import-NSPADGpoBackup reports (still right once that bug is fixed)' {
        Mock -ModuleName NSP.ActiveDirectory Import-NSPADGpoBackup {
            $script:links.Add([pscustomobject]@{ DisplayName = $TargetName; Target = 'DC=fabrikam,DC=local' })
            [pscustomobject]@{ GpoName = $TargetName; Linked = $false }
        }
        (Import-NSPADGpoRecipe -Recipe Huntress -FileShareRoot '\\fileserver\s$\Huntress' -Values $values -Confirm:$false).Linked | Should -BeTrue
    }

    It 'asks for the share folder and any value not passed' {
        Mock -ModuleName NSP.ActiveDirectory Read-NSPADGpoRecipeValue {
            if ($Prompt -like 'Deployment folder*') { '\\fileserver\GPO$\Huntress' } elseif ($Secret) { $AccountKey } else { 'Asked Org' }
        }
        Import-NSPADGpoRecipe -Recipe Huntress -Confirm:$false | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADGpoRecipeValue -Times 3
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPADGpoRecipeValue -Times 1 -ParameterFilter { $Secret -and $Prompt -like '*account key*' }
        $payload.Text | Should -Match "'Asked Org'"
    }

    It 'checks every value before changing anything' {
        { Import-NSPADGpoRecipe -Recipe Huntress -FileShareRoot 'C:\Local\Huntress' -Values $values -Confirm:$false } | Should -Throw '*UNC*'
        { Import-NSPADGpoRecipe -Recipe Huntress -FileShareRoot '\\fileserver\s$\Huntress' -Values @{ OrganizationKey = 'F'; AccountKey = 'short' } -Confirm:$false } | Should -Throw '*AccountKey*'
        { Import-NSPADGpoRecipe -Recipe Huntress -FileShareRoot '\\fileserver\s$\Huntress' -Values @{ Typo = 1 } -Confirm:$false } | Should -Throw "*no value 'Typo'*"
        { Import-NSPADGpoRecipe -Recipe Nope -Confirm:$false } | Should -Throw '*Recipes: *Huntress*'
        Should -Invoke -ModuleName NSP.ActiveDirectory Initialize-NSPADGpoRecipeShare -Times 0
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0
    }

    It 'the dashboard entry previews with -WhatIf in DRY RUN and deploys in APPLY, remembering the share' -TestCases @(
        @{ Dry = $true }
        @{ Dry = $false }
    ) {
        Set-NSPDryRun -Enabled $Dry -Confirm:$false
        Mock -ModuleName NSP.ActiveDirectory Write-NSPADScreen { }
        Mock -ModuleName NSP.ActiveDirectory Write-NSPConsoleLine { }
        Mock -ModuleName NSP.ActiveDirectory Wait-NSPADReturn { }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPMenu { 'Huntress' }
        Mock -ModuleName NSP.ActiveDirectory Read-NSPNonEmpty { if ($Prompt -like 'Deployment folder*') { '\\fileserver\GPO_Share$\Huntress\' } else { 'Fabrikam' } }
        Mock -ModuleName NSP.ActiveDirectory Import-NSPADGpoRecipe { }
        $saved = InModuleScope NSP.ActiveDirectory {
            $script:ADAnswers = $null
            Invoke-NSPADMenuGpoRecipe
            $script:ADAnswers
        }
        $saved.GpoRecipe_Huntress_ShareRoot | Should -Be '\\fileserver\GPO_Share$\Huntress'
        $saved.GpoRecipe_Huntress_OrganizationKey | Should -Be 'Fabrikam'
        @($saved.PSObject.Properties.Name) | Should -Not -Contain 'GpoRecipe_Huntress_AccountKey' -Because 'the account key is never saved'
        Should -Invoke -ModuleName NSP.ActiveDirectory Read-NSPNonEmpty -Times 0 -ParameterFilter { $Prompt -like '*account key*' }
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-NSPADGpoRecipe -Times 1 -ParameterFilter {
            $Recipe -eq 'Huntress' -and $FileShareRoot -eq '\\fileserver\GPO_Share$\Huntress' -and [bool]$WhatIf -eq $Dry -and
                $Values.OrganizationKey -eq 'Fabrikam' -and -not $Values.ContainsKey('AccountKey')
        }
    }

    It '-WhatIf changes nothing' {
        Import-NSPADGpoRecipe -Recipe Huntress -FileShareRoot '\\fileserver\s$\Huntress' -Values $values -WhatIf | Out-Null
        Should -Invoke -ModuleName NSP.ActiveDirectory Initialize-NSPADGpoRecipeShare -Times 0
        Should -Invoke -ModuleName NSP.ActiveDirectory Write-NSPADGpoRecipePayload -Times 0
        Should -Invoke -ModuleName NSP.ActiveDirectory Import-GPO -Times 0
    }
}
