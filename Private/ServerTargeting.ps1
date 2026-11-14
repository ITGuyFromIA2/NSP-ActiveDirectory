<#
    One domain controller per call. A write function that takes -Server passes the same value to
    every AD and Group Policy cmdlet and every ADSI bind it makes, so its existence check, its write
    and its read-back all go to that DC. Without -Server nothing changes: each cmdlet picks a DC as
    it always has.
#>

function Get-NSPADServerSplat {
    # @{ Server = '<dc>' } when a DC was named, otherwise an empty hashtable. Splat it into every
    # AD (-Server) and GroupPolicy (-Server) cmdlet in the call.
    param([AllowEmptyString()][AllowNull()][string]$Server)
    if ([string]::IsNullOrWhiteSpace($Server)) { return @{} }
    return @{ Server = $Server.Trim() }
}

function Get-NSPADAdsiPath {
    # PURE. LDAP://<dc>/<dn> when a DC is named, LDAP://<dn> otherwise (serverless bind).
    param([Parameter(Mandatory)][string]$DistinguishedName, [AllowEmptyString()][AllowNull()][string]$Server)
    if ([string]::IsNullOrWhiteSpace($Server)) { return "LDAP://$DistinguishedName" }
    return "LDAP://$($Server.Trim())/$DistinguishedName"
}

function New-NSPADDirectoryEntry {
    # The one place an ADSI DirectoryEntry is bound for a write path, so a test can see the target.
    param([Parameter(Mandatory)][string]$DistinguishedName, [AllowEmptyString()][AllowNull()][string]$Server)
    return [ADSI](Get-NSPADAdsiPath -DistinguishedName $DistinguishedName -Server $Server)
}

function Format-NSPADServerArg {
    # PURE. " -Server '<dc>'" for a preview line, or '' when no DC was named.
    param([AllowEmptyString()][AllowNull()][string]$Server)
    if ([string]::IsNullOrWhiteSpace($Server)) { return '' }
    return " -Server '$($Server.Trim())'"
}

function Resolve-NSPADDomainInfoForServer {
    # For functions that already take -DomainInfo: -Server alone looks the domain up on that DC;
    # both together must name the same DC, or the call would read on one and write on another.
    param([AllowNull()]$DomainInfo, [AllowEmptyString()][AllowNull()][string]$Server)
    $named = -not [string]::IsNullOrWhiteSpace($Server)
    if ($DomainInfo) {
        if ($named -and "$($DomainInfo.Server)" -ne $Server.Trim()) {
            # Terminating on purpose: ambiguous targeting is never turned into an -AsResult outcome.
            throw (New-NSPADTerminatingError "-Server '$($Server.Trim())' and -DomainInfo (from '$($DomainInfo.Server)') name different domain controllers. Pass one, or make them match. Nothing was changed.")
        }
        return $DomainInfo
    }
    if ($named) { return Get-NSPADDomainInfo -Server $Server.Trim() }
    return Get-NSPADDomainInfo
}
