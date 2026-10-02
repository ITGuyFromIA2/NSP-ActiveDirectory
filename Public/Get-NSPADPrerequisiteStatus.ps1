function Get-NSPADPrerequisiteStatus {
    <#
    .SYNOPSIS
        Whether the PowerShell modules this module's AD and GPO functions call are installed:
        ActiveDirectory (group/OU scaffold, nesting) and GroupPolicy (GPO, WMI filters).
    .EXAMPLE
        Get-NSPADPrerequisiteStatus
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        ActiveDirectory = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
        GroupPolicy     = [bool](Get-Module -ListAvailable -Name GroupPolicy)
    }
}
