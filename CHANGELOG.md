# Changelog

All notable changes to NSP.ActiveDirectory are documented here. Versions follow
[SemVer](https://semver.org/). `0.x` until it has real use outside NSP.

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
