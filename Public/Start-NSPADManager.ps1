function Start-NSPADManager {
    <#
    .SYNOPSIS
        The AD Manager dashboard: RSAT, VPN group/OU scaffold, group nesting, auto-enrollment GPO,
        WMI filters and the VPN inventory export, with DRY RUN on by default.

    .DESCRIPTION
        Relaunches elevated if needed. Answers are kept in the AD work folder
        (Get-NSPToolWorkPath -Tool AD). -SeedAnswersJson merges a launcher's answers into them;
        with -SeedOnly that is all it does (what a generated shim calls first). The first start on a
        server also offers to move the zip-era AD-Manager's files into the work folder.

        Every change goes through Invoke-NSPStep: DRY RUN prints what it would do, D switches to APPLY.

    .PARAMETER SeedAnswersJson
        Answers to merge in (plain JSON, or an AD Answers hand-off).

    .PARAMETER SeedOnly
        Merge -SeedAnswersJson and return without opening the dashboard.

    .PARAMETER NoElevate
        Do not relaunch elevated.

    .EXAMPLE
        Start-NSPADManager

    .EXAMPLE
        Start-NSPADManager -SeedAnswersJson (Get-Content .\ExampleCo_AD_Answers.json -Raw)
    #>
    [CmdletBinding()]
    param(
        [string]$SeedAnswersJson,
        [switch]$SeedOnly,
        [switch]$NoElevate
    )

    Use-NSPADDependency -Console -Bootstrap

    if ($SeedOnly) {
        $null = Import-NSPToolSeedAnswers -Tool AD -SeedAnswersJson $SeedAnswersJson
        return
    }

    if (-not $NoElevate) {
        $manifest = (Join-Path $script:ModuleRoot 'NSP.ActiveDirectory.psd1').Replace("'", "''")
        if (Invoke-NSPElevated -Command "Import-Module '$manifest'; Start-NSPADManager" -NoExit) { return }
    }

    $script:ADAnswers = Import-NSPToolSeedAnswers -Tool AD -SeedAnswersJson $SeedAnswersJson

    # First start on this server: offer to bring over what the zip-era AD-Manager left behind.
    $marker = Join-Path (Get-NSPToolWorkPath -Tool AD -Create) '.legacy-checked'
    if (-not (Test-Path -LiteralPath $marker)) {
        try {
            $summary = Move-NSPToolLegacyData -Tool AD
            if ($summary.Found) { $script:ADAnswers = Get-NSPToolAnswers -Tool AD; Read-Host "`nPress Enter to continue" | Out-Null }
        } catch { Write-Warning "Old AD-Manager files could not be checked: $($_.Exception.Message)" }
        Set-Content -LiteralPath $marker -Value (Get-Date -Format 's')
    }

    $version = Get-NSPADModuleVersion
    $label = (Get-NSPToolVersionStatus -ToolKey 'NSP.ActiveDirectory' -Version $version).Label
    Set-NSPConsoleMaximized -ErrorAction SilentlyContinue
    Set-NSPDryRun -Enabled $true

    $choices = @(
        [pscustomobject]@{ Label = 'Install RSAT / management modules'; Value = 'Prereqs'; Help = 'ActiveDirectory and GroupPolicy PowerShell modules.' }
        [pscustomobject]@{ Label = 'Stand up the VPN group/OU scaffold'; Value = 'Scaffold'; Help = 'VPNGroups\ with the main VPN group, VPNGroups\FWRules\ with the VPNFW purpose groups.' }
        [pscustomobject]@{ Label = 'Nest a group into the shared VPNFW purpose groups'; Value = 'Nest'; Help = 'Repeatable, for group pairs added later.' }
        [pscustomobject]@{ Label = 'Push the certificate auto-enrollment GPO'; Value = 'Gpo' }
        [pscustomobject]@{ Label = 'Stand up the well-known WMI filters'; Value = 'Wmi' }
        [pscustomobject]@{ Label = 'Export VPN documentation inventory (read-only)'; Value = 'Inventory'; Help = 'Hand-off file for the Orchestrator VPN report.' }
        [pscustomobject]@{ Key = 'D'; Label = 'Toggle DRY RUN / APPLY'; Value = 'DryRun' }
        [pscustomobject]@{ Key = 'L'; Label = 'Clean up old AD-Manager (zip) files'; Value = 'Legacy' }
    )

    while ($true) {
        Clear-NSPConsole
        $company = if ($script:ADAnswers -and $script:ADAnswers.PSObject.Properties['CompanyName']) { [string]$script:ADAnswers.CompanyName } else { $env:USERDNSDOMAIN }
        Write-NSPConsoleHeader -Title "AD Manager  $label" -Subtitle $company
        if (Get-NSPDryRun) {
            Write-NSPConsoleLine '  MODE: DRY RUN - actions print what they would do and change nothing. Press D to switch to APPLY.' -Role Heading
        } else {
            Write-NSPConsoleLine '  MODE: APPLY - actions will make real changes. Press D to switch back to DRY RUN.' -Role Error
        }
        Write-Host ''
        $pick = Read-NSPMenu -Choices $choices -CancelLabel 'Quit'
        if ($null -eq $pick) { return }
        try {
            switch ($pick) {
                'Prereqs' { Invoke-NSPADMenuPrereqs }
                'Scaffold' { Invoke-NSPADMenuScaffold }
                'Nest' { Invoke-NSPADMenuNestGroup }
                'Gpo' { Invoke-NSPADMenuAutoEnrollGpo }
                'Wmi' { Invoke-NSPADMenuWmiFilters }
                'Inventory' { Invoke-NSPADMenuVpnInventory }
                'Legacy' { Invoke-NSPADMenuLegacyCleanup }
                'DryRun' {
                    if (Get-NSPDryRun) {
                        Write-NSPConsoleLine "`nSwitching to APPLY mode - actions will make real changes." -Role Error
                        if ((Read-Host 'Type APPLY to confirm') -ceq 'APPLY') { Set-NSPDryRun -Enabled $false }
                        else { Write-NSPConsoleLine 'Kept DRY RUN.' -Role Muted }
                    } else {
                        Set-NSPDryRun -Enabled $true
                        Write-NSPConsoleLine "`nBack to DRY RUN." -Role Heading
                    }
                    Start-Sleep -Seconds 1
                }
            }
            Save-NSPToolAnswers -Tool AD -Answers $script:ADAnswers
        } catch {
            Write-NSPConsoleLine "`nUNEXPECTED ERROR: $($_.Exception.Message)" -Role Error
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
            Read-Host 'Press Enter to return to the menu' | Out-Null
        }
    }
}
