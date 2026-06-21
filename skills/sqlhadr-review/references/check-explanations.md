# sqlhadr-review — Checks Explained

## Contents

- [Category 1: Replica Connectivity and Role (H1–H6)](#category-1-replica-connectivity-and-role-h1h6)
- [Category 2: Data Loss and Recovery Time (H7–H11)](#category-2-data-loss-and-recovery-time-h7h11)
- [Category 3: Throughput and Performance (H12–H16)](#category-3-throughput-and-performance-h12h16)
- [Category 4: Configuration (H17–H22)](#category-4-configuration-h17h22)
- [Category 5: Modern AG Feature Checks (H23–H27)](#category-5-modern-ag-feature-checks-h23h27)
- [Category 6: Seeding and Initialization Integrity (H28)](#category-6-seeding-and-initialization-integrity-h28)
- [Quick Reference](#quick-reference)

---


Plain-English explanations for all 27 active H-checks (H1–H28; H21 is retired — merged into
`sqlag-review` F15). For check trigger conditions and thresholds, see `SKILL.md`. This file is
for human reference only — it is not loaded by the skill.

---

## Category 1: Replica Connectivity and Role (H1–H6)

### H1 — Replica Disconnected

**What it means**
The primary replica has lost its connection to this secondary. No log is being sent, no
acknowledgements are being received, and automatic failover to this secondary is impossible.
This is the most severe connectivity failure short of a full quorum loss.

**How to spot it**
In the DMV output, look at `connected_state_desc` for each non-primary replica row.

```
replica_server_name   connected_state_desc   last_connect_error_number
NODE2\SQL2019         DISCONNECTED           35206
```

**Example (problem + fix)**
```
-- Problem: H1 fires when connected_state_desc = DISCONNECTED

-- Investigate from the primary:
SELECT replica_server_name,
       connected_state_desc,
       last_connect_error_number,
       last_connect_error_description,
       last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;

-- Fix: Verify service and endpoint on the secondary
-- On NODE2\SQL2019:
SELECT state_desc FROM sys.database_mirroring_endpoints;
-- If STOPPED: ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
```

**Fix options**
1. Check network connectivity: `ping NODE2\SQL2019` and `Test-NetConnection NODE2\SQL2019 -Port 5022`
2. Verify SQL Server service is running on NODE2\SQL2019
3. Review CLUSTER.LOG (`C:\Windows\Cluster\cluster.log`) for node eviction or network faults
4. Verify the HADR endpoint is running (see code block above)
5. Review Windows Event Log on NODE2\SQL2019 for service failures or OS events

**Related checks:** H2, H3, H5

---

### H2 — Replica in Resolving State

**What it means**
The replica's role cannot be determined. RESOLVING means the replica has lost contact with
the Windows Server Failover Cluster and does not know if it should be PRIMARY or SECONDARY.
This occurs during quorum loss, node eviction, or an unplanned failover in progress.

**How to spot it**
```
replica_server_name   role_desc    connected_state_desc
NODE2\SQL2019         RESOLVING    DISCONNECTED
```

**Example (problem + fix)**
```sql
-- Check current quorum status from Windows:
-- (Run in PowerShell on any WSFC node)
-- Get-ClusterQuorum
-- Get-ClusterNode | Select Name, State

-- On SQL Server, monitor role transition:
SELECT name, role_desc, operational_state_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
```

**Fix options**
1. Open Failover Cluster Manager and check node and quorum health
2. Review CLUSTER.LOG for quorum events or node eviction messages
3. If a planned failover is in progress, wait for it to complete (RESOLVING is transient)
4. If quorum was lost: restore quorum votes, bring nodes online, then re-evaluate

**Related checks:** H1, H3

---

### H3 — Synchronization Unhealthy at Replica Level

**What it means**
The replica-level `synchronization_health_desc` reflects the worst health across all
databases on that replica. NOT_HEALTHY means at least one database is not synchronizing
correctly. This rolls up from individual database states and is a signal to drill into H4.

**How to spot it**
```
replica_server_name   synchronization_health_desc
NODE2\SQL2019         NOT_HEALTHY
```

**Example (problem + fix)**
```sql
-- Drill into per-database health on the unhealthy replica:
SELECT drs.database_name,
       drs.synchronization_state_desc,
       drs.synchronization_health_desc,
       drs.redo_queue_size,
       drs.log_send_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE ar.replica_server_name = N'NODE2\SQL2019';
```

**Fix options**
1. Identify the specific unhealthy database using the per-database query above
2. Check ERRORLOG on the secondary for transport or redo errors
3. If `synchronization_state_desc = NOT SYNCHRONIZING`, proceed to H4 fix steps
4. Resume the database if suspended: `ALTER DATABASE [db] SET HADR RESUME`

**Related checks:** H1, H4

---

### H4 — Replica Not Synchronizing (Sync-Commit)

**What it means**
A synchronous-commit secondary is NOT SYNCHRONIZING. This is severe because the primary
waits for every synchronous secondary to harden the log before committing. A stalled
SYNCHRONOUS_COMMIT replica adds unbounded latency to all write transactions on the primary.

**How to spot it**
```
replica_server_name   availability_mode_desc   synchronization_state_desc
NODE2\SQL2019         SYNCHRONOUS_COMMIT       NOT SYNCHRONIZING
```

**Example (problem + fix)**
```sql
-- Check for full transaction log on secondary (a common cause):
-- Run on NODE2\SQL2019:
SELECT name, log_reuse_wait_desc,
       (size * 8.0) / 1024 AS size_mb,
       (FILEPROPERTY(name, 'SpaceUsed') * 8.0) / 1024 AS used_mb
FROM sys.databases
WHERE name IN (SELECT database_name FROM sys.dm_hadr_database_replica_states);

-- Resume synchronization after resolving the root cause:
ALTER DATABASE [SalesDB] SET HADR RESUME;
```

**Fix options**
1. Check for a full transaction log on the secondary blocking redo (see code block)
2. Check ERRORLOG on the secondary for `hadr_work_queue` errors or transport failures
3. Verify disk space on the secondary data volume — redo requires write space
4. After fixing root cause: `ALTER DATABASE [db] SET HADR RESUME`

**Related checks:** H3, H7, H16

---

### H5 — Last Connect Error Present

**What it means**
A non-zero `last_connect_error_number` means the HADR transport recorded a connection
failure at some point. The replica may currently be CONNECTED, but the error record reveals
prior instability — a network blip, certificate expiry, or endpoint restart.

**How to spot it**
```
replica_server_name   connected_state_desc   last_connect_error_number   last_connect_error_description
NODE3\SQL2019         CONNECTED              35201                        A connection with the server failed...
```

**Example (problem + fix)**
```sql
-- Get full error context:
SELECT ar.replica_server_name,
       ars.connected_state_desc,
       ars.last_connect_error_number,
       ars.last_connect_error_description,
       ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
WHERE ars.last_connect_error_number != 0;
```

**Fix options**
1. Review `last_connect_error_description` — common error 35201 = connection timeout; 35206 = endpoint unreachable
2. If the error mentions certificates: check certificate expiry dates on the HADR endpoint
3. Correlate `last_connect_error_timestamp` with network events or maintenance windows
4. Clear the error history by restarting HADR: `ALTER DATABASE [db] SET HADR SUSPEND / RESUME`

**Related checks:** H1

---

### H6 — Manual Failover Mode on Sync-Commit Replica

**What it means**
A synchronous-commit replica configured for MANUAL failover requires a DBA to execute
`ALTER AVAILABILITY GROUP ... FAILOVER` before the secondary can become primary. During
an unplanned primary outage, every second the DBA spends locating the issue and executing
the command adds to downtime.

**How to spot it**
```
replica_server_name   availability_mode_desc   failover_mode_desc
NODE2\SQL2019         SYNCHRONOUS_COMMIT       MANUAL
```

**Example (problem + fix)**
```sql
-- Change to automatic failover (requires WSFC quorum support):
ALTER AVAILABILITY GROUP [SalesAG]
MODIFY REPLICA ON N'NODE2\SQL2019'
WITH (FAILOVER_MODE = AUTOMATIC);

-- Verify the change:
SELECT replica_server_name, failover_mode_desc
FROM sys.availability_replicas
WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = N'SalesAG');
```

**Fix options**
1. Verify WSFC quorum can support automatic failover (requires a majority of nodes online)
2. Confirm the secondary is SYNCHRONIZED (not just SYNCHRONIZING) before enabling AUTO failover
3. Change failover mode using the T-SQL above or via SSMS AG Properties dialog

**Related checks:** H18

---

## Category 2: Data Loss and Recovery Time (H7–H11)

### H7 — Estimated Data Loss

**What it means**
`estimated_data_loss_seconds` tells you how much data you would lose (in seconds of
transactions) if the primary failed right now. For a synchronous-commit replica it should
be 0 — any nonzero value means the secondary is not fully caught up. For an async replica,
some lag is expected, but large values represent real RPO violations.

**How to spot it**
```
database_name   availability_mode_desc     estimated_data_loss_seconds
SalesDB         SYNCHRONOUS_COMMIT         45
SalesDB         ASYNCHRONOUS_COMMIT        120
```

**Example (problem + fix)**
```sql
-- Monitor data loss trend over time:
SELECT drs.database_name,
       ar.replica_server_name,
       ar.availability_mode_desc,
       drs.estimated_data_loss_seconds,
       drs.secondary_lag_seconds,
       drs.log_send_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
ORDER BY drs.estimated_data_loss_seconds DESC;
```

**Fix options**
1. For sync replicas: investigate H4 (NOT SYNCHRONIZING) — sync replicas should have 0 data loss
2. For async replicas: increase network bandwidth or reduce log generation rate
3. Consider converting a high-data-loss async replica to synchronous-commit if RPO requires it
4. Check secondary I/O throughput — if redo cannot keep up, data loss grows over time

**Related checks:** H4, H9, H11

---

### H8 — Estimated Recovery Time

**What it means**
`estimated_recovery_time_seconds` is how long it would take the secondary to redo all
queued log and open for connections after a failover. A high value means a failover will
result in an extended period where the new primary is recovering before it accepts connections,
violating RTO commitments.

**How to spot it**
```
database_name   estimated_recovery_time_seconds   redo_queue_size
SalesDB         420                               650000   (KB)
```

**Example (problem + fix)**
```sql
-- Compute redo rate vs queue to estimate catchup time:
SELECT drs.database_name,
       drs.redo_queue_size / 1024.0           AS redo_queue_mb,
       drs.redo_rate / 1024.0                 AS redo_rate_mb_per_s,
       CASE WHEN drs.redo_rate > 0
            THEN drs.redo_queue_size / drs.redo_rate
            ELSE NULL END                      AS estimated_catchup_sec,
       drs.estimated_recovery_time_seconds
FROM sys.dm_hadr_database_replica_states drs;
```

**Fix options**
1. Reduce redo queue size (H10 fix steps) — recovery time is directly proportional to queue size
2. Improve secondary disk I/O to increase redo rate
3. Evaluate whether the RTO is acceptable; if not, add storage capacity to the secondary

**Related checks:** H10, H12

---

### H9 — Secondary Lag

**What it means**
`secondary_lag_seconds` measures how far behind the secondary is relative to the primary
in terms of committed transactions. It combines both send lag (log not yet sent) and redo
lag (log sent but not yet applied). A high value means read queries on the secondary see
stale data and a failover would require the secondary to redo a large backlog.

**How to spot it**
```
replica_server_name   database_name   secondary_lag_seconds   log_send_queue_size   redo_queue_size
NODE2\SQL2019         SalesDB         85                      450000                200000
```

**Example (problem + fix)**
```sql
-- Decompose lag into send lag vs redo lag:
SELECT ar.replica_server_name,
       drs.database_name,
       drs.secondary_lag_seconds,
       drs.log_send_queue_size / 1024.0   AS send_queue_mb,
       drs.redo_queue_size / 1024.0       AS redo_queue_mb,
       drs.log_send_rate / 1024.0         AS send_rate_mb_s,
       drs.redo_rate / 1024.0             AS redo_rate_mb_s
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id;
```

**Fix options**
1. If `log_send_queue_size` is large: network bandwidth or transport issue (H11, H13)
2. If `redo_queue_size` is large: secondary I/O throughput issue (H10, H12)
3. If both queues are large: the secondary has fallen far behind — check node health (H15)

**Related checks:** H7, H10, H11, H12, H13, H15

---

### H10 — Redo Queue Buildup

**What it means**
`redo_queue_size` is the amount of log (in KB) that has been received by the secondary but
not yet applied to the data files. A large redo queue means the secondary's redo thread
cannot keep up with incoming log, and that a failover will require proportionally more
recovery time before the new primary is ready.

**How to spot it**
```
replica_server_name   database_name   redo_queue_size   redo_rate
NODE2\SQL2019         SalesDB         640000            8200      (KB/s)
```

**Example (problem + fix)**
```sql
-- Check secondary I/O latency (run on secondary):
SELECT DB_NAME(vfs.database_id) AS db_name,
       vfs.file_id,
       vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS avg_write_ms,
       vfs.io_stall_read_ms  / NULLIF(vfs.num_of_reads,  0) AS avg_read_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
ORDER BY avg_write_ms DESC;
```

**Fix options**
1. Investigate secondary disk write latency — redo is write-intensive (see code block)
2. Check whether reporting queries on the readable secondary are competing with redo for I/O
3. Consider placing secondary data files on faster storage (NVMe, dedicated SAN LUN)
4. If lag is temporary (after a burst), monitor for natural recovery as workload settles

**Related checks:** H8, H12, H14

---

### H11 — Log Send Queue Buildup

**What it means**
`log_send_queue_size` is log generated on the primary that has not yet been transmitted to
the secondary. A large send queue means the network link cannot keep up with log generation
rate. If the primary fails while the queue is large, that log is lost (for async replicas).

**How to spot it**
```
replica_server_name   database_name   log_send_queue_size   log_send_rate
NODE2\SQL2019         SalesDB         520000                12400     (KB/s)
```

**Example (problem + fix)**
```sql
-- Estimate time to drain the send queue:
SELECT ar.replica_server_name,
       drs.database_name,
       drs.log_send_queue_size / 1024.0   AS send_queue_mb,
       drs.log_send_rate / 1024.0         AS send_rate_mb_s,
       CASE WHEN drs.log_send_rate > 0
            THEN drs.log_send_queue_size / drs.log_send_rate
            ELSE NULL END                  AS drain_time_sec
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id;
```

**Fix options**
1. Check network bandwidth utilization between primary and secondary
2. If `log_send_rate = 0` (H13 co-fires): the transport is stalled — check endpoint health
3. If `log_send_rate > 0` but queue is growing: log generation exceeds link capacity — consider
   network upgrade or reducing transaction log generation (review large batch operations)

**Related checks:** H7, H9, H13

---

## Category 3: Throughput and Performance (H12–H16)

### H12 — Zero Redo Rate on Synchronizing Database

**What it means**
The redo thread on the secondary has stopped applying log even though there is log waiting
to be applied (`redo_queue_size > 0`) and the database is in SYNCHRONIZING state. This
is abnormal — the redo thread should always be processing its queue.

**How to spot it**
```
database_name   synchronization_state_desc   redo_queue_size   redo_rate
SalesDB         SYNCHRONIZING                180000            0
```

**Example (problem + fix)**
```sql
-- Check for blocking on the secondary (readable secondary scenario):
-- Run on the secondary node:
SELECT blocking_session_id, session_id, wait_type, wait_time,
       DB_NAME(database_id) AS db_name
FROM sys.dm_exec_requests
WHERE blocking_session_id != 0;

-- Suspend and resume to reset the redo thread:
ALTER DATABASE [SalesDB] SET HADR SUSPEND;
ALTER DATABASE [SalesDB] SET HADR RESUME;
```

**Fix options**
1. Check for blocking sessions on the secondary holding row-version locks (readable secondary)
2. Review ERRORLOG on secondary for redo errors: search for `hadr_work_queue` or `redo thread`
3. Suspend and resume HADR for the database to reset the redo thread (see code block)
4. Monitor `last_redone_lsn` in the DMV — if it advances after resume, the stall was transient

**Related checks:** H8, H10

---

### H13 — Zero Log Send Rate with Non-Empty Send Queue

**What it means**
Log is queued on the primary but the HADR transport is not sending it to the secondary.
The send thread has stalled. This is distinct from H1 (disconnected) — the replica may
show as CONNECTED but the send thread has stopped sending.

**How to spot it**
```
replica_server_name   database_name   log_send_queue_size   log_send_rate
NODE2\SQL2019         SalesDB         350000                0
```

**Example (problem + fix)**
```sql
-- Check endpoint status on the primary:
SELECT name, state_desc, connection_auth_desc
FROM sys.database_mirroring_endpoints;

-- Restart the endpoint if STOPPED or DISCONNECTED:
ALTER ENDPOINT [Hadr_endpoint] STATE = STOPPED;
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;

-- Alternatively, check the HADR transport session:
SELECT * FROM sys.dm_hadr_availability_replica_states
WHERE connected_state_desc != 'CONNECTED';
```

**Fix options**
1. Verify endpoint state (see code block) — a STOPPED endpoint halts all log send
2. Check firewall rules for port 5022 (or configured HADR endpoint port) between nodes
3. Review ERRORLOG on primary for transport errors: search for `HADR` and `transport`
4. Restart the HADR endpoint as a last resort (causes a brief reconnection)

**Related checks:** H1, H5, H11

---

### H14 — Redo Rate / Send Rate Mismatch

**What it means**
Log is being sent to the secondary, and the secondary is redoing it, but redo is slower
than the send rate. The redo queue grows over time even though both processes are active.
This is a secondary-side I/O throughput problem, not a network problem.

**How to spot it**
```
database_name   log_send_rate   redo_rate   redo_queue_size (growing)
SalesDB         18400           6200        120000 → 150000 → 180000
```

**Example (problem + fix)**
```sql
-- Monitor the mismatch over time (run every 30 seconds):
SELECT GETDATE() AS sample_time,
       ar.replica_server_name,
       drs.database_name,
       drs.log_send_rate,
       drs.redo_rate,
       drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id;
```

**Fix options**
1. Investigate secondary disk write latency using `sys.dm_io_virtual_file_stats` (see H10)
2. Check whether read-only workloads on the secondary are saturating I/O
3. Profile secondary CPU — redo is single-threaded and CPU-bound on some workloads
4. Consider dedicated storage for AG databases on the secondary

**Related checks:** H10, H12

---

### H15 — Multiple Databases Lagging on Same Replica

**What it means**
When three or more databases on the same secondary replica are simultaneously behind,
the problem is at the node level, not per-database. A single slow database suggests a
database-specific issue; multiple simultaneous laggers point to resource saturation on
the secondary host (CPU, memory, or disk).

**How to spot it**
```
replica_server_name   database_name   secondary_lag_seconds
NODE2\SQL2019         SalesDB         78
NODE2\SQL2019         HRDB            65
NODE2\SQL2019         ReportingDB     91
```

**Example (problem + fix)**
```sql
-- Count lagging databases per replica:
SELECT ar.replica_server_name,
       COUNT(*) AS lagging_db_count,
       AVG(drs.secondary_lag_seconds) AS avg_lag_sec,
       MAX(drs.secondary_lag_seconds) AS max_lag_sec
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE drs.secondary_lag_seconds > 10
GROUP BY ar.replica_server_name
HAVING COUNT(*) >= 3;
```

**Fix options**
1. Check secondary node CPU, memory, and disk I/O via Windows Performance Monitor or SSMS Activity Monitor
2. Look for a single large-transaction database monopolizing redo threads — redo is serial per database
3. Review CLUSTER.LOG for resource pressure events on the secondary node
4. Check Windows memory pressure: `sys.dm_os_memory_clerks` on the secondary

**Related checks:** H9, H10, H12

---

### H16 — Commit Latency Signal on Sync-Commit Replica

**What it means**
A SYNCHRONOUS_COMMIT replica that is in SYNCHRONIZING (rather than SYNCHRONIZED) state
means the primary is actively waiting for this secondary to catch up before it can harden
and acknowledge transactions. Every write on the primary is blocked until the secondary
responds. While SYNCHRONIZING is transient during normal operations, a replica that stays
in SYNCHRONIZING adds measurable latency to all primary transactions.

**How to spot it**
```
replica_server_name   availability_mode_desc   synchronization_state_desc
NODE2\SQL2019         SYNCHRONOUS_COMMIT       SYNCHRONIZING
```

**Example (problem + fix)**
```sql
-- Check how long the replica has been SYNCHRONIZING:
SELECT ar.replica_server_name,
       drs.database_name,
       drs.synchronization_state_desc,
       drs.secondary_lag_seconds,
       drs.estimated_data_loss_seconds
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
  AND drs.synchronization_state_desc = 'SYNCHRONIZING';

-- Measure primary commit latency using sys.dm_os_wait_stats:
SELECT wait_type, waiting_tasks_count,
       wait_time_ms / NULLIF(waiting_tasks_count, 0) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('HADR_SYNC_COMMIT', 'HADR_WORK_QUEUE')
ORDER BY wait_time_ms DESC;
```

**Fix options**
1. Run `/sqlwait-review` to quantify `HADR_SYNC_COMMIT` wait impact on the primary
2. Investigate send and redo queues (H10, H11) — SYNCHRONIZING indicates the secondary is catching up
3. If the replica is persistently SYNCHRONIZING, consider changing to ASYNCHRONOUS_COMMIT if
   the sync-commit requirement is not strict
4. Review secondary node I/O — a slow secondary causes the primary to wait

**Related checks:** H4, H7, H10

---

## Category 4: Configuration (H17–H22)

### H17 — Async Replica in Sync-Expected Position

**What it means**
In a two-replica AG where the second replica is the only disaster recovery target, an
ASYNCHRONOUS_COMMIT mode means data loss is possible on primary failure. If the business
requires zero data loss (RPO = 0), an async-only topology is architecturally misaligned.

**How to spot it**
```
replica_server_name   availability_mode_desc    failover_mode_desc
NODE1\SQL2019         (PRIMARY)                 AUTOMATIC
NODE2\SQL2019         ASYNCHRONOUS_COMMIT       MANUAL
-- Only two replicas; NODE2 is the sole DR target
```

**Example (problem + fix)**
```sql
-- Change async replica to synchronous-commit:
ALTER AVAILABILITY GROUP [SalesAG]
MODIFY REPLICA ON N'NODE2\SQL2019'
WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);

-- Verify estimated data loss drops to 0 after the change:
SELECT replica_server_name,
       availability_mode_desc,
       estimated_data_loss_seconds
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_database_replica_states drs
    ON ar.replica_id = drs.replica_id;
```

**Fix options**
1. Evaluate whether the network and I/O can sustain synchronous-commit latency before switching
2. Test commit latency impact with a representative workload before changing production
3. If network latency is too high for sync, document the async RPO and accept the risk formally

**Related checks:** H6, H18

---

### H18 — No Automatic Failover Replica

**What it means**
Every replica is configured for manual failover. This means a primary failure will leave
the AG without a primary until a DBA manually executes a failover command. The time from
failure detection to manual failover is added to your effective RTO.

**How to spot it**
```
replica_server_name   failover_mode_desc
NODE1\SQL2019         MANUAL
NODE2\SQL2019         MANUAL
NODE3\SQL2019         MANUAL
```

**Example (problem + fix)**
```sql
-- Enable automatic failover on a sync-commit secondary:
ALTER AVAILABILITY GROUP [SalesAG]
MODIFY REPLICA ON N'NODE2\SQL2019'
WITH (FAILOVER_MODE = AUTOMATIC);

-- Verify WSFC quorum is healthy before enabling:
-- In PowerShell: Get-ClusterQuorum
```

**Fix options**
1. Verify WSFC has enough quorum votes to support automatic failover without the primary
2. Configure automatic failover on the highest-priority synchronous-commit secondary
3. At least one automatic failover replica per AG is a minimum best-practice target

**Related checks:** H6, H17

---

### H19 — Single Replica AG

**What it means**
The AG has only one replica — no secondary exists. This configuration provides no high
availability — a primary failure means the AG is offline until the primary is restored.

**How to spot it**
```
-- Only one row in sys.availability_replicas for this AG
ag_name   replica_server_name   role_desc
SalesAG   NODE1\SQL2019         PRIMARY
```

**Example (problem + fix)**
```sql
-- Add a secondary replica:
ALTER AVAILABILITY GROUP [SalesAG]
ADD REPLICA ON N'NODE2\SQL2019' WITH (
    ENDPOINT_URL = N'TCP://NODE2\SQL2019:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC,
    SECONDARY_ROLE (ALLOW_CONNECTIONS = NO)
);
```

**Fix options**
1. Add a secondary replica following the AG Add Replica wizard in SSMS
2. If this is intentional (read-scale only, single-node), document the design decision

**Related checks:** H18

---

### H20 — Listener Not Configured

**What it means**
An AG listener is a virtual network name and IP address that clients connect to regardless
of which replica is currently primary. Without a listener, application connection strings
must hardcode the primary server name and must be updated after every failover.

**How to spot it**
```sql
-- No rows returned:
SELECT * FROM sys.availability_group_listeners
WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = N'SalesAG');
```

**Example (problem + fix)**
```sql
-- Add a listener:
ALTER AVAILABILITY GROUP [SalesAG]
ADD LISTENER N'sales-ag-listener' (
    WITH IP ((N'10.1.0.50', N'255.255.255.0')),
    PORT = 1433
);

-- Application connection string after:
-- Server=sales-ag-listener,1433;Database=SalesDB;Integrated Security=True;
```

**Fix options**
1. Create a listener via the SSMS AG Properties dialog or T-SQL (see code block)
2. Allocate a static IP address on the same subnet as the AG replicas
3. Update application connection strings to use the listener DNS name
4. Test the listener from the application tier before removing the old server-name references

**Related checks:** `sqlag-review` F15 (read-only routing — H21 retired)

---

### Retired — H21 (merged into sqlag-review F15)

**What it means**
H21 used to fire on a readable secondary with `read_only_routing_url IS NULL`. That condition
is identical to `sqlag-review` F15 (Read-Only Routing URL Absent on Readable Secondary) — both
checks evaluate the same static columns (`secondary_role_allow_connections_desc`,
`read_only_routing_url`) from `sys.availability_replicas`, and there is no runtime-only signal
in the `sys.dm_hadr_*` DMVs that distinguishes a "configured but unreachable" routing URL from
a "not configured" one without an active connectivity probe outside this skill's input model.

**Why F15 is the canonical check**
`sqlag-review` owns AG configuration-correctness checks; `sqlhadr-review` owns runtime-health
checks. Read-only routing absence is a configuration gap, not a runtime health symptom, so it
belongs in `sqlag-review`. Run `/sqlag-review` to get this finding (F15).

**Why the ID is retired, not renumbered**
H22–H28 follow H21 in this skill's numbering, and H28 is referenced by ID from `sqlag-review`
F37. Renumbering H22→H21 and so on would cascade into that cross-reference and every check-count
touch point already documented elsewhere. Leaving H21 retired (a documented gap) avoids that
cascade while still deduplicating the finding.

**Related checks:** `sqlag-review` F15 (canonical), H20

---

### H22 — Automatic Seeding Active

**What it means**
Automatic seeding transfers a full copy of the database from the primary to the secondary
over the HADR transport without requiring a manual backup/restore. While seeding is in
progress, the secondary database is not yet in the AG and provides no HA protection for
that database.

**How to spot it**
```
replica_server_name   database_name   synchronization_state_desc   seeding_mode_desc
NODE3\SQL2019         SalesDB         NOT SYNCHRONIZING            AUTOMATIC
```

**Example (problem + fix)**
```sql
-- Monitor automatic seeding progress:
SELECT ag.name AS ag_name,
       ar.replica_server_name,
       adc.database_name,
       haas.current_state,
       haas.performed_seeding,
       haas.start_time,
       haas.completion_time,
       haas.number_of_attempts
FROM sys.dm_hadr_automatic_seeding haas
JOIN sys.availability_groups ag ON haas.ag_id = ag.group_id
JOIN sys.availability_replicas ar ON haas.ag_db_id = ar.replica_id
JOIN sys.availability_group_database_replicas adc
    ON haas.ag_db_id = adc.replica_id;

-- Check seeding errors:
SELECT * FROM sys.dm_hadr_automatic_seeding
WHERE current_state != 'COMPLETED';
```

**Fix options**
1. Monitor progress using `sys.dm_hadr_automatic_seeding` (see code block)
2. Ensure sufficient network bandwidth — seeding transfers the full database over the HADR endpoint
3. If seeding is failing (`number_of_attempts` > 1), check ERRORLOG for seeding error details
4. For very large databases, consider manual backup/restore seeding to avoid prolonged network load

**Related checks:** H19

---

## Category 5: Modern AG Feature Checks (H23–H27)

---

### H23 — Contained AG Misrouted DML

**What it means**
A Contained Availability Group (SQL 2022+) replicates its own system databases (master, msdb) to all replicas, enabling logins, SQL Agent jobs, and linked servers to exist independently of the Windows host. If a contained system database falls out of sync, operations that depend on those objects (jobs, logins, alerts) may fail on the secondary or break after failover.

**How to spot it**
```sql
SELECT g.name AS ag_name, g.is_contained, d.database_name, d.synchronization_state_desc
FROM sys.dm_hadr_database_replica_states d
JOIN sys.availability_groups g ON d.group_id = g.group_id
WHERE g.is_contained = 1 AND d.synchronization_state_desc != 'SYNCHRONIZED';
```

**Common causes**
- DDL on contained system objects while the secondary is lagging
- Redo queue buildup on the secondary blocking system database sync
- Contained AG configured but the cluster was failover-tested before full sync

**Fix options**
1. Check redo queue for the contained system database replicas
2. Resolve blocking redo by reducing transaction size on the primary
3. Confirm intent: `SELECT * FROM sys.availability_groups WHERE is_contained = 1`

**Related checks:** H10 (Redo Queue Buildup), H4 (Replica Not Synchronizing)

---

### H24 — Cloud Witness Inaccessible

**What it means**
Cloud Witness (Windows Server 2016+) uses an Azure Blob Storage account as the WSFC quorum witness. If the witness is unreachable, the cluster is operating without a tie-breaking vote — in a two-node cluster, a node failure means quorum is lost and the AG goes offline. This check fires when `sys.dm_hadr_cluster` shows Cloud Witness as the quorum type but quorum state is abnormal.

**How to spot it**
```sql
SELECT quorum_type_desc, quorum_state_desc FROM sys.dm_hadr_cluster;
-- Expected: CLOUD_WITNESS / QUORUM_IN_PROGRESS_NORMAL
-- Problem: any other quorum_state_desc
```

**Common causes**
- Azure Storage account access key rotated without updating the Cloud Witness configuration
- Firewall or NSG rule change blocking outbound HTTPS to `<account>.blob.core.windows.net`
- Storage account deleted, suspended, or in a different Azure region with intermittent latency

**Fix options**
1. `Test-NetConnection -ComputerName <storageaccount>.blob.core.windows.net -Port 443`
2. Validate the access key in Failover Cluster Manager → Cloud Witness properties
3. If the witness is permanently unavailable, switch to a File Share Witness temporarily while resolving the storage issue

**Related checks:** H18 (No Automatic Failover Replica), H19 (Single Replica AG)

---

### H25 — Parallel Redo Worker Saturation

**What it means**
SQL Server 2016+ uses Parallel Redo to replay transaction log records on secondary replicas using multiple threads. When primary workload generates log faster than the secondary can redo it, the redo queue grows. This check identifies cases where redo threads are at capacity — characterized by a non-zero and growing redo queue combined with a redo rate that cannot keep up with the log send rate.

**How to spot it**
```sql
SELECT r.replica_server_name, d.database_name,
       d.redo_queue_size, d.redo_rate,
       d.log_send_queue_size, d.log_send_rate
FROM sys.dm_hadr_database_replica_states d
JOIN sys.dm_hadr_availability_replica_states r ON d.replica_id = r.replica_id
WHERE d.redo_queue_size > 524288  -- 512 MB
  AND (d.redo_rate = 0 OR d.redo_rate < d.log_send_rate * 0.7);
```

**Common causes**
- Primary running large bulk operations (index rebuild, bulk insert) that generate disproportionate log volume
- Secondary I/O subsystem slower than primary — redo is I/O-bound
- Insufficient CPU on the secondary limiting Parallel Redo threads

**Fix options**
1. Check active redo threads: `SELECT * FROM sys.dm_exec_requests WHERE command LIKE '%REDO%'`
2. On primary, break large operations into smaller batches to reduce instantaneous log generation
3. Review secondary I/O latency for the database files — redo is write-I/O-bound; SSD/NVMe can dramatically increase redo throughput

**Related checks:** H10 (Redo Queue Buildup), H14 (Redo Rate / Send Rate Mismatch)

---

### H26 — Read-Scale Secondary Missing RCSI

**What it means**
A readable secondary replica allows read-only connections, but without Read Committed Snapshot Isolation (RCSI) enabled on the primary database, readers on the secondary acquire shared locks that can conflict with redo thread page access. This causes redo to wait on reader locks, increasing secondary lag and potentially delaying commits on sync-commit primaries.

**How to spot it**
```sql
-- On primary: check RCSI status
SELECT name, is_read_committed_snapshot_on
FROM sys.databases
WHERE name IN (SELECT database_name FROM sys.dm_hadr_database_replica_states);
-- is_read_committed_snapshot_on = 0 with a readable secondary = problem
```

**Common causes**
- Database created before AG was set up; RCSI was not enabled
- DBA disabled RCSI to reduce version store overhead without knowing the AG secondary was readable
- Migration from a non-AG environment where RCSI was not required

**Fix options**
1. Enable RCSI: `ALTER DATABASE [db] SET READ_COMMITTED_SNAPSHOT ON` — this propagates to all replicas automatically
2. Monitor version store growth after enabling: `SELECT * FROM sys.dm_tran_version_store_space_usage`
3. Confirm: `SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = 'db'`

**Related checks:** `sqlag-review` F15 (Read-Only Routing URL Absent — H21 retired), H9 (Secondary Lag)

---

### H27 — AG Without Database-Level Health Detection

**What it means**
By default, AG failover is triggered only by instance-level failures (SQL Server process dies, lease timeout). With `DB_FAILOVER = OFF`, a database that goes suspect, offline, or into recovery mode does not trigger AG failover — applications connecting through the listener will see errors until someone manually intervenes. This check identifies AGs that have not enabled database-level health detection.

**How to spot it**
```sql
SELECT name, db_failover
FROM sys.availability_groups
WHERE db_failover = 0;
```

**Common causes**
- Default AG configuration; `DB_FAILOVER` defaults to OFF in all SQL Server versions
- DBA explicitly disabled it to avoid failovers triggered by transient database recovery events

**Fix options**
1. Enable: `ALTER AVAILABILITY GROUP [ag] SET (DB_FAILOVER = ON)`
2. Test before enabling in production — verify that the workload does not generate transient database recovery events that would cause spurious failovers
3. Document the decision either way; if left OFF, ensure monitoring alerts on database state changes

**Related checks:** H18 (No Automatic Failover Replica), H2 (Replica in Resolving State)

---

## Category 6: Seeding and Initialization Integrity (H28)

### H28 — Secondary Database Stuck in INITIALIZING State

**What it means**
`INITIALIZING` is one of five values for `synchronization_state_desc` (alongside `NOT
SYNCHRONIZING`, `SYNCHRONIZING`, `SYNCHRONIZED`, `REVERTING`). Microsoft documents it as the
phase of undo in which the transaction log a secondary needs to catch up to the undo LSN is
still being shipped and hardened on that secondary. Microsoft Learn carries an explicit caution
for this state: forcing failover to a secondary replica while its database is `INITIALIZING`
leaves the database in a state where it cannot be started as a primary database — it must
either reconnect as a secondary to resume normal data movement, or have new log records applied
from a log backup. This means the danger window is not "the database is unhealthy" in the way
`NOT SYNCHRONIZING` is — it is a transient state that becomes a stuck state specifically if a
failover happens to land on it.

**How to spot it**
```sql
SELECT ag.name AS ag_name, ar.replica_server_name, drs.database_name,
       drs.synchronization_state_desc, drs.is_suspended, drs.suspend_reason_desc,
       drs.redo_queue_size, drs.redo_rate, drs.last_redone_time
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE drs.synchronization_state_desc = 'INITIALIZING';
```
Sample the query at least twice a few minutes apart — `INITIALIZING` alone is not abnormal
during a legitimate seed or rejoin; what makes it a finding is no forward progress between
samples, or its presence immediately after a failover event.

**Common causes**
- A failover occurred while a secondary database had not yet finished initial data movement
  (legitimately mid-seed, mid-rejoin after a long outage, or mid-catch-up after a large backlog)
- An automatic-seeding attempt collided with a manual backup/restore-based join — `SEEDING_MODE`
  is evaluated dynamically every time a database is added to the AG, so a replica left at
  `AUTOMATIC` can start its own seed in parallel with an operator's manual restore, leaving a
  hybrid/inconsistent copy that reports healthy under routine log streaming and only surfaces
  as stuck `INITIALIZING` at the next forced full redo/undo pass (failover)
- Observed pattern, applicable to any manual-restore workflow (a single database add, a DR
  rebuild, or a large migration): `seeding_mode = AUTOMATIC` is left on while databases are
  restored manually `WITH NORECOVERY`, primaries brought online, and `ADD DATABASE` run; all
  secondaries join and the AG reports healthy — but a database on the new secondary after a
  later failover is found stuck in `INITIALIZING`/`RECOVERY_PENDING`

**Fix options**
1. Do not force failover onto a replica while a database shows `INITIALIZING` — wait for it to
   reach `SYNCHRONIZING`/`SYNCHRONIZED` first if failover is plannable.
2. If a database is already stuck post-failover, check `last_redone_time` and `redo_queue_size`
   trend for any progress before concluding it is truly stuck rather than just slow.
3. To recover a stuck database, either reconnect it as a secondary to a healthy primary so
   normal log streaming resumes, or restore it from a log-backup chain to bring it current.
4. If this followed a manual-restore operation, audit `seeding_mode_desc` on every replica
   (`sqlag-review` F37) — `AUTOMATIC` left active alongside a manual-restore workflow is the
   most likely root cause of a single inconsistent database surviving pre-failover health
   checks undetected.
5. Going forward, explicitly set `SEEDING_MODE = MANUAL` before any manual-restore operation,
   and verify each database's synchronization state individually after `ADD DATABASE` rather
   than relying solely on the AG-level healthy rollup.

**Related checks:** H10 (Redo Queue Buildup — requires `SYNCHRONIZING`, does not cover
`INITIALIZING`), H12 (Zero Redo Rate — same `SYNCHRONIZING` requirement), `sqlag-review` F37
(automatic seeding left enabled during a manual-restore workflow — the configuration-level
root cause)

**Microsoft Learn reference:** [sys.dm_hadr_database_replica_states (Transact-SQL)](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-hadr-database-replica-states-transact-sql) — `synchronization_state` value `4` = `INITIALIZING`, with the documented caution that forcing failover to a secondary in this state leaves the database unable to start as primary.


---

## Quick Reference

| Check | Category | Severity | Key Signal |
|-------|----------|----------|-----------|
| H1 | Connectivity | Critical | `connected_state_desc = DISCONNECTED` |
| H2 | Connectivity | Critical | `role_desc = RESOLVING` |
| H3 | Connectivity | Critical | `synchronization_health_desc = NOT_HEALTHY` (replica) |
| H4 | Connectivity | Critical | `synchronization_state_desc = NOT SYNCHRONIZING` on sync-commit |
| H5 | Connectivity | Warning | `last_connect_error_number != 0` |
| H6 | Connectivity | Warning | `failover_mode_desc = MANUAL` on sync-commit replica |
| H7 | Data Loss | Critical/Warning | `estimated_data_loss_seconds` > threshold |
| H8 | Recovery Time | Warning | `estimated_recovery_time_seconds` > 300 sec |
| H9 | Secondary Lag | Critical/Warning | `secondary_lag_seconds` > threshold |
| H10 | Redo Queue | Critical/Warning | `redo_queue_size` > threshold |
| H11 | Log Send Queue | Warning | `log_send_queue_size` > 500 MB |
| H12 | Throughput | Warning | `redo_rate = 0` with queue and SYNCHRONIZING |
| H13 | Throughput | Warning | `log_send_rate = 0` with non-empty send queue |
| H14 | Throughput | Warning | `redo_rate` << `log_send_rate`, queue growing |
| H15 | Throughput | Critical | ≥3 databases lagging >10 sec on same replica |
| H16 | Throughput | Warning | Sync-commit replica in SYNCHRONIZING (stalling commits) |
| H17 | Configuration | Info | Async-only replica in sole DR position |
| H18 | Configuration | Warning | No replica has `failover_mode_desc = AUTOMATIC` |
| H19 | Configuration | Info | Only one replica in the AG |
| H20 | Configuration | Info | No listener configured |
| H21 | Retired | — | Merged into `sqlag-review` F15 (read-only routing URL absent) |
| H22 | Configuration | Info | Automatic seeding in progress |
| H23 | Modern — Contained AG | Warning | Contained system database not SYNCHRONIZED |
| H24 | Modern — Cloud Witness | Critical | Cloud Witness quorum state abnormal |
| H25 | Modern — Parallel Redo | Warning | Redo queue growing; redo rate < send rate |
| H26 | Modern — RCSI | Warning | Readable secondary, RCSI disabled on primary |
| H27 | Modern — DB Health | Info | `db_failover = 0` on HA-configured AG |
| H28 | Seeding/Initialization | Critical | `synchronization_state_desc = INITIALIZING`, stuck or post-failover |
