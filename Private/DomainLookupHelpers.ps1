# LDAP and DC-locator access for Get-NSPADDomainInfo / Get-NSPADComputer. No AD module, no AD Web
# Services: the DC locator (DsGetDcName, the same lookup Windows logon uses) and plain LDAP. Tests
# mock these two functions.

function Find-NSPADDomainController {
    # A responsive DC: -Server is checked and returned as the DC's own name; otherwise the locator
    # picks one for this computer's domain, forcing rediscovery so a DC that went bad since the
    # last lookup isn't reused from cache.
    param([string]$Server)
    if ($Server) {
        $context = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new('DirectoryServer', $Server)
        return [System.DirectoryServices.ActiveDirectory.DomainController]::GetDomainController($context).Name
    }
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
    $domain.FindDomainController([System.DirectoryServices.ActiveDirectory.LocatorOptions]::ForceRediscovery).Name
}

function Read-NSPADRootDse {
    # The DC's RootDSE naming contexts. RootDSE is read as an entry, not searched: a
    # DirectorySearcher rooted at RootDSE fails ("the provider does not support searching").
    param([Parameter(Mandatory)][string]$Server)
    $rootDse = [ADSI]"LDAP://$Server/RootDSE"
    @{
        defaultnamingcontext       = [string]$rootDse.defaultNamingContext[0]
        configurationnamingcontext = [string]$rootDse.configurationNamingContext[0]
    }
}

function Read-NSPADLdap {
    # One LDAP search against one DC. Returns one hashtable per result: lower-case property name ->
    # first value (byte arrays such as objectSid stay byte arrays). -Scope Base reads one object.
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$SearchBase,
        [string]$Filter = '(objectClass=*)',
        [Parameter(Mandatory)][string[]]$Property,
        [ValidateSet('Base', 'OneLevel', 'Subtree')][string]$Scope = 'Subtree'
    )
    $root = [ADSI]"LDAP://$Server/$($SearchBase -replace '/', '\/')"
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($root, $Filter)
    $searcher.SearchScope = $Scope
    foreach ($name in $Property) { [void]$searcher.PropertiesToLoad.Add($name) }
    $results = $searcher.FindAll()
    try {
        foreach ($result in $results) {
            $item = @{}
            foreach ($name in $result.Properties.PropertyNames) { $item[$name.ToLowerInvariant()] = $result.Properties[$name][0] }
            $item
        }
    } finally { $results.Dispose() }
}
