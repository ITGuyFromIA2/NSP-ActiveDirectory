# Start-NSPADManager's menu actions. Each gathers what it needs, then calls the public functions;
# every change goes through Invoke-NSPStep, so DRY RUN is honoured.

function Write-NSPADScreen {
    param([Parameter(Mandatory)][string]$Title)
    Clear-NSPConsole
    Write-NSPConsoleHeader -Title $Title -Subtitle 'AD Manager'
    Write-Host ''
}

function Wait-NSPADReturn {
    Read-Host "`nPress Enter to return to the menu" | Out-Null
}

function Get-NSPADScaffoldAnswers {
    # The answers the scaffold plan reads: this server's saved AD answers when they carry scaffold
    # fields, else optionally a ClientAnswers\<Abbrev>.json file, else $null (generic defaults).
    $saved = $script:ADAnswers
    $scaffoldFields = @('Auth_UserGroup_Value', 'VPNFW_DNS_Mode') + @(Get-NSPADPurposeGroupDefault | ForEach-Object AnswersField)
    if ($saved -and @($scaffoldFields | Where-Object { $saved.PSObject.Properties[$_] }).Count) {
        $label = if ($saved.PSObject.Properties['CompanyName'] -and $saved.CompanyName) { " for $($saved.CompanyName)" } else { '' }
        if (Read-NSPConfirm -Prompt "Use the saved answers$($label)?" -DefaultYes) { return $saved }
    }
    if (-not (Read-NSPConfirm -Prompt "Read defaults from a client's saved answers file (ClientAnswers\<Abbrev>.json)?")) { return $null }
    $path = (Read-NSPNonEmpty -Prompt 'Path to the answers file').Trim('"')
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "  '$path' not found - using generic defaults instead." -ForegroundColor Yellow
        return $null
    }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch {
        Write-Host "  Could not parse '$path' ($($_.Exception.Message)) - using generic defaults instead." -ForegroundColor Yellow
        return $null
    }
}

function Invoke-NSPADMenuPrereqs {
    Write-NSPADScreen 'Install RSAT / management modules'
    $st = Get-NSPADPrerequisiteStatus
    $adText = if ($st.ActiveDirectory) { 'present' } else { 'MISSING - needed for menu 2/3 (group/OU scaffold)' }
    $gpText = if ($st.GroupPolicy) { 'present' } else { 'MISSING - needed for menu 4/5 (GPO, WMI filters)' }
    Write-NSPConsoleLine "  ActiveDirectory module : $adText" -Role $(if ($st.ActiveDirectory) { 'Success' } else { 'Warning' })
    Write-NSPConsoleLine "  GroupPolicy module     : $gpText" -Role $(if ($st.GroupPolicy) { 'Success' } else { 'Warning' })
    Write-Host ''
    if (Read-NSPConfirm -Prompt 'Proceed?' -DefaultYes) { Install-NSPADPrerequisite }
    Wait-NSPADReturn
}

function Invoke-NSPADMenuScaffold {
    Write-NSPADScreen 'Stand up the VPN group/OU scaffold'
    if (-not (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
        Write-NSPConsoleLine '  ActiveDirectory module not available - run menu 1 (Install RSAT) first.' -Role Error
        Wait-NSPADReturn; return
    }
    $clientAnswers = Get-NSPADScaffoldAnswers
    Write-Host ''
    Write-NSPConsoleLine '  Pick the base OU everything gets created under:' -Role Heading
    $baseOU = Select-NSPADOrganizationalUnit
    if (-not $baseOU) {
        Write-NSPConsoleLine '  Cancelled - no OU selected.' -Role Muted
        Wait-NSPADReturn; return
    }
    $plan = Get-NSPADScaffoldPlan -ClientAnswers $clientAnswers -BaseOU $baseOU
    Write-Host "`n  About to create:" -ForegroundColor Cyan
    Show-NSPADScaffoldPlan -Plan $plan
    if (Read-NSPConfirm -Prompt 'Create/update this scaffold now?' -DefaultYes) {
        New-NSPADVpnGroupScaffold -Plan $plan
        Write-NSPConsoleLine "`n  Done." -Role Success
    }
    Wait-NSPADReturn
}

function Show-NSPADScaffoldPlan {
    param([Parameter(Mandatory)]$Plan)
    Write-Host ''
    Write-Host "  $($Plan.BaseOU)" -ForegroundColor Gray
    Write-Host '    VPNGroups\' -ForegroundColor White
    Write-Host "      $($Plan.MainGroupName)" -ForegroundColor Green
    Write-Host '      FWRules\' -ForegroundColor White
    foreach ($pg in $Plan.PurposeGroups) { Write-Host "        $($pg.Name)   ($($pg.Key))" -ForegroundColor Green }
    Write-Host ''
}

function Invoke-NSPADMenuNestGroup {
    Write-NSPADScreen 'Nest a group into the shared VPNFW purpose groups'
    if (-not (Get-Command Get-ADGroup -ErrorAction SilentlyContinue)) {
        Write-NSPConsoleLine '  ActiveDirectory module not available - run menu 1 (Install RSAT) first.' -Role Error
        Wait-NSPADReturn; return
    }
    Write-NSPConsoleLine '  Pick the FWRules\ OU the purpose groups live under:' -Role Heading
    $fwRulesOU = Select-NSPADOrganizationalUnit
    if (-not $fwRulesOU) {
        Write-NSPConsoleLine '  Cancelled - no OU selected.' -Role Muted
        Wait-NSPADReturn; return
    }
    $purposeGroups = @(Get-ADGroup -SearchBase $fwRulesOU -SearchScope OneLevel -Filter * -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $purposeGroups.Count) {
        Write-NSPConsoleLine "  No groups found directly under '$fwRulesOU' - run menu 2 first, or pick a different OU." -Role Warning
        Wait-NSPADReturn; return
    }
    $memberName = Read-NSPNonEmpty -Prompt 'AD group to nest (exact name)'
    $memberGroup = Get-ADGroup -Filter "Name -eq '$($memberName.Replace("'", "''"))'" -ErrorAction SilentlyContinue
    if (-not $memberGroup) {
        Write-NSPConsoleLine "  No group named '$memberName' found - nothing nested." -Role Warning
        Wait-NSPADReturn; return
    }
    Write-Host ''
    for ($i = 0; $i -lt $purposeGroups.Count; $i++) { Write-Host ('    {0}. {1}' -f ($i + 1), $purposeGroups[$i].Name) }
    Write-Host ''
    $sel = Read-NSPOptional -Prompt "Numbers to nest '$memberName' into (comma-separated), or blank to cancel"
    $picked = @($sel -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 } |
            Where-Object { $_ -ge 0 -and $_ -lt $purposeGroups.Count } | ForEach-Object { $purposeGroups[$_] })
    if (-not $picked.Count) {
        Write-NSPConsoleLine '  Nothing selected - cancelled.' -Role Muted
        Wait-NSPADReturn; return
    }
    foreach ($pg in $picked) { Add-NSPADGroupMember -GroupIdentity $pg.DistinguishedName -MemberIdentity $memberGroup.DistinguishedName }
    Wait-NSPADReturn
}

function Invoke-NSPADMenuAutoEnrollGpo {
    Write-NSPADScreen 'Push the certificate auto-enrollment GPO'
    if (-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)) {
        Write-NSPConsoleLine '  GroupPolicy module not available - run menu 1 (Install RSAT) first.' -Role Error
        Wait-NSPADReturn; return
    }
    $gpoName = Read-NSPNonEmpty -Prompt 'GPO name' -CurrentValue 'NSP - Certificate Auto-Enrollment'
    Write-Host ''
    Write-Host "  GPO: $gpoName   (dedicated - Default Domain Policy is not touched)" -ForegroundColor White
    Write-Host '  Linked at the domain root.' -ForegroundColor Gray
    foreach ($v in (Get-NSPADAutoEnrollGpoPlan)) {
        Write-Host ('    [{0}] {1}\{2} = {3} ({4})' -f $v.Hive, $v.Key, $v.ValueName, $v.Value, $v.Type) -ForegroundColor Gray
    }
    Write-Host '    AEPolicy 7 = enrolled + renew/update/remove-revoked + update-templates' -ForegroundColor DarkGray
    if (Read-NSPConfirm -Prompt "`nProceed?" -DefaultYes) { New-NSPADAutoEnrollGpo -GpoName $gpoName }
    Wait-NSPADReturn
}

function Invoke-NSPADMenuWmiFilters {
    Write-NSPADScreen 'Stand up the well-known WMI filters'
    if (-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)) {
        Write-NSPConsoleLine '  GroupPolicy module not available - run menu 1 (Install RSAT) first.' -Role Error
        Wait-NSPADReturn; return
    }
    $filters = @(Get-NSPADWellKnownWmiFilter)
    Write-NSPConsoleLine '  Will create/update:' -Role Heading
    foreach ($f in $filters) { Write-Host "    $($f.Name)" -ForegroundColor Gray }
    if (-not (Read-NSPConfirm -Prompt "`nProceed?" -DefaultYes)) { Wait-NSPADReturn; return }
    try {
        Install-NSPADWmiFilterModule
        foreach ($f in $filters) { New-NSPADWmiFilter -Filter $f }
        Write-NSPConsoleLine "`n  Done." -Role Success
    } catch {
        Write-NSPConsoleLine "`n  ERROR: $($_.Exception.Message)" -Role Error
    }
    Wait-NSPADReturn
}

function Invoke-NSPADMenuVpnInventory {
    Write-NSPADScreen 'Export VPN documentation inventory (read-only)'
    Write-NSPConsoleLine '  Collects VPN groups (members, nesting, SIDs), client-auth certificate templates' -Role Muted
    Write-NSPConsoleLine '  (Enroll/AutoEnroll groups), and TameMyCerts OU stamps into one hand-off file.' -Role Muted
    Write-NSPConsoleLine '  Run on the CA/NPS server when possible: ias.xml and the TameMyCerts policy folder are found automatically.' -Role Muted
    Write-Host ''

    $patterns = Read-NSPNonEmpty -Prompt 'Group name patterns (comma-separated)' -CurrentValue 'IKEv2*, VPNFW*, FGT*'
    $groupPattern = @($patterns -split '\s*,\s*' | Where-Object { $_ })

    $npsPath = ''
    if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\ias\ias.xml'))) {
        $answer = (Read-NSPOptional -Prompt "Path to a copy of the NPS server's ias.xml (blank to skip - NPS-named groups then rely on the patterns)").Trim('"')
        if ($answer -and (Test-Path -LiteralPath $answer)) { $npsPath = $answer }
    }
    $policyDirectory = ''
    if (-not (Get-ADInvTameMyCertsDirectory)) {
        $answer = (Read-NSPOptional -Prompt 'TameMyCerts policy folder (blank to skip - OU stamps are then left out)').Trim('"')
        if ($answer -and (Test-Path -LiteralPath $answer)) { $policyDirectory = $answer }
    }
    $savedCompany = if ($script:ADAnswers -and $script:ADAnswers.PSObject.Properties['CompanyName']) { [string]$script:ADAnswers.CompanyName } else { '' }
    $company = Read-NSPNonEmpty -Prompt 'Client (company) name for the file' -CurrentValue $savedCompany
    $outputDirectory = Read-NSPNonEmpty -Prompt 'Output folder' -CurrentValue (Get-NSPToolWorkPath -Tool AD -Kind Responses)

    try {
        $result = Export-NSPADVpnInventory -OutputDirectory $outputDirectory -Company $company -GroupPattern $groupPattern -NpsConfigPath $npsPath -PolicyDirectory $policyDirectory
        Write-Host ''
        Write-NSPConsoleLine ('  Groups: {0}   Templates: {1}   TameMyCerts policies: {2}' -f $result.Groups, $result.Templates, $result.TameMyCertsPolicies) -Role Success
        Write-NSPConsoleLine "  Written: $($result.Path)" -Role Success
        Write-NSPConsoleLine "  Copy it to the Orchestrator's Staging\<Client>\Inbox\ folder (with the ias.xml for the VPN report)." -Role Heading
        Write-NSPConsoleLine '  Opening the folder in Explorer (accept the access prompt if one appears).' -Role Muted
        Open-NSPOutputFolder -Path $result.Path
    } catch {
        Write-NSPConsoleLine "`n  ERROR: $($_.Exception.Message)" -Role Error
    }
    Wait-NSPADReturn
}

function Invoke-NSPADMenuLegacyCleanup {
    Write-NSPADScreen 'Clean up old AD-Manager (zip) files'
    Write-NSPConsoleLine '  Moves answers and hand-off files the zip-era AD-Manager left on this server into' -Role Muted
    Write-NSPConsoleLine "  $(Get-NSPToolWorkPath -Tool AD), then removes the old copies (you are asked first)." -Role Muted
    $summary = Move-NSPToolLegacyData -Tool AD
    if ($summary.Found) { $script:ADAnswers = Get-NSPToolAnswers -Tool AD }
    Wait-NSPADReturn
}
