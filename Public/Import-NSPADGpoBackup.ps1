function Import-NSPADGpoBackup {
    <#
    .SYNOPSIS
        Imports a GPO backup into this domain - a backup folder or a .zip of one, e.g. a row from
        Get-NSPADGpoCatalog - filling in this domain's names for the DC.contoso.com / contoso.com /
        contoso placeholders, then optionally sets a WMI filter and links it at the domain root.
    .DESCRIPTION
        Works on a temporary copy: the catalog's own files are never changed (the zip-era
        ReplaceImportGPO.ps1 rewrote the backup in place). Import-GPO -CreateIfNeeded creates the GPO
        or overwrites the settings of an existing one with the same name. Supports -WhatIf.
    .PARAMETER Path
        A backup root (the folder holding the {GUID} folder) or a .zip of one.
    .PARAMETER TargetName
        Name of the GPO in this domain. Default: the backup's own display name.
    .PARAMETER WmiFilterName
        A WMI filter (already in this domain - see New-NSPADWmiFilter) to apply to the GPO.
    .PARAMETER LinkAtDomainRoot
        Link the GPO at the domain root (New-NSPADGpoLink - skipped when already linked).
    .PARAMETER Replace
        Extra literal find -> replace pairs applied to every .xml file in the copy (preference
        files included), after the domain names - for tokens a template carries, such as a
        file-share path. Values are inserted as-is, so XML-escape them.
    .EXAMPLE
        Get-NSPADGpoCatalog -Path '\\fileserver\GPO' | Where-Object DisplayName -like '*TLS 1.2*' |
            ForEach-Object { Import-NSPADGpoBackup -Path $_.Path -WmiFilterName 'NSP_AT - All Servers' -LinkAtDomainRoot }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Path,
        [string]$TargetName,
        [string]$WmiFilterName,
        [switch]$LinkAtDomainRoot,
        [Collections.IDictionary]$Replace
    )
    process {
        Assert-NSPADCommand Import-GPO -ModuleHint 'GroupPolicy (RSAT)'
        if (-not (Test-Path -LiteralPath $Path)) { throw "GPO backup not found: $Path" }
        $work = Join-Path ([IO.Path]::GetTempPath()) ('NSPGpoImport_' + [guid]::NewGuid().ToString('N'))
        # Scratch copy - not the change -WhatIf previews, so its file steps always run.
        New-Item -ItemType Directory -Path $work -Force -WhatIf:$false | Out-Null
        try {
            if ((Get-Item -LiteralPath $Path).PSIsContainer) { Copy-Item -LiteralPath $Path -Destination $work -Recurse -Force -WhatIf:$false; $src = Join-Path $work (Split-Path -Leaf $Path) }
            else { Expand-Archive -LiteralPath $Path -DestinationPath $work -Force -WhatIf:$false; $src = $work }
            $info = Get-ChildItem -LiteralPath $src -Recurse -Force -File -Filter 'bkupInfo.xml' | Select-Object -First 1
            if (-not $info) { throw "No GPO backup (bkupInfo.xml) in $Path" }
            $backup = Get-NSPADGpoBackupInfo -BackupFolder $info.DirectoryName
            $name = if ($TargetName) { $TargetName } else { $backup.DisplayName }
            if (-not $PSCmdlet.ShouldProcess($name, "Import GPO backup '$($backup.DisplayName)'$(if ($WmiFilterName) { ", WMI filter '$WmiFilterName'" })$(if ($LinkAtDomainRoot) { ', link at the domain root' })")) { return }

            Convert-NSPADGpoBackupFolder -BackupRoot $backup.BackupRoot -From $script:NSPADGpoPlaceholder -To (Get-NSPADGpoDomainNames)
            if ($Replace -and $Replace.Count) { Convert-NSPADGpoBackupToken -BackupRoot $backup.BackupRoot -Replace $Replace }
            $null = Import-GPO -BackupId $backup.BackupId -Path $backup.BackupRoot -TargetName $name -CreateIfNeeded -ErrorAction Stop
            if (-not (Get-GPO -Name $name -ErrorAction SilentlyContinue)) { throw "GPO '$name' was not imported." }
            if ($WmiFilterName) { Set-NSPADGpoWmiFilter -GpoName $name -WmiFilterName $WmiFilterName }
            if ($LinkAtDomainRoot) { New-NSPADGpoLink -GpoName $name -TargetDN "$((Get-ADDomain -ErrorAction Stop).DistinguishedName)" }
            [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.GpoImport'; GpoName = $name; BackupName = $backup.DisplayName; WmiFilter = $WmiFilterName; Linked = [bool]$LinkAtDomainRoot }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}
