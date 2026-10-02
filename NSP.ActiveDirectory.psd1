@{
    RootModule        = 'NSP.ActiveDirectory.psm1'
    ModuleVersion     = '0.1.1'
    GUID              = '35f1aeb4-782a-4a6a-8865-daec1be3cce6'
    Author            = 'Network Systems Plus'
    CompanyName       = 'Network Systems Plus'
    Copyright         = '(c) Network Systems Plus. All rights reserved.'
    Description       = 'Active Directory and Group Policy for NSP VPN deployments: VPN group/OU scaffold, group nesting, certificate auto-enrollment GPO, WMI filters, read-only VPN inventory, and the AD Manager dashboard (Start-NSPADManager). Windows PowerShell 5.1 compatible.'

    # 5.1 is the floor for every NSP toolkit, and the module must import on a bare 5.1 host -
    # sibling NSP modules are loaded on first use (Private\Import-NSPToolkitModule.ps1), never
    # declared as RequiredModules.
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Add-NSPADGroupMember'
        'Export-NSPADVpnInventory'
        'Get-NSPADAutoEnrollGpoPlan'
        'Get-NSPADOrganizationalUnitChild'
        'Get-NSPADPrerequisiteStatus'
        'Get-NSPADPurposeGroupDefault'
        'Get-NSPADScaffoldPlan'
        'Get-NSPADVpnInventory'
        'Get-NSPADWellKnownWmiFilter'
        'Install-NSPADPrerequisite'
        'Install-NSPADWmiFilterModule'
        'New-NSPADAutoEnrollGpo'
        'New-NSPADGpoLink'
        'New-NSPADGroup'
        'New-NSPADOrganizationalUnit'
        'New-NSPADShim'
        'New-NSPADVpnGroupScaffold'
        'New-NSPADWmiFilter'
        'Select-NSPADOrganizationalUnit'
        'Start-NSPADManager'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('NSP', 'ActiveDirectory', 'GroupPolicy', 'VPN', 'GPO', 'WMIFilter')
            ProjectUri   = 'https://github.com/ITGuyFromIA2/NSP-ActiveDirectory'
            LicenseUri   = 'https://github.com/ITGuyFromIA2/NSP-ActiveDirectory/blob/main/LICENSE'
            ReleaseNotes = 'https://github.com/ITGuyFromIA2/NSP-ActiveDirectory/blob/main/CHANGELOG.md'
        }
    }
}