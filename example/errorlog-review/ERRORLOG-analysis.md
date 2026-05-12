# SQL Server ERRORLOG Analysis

### Summary
- **2 Critical, 2 Warnings, 3 Info**
- **Time range:** 2026-01-15 14:00:01 – 2026-01-15 15:00:33
- **SQL Server version:** Microsoft SQL Server 2019 (RTM-CU22) (KB5027702) - 15.0.4316.3 (X64) — Enterprise Edition, Windows Server 2022 Hypervisor
- **Highest-risk finding:** C1 — E15 I/O Subsystem Slow (root cause of the AG failover chain)
- **Log coverage note:** Single ERRORLOG file; 60-minute window; prior log (ERRORLOG.1) not provided — events before 14:00 are not visible

---

## Critical Issues

### [C1 — E15] I/O Subsystem Slow — E:\Data\AG1_SalesDB.mdf (14:28:44)

- **Observed:** Three separate `I/O requests taking longer than 15 seconds` entries for SalesDB (database ID 7):
  - 14:28:44 — E:\Data\AG1_SalesDB.mdf (data file)
  - 14:28:50 — E:\Data\AG1_SalesDB_log.ldf (log file)
  - 14:29:11 — E:\Data\AG1_SalesDB.mdf (second occurrence on data file; "2 occurrence(s)")
  - A fourth entry at 14:58:44 on E:\Data\AG1_SalesDB.mdf confirms the storage problem persisted after the failover
- **Impact:** Storage latency on E:\ exceeded 15 seconds on both the data and log file for SalesDB. The sp_server_diagnostics thread, which must report to WSFC within the `HealthCheckTimeout` window (30 seconds, as shown at 14:31:58), could not complete while I/O was blocked. This triggered the AG health-check timeout (E6 at 14:29:33), which triggered lease expiry (E2 at 14:32:05), which triggered the unplanned AG failover (E1 at 14:32:08). The I/O at 14:58:44 after failover indicates the root cause on E:\ has not been resolved — the new primary is also at risk.
- **Fix:**
  1. Investigate E:\ storage immediately — check disk queue length, RAID controller cache battery status, VM IOPS allocation. The VM hypervisor line in the startup entry (`on Windows Server 2022 (Hypervisor)`) confirms this is a virtual machine; check whether the IOPS cap was reached during the backup workload at 14:15 and 14:20.
  2. Move SalesDB data and log files to a storage volume with guaranteed low latency (separate from backup destinations).
  3. Run `/sqlwait-review` on the next wait statistics capture — look for `PAGEIOLATCH_SH` and `PAGEIOLATCH_EX` dominance.
  4. Resolve before the next scheduled backup to prevent recurrence.

---

### [C2 — E2] Lease Expiry — AG1 (14:32:05)

- **Observed:** `The lease between the availability group 'AG1' and the Windows Server Failover Cluster has expired` at 14:32:05. Immediately preceded by E6 (AG health-check timeout, 14:31:58). Root cause is C1 — E15 (I/O subsystem slow, 14:28:44–14:29:11).
- **Impact:** WSFC concluded the primary was unhealthy and initiated an automatic failover. AG1 transitioned from PRIMARY to SECONDARY on this instance at 14:32:08 and then back to PRIMARY on this instance at 14:32:12 (apparent re-election), with the full role-change sequence completing by 14:32:12. Applications lost their primary connection to AG1 databases during this window — approximately 4–7 seconds of disruption for applications using the AG listener. Any uncommitted transactions on SalesDB at 14:32:05 were rolled back.
- **Fix:**
  1. Root cause is E:\ storage latency (C1 — E15). Resolving the I/O issue prevents recurrence.
  2. Do not increase `LeaseTimeout` or `HealthCheckTimeout` in WSFC as a first response — this masks the storage problem and increases the time SQL Server appears unhealthy before failover.
  3. After resolving storage, verify AG1 synchronisation state: `SELECT synchronization_state_desc, redo_queue_size FROM sys.dm_hadr_database_replica_states`.
  4. Review the secondary replica's I/O as well — the fourth I/O slow entry at 14:58:44 occurred after the failover, suggesting both replicas share the same E:\ volume, which is a configuration risk.

---

## Warnings

### [W1 — E1] AG Failover Event — AG1 (14:32:08)

- **Observed:** `AG1 is changing roles from PRIMARY to SECONDARY because of an automatic failover` at 14:32:08, followed immediately by a transition back to PRIMARY at 14:32:12 on the same instance. This is a rapid failover-and-failback sequence, not a full replica switch to the secondary server.
- **Impact:** The failover sequence (14:32:05 lease expiry → 14:32:08 PRIMARY to SECONDARY → 14:32:09 role change → 14:32:12 back to PRIMARY) indicates WSFC attempted failover but the secondary replica was not ready or suitable, causing an immediate failback. Applications connected via the AG listener would have experienced connection errors during this 7-second window.
- **Fix:**
  1. This is a downstream consequence of C1 and C2. Resolving the I/O issue prevents recurrence.
  2. Review the secondary replica readiness: confirm automatic failover mode is configured and the secondary is synchronised before the next incident.
  3. Check the Windows Event Log and WSFC cluster log for the failover decision details around 14:32.

---

### [W2 — E22] Login Failure Burst — 'sa' from 203.0.113.44 (14:33:01–14:33:03)

- **Observed:** 26 `Login failed for user 'sa'` entries from IP 203.0.113.44 within approximately 2.5 seconds (14:33:01.11 to 14:33:03.99). Error state 8 = password did not match. This IP is in the 203.0.113.0/24 TEST-NET range (documentation/example range) but would represent an external IP in a real environment.
- **Impact:** 26 failures in 2.5 seconds far exceeds the Critical threshold of 20 failures in 5 minutes. This is a brute-force credential attack against the `sa` account from an external source. The attempt coincides with the AG failover window at 14:32, which may not be coincidental — attackers sometimes exploit failover windows when monitoring activity may be disrupted.
- **Fix:**
  1. Block 203.0.113.44 at the network firewall immediately.
  2. Verify the `sa` account is disabled: `SELECT name, is_disabled FROM sys.server_principals WHERE name = 'sa'`. If enabled, disable it: `ALTER LOGIN [sa] DISABLE`.
  3. Enable failed login auditing if not already set (E25 shows TF 3226 suppresses successful backups, not logins — verify separately):
     ```sql
     EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
         N'Software\Microsoft\MSSQLServer\MSSQLServer',
         N'AuditLevel', REG_DWORD, 2;
     ```
  4. Review firewall rules — TCP port 1433 should not be directly accessible from the internet.

---

## Info

### [I1 — E25] Trace Flags Active at Startup (14:00:01)

- **Observed:** Two trace flags enabled at startup: TF 3226 (`Suppress successful backup log messages`) and TF 4199 (`Enable query optimizer fixes for all query plans`).
- **Impact:** TF 3226 reduces ERRORLOG noise by suppressing successful backup completion messages — the backup entries visible at 14:15 and 14:20 are for log backups, which are typically not suppressed by TF 3226 (it suppresses full/differential database backup entries by default). TF 4199 enables all QO hotfixes that are off by default — on SQL 2019 CU22, this is beneficial for complex query plans but adds some risk of plan regressions on upgrade. Both flags appear intentional and documented.
- **Fix:** No immediate action required. Verify TF 4199 intent: in SQL Server 2022, many QO fixes are enabled by default under compatibility level 160, making TF 4199 unnecessary on upgraded instances. After any future CU upgrade, re-evaluate whether both flags are still needed.

---

### [I2 — E19] VLF Proliferation Signal — SalesDB (multiple autogrow events)

- **Observed:** Four `Autogrow of file 'SalesDB_log'` entries in the 60-minute window: 14:02:33 (1244 ms), 14:25:03 (1887 ms), 14:36:03 (2033 ms), 14:48:55 (1671 ms). Average autogrow delay: 1.7 seconds per event. Each autogrow creates new VLFs; the growth duration suggests the log file is growing in 8 MB increments (short autogrow = small increment).
- **Impact:** Four autogrow events in 60 minutes on SalesDB indicates the log file is not sized for the workload. Each autogrow introduces latency into the transactions waiting for log flush. Over time, thousands of small VLFs will degrade recovery performance, log backup speed, and crash recovery time.
- **Fix:**
  1. Run `DBCC LOGINFO([SalesDB])` to count current VLFs — if > 500, consolidate.
  2. Pre-size the log file: `ALTER DATABASE [SalesDB] MODIFY FILE (NAME = N'SalesDB_log', SIZE = 10240MB, FILEGROWTH = 1024MB)`. The SIZE should be large enough to eliminate autogrow under normal workloads.
  3. Set a larger autogrow increment (1 GB) as a safety net — not as the primary sizing strategy.

---

### [I3 — E28] SQL Server Version — 2019 RTM-CU22 (14:00:01)

- **Observed:** `Microsoft SQL Server 2019 (RTM-CU22) (KB5027702) - 15.0.4316.3` running on Windows Server 2022 Hypervisor. SQL Server 2019 mainstream support ends 2025-01-07; extended support ends 2030-01-08.
- **Impact:** CU22 was released July 2023. As of 2026-01, SQL Server 2019 CU29 (15.0.4415.2) is the current CU — approximately 7 cumulative updates behind. Notable fixes in CU23–CU29 include memory grant estimation improvements (relevant to E14 risk), non-yielding scheduler fixes (relevant to E13 risk), and AG failover reliability improvements (relevant to C1/C2). The instance is within extended support but not on the latest CU.
- **Fix:** Plan CU upgrade to 2019 CU29 in a maintenance window. Test in a non-production environment first to validate no plan regressions occur with TF 4199 (I1).

---

## Passed Checks

| Check | Result |
|-------|--------|
| E3 — Replica State Change | PASS — state change at 14:32:08 is fully explained by C2 (lease expiry); no unexpected independent transitions observed |
| E4 — AG Database Joining Failure | PASS — SalesDB and ReportingDB joined AG1 successfully at 14:35:23 |
| E5 — Data Synchronisation Suspended | PASS — no `Data movement suspended` entries found; databases resumed sync after failover |
| E6 — AG Health Check Timeout | Fired — precursor to C2; logged at 14:29:33 and 14:31:58 as part of the failover chain |
| E7 — Redo Thread Error | PASS — no `error occurred in the redo thread` entries found |
| E8 — Secondary Not Synchronising | PASS — no `Waiting for redo catch-up` entries found; secondary joined cleanly at 14:35 |
| E9 — FAIL_PAGE_ALLOCATION | PASS — no `FAIL_PAGE_ALLOCATION` entries found |
| E10 — OS Memory Pressure | PASS — no `significant part of sql server process memory has been paged out` entries found |
| E11 — Buffer Pool Insufficient | PASS — no `insufficient system memory in resource pool` entries found |
| E12 — Worker Thread Exhaustion | PASS — no `no more threads available` entries found |
| E13 — Scheduler Non-Yielding | PASS — no `non-yielding on Scheduler` entries found |
| E14 — Memory Grant Timeout | PASS — no `Memory grant request timed out` entries found |
| E16 — Database Corruption Warning | PASS — no `checksum mismatch`, `torn page`, or `consistency errors` entries found |
| E17 — TempDB Space Exhaustion | PASS — no `Could not allocate space in database tempdb` entries found |
| E18 — Log Backup Overdue | PASS — SalesDB: log backups at 14:15, 14:38, 14:50 (max gap ~35 min); ReportingDB: backups at 14:20, 14:45 (max gap ~25 min); AdventureWorks2019: backup at 15:00 (prior backup in ERRORLOG.1 not visible — SKIP for prior gap; current log shows one backup within the window) |
| E20 — Abnormal Shutdown | PASS — instance shut down cleanly: `SQL Server is terminating in response to a stop request from Service Control Manager` at 15:00:33 |
| E21 — Repeated Restarts | PASS — only one startup message in the 60-minute window (at 14:00:01); no crash-loop pattern |
| E23 — Linked Server Error | PASS — no `OLE DB provider reported an error` entries found |
| E24 — Connectivity Error | PASS — no pre-login handshake errors; the two login failures for 'AppUser' at 14:00:14 are an application misconfiguration (database 'OldAppDB' does not exist) — minor, not a connectivity error pattern |
| E26 — Max Server Memory Default | SKIP — no explicit `max server memory` startup message visible in this log; recommend verifying: `SELECT name, value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)'` |
| E27 — ERRORLOG Rotation Gap | INFO — single file provided, covering 14:00–15:00 only. Prior ERRORLOG.1 not provided. The instance started at 14:00:01 (suggesting a prior restart — the log reinitialisation message confirms this). Events before 14:00 are not visible; retrieve with `EXEC xp_readerrorlog 1, 1`. |

---

## Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Investigate E:\ storage latency — check VM IOPS allocation, RAID controller cache, disk queue length | C1 — E15, C2 — E2, W1 — E1 | 30–60 min |
| 2 — Immediately | Block 203.0.113.44 at firewall; verify `sa` login is disabled | W2 — E22 | 10 min |
| 3 — Today | Move SalesDB data/log files to separate, lower-latency storage volume (not shared with backup destination) | C1 — E15 (prevention) | 2–4 hr (maintenance window) |
| 4 — Today | Retrieve ERRORLOG.1 to determine what caused the restart at ~14:00 | E27 | 10 min |
| 5 — This week | Pre-size SalesDB log file; increase autogrow increment to eliminate repeated autogrow events | I2 — E19 | 30 min |
| 6 — This week | Plan CU upgrade to SQL Server 2019 CU29 in a test environment | I3 — E28 | 4–8 hr |
| 7 — Ongoing | Verify `max server memory` is explicitly configured (not 2147483647 default) | E26 | 15 min |
