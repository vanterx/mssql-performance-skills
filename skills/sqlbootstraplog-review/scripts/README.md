# sqlbootstraplog-review — Scripts

Reference scripts for users. Run them on the SQL Server host (not inside this
skill) and paste the output, or use them as pre-flight gates in patching
automation.

## check-pending-reboot.ps1

Detects the Windows pending-reboot conditions that fail SQL Server Setup's
"Restart computer" rule (check U7) — run it **before** launching setup or
applying a CU/SP, and again afterwards to see whether the installer left a
reboot pending.

**Signals checked:**

| # | Signal | Source |
|---|--------|--------|
| 1 | Component Based Servicing | `HKLM\...\Component Based Servicing\RebootPending` |
| 2 | Windows Update | `HKLM\...\WindowsUpdate\Auto Update\RebootRequired` |
| 3 | Pending file renames (the signal Setup's rule checks) | `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager : PendingFileRenameOperations` |
| 4 | Pending computer rename | `ActiveComputerName` vs `ComputerName` |
| 5 | ConfigMgr (SCCM) client | `CCM_ClientUtilities.DetermineIfRebootPending` (skipped if absent) |

**Usage:**

```powershell
# Summary table + exit code (0 = clear, 1 = reboot pending)
.\check-pending-reboot.ps1

# Also list the files behind PendingFileRenameOperations
# (reveals which product caused the pending state)
.\check-pending-reboot.ps1 -ShowDetail
```

**Prerequisites:** Windows PowerShell 5.1+ or PowerShell 7+; read access to
HKLM (run elevated for completeness). The ConfigMgr check needs the ConfigMgr
client and is skipped silently without it.

**Automation:** the exit code makes it a drop-in pre-flight gate:

```powershell
.\check-pending-reboot.ps1
if ($LASTEXITCODE -ne 0) { Restart-Computer -Force }   # then rerun the gate
```
