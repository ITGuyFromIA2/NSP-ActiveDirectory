function Select-NSPADOrganizationalUnit {
    <#
    .SYNOPSIS
        Interactive text OU picker: browse one level at a time (a number goes into a child OU, B backs
        up one level, S uses the current OU, Q cancels). Returns the chosen DN or $null.
    .DESCRIPTION
        Lazy, one level per screen (no whole-tree walk). Back uses an explicit history stack rather
        than re-deriving the parent from the DN, so an OU name with an escaped comma can't break it.
    .PARAMETER StartingDN
        Where to start. Blank starts at the domain root.
    .EXAMPLE
        $ou = Select-NSPADOrganizationalUnit
    #>
    [CmdletBinding()]
    param(
        [string]$StartingDN,
        [string]$Server,
        [System.Management.Automation.PSCredential]$Credential
    )

    $currentDN = $StartingDN
    $history = New-Object System.Collections.Generic.List[string]

    while ($true) {
        try {
            $level = Get-NSPADOrganizationalUnitChild -SearchBase $currentDN -Server $Server -Credential $Credential
        } catch {
            Write-Host "Could not list child OUs under '$currentDN' - $($_.Exception.Message)" -ForegroundColor Red
            return $null
        }
        $currentDN = $level.SearchBase
        $children = $level.Children

        Write-Host ''
        Write-Host "Current OU: $currentDN" -ForegroundColor Cyan
        if ($children.Count -eq 0) {
            Write-Host '    (no child OUs here)' -ForegroundColor Gray
        } else {
            for ($i = 0; $i -lt $children.Count; $i++) {
                Write-Host ('    {0}. {1}' -f ($i + 1), $children[$i].Name)
            }
        }
        Write-Host ''
        Write-Host '  S. Use THIS OU'
        if ($history.Count -gt 0) { Write-Host '  B. Back up one level' }
        Write-Host '  Q. Cancel'
        $sel = [string](Read-Host 'Select a number to browse into a child OU, or a letter')

        switch -Regex ($sel.Trim()) {
            '^[Ss]$' { return $currentDN }
            '^[Qq]$' { return $null }
            '^[Bb]$' {
                if ($history.Count -gt 0) {
                    $currentDN = $history[$history.Count - 1]
                    $history.RemoveAt($history.Count - 1)
                } else {
                    Write-Host 'Already at the top.' -ForegroundColor Yellow
                }
            }
            default {
                $idx = ($sel -as [int]) - 1
                if ($idx -ge 0 -and $idx -lt $children.Count) {
                    $history.Add($currentDN)
                    $currentDN = $children[$idx].DistinguishedName
                } else {
                    Write-Host 'Invalid selection.' -ForegroundColor Yellow
                }
            }
        }
    }
}
