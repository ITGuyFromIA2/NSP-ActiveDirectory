<#
    GPO recipe helpers (Import-NSPADGpoRecipe). A recipe is GpoRecipes\<Name>\Recipe.psd1 plus a
    portable GPO backup; the share layout and permissions follow the FortiClient Kickstart:
        <ShareRoot>                 Authenticated Users read (inheritance broken, Users removed)
        <ShareRoot>\<ReportFolder>  + Authenticated Users create/write files - computers report here
        <ShareRoot>\<Payload>       SYSTEM, administrators, domain computers/DCs only (it holds secrets)
#>

$script:NSPADUncPattern = '^\\\\[^\\/:*?"<>|\r\n]+\\[^"<>|\r\n]+$'

function Expand-NSPADGpoRecipeText {
    # PURE. Replaces {Name} with $Values[Name]; an unknown name throws (a recipe typo, not input).
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][Collections.IDictionary]$Values)
    return [regex]::Replace($Text, '\{([A-Za-z][A-Za-z0-9_]*)\}', {
        param($m)
        $key = $m.Groups[1].Value
        if (-not $Values.Contains($key)) { throw "Recipe value {$key} is not a prompt or built-in." }
        return [string]$Values[$key]
    })
}

function ConvertFrom-NSPADSecureString {
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-NSPADGpoRecipeValue {
    # Asks until the answer matches -Pattern. -Secret reads masked (Read-Host -AsSecureString).
    param([Parameter(Mandatory)][string]$Prompt, [string]$Pattern, [switch]$Secret, [string]$Hint)
    while ($true) {
        if ($Secret) {
            $value = ConvertFrom-NSPADSecureString (Read-Host -Prompt $Prompt -AsSecureString)
        } else {
            $value = Read-NSPNonEmpty -Prompt $(if ($Hint) { "$Prompt (e.g. $Hint)" } else { $Prompt })
        }
        $value = "$value".Trim()
        if ($value -and (-not $Pattern -or $value -match $Pattern)) { return $value }
        Write-Warning 'That value is not valid - try again.'
    }
}

function Initialize-NSPADGpoRecipeShare {
    # Creates the share folder and its report subfolders and sets their permissions. The parent
    # (the share itself) must exist and be writable by the caller. Re-running is harmless.
    param([Parameter(Mandatory)][string]$ShareRoot, [string[]]$ReportFolders = @())
    $parent = Split-Path -Parent $ShareRoot
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "'$parent' is not reachable - create the share first, or check the path and your access." }
    foreach ($dir in @($ShareRoot) + @($ReportFolders | ForEach-Object { Join-Path $ShareRoot $_ })) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            Write-Host "  Created $dir" -ForegroundColor Gray
        }
    }

    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $authUsers = New-Object Security.Principal.SecurityIdentifier('S-1-5-11')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')

    # Root: stop inheriting (keeping what was inherited), drop Users, Authenticated Users read.
    $acl = Get-Acl -LiteralPath $ShareRoot
    $acl.SetAccessRuleProtection($true, $true)
    Set-Acl -LiteralPath $ShareRoot -AclObject $acl
    $acl = Get-Acl -LiteralPath $ShareRoot
    foreach ($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) {
        try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) } catch { continue }
        if ($sid -eq $users) { $acl.RemoveAccessRuleSpecific($rule) }
    }
    $read = [Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize'
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($authUsers, $read, $inherit, $none, $allow)))
    Set-Acl -LiteralPath $ShareRoot -AclObject $acl
    Write-Host "  $ShareRoot - Authenticated Users read; Users removed" -ForegroundColor Gray

    # Report folders: computers create and write their own files (no delete, no attribute changes).
    $write = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, Synchronize'
    foreach ($name in $ReportFolders) {
        $dir = Join-Path $ShareRoot $name
        $acl = Get-Acl -LiteralPath $dir
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($authUsers, $write, $inherit, $none, $allow)))
        Set-Acl -LiteralPath $dir -AclObject $acl
        Write-Host "  $dir - Authenticated Users may write" -ForegroundColor Gray
    }
}

function Test-NSPADGpoLinked {
    # True when -TargetDN really carries a link to the GPO - read back from AD, so a caller never
    # depends on what the link step reported (or on whether a dry run skipped it).
    param([Parameter(Mandatory)][string]$GpoName, [Parameter(Mandatory)][string]$TargetDN)
    $links = @((Get-GPInheritance -Target $TargetDN -ErrorAction Stop).GpoLinks | Where-Object { $_.DisplayName -eq $GpoName })
    return ($links.Count -gt 0)
}

function Write-NSPADGpoRecipePayload {
    # Locks the file down first, then writes it (UTF-8 with BOM, as New-NSPClientScript does - 5.1
    # reads a BOM-less script as ANSI). An existing file keeps its ACL through the rewrite.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$DomainSid)
    Protect-NSPADGpoRecipePayload -Path $Path -DomainSid $DomainSid
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}

function Protect-NSPADGpoRecipePayload {
    # One file, readable only by the machines that run it: SYSTEM, Administrators and Domain Admins
    # full; Domain Computers, Domain Controllers and Enterprise Domain Controllers read. Creates
    # the file (empty) first when missing, so its contents never sit under the share's broad ACL.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$DomainSid)
    if (-not (Test-Path -LiteralPath $Path)) { [IO.File]::WriteAllText($Path, '') }
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $grants = @(
        @('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @("$DomainSid-512", 'FullControl'),
        @("$DomainSid-515", 'ReadAndExecute'), @("$DomainSid-516", 'ReadAndExecute'), @('S-1-5-9', 'ReadAndExecute')
    )
    foreach ($g in $grants) {
        $sid = New-Object Security.Principal.SecurityIdentifier($g[0])
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]$g[1], $allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
