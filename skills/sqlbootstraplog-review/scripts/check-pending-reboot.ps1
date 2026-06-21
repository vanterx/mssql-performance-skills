<#
.SYNOPSIS
    Checks Windows for pending-reboot conditions that block SQL Server Setup.

.DESCRIPTION
    SQL Server Setup's "Restart computer" global rule (RebootRequiredCheck) fails
    when a reboot is pending, most commonly because of the
    PendingFileRenameOperations registry value. Run this script BEFORE launching
    SQL Server Setup or applying a Cumulative Update / Service Pack to avoid the
    rule failure, and run it again afterwards to confirm whether the installer
    left a reboot pending (MSI exit code 3010).

    Signals checked (all documented Windows mechanisms):
      1. Component Based Servicing  - HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\
                                      Component Based Servicing\RebootPending
      2. Windows Update             - HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\
                                      WindowsUpdate\Auto Update\RebootRequired
      3. Pending file renames       - HKLM:\SYSTEM\CurrentControlSet\Control\
                                      Session Manager : PendingFileRenameOperations
                                      (the signal SQL Server Setup's rule checks)
      4. Pending computer rename    - ActiveComputerName != ComputerName
      5. ConfigMgr (SCCM) client    - CCM_ClientUtilities.DetermineIfRebootPending
                                      (skipped silently when the client is absent)

    Planned home: skills/sqlsetup-review/scripts/ once the sqlsetup-review skill
    (backlog/sqlsetup-review-skill-plan.md, check U7) is implemented.

.PARAMETER ShowDetail
    Also print the raw PendingFileRenameOperations entries so you can see which
    files are waiting (often reveals which product caused the pending state).

.EXAMPLE
    .\check-pending-reboot.ps1
    Runs all checks and prints a summary table. Exit code 0 = no reboot pending,
    1 = reboot pending.

.EXAMPLE
    .\check-pending-reboot.ps1 -ShowDetail
    Includes the file list behind PendingFileRenameOperations.

.NOTES
    Requires: Windows PowerShell 5.1+ or PowerShell 7+, read access to HKLM
    (run elevated for completeness; SCCM check needs the ConfigMgr client).
    Reference: SQL Server Setup log files -
    https://learn.microsoft.com/sql/database-engine/install-windows/view-and-read-sql-server-setup-log-files
#>
[CmdletBinding()]
param(
    [switch]$ShowDetail
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {
    param([string]$Check, [bool]$Pending, [string]$Evidence)
    $results.Add([pscustomobject]@{
        Check    = $Check
        Pending  = $Pending
        Evidence = $Evidence
    })
}

# 1. Component Based Servicing (Windows servicing stack)
$cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$cbsPending = Test-Path -Path $cbsKey
Add-Result 'Component Based Servicing' $cbsPending ($(if ($cbsPending) { 'RebootPending key exists' } else { 'no RebootPending key' }))

# 2. Windows Update
$wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$wuPending = Test-Path -Path $wuKey
Add-Result 'Windows Update' $wuPending ($(if ($wuPending) { 'RebootRequired key exists' } else { 'no RebootRequired key' }))

# 3. PendingFileRenameOperations - the signal behind SQL Setup's "Restart computer" rule
$smKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$pfro = (Get-ItemProperty -Path $smKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
$pfroEntries = @($pfro | Where-Object { $_ })   # value is a REG_MULTI_SZ; entries pair old/new paths
$pfroPending = $pfroEntries.Count -gt 0
Add-Result 'PendingFileRenameOperations (blocks SQL Setup rule)' $pfroPending ($(if ($pfroPending) { "$($pfroEntries.Count) entries" } else { 'value absent or empty' }))

# 4. Pending computer rename
$activeName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
$staticName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
$renamePending = $activeName -ne $staticName
Add-Result 'Pending computer rename' $renamePending ($(if ($renamePending) { "active '$activeName' != configured '$staticName'" } else { "name '$activeName'" }))

# 5. ConfigMgr (SCCM) client, when present
try {
    $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' `
                            -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
    $ccmPending = [bool]($ccm.RebootPending -or $ccm.IsHardRebootPending)
    Add-Result 'ConfigMgr client' $ccmPending ($(if ($ccmPending) { 'client reports reboot pending' } else { 'client reports none' }))
} catch {
    Write-Verbose 'ConfigMgr client not present - check skipped.'
}

# Output
Write-Host ''
Write-Host "Pending-reboot check on $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
$results | Format-Table -AutoSize

if ($ShowDetail -and $pfroPending) {
    Write-Host 'PendingFileRenameOperations entries:'
    $pfroEntries | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
}

$anyPending = ($results | Where-Object Pending).Count -gt 0
if ($anyPending) {
    Write-Warning 'A reboot is pending. SQL Server Setup''s "Restart computer" rule will fail - reboot before installing or patching.'
    if ($pfroPending -and -not $ShowDetail) {
        Write-Host 'Tip: rerun with -ShowDetail to see which files are waiting for rename.'
    }
    exit 1
}

Write-Host 'No pending reboot detected - SQL Server Setup''s restart rule should pass.'
exit 0
