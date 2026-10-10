function Install-NSPADServiceAccount {
    <#
    .SYNOPSIS
        Installs a gMSA on this computer and confirms it works (Install-ADServiceAccount, then Test-ADServiceAccount). Dry-run aware (Invoke-NSPStep).
    .DESCRIPTION
        Run it elevated on each computer that will use the account, after New-NSPADServiceAccount
        (a new gMSA can take a few minutes to replicate). Needs the AD module on this computer
        (Install-NSPADPrerequisite). Returns $true when the account tests good, $false when it was
        installed but doesn't, and nothing in DRY RUN.
    .EXAMPLE
        Set-NSPDryRun -Enabled $false
        Install-NSPADServiceAccount -Name 'svc_transfer'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    $bare = $Name.TrimEnd('$')
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install gMSA '$bare'")) { return }
    Use-NSPADDependency
    Assert-NSPADCommand Install-ADServiceAccount
    $result = Invoke-NSPStep -Description "Install gMSA '$bare' on $env:COMPUTERNAME" `
        -Commands @("Install-ADServiceAccount -Identity '$bare'", "Test-ADServiceAccount -Identity '$bare'") `
        -Action {
            Install-ADServiceAccount -Identity $bare -ErrorAction Stop
            [bool](Test-ADServiceAccount -Identity $bare -ErrorAction Stop)
        }
    if ($result.Ran) { return [bool]$result.Output }
}
