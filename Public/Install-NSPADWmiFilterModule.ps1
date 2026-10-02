function Install-NSPADWmiFilterModule {
    <#
    .SYNOPSIS
        Makes sure the third-party BW.Utils.GroupPolicy.WMIFilter module is installed, patched and
        imported. Dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        The installed module needs two fixes to work here ([DirectoryContext] fully qualified; the
        domain read from WMI instead of USERDNSDOMAIN). The patch is applied only when not already
        present. A raw-ADSI replacement for this module is on the roadmap.
    .EXAMPLE
        Install-NSPADWmiFilterModule
    #>
    [CmdletBinding()]
    param()
    Use-NSPADDependency
    if (-not (Get-Module -ListAvailable -Name BW.Utils.GroupPolicy.WMIFilter)) {
        Invoke-NSPStep -Description 'Install BW.Utils.GroupPolicy.WMIFilter (PSGallery)' `
            -Commands @('Install-Module BW.Utils.GroupPolicy.WMIFilter -Scope AllUsers -Force -AllowClobber') `
            -Action {
                Install-PackageProvider NuGet -Force -MinimumVersion 2.8.5.208 -ErrorAction SilentlyContinue | Out-Null
                Install-Module BW.Utils.GroupPolicy.WMIFilter -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
            } | Out-Null
        if (Get-NSPDryRun) { return }
    }

    $installed = Get-InstalledModule -Name BW.Utils.GroupPolicy.WMIFilter -ErrorAction SilentlyContinue
    if (-not $installed) {
        throw 'BW.Utils.GroupPolicy.WMIFilter is not installed - run this step with dry run off first, or install it by hand.'
    }
    $modFile = (Get-ChildItem -Path $installed.InstalledLocation -Filter '*.psm1' -ErrorAction Stop | Select-Object -First 1).FullName
    $content = Get-Content -Path $modFile -Raw
    $needsPatch = ($content -match [regex]::Escape('[DirectoryContext]')) -and ($content -notmatch [regex]::Escape('[System.DirectoryServices.ActiveDirectory.DirectoryContext]'))
    if (-not $needsPatch) {
        Write-Host '  BW.Utils.GroupPolicy.WMIFilter is already patched - skipping.' -ForegroundColor Gray
        Remove-Module BW.Utils.GroupPolicy.WMIFilter -ErrorAction SilentlyContinue
        Import-Module BW.Utils.GroupPolicy.WMIFilter -Force -Global -ErrorAction Stop
        return
    }
    Invoke-NSPStep -Description "Patch $modFile (fully-qualify [DirectoryContext]; USERDNSDOMAIN -> WMI domain lookup)" `
        -Commands @("(Get-Content -Raw '$modFile') -replace ... | Set-Content '$modFile'") `
        -Action {
            $patched = $content.Replace('[DirectoryContext]', '[System.DirectoryServices.ActiveDirectory.DirectoryContext]')
            $patched = $patched.Replace('$Domain = $env:USERDNSDOMAIN', '$Domain = (Get-WmiObject -Query "SELECT Domain FROM Win32_ComputerSystem").Domain')
            Set-Content -Path $modFile -Value $patched
        } | Out-Null
    if (-not (Get-NSPDryRun)) {
        Remove-Module BW.Utils.GroupPolicy.WMIFilter -ErrorAction SilentlyContinue
        Import-Module BW.Utils.GroupPolicy.WMIFilter -Force -Global -ErrorAction Stop
    }
}
