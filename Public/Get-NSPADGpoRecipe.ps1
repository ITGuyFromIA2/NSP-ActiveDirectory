function Get-NSPADGpoRecipe {
    <#
    .SYNOPSIS
        Lists the GPO recipes Import-NSPADGpoRecipe can deploy: name, GPO name, what it asks for.
    .DESCRIPTION
        Read-only. A recipe is a folder under the module's GpoRecipes\ holding Recipe.psd1 (the GPO
        name, prompts, share layout, payload script and GPO tokens) and a portable GPO backup.
    .PARAMETER Name
        Return only this recipe (wildcards allowed).
    .EXAMPLE
        Get-NSPADGpoRecipe | Format-Table Name, GpoName, Description -Wrap
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][string]$Name = '*')

    $root = Join-Path $script:ModuleRoot 'GpoRecipes'
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $manifest = Join-Path $dir.FullName 'Recipe.psd1'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $data = Import-PowerShellDataFile -LiteralPath $manifest
        if ($data.Name -notlike $Name) { continue }
        $backup = Join-Path $dir.FullName $data.Backup
        if (-not (Test-Path -LiteralPath (Join-Path $backup 'manifest.xml'))) { throw "GPO recipe '$($data.Name)' has no GPO backup at $backup" }
        [pscustomobject]@{
            PSTypeName    = 'NSP.ActiveDirectory.GpoRecipe'
            Name          = $data.Name
            Version       = [string]$data.Version
            Description   = $data.Description
            GpoName       = $data.GpoName
            Prompts       = @($data.Prompts)
            ShareFolder   = $data.ShareFolder
            ReportFolders = @($data.ReportFolders)
            Payload       = $data.Payload
            GpoTokens     = $data.GpoTokens
            BackupPath    = $backup
            Path          = $dir.FullName
        }
    }
}
