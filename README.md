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
| PasswordLastSetUtc | DateTime UTC or null |
| PasswordLastSetState | string: Known, Zero, Unknown |
| PasswordMustChangeAtNextLogon | bool or null |
| MsExchRecipientTypeDetails | Int64 or null |

Missing GUID, SID, DN or account-control data fails conversion. Optional strings are empty when
absent. A missing consistency GUID can mean absent or unreadable; it does not establish the sync
source-anchor strategy. Pairing and anchor verification belong to the separate pairing workflow.
Inventories contain personal data: store them in approved local state, outside Git and Coordination.

The repository gate is offline and always sets `NSP_AD_LIVE_TESTS=0`. The existing local-domain
integration test is opt-in only: after separate owner authorization, set `NSP_AD_LIVE_TESTS=1`
and invoke that test directly with Pester. Domain membership alone never opts in.

## User address migration

`Get-NSPADUserAddressPlan` brings the reusable UPN, mail, proxy-address and optional SAM rename
behavior into a pure planner. It accepts the existing `NSP.ActiveDirectory.User` objects without
changing that contract or mutating the input. Directory reads and writes require separate owner
authorization for the environment. The following read is an example to run only after authorization:

```powershell
$inventory = @(Get-NSPADUser -All -Forest -Server 'dc01.old.example' -ErrorAction Stop)
# Use stable GUIDs to select accounts. Unselected users still participate in collision checks.
$selected = @($inventory | Where-Object SamAccountName -eq 'alex' | ForEach-Object ObjectGUID)
$plans = @(Get-NSPADUserAddressPlan -User $inventory -Identity $selected `
    -OldDomain old.example -NewDomain new.example -Format First.Last)
$plans | Select-Object ObjectGUID, Blocked, Changed, Reasons, Before, After
Set-NSPADUserAddress -Plan $plans                   # preview; no directory access
Set-NSPADUserAddress -Plan $plans -Apply -WhatIf     # preview; no directory access
# With separate live-write authorization, this confirms each changed account:
# $results = @(Set-NSPADUserAddress -Plan $plans -Apply)
```

Parameters use domain names without `@`. `-Format ReplaceSuffix` is the default and preserves
the UPN local part; the existing suffix must be the old or target domain. Other formats are
`SamAccountName`, `FLast`, `First.Last` and `LastF`. Name formats require both names; no `NA`
fallback, transliteration or silent truncation occurs. Unusual addresses become blocked review
cases. Only `-ChangeSamAccountName` renames SAM, with the twenty-character limit checked.

UPN, mail and primary SMTP updates default to enabled and are independently controlled by
`-UpdateUPN:$false`, `-UpdateMail:$false` and `-UpdatePrimarySmtp:$false`. Empty mail stays empty
unless `-CreateMailIfEmpty` is supplied. Existing mail or a primary SMTP outside the old domain
and different from the generated target blocks the plan rather than being overwritten.

Aliases, the previous valid UPN, previous primary SMTP and X400/X500 addresses are preserved by
default. SMTP comparisons use exact case-insensitive address equality, with exactly one `SMTP:`
primary when promotion is enabled; other SMTP entries are `smtp:`. Duplicates are removed without
regex or substring matching. Existing non-SMTP values retain their spelling.

- `-ConvertAliasDomain` also generates target-domain versions of old-domain SMTP aliases.
- `-PreserveOldAddress:$false` removes old-domain SMTP values during conversion/promotion.
- `-RemoveAliasDomain @('routing.example')` removes only exact matching SMTP suffixes.
- `-RemoveAddressType X400,X500` explicitly removes those types.
- `-SkipIdentity $guids` excludes selected users from changes while keeping their collision claims.

The supplied inventory must be complete for the desired scope. The planner checks existing and
proposed UPN/mail/SMTP claims across visible users, and SAM claims within each domain. Existing
claims remain reserved even for selected users: a batch cannot depend on freeing another user's
address first. It does not inventory contacts/groups or validate Exchange address policy, accepted
domains, configured UPN suffixes, every directory ACL or all external systems using an address.
Complete visible-user inventory is not proof that an address is available everywhere.

`Set-NSPADUserAddress -Apply` needs RSAT's `Set-ADUser`. It refreshes all forest users, regenerates
the selected batch under one policy, checks collisions and rejects changed GUID/SID/provenance,
source state or proposed state before the first write. Plans whose selected DC differs from the
new inventory are conservatively stale; regenerate and review them. It then confirms each user,
reads that GUID again on its pinned DC, writes only changed attributes, and reads back. An empty
proxy list uses `-Clear`, never `-Replace` with an empty array. It never triggers Entra Connect sync.

Results are `Preview`, `Unchanged`, `Skipped`, `Verified`, `Failed`, `WriteUnverified` or
`VerificationFailed`. An uncertain result stops the batch; earlier successful results remain in
the output and later users have not been attempted. Retain those results and inspect uncertainty
before retrying. There is no rollback or cross-user transaction, and concurrent edits elsewhere
can race a preflight. Verification covers these AD attributes on that DC, not replication or cloud
linking. Tests use invented objects and fake directory boundaries; no live migration is proven.

Plans and results contain personal data. Keep them in approved local state outside Git and
Coordination. In the pairing process, perform address preparation before final hard-match
preflight, then refresh both inventories and revalidate the saved queue by GUID/SID and cloud ID.
Address changes and hard matches require separate decisions; normal sync may establish a link
between these steps. Pairing UI integration belongs to NSP.M365.UserPairing and is separate from
these AD commands.

## Forest UPN suffix gate

The pairing menu can compare selected Microsoft 365 domains with the on-prem forest's suffixes,
then offer each missing suffix as a separate, explicitly confirmed action. These AD primitives
do not read Microsoft 365, automatically import cloud domains or create suffixes during a user
update. All directory reads/writes still need authorization for that environment.

```powershell
# After authorization for the forest read:
$forest = Get-NSPADForestInfo -Server dc01.old.example
$forest | Select-Object ForestDNSRoot, DomainDNSRoots, AlternateUPNSuffixes, AvailableUPNSuffixes
$suffixPlan = Get-NSPADForestUPNSuffixPlan -ForestInfo $forest -Suffix new.example
Add-NSPADForestUPNSuffix -Plan $suffixPlan                  # offline preview
Add-NSPADForestUPNSuffix -Plan $suffixPlan -Apply -WhatIf    # offline preview
# With separate authorization for this forest change, confirm the selected suffix:
# $result = Add-NSPADForestUPNSuffix -Plan $suffixPlan -Apply
```

`Get-NSPADForestInfo` reads LDAP and needs no RSAT or ADWS. It returns forest root/domain names,
configuration DN and GUID, actual server, domain DNS roots, configured alternate UPN suffixes
and their distinct union as `AvailableUPNSuffixes`. Domain DNS roots already qualify; they do
not need duplicate alternate entries. This follows Microsoft's
[UPN naming rules](https://learn.microsoft.com/en-us/windows/win32/ad/naming-properties).
Directory errors terminate. Visibility remains subject to ACLs; an absent optional uPNSuffixes
attribute cannot be distinguished from a hidden one, so the visible list is not proof of full
attribute access. Missing required forest identity or inconsistent discovery is an error.

`Get-NSPADForestUPNSuffixPlan` is pure and accepts one DNS suffix without `@`. It returns
`NSP.ActiveDirectory.ForestUPNSuffixPlan`: forest identity, configuration GUID, pinned server,
requested Suffix, Availability (`Domain`, `Alternate`, `Missing`), domain roots, Before/After
alternate arrays, Changed, Blocked and Reasons. Existing domain/alternate suffixes are no-ops.

`Add-NSPADForestUPNSuffix` previews by default. Actual `-Apply` revalidates forest identity and
the reviewed snapshot, confirms the one addition, rereads immediately before writing, then uses
RSAT's `Set-ADForest -UPNSuffixes @{Add=...}` on the pinned server. It never replaces/removes the
suffix list. Read-back checks the forest, target suffix and preservation of prior alternates.
See Microsoft's [Set-ADForest documentation](https://learn.microsoft.com/en-us/powershell/module/activedirectory/set-adforest).
Results are Preview, AlreadyAvailable, Skipped, Verified, WriteUnverified or VerificationFailed.
An uncertain result requires inspection before retrying; a success on one DC does not prove
replication. This does not verify an Entra domain, create DNS records, change any user or start sync.

After each suffix addition, refresh forest facts before planning another: old snapshots are
stale after configuration changes. Refresh/review user plans too. User-address `-Apply` now
refuses a changed UPN whose target suffix is unavailable; it never adds that suffix implicitly.
Mail/proxy-only changes do not require an email domain to be a forest UPN suffix. Pure previews
remain offline. Pairing menu integration and cloud-domain selection stay with the Graph Specialist.
Existing identity and address fields are preserved. Coverage is offline with invented forest facts;
no live suffix addition has been validated by this release preparation.

## Optional user password and recipient metadata

Source 0.1.12 extends the agreed User contract with four properties, always present. Existing
identity/provenance and address fields retain their types. All domain and forest query modes
request `pwdLastSet` and `msExchRecipientTypeDetails`; no RSAT or additional directory query is needed.

- `PasswordLastSetUtc`: DateTime with Kind=Utc for a valid positive FILETIME; null otherwise.
- `PasswordLastSetState`: Known, Zero or Unknown. Missing, unreadable, negative, malformed and
  out-of-range password data is Unknown. Zero stays Zero and never becomes a date in 1601.
- `PasswordMustChangeAtNextLogon`: bool for Known/Zero, otherwise null. Known positive time is
  false; zero is true only when userAccountControl does not have DONT_EXPIRE_PASSWD (0x10000).
  This describes the attribute flag combination, not all password-expiration/logon policy.
- `MsExchRecipientTypeDetails`: raw Int64 or null. Preserve zero and large bit flags exactly;
  missing/unreadable/malformed/out-of-range data is null, never an invented classification.

The zero/never-expires rule follows Microsoft's
[pwdLastSet attribute documentation](https://learn.microsoft.com/en-us/windows/win32/adschema/a-pwdlastset).
These optional attributes are diagnostic data. A missing value can mean absent or unreadable;
it does not prove a user has no Exchange recipient type. Comparing the AD password timestamp
with cloud lastPasswordChangeDateTime does not prove password synchronization or equality of
passwords. Queue state and reports containing these fields still belong outside Git/Coordination.

The pairing consumer can prefer these public fields over its temporary LDAP adapter. Its review
and preflight policy remain pairing-owned; adding raw recipient metadata here does not itself
implement any cloud eligibility decision or authorize a live read/write.
