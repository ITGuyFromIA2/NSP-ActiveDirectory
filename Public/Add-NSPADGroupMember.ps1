function Add-NSPADGroupMember {
    <#
    .SYNOPSIS
        Nests -MemberIdentity into -GroupIdentity unless it is already a member. Idempotent;
        dry-run aware (Invoke-NSPStep).
    .PARAMETER Server
        A domain controller. The membership read and the add both go to it. Default: the AD
        module picks one for each cmdlet.
    .EXAMPLE
        Add-NSPADGroupMember -GroupIdentity 'CN=VPNFW_DNS_Group,OU=FWRules,...' -MemberIdentity 'CN=VPN_Staff,...'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GroupIdentity,
        [Parameter(Mandatory)][string]$MemberIdentity,
        [ValidateNotNullOrEmpty()][string]$Server
    )
    if (-not $PSCmdlet.ShouldProcess("$GroupIdentity", "Add member '$MemberIdentity' if it is not one already")) { return }
    Use-NSPADDependency
    Assert-NSPADCommand Get-ADGroupMember
    $srv = Get-NSPADServerSplat -Server $Server
    $already = @(Get-ADGroupMember -Identity $GroupIdentity @srv -ErrorAction SilentlyContinue | Where-Object {
            $_.DistinguishedName -eq $MemberIdentity -or $_.SamAccountName -eq $MemberIdentity -or $_.Name -eq $MemberIdentity
        })
    if ($already.Count -gt 0) {
        Write-Host "  '$MemberIdentity' is already a member of '$GroupIdentity' - skipping." -ForegroundColor Gray
        return
    }
    Invoke-NSPStep -Description "Nest '$MemberIdentity' into '$GroupIdentity'" `
        -Commands @("Add-ADGroupMember -Identity '$GroupIdentity' -Members '$MemberIdentity'$(Format-NSPADServerArg $Server)") `
        -Action { Add-ADGroupMember -Identity $GroupIdentity -Members $MemberIdentity @srv } | Out-Null
}
