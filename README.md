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
| `Get-NSPADUser` | Paged user inventory by exact identity, wildcard filter or all users; separate explicit forest scope. See user inventory below. |
| `Get-NSPADServiceAccount` / `Test-NSPADServiceAccount` / `New-NSPADServiceAccount` / `Install-NSPADServiceAccount` | Group managed service accounts: read and readiness checks over LDAP (including "may this computer retrieve the password", through its groups); create (checks the KDS root key) and install with the AD module. |
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
| `Get-NSPADGpoCatalog` / `Export-NSPADGpoBackup` / `Import-NSPADGpoBackup` | A catalog of portable GPO backups (placeholder domain names) - list it, add to it (`-Genericize`), and import from it into this domain, optionally with a WMI filter and a domain-root link. Import works on a copy; the catalog is never changed. `-Replace` fills a template's own tokens (e.g. a share path) in its preference XML. |
| `Get-NSPADGpoRecipe` / `Import-NSPADGpoRecipe` | Ready-made GPO deployments, run on the client's DC: share folder + report folders, the payload script (NSP.ClientScripts), the GPO pointing at it, and the link - see below. |

Every command that changes AD, GPOs or files supports `-WhatIf` / `-Confirm`. The AD Manager
dashboard's steps also honour NSP.Toolkit's dry-run mode (on by default there).

## GPO recipes

A recipe (`GpoRecipes\<Name>\Recipe.psd1` + a portable GPO backup) is a whole deployment. On the
client's DC, as a domain admin:

```powershell
Import-NSPADGpoRecipe -Recipe Huntress -Action Deploy -Scope All
```

It asks for the share folder and the recipe's values (Huntress: organization key, account key -
masked), shows what it will do, and after one confirmation:

1. creates the share folder (its parent share must exist) and report folders, Kickstart-style:
   Authenticated Users read the folder (inheritance broken, Users removed) and may write in the
   report folders;
2. writes the script there, readable only by SYSTEM, administrators, domain computers and DCs;
3. imports the GPO pointing at the script and links it at the domain root.

Re-running updates the script and the GPO in place.

| Recipe | GPO | Share layout |
|---|---|---|
| `Huntress` | `NSP - Deploy Huntress`: copies `HuntressInstall.ps1` from the share to `C:\ProgramData\NSP\Huntress` (locked to SYSTEM/Administrators by the script) and a SYSTEM task runs the local copy at registration, unlock, startup and daily; it exits at once when the agent is healthy, and re-registers an orphaned (401) or foreign one. | `HuntressInstall.ps1`, `Status\<COMPUTER>.json` (Installed / AlreadyInstalled / Failed, agent version), `Transcripts\` (one per install run) |

`-FileShareRoot` and `-Values @{ OrganizationKey = ...; AccountKey = ... }` skip the questions.
In the AD Manager dashboard it is **Deploy a GPO recipe**: it remembers the share folder and the
non-secret values (Huntress: the organization key) per recipe in the AD answers - never the
account key, which is asked for masked every time - and in DRY RUN it runs with `-WhatIf` (asks everything, changes nothing) - switch to APPLY
to deploy.
Only `-Action Deploy` and `-Scope All` exist so far.

## Answers

The dashboard reads: `CompanyName`, `Auth_UserGroup_Value` (main VPN group), `VPNFW_DNS_Mode`,
`VPNFW_DCComms_GroupName`, `VPNFW_SMB_GroupName`, `VPNFW_RDS_GroupName`, `VPNFW_DNS_GroupName`.

## Tests

```powershell
.\tools\Test-Repo.ps1      # PSScriptAnalyzer + Pester 5 under Windows PowerShell 5.1 and pwsh
```

Tests load the sibling checkouts (NSP-Bootstrap, NSP-Console, NSP-Toolkit, NSP-ClientScripts) and
never touch real AD: RSAT cmdlets are stubbed and mocked, LDAP wrappers are mocked.

## User inventory over LDAP

`Get-NSPADUser` returns `NSP.ActiveDirectory.User` without RSAT or ADWS. These are read-only
commands; run them against a directory only with its owner's authorization.

```powershell
$domain = Get-NSPADDomainInfo -Server 'dc01.contoso.example'
Get-NSPADUser -Identity 'one' -DomainInfo $domain       # exact sAMAccountName
Get-NSPADUser -Filter '*example*' -DomainInfo $domain   # all candidates, no automatic choice
Get-NSPADUser -All -DomainInfo $domain -SearchBase 'OU=People,DC=contoso,DC=example'
Get-NSPADUser -All -Forest -Server 'dc01.contoso.example' -PageSize 500
```

Choose exactly one of `-Identity`, `-Filter` or `-All`. Filter is a wildcard assertion value
searched across sAMAccountName, userPrincipalName, displayName, mail and proxyAddresses. Only
`*` acts as a wildcard. LDAP syntax, backslashes, parentheses and NUL are escaped; Identity
treats `*` literally too. This parameter does not accept a raw LDAP filter or PowerShell expression.

In domain scope, `-DomainInfo` pins the domain and DC. Without it, `-Server` selects a DC or the
local domain locator selects one. When both are supplied, the server must resolve the same domain.
`-SearchBase` defaults to the domain DN and must be within it. Domain searches do not chase referrals.
`-Server` takes a DNS name, without a protocol or port.

Forest scope uses separate parameter sets: `-Forest` requires `-Server` and cannot be combined
with `-DomainInfo` or `-SearchBase`. It reads active domain crossRefs in the seed forest's
configuration, locates a DC for each domain, verifies the domain and forest configuration, then
queries each domain over LDAP. External references and application partitions are excluded.
This reads each domain's full attributes rather than relying on a global catalog's partial set.
The same sAMAccountName in two domains produces two results, each with its own domain and DC.
Within one domain, duplicate exact identities are an error. Wildcard filters return every candidate.

All modes page at 500 objects by default (`-PageSize` accepts 1-1000); page size does not cap the
total inventory. The private LDAP helper also accepts optional size and server time limits; its
defaults add no client-side total cap. LDAP access errors terminate rather than returning a
successful empty inventory. A failure can occur after earlier domain results were emitted:
discard partial output and resolve the error before treating an inventory as complete.
Directory ACLs still govern which users, attributes and domain crossRefs are visible. Offline
tests cover paging configuration and result traversal; live directory validation is not implied.

| Property | Type |
|---|---|
| DistinguishedName | string |
| SamAccountName, UserPrincipalName, DisplayName, GivenName, Surname, Mail | string |
| ProxyAddresses | string[], including an empty array when absent |
| ObjectGUID | Guid |
| ConsistencyGuidBytes | byte[] or null, raw mS-DS-ConsistencyGuid |
| ObjectSID | string in SDDL form |
| Enabled | bool, from userAccountControl's disabled bit |
| DomainDNSRoot, Server | string, the domain and DC actually read |

Missing GUID, SID, DN or account-control data fails conversion. Optional strings are empty when
absent. A missing consistency GUID can mean absent or unreadable; it does not establish the sync
source-anchor strategy. Pairing and anchor verification belong to the separate pairing workflow.
Inventories contain personal data: store them in approved local state, outside Git and Coordination.

The repository gate is offline and always sets `NSP_AD_LIVE_TESTS=0`. The existing local-domain
integration test is opt-in only: after separate owner authorization, set `NSP_AD_LIVE_TESTS=1`
and invoke that test directly with Pester. Domain membership alone never opts in.
