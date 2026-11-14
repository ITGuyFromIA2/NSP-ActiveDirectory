<#
    The -AsResult paths of the write functions (rank 4). Each public function hands over to one of
    these at its top when -AsResult is given, so the default path - and its return values - stay
    exactly as before. Contract and invariants: WriteOutcome.ps1.

    Every directory write here uses -ErrorAction Stop, so a non-terminating cmdlet error can never
    count as a write that worked. Every Created/Updated is decided by a fresh read after the write.
#>

function Test-NSPADIdentityNotFound {
    # True for the AD module's "no such object" exception (by type name: RSAT may be absent).
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.GetType().Name -eq 'ADIdentityNotFoundException') { return $true }
        $ex = $ex.InnerException
    }
    return $false
}

function Get-NSPADOutcomeOu {
    # The OU at exactly $DN, or $null when it does not exist. Any other failure throws.
    param([string]$DN, [hashtable]$Srv)
    try { return (Get-ADOrganizationalUnit -Identity $DN -Properties Description @Srv -ErrorAction Stop) }
    catch { if (Test-NSPADIdentityNotFound $_) { return $null } throw }
}

function Invoke-NSPADOrganizationalUnitOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$Name, [string]$Path, [string]$Description, [string]$Server)
    $dn = "OU=$Name,$Path"
    $srv = Get-NSPADServerSplat -Server $Server
    Invoke-NSPADOutcome -Operation 'New-NSPADOrganizationalUnit' -Target $dn -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess($dn, 'Create the organizational unit if it is missing')) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Get-ADOrganizationalUnit
        $existing = Get-NSPADOutcomeOu -DN $dn -Srv $srv
        if ($existing) {
            # A planned description is a planned property: an OU without it is not "already present".
            if ($Description -and "$($existing.Description)" -ne $Description) { throw (New-NSPADCodedError Conflict "OU '$dn' exists with a different description.") }
            Write-Host "  OU '$dn' already exists - skipping create." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$($existing.DistinguishedName)"; ObservedMatch = $true }
        }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Create OU '$Name' under $Path" `
            -Commands @("New-ADOrganizationalUnit -Name '$Name' -Path '$Path'$(Format-NSPADServerArg $Server)") `
            -Action {
                $params = @{ Name = $Name; Path = $Path; ErrorAction = 'Stop' } + $srv
                if ($Description) { $params['Description'] = $Description }
                New-ADOrganizationalUnit @params | Out-Null
            }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = Get-NSPADOutcomeOu -DN $dn -Srv $srv
        if (-not $after -or "$($after.DistinguishedName)" -ne $dn) { throw (New-NSPADCodedError ReadBackFailed "OU '$dn' was created but cannot be read back.") }
        @{ Outcome = 'Created'; ObservedTarget = "$($after.DistinguishedName)"; ObservedMatch = $true }
    }
}

function Invoke-NSPADGroupOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$Name, [string]$Path, [string]$GroupScope, [string]$GroupCategory, [string]$SamAccountName, [string]$Description, [string]$Server)
    $planned = "CN=$Name,$Path"
    $srv = Get-NSPADServerSplat -Server $Server
    $sam = if ($SamAccountName) { $SamAccountName } else { $Name -replace '[^A-Za-z0-9_\-]', '' }
    $filter = "(&(objectClass=group)(sAMAccountName=$(ConvertTo-NSPADLdapFilterValue -Value $sam)))"
    Invoke-NSPADOutcome -Operation 'New-NSPADGroup' -Target $planned -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess($planned, 'Create the group if it is missing')) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Get-ADGroup
        $existing = @(Get-ADGroup -LDAPFilter $filter @srv -ErrorAction Stop)
        if ($existing.Count -gt 1) { throw (New-NSPADCodedError Conflict "More than one group has sAMAccountName '$sam'.") }
        if ($existing.Count -eq 1) {
            $g = $existing[0]
            # Same name is not enough: it must be the planned object (N4: a built-in group can share the name).
            if ("$($g.DistinguishedName)" -ne $planned -or "$($g.GroupScope)" -ne $GroupScope -or "$($g.GroupCategory)" -ne $GroupCategory) {
                throw (New-NSPADCodedError Conflict "Group '$sam' already exists as $($g.DistinguishedName) ($($g.GroupScope) $($g.GroupCategory)), not as planned.")
            }
            Write-Host "  Group '$sam' already exists ($($g.DistinguishedName)) - skipping create." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$($g.DistinguishedName)"; ObservedMatch = $true }
        }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Create AD group '$Name' ($GroupScope $GroupCategory) under $Path" `
            -Commands @("New-ADGroup -Name '$Name' -SamAccountName '$sam' -GroupScope $GroupScope -GroupCategory $GroupCategory -Path '$Path'$(Format-NSPADServerArg $Server)") `
            -Action {
                $params = @{ Name = $Name; SamAccountName = $sam; GroupScope = $GroupScope; GroupCategory = $GroupCategory; Path = $Path; ErrorAction = 'Stop' } + $srv
                if ($Description) { $params['Description'] = $Description }
                New-ADGroup @params | Out-Null
            }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = @(Get-ADGroup -LDAPFilter $filter @srv -ErrorAction Stop)
        if ($after.Count -ne 1 -or "$($after[0].DistinguishedName)" -ne $planned -or "$($after[0].GroupScope)" -ne $GroupScope -or "$($after[0].GroupCategory)" -ne $GroupCategory) {
            throw (New-NSPADCodedError ReadBackFailed "Group '$sam' was created but the read-back does not show it as planned.")
        }
        @{ Outcome = 'Created'; ObservedTarget = "$($after[0].DistinguishedName)"; ObservedMatch = $true }
    }
}

function Invoke-NSPADGroupMemberOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$GroupIdentity, [string]$MemberIdentity, [string]$Server)
    $srv = Get-NSPADServerSplat -Server $Server
    $isMember = { param($m) $m.DistinguishedName -eq $MemberIdentity -or $m.SamAccountName -eq $MemberIdentity -or $m.Name -eq $MemberIdentity }
    Invoke-NSPADOutcome -Operation 'Add-NSPADGroupMember' -Target "$MemberIdentity -> $GroupIdentity" -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess("$GroupIdentity", "Add member '$MemberIdentity' if it is not one already")) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Get-ADGroupMember
        $found = @(Get-ADGroupMember -Identity $GroupIdentity @srv -ErrorAction Stop | Where-Object { & $isMember $_ })
        if ($found.Count -gt 0) {
            Write-Host "  '$MemberIdentity' is already a member of '$GroupIdentity' - skipping." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$($found[0].DistinguishedName) -> $GroupIdentity"; ObservedMatch = $true }
        }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Nest '$MemberIdentity' into '$GroupIdentity'" `
            -Commands @("Add-ADGroupMember -Identity '$GroupIdentity' -Members '$MemberIdentity'$(Format-NSPADServerArg $Server)") `
            -Action { Add-ADGroupMember -Identity $GroupIdentity -Members $MemberIdentity @srv -ErrorAction Stop }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = @(Get-ADGroupMember -Identity $GroupIdentity @srv -ErrorAction Stop | Where-Object { & $isMember $_ })
        if (-not $after.Count) { throw (New-NSPADCodedError ReadBackFailed "'$MemberIdentity' was added but is not listed as a member of '$GroupIdentity'.") }
        @{ Outcome = 'Created'; ObservedTarget = "$($after[0].DistinguishedName) -> $GroupIdentity"; ObservedMatch = $true }
    }
}

function Invoke-NSPADGpoLinkOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$GpoName, [string]$TargetDN, [string]$Server)
    $srv = Get-NSPADServerSplat -Server $Server
    $target = "$GpoName @ $TargetDN"
    Invoke-NSPADOutcome -Operation 'New-NSPADGpoLink' -Target $target -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess("$TargetDN", "Link GPO '$GpoName'")) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy'
        if (Test-NSPADGpoLinked -GpoName $GpoName -TargetDN $TargetDN -Server $Server) {
            Write-Host "  '$GpoName' is already linked at '$TargetDN' - skipping." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = $target; ObservedMatch = $true }
        }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Link GPO '$GpoName' at $TargetDN" `
            -Commands @("New-GPLink -Name '$GpoName' -Target '$TargetDN' -LinkEnabled Yes$(Format-NSPADServerArg $Server)") `
            -Action { New-GPLink -Name $GpoName -Target $TargetDN -LinkEnabled Yes @srv -ErrorAction Stop | Out-Null }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        if (-not (Test-NSPADGpoLinked -GpoName $GpoName -TargetDN $TargetDN -Server $Server)) { throw (New-NSPADCodedError ReadBackFailed "GPO '$GpoName' was linked but the link is not visible at $TargetDN.") }
        @{ Outcome = 'Created'; ObservedTarget = $target; ObservedMatch = $true }
    }
}

function Invoke-NSPADGpoWmiFilterOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$GpoName, [string]$WmiFilterName, [bool]$Clear, [string]$Server)
    $srv = Get-NSPADServerSplat -Server $Server
    $want = if ($Clear) { '' } else { $WmiFilterName }
    $action = if ($Clear) { 'Remove the WMI filter' } else { "Apply WMI filter '$WmiFilterName'" }
    $target = "$GpoName : $(if ($Clear) { '<no WMI filter>' } else { $WmiFilterName })"
    $filterOf = { param($g) if ($g -and $g.PSObject.Properties['WmiFilter'] -and $g.WmiFilter) { "$($g.WmiFilter.Name)" } else { '' } }
    Invoke-NSPADOutcome -Operation 'Set-NSPADGpoWmiFilter' -Target $target -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess($GpoName, $action)) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy (RSAT)'
        $domain = Get-ADDomain @srv -ErrorAction Stop
        $gpo = Get-GPO -Name $GpoName @srv -ErrorAction Stop
        $id = ''
        if (-not $Clear) {
            $filter = Get-NSPADWmiSomEntry -DomainDN "$($domain.DistinguishedName)" -Server $Server | Where-Object { $_.Name -eq $WmiFilterName } | Select-Object -First 1
            if (-not $filter) { throw (New-NSPADCodedError NotFound "WMI filter '$WmiFilterName' does not exist - create it first (New-NSPADWmiFilter).") }
            $id = $filter.Id
        }
        if ((& $filterOf $gpo) -eq $want) {
            Write-Host "  '$GpoName' already has the requested WMI filter setting - skipping." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = $target; ObservedMatch = $true }
        }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "$action on GPO '$GpoName'" `
            -Commands @("[ADSI] gPCWQLFilter on $(Get-NSPADAdsiPath -DistinguishedName "CN={$($gpo.Id)},CN=Policies,CN=System,$($domain.DistinguishedName)" -Server $Server)") `
            -Action { Set-NSPADGpoWqlFilterAttribute -DomainDN "$($domain.DistinguishedName)" -DnsRoot "$($domain.DNSRoot)" -GpoGuid "$($gpo.Id)" -WmiFilterId $id -Server $Server }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        if ((& $filterOf (Get-GPO -Name $GpoName @srv -ErrorAction Stop)) -ne $want) { throw (New-NSPADCodedError ReadBackFailed "GPO '$GpoName' does not show the requested WMI filter after the write.") }
        @{ Outcome = 'Updated'; ObservedTarget = $target; ObservedMatch = $true }
    }
}

function Invoke-NSPADWmiFilterOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, $Filter, [string]$Server)
    $srv = Get-NSPADServerSplat -Server $Server
    $want = @($Filter.Expression)
    $matches_ = { param($e) $e -and -not (Compare-Object -ReferenceObject @($e.Query) -DifferenceObject $want -SyncWindow 0) -and "$($e.Description)".Trim() -eq "$($Filter.Description)".Trim() }
    Invoke-NSPADOutcome -Operation 'New-NSPADWmiFilter' -Target "$($Filter.Name)" -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess("$($Filter.Name)", 'Create the WMI filter if it is missing')) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        $domain = Get-ADDomain @srv -ErrorAction Stop
        $domainDn = "$($domain.DistinguishedName)"
        $existing = Get-NSPADWmiSomEntry -DomainDN $domainDn -Server $Server | Where-Object { $_.Name -eq $Filter.Name } | Select-Object -First 1
        if (& $matches_ $existing) {
            Write-Host "  WMI filter '$($Filter.Name)' already exists and matches - skipping." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$($existing.DN)"; ObservedMatch = $true }
        }
        $verb = if ($existing) { 'Update' } else { 'Create' }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "$verb WMI filter '$($Filter.Name)'" `
            -Commands @("[ADSI] msWMI-Som under $(Get-NSPADAdsiPath -DistinguishedName "CN=SOM,CN=WMIPolicy,CN=System,$domainDn" -Server $Server)") `
            -Action { Save-NSPADWmiSomEntry -DomainDN $domainDn -DnsRoot "$($domain.DNSRoot)" -Name $Filter.Name -Description $Filter.Description -Query $want -DN $(if ($existing) { $existing.DN }) -Server $Server }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = Get-NSPADWmiSomEntry -DomainDN $domainDn -Server $Server | Where-Object { $_.Name -eq $Filter.Name } | Select-Object -First 1
        if (-not (& $matches_ $after)) { throw (New-NSPADCodedError ReadBackFailed "WMI filter '$($Filter.Name)' does not read back as written.") }
        @{ Outcome = $(if ($existing) { 'Updated' } else { 'Created' }); ObservedTarget = "$($after.DN)"; ObservedMatch = $true }
    }
}

function Invoke-NSPADGpoBackupOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$Path, [string]$TargetName, [string]$WmiFilterName, [bool]$LinkAtDomainRoot, [Collections.IDictionary]$Replace, [string]$Server)
    $srv = Get-NSPADServerSplat -Server $Server
    $planName = if ($TargetName) { $TargetName } else { $Path }
    Invoke-NSPADOutcome -Operation 'Import-NSPADGpoBackup' -Target $planName -Server $Server -Body {
        param($ctx)
        Assert-NSPADCommand Import-GPO -ModuleHint 'GroupPolicy (RSAT)'
        if (-not (Test-Path -LiteralPath $Path)) { throw (New-NSPADCodedError NotFound 'The GPO backup path does not exist.') }
        $work = Join-Path ([IO.Path]::GetTempPath()) ('NSPGpoImport_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force -WhatIf:$false | Out-Null
        try {
            if ((Get-Item -LiteralPath $Path).PSIsContainer) { Copy-Item -LiteralPath $Path -Destination $work -Recurse -Force -WhatIf:$false; $src = Join-Path $work (Split-Path -Leaf $Path) }
            else { Expand-Archive -LiteralPath $Path -DestinationPath $work -Force -WhatIf:$false; $src = $work }
            $info = Get-ChildItem -LiteralPath $src -Recurse -Force -File -Filter 'bkupInfo.xml' | Select-Object -First 1
            if (-not $info) { throw (New-NSPADCodedError NotFound 'No GPO backup (bkupInfo.xml) at that path.') }
            $backup = Get-NSPADGpoBackupInfo -BackupFolder $info.DirectoryName
            $name = if ($TargetName) { $TargetName } else { $backup.DisplayName }
            if (-not $Cmdlet.ShouldProcess($name, "Import GPO backup '$($backup.DisplayName)'")) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }

            $names = Get-NSPADGpoDomainNames -Server $Server
            foreach ($key in 'Pdc', 'Dns', 'NetBios') {
                if ([string]::IsNullOrWhiteSpace("$($names[$key])")) { throw (New-NSPADCodedError PreconditionFailed "This domain's $key name could not be read.") }
            }
            $domainDn = "$((Get-ADDomain @srv -ErrorAction Stop).DistinguishedName)"
            if ([string]::IsNullOrWhiteSpace($domainDn)) { throw (New-NSPADCodedError PreconditionFailed "This domain's distinguished name could not be read.") }
            if ($WmiFilterName -and -not (Get-NSPADWmiSomEntry -DomainDN $domainDn -Server $Server | Where-Object { $_.Name -eq $WmiFilterName } | Select-Object -First 1)) {
                throw (New-NSPADCodedError NotFound "WMI filter '$WmiFilterName' does not exist - create it first.")
            }
            # One gate in this mode: Import-GPO is a directory write too, so a dry run previews the
            # whole import instead of importing and then previewing only the filter and link.
            if (Get-NSPDryRun) {
                Write-Host "  [DRY RUN] Import GPO backup '$($backup.DisplayName)' as '$name'$(if ($WmiFilterName) { ", WMI filter '$WmiFilterName'" })$(if ($LinkAtDomainRoot) { ', link at the domain root' })" -ForegroundColor Cyan
                return @{ Outcome = 'Previewed' }
            }
            $existedBefore = [bool](Get-GPO -Name $name @srv -ErrorAction SilentlyContinue)

            $ctx.Phase = 'Write'
            Convert-NSPADGpoBackupFolder -BackupRoot $backup.BackupRoot -From $script:NSPADGpoPlaceholder -To $names
            if ($Replace -and $Replace.Count) { Convert-NSPADGpoBackupToken -BackupRoot $backup.BackupRoot -Replace $Replace }
            $null = Import-GPO -BackupId $backup.BackupId -Path $backup.BackupRoot -TargetName $name -CreateIfNeeded @srv -ErrorAction Stop
            if ($WmiFilterName) { Set-NSPADGpoWmiFilter -GpoName $name -WmiFilterName $WmiFilterName @srv -Confirm:$false }
            if ($LinkAtDomainRoot) { New-NSPADGpoLink -GpoName $name -TargetDN $domainDn @srv -Confirm:$false }

            $ctx.Phase = 'ReadBack'
            $after = Get-GPO -Name $name @srv -ErrorAction Stop
            if (-not $after) { throw (New-NSPADCodedError ReadBackFailed "GPO '$name' is not visible after the import.") }
            if ($WmiFilterName) {
                $f = if ($after.PSObject.Properties['WmiFilter'] -and $after.WmiFilter) { "$($after.WmiFilter.Name)" } else { '' }
                if ($f -ne $WmiFilterName) { throw (New-NSPADCodedError ReadBackFailed "GPO '$name' does not show WMI filter '$WmiFilterName'.") }
            }
            if ($LinkAtDomainRoot -and -not (Test-NSPADGpoLinked -GpoName $name -TargetDN $domainDn -Server $Server)) {
                throw (New-NSPADCodedError ReadBackFailed "GPO '$name' is not linked at the domain root after the import.")
            }
            return @{ Outcome = $(if ($existedBefore) { 'Updated' } else { 'Created' }); ObservedTarget = "$($after.DisplayName)"; ObservedMatch = $true }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}

function Invoke-NSPADAutoEnrollGpoOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$GpoName, [bool]$IncludeComputerConfig, [string]$DomainDn, [string]$Server)
    $srv = Get-NSPADServerSplat -Server $Server
    Invoke-NSPADOutcome -Operation 'New-NSPADAutoEnrollGpo' -Target $GpoName -Server $Server -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess("$GpoName", 'Create the certificate auto-enrollment GPO and link it at the domain root')) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Get-GPO -ModuleHint 'GroupPolicy'
        $dn = $DomainDn
        if (-not $dn) { $dn = "$((Get-ADDomain @srv -ErrorAction Stop).DistinguishedName)" }   # no logon-domain guess in this mode
        if ($dn -notmatch '^\s*DC=[^,=\s]+') { throw (New-NSPADCodedError PreconditionFailed "The domain's distinguished name could not be read - pass -DomainDn.") }
        $plan = @(Get-NSPADAutoEnrollGpoPlan -IncludeComputerConfig:$IncludeComputerConfig)
        $valuesMatch = {
            foreach ($v in $plan) {
                $cur = Get-GPRegistryValue -Name $GpoName -Key $v.Key -ValueName $v.ValueName @srv -ErrorAction SilentlyContinue
                if (-not $cur -or "$($cur.Value)" -ne "$($v.Value)") { return $false }
            }
            return $true
        }
        $existing = Get-GPO -Name $GpoName @srv -ErrorAction SilentlyContinue
        if ($existing -and (& $valuesMatch) -and (Test-NSPADGpoLinked -GpoName $GpoName -TargetDN $dn -Server $Server)) {
            Write-Host "  GPO '$GpoName' already has every value and is linked - skipping." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$($existing.DisplayName)"; ObservedMatch = $true }
        }
        $dry = Get-NSPDryRun
        $ctx.Phase = 'Write'
        if (-not $existing) {
            $null = Invoke-NSPStep -Description "Create GPO '$GpoName'" -Commands @("New-GPO -Name '$GpoName'$(Format-NSPADServerArg $Server)") `
                -Action { New-GPO -Name $GpoName @srv -ErrorAction Stop | Out-Null }
        }
        $failed = 0
        foreach ($v in $plan) {
            $step = Invoke-NSPStep -Description "Set $($v.Hive) value $($v.ValueName) = $($v.Value)" `
                -Commands @("Set-GPRegistryValue -Name '$GpoName' -Key '$($v.Key)' -ValueName $($v.ValueName) -Type $($v.Type) -Value $($v.Value)$(Format-NSPADServerArg $Server)") `
                -Action { Set-GPRegistryValue -Name $GpoName -Key $v.Key -ValueName $v.ValueName -Type $v.Type -Value $v.Value @srv -ErrorAction Stop | Out-Null } -ContinueOnError
            if ($step.Error) { $failed++ }
        }
        if ($failed) { throw (New-NSPADCodedError WriteFailed "$failed value(s) could not be set; the GPO was not linked.") }
        New-NSPADGpoLink -GpoName $GpoName -TargetDN $dn @srv -Confirm:$false
        if ($dry) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = Get-GPO -Name $GpoName @srv -ErrorAction Stop
        if (-not $after -or -not (& $valuesMatch) -or -not (Test-NSPADGpoLinked -GpoName $GpoName -TargetDN $dn -Server $Server)) {
            throw (New-NSPADCodedError ReadBackFailed "GPO '$GpoName' does not read back with every value and the link.")
        }
        @{ Outcome = $(if ($existing) { 'Updated' } else { 'Created' }); ObservedTarget = "$($after.DisplayName)"; ObservedMatch = $true }
    }
}

function Invoke-NSPADServiceAccountOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$Name, [string[]]$AllowedComputer, [string]$Description, [string]$DNSHostName, [int]$PasswordIntervalDays, [bool]$SkipKdsCheck, $DomainInfo, [string]$Server)
    $bare = $Name.TrimEnd('$')
    # Ambiguous targeting is never a result: it throws before anything is read.
    if ($DomainInfo -and $Server -and "$($DomainInfo.Server)" -ne $Server.Trim()) {
        throw (New-NSPADTerminatingError "-Server '$($Server.Trim())' and -DomainInfo (from '$($DomainInfo.Server)') name different domain controllers. Nothing was changed.")
    }
    $initialServer = if ($DomainInfo) { "$($DomainInfo.Server)" } else { $Server }
    Invoke-NSPADOutcome -Operation 'New-NSPADServiceAccount' -Target $bare -Server $initialServer -Body {
        param($ctx)
        $di = Resolve-NSPADDomainInfoForServer -DomainInfo $DomainInfo -Server $Server
        $ctx.Server = "$($di.Server)"     # every read and the create below go to this DC
        $preview = [bool]$WhatIfPreference
        $computers = @(foreach ($c in $AllowedComputer) {
                $found = Get-NSPADComputer -Name $c -DomainInfo $di
                if (-not $found) {
                    if (-not $preview) { throw (New-NSPADCodedError NotFound "No computer account '$c'.") }
                    Write-Warning "Preview: no computer account '$c'. The real run would stop here."
                    continue
                }
                $found
            })
        $sids = @($computers | ForEach-Object { "$($_.SID)" })
        $existing = Get-NSPADServiceAccount -Name $bare -DomainInfo $di
        if ($existing) {
            $allowed = @($existing.AllowedPrincipals | ForEach-Object { "$($_.Sid)" })
            $missing = @($sids | Where-Object { $allowed -notcontains $_ })
            if ($missing.Count -or $computers.Count -ne $AllowedComputer.Count) { throw (New-NSPADCodedError Conflict "gMSA '$bare' exists but does not list every planned computer directly.") }
            Write-Host "  gMSA '$bare' already exists ($($existing.DistinguishedName)) - skipping create." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$($existing.DistinguishedName)"; ObservedMatch = $true }
        }
        if (-not $SkipKdsCheck) {
            $kds = Get-NSPADKdsRootKeyStatus -DomainInfo $di
            if (-not $kds.Usable) {
                if (-not $preview) { throw (New-NSPADCodedError PreconditionFailed "No usable KDS root key (status $($kds.Status)).") }
                Write-Warning "Preview: no usable KDS root key (status $($kds.Status)). The real run would stop here."
            }
        }
        $hostName = if ($DNSHostName) { $DNSHostName } else { "$bare.$($di.DNSRoot)" }
        if (-not $Cmdlet.ShouldProcess("$($di.NetBIOSName)\$bare`$", "Create gMSA usable by $(@($computers.Name) -join ', ')")) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand New-ADServiceAccount
        $principalDns = @($computers.DistinguishedName)
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Create gMSA '$bare' (usable by $(@($computers.Name) -join ', ')) on $($di.Server)" `
            -Commands @("New-ADServiceAccount -Name '$bare' -DNSHostName '$hostName' -PrincipalsAllowedToRetrieveManagedPassword <$($computers.Count) computer(s)> -ManagedPasswordIntervalInDays $PasswordIntervalDays -KerberosEncryptionType AES128,AES256 -Server '$($di.Server)'") `
            -Action {
                $params = @{
                    Name = $bare; DNSHostName = $hostName; Enabled = $true
                    PrincipalsAllowedToRetrieveManagedPassword = $principalDns
                    ManagedPasswordIntervalInDays = $PasswordIntervalDays
                    KerberosEncryptionType = 'AES128', 'AES256'
                    Server = $di.Server; ErrorAction = 'Stop'
                }
                if ($Description) { $params.Description = $Description }
                New-ADServiceAccount @params | Out-Null
            }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = Get-NSPADServiceAccount -Name $bare -DomainInfo $di
        $allowedAfter = @($after.AllowedPrincipals | ForEach-Object { "$($_.Sid)" })
        if (-not $after -or @($sids | Where-Object { $allowedAfter -notcontains $_ }).Count) { throw (New-NSPADCodedError ReadBackFailed "gMSA '$bare' was created but does not read back with every planned computer.") }
        @{ Outcome = 'Created'; ObservedTarget = "$($after.DistinguishedName)"; ObservedMatch = $true }
    }
}

function Invoke-NSPADInstallServiceAccountOutcome {
    # Local to this computer: Server is always $null.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [string]$Name)
    $bare = $Name.TrimEnd('$')
    Invoke-NSPADOutcome -Operation 'Install-NSPADServiceAccount' -Target "$bare on $env:COMPUTERNAME" -Server $null -Body {
        param($ctx)
        if (-not $Cmdlet.ShouldProcess($env:COMPUTERNAME, "Install gMSA '$bare'")) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        Assert-NSPADCommand Install-ADServiceAccount
        $already = $false
        try { $already = [bool](Test-ADServiceAccount -Identity $bare -ErrorAction Stop) } catch { $already = $false }
        if ($already) {
            Write-Host "  gMSA '$bare' already works on $env:COMPUTERNAME - skipping install." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "$bare on $env:COMPUTERNAME"; ObservedMatch = $true }
        }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Install gMSA '$bare' on $env:COMPUTERNAME" -Commands @("Install-ADServiceAccount -Identity '$bare'") `
            -Action { Install-ADServiceAccount -Identity $bare -ErrorAction Stop }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        if (-not [bool](Test-ADServiceAccount -Identity $bare -ErrorAction Stop)) { throw (New-NSPADCodedError ReadBackFailed "gMSA '$bare' was installed but Test-ADServiceAccount reports it unusable.") }
        @{ Outcome = 'Created'; ObservedTarget = "$bare on $env:COMPUTERNAME"; ObservedMatch = $true }
    }
}

function Invoke-NSPADKdsRootKeyOutcome {
    # The reads go to the DomainInfo DC, but Add-KdsRootKey runs on this computer, so no single DC
    # can be claimed: Server is always $null.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess runs on the public cmdlet passed as -Cmdlet, which declares SupportsShouldProcess.')]
    param($Cmdlet, [datetime]$EffectiveTime, $DomainInfo)
    Invoke-NSPADOutcome -Operation 'New-NSPADKdsRootKey' -Target 'KDS root key' -Server $null -Body {
        param($ctx)
        $di = if ($DomainInfo) { $DomainInfo } else { Get-NSPADDomainInfo }
        $status = Get-NSPADKdsRootKeyStatus -DomainInfo $di
        if ($status.Status -eq 'CannotRead') { throw (New-NSPADCodedError PreconditionFailed 'The KDS root keys could not be read.') }
        if ($status.Visible -gt 0) {
            Write-Host "  The forest already has $($status.Visible) KDS root key(s) - not creating another." -ForegroundColor Gray
            return @{ Outcome = 'AlreadyPresent'; ObservedTarget = "KDS root key ($($status.Visible) visible, forest of $($di.DNSRoot))"; ObservedMatch = $true }
        }
        if (-not $Cmdlet.ShouldProcess("forest of $($di.DNSRoot)", "Create a KDS root key usable from $($EffectiveTime.ToString('u'))")) { return @{ Outcome = (Get-NSPADDeclinedOutcome) } }
        Use-NSPADDependency
        if (-not (Get-Command Add-KdsRootKey -ErrorAction SilentlyContinue)) { throw (New-NSPADCodedError PreconditionFailed 'Add-KdsRootKey is not available on this machine.') }
        $ctx.Phase = 'Write'
        $step = Invoke-NSPStep -Description "Create a KDS root key usable from $($EffectiveTime.ToString('u'))" `
            -Commands @("Add-KdsRootKey -EffectiveTime '$($EffectiveTime.ToString('o'))'") `
            -Action { Add-KdsRootKey -EffectiveTime $EffectiveTime -ErrorAction Stop | Out-Null }
        if (-not $step.Ran) { return @{ Outcome = 'Previewed' } }
        $ctx.Phase = 'ReadBack'
        $after = Get-NSPADKdsRootKeyStatus -DomainInfo $di
        if ($after.Visible -lt 1) { throw (New-NSPADCodedError ReadBackFailed 'Add-KdsRootKey ran, but no KDS root key is visible.') }
        @{ Outcome = 'Created'; ObservedTarget = "KDS root key ($($after.Visible) visible, forest of $($di.DNSRoot))"; ObservedMatch = $true }
    }
}
