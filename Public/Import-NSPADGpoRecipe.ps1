function Import-NSPADGpoRecipe {
    <#
    .SYNOPSIS
        Deploys a GPO recipe (Get-NSPADGpoRecipe) to this domain, run on the client's DC: prepares
        the file-share folder, writes the recipe's script to it, imports the recipe's GPO pointing at
        that script, and links it. Asks for anything not passed in.
    .DESCRIPTION
        -Action Deploy, in order:
          1. Share: creates <FileShareRoot> and its report folders, Kickstart-style - Authenticated
             Users read the folder (inheritance broken, Users removed) and may create/write files in
             the report folders, so the computers report back there.
          2. Script: renders the recipe's NSP.ClientScripts recipe to <FileShareRoot>\<file>, readable
             only by SYSTEM, administrators, domain computers and domain controllers (it can carry
             secrets, e.g. the Huntress account key).
          3. GPO: imports the recipe's portable backup (Import-NSPADGpoBackup - this domain's names
             filled in, the script path put into its preference XML) as the recipe's GPO, creating it
             or updating it in place, and links it per -Scope.
        Re-running updates everything in place: the script is regenerated, the GPO re-imported.
        Values are checked before anything changes; one confirmation covers all three steps
        (-Confirm:$false skips it, -WhatIf shows it).
    .PARAMETER Recipe
        The recipe name, e.g. Huntress (Get-NSPADGpoRecipe lists them).
    .PARAMETER Action
        Deploy (the only action so far).
    .PARAMETER Scope
        All - link at the domain root, every computer including domain controllers (the only scope
        so far).
    .PARAMETER FileShareRoot
        The deployment folder on a file share, e.g. \\fileserver\GPO_Share$\Huntress. Its parent must
        exist. Asked for when not given.
    .PARAMETER Values
        Answers to the recipe's prompts (e.g. @{ OrganizationKey = 'Contoso'; AccountKey = ... }); a
        secret may be a SecureString. Anything missing is asked for.
    .EXAMPLE
        Import-NSPADGpoRecipe -Recipe Huntress -Action Deploy -Scope All
    .EXAMPLE
        Import-NSPADGpoRecipe Huntress -FileShareRoot '\\fileserver\GPO_Share$\Huntress' -Values @{ OrganizationKey = 'Contoso' }
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({ param($c, $p, $word) (Get-NSPADGpoRecipe).Name | Where-Object { $_ -like "$word*" } })]
        [string]$Recipe,
        [ValidateSet('Deploy')][string]$Action = 'Deploy',
        [ValidateSet('All')][string]$Scope = 'All',
        [string]$FileShareRoot,
        [hashtable]$Values = @{}
    )

    $r = @(Get-NSPADGpoRecipe | Where-Object { $_.Name -eq $Recipe })
    if ($r.Count -ne 1) { throw "No GPO recipe named '$Recipe'. Recipes: $(@(Get-NSPADGpoRecipe).Name -join ', ')." }
    $r = $r[0]
    $promptNames = @($r.Prompts | ForEach-Object { $_.Name })
    foreach ($key in $Values.Keys) {
        if ($promptNames -notcontains $key) { throw "Recipe '$($r.Name)' has no value '$key'. Values: $($promptNames -join ', ')." }
    }

    Use-NSPADDependency -Console
    Assert-NSPADCommand Import-GPO -ModuleHint 'GroupPolicy (RSAT)'
    Assert-NSPADCommand Get-ADDomain
    Import-NSPToolkitModule -Name NSP.ClientScripts -MinimumVersion 0.1.5
    $domain = Get-ADDomain -ErrorAction Stop

    Write-Host "`n$($r.Name) GPO recipe - $Action, scope $Scope, domain $($domain.DNSRoot)" -ForegroundColor Cyan
    if (-not $FileShareRoot) {
        $FileShareRoot = Read-NSPADGpoRecipeValue -Prompt 'Deployment folder on a file share' -Pattern $script:NSPADUncPattern -Hint "\\fileserver\GPO_Share`$\$($r.ShareFolder)"
    }
    $FileShareRoot = $FileShareRoot.Trim().TrimEnd('\')
    if ($FileShareRoot -notmatch $script:NSPADUncPattern) { throw "-FileShareRoot must be a UNC path (\\server\share\folder): $FileShareRoot" }

    $answers = [ordered]@{}
    foreach ($p in $r.Prompts) {
        if ($Values.ContainsKey($p.Name)) {
            $v = $Values[$p.Name]
            if ($v -is [Security.SecureString]) { $v = ConvertFrom-NSPADSecureString $v }
            $v = "$v".Trim()
            if ($p.Pattern -and $v -notmatch $p.Pattern) { throw "-Values $($p.Name) is not valid for recipe '$($r.Name)'." }
        } else {
            $v = Read-NSPADGpoRecipeValue -Prompt $p.Prompt -Pattern $p.Pattern -Secret:([bool]$p.Secret)
        }
        $answers[$p.Name] = $v
    }

    $payloadPath = Join-Path $FileShareRoot $r.Payload.FileName
    $all = [ordered]@{}
    foreach ($k in $answers.Keys) { $all[$k] = $answers[$k] }
    $all['ShareRoot'] = $FileShareRoot; $all['PayloadPath'] = $payloadPath; $all['GpoName'] = $r.GpoName

    # Rendered (and so validated) before anything changes.
    $scriptParams = @{ GeneratedBy = "Import-NSPADGpoRecipe $($r.Name) v$($r.Version)" }
    foreach ($k in $r.Payload.Parameters.Keys) { $scriptParams[$k] = Expand-NSPADGpoRecipeText -Text $r.Payload.Parameters[$k] -Values $all }
    $scriptText = ConvertTo-NSPClientScript -Recipe $r.Payload.ClientScriptRecipe -Parameters $scriptParams
    $tokens = @{}
    foreach ($k in $r.GpoTokens.Keys) { $tokens[$k] = [Security.SecurityElement]::Escape((Expand-NSPADGpoRecipeText -Text $r.GpoTokens[$k] -Values $all)) }

    $reportList = @($r.ReportFolders | ForEach-Object { Join-Path $FileShareRoot $_ })
    Write-Host "  Share folder : $FileShareRoot"
    Write-Host "  Script       : $payloadPath"
    if ($reportList) { Write-Host "  Reports      : $($reportList -join ', ')" }
    Write-Host "  GPO          : $($r.GpoName), linked at $($domain.DistinguishedName) (all computers)"
    if (-not $PSCmdlet.ShouldProcess($domain.DNSRoot, "Deploy GPO recipe '$($r.Name)': share folder $FileShareRoot, GPO '$($r.GpoName)' linked at the domain root")) { return }

    Write-Host "`n[1/3] Share folder" -ForegroundColor Cyan
    Initialize-NSPADGpoRecipeShare -ShareRoot $FileShareRoot -ReportFolders @($r.ReportFolders)

    Write-Host "[2/3] Script" -ForegroundColor Cyan
    Write-NSPADGpoRecipePayload -Path $payloadPath -Text $scriptText -DomainSid "$($domain.DomainSID)"
    Write-Host "  Wrote $payloadPath (SYSTEM, administrators, domain computers and DCs only)" -ForegroundColor Gray

    Write-Host "[3/3] GPO" -ForegroundColor Cyan
    # The confirmation above is this command's gate, so NSP.Toolkit's session dry run (on by
    # default) must not quietly skip the link step; the caller's setting comes back afterwards.
    $wasDryRun = Get-NSPDryRun
    Set-NSPDryRun -Enabled $false -Confirm:$false
    try {
        $import = Import-NSPADGpoBackup -Path $r.BackupPath -TargetName $r.GpoName -Replace $tokens -LinkAtDomainRoot:($Scope -eq 'All') -Confirm:$false
    } finally {
        Set-NSPDryRun -Enabled $wasDryRun -Confirm:$false
    }
    # Import-NSPADGpoBackup's own Linked flag is not trusted (see the backlog: a dry run used to skip
    # the link and still say True) - the link is read back from AD instead.
    $linked = $false
    if ($Scope -eq 'All') {
        $linked = Test-NSPADGpoLinked -GpoName $import.GpoName -TargetDN "$($domain.DistinguishedName)"
        if (-not $linked) { throw "GPO '$($import.GpoName)' was imported but is not linked at $($domain.DistinguishedName). Link it with: New-NSPADGpoLink -GpoName '$($import.GpoName)' -TargetDN '$($domain.DistinguishedName)'" }
    }
    Write-Host "  Imported '$($r.GpoName)'$(if ($linked) { ' - linked at the domain root (checked in AD)' })" -ForegroundColor Gray
    Write-Host "`nDone. Computers pick it up at their next policy refresh (gpupdate /force to hurry one); results land in $(if ($reportList) { $reportList -join ' and ' } else { $FileShareRoot })." -ForegroundColor Green

    [pscustomobject]@{
        PSTypeName    = 'NSP.ActiveDirectory.GpoRecipeDeployment'
        Recipe        = $r.Name
        Action        = $Action
        Scope         = $Scope
        GpoName       = $r.GpoName
        Linked        = $linked
        FileShareRoot = $FileShareRoot
        PayloadPath   = $payloadPath
        ReportFolders = $reportList
    }
}
