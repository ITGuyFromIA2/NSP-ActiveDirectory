function Assert-NSPADForestSuffixPlanCurrent {
    param($Plan, $Current)
    foreach ($name in 'ForestDNSRoot','RootDomainDN','ConfigurationDN','ConfigurationGUID','Server','Suffix','Availability','Changed') {
        if ([string]$Plan.$name -ine [string]$Current.$name) { throw 'Forest suffix plan is stale or altered; regenerate and review it.' }
    }
    foreach ($name in 'DomainDNSRoots','Before','After') {
        $old = ConvertTo-Json -InputObject @($Plan.$name | Sort-Object -Unique) -Compress
        $new = ConvertTo-Json -InputObject @($Current.$name | Sort-Object -Unique) -Compress
        if ($old -ine $new) { throw 'Forest suffix plan is stale or altered; regenerate and review it.' }
    }
}
