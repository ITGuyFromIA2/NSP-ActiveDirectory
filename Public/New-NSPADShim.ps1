function New-NSPADShim {
    <#
    .SYNOPSIS
        Writes a launcher script for AD Manager - optionally carrying a client's answers - to drop on
        a domain controller or management server and run.

    .DESCRIPTION
        The launcher installs NSP.ActiveDirectory (this version or newer) and the NSP modules it
        uses from the PowerShell Gallery, hands the answers to Start-NSPADManager once, blanks them
        from its own file, and starts the dashboard. See New-NSPToolShim (NSP.ClientScripts).

        Answer fields the dashboard uses: CompanyName, Auth_UserGroup_Value (the main VPN group),
        VPNFW_DNS_Mode, VPNFW_DCComms_GroupName, VPNFW_SMB_GroupName, VPNFW_RDS_GroupName,
        VPNFW_DNS_GroupName. Other fields are kept as-is.

    .PARAMETER Answers
        Hashtable, object or JSON string. Optional: without it the launcher just starts the tool.

    .PARAMETER Path
        Where to write the launcher (.ps1).

    .PARAMETER Company
        Shown in the launcher header; defaults to Answers.CompanyName.

    .PARAMETER GeneratedBy
        Shown in the launcher header, e.g. 'Orchestrator 4.1.0'.

    .PARAMETER Force
        Overwrite an existing file.

    .EXAMPLE
        New-NSPADShim -Answers @{ CompanyName = 'Example Co'; Auth_UserGroup_Value = 'VPN_Staff' } -Path C:\Temp\AD-Manager.ps1
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([IO.FileInfo])]
    param(
        [object]$Answers,
        [Parameter(Mandatory)][string]$Path,
        [string]$Company,
        [string]$GeneratedBy,
        [switch]$Force
    )

    Import-NSPToolkitModule -Name NSP.ClientScripts -MinimumVersion 0.1.0
    if ($Answers -is [string]) {
        try { $Answers = ConvertFrom-Json -InputObject $Answers -ErrorAction Stop }
        catch { throw "-Answers is not valid JSON: $($_.Exception.Message)" }
    }
    if (-not $Company -and $Answers) {
        $Company = if ($Answers -is [Collections.IDictionary]) { [string]$Answers['CompanyName'] } elseif ($Answers.PSObject.Properties['CompanyName']) { [string]$Answers.CompanyName } else { '' }
    }

    $version = Get-NSPADModuleVersion
    $shim = @{
        ToolName             = 'AD Manager'
        ModuleName           = 'NSP.ActiveDirectory'
        ModuleMinimumVersion = $version
        EntryFunction        = 'Start-NSPADManager'
        Modules              = @(
            @{ Name = 'NSP.Console'; MinimumVersion = '0.1.2' }
            @{ Name = 'NSP.Toolkit'; MinimumVersion = '0.1.0' }
            @{ Name = 'NSP.ActiveDirectory'; MinimumVersion = $version }
        )
        Path                 = $Path
        Force                = $Force
    }
    if ($null -ne $Answers) { $shim['SeedAnswers'] = $Answers }
    if ($Company) { $shim['Company'] = $Company }
    if ($GeneratedBy) { $shim['GeneratedBy'] = $GeneratedBy }

    if ($PSCmdlet.ShouldProcess($Path, 'Write AD Manager launcher')) {
        New-NSPToolShim @shim -Confirm:$false
    }
}
