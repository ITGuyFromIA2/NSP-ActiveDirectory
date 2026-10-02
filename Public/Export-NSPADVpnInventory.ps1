function Export-NSPADVpnInventory {
    <#
    .SYNOPSIS
        Runs Get-NSPADVpnInventory and writes it to a file: by default an AD Response hand-off
        (<Company>_AD_Response.json) for the IPSec Orchestrator's Inbox, or with -Format Legacy the
        bare ADInventory_<domain>_<timestamp>.json NSP.FortiGate's -AdInventory reads directly.
    .DESCRIPTION
        The inventory inside the hand-off is unchanged (SchemaVersion 1), so the Orchestrator can
        unwrap it for the VPN report. Returns Path, Groups, Templates, TameMyCertsPolicies, NpsConfigPath.
    .PARAMETER OutputDirectory
        Folder to write into. Defaults to the AD tool's work folder (Responses).
    .PARAMETER Company
        Client name for the hand-off header and file name (Handoff format).
    .PARAMETER Format
        Handoff (default) or Legacy.
    .EXAMPLE
        Export-NSPADVpnInventory -Company 'Example Co'
    .EXAMPLE
        Export-NSPADVpnInventory -Format Legacy -OutputDirectory C:\Temp
    #>
    [CmdletBinding()]
    param(
        [string]$OutputDirectory,
        [string]$Company = '',
        [ValidateSet('Handoff', 'Legacy')][string]$Format = 'Handoff',
        [string[]]$GroupPattern = @('IKEv2*', 'VPNFW*', 'FGT*'),
        [string]$TemplatePattern,
        [string]$NpsConfigPath,
        [string]$PolicyDirectory
    )
    if ($Format -eq 'Handoff' -or -not $OutputDirectory) { Use-NSPADDependency }
    if (-not $OutputDirectory) { $OutputDirectory = Get-NSPToolWorkPath -Tool AD -Kind Responses -Create }

    $inventory = Get-NSPADVpnInventory -GroupPattern $GroupPattern -TemplatePattern $TemplatePattern -NpsConfigPath $NpsConfigPath -PolicyDirectory $PolicyDirectory
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

    if ($Format -eq 'Legacy') {
        $domain = if ($inventory.Domain) { $inventory.Domain } else { 'domain' }
        $path = Join-Path $OutputDirectory ('ADInventory_{0}_{1}.json' -f $domain, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        [IO.File]::WriteAllText($path, ($inventory | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    } else {
        $handoff = New-NSPHandoff -Kind Response -Tool AD -Company $Company -Payload $inventory -PayloadSchema 1 `
            -ToolVersion (Get-NSPADModuleVersion) -GeneratedBy "NSP.ActiveDirectory $(Get-NSPADModuleVersion)" -Domain ([string]$inventory.Domain)
        $path = (Export-NSPHandoff -Handoff $handoff -Directory $OutputDirectory).FullName
    }
    [pscustomobject]@{
        Path                = $path
        Groups              = @($inventory.Groups).Count
        Templates           = @($inventory.Templates).Count
        TameMyCertsPolicies = @($inventory.TameMyCerts.Policies).Count
        NpsConfigPath       = $NpsConfigPath
    }
}
