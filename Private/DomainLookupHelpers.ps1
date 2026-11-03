# LDAP and DC-locator access for Get-NSPADDomainInfo / Get-NSPADComputer. No AD module, no AD Web
# Services: the DC locator (DsGetDcName, the same lookup Windows logon uses) and plain LDAP. Tests
# mock these two functions.

function Find-NSPADDomainController {
    # A responsive DC: -Server is checked and returned as the DC's own name; otherwise the locator
    # picks one for this computer's domain, forcing rediscovery so a DC that went bad since the
    # last lookup isn't reused from cache.
    [CmdletBinding(DefaultParameterSetName = 'Server')]
    param(
        [Parameter(ParameterSetName = 'Server')][string]$Server,
        [Parameter(Mandatory, ParameterSetName = 'Domain')][string]$DomainName
    )
    if ($Server) {
        $context = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new('DirectoryServer', $Server)
        return [System.DirectoryServices.ActiveDirectory.DomainController]::GetDomainController($context).Name
    }
    $domain = if ($DomainName) {
        $context = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new('Domain', $DomainName)
        [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($context)
    } else {
        [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
    }
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

function New-NSPADLdapEntry {
    # Separate constructors let offline tests exercise the real search/lifetime logic.
    param([string]$Server, [string]$SearchBase)
    [ADSI]"LDAP://$Server/$($SearchBase -replace '/', '\/')"
}

function New-NSPADLdapSearcher {
    param($Root, [string]$Filter)
    New-Object System.DirectoryServices.DirectorySearcher($Root, $Filter)
}

function Read-NSPADLdap {
    # One LDAP search against one DC. Returns one hashtable per result: lower-case property name ->
    # first value (byte arrays such as objectSid stay byte arrays), or every value for the names in
    # -MultiValued (an array). -Scope Base reads one object (constructed attributes such as
    # tokenGroups only come back from a Base read).
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$SearchBase,
        [string]$Filter = '(objectClass=*)',
        [Parameter(Mandatory)][string[]]$Property,
        [ValidateSet('Base', 'OneLevel', 'Subtree')][string]$Scope = 'Subtree',
        [string[]]$MultiValued = @(),
        [ValidateRange(1, 1000)][int]$PageSize = 500,
        [ValidateRange(0, 2147483647)][int]$SizeLimit = 0,
        [ValidateScript({ $_ -ge [timespan]::Zero -and $_.TotalSeconds -le [int]::MaxValue })]
        [timespan]$ServerTimeLimit = [timespan]::Zero
    )
    $root = $null
    $searcher = $null
    $results = $null
    try {
        $root = New-NSPADLdapEntry -Server $Server -SearchBase $SearchBase
        $searcher = New-NSPADLdapSearcher -Root $root -Filter $Filter
        $searcher.SearchScope = $Scope
        $searcher.PageSize = $PageSize
        $searcher.SizeLimit = $SizeLimit
        $searcher.ServerTimeLimit = $ServerTimeLimit
        # A domain search must stay in its selected naming context. Forest reads enumerate
        # domains explicitly instead of silently following referrals across environments.
        $searcher.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        foreach ($name in $Property) { [void]$searcher.PropertiesToLoad.Add($name) }
        $multi = @($MultiValued | ForEach-Object { $_.ToLowerInvariant() })
        $results = $searcher.FindAll()
        foreach ($result in $results) {
            $item = @{}
            foreach ($name in $result.Properties.PropertyNames) {
                $key = $name.ToLowerInvariant()
                $item[$key] = if ($multi -contains $key) { , @($result.Properties[$name]) } else { , $result.Properties[$name][0] }
            }
            $item
        }
    } finally {
        if ($null -ne $results) { $results.Dispose() }
        if ($null -ne $searcher) { $searcher.Dispose() }
        if ($null -ne $root) { $root.Dispose() }
    }
}
