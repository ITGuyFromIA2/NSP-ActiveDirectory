function ConvertTo-NSPADLdapFilterValue {
    # RFC 4515 assertion value, never a complete LDAP filter. Wildcards are opt-in.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$AllowWildcard
    )
    $escaped = $Value.Replace('\', '\5c').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
    if (-not $AllowWildcard) { $escaped = $escaped.Replace('*', '\2a') }
    $escaped
}
