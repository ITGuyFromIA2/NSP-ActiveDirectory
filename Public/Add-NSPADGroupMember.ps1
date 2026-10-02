function Add-NSPADGroupMember {
    <#
    .SYNOPSIS
        Nests -MemberIdentity into -GroupIdentity unless it is already a member. Idempotent;
        dry-run aware (Invoke-NSPStep).
    .EXAMPLE
        Add-NSPADGroupMember -GroupIdentity 'CN=VPNFW_DNS_Group,OU=FWRules,...' -MemberIdentity 'CN=VPN_Staff,...'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupIdentity,
        [Parameter(Mandatory)][string]$MemberIdentity
    )
    Use-NSPADDependency
    Assert-NSPADCommand Get-ADGroupMember
    $already = @(Get-ADGroupMember -Identity $GroupIdentity -ErrorAction SilentlyContinue | Where-Object {
            $_.DistinguishedName -eq $MemberIdentity -or $_.SamAccountName -eq $MemberIdentity -or $_.Name -eq $MemberIdentity
        })
    if ($already.Count -gt 0) {
        Write-Host "  '$MemberIdentity' is already a member of '$GroupIdentity' - skipping." -ForegroundColor Gray
        return
    }
    Invoke-NSPStep -Description "Nest '$MemberIdentity' into '$GroupIdentity'" `
        -Commands @("Add-ADGroupMember -Identity '$GroupIdentity' -Members '$MemberIdentity'") `
        -Action { Add-ADGroupMember -Identity $GroupIdentity -Members $MemberIdentity } | Out-Null
}
