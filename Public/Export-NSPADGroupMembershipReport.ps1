function Export-NSPADGroupMembershipReport {
    <#
    .SYNOPSIS
        Writes one CSV per group (GivenName, Surname, UserPrincipalName, SamAccountName, Group) into
        -Path, moving the previous run's CSVs into an archive folder and deleting archived reports
        older than -RetentionDays. Returns the CSV files written.
    .DESCRIPTION
        A monthly "who is in these groups" report. File names are <yyyy-MM-dd>_<group>.csv. Members
        are users (nested groups expanded with -Recursive); computers and groups are left out.
        Sending the report on (email, ticket) is left to the caller. Supports -WhatIf.
    .PARAMETER Group
        Groups to report on.
    .PARAMETER Path
        Report folder (created when missing).
    .PARAMETER ArchiveFolderName
        Sub-folder of -Path that earlier reports are moved into. Default: PastReports.
    .PARAMETER RetentionDays
        Archived reports older than this are deleted. Default: 180.
    .PARAMETER Recursive
        Include users who are members through nested groups.
    .EXAMPLE
        Export-NSPADGroupMembershipReport -Group 'Group - All Employees', 'Group - On Call' -Path 'D:\Reports\Groups'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string[]]$Group,
        [Parameter(Mandatory)][string]$Path,
        [string]$ArchiveFolderName = 'PastReports',
        [ValidateRange(1, 3650)][int]$RetentionDays = 180,
        [switch]$Recursive
    )
    Assert-NSPADCommand Get-ADGroupMember -ModuleHint 'ActiveDirectory (RSAT)'
    $archive = Join-Path $Path $ArchiveFolderName
    if (-not $PSCmdlet.ShouldProcess($Path, "Write group membership reports for $($Group.Count) group(s)")) { return }
    foreach ($dir in $Path, $archive) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } }

    # Last run's reports move to the archive; archived reports past retention are deleted.
    foreach ($old in @(Get-ChildItem -LiteralPath $Path -Filter '*.csv' -File)) { Move-Item -LiteralPath $old.FullName -Destination $archive -Force }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    foreach ($stale in @(Get-ChildItem -LiteralPath $archive -Filter '*.csv' -File | Where-Object { $_.LastWriteTime -lt $cutoff })) { Remove-Item -LiteralPath $stale.FullName -Force }

    $stamp = Get-Date -Format 'yyyy-MM-dd'
    foreach ($g in $Group) {
        $rows = foreach ($m in @(Get-ADGroupMember -Identity $g -Recursive:$Recursive -ErrorAction Stop | Where-Object { $_.objectClass -eq 'user' })) {
            $u = Get-ADUser -Identity $m -Properties GivenName, Surname, UserPrincipalName -ErrorAction Stop
            [pscustomobject]@{ GivenName = $u.GivenName; Surname = $u.Surname; UserPrincipalName = $u.UserPrincipalName; SamAccountName = $u.SamAccountName; Group = $g }
        }
        $file = Join-Path $Path ("{0}_{1}.csv" -f $stamp, ($g -replace '[\\/:*?"<>|]', '_'))
        if ($rows) { $rows | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 } else { Set-Content -LiteralPath $file -Value '"GivenName","Surname","UserPrincipalName","SamAccountName","Group"' -Encoding UTF8 }
        Get-Item -LiteralPath $file
    }
}
