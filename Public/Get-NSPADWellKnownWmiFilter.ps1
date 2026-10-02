function Get-NSPADWellKnownWmiFilter {
    <#
    .SYNOPSIS
        The six well-known NSP WMI filters (PDC only, non-PDC DCs, all DCs, member servers, all
        servers, workstations): Name, Expression (one WQL string, or several), Description. Pure data.
    .EXAMPLE
        Get-NSPADWellKnownWmiFilter | Select-Object Name, Description
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            Name        = 'NSP_AT - ONLY PDC'
            Expression  = 'Select * from Win32_ComputerSystem WHERE (DomainRole = "5")'
            Description = 'Returns holder of the PDCs FSMO Roles'
        }
        [pscustomobject]@{
            Name        = 'NSP_AT - All NON-PDC Domain Controllers'
            Expression  = @('Select * from Win32_ComputerSystem WHERE (DomainRole <> "5")', 'select * from Win32_OperatingSystem WHERE (ProductType = "2")')
            Description = 'Selects all NON-PDC Domain Controllers'
        }
        [pscustomobject]@{
            Name        = 'NSP_AT - All Domain Controllers'
            Expression  = 'select * from Win32_OperatingSystem WHERE (ProductType = "2")'
            Description = 'Selects all Domain Controllers, regardless of PDC role'
        }
        [pscustomobject]@{
            Name        = 'NSP_AT - All Member Servers'
            Expression  = 'select * from Win32_OperatingSystem WHERE (ProductType = "3")'
            Description = 'Returns all non-DC Member Servers'
        }
        [pscustomobject]@{
            Name        = 'NSP_AT - All Servers'
            Expression  = 'select * from Win32_OperatingSystem WHERE (ProductType = "2") OR (ProductType = "3")'
            Description = 'Returns ALL servers in AD, including PDC'
        }
        [pscustomobject]@{
            Name        = 'NSP_AT - All Workstations'
            Expression  = 'select * from Win32_OperatingSystem WHERE (ProductType <> "2") AND (ProductType <> "3")'
            Description = 'Returns All non-servers in AD'
        }
    )
}
