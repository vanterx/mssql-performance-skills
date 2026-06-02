# WSFC Cluster Log — Checks Explained (L1–L30)

## Contents

- [File-Wide Pattern Checks (L1–L8)](#file-wide-pattern-checks-l1l8)
- [AG Resource Checks (L9–L17)](#ag-resource-checks-l9l17)
- [Network and Node Checks (L18–L22)](#network-and-node-checks-l18l22)
- [Configuration Signal Checks (L23–L25)](#configuration-signal-checks-l23l25)
- [Modern Cluster Feature Checks (L26–L30)](#modern-cluster-feature-checks-l26l30)
- [Quick Reference Table](#quick-reference-table)

---


Plain-English explanations of every check in `clusterlog-review`. Each entry follows the
five-part structure: **What it means / How to spot it / Example / Fix options / Related checks**.

---

## File-Wide Pattern Checks (L1–L8)

### L1 — Lease Timeout

**What it means:**
SQL Server maintains a lease with WSFC to prove the SQL Server process is alive and healthy.
A dedicated lease thread inside SQL Server renews this lease on a fixed interval. If the lease
thread cannot run — because schedulers are starved, memory is paging, or I/O is hung — the
lease expires and WSFC declares the AG resource failed immediately, with no grace period.
This is the most common root cause of unexpected AG failovers on busy systems.

**How to spot it:**
```
00002cc4.00001264::2026/01/15-14:32:01.543 ERR  [RES] SQL Server Availability Group <AG1>:
[hadrag] Lease Thread terminated. Lease time expired.
```
Look for `Lease Thread terminated`, `lease time expired`, or `LeaseExpired` in `[hadrag]`
or `[RES]` log entries. The timestamp marks the exact moment WSFC declared the AG failed.

**Example:**

Problem — lease expiry caused by scheduler starvation:
```
14:31:55.100 ERR  [hadrag] Lease renewal attempt failed — scheduler not available
14:32:01.543 ERR  [hadrag] Lease Thread terminated. Lease time expired.
14:32:01.600 ERR  [RCM]   Resource AG1 transitioning: Online-->Offline
```

Fix — identify the long-running query blocking a scheduler during that window:
```sql
SELECT session_id, blocking_session_id, wait_type, wait_time, status, text
FROM sys.dm_exec_requests
CROSS APPLY sys.dm_exec_sql_text(sql_handle)
WHERE wait_time > 15000;
```

**Fix options:**
1. Capture `sys.dm_os_ring_buffers` immediately after the next incident: `WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'` — shows scheduler usage at the time of the lease failure.
2. Check for memory pressure causing physical paging: `DBCC MEMORYSTATUS` or `sys.dm_os_memory_clerks` sorted by `pages_kb` descending.
3. If storage I/O is the cause, measure average disk latency on the SQL Server system drive — values above 10 ms for sequential writes can delay the health thread.
4. As a last resort, raise `HealthCheckTimeout` on the AG resource property (default 30,000 ms) to give SQL Server more time before WSFC declares it failed.

**Related checks:** L2, L10, L12

---

### L2 — Health Check Failure

**What it means:**
The AG resource DLL (hadrres.dll) monitors SQL Server health by calling `sp_server_diagnostics`
at regular intervals. This stored procedure reports the health state of the system (state 1–5).
States 3 (Warning) and above can trigger a resource failure depending on the `FailureConditionLevel`
AG property. LooksAlive checks whether the SQL Server process is running; IsAlive runs the full
sp_server_diagnostics query.

**How to spot it:**
```
00003cc4.00001265::2026/01/15-14:31:58.012 ERR  [RES] SQL Server Availability Group <AG1>:
[hadrag] IsAlive check failed. HealthCheckTimeout exceeded.
```
Look for `IsAlive check failed`, `LooksAlive check failed`, or `HealthCheckTimeout` in
`[RES]`/`[hadrag]` messages. Note whether it is LooksAlive (process-level) or IsAlive
(query-level) — the distinction identifies the failure layer.

**Example:**

Problem:
```
14:31:58.012 ERR  [hadrag] IsAlive check failed. HealthCheckTimeout = 30000 ms exceeded.
14:31:58.015 ERR  [hadrag] Initiating resource failure.
```

Fix — set a longer diagnostic collection first to understand frequency:
```sql
-- Enable Extended Events for sp_server_diagnostics results:
CREATE EVENT SESSION [ag_health] ON SERVER
ADD EVENT sqlserver.hadr_health_issue(
    WHERE state >= 3)
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION [ag_health] ON SERVER STATE = START;
```

**Fix options:**
1. Review `sp_server_diagnostics` output manually: `EXEC sp_server_diagnostics 5` — run during a high-load period to see which component reports Warning or Error.
2. Raise `FailureConditionLevel` on the AG resource from the default (3) to 4 or 5 to only failover on the most severe conditions (reduces false positives from transient resource pressure).
3. Fix underlying performance issues causing the health check query to time out (see L1 fix options).
4. Check that `sp_server_diagnostics` is not blocked by an open transaction on the DAG health thread.

**Related checks:** L1, L12, L14

---

### L3 — RHS Process Crash

**What it means:**
The Resource Hosting Subsystem (rhs.exe) is the Windows process that hosts resource DLLs,
including hadrres.dll. If rhs.exe crashes — due to an unhandled exception in any DLL it hosts,
a memory access violation, or a third-party DLL injected into the process — every resource
hosted in that rhs.exe process goes offline simultaneously. Without `SeparateMonitor`, the AG
resource shares rhs.exe with other cluster resources, meaning another DLL's bug can kill the AG.

**How to spot it:**
```
00001234.00000456::2026/01/15-14:30:00.001 WARN [RHS] RHS.EXE process terminated unexpectedly.
00001234.00000457::2026/01/15-14:30:00.100 INFO [RHS] Creating new RHS process.
00001234.00000458::2026/01/15-14:30:00.200 ERR  [RCM] Resource AG1 failed — RHS process crash.
```
Look for `RHS.EXE terminated`, `creating new RHS process`, or `unhandled exception` in `[RHS]`.

**Example:**

Problem — third-party DLL loaded into shared rhs.exe caused access violation:
```
14:30:00.001 WARN [RHS] rhs.exe terminated (PID 4892) — unhandled exception code 0xC0000005
14:30:00.100 INFO [RHS] Creating new RHS process (PID 5020)
14:30:00.200 ERR  [RCM] Resource AG1 offline — RHS process failure
```

Fix — enable SeparateMonitor to isolate the AG's DLL in its own process:
```powershell
$agRes = Get-ClusterResource "SQL Server Availability Group (AG1)"
$agRes | Set-ClusterParameter SeparateMonitor 1
# Restart the resource to apply:
Stop-ClusterResource $agRes
Start-ClusterResource $agRes
```

**Fix options:**
1. Enable `SeparateMonitor` on the AG resource (see L24) — prevents other DLLs from crashing the AG's host process.
2. Review Windows Application event log for Event ID 1146 (RHS terminated) and capture the accompanying crash dump in `%SystemRoot%\Minidump`.
3. Remove third-party cluster resource DLLs from the shared rhs.exe if identified as the fault source.
4. Open a Microsoft support case with the crash dump if the faulting module is a Microsoft DLL.

**Related checks:** L24, L4

---

### L4 — Error Burst Density

**What it means:**
A dense cluster of ERR-level entries in a short window is the cluster log's equivalent of an
alarm going off. It signals multiple subsystems failing in rapid succession — almost always
caused by a single root cause event that cascades. The value of this check is identifying
the temporal boundary of the incident and the first ERR entry, which is typically the origin.

**How to spot it:**
Count ERR lines within any 5-minute sliding window. The first ERR in a burst is the originating
failure; subsequent ERRs are usually cascades from the same cause.
```
14:31:55.100 ERR  [hadrag] ...
14:31:58.012 ERR  [hadrag] ...
14:32:01.543 ERR  [RCM]   ...
14:32:02.001 ERR  [RES]   ...
```

**Example:**

Problem — 8 ERR lines in 3 minutes, first one is a lease renewal failure:
```
14:31:55 ERR  [hadrag] Lease renewal failed
14:31:58 ERR  [hadrag] IsAlive check failed
14:32:01 ERR  [hadrag] Lease Thread terminated
14:32:01 ERR  [RCM]   AG1 transitioning Online-->Offline
14:32:02 ERR  [RES]   SQL Server not responding
14:32:03 ERR  [RCM]   Initiating failover for AG1
14:32:05 ERR  [NM]    Network interface state change
14:32:07 ERR  [RCM]   AG1 resource failed
```
The root cause is the `14:31:55` lease renewal failure (L1). All other ERRs are cascades.

**Fix options:**
1. Identify the earliest ERR timestamp in the burst — that line is the root cause. Fix it first; all later ERRs in the burst will stop.
2. Group ERR lines by component (`[hadrag]`, `[RCM]`, `[RHS]`, `[NM]`) — if all components appear, it is a systemic failure; if only `[hadrag]`, it is SQL Server-specific.
3. Compare the burst timestamp with the Windows System event log and SQL ERRORLOG to correlate with OS-level events.

**Related checks:** L1, L2, L3, L15

---

### L5 — Repeated Failover Cycling

**What it means:**
When the root cause of an AG failure is not fixed, the cluster repeatedly tries to bring
the AG resource online — and fails each time. This cycling exhausts the `MaxRestarts` limit
(default: 1 restart in 15 minutes for most versions) and leaves the AG permanently offline.
The pattern in the log is a sequence of Online→Offline→Online→Offline events for the same
AG resource within a short window.

**How to spot it:**
Search for repeated transitions for the same AG resource name within a 30-minute window:
```
14:32:01 ERR  [RCM] AG1 transitioning: Online-->Offline
14:32:15 INFO [RCM] AG1 transitioning: Offline-->OnlinePending
14:32:45 ERR  [RCM] AG1 transitioning: OnlinePending-->Offline
14:33:00 INFO [RCM] AG1 transitioning: Offline-->OnlinePending
14:33:30 ERR  [RCM] AG1 transitioning: OnlinePending-->Offline
```

**Example:**

Problem — three cycles in 10 minutes, each failing at OnlinePending:
```
14:32:01 ERR  AG1 Online-->Offline   (lease timeout — L1)
14:32:15 INFO AG1 Offline-->OnlinePending
14:32:45 ERR  AG1 OnlinePending-->Offline  (health check still failing)
14:33:00 INFO AG1 Offline-->OnlinePending
14:33:30 ERR  AG1 OnlinePending-->Offline  (health check still failing)
14:35:00 ERR  AG1 exceeded MaxRestarts — resource left offline
```

Fix — stop the cycling and fix the root cause before attempting manual restart:
```powershell
# Stop cycling by taking the resource offline manually:
Stop-ClusterResource "SQL Server Availability Group (AG1)"
# Fix root cause (L1, L2, or L18), then:
Start-ClusterResource "SQL Server Availability Group (AG1)"
```

**Fix options:**
1. Take the AG resource offline manually to halt the cycling while diagnosing the root cause.
2. Identify the failure at each OnlinePending→Offline transition — if it is the same failure (L1, L2), the root cause has not been resolved between restarts.
3. Raise `MaxRestarts` temporarily only if the root cause is transient (e.g., a brief network blip at L18). Do not raise it if the failure is persistent.

**Related checks:** L1, L2, L18, L9

---

### L6 — Quorum Loss

**What it means:**
A WSFC cluster requires a quorum (majority of votes) to operate. If too many nodes or the
witness become unavailable simultaneously, quorum is lost and the cluster service stops on
all nodes — taking every AG and clustered resource offline. Quorum loss is a total outage
that cannot be resolved by restarting the AG resource alone.

**How to spot it:**
```
00002cc4.00003344::2026/01/15-14:33:00.001 ERR  [NM] Lost quorum — cluster service stopping.
00002cc4.00003345::2026/01/15-14:33:00.002 ERR  [RCM] All resources taken offline — no quorum.
```
Look for `quorum loss`, `no quorum`, `lost quorum`, or `cluster service stopping` in any
component.

**Example:**

Problem — 3-node cluster lost 2 nodes simultaneously, quorum lost:
```
14:32:58 ERR  [NODE] NODE2 removed from cluster membership
14:32:59 ERR  [NODE] NODE3 removed from cluster membership
14:33:00 ERR  [NM]   Quorum not achieved. Votes: 1 of 3.
14:33:00 ERR  [RCM]  Cluster service stopping — no quorum.
```

Fix — for a 2-node cluster + witness, restore witness access:
```powershell
# Check witness status:
Get-ClusterQuorum
# If witness disk is offline, bring it back:
Get-ClusterResource "Cluster Disk 1" | Start-ClusterResource
```

**Fix options:**
1. Restore connectivity to the isolated nodes or witness to recover quorum without data loss.
2. If a node is permanently failed and cannot be recovered, use `Start-ClusterNode -FQ` (force quorum) only as a last resort — this overrides quorum validation and can cause split-brain if the other nodes are still alive.
3. Review quorum design: odd-node clusters do not need a witness; even-node clusters require a witness. Use a cloud witness (Azure Blob Storage) for geographically distributed clusters where a disk witness is not practical.

**Related checks:** L7, L18, L21, L22

---

### L7 — Node Eviction

**What it means:**
Node eviction is the cluster's mechanism for removing a node that has lost communication with
the cluster. After sustained heartbeat failures, the surviving nodes vote to evict the
non-responsive node — formally removing it from the cluster membership and releasing its votes.
All resources that were primary on the evicted node immediately fail over (or become
unavailable if no suitable target exists).

**How to spot it:**
```
00002cc4.00001266::2026/01/15-14:33:15.001 WARN [NODE] NODE2 is being evicted from cluster membership.
00002cc4.00001267::2026/01/15-14:33:15.500 ERR  [NM]   Node NODE2 removed. Current membership: {NODE1, NODE3}.
```
Look for `evicted`, `removed from membership`, or `NodeMembership` showing a node departure.

**Example:**

Problem — NODE2 evicted after 3 missed heartbeats:
```
14:32:55 WARN [NODE] Missed heartbeat #1 from NODE2
14:32:57 WARN [NODE] Missed heartbeat #2 from NODE2
14:32:59 WARN [NODE] Missed heartbeat #3 from NODE2
14:33:00 ERR  [NODE] NODE2 declared dead — initiating eviction
14:33:15 WARN [NODE] NODE2 evicted from cluster membership
```

**Fix options:**
1. Investigate heartbeat failures (L20) to understand why NODE2 stopped responding — network failure, CPU starvation, or kernel-mode hang.
2. After restoring connectivity on the evicted node, re-add it to the cluster and verify cluster network health before allowing it to host AG primaries.
3. Check `CrossSubnetThreshold` and `CrossSubnetDelay` settings — overly aggressive settings evict nodes during brief network blips in high-latency WAN environments.

**Related checks:** L20, L18, L6

---

### L8 — Log Time Gap

**What it means:**
The WSFC cluster log records events continuously when the cluster service is running and
VerboseLogging is enabled. A gap in timestamps — especially one coinciding with the incident
window — means the cluster service was stopped, the node was offline, or VerboseLogging was
disabled. Gaps can conceal the root cause of the incident entirely.

**How to spot it:**
Compare consecutive timestamp differences across log entries. A gap longer than 5 minutes
where no entries appear from any component is significant.
```
14:25:00.100 INFO [RCM]  AG1 health check OK
                          [--- 18-minute gap --- ]
14:43:15.200 ERR  [RCM]  AG1 transitioning: Online-->Offline
```

**Example:**

Problem — 18-minute gap exactly covering the incident window:
```
14:25:00 INFO [RCM] AG1 health check OK
              [no entries]
14:43:15 ERR  [RCM] AG1 Online-->Offline
```
The root cause occurred in the 14:25–14:43 window, but no log evidence remains.

**Fix options:**
1. Check CLUSTER.LOG files from all other nodes — a gap on one node's log may be covered by entries on another node's log.
2. Enable VerboseLogging to prevent future gaps from masked low-frequency events (see L23).
3. Correlate the gap timestamp with the Windows System event log and SQL ERRORLOG to reconstruct what happened during the silent period.

**Related checks:** L23, L25

---

## AG Resource Checks (L9–L17)

### L9 — AG Offline Transition

**What it means:**
This check captures the exact moment WSFC declared the AG resource offline in the cluster log.
The transition direction (Online→Offline vs. OnlinePending→Offline) reveals whether the AG was
previously running successfully or failed during startup. This is typically the downstream effect
of L1, L2, or L3 — but can also be caused by an administrator manually taking the resource
offline.

**How to spot it:**
```
00002cc4.00001268::2026/01/15-14:32:01.600 ERR  [RCM] Resource 'SQL Server Availability Group (AG1)':
TransitionToState(Online-->Offline) OfflineCallIssued.
```
Look for `TransitionToState`, `OfflineCallIssued`, or `resource going offline` in `[RCM]`
entries. Note the source state: Online (unexpected failure) vs. OnlinePending (failed to start).

**Example:**

Problem — unexpected offline from Online state:
```
14:32:01 ERR  [RCM] Resource AG1: TransitionToState(Online-->Offline) OfflineCallIssued.
14:32:01 INFO [hadrag] Offline call issued. Reason: lease timeout.
```

Fix — correlate with the preceding `[hadrag]` entries for the reason:
```
Search CLUSTER.LOG backward from the transition timestamp for [hadrag] ERR entries —
they contain the SQL Server-reported reason for the offline call.
```

**Fix options:**
1. Identify the reason in the preceding `[hadrag]` entries — it will be one of: lease expiry (L1), IsAlive failure (L2), SQL connectivity loss (L10), or hadrres.dll error (L13).
2. If the transition was from OnlinePending, focus on L12 (long pending state) and L10 (SQL connectivity) — the AG resource started but SQL Server was not ready.
3. If the transition was administrator-initiated (no preceding `[hadrag]` error), treat as planned maintenance.

**Related checks:** L1, L2, L12, L16

---

### L10 — SQL Connectivity Loss

**What it means:**
hadrres.dll connects to the local SQL Server instance via ODBC to run health checks and
issue AG commands. If this connection fails — because SQL Server is stopped, starting, or
overloaded — the DLL cannot run health checks and will eventually declare the resource failed.
This is distinct from replica-to-replica AG connectivity (L17), which is the HADR endpoint.

**How to spot it:**
```
00002cc4.00001269::2026/01/15-14:31:50.001 ERR  [hadrag] Disconnect from SQL Server.
SQL Server connection failed with error: Login timeout expired.
```
Look for `Disconnect from SQL Server`, `ODBC error`, `SqlConnect failed`, or `connection failed`
in `[hadrag]` or `[RES]` messages. Note: this is a local connection (127.0.0.1), not remote.

**Example:**

Problem — SQL Server was slow to accept connections during startup:
```
14:31:50 ERR  [hadrag] SqlConnect failed. Login timeout expired. (10 seconds)
14:31:50 ERR  [hadrag] Unable to connect to SQL Server — health check unavailable.
14:31:58 ERR  [hadrag] IsAlive check failed.
```

**Fix options:**
1. Check whether SQL Server was starting or restarting at the same time — the AG resource may have come online before SQL Server was ready to accept connections.
2. Verify that SQL Server's maximum connections setting (`sys.configurations` where `name = 'max connections'`) was not exhausted during the incident.
3. Check SQL Server ERRORLOG for login failure messages or connection refusals at the incident timestamp.
4. Ensure the cluster service account has `sysadmin` rights on the SQL Server instance for hadrres.dll health check connections.

**Related checks:** L1, L2, L9

---

### L11 — Forced Failover

**What it means:**
A forced failover promotes a secondary replica to primary without verifying that it has
received all committed transactions from the old primary. This risks data loss — transactions
committed on the old primary after the last synchronization point may not be present on the
new primary. Forced failovers appear in the cluster log when the primary AG resource fails
and WSFC promotes a secondary that was in Asynchronous Commit mode, or when an administrator
issues a forced failover command.

**How to spot it:**
```
00002cc4.00001270::2026/01/15-14:35:00.001 WARN [hadrag] Forced failover of AG1.
New primary: NODE2. Data loss possible — replica was not synchronized.
```
Look for `forced failover` in `[hadrag]` or `[RCM]` entries, or a secondary transitioning to
primary without a matching planned failover sequence.

**Example:**

Problem — forced failover due to primary unavailability with async replica:
```
14:35:00 WARN [hadrag] Forced failover. Previous primary NODE1 unavailable.
14:35:00 INFO [RCM]   AG1 online on NODE2 (SECONDARY_ROLE -- > PRIMARY_ROLE)
14:35:01 WARN [hadrag] Data loss may have occurred — check last_commit_lsn.
```

Fix — verify data loss extent:
```sql
-- On the new primary (NODE2), check if any transactions are missing:
SELECT replica_id, last_commit_lsn, last_commit_time
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1;
-- Compare with backup of old primary if available.
```

**Fix options:**
1. Compare `last_commit_lsn` on the new primary with the backup of the old primary to quantify data loss.
2. If data loss is unacceptable, configure the AG with Synchronous Commit mode for the replicas eligible for automatic failover.
3. Review `AVAILABILITY_MODE` on each replica — asynchronous replicas should not be failover targets unless data loss is explicitly acceptable.

**Related checks:** L9, L16

---

### L12 — Long Pending State

**What it means:**
When WSFC transitions an AG resource to Online or Offline, it first enters OnlinePending or
OfflinePending. The resource DLL has a fixed window to complete the transition. If it exceeds
the pending duration threshold (see Thresholds Reference), WSFC issues a forceful state change —
either marking the resource failed (OnlinePending timeout) or forcing a dirty offline
(OfflinePending timeout). Long pending states indicate SQL Server is not completing AG
initialization or shutdown within the expected window.

**How to spot it:**
Calculate the elapsed time between the Pending entry and the next state change:
```
14:32:10.000 INFO [RCM] AG1 entering OnlinePending state.
14:35:10.000 ERR  [RCM] AG1 OnlinePending timeout exceeded (180 sec). Marking failed.
```

**Example:**

Problem — slow database recovery during failover caused OnlinePending timeout:
```
14:32:10 INFO [RCM]   AG1 entering OnlinePending
14:32:10 INFO [hadrag] Waiting for database recovery to complete on DB1, DB2, DB3
14:34:50 ERR  [RCM]   AG1 OnlinePending timeout (160 sec) — resource failed
```

Fix — identify which database was slow to recover:
```sql
-- Check recovery state of databases in the AG:
SELECT d.name, d.state_desc, d.log_reuse_wait_desc
FROM sys.databases d
JOIN sys.availability_databases_cluster adc ON d.name = adc.database_name
WHERE adc.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = 'AG1');
```

**Fix options:**
1. Identify which database is slow to recover: check SQL ERRORLOG for `Recovery of database ... is X% complete` messages.
2. Raise the `PendingTimeout` cluster resource parameter if database recovery is legitimately slow due to a large undo log.
3. Consider enabling Accelerated Database Recovery (ADR) to reduce database recovery time after failover.

**Related checks:** L9, L10, L2

---

### L13 — hadrres.dll Init Failure

**What it means:**
hadrres.dll is the resource DLL that WSFC loads to manage the AG resource. If this DLL
cannot be loaded or initialized — due to a missing dependency, corrupted binary, or wrong
version — the AG resource cannot come online on that node. This is typically seen after
SQL Server patches, upgrades, or failed installations where the DLL path in the cluster
resource properties is incorrect.

**How to spot it:**
```
00002cc4.00001271::2026/01/15-09:00:00.001 ERR  [RES] Failed to load resource DLL hadrres.dll.
Error: 0x7E (The specified module could not be found.)
```
Look for DLL load failure, `failed to initialize`, or `module not found` in `[RES]` or `[RHS]`
context.

**Example:**

Problem — DLL path not updated after SQL Server patch:
```
09:00:00 ERR  [RES] Cannot load hadrres.dll from C:\Program Files\Microsoft SQL Server\
              MSSQL15.MSSQLSERVER\MSSQL\Binn\hadrres.dll: module not found (0x7E)
```

Fix — update the resource DLL path in Cluster resource properties:
```powershell
# Verify the correct path for the installed SQL Server version:
Get-Item "C:\Program Files\Microsoft SQL Server\MSSQL*\MSSQL\Binn\hadrres.dll"
# Update the cluster resource property:
(Get-ClusterResource "SQL Server Availability Group (AG1)") |
    Set-ClusterParameter -Name "DllName" -Value "C:\correct\path\hadrres.dll"
```

**Fix options:**
1. Verify the correct hadrres.dll path for the installed SQL Server version and update the resource property.
2. Check Windows Application event log for Event ID 1069 (Resource DLL failure) with the Windows error code.
3. Run `sfc /scannow` to repair corrupted system files if the error indicates binary corruption.
4. If after a SQL Server patch, check the patch log for any DLL registration failures.

**Related checks:** L3, L9

---

### L14 — Resource DLL API Timeout

**What it means:**
WSFC calls resource DLL API functions (Online, Offline, LooksAlive, IsAlive) and expects
a response within `DllWatchdogTimeout` milliseconds (default: 60,000 ms = 60 seconds).
If hadrres.dll does not respond in time, WSFC logs an API timeout warning. Repeated timeouts
cause WSFC to declare the DLL hung and terminate the resource — similar effect to L2 but
at a lower level.

**How to spot it:**
```
00002cc4.00001272::2026/01/15-14:31:45.001 WARN [RCM] Resource AG1: DLL API call (IsAlive)
returned after 62000 ms. DllWatchdogTimeout = 60000 ms.
```
Look for `DLL API call` timeout, `API call timed out`, or `DllWatchdogTimeout` in `[RCM]`
or `[RHS]` entries.

**Example:**

Problem — IsAlive taking > 60 sec due to sp_server_diagnostics wait:
```
14:31:45 WARN [RCM] AG1: DLL API IsAlive timed out after 62000 ms
14:31:45 ERR  [RHS] Terminating resource DLL thread — DllWatchdogTimeout exceeded
```

**Fix options:**
1. Same root cause investigation as L1 and L2 — DLL API timeouts indicate SQL Server is not responding promptly.
2. Raise `DllWatchdogTimeout` on the AG resource if the SQL Server health check query is legitimately slow: `Set-ClusterParameter -Name DllWatchdogTimeout -Value 90000`.
3. Fix the underlying SQL Server issue (scheduler starvation, I/O hang) rather than relying on higher timeout values.

**Related checks:** L1, L2, L12

---

### L15 — Cascade Across AGs

**What it means:**
If two or more AG resources show ERR entries within the same short window, the most likely
explanation is a shared infrastructure failure — not individual AG problems. Seeing multiple
AGs fail at nearly the same time should redirect the investigation from AG tuning to network
partitions, node failures, or RHS crashes that affect all resources on the node simultaneously.

**How to spot it:**
Collect distinct AG resource names from all ERR lines and group them by 5-minute windows:
```
14:32:01 ERR  [hadrag] AG1 offline
14:32:02 ERR  [hadrag] AG2 offline
14:32:03 ERR  [RCM]   AG1 failed
14:32:04 ERR  [RCM]   AG2 failed
```
If two or more distinct AG names appear in ERR lines within 5 minutes, this check fires.

**Example:**

Problem — network partition took both AG1 and AG2 offline simultaneously:
```
14:32:00 ERR  [NM]    Network partition detected
14:32:01 ERR  [hadrag] AG1: lease timeout
14:32:01 ERR  [hadrag] AG2: lease timeout
14:32:02 ERR  [RCM]   AG1 transitioning: Online-->Offline
14:32:02 ERR  [RCM]   AG2 transitioning: Online-->Offline
```

**Fix options:**
1. Identify the first log entry before any AG-specific ERR — that entry in `[NM]`, `[NODE]`, or `[RHS]` is the shared root cause.
2. Treat the second (and subsequent) AG failures as cascades — do not separately investigate them until the root cause is resolved.

**Related checks:** L18, L3, L4

---

### L16 — Primary Role Loss

**What it means:**
The primary replica transitions to Resolving or Secondary role without a corresponding
planned failover sequence in the log. This means the AG's primary is gone — write workloads
fail with errors until a new primary is established. Unlike L9 (resource offline), L16 fires
on the AG role transition itself (SQL Server's internal state), which may occur slightly before
or after the WSFC resource state change.

**How to spot it:**
```
00002cc4.00001273::2026/01/15-14:32:02.001 INFO [hadrag] AG1 PRIMARY_ROLE transitioning to RESOLVING_NORMAL.
Role change: PRIMARY --> RESOLVING. Reason: [hadrag] lease expiry.
```
Look for `PRIMARY_ROLE transitioning to RESOLVING` or `PRIMARY --> RESOLVING/SECONDARY` in
`[hadrag]` without a preceding `ALTER AVAILABILITY GROUP ... FAILOVER` in the SQL ERRORLOG.

**Example:**

Problem — unexpected primary role loss after lease timeout:
```
14:32:01 ERR  [hadrag] Lease Thread terminated
14:32:02 INFO [hadrag] AG1: PRIMARY_ROLE --> RESOLVING_NORMAL
14:32:05 INFO [hadrag] AG1: RESOLVING_NORMAL --> SECONDARY_ROLE (on NODE2)
```

**Fix options:**
1. Correlate with L1 (lease timeout) or L9 (resource offline) — primary role loss is a downstream effect of one of these.
2. Verify whether a secondary promoted to primary — if so, the failover completed successfully even if the log shows the primary lost its role.
3. If no secondary promoted, the AG is stuck in Resolving state — manually bring a replica online: `ALTER AVAILABILITY GROUP [AG1] FORCE_FAILOVER_ALLOW_DATA_LOSS`.

**Related checks:** L1, L9, L11

---

### L17 — Replica Disconnection

**What it means:**
The AG mirroring endpoints (typically TCP 5022) between replicas have lost connectivity.
When replicas are disconnected, data cannot flow from primary to secondary. The secondary's
redo queue will fall behind. If a failover occurs while a replica is disconnected, that
replica will have a stale database and may not be an eligible failover target.

**How to spot it:**
```
00002cc4.00001274::2026/01/15-14:30:00.001 WARN [hadrag] Replica NODE2 is DISCONNECTED.
Last connection: 2026/01/15-14:29:45.000. Endpoint: tcp://NODE2.domain.com:5022.
```
Look for `DISCONNECTED`, `replica disconnected`, or `endpoint failure` in `[hadrag]` or `[RES]`.

**Example:**

Problem — firewall rule blocked port 5022 after patch Tuesday changes:
```
14:30:00 WARN [hadrag] Replica NODE2 (endpoint tcp://NODE2:5022) DISCONNECTED.
14:30:00 WARN [hadrag] Send queue for NODE2 is backing up: 1,200 KB pending.
```

Fix — verify endpoint accessibility:
```sql
-- On primary, check endpoint state:
SELECT name, state_desc, role_desc FROM sys.database_mirroring_endpoints;
-- Test connectivity from primary to secondary:
-- (run from cmd on primary) telnet NODE2 5022
```

**Fix options:**
1. Test TCP 5022 connectivity from each node to all other nodes using `Test-NetConnection -Port 5022`.
2. Check Windows Firewall and any perimeter firewalls for rules blocking inbound/outbound TCP 5022.
3. Verify the Database Mirroring Endpoint is in STARTED state: `SELECT state_desc FROM sys.endpoints WHERE type_desc = 'DATABASE_MIRRORING'`.
4. Check DNS resolution for the endpoint hostnames — a stale DNS entry pointing to a decommissioned IP will cause connection failures.

**Related checks:** L18, L19, L20

---

## Network and Node Checks (L18–L22)

### L18 — Network Partition / Split-Brain

**What it means:**
A network partition occurs when cluster nodes lose the ability to communicate with each other
over the cluster heartbeat network. WSFC uses voting to determine which partition holds quorum.
The minority partition loses all resources and the cluster service stops. Split-brain (both
partitions believe they hold quorum) can occur in misconfigured even-node clusters without a
witness — this is a data integrity risk.

**How to spot it:**
```
00002cc4.00001275::2026/01/15-14:32:00.001 ERR  [NM] Network partition detected.
NODE1 can no longer communicate with: NODE2, NODE3.
Quorum status: 1 vote of 3 — cluster will stop.
```
Look for `network partition`, `split brain`, `unable to communicate with`, or quorum votes
dropping below majority in `[NM]` or `[NODE]` entries.

**Example:**

Problem — switch failure isolated NODE1 from NODE2 and NODE3:
```
14:32:00 ERR  [NM]   Network partition. NODE1 isolated. Votes: 1 of 3.
14:32:00 ERR  [NM]   Cluster service stopping on NODE1 — no quorum.
14:32:01 INFO [NM]   NODE2 and NODE3 retain quorum (2 of 3 votes). Continuing.
14:32:02 INFO [RCM]  AG1 failing over to NODE2.
```

**Fix options:**
1. Restore network connectivity to the isolated node.
2. Review NIC teaming/bonding configuration — a single NIC for cluster heartbeats is a single point of failure; use at least two NICs on separate switches.
3. Configure a dedicated cluster heartbeat network separate from the SQL client data network.
4. Implement a cloud witness so that a single network failure cannot cause quorum loss (even-node clusters).

**Related checks:** L6, L19, L20, L22

---

### L19 — Cluster Network Interface Failure

**What it means:**
One of the cluster's registered network interfaces (NICs) has gone offline or failed.
This degrades the cluster's network redundancy. If the cluster has only one network and
that NIC fails, it immediately becomes a network partition (L18). If the cluster has multiple
networks, the failure is a Warning but requires prompt remediation to restore redundancy.

**How to spot it:**
```
00002cc4.00001276::2026/01/15-14:31:00.001 WARN [NM] Cluster network interface 'Cluster Network 1'
on NODE1 has failed. Network state: Failed.
```
Look for `network interface` failed, `adapter` offline, or `NetworkInterface` state change to
Failed in `[NM]` entries.

**Example:**

Problem — NIC driver crash on NODE1 caused the cluster heartbeat network to fail:
```
14:31:00 WARN [NM]   NIC 'Cluster Network 1' on NODE1 failed. (Driver: vmxnet3)
14:31:00 INFO [NM]   Cluster network 'Cluster Network 2' on NODE1 still active.
14:31:00 WARN [NM]   NODE1 now has 1 cluster network instead of 2 — redundancy lost.
```

**Fix options:**
1. Check Windows Device Manager and System event log for NIC driver errors (Event ID 27, 32) on the affected node.
2. Update the NIC driver if a known crash bug exists for the current version.
3. For VMs: check the hypervisor's virtual switch health and vNIC binding.
4. For physical hosts: inspect the physical cable and switch port; test with `Test-NetConnection`.

**Related checks:** L18, L20

---

### L20 — Heartbeat Timeout

**What it means:**
Cluster nodes send periodic heartbeats to each other to prove they are alive. If a node
misses more heartbeats than the configured threshold, the surviving nodes begin the eviction
process. Heartbeat timeouts are the early warning sign before node eviction (L7) and are
caused by network latency, CPU starvation on the heartbeat-sending node, or full network
failure. The `CrossSubnetThreshold` and `SameSubnetThreshold` control how many missed heartbeats
before eviction begins.

**How to spot it:**
```
00002cc4.00001277::2026/01/15-14:32:55.001 WARN [NODE] Missed heartbeat #1 from NODE2
00002cc4.00001278::2026/01/15-14:32:57.100 WARN [NODE] Missed heartbeat #2 from NODE2
00002cc4.00001279::2026/01/15-14:32:59.200 WARN [NODE] Missed heartbeat #3 from NODE2
```
Count consecutive missed heartbeat warnings from the same node — reaching the configured
threshold triggers eviction.

**Example:**

Problem — 3 missed heartbeats from NODE2 leading to eviction:
```
14:32:55 WARN [NODE] Missed heartbeat #1 from NODE2 (CrossSubnetThreshold = 3)
14:32:57 WARN [NODE] Missed heartbeat #2 from NODE2
14:32:59 WARN [NODE] Missed heartbeat #3 from NODE2 — threshold reached
14:33:00 ERR  [NODE] NODE2 declared dead. Initiating eviction.
```

**Fix options:**
1. Measure round-trip latency between cluster nodes on the heartbeat network — for WAN/cross-subnet clusters, increase `CrossSubnetThreshold` and `CrossSubnetDelay` if latency spikes cause false evictions.
2. Check CPU utilization on the node that stopped responding — a 100% CPU condition prevents the heartbeat thread from running, causing false heartbeat failures.
3. Avoid placing the cluster heartbeat network on the same NIC as high-bandwidth SQL client traffic — bandwidth saturation can delay heartbeat packets.

**Related checks:** L7, L18, L19

---

### L21 — Witness Access Failure

**What it means:**
The cluster witness (disk witness, file share witness, or cloud witness) provides the
tie-breaking vote that allows an even-node cluster to maintain quorum when one node fails.
If the witness becomes unavailable at the same time a node fails, the remaining node cannot
achieve quorum and the cluster stops. Witness failure is often overlooked until it matters.

**How to spot it:**
```
00002cc4.00001280::2026/01/15-14:31:00.001 ERR  [RES] Disk Witness resource failed.
Cluster disk not accessible from NODE1. Witness vote: unavailable.
```
Look for `witness resource failed`, `disk witness offline`, `file share witness` errors,
or `cloud witness` access failures in `[RES]` or `[RCM]` entries.

**Example:**

Problem — file share witness UNC path inaccessible after file server maintenance:
```
14:31:00 ERR  [RES] File Share Witness \\fileserver\witness: access denied (0x5)
14:31:00 WARN [NM]  Witness vote unavailable. Cluster voting: 2 nodes only.
14:31:01 INFO [NM]  Quorum can still be achieved with 2 of 2 node votes — proceeding.
```

**Fix options:**
1. For disk witness: verify the witness disk's cluster resource is Online in Failover Cluster Manager.
2. For file share witness: verify the UNC path is accessible (`Test-Path \\server\share`) and the cluster service account has `Full Control` on the share.
3. For cloud witness: verify Azure Blob Storage connectivity (`Test-NetConnection -ComputerName *.blob.core.windows.net -Port 443`) and that the storage account key is current.
4. Monitor witness health proactively — configure an alert on the witness resource state to detect failures before they matter.

**Related checks:** L6, L18

---

### L22 — Node Isolation

**What it means:**
Node isolation is the extreme case of L20 — the node has lost communication with all other
cluster nodes simultaneously. This can happen due to total NIC failure, a switch failure
affecting all cluster networks, or a host-level failure (BSOD, power loss) that takes the
node offline entirely. An isolated node loses quorum and all its resources fail over (or fail
entirely if no failover target is available).

**How to spot it:**
```
00002cc4.00001281::2026/01/15-14:33:00.001 ERR  [NODE] NODE1: unable to communicate with
any cluster node. Cluster service stopping. I am isolated.
```
Look for `node isolated`, `unable to communicate with any`, or `I am isolated` in `[NODE]`
or `[NM]` entries.

**Example:**

Problem — hypervisor host went offline taking the guest VM's cluster node with it:
```
14:33:00 ERR  [NODE] NODE1 isolated — communication with NODE2, NODE3 lost simultaneously.
14:33:00 ERR  [NM]   All cluster networks down on NODE1. Cluster service stopping.
14:33:01 INFO [NM]   NODE2 and NODE3 retain quorum (2 of 3). AG1 failing over to NODE2.
```

**Fix options:**
1. Check hypervisor/host health first — node isolation with simultaneous loss of all networks usually indicates a host-level failure rather than a network configuration issue.
2. After restoring the node, verify all cluster networks are healthy before adding the node back to active cluster membership.
3. For VMs: implement VM-level HA at the hypervisor layer (e.g., VMware HA, Hyper-V Live Migration) to reduce the probability of host-level isolation events.

**Related checks:** L18, L20, L7

---

## Configuration Signal Checks (L23–L25)

### L23 — VerboseLogging = 0 (Sparse Events)

**What it means:**
WSFC cluster logging has two verbosity levels: standard (default) and verbose. At standard
logging, many intermediate state transitions, API call durations, and health check results
are not recorded. This means that in a post-incident analysis, the log may not contain the
evidence needed to diagnose the root cause. VerboseLogging=1 adds significantly more detail
to the cluster log, including timing information for every health check call.

**How to spot it:**
If the log contains fewer than 20 entries per minute in the period before the incident
(excluding the burst during the failure itself), or if API call durations and state
transition reasons are absent, VerboseLogging is likely at 0.
```
14:25:00 INFO [RCM] AG1 health check OK
14:30:00 INFO [RCM] AG1 health check OK
[5-minute gap with no intermediate entries]
```

**Example:**

Problem — only one entry per 5 minutes in the pre-incident window:
```
14:25:00 INFO [RCM] AG1 health check OK
14:30:00 INFO [RCM] AG1 health check OK
14:35:00 ERR  [RCM] AG1 transitioning: Online-->Offline  ← no warning, no context
```
With VerboseLogging=1, entries between 14:25 and 14:35 would show health check durations
and any transient issues that preceded the failure.

Fix — enable verbose logging on all cluster nodes:
```powershell
# Enable VerboseLogging on the AG resource on all nodes:
Get-ClusterResource | Where-Object {$_.ResourceType -eq 'SQL Server Availability Group'} |
    ForEach-Object { $_ | Set-ClusterParameter VerboseLogging 1 }
```

**Fix options:**
1. Enable VerboseLogging=1 on all AG resources before the next maintenance window.
2. Review cluster disk I/O impact — verbose logging writes more to the cluster log file. Monitor disk write latency for `C:\Windows\Cluster\cluster.log`.
3. Note that verbose logging is reset to 0 when the cluster service restarts on some Windows versions — automate re-enabling it via a startup script or Group Policy.

**Related checks:** L8, L25

---

### L24 — SeparateMonitor Not Set

**What it means:**
By default, hadrres.dll shares rhs.exe with other cluster resource DLLs on the same node.
If any other DLL in that shared rhs.exe throws an unhandled exception, the entire rhs.exe
process terminates — taking the AG resource offline (L3). `SeparateMonitor=1` on the AG
resource tells WSFC to host hadrres.dll in its own dedicated rhs.exe process, isolating it
from faults in other resource DLLs.

**How to spot it:**
If multiple distinct resource DLL log entries appear with the same thread ID prefix (indicating
the same rhs.exe process), and no `SeparateMonitor` configuration entry exists, this check fires.
In practice, the absence of per-resource rhs.exe PID entries is the signal.

**Example:**

Problem — shared rhs.exe hosts AG1, AG2, and IP Address resources:
```
[same thread prefix] [RES] AG1: IsAlive check starting
[same thread prefix] [RES] IP Address: online check
[same thread prefix] [RES] AG2: LooksAlive check
```

Fix — isolate the AG resource in its own rhs.exe:
```powershell
$agRes = Get-ClusterResource "SQL Server Availability Group (AG1)"
$agRes | Set-ClusterParameter SeparateMonitor 1
# Restart resource to apply the change:
Stop-ClusterResource $agRes; Start-ClusterResource $agRes
```

**Fix options:**
1. Enable `SeparateMonitor=1` on each AG resource as a proactive measure.
2. Identify all non-AG resource DLLs sharing rhs.exe — any of these could cause L3.
3. This setting is a Microsoft recommendation for all SQL Server AG resources on Windows Server 2012 R2 and later.

**Related checks:** L3

---

### L25 — Missing Node Coverage

**What it means:**
CLUSTER.LOG is written independently by each cluster node. The log collected from a single
node contains only events observed by that node — events on a silently-failed or isolated
node will not appear. If the analysis is performed on a log from only one node, it may
miss the root cause entirely (particularly for L18, L7, and L22, where the failure
perspective from the failing node is most diagnostic).

**How to spot it:**
Count the distinct node identifiers appearing as log entry sources. If this count is less
than the expected cluster node count (visible in `[NODE]` membership entries), the log
coverage is incomplete.
```
[NODE1 entries throughout]
[NODE2 entries throughout]
[No entries from NODE3 — expected 3-node cluster]
```

**Example:**

Problem — log collected from NODE1 only; NODE3's isolation event not visible:
```
14:32:00 INFO [NM] NODE3 was evicted from cluster membership (seen from NODE1)
[No NODE3 log available to see what NODE3 observed — was it a network failure or a crash?]
```

Fix — collect logs from all nodes at once:
```powershell
# Collect the last 60 minutes of cluster logs from all nodes:
Get-ClusterLog -Node * -Destination C:\ClusterLogs -TimeSpan 60
# Merge and sort by timestamp for a unified view.
```

**Fix options:**
1. Collect CLUSTER.LOG from all nodes for the same time window using `Get-ClusterLog -Node *`.
2. Sort merged logs by timestamp to reconstruct the timeline from all perspectives.
3. Note in the analysis summary which nodes are represented and which are missing.

**Related checks:** L8, L23

---

## Modern Cluster Feature Checks (L26–L30)

### L26 — Cloud Witness Repeated Timeout (Windows Server 2016+)

**What it means:**
Cloud Witness uses Azure Blob Storage as the quorum witness for WSFC clusters. It is the
recommended witness type for clusters that span availability zones or Azure regions, replacing
the traditional disk or file share witness. When CLUSTER.LOG shows repeated CloudWitness
timeout or connectivity failure entries — three or more within a 10-minute window — the
cluster is running without a functional quorum witness. In an even-node cluster, losing the
witness means a single node failure can cause quorum loss and a complete cluster outage.

**How to spot it:**
```
00002cc4.00001282::2026/03/10-09:12:01.001 ERR  [CloudWitness] Unable to reach Azure Blob Storage.
Timeout after 30000 ms. Account: myclusterwitness.blob.core.windows.net
00002cc4.00001283::2026/03/10-09:14:30.001 ERR  [CloudWitness] Timeout — CloudWitness vote unavailable.
00002cc4.00001284::2026/03/10-09:16:45.001 ERR  [CloudWitness] Timeout — CloudWitness vote unavailable.
```
Search for `CloudWitness` combined with `Timeout`, `Unable to reach`, or `vote unavailable`.
Three or more occurrences in 10 minutes trigger this check.

**Example:**

Problem — outbound HTTPS blocked after firewall policy change:
```
09:12:01 ERR  [CloudWitness] Unable to reach myclusterwitness.blob.core.windows.net:443.
              Timeout after 30000 ms. Error: WINHTTP_ERROR_TIMEOUT
09:14:30 ERR  [CloudWitness] CloudWitness vote unavailable (attempt 2 of 3 in last 10 min)
09:16:45 ERR  [CloudWitness] CloudWitness vote unavailable (attempt 3 of 3) — check network
```

Fix — test outbound HTTPS connectivity to the storage endpoint:
```powershell
# Test connectivity from each cluster node:
Test-NetConnection -ComputerName myclusterwitness.blob.core.windows.net -Port 443
# If connectivity passes but auth fails, regenerate the storage account access key in
# Failover Cluster Manager: Cluster Core Resources > Cloud Witness > Properties
```

**Fix options:**
1. Test outbound TCP 443 from each cluster node to `<storageaccount>.blob.core.windows.net` — firewall rules often block this after patch-Tuesday policy pushes.
2. Verify the storage account access key in Failover Cluster Manager (Cloud Witness properties) — keys may have been rotated without updating the cluster configuration.
3. Check whether the Azure Storage account has a firewall or virtual network rule that excludes the cluster nodes' public IP addresses.
4. If the Cloud Witness storage account is permanently unavailable, configure an alternative witness: `Set-ClusterQuorum -FileShareWitness \\server\share` or a replacement Azure storage account.

**Related checks:** L4 (quorum loss), L22 (witness failure)

---

### L27 — Azure Arc-Managed Cluster Agent Disconnect (Any version with Arc)

**What it means:**
Azure Arc extends Azure management capabilities (Defender for SQL, automated backups, Azure
Policy, monitoring) to SQL Server instances running outside of Azure. The Arc agent (himds)
and its extensions (ArcSqlInstanceExtension, HybridConnectivity) run as Windows services on
each cluster node. When CLUSTER.LOG records Arc agent disconnection or heartbeat failure
events, the node has lost contact with the Azure control plane. While Arc disconnect does not
directly cause SQL Server or AG outages, it means Defender for SQL threat detection, automated
backup policies, and compliance enforcement are silently not functioning.

**How to spot it:**
```
00002cc4.00001285::2026/03/10-10:05:00.001 WARN [ArcSqlExtension] Heartbeat failure.
Agent has not reached Azure control plane in 15 minutes.
00002cc4.00001286::2026/03/10-10:07:30.001 ERR  [HybridConnectivity] Agent disconnected.
Last successful contact: 2026/03/10-09:50:00.
```
Search for `ArcSqlExtension`, `HybridConnectivity`, or `himds` combined with `disconnected`,
`heartbeat failure`, or `unable to reach`.

**Example:**

Problem — Arc agent services stopped after Windows update reboot:
```
10:05:00 WARN [ArcSqlExtension] Heartbeat failure — Azure control plane unreachable.
10:05:00 WARN [HybridConnectivity] Agent disconnected. Last seen: 09:50:00.
10:07:30 ERR  [ArcSqlExtension] Agent offline. Defender for SQL telemetry paused.
```

Fix — check Arc service status and outbound connectivity:
```powershell
# Check service health on each node:
Get-Service -Name 'himds','ArcSqlInstanceExtension' | Select Name, Status, StartType
# Restart if stopped:
Start-Service himds; Start-Service ArcSqlInstanceExtension
# Verify outbound HTTPS to Arc endpoints:
Test-NetConnection -ComputerName management.azure.com -Port 443
Test-NetConnection -ComputerName eas.his.arc.azure.com -Port 443
```

**Fix options:**
1. Check service status for `himds` and `ArcSqlInstanceExtension` on each node — services may have failed to restart after a Windows update reboot.
2. Review Windows Event Log (Application) for Arc extension crash events or installation errors.
3. Verify outbound connectivity to `*.arc.azure.com:443` and `*.his.arc.azure.com:443` — proxy settings or firewall rules may block Arc endpoints.
4. If the agent is repeatedly disconnecting, review the Arc extension version and apply available updates via Azure Portal > Arc-enabled SQL Server > Extensions.

**Related checks:** L1 (error burst), L8 (log time gap)

---

### L28 — Contained AG: Contained System Database Offline (SQL 2022+)

**What it means:**
Contained Availability Groups (introduced in SQL Server 2022) maintain a contained version
of the system databases — including a contained `master` and `msdb` — within the AG itself.
These contained system databases carry AG-scoped logins, SQL Agent jobs, linked server
definitions, and maintenance plans, making them portable across replicas without manual
synchronization. When the cluster log shows a contained system database resource (named
`<ag_name>_master` or similar) in FAILED or OFFLINE state, those AG-scoped objects become
unavailable on the current primary — SQL Agent jobs stop running, linked server queries fail,
and logins defined in the contained master cannot authenticate.

**How to spot it:**
```
00002cc4.00001287::2026/03/10-11:30:00.001 ERR  [RCM] Resource 'ContainedAG1_master':
TransitionToState(Online-->Offline) OfflineCallIssued. Reason: resource failure.
00002cc4.00001288::2026/03/10-11:30:00.100 ERR  [RES] ContainedAG1_master: database offline.
```
Search for the contained system database resource name (`<ag_name>_master`, `<ag_name>_msdb`)
in OFFLINE or FAILED transition entries in `[RCM]` or `[RES]`.

**Example:**

Problem — contained master database went offline due to I/O error on primary:
```
11:30:00 ERR  [RCM] Resource 'ContainedAG1_master' transitioning: Online-->Offline
11:30:00 ERR  [RES] ContainedAG1_master: database unavailable. Check SQL ERRORLOG.
11:30:01 WARN [hadrag] AG ContainedAG1: contained system database failure — some features
              unavailable (SQL Agent, linked servers, contained logins).
```

Fix — attempt to bring the contained system database resource online:
```powershell
# Attempt to bring the resource online:
Start-ClusterResource -Name 'ContainedAG1_master'
# Check for errors:
Get-ClusterResourceState -Name 'ContainedAG1_master'
```

**Fix options:**
1. Attempt `Start-ClusterResource -Name '<ag_name>_master'` — if it fails immediately, the SQL ERRORLOG on the primary will contain the database-level error (corruption, I/O failure).
2. Correlate with `/hadr-health-review` H23 (contained system database check) and `/errorlog-review` E15–E19 (I/O error checks) for the underlying cause.
3. If the contained system database is corrupt, restore it from the most recent AG-consistent backup. For contained AGs, back up the contained system databases as part of the regular backup schedule.
4. Review the data volume's I/O health — contained system database failures are often caused by the same I/O issues that affect user databases (L1 root cause chain).

**Related checks:** L9 (AG offline transition), L10 (SQL connectivity loss)

---

### L29 — Cross-Subnet Probe Failure (All versions)

**What it means:**
In multi-site or multi-subnet WSFC configurations, nodes in different subnets communicate
via cross-subnet heartbeat probes (UDP port 3343). These probes are separate from the
intra-subnet heartbeat and use different threshold settings (`CrossSubnetThreshold`,
`CrossSubnetDelay`). When CLUSTER.LOG records repeated cross-subnet probe failures — showing
`FAILED` or `No response` for a remote subnet node — the cluster has lost its inter-site
heartbeat path. This is a direct precursor to node isolation and quorum loss for any node
that cannot reach a majority across subnets, and is often caused by inter-site routing
changes, firewall rule drift, or WAN link degradation.

**How to spot it:**
```
00002cc4.00001289::2026/03/10-12:00:01.001 WARN [NODE] CrossSubnet probe to NODE3 (10.2.0.5): FAILED.
00002cc4.00001290::2026/03/10-12:00:03.001 WARN [NODE] CrossSubnet probe to NODE3 (10.2.0.5): No response.
00002cc4.00001291::2026/03/10-12:00:05.001 ERR  [NODE] CrossSubnet probe to NODE3: threshold reached.
```
Search for `CrossSubnet` combined with `FAILED`, `No response`, or `probe` in `[NODE]` entries.

**Example:**

Problem — new inter-site firewall rule blocking UDP 3343 after network refresh:
```
12:00:01 WARN [NODE] CrossSubnet probe to NODE3 (10.2.0.5) FAILED (attempt 1)
12:00:03 WARN [NODE] CrossSubnet probe to NODE3 (10.2.0.5) FAILED (attempt 2)
12:00:05 WARN [NODE] CrossSubnet probe to NODE3 (10.2.0.5) FAILED (attempt 3)
12:00:05 ERR  [NODE] CrossSubnetThreshold (3) reached — NODE3 declared unreachable.
12:00:06 ERR  [NODE] NODE3 removed from cluster membership.
```

Fix — verify UDP 3343 between subnets and check routing:
```powershell
# Test UDP reachability between subnets (use PortQry or a custom UDP probe):
# PortQry -n 10.2.0.5 -e 3343 -p UDP
# Check current cross-subnet cluster settings:
(Get-Cluster).CrossSubnetThreshold
(Get-Cluster).CrossSubnetDelay
# Temporarily raise threshold to allow time for routing fix:
(Get-Cluster).CrossSubnetThreshold = 10
```

**Fix options:**
1. Verify UDP port 3343 is open bidirectionally between all subnet pairs — this port must be allowed through all firewalls and security groups on the inter-site path.
2. Check routing between sites for recent changes — an asymmetric route or missing route can cause one-way UDP failure that appears as probe failures only in one direction.
3. Review Windows Firewall rules on the nodes in the remote subnet — a GPO-pushed rule may have blocked inbound UDP 3343.
4. Confirm multisite DNS resolution is functioning correctly — cross-subnet probes use node names, not just IPs; a stale DNS entry pointing to a retired IP can cause failures.
5. Increase `CrossSubnetThreshold` temporarily while the network issue is being resolved to prevent spurious node evictions during the fix window.

**Related checks:** L18 (partition/split-brain), L21 (heartbeat timeout)

---

### L30 — sp_server_diagnostics Component Warning (SQL 2012+)

**What it means:**
`sp_server_diagnostics` is the health check stored procedure that SQL Server uses to report
its internal subsystem status to WSFC. It is called by hadrres.dll as part of the IsAlive
check and returns a component state for five subsystems: `system` (scheduler and I/O
non-yielding), `resource` (memory pressure), `query_processing` (blocking, deadlock,
spinlock), `io_subsystem` (I/O errors and latency), and `events` (critical ring buffer
events). When CLUSTER.LOG shows `IsAlive check failed` or `sp_server_diagnostics` returning
WARNING or ERROR for any component, it means SQL Server's own health monitor has detected a
problem severe enough to report to WSFC. Depending on the AG's `FailureConditionLevel`,
WARNING or ERROR states can trigger automatic AG failover. These signals are direct diagnostic
pointers to the SQL Server subsystem that is in distress.

**How to spot it:**
```
00002cc4.00001292::2026/03/10-14:31:58.001 ERR  [hadrag] IsAlive check failed.
sp_server_diagnostics returned state=WARNING for component: query_processing.
Details: 3 sessions with wait > 30 seconds, 1 non-yielding scheduler detected.
```
Search for `IsAlive check failed`, `sp_server_diagnostics`, `state=WARNING`, or
`state=ERROR` in `[hadrag]` or `[RES]` entries. Note the `component` field — it
identifies which SQL Server subsystem is in distress.

**Example:**

Problem — query processing component warning due to non-yielding scheduler:
```
14:31:50 WARN [hadrag] sp_server_diagnostics: component=query_processing state=WARNING
              non_yielding_scheduler_count=1 pending_tasks=847
14:31:55 WARN [hadrag] sp_server_diagnostics: component=query_processing state=ERROR
              non_yielding_scheduler_count=1 (escalated after 2 consecutive warnings)
14:31:58 ERR  [hadrag] IsAlive check failed. HealthCheckTimeout exceeded.
14:32:01 ERR  [RCM]   AG1 transitioning: Online-->Offline
```

Fix — map the component to the appropriate specialist skill:
```sql
-- Run manually to reproduce the health state:
EXEC sp_server_diagnostics 5;
-- Returns one row per component with state (1=clean, 2=warning, 3=error, 4=failure)
-- and component-specific XML details.
```

**Fix options:**
1. `query_processing` WARNING/ERROR → run `/sqlwait-review` on `sys.dm_os_wait_stats` output and `/tsql-review` on blocking queries; check for non-yielding schedulers in ERRORLOG.
2. `io_subsystem` WARNING/ERROR → run `/errorlog-review` checks E15–E19 (I/O slow, stalled scheduler); measure disk latency with `sys.dm_io_virtual_file_stats`.
3. `resource` WARNING/ERROR → run `/errorlog-review` checks E9–E14 (memory pressure); check `sys.dm_os_memory_clerks` for clerks consuming abnormal page counts.
4. `system` WARNING/ERROR → investigate non-yielding schedulers in the SQL ERRORLOG (search for `non-yielding`); may require a SQL Server service restart if a scheduler is permanently stuck.
5. `events` WARNING/ERROR → check SQL ERRORLOG and `sys.dm_os_ring_buffers` for critical events logged in the window before the health check failure.
6. Raise `FailureConditionLevel` from default 3 to 4 or 5 to prevent WARNING-level component states from triggering automatic failover if the underlying condition is known and non-critical.

**Related checks:** L1 (error burst), L2 (health check failure)

---

## Quick Reference Table

| ID | Name | Category | Severity |
|----|------|----------|----------|
| L1 | Lease Timeout | File-wide | Critical |
| L2 | Health Check Failure | File-wide | Critical |
| L3 | RHS Process Crash | File-wide | Critical |
| L4 | Error Burst Density | File-wide | Critical / Warning |
| L5 | Repeated Failover Cycling | File-wide | Critical / Warning |
| L6 | Quorum Loss | File-wide | Critical |
| L7 | Node Eviction | File-wide | Critical |
| L8 | Log Time Gap | File-wide | Critical / Warning |
| L9 | AG Offline Transition | AG Resource | Critical / Warning |
| L10 | SQL Connectivity Loss | AG Resource | Critical |
| L11 | Forced Failover | AG Resource | Warning |
| L12 | Long Pending State | AG Resource | Critical / Warning |
| L13 | hadrres.dll Init Failure | AG Resource | Critical |
| L14 | Resource DLL API Timeout | AG Resource | Warning |
| L15 | Cascade Across AGs | AG Resource | Warning |
| L16 | Primary Role Loss | AG Resource | Warning |
| L17 | Replica Disconnection | AG Resource | Warning |
| L18 | Network Partition / Split-Brain | Network/Node | Critical |
| L19 | Cluster Network Interface Failure | Network/Node | Warning |
| L20 | Heartbeat Timeout | Network/Node | Critical / Warning |
| L21 | Witness Access Failure | Network/Node | Critical |
| L22 | Node Isolation | Network/Node | Critical |
| L23 | VerboseLogging = 0 | Configuration | Info |
| L24 | SeparateMonitor Not Set | Configuration | Info |
| L25 | Missing Node Coverage | Configuration | Info |
| L26 | Cloud Witness Repeated Timeout | Modern | Critical |
| L27 | Azure Arc Agent Disconnect | Modern | Warning |
| L28 | Contained AG System Database Offline | Modern | Critical |
| L29 | Cross-Subnet Probe Failure | Modern | Critical |
| L30 | sp_server_diagnostics Component Warning | Modern | Warning/Critical |
