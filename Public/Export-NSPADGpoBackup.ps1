function Export-NSPADGpoBackup {
    <#
    .SYNOPSIS
        Backs up one or more GPOs into <Path>\<safe GPO name>\, optionally made portable (-Genericize):
        this domain's DC, DNS and NetBIOS names replaced by the DC.contoso.com / contoso.com / contoso
        placeholders Import-NSPADGpoBackup fills in on the target domain. Returns the backup folders.
    .DESCRIPTION
        Uses Backup-GPO (GroupPolicy module). Each GPO gets its own folder, so a catalog share can hold
        many. Supports -WhatIf.
    .PARAMETER Name
        GPO display names.
    .PARAMETER Path
        Folder to write the backups into.
    .PARAMETER Genericize
        Replace this domain's names with the placeholders (for a shared catalog).
    .PARAMETER Comment
        Backup comment.
    .EXAMPLE
        Export-NSPADGpoBackup -Name 'NSP - TLS1 - Enable TLS 1.2' -Path 'D:\GPOCatalog\TLS' -Genericize
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Genericize,
        [string]$Comment
    )
    Assert-NSPADCommand Backup-GPO -ModuleHint 'GroupPolicy (RSAT)'
    $domain = if ($Genericize) { Get-NSPADGpoDomainNames } else { $null }
    foreach ($n in $Name) {
        $dir = Join-Path $Path ($n -replace '[\\/:*?"<>|]', '_')
        if (-not $PSCmdlet.ShouldProcess($dir, "Back up GPO '$n'$(if ($Genericize) { ' (portable)' })")) { continue }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $backupArgs = @{ Name = $n; Path = $dir; ErrorAction = 'Stop' }
        if ($Comment) { $backupArgs.Comment = $Comment }
        $null = Backup-GPO @backupArgs
        if ($Genericize) { Convert-NSPADGpoBackupFolder -BackupRoot $dir -From $domain -To $script:NSPADGpoPlaceholder }
        Get-Item -LiteralPath $dir
    }
}
