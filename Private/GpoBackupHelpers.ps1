<#
    GPO backup helpers (from PoSHRepo Windows\GPO\ReplaceImportGPO.ps1 + ActiveDirectory\GPO\ExportGPO.ps1).
    A "portable" backup has its source domain replaced by placeholders, in this order:
        DC.contoso.com  <- the domain controller FQDN the backup was taken on (PDC emulator)
        contoso.com     <- the DNS domain
        contoso         <- the NetBIOS domain
    Order matters both ways: the DC FQDN contains the DNS name, and the DNS name contains the
    NetBIOS name in most domains.
#>

$script:NSPADGpoPlaceholder = [ordered]@{ Pdc = 'DC.contoso.com'; Dns = 'contoso.com'; NetBios = 'contoso' }
# The files Backup-GPO writes that carry domain names; manifest.xml sits beside the {GUID} folder.
$script:NSPADGpoBackupFiles = @('gpreport.xml', 'Backup.xml', 'bkupInfo.xml')

function Get-NSPADGpoBackupInfo {
    # One backup ({GUID} folder holding bkupInfo.xml): display name, backup ID, GPO GUID, time, domain.
    param([Parameter(Mandatory)][string]$BackupFolder)
    $info = Get-ChildItem -LiteralPath $BackupFolder -Filter 'bkupInfo.xml' -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $info) { return $null }
    try { $x = [xml](Get-Content -LiteralPath $info.FullName -Raw) } catch { return $null }
    $bi = $x.DocumentElement
    $text = { param($n) $node = $bi.ChildNodes | Where-Object { $_.LocalName -eq $n } | Select-Object -First 1; if ($node) { "$($node.InnerText)".Trim() } }
    [pscustomobject]@{
        DisplayName  = & $text 'GPODisplayName'
        BackupId     = & $text 'ID'
        GpoGuid      = & $text 'GPOGuid'
        BackupTime   = & $text 'BackupTime'
        SourceDomain = & $text 'GPODomain'
        Comment      = & $text 'Comment'
        BackupFolder = (Get-Item -LiteralPath $BackupFolder).FullName
        BackupRoot   = (Split-Path -Parent (Get-Item -LiteralPath $BackupFolder).FullName)
    }
}

function Get-NSPADGpoDomainNames {
    # This domain's names in placeholder order: Pdc, Dns, NetBios.
    $d = Get-ADDomain -ErrorAction Stop
    [ordered]@{ Pdc = "$($d.PDCEmulator)"; Dns = "$($d.DNSRoot)"; NetBios = "$($d.NetBIOSName)" }
}

function Convert-NSPADGpoBackupText {
    <#
        PURE. Replaces each -From value with the matching -To value (keys Pdc, Dns, NetBios, in that
        order) in -Text. Case-insensitive, so a backup taken on CONTOSO.COM still matches contoso.com.
    #>
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][Collections.IDictionary]$From, [Parameter(Mandatory)][Collections.IDictionary]$To)
    foreach ($key in 'Pdc', 'Dns', 'NetBios') {
        if ([string]::IsNullOrEmpty($From[$key]) -or $null -eq $To[$key]) { continue }
        $Text = [regex]::Replace($Text, [regex]::Escape([string]$From[$key]), ([string]$To[$key]).Replace('$', '$$'), 'IgnoreCase')
    }
    return $Text
}

function Convert-NSPADGpoBackupFolder {
    # Rewrites the domain names in one backup root (manifest.xml + the {GUID} folder's files). Keeps
    # each file's encoding (Backup-GPO writes UTF-16 for some of them).
    param([Parameter(Mandatory)][string]$BackupRoot, [Parameter(Mandatory)][Collections.IDictionary]$From, [Parameter(Mandatory)][Collections.IDictionary]$To)
    $files = @(Get-ChildItem -LiteralPath $BackupRoot -Filter 'manifest.xml' -Force -File -ErrorAction SilentlyContinue)
    foreach ($guidDir in @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -Filter '{*}')) {
        $files += @(Get-ChildItem -LiteralPath $guidDir.FullName -Force -File | Where-Object { $script:NSPADGpoBackupFiles -contains $_.Name })
    }
    foreach ($f in $files) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $enc = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { [Text.Encoding]::Unicode }
               elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { New-Object Text.UTF8Encoding($true) }
               else { New-Object Text.UTF8Encoding($false) }
        $reader = New-Object IO.StreamReader((New-Object IO.MemoryStream(, $bytes)), $enc, $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $new = Convert-NSPADGpoBackupText -Text $text -From $From -To $To
        if ($new -cne $text) {
            $attrs = $f.Attributes
            if ($attrs -band [IO.FileAttributes]::Hidden) { $f.Attributes = $attrs -band (-bnot [IO.FileAttributes]::Hidden) }
            try { [IO.File]::WriteAllText($f.FullName, $new, $enc) } finally { $f.Attributes = $attrs }
        }
    }
}
