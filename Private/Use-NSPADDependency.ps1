function Use-NSPADDependency {
    # Loads the sibling NSP modules this module's state-changing and interactive functions need.
    # Pure functions (plans, filter tables, inventory helpers) never call this, so they work on a
    # bare host. Returns immediately once the modules are loaded.
    param([switch]$Console, [switch]$Bootstrap)
    Import-NSPToolkitModule -Name NSP.Toolkit -MinimumVersion 0.1.0
    if ($Console) { Import-NSPToolkitModule -Name NSP.Console -MinimumVersion 0.1.2 }
    if ($Bootstrap) { Import-NSPToolkitModule -Name NSP.Bootstrap -MinimumVersion 0.1.3 }
}

function Get-NSPADAnswerValue {
    # A non-blank answer field as a string, or $null (answers may be $null, a hashtable or an object).
    param([AllowNull()]$Answers, [Parameter(Mandatory)][string]$Field)
    if ($null -eq $Answers) { return $null }
    $v = if ($Answers -is [Collections.IDictionary]) { $Answers[$Field] } elseif ($Answers.PSObject.Properties[$Field]) { $Answers.$Field } else { $null }
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { return $null }
    return [string]$v
}

function Assert-NSPADCommand {
    # Throws the standard "install RSAT first" message when an AD/GPO cmdlet is missing.
    param([Parameter(Mandatory)][string]$Name, [string]$ModuleHint = 'ActiveDirectory')
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "The $ModuleHint module (RSAT) is not available on this machine - install it first (Install-NSPADPrerequisite, or menu 1 in Start-NSPADManager)."
    }
}
