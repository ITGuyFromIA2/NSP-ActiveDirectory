# Changelog

All notable changes to NSP.ActiveDirectory are documented here. Versions follow
[SemVer](https://semver.org/). `0.x` until it has real use outside NSP.

## 0.1.8

- Huntress GPO recipe v2: the GPO copies the script from the share to `C:\ProgramData\NSP\Huntress` (Files
  preference) and the task runs that local copy, so a machine that starts off the network still installs. The script
  limits that folder to SYSTEM and Administrators on every run. Needs NSP.ClientScripts 0.1.5.

## 0.1.7

- **GPO recipes**: `Import-NSPADGpoRecipe -Recipe Huntress -Action Deploy -Scope All`, run on the client's
  DC, asks for the share folder and the Huntress keys, then sets up the share folder and its report
  folders (Kickstart-style permissions), writes the installer script (NSP.ClientScripts
  `HuntressInstaller`, readable by computers and admins only), imports `NSP - Deploy Huntress` pointing
  at it and links it at the domain root. `Get-NSPADGpoRecipe` lists recipes. Needs NSP.ClientScripts 0.1.4.
  In the dashboard: **Deploy a GPO recipe** (remembers the share folder and organization key, never the
  account key; DRY RUN previews with `-WhatIf`).
- The Huntress GPO is the 2024 `GPO-HuntressDeploy.zip`, cleaned up: the task runs the script from the
  share instead of a Files copy to `C:\Admin`, the log push-back item is gone (the script reports to the
  share itself), and the previous client's server, domain and account names are gone.
- The Huntress task also runs **at startup (5 min delay) and daily (random 4 h delay)**, so servers nobody logs
  into retry, and no longer wakes the computer. `Import-NSPADGpoRecipe` reads the domain-root link back from AD
  instead of trusting `Import-NSPADGpoBackup`'s `Linked` (see the backlog's dry-run link bug).
- `Import-NSPADGpoBackup -Replace`: extra find -> replace pairs over every XML file in the copy,
  preference files included.

## 0.1.6

- `Get-NSPADDomainInfo` and `Get-NSPADComputer`: domain names, DN, PDC emulator, and computer accounts over
  the DC locator and plain LDAP - no AD module and no AD Web Services, so a sick DC or broken ADWS
  doesn't stop a tool that only needs these facts. The DC that answered is returned for later reads.
  From a client file-transfer job's setup, where Get-ADDomain kept failing on a bad DC.
- gMSAs: `Get-NSPADServiceAccount` (LDAP: logon name, enabled, interval, who may retrieve the password),
  `Test-NSPADServiceAccount` (exists, enabled, the computer allowed directly or through a group via
  tokenGroups, installed here), `New-NSPADServiceAccount` (idempotent; checks for a usable KDS root key;
  AES only; on the located DC) and `Install-NSPADServiceAccount`. Create and install need the AD module and
  go through Invoke-NSPStep. `Get-NSPADDomainInfo` also returns `ConfigurationDN`.

## 0.1.5

- Release routine: `tools\Publish-ToGallery.ps1` now runs `Publish-NSPModule` from NSP.RepoTools, the checks every NSP module shares (including a client-reference sweep of the Git history). No change to the module itself.

## 0.1.4

- **WMI filters through ADSI** - `New-NSPADWmiFilter` writes the msWMI-Som object directly; new
  `Get-NSPADWmiFilter` and `Set-NSPADGpoWmiFilter`. The patched third-party BW.Utils module (and its
  system-only-change toggling) is no longer used; `Install-NSPADWmiFilterModule` stays for scripts
  that call BW.Utils themselves. Needs one live check on a domain controller.
- **Group tools** (from the PoSHRepo ADGroups scripts): `Compare-NSPADGroupMembership`,
  `Test-NSPADUserGroupMembership`, `Copy-NSPADUserGroupMembership`,
  `Remove-NSPADDisabledUserGroupMembership`, `Export-NSPADGroupMembershipReport`.
- **GPO catalog and transplant** (from ExportGPO / ReplaceImportGPO): `Get-NSPADGpoCatalog`,
  `Export-NSPADGpoBackup -Genericize`, `Import-NSPADGpoBackup`. Import fills in this domain's names
  on a temporary copy - the zip-era script rewrote the catalog's own files.
## 0.1.3

- From the 2026-10-02 review: every exported command that changes AD or writes files supports
  `-WhatIf` / `-Confirm` (on top of NSP.Toolkit's dry-run mode, which still governs the dashboard).
  `New-NSPADGroup` / `New-NSPADOrganizationalUnit -WhatIf` still return the DN they would create.
- `New-NSPADGpoLink` no longer swallows a failed link: only the already-linked case is tolerated.
- Needs NSP.Toolkit 0.1.1. The sibling loader announces Gallery installs and is generated from
  NSP-Toolkit's canonical copy; the module loader dot-sources files in name order.

## 0.1.2

- The hand-back folder now opens in Explorer for real. Explorer runs as the desktop user without
  elevation and refused to open the Administrators-only folder directly (seen live); the tool now
  gives that user read-only access to the one Responses folder first (what Explorer's own "Continue"
  prompt does, but read-only), then opens it. The user is the owner of the session's explorer.exe,
  so over-the-shoulder elevation works too.

## 0.1.1

- Menu "Export VPN inventory" opens the output folder in Explorer after writing
  <Company>_AD_Response.json, so the tech can copy it off the server (accept the access prompt - the
  folder is Administrators-only).

## 0.1.0

First release.

The other NSP modules it needs are installed from the PowerShell Gallery the first time they're needed,
so `Install-Module` of this one module is enough. Set `NSP_NO_AUTOINSTALL=1` to turn that off.
