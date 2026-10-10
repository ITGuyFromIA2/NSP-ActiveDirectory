# NSP.ActiveDirectory

Active Directory and Group Policy for NSP VPN deployments, plus the **AD Manager** dashboard
(formerly the zip-delivered AD-Manager in NSP-FGTIPSecTools). Windows PowerShell **5.1** compatible
(and 7+); imports on a bare host. NSP.Toolkit / NSP.Console / NSP.Bootstrap are loaded when a
function first needs them.

## Start it

```powershell
Start-NSPADManager                 # the dashboard (relaunches elevated)
Start-NSPToolkit -Tool AD          # same, via the NSP.Toolkit launcher
New-NSPADShim -Answers $answers -Path C:\Temp\AD-Manager.ps1   # a launcher to drop on a DC
```

Every change goes through `Invoke-NSPStep` (NSP.Toolkit): DRY RUN is on by default and prints what
would happen; D in the dashboard (or `Set-NSPDryRun -Enabled $false`) applies for real. Answers live
in `%ProgramData%\NSP\Toolkit\AD\Answers`.

## What's in it

| Function | Purpose |
|---|---|
| `Start-NSPADManager` | The dashboard. `-SeedAnswersJson` merges a launcher's answers; `-SeedOnly` does only that. |
| `New-NSPADShim` | Write a launcher (NSP.ClientScripts ToolShim recipe), optionally carrying a client's answers. |
| `Get-NSPADPrerequisiteStatus` / `Install-NSPADPrerequisite` | RSAT ActiveDirectory + GroupPolicy. |
| `Get-NSPADDomainInfo` / `Get-NSPADComputer` | Domain names, DN, PDC emulator, and computer accounts over the DC locator and LDAP - no AD module or AD Web Services needed, so a sick DC or broken ADWS doesn't block them. |
| `Get-NSPADScaffoldPlan` / `New-NSPADVpnGroupScaffold` / `Get-NSPADPurposeGroupDefault` | The VPN group/OU scaffold: `VPNGroups\` (main VPN group) and `VPNGroups\FWRules\` (VPNFW purpose groups), named from the client's answers or generic defaults. |
| `New-NSPADOrganizationalUnit` / `New-NSPADGroup` / `Add-NSPADGroupMember` | Idempotent AD primitives (create only what is missing). |
| `Get-NSPADOrganizationalUnitChild` / `Select-NSPADOrganizationalUnit` | One-level OU listing and the interactive OU browser. |
| `Get-NSPADAutoEnrollGpoPlan` / `New-NSPADAutoEnrollGpo` / `New-NSPADGpoLink` | Dedicated certificate auto-enrollment GPO (AEPolicy 7), linked at the domain root. |
| `Get-NSPADWellKnownWmiFilter` / `New-NSPADWmiFilter` / `Get-NSPADWmiFilter` / `Set-NSPADGpoWmiFilter` | WMI filters, written and read straight through ADSI (no third-party module): the six NSP_AT filters, and applying one to a GPO. `Install-NSPADWmiFilterModule` (BW.Utils) is no longer needed. |
| `Get-NSPADVpnInventory` / `Export-NSPADVpnInventory` | Read-only VPN documentation inventory (groups, nesting, users, client-auth templates, TameMyCerts OU stamps). Export writes an AD Response hand-off for the Orchestrator's Inbox, or `-Format Legacy` for NSP.FortiGate's `-AdInventory`. |
| `Compare-NSPADGroupMembership` / `Test-NSPADUserGroupMembership` | Who is in group A, B or both; is a user in each of these groups. Read-only. |
| `Copy-NSPADUserGroupMembership` | Give user B the groups user A is in. |
| `Remove-NSPADDisabledUserGroupMembership` | Park disabled accounts in a holding group (as their primary group) and remove their other memberships. ConfirmImpact High. |
| `Export-NSPADGroupMembershipReport` | One CSV per group, previous reports archived and purged after a retention period. |
| `Get-NSPADGpoCatalog` / `Export-NSPADGpoBackup` / `Import-NSPADGpoBackup` | A catalog of portable GPO backups (placeholder domain names) - list it, add to it (`-Genericize`), and import from it into this domain, optionally with a WMI filter and a domain-root link. Import works on a copy; the catalog is never changed. |

Every command that changes AD, GPOs or files supports `-WhatIf` / `-Confirm`. The AD Manager
dashboard's steps also honour NSP.Toolkit's dry-run mode (on by default there).

## Answers

The dashboard reads: `CompanyName`, `Auth_UserGroup_Value` (main VPN group), `VPNFW_DNS_Mode`,
`VPNFW_DCComms_GroupName`, `VPNFW_SMB_GroupName`, `VPNFW_RDS_GroupName`, `VPNFW_DNS_GroupName`.

## Tests

```powershell
.\tools\Test-Repo.ps1      # PSScriptAnalyzer + Pester 5 under Windows PowerShell 5.1 and pwsh
```

Tests load the sibling checkouts (NSP-Bootstrap, NSP-Console, NSP-Toolkit, NSP-ClientScripts) and
never touch real AD: RSAT cmdlets are stubbed and mocked, LDAP wrappers are mocked.
