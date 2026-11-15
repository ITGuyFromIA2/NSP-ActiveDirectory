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

        A domain name that cannot be read, or a WMI filter that does not exist, stops the command
        before anything is imported.

        The result's WmiFilter and Linked are read back from the directory after the steps ran:
        WmiFilter is the filter the GPO has now (empty if none), Linked is True only when the
        link is really at the domain root. The filter and link steps follow NSP.Toolkit's dry run
        (on by default), so with dry run on the GPO is imported and both come back empty / False.
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
    .PARAMETER Server
        A domain controller. The domain-name reads, the filter lookup, Import-GPO, the filter and
        link steps and both read-backs all go to it, so the read-back never looks at a DC the
        import has not reached yet. Default: each cmdlet picks one.
    .PARAMETER AsResult
        Return an NSP.ActiveDirectory.WriteOutcome instead of the GpoImport object: Created (no GPO
        of that name before), Updated (Import-GPO overwrote one: the backup is not compared with the
        GPO first, so Updated does not mean drift was found) or Failed. Created/Updated need the
        GPO, the requested filter and the requested link all read back. Unlike the default path,
        Import-GPO itself follows NSP.Toolkit's dry run in this mode: with dry run on, nothing is
        imported and the outcome is Previewed. CHECK Outcome. Not management-plane verification.
    .EXAMPLE
        Get-NSPADGpoCatalog -Path '\\fileserver\GPO' | Where-Object DisplayName -like '*TLS 1.2*' |
            ForEach-Object { Import-NSPADGpoBackup -Path $_.Path -WmiFilterName 'NSP_AT - All Servers' -LinkAtDomainRoot }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    [OutputType('NSP.ActiveDirectory.WriteOutcome')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][string]$Path,
        [string]$TargetName,
        [string]$WmiFilterName,
        [switch]$LinkAtDomainRoot,
        [Collections.IDictionary]$Replace,
        [ValidateNotNullOrEmpty()][string]$Server,
        [switch]$AsResult
    )
    process {
        if ($AsResult) { return (Invoke-NSPADGpoBackupOutcome -Cmdlet $PSCmdlet -Path $Path -TargetName $TargetName -WmiFilterName $WmiFilterName -LinkAtDomainRoot ([bool]$LinkAtDomainRoot) -Replace $Replace -Server $Server) }
        Assert-NSPADCommand Import-GPO -ModuleHint 'GroupPolicy (RSAT)'
        $srv = Get-NSPADServerSplat -Server $Server
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

            # Everything that can be found missing is looked up BEFORE the import, so a missing domain
            # name or WMI filter stops the command with nothing written, not with a GPO imported and
            # an exception in place of a result.
            $names = Get-NSPADGpoDomainNames -Server $Server
            foreach ($key in 'Pdc', 'Dns', 'NetBios') {
                if ([string]::IsNullOrWhiteSpace("$($names[$key])")) { throw "This domain's $key name could not be read (Get-ADDomain) - nothing was imported." }
            }
            $domainDn = ''
            if ($WmiFilterName -or $LinkAtDomainRoot) {
                $domainDn = "$((Get-ADDomain @srv -ErrorAction Stop).DistinguishedName)"
                if ([string]::IsNullOrWhiteSpace($domainDn)) { throw "This domain's distinguished name could not be read (Get-ADDomain) - nothing was imported." }
            }
            if ($WmiFilterName -and -not (Get-NSPADWmiSomEntry -DomainDN $domainDn -Server $Server | Where-Object { $_.Name -eq $WmiFilterName } | Select-Object -First 1)) {
                throw "WMI filter '$WmiFilterName' does not exist in $($names.Dns) - create it first (New-NSPADWmiFilter). Nothing was imported."
            }

            Convert-NSPADGpoBackupFolder -BackupRoot $backup.BackupRoot -From $script:NSPADGpoPlaceholder -To $names
            if ($Replace -and $Replace.Count) { Convert-NSPADGpoBackupToken -BackupRoot $backup.BackupRoot -Replace $Replace }
            $null = Import-GPO -BackupId $backup.BackupId -Path $backup.BackupRoot -TargetName $name -CreateIfNeeded @srv -ErrorAction Stop
            if (-not (Get-GPO -Name $name @srv -ErrorAction SilentlyContinue)) { throw "GPO '$name' was not imported." }
            if ($WmiFilterName) { Set-NSPADGpoWmiFilter -GpoName $name -WmiFilterName $WmiFilterName @srv }
            if ($LinkAtDomainRoot) { New-NSPADGpoLink -GpoName $name -TargetDN $domainDn @srv }

            # WmiFilter and Linked say what the directory holds now, read back after the steps above.
            # Both steps are dry-run aware (Invoke-NSPStep), so asking for them is not proof they ran.
            $appliedFilter = $null
            if ($WmiFilterName) {
                $after = Get-GPO -Name $name @srv -ErrorAction SilentlyContinue
                if ($after -and $after.PSObject.Properties['WmiFilter'] -and $after.WmiFilter) { $appliedFilter = "$($after.WmiFilter.Name)" }
            }
            $linked = $false
            if ($LinkAtDomainRoot) {
                try { $linked = [bool](Test-NSPADGpoLinked -GpoName $name -TargetDN $domainDn -Server $Server) }
                catch { Write-Warning "GPO '$name' was imported, but its link at $domainDn could not be read back: $($_.Exception.Message)" }
            }
            [pscustomobject]@{ PSTypeName = 'NSP.ActiveDirectory.GpoImport'; GpoName = $name; BackupName = $backup.DisplayName; WmiFilter = $appliedFilter; Linked = $linked }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}
