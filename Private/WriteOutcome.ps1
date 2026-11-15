<#
    Rank 4: the opt-in -AsResult outcome of a write function (NSP.ActiveDirectory.WriteOutcome).
    Contract agreed with the Catalyst, 2026-11-14 (coordination note
    ..._ad-specialist_rank-4-outcome-contract-review.md). In short:

      Outcome         Created | Updated | AlreadyPresent | Previewed | Skipped | Failed
      ObservedTarget  only what a directory READ returned; never the requested name
      ObservedMatch   Created/Updated: a fresh read AFTER the write matched the plan.
                      AlreadyPresent: the existence read matched identity AND the planned properties.
                      (Exception: New-NSPADKdsRootKey is presence only - "at least one key was
                      read"; -EffectiveTime is not compared and usability is not claimed.)
                      Always False for Previewed, Skipped and Failed.
      Server          the DC every directory call in the call used, or $null when none was pinned
                      (or when part of the work is local, such as Add-KdsRootKey)
      ErrorCode       set only for Failed: PreconditionFailed | NotFound | Conflict | WriteFailed |
                      ReadBackFailed | Unexpected (reserved; nothing produces it yet)

    There is deliberately NO message or exception text on the object, and this module's own
    outcome line prints the operation and the code only. That is NOT the whole host output: a
    write runs as an NSP.Toolkit Invoke-NSPStep, which prints "-> ERROR: <exception message>" for
    a failing step, as it does for every caller. So a transcript of a failed write step can hold
    the directory's own error text. Changing that needs a change in NSP.Toolkit (not decided).

    This is module-local observation. It is NOT a management-plane step result and never sets
    an MP-4 'verified' flag; a caller must check Outcome and take its own fresh read.

    Returned Failed: expected, handled directory / precondition / write / read-back errors.
    Still THROWN: parameter binding and validation, ambiguous targeting (-Server vs -DomainInfo),
    contract violations inside this module, and programmer errors.
#>

$script:NSPADOutcomeValues = @('Created', 'Updated', 'AlreadyPresent', 'Previewed', 'Skipped', 'Failed')
$script:NSPADErrorCodes = @('PreconditionFailed', 'NotFound', 'Conflict', 'WriteFailed', 'ReadBackFailed', 'Unexpected')

function New-NSPADCodedError {
    # An exception that -AsResult turns into Failed with exactly this code (and that a normal call
    # sees as an ordinary exception with the same message).
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message)
    if ($script:NSPADErrorCodes -notcontains $Code) { throw (New-NSPADTerminatingError "Unknown NSP.ActiveDirectory error code '$Code'.") }
    $e = New-Object System.InvalidOperationException $Message
    $e.Data['NSPADErrorCode'] = $Code
    return $e
}

function New-NSPADTerminatingError {
    # An exception that -AsResult must NOT turn into a result: ambiguity or a contract violation.
    param([Parameter(Mandatory)][string]$Message)
    $e = New-Object System.InvalidOperationException $Message
    $e.Data['NSPADTerminate'] = $true
    return $e
}

function New-NSPADWriteOutcome {
    # Builds the outcome and enforces the contract; a violation is a bug here and throws.
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Outcome,
        [AllowNull()][AllowEmptyString()][string]$ObservedTarget,
        [bool]$ObservedMatch,
        [AllowNull()][AllowEmptyString()][string]$Server,
        [AllowNull()][AllowEmptyString()][string]$ErrorCode
    )
    if ($script:NSPADOutcomeValues -cnotcontains $Outcome) { throw (New-NSPADTerminatingError "Outcome '$Outcome' is not one of $($script:NSPADOutcomeValues -join ', ').") }
    $hasCode = -not [string]::IsNullOrEmpty($ErrorCode)
    if (($Outcome -ceq 'Failed') -ne $hasCode) { throw (New-NSPADTerminatingError "Outcome '$Outcome' with ErrorCode '$ErrorCode': Failed needs a code, and only Failed may have one.") }
    if ($hasCode -and $script:NSPADErrorCodes -cnotcontains $ErrorCode) { throw (New-NSPADTerminatingError "ErrorCode '$ErrorCode' is not one of $($script:NSPADErrorCodes -join ', ').") }
    $success = @('Created', 'Updated', 'AlreadyPresent') -ccontains $Outcome
    if ($success -and (-not $ObservedMatch -or [string]::IsNullOrEmpty($ObservedTarget))) { throw (New-NSPADTerminatingError "Outcome '$Outcome' needs a matching directory read (ObservedMatch and ObservedTarget).") }
    if (-not $success -and $ObservedMatch) { throw (New-NSPADTerminatingError "Outcome '$Outcome' cannot have ObservedMatch.") }
    if (@('Previewed', 'Skipped') -ccontains $Outcome -and -not [string]::IsNullOrEmpty($ObservedTarget)) { throw (New-NSPADTerminatingError "Outcome '$Outcome' cannot have an ObservedTarget: nothing was read for it.") }

    [pscustomobject][ordered]@{
        PSTypeName     = 'NSP.ActiveDirectory.WriteOutcome'
        Operation      = $Operation
        Target         = $Target
        Outcome        = $Outcome
        ObservedTarget = $(if ([string]::IsNullOrEmpty($ObservedTarget)) { $null } else { $ObservedTarget })
        ObservedMatch  = [bool]$ObservedMatch
        Server         = $(if ([string]::IsNullOrWhiteSpace($Server)) { $null } else { $Server.Trim() })
        ErrorCode      = $(if ($hasCode) { $ErrorCode } else { $null })
    }
}

function Get-NSPADDeclinedOutcome {
    # ShouldProcess said no: -WhatIf (or an inherited WhatIfPreference) previews; anything else
    # (a declined -Confirm prompt) is Skipped. Read from the calling function's scope.
    if ($WhatIfPreference) { return 'Previewed' }
    return 'Skipped'
}

function Resolve-NSPADErrorCode {
    # $null means "do not turn this into a result - rethrow it".
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord, [Parameter(Mandatory)][string]$Phase)
    $ex = $ErrorRecord.Exception
    while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex.Data -and $ex.Data.Contains('NSPADTerminate')) { return $null }
    if ($ex.Data -and $ex.Data.Contains('NSPADErrorCode')) { return [string]$ex.Data['NSPADErrorCode'] }
    if ($ex -is [System.Management.Automation.ParameterBindingException]) { return $null }
    if ($ex -is [System.Management.Automation.CommandNotFoundException]) { return $null }
    # PowerShell's own "this script is wrong" errors are bugs, not directory results.
    if ("$($ErrorRecord.FullyQualifiedErrorId)" -match '^(InvokeMethodOnNull|MethodNotFound|PropertyNotFoundStrict|VariableIsUndefined|NamedParameterNotFound|PositionalParameterNotFound|MissingArgument|ParameterArgumentValidationError|ParameterArgumentTransformationError)') { return $null }
    switch ($Phase) {
        'Precondition' { return 'PreconditionFailed' }
        'Write' { return 'WriteFailed' }
        'ReadBack' { return 'ReadBackFailed' }
        default { return $null }
    }
}

function Invoke-NSPADOutcome {
    # Runs one -AsResult body. The body gets a context and sets $ctx.Phase to 'Write' before its
    # first change and to 'ReadBack' after it; it must return exactly one hashtable for
    # New-NSPADWriteOutcome (Outcome, and ObservedTarget/ObservedMatch when it read something).
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Target,
        [AllowNull()][AllowEmptyString()][string]$Server,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $ctx = [pscustomobject]@{ Phase = 'Precondition'; Server = $Server }
    try {
        $out = @(& $Body $ctx)
        if ($out.Count -ne 1 -or $out[0] -isnot [hashtable]) {
            throw (New-NSPADTerminatingError "$Operation -AsResult: the body returned $($out.Count) object(s), not one hashtable. This is a bug in NSP.ActiveDirectory.")
        }
        $r = $out[0]
        return (New-NSPADWriteOutcome -Operation $Operation -Target $Target -Server $ctx.Server @r)
    } catch {
        $code = Resolve-NSPADErrorCode -ErrorRecord $_ -Phase $ctx.Phase
        if (-not $code) { throw }
        # No exception text from here: not on the object, not in the lines below. (A failed write
        # step has already printed the directory's error through NSP.Toolkit's Invoke-NSPStep.)
        Write-Host "  $Operation failed ($code). Run it without -AsResult to see the error." -ForegroundColor Red
        # Nothing is ever rolled back. A failed write may have changed part of what was planned
        # (for example some GPO values); a failed read-back may follow a write that worked.
        if ($ctx.Phase -eq 'Write') { Write-Host '  Part of the change may have been made before the failure; nothing was rolled back.' -ForegroundColor Yellow }
        if ($ctx.Phase -eq 'ReadBack') { Write-Host '  The change may already have been made; nothing was rolled back.' -ForegroundColor Yellow }
        return (New-NSPADWriteOutcome -Operation $Operation -Target $Target -Server $ctx.Server -Outcome Failed -ErrorCode $code)
    }
}
