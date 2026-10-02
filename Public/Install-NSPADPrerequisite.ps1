function Install-NSPADPrerequisite {
    <#
    .SYNOPSIS
        Installs the RSAT tooling this module needs (ActiveDirectory + GroupPolicy): Windows features
        on a server, RSAT capabilities on a client OS. Dry-run aware (Invoke-NSPStep).
    .EXAMPLE
        Set-NSPDryRun -Enabled $false; Install-NSPADPrerequisite
    #>
    [CmdletBinding()]
    param()
    Use-NSPADDependency

    $isServer = $true
    try { $isServer = ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1) } catch { Write-Verbose "OS type unknown: $_" }

    if ($isServer -and (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        $features = @('RSAT-AD-PowerShell', 'GPMC')
        $need = @($features | Where-Object { -not (Get-WindowsFeature -Name $_ -ErrorAction SilentlyContinue).Installed })
        if (-not $need.Count) {
            Write-Host "  Already installed: $($features -join ', ')" -ForegroundColor Green
            return
        }
        Invoke-NSPStep -Description "Install management features: $($need -join ', ')" `
            -Commands @("Install-WindowsFeature $($need -join ',') -IncludeManagementTools") `
            -Action { Install-WindowsFeature -Name $need -IncludeManagementTools | Out-String } | Out-Null
    } else {
        $caps = @('Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0', 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0')
        $need = @($caps | Where-Object { (Get-WindowsCapability -Online -Name $_ -ErrorAction SilentlyContinue).State -ne 'Installed' })
        if (-not $need.Count) {
            Write-Host '  All RSAT capabilities already installed.' -ForegroundColor Green
            return
        }
        foreach ($c in $need) {
            $cap = $c
            Invoke-NSPStep -Description "Add RSAT capability $cap" `
                -Commands @("Add-WindowsCapability -Online -Name $cap") `
                -Action { Add-WindowsCapability -Online -Name $cap | Out-String } | Out-Null
        }
    }
    Write-Host '  Start a new PowerShell session so the new modules load.' -ForegroundColor Cyan
}
