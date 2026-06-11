# sqlbootstraplog-review — Checks Explained (U1–U24)

## Contents
- [Summary and Outcome Checks (U1–U6)](#summary-and-outcome-checks-u1u6)
- [Rule-Failure Pattern Checks (U7–U13)](#rule-failure-pattern-checks-u7u13)
- [Detail.txt and MSI Forensic Checks (U14–U18)](#detailtxt-and-msi-forensic-checks-u14u18)
- [ConfigurationFile.ini Review Checks (U19–U24)](#configurationfileini-review-checks-u19u24)
- [Quick Reference](#quick-reference)

The Setup Bootstrap log layout, file purposes, and the documented search methods
("error"/"failed" in Summary.txt, "error"/"exception" at the end of Detail.txt,
"value 3" in MSI logs) come from Microsoft's
[View and read SQL Server Setup log files](https://learn.microsoft.com/sql/database-engine/install-windows/view-and-read-sql-server-setup-log-files).

---

## Summary and Outcome Checks (U1–U6)

### U1 — Setup Final Result Failed

**What it means:** The run's overall verdict. Summary.txt opens with an
"Overall summary" block; anything other than `Passed` in `Final result:` means the
requested action (Install, Upgrade, Patch, AddNode, ...) did not complete.

**How to spot it:**
```
Overall summary:
  Final result:                  Failed: see details below
  Exit code (Decimal):           -2061893606
  Requested action:              Install
```

**Example:** A SQL Server 2022 Express install ends `Failed`, exit code
-2061893606, with Database Engine Services and Replication both listed as
`Status: Failed` in `Detailed results:`.

**Fix options (ranked):**
1. Read `Detailed results:` — each failed feature carries `Component error code:`,
   `Error description:`, and a `Next Step:` (Microsoft's recovery order: resolve,
   uninstall the feature, rerun setup).
2. Run U2 on the error code, U3 on the rules section, U14/U15 on Detail.txt and MSI
   logs to locate the root cause.
3. Keep the whole timestamped log folder (it is also archived as `Log*.cab`) — every
   later check reads from it.

**Related checks:** U2 (error code), U4 (partial failure), U17 (cascade ordering)

---

### U2 — Component Error Code Extraction

**What it means:** Failed features report a `Component error code:` (commonly
`0x84xxxxxx`/`0x85xxxxxx` setup facility codes) plus an `Error description:` and an
`Error help link:` URL that encodes the product version and event ID for lookup.

**How to spot it:**
```
Component name:    SQL Server Database Engine Services Instance Features
Component error code:  0x851A001A
Error description:     Wait on the Database Engine recovery handle failed.
                       Check the SQL Server error log for potential causes.
```

**Example:** `0x851A001A` — the engine binaries installed, but the new instance
failed to start when setup tried to run its configuration steps. The setup log
cannot explain *why*; the new instance's ERRORLOG can.

**Fix options:**
1. Quote the code, description, and help link in the report.
2. For 0x851A001A specifically: open
   `...\MSSQL<nn>.<INSTANCE>\MSSQL\LOG\ERRORLOG` and hand off to
   `/sqlerrorlog-review` — common causes are service account logon failures,
   inaccessible data directories, and storage sector-size issues.
3. For unfamiliar codes, search the code together with the `Error description:`
   text on learn.microsoft.com — the help link resolves to the matching
   troubleshooting article.

**Related checks:** U1, U14 (the same failure seen from Detail.txt)

---

### U3 — Failed Setup Rules Listed

**What it means:** Setup evaluates rule sets (global rules, then scenario-specific
rules) and the Summary ends with `Rules with failures or warnings:`. A failed rule
blocked the run; warnings are advisory.

**How to spot it:**
```
Rules with failures or warnings:
Global rules:
Warning    IsFirewallEnabled    The Windows Firewall is enabled. ...
Rules report file:  C:\...\20251207_165550\SystemConfigurationCheck_Report.htm
```

**Example:** A patch run lists `Failed` for a restart rule; the patch never began
copying files.

**Fix options:**
1. Treat each `Failed` rule as its own finding; map it to U7–U13.
2. Ask for `SystemConfigurationCheck_Report.htm` when the rule name is ambiguous —
   it contains a short description and status for every executed rule.
3. Leave warnings (e.g., `IsFirewallEnabled`) as Info unless they explain a later
   connectivity complaint.

**Related checks:** U7–U13 (per-rule patterns), U13 (global rules phase)

---

### U4 — Partial Feature Failure

**What it means:** One run can install several features; setup reports status per
feature. A mix of `Passed` and `Failed` leaves a partial install on the machine.

**How to spot it:** In `Detailed results:`, one feature `Failed` with
`Reason for failure: An error occurred during the setup process of the feature.`
while a sibling reports `Passed` — or a dependent feature fails with
`An error occurred for a dependency of the feature`.

**Example:** Database Engine Services fails with 0x851A001A; Replication fails as
its dependency; Management Tools pass.

**Fix options:**
1. Identify the root feature (the one whose failure reason is *not* "dependency").
2. Follow its `Next Step:`: resolve the cause, uninstall that feature, rerun setup.
3. After recovery, verify all intended features are `Configured` in the
   "Product features discovered" section of a fresh setup run, or via
   SQL Server Installation Center → Tools → Installed features discovery report.

**Related checks:** U1, U17 (cascade ordering)

---

### U5 — Patch/Upgrade Per-Instance Failure

**What it means:** When patching, setup writes per-instance subfolders (one per
patched instance plus one for shared features), each with a similar set of log
files. One instance can fail while others succeed, leaving mixed binary versions.

**How to spot it:** Log folder contains
`...\<yyyyMMdd_HHmmss>\MSSQLSERVER\`, `...\INST2\`, etc.; the per-instance summary
for one of them reports failure, or the top-level Summary shows a failed instance.

**Example:** A CU applies cleanly to `MSSQLSERVER` but fails on `INST2` with a
file-in-use error; `SELECT @@VERSION` then differs between the two instances.

**Fix options:**
1. Re-run the CU — it detects the partially patched instance and resumes.
2. If it keeps failing, analyze that instance's subfolder Detail.txt (U14) and MSI
   logs (U15).
3. Confirm post-fix with `@@VERSION` per instance and the discovery report.

**Related checks:** U1, U14, U15

---

### U6 — Component Update Phase Failure

**What it means:** Phase 2 of setup checks for updates to the media being
installed (product updates / Microsoft Update). On servers without internet
access this phase can fail or stall before the main action starts.

**How to spot it:** `Product Update Status:` reports an error (a healthy offline
choice reads "User selected not to include product updates."), or Detail.txt shows
the update-search step failing with a network/proxy error.

**Example:** An air-gapped server's install sits in the update search and then
errors; rerunning with updates disabled proceeds normally.

**Fix options:**
1. Rerun with `UpdateEnabled=False` (INI) or `/UpdateEnabled=False` (command line).
2. Or stage the CU locally and set `UpdateSource=<folder>` so setup slipstreams it
   without internet access.
3. If updates were skipped, patch to the target build immediately after install.

**Related checks:** U1, U10

---

## Rule-Failure Pattern Checks (U7–U13)

### U7 — Restart Computer Rule Failed (Pending Reboot)

**What it means:** Setup refuses to run while Windows has a pending reboot. The
most common signal is the `PendingFileRenameOperations` registry value
(`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager`) left behind by a prior
installer; CBS, Windows Update, a pending computer rename, and ConfigMgr can also
set pending-reboot state.

**How to spot it:** A failed restart-type rule (`RebootRequiredCheck` / "Restart
computer") in the Summary rules section or the rules report.

**Example:** A CU run on a server patched by Windows Update an hour earlier fails
the restart rule; after a reboot the CU applies cleanly.

**Fix options:**
1. Run this skill's [`../scripts/check-pending-reboot.ps1`](../scripts/check-pending-reboot.ps1)
   — it checks all five signals and exits 1 when a reboot is pending; `-ShowDetail`
   lists the `PendingFileRenameOperations` entries so you can see which product
   caused the state.
2. Reboot, rerun the script to confirm exit 0, then rerun setup.
3. If the state re-appears after every reboot, an agent or AV product is
   re-creating it — identify it from the `-ShowDetail` file paths and stop it for
   the maintenance window.
4. Make the script a pre-flight gate in patching automation (exit code 0/1).

**Related checks:** U3, U13

---

### U8 — Disk Space Rule Failed

**What it means:** A target volume (install drive, system drive, or a data/log
directory) lacks the free space setup requires — including temp working space.

**How to spot it:** Failed rule or error text naming a drive and a required-space
figure.

**Example:** `C:\` has 1.2 GB free; the engine install requires more on the system
drive even though `INSTANCEDIR` points at `D:\`.

**Fix options:**
1. Free or extend the named volume.
2. Repoint INI directory parameters (`INSTALLSQLDATADIR`, `SQLUSERDBDIR`,
   `SQLTEMPDBDIR`, `SQLBACKUPDIR`) at volumes with capacity — see U24.
3. Clear old `Setup Bootstrap\Log` folders and `%temp%` from prior failed runs.

**Related checks:** U24

---

### U9 — Account or Permission Rule Failed

**What it means:** Setup validates the installing user's rights and every service
account credential before acting. Wrong passwords, locked/expired accounts, an
unreachable domain controller, or a non-admin installer all fail here.

**How to spot it:** Failed rule or error text about credential validation, account
rights, or the installing user; in Detail.txt, the failing action often names the
account.

**Example:** `SQLSVCACCOUNT=CONTOSO\sqlsvc` with a recently rotated password fails
credential validation; the run stops before file copy.

**Fix options:**
1. Re-enter credentials; confirm account state (locked/expired) in AD.
2. Run setup elevated from a local Administrators member.
3. For gMSA: confirm the computer account may retrieve the managed password
   (`Test-ADServiceAccount`).
4. For AddNode: the installing account also needs rights on the WSFC cluster object.

**Related checks:** U11, U19; `/sqlspn-review` post-install

---

### U10 — Prerequisite Rule Failed

**What it means:** The OS or a software prerequisite (.NET Framework, PowerShell,
supported OS version/edition) does not meet the requirements of the SQL Server
version being installed.

**How to spot it:** Failed rule naming the missing prerequisite or unsupported OS.

**Example:** Installing a current SQL Server version on an out-of-support OS build
fails the OS-version rule with no override.

**Fix options:**
1. Install the named prerequisite and rerun.
2. OS unsupported: choose a SQL Server version supported on that OS or move to a
   supported OS — there is no rule override.
3. Check the target version's "hardware and software requirements" page on
   learn.microsoft.com for the exact matrix.

**Related checks:** U13

---

### U11 — Cluster Rule Failed

**What it means:** Failover-cluster scenarios (InstallFailoverCluster, AddNode,
RemoveNode) run extra rules: WSFC service health, node membership, shared storage,
and cluster security checks.

**How to spot it:** Failed cluster-category rule in a clustered `Requested action:`.

**Example:** AddNode fails because the new node has a different OS patch level and
cluster validation reports inconsistent updates across nodes.

**Fix options:**
1. Run the WSFC Cluster Validation wizard and resolve its findings first — setup's
   rules are a subset of it.
2. Align OS patch levels across nodes; confirm the installing account has cluster
   management rights.
3. Cross-reference `/sqlclusterlog-review` for the cluster-side view of the same
   window.

**Related checks:** U9; L-checks in `sqlclusterlog-review`

---

### U12 — Security Policy Blocker

**What it means:** Something outside SQL Server blocked the installer: AppLocker /
Software Restriction Policies, an MSI blocked by policy, media carrying a zone
identifier (mark-of-the-web) after download, or AV quarantining setup binaries.

**How to spot it:** MSI log errors about blocked packages or policy; Windows
Installer error text mentioning policy; setup failing instantly with access
denied on its own binaries.

**Example:** ISO contents copied from a download folder keep the zone identifier;
msiexec refuses the packages until the files are unblocked.

**Fix options:**
1. Unblock the media (file Properties → Unblock; or extract the ISO with a method
   that strips zone identifiers).
2. Temporary AppLocker/SRP exception for the setup folder.
3. Exclude setup working directories from real-time AV during the window.

**Related checks:** U15 (the block usually surfaces as an MSI failure), U16

---

### U13 — Global Rules Phase Failure

**What it means:** Setup's first phase validates basic system requirements. A run
that dies here produces a Summary with rule results but no `Detailed results:`
per-feature section — the requested action never started.

**How to spot it:** Very short Summary; `Final result: Failed` with only global
rule output; Detail.txt ends during rule evaluation.

**Example:** Setup launched non-elevated on a hardened server fails global rules
immediately.

**Fix options:**
1. Fix the named global rule — most map to U7 (reboot), U9 (rights), U10 (OS).
2. If rules cannot execute at all, check WMI health (`winmgmt /verifyrepository`)
   — setup's rule engine depends on WMI.
3. Rerun from an elevated prompt.

**Related checks:** U7, U9, U10

---

## Detail.txt and MSI Forensic Checks (U14–U18)

### U14 — Exception at End of Detail.txt

**What it means:** Detail.txt logs every setup action in invocation order, so a
failed run's exception lands at the end of the file. Microsoft's documented method:
examine the end first, then keyword-search "error" / "exception".

**How to spot it:**
```
(01) 2026-06-11 02:14:55 Slp: Exception type: Microsoft.SqlServer.Configuration...
(01) 2026-06-11 02:14:55 Slp:     Message:  ...
(01) 2026-06-11 02:14:55 Slp:     Inner exception type: System.ComponentModel.Win32Exception
```

**Example:** The last action `SQLEngineConfigAction_install_confignonrc` raises an
exception whose inner Win32Exception is "Access is denied" on the data directory.

**Fix options:**
1. Report the failing action name, exception chain (the inner exception usually
   carries the OS error), and timestamps.
2. Map the action to the feature in U1's `Detailed results:`.
3. The OS error drives the fix (access denied → ACLs/AV; file in use → locking
   process; service start errors → ERRORLOG via U2).

**Related checks:** U2, U15, U16, U17

---

### U15 — MSI Return Value 3

**What it means:** msiexec writes a log per package; a custom action that fails
logs `Return value 3`. Microsoft's documented method: search "value 3" and read
the text immediately around it.

**How to spot it:**
```
Action ended 2:14:51: InstallFiles. Return value 3.
MSI (s) (A0:B4) [02:14:51:307]: Note: 1: 1603
```

**Example:** `sql_engine_core_inst.msi` log shows `Return value 3` right after a
file-copy action with Windows Installer error 1603; AV had locked the target file.

**Fix options:**
1. Identify the failing action and the MSI error code (1603 generic failure,
   1935 assembly/servicing, 1607/1719 installer service issues, ...).
2. The package is identified by the log file name
   (`<Feature>_<Architecture>_<Interaction>.log`).
3. For 1603 with no obvious cause: check U12 (policy/AV) and Windows Installer
   service health; rerun with the media local rather than on a network share.

**Related checks:** U12, U14, U16

---

### U16 — Setup Process Crash

**What it means:** Different from a failed action: the setup process itself died —
a Watson (error reporting) bucket appears, Detail.txt stops mid-action, or the
Summary reports a `Pending`/absent final result.

**How to spot it:** Abrupt end of Detail.txt with no closing summary; a
`Final result: Pending` that never resolves; Application event log shows setup
crashing.

**Example:** An upgrade Summary says `Pending` after 11 seconds while Detail.txt
shows another 18 minutes of activity, then silence — the host was rebooted
mid-upgrade.

**Fix options:**
1. Rule out corrupt media: re-download, verify checksum, run from a local path.
2. Check the Application event log for the faulting module at the crash time.
3. If the machine restarted mid-run, rerun setup — it detects and resumes/repairs
   the interrupted operation; use Repair when the instance is left broken.

**Related checks:** U5, U14, U15

---

### U17 — Failure Cascade Ordering

**What it means:** One root failure commonly produces several downstream failures
(dependent features, later actions). Reporting all of them as equal findings sends
the operator chasing symptoms.

**How to spot it:** Multiple `Failed` features where all but one say
"An error occurred for a dependency of the feature"; multiple Detail.txt errors
where only the earliest is independent.

**Example:** Engine fails to start (root); Replication fails as a dependency;
post-install validation actions fail as cascade. One fix, one rerun.

**Fix options:**
1. Sort failures by Detail.txt timestamp; the earliest independent failure is the
   root cause.
2. Use `Reason for failure:` text to mark dependency failures as cascade.
3. Report exactly one root cause and list the rest under it.

**Related checks:** U1, U4, U14

---

### U18 — Datastore State Referenced

**What it means:** The `Datastore\` subfolder holds XML dumps of every
configuration object setup tracked, snapshotted per execution phase — what setup
*believed* each setting to be. Useful when no action failed but the result is not
what the operator intended.

**How to spot it:** Configuration disputes ("I set the collation/IFI/directories
differently") with an inconclusive Summary; the Datastore folder exists in the
timestamped log folder.

**Example:** Operator insists they enabled IFI in the UI; the Datastore instance
settings XML shows `SQLSVCINSTANTFILEINIT` false — the checkbox was not set.

**Fix options:**
1. Ask for the relevant Datastore XML and compare against intent.
2. Use it to close "setup ignored my setting" disputes — it records the effective
   input.
3. Correct via post-install change or a fresh INI for the next build.

**Related checks:** U19–U24

---

## ConfigurationFile.ini Review Checks (U19–U24)

`ConfigurationFile.ini` records the run's input settings and can drive a repeat
unattended install. Passwords, PID, and some parameters are not saved into it.
The same parameters appear under `User Input Settings:` in the Summary.

### U19 — Service Account Choice

**What it means:** The engine/Agent service identity is fixed at setup. Shared
built-ins (LocalSystem, NETWORK SERVICE) widen blast radius; plain domain users
need manual password rotation; virtual accounts (`NT Service\MSSQLSERVER`) and
gMSAs are the maintained patterns.

**How to spot it:** `SQLSVCACCOUNT` / `AGTSVCACCOUNT` values in the INI or
User Input Settings.

**Example:** `SQLSVCACCOUNT: NT AUTHORITY\SYSTEM` on a production engine —
any engine compromise is instant LocalSystem.

**Fix options:**
1. Standalone default: keep `NT Service\MSSQLSERVER` (virtual account).
2. Domain estates needing cross-machine identity (AG endpoints, Kerberos,
   UNC backups): gMSA.
3. Change later only via SQL Server Configuration Manager so the required rights
   and key ACLs are re-granted.

**Related checks:** U9, U22; K-checks in `sqlspn-review`

---

### U20 — Instant File Initialization Not Granted at Setup (SQL 2016+)

**What it means:** Since SQL Server 2016, setup can grant the engine account
"Perform volume maintenance tasks" (`SQLSVCINSTANTFILEINIT=True`), enabling
instant file initialization. Without IFI, data-file create/grow/restore
zero-fills every byte.

**How to spot it:** `SQLSVCINSTANTFILEINIT: false` (or absent) in the INI /
User Input Settings.

**Example:** A 500 GB restore spends most of its time zero-filling because IFI
was never granted at install.

**Fix options:**
1. Grant now: secpol.msc → "Perform volume maintenance tasks" → add the engine
   service account → restart the service.
2. Fleet builds: `/SQLSVCINSTANTFILEINIT="True"` in the INI.
3. Verify: `sys.dm_server_services.instant_file_initialization_enabled = 'Y'`
   (cross-check `/sqldbconfig-review` B22).
4. Note: log files do not use IFI (SQL 2022+ allows IFI for log autogrowth events
   up to 64 MB only).

**Related checks:** B22 in `sqldbconfig-review`; Z11 in `sqldiskio-review`

---

### U21 — TempDB Setup Parameters Undersized (SQL 2016+)

**What it means:** Since SQL Server 2016, setup configures TempDB
(`SQLTEMPDBFILECOUNT`, `SQLTEMPDBFILESIZE`, `SQLTEMPDBFILEGROWTH`,
`SQLTEMPDBDIR`, log equivalents). Defaults are sized for small machines; leaving
them produces allocation contention and constant autogrowth on real workloads.

**How to spot it:**
```
SQLTEMPDBFILECOUNT:            1
SQLTEMPDBFILESIZE:             8
SQLTEMPDBDIR:                  <empty>
```
on a 16-core production server.

**Example:** 1 × 8 MB TempDB data file on 12 cores — PAGELATCH contention on
PFS/GAM from day one.

**Fix options:**
1. `SQLTEMPDBFILECOUNT` = MIN(logical processors, 8), equal sizes, same growth.
2. Pre-size files to workload (hundreds of MB to GBs), dedicated volume via
   `SQLTEMPDBDIR`.
3. Already installed: fix live (`ALTER DATABASE tempdb MODIFY FILE ...`) and
   validate with `/sqldbconfig-review` B23 and `/sqldiskio-review` Z7–Z9.

**Related checks:** U24; B23, V9

---

### U22 — Security Surface Widened at Setup

**What it means:** Setup decides authentication mode and enabled protocols.
`SECURITYMODE=SQL` enables mixed authentication (the `sa` surface);
`TCPENABLED` / `NPENABLED` control TCP and named pipes.

**How to spot it:** `SECURITYMODE: SQL`, `NPENABLED: 1`, or a `TCPENABLED` value
that contradicts the server's purpose, in the INI / User Input Settings.

**Example:** Mixed mode requested "just in case", `sa` left enabled with a weak
password — the most common brute-force target.

**Fix options:**
1. Prefer Windows authentication; enable mixed mode only for a documented
   application need, then disable or rename `sa`.
2. Align protocols with intent in SQL Server Configuration Manager (per-instance
   TCP/NP) post-install.
3. Post-install posture review: `/sqldbconfig-review` B24–B28.

**Related checks:** U19; B24–B28

---

### U23 — Feature Sprawl in FEATURES List

**What it means:** Every feature in `FEATURES=` is patch surface, attack surface,
and (for AS/RS) a separate service competing for memory outside
`max server memory`.

**How to spot it:** `FEATURES: SQLENGINE, AS, RS, DQ, IS` on a box whose stated
purpose is an OLTP engine.

**Example:** Reporting Services installed but never configured still receives CUs
and runs a service.

**Fix options:**
1. Uninstall unused features (Programs and Features → SQL Server → Remove →
   select features).
2. Keep fleet INIs minimal: `FEATURES=SQLENGINE` plus only what the role needs.
3. Memory-competition symptoms: `/sqlmemory-review` O18/O20.

**Related checks:** U24; O18, O20

---

### U24 — Directory Co-location at Setup

**What it means:** The INI's directory parameters (`INSTALLSQLDATADIR`,
`SQLUSERDBDIR`, `SQLUSERDBLOGDIR`, `SQLTEMPDBDIR`, `SQLBACKUPDIR`) decide volume
placement. Everything left at defaults lands under
`C:\Program Files\Microsoft SQL Server\` — data, log, TempDB, and backups
competing on the system drive.

**How to spot it:** All directory parameters `<empty>` or pointing at the same
drive letter in the INI / User Input Settings.

**Example:** `INSTANCEDIR: C:\Program Files\Microsoft SQL Server\` with every
data directory empty — a data file growth event can fill `C:\` and freeze the OS.

**Fix options:**
1. At install: data, log, TempDB, backups each on appropriate volumes; nothing
   that grows on the system drive.
2. Already installed: move files (offline `ALTER DATABASE ... MODIFY FILE` +
   file move), system DBs per the documented procedure.
3. Validate placement and latency: `/sqldiskio-review` Z6–Z10.

**Related checks:** U8, U21; Z6–Z10

---

## Quick Reference

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| U1 | Outcome | Final result not Passed | Critical |
| U2 | Outcome | Component error code on failed feature | Critical |
| U3 | Outcome | Failed rule in rules section | Critical (rule) / Info (warning) |
| U4 | Outcome | Mixed Passed/Failed features | Critical |
| U5 | Outcome | Patch failed for one instance | Critical |
| U6 | Outcome | Product update phase error | Warning |
| U7 | Rules | Restart computer rule failed | Critical |
| U8 | Rules | Disk space rule failed | Critical |
| U9 | Rules | Account/permission rule failed | Critical |
| U10 | Rules | Prerequisite rule failed | Critical |
| U11 | Rules | Cluster rule failed | Critical |
| U12 | Rules | Policy/AV blocked installer | Critical |
| U13 | Rules | Global Rules phase failure | Critical |
| U14 | Forensics | Exception at end of Detail.txt | Critical |
| U15 | Forensics | MSI "Return value 3" | Critical |
| U16 | Forensics | Setup process crash / Pending result | Critical |
| U17 | Forensics | Multiple failures — order by causality | Info |
| U18 | Forensics | Datastore XML consulted | Info |
| U19 | INI | Built-in/shared service account | Warning |
| U20 | INI | SQLSVCINSTANTFILEINIT false/absent (2016+) | Warning |
| U21 | INI | TempDB file count/size at defaults (2016+) | Warning |
| U22 | INI | Mixed auth / protocol surface | Warning |
| U23 | INI | FEATURES beyond server purpose | Info |
| U24 | INI | Directories co-located / on system drive | Warning |
