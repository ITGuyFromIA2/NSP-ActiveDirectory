function Get-NSPADGpoCatalog {
    <#
    .SYNOPSIS
        Lists the GPO backups in a catalog folder (a share of exported, portable GPOs): one row per
        backup with its display name, backup ID, time, folder, and whether ADMX templates sit next
        to it. Zip files in the catalog are listed too (Kind = Zip) - Import-NSPADGpoBackup takes either.
    .DESCRIPTION
        Read-only. A backup is any {GUID} folder holding bkupInfo.xml (hidden, as Backup-GPO writes
        it), up to -Depth levels below -Path. Category is the first folder under -Path.
    .PARAMETER Path
        The catalog root, e.g. a share of GPO exports. Defaults to $env:NSP_GPO_CATALOG.
    .PARAMETER Depth
        How deep to look. Default 5.
    .EXAMPLE
        Get-NSPADGpoCatalog -Path '\\fileserver\GPO' | Format-Table Category, DisplayName, BackupTime
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path = $env:NSP_GPO_CATALOG,
        [ValidateRange(1, 10)][int]$Depth = 5
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Give -Path (the GPO catalog folder), or set NSP_GPO_CATALOG.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "GPO catalog not found: $Path" }
    $root = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')
    $parsed = [datetime]::MinValue
    $category = { param($full) $rel = $full.Substring($root.Length).TrimStart('\'); if ($rel -match '\\') { $rel.Split('\')[0] } else { '' } }

    foreach ($info in @(Get-ChildItem -LiteralPath $root -Recurse -Depth $Depth -Force -File -Filter 'bkupInfo.xml' -ErrorAction SilentlyContinue)) {
        $b = Get-NSPADGpoBackupInfo -BackupFolder $info.DirectoryName
        if (-not $b) { continue }
        $hasAdmx = [bool](Get-ChildItem -LiteralPath (Split-Path -Parent $b.BackupRoot) -Recurse -Depth 2 -Filter '*.admx' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        [pscustomobject]@{
            PSTypeName  = 'NSP.ActiveDirectory.GpoCatalogEntry'
            Kind        = 'Backup'
            Category    = & $category $b.BackupFolder
            DisplayName = $b.DisplayName
            BackupId    = $b.BackupId
            BackupTime  = $(if ([datetime]::TryParse("$($b.BackupTime)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { $parsed } else { $b.BackupTime })
            HasAdmx     = $hasAdmx
            Path        = $b.BackupRoot
        }
    }
    foreach ($zip in @(Get-ChildItem -LiteralPath $root -Recurse -Depth $Depth -File -Filter '*.zip' -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{
            PSTypeName  = 'NSP.ActiveDirectory.GpoCatalogEntry'
            Kind        = 'Zip'
            Category    = & $category $zip.FullName
            DisplayName = $zip.BaseName
            BackupId    = $null
            BackupTime  = $zip.LastWriteTime
            HasAdmx     = $null
            Path        = $zip.FullName
        }
    }
}
