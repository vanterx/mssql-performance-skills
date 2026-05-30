# HADR Health Analysis

### Summary
- **3 Critical, 3 Warnings, 2 Info**
- Availability group: **SalesAG**
- Replicas:
  - NODE1\SQL2022 — PRIMARY (CONNECTED, HEALTHY)
  - NODE2\SQL2022 — SECONDARY (DISCONNECTED, NOT_HEALTHY) — **critical**
  - NODE3\SQL2022 — SECONDARY (CONNECTED, PARTIALLY_HEALTHY, async)
- Highest-risk finding: **[C1 — H1] Replica Disconnected — NODE2\SQL2022**

---

## Critical Issues

### [C1 — H1] Replica Disconnected — NODE2\SQL2022
- **Observed:** `connected_state_desc = DISCONNECTED`; `last_connect_error_number = 35206`;
  `last_connect_error_description = "The connection attempt to secondary replica
  'NODE2\SQL2022' timed out. This is a transient error. The remote endpoint may be
  inaccessible."`; all three databases on this replica show `NOT SYNCHRONIZING`.
- **Impact:** No log is being sent to NODE2\SQL2022. All three databases (SalesDB, HRDB,
  ReportingDB) are accumulating redo queue with zero send rate. Because NODE2 is configured
  as a SYNCHRONOUS_COMMIT replica, any primary commits that were waiting on acknowledgement
  from this replica have been blocked or rerouted. Automatic failover to NODE2 is impossible
  while it is disconnected.
- **Fix:** Verify network connectivity to NODE2\SQL2022 and confirm the SQL Server service
  is running. Check the HADR endpoint state on NODE2: `SELECT state_desc FROM
  sys.database_mirroring_endpoints`. Review CLUSTER.LOG for network partition or node
  eviction events. If the endpoint is STOPPED, restart it: `ALTER ENDPOINT [Hadr_endpoint]
  STATE = STARTED`. Once reconnected, monitor log send queue drain rate.

### [C2 — H3 / H4] Synchronization Unhealthy — NODE2\SQL2022 (All Databases NOT SYNCHRONIZING)
- **Observed:** `synchronization_health_desc = NOT_HEALTHY` at replica level. All three
  databases show `synchronization_state_desc = NOT SYNCHRONIZING` and
  `db_sync_health = NOT_HEALTHY`. Root cause is the disconnection (C1 above).
- **Impact:** A SYNCHRONOUS_COMMIT replica that is NOT SYNCHRONIZING adds latency to primary
  commits because SQL Server attempts to send log to the secondary. Until connectivity is
  restored, the primary may operate in an unprotected single-replica state.
- **Fix:** Restore connectivity to NODE2\SQL2022 (see C1). Once reconnected, the databases
  will transition to SYNCHRONIZING and then SYNCHRONIZED automatically. If recovery is
  delayed, run `ALTER DATABASE [SalesDB] SET HADR RESUME` for each database after verifying
  the secondary is online.

### [C3 — H10] Redo Queue Critical — NODE2\SQL2022, SalesDB (620 MB)
- **Observed:** `redo_queue_size = 635,904 KB` (~620 MB) for SalesDB on NODE2\SQL2022.
  `redo_rate = 0` (redo thread is not active due to disconnection). HRDB: 180 MB redo queue.
  ReportingDB: 96 MB redo queue.
- **Impact:** After reconnection, NODE2\SQL2022 must apply ~900 MB of queued redo log across
  all three databases before reaching SYNCHRONIZED state. The `estimated_recovery_time_seconds`
  for SalesDB is 388 seconds (~6.5 minutes) — this is the minimum time to complete
  resynchronization after reconnection. During this window, automatic failover to NODE2 is
  not available.
- **Fix:** After resolving C1 and restoring connectivity, monitor redo queue drain with:
  ```sql
  SELECT drs.database_name, drs.redo_queue_size / 1024.0 AS redo_mb,
         drs.redo_rate / 1024.0 AS redo_rate_mb_s
  FROM sys.dm_hadr_database_replica_states drs
  JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
  WHERE ar.replica_server_name = N'NODE2\SQL2022';
  ```
  Check secondary disk I/O if the redo rate is low after reconnection.

---

## Warnings

### [W1 — H18] No Automatic Failover Replica
- **Observed:** Both NODE2\SQL2022 and NODE3\SQL2022 have `failover_mode_desc = MANUAL`.
  NODE1\SQL2022 (PRIMARY) has `failover_mode_desc = AUTOMATIC` but this applies to failover
  *from* the primary, not *to* a secondary. No secondary is configured for automatic failover.
- **Impact:** If the primary (NODE1\SQL2022) fails, the AG will have no primary until a DBA
  manually executes `ALTER AVAILABILITY GROUP [SalesAG] FORCE_FAILOVER_ALLOW_DATA_LOSS` or
  `ALTER AVAILABILITY GROUP [SalesAG] FAILOVER`. This increases effective RTO by the time
  required for an on-call DBA to respond and execute the failover.
- **Fix:** Once NODE2\SQL2022 is reconnected and SYNCHRONIZED, configure automatic failover:
  ```sql
  ALTER AVAILABILITY GROUP [SalesAG]
  MODIFY REPLICA ON N'NODE2\SQL2022'
  WITH (FAILOVER_MODE = AUTOMATIC);
  ```
  Verify WSFC quorum health before enabling. NODE3 is ASYNCHRONOUS_COMMIT and cannot be
  an automatic failover target — focus on NODE2.

### [W2 — H7] Estimated Data Loss — NODE2\SQL2022, SalesDB (42 sec — Critical)
- **Observed:** `estimated_data_loss_seconds = 42` for SalesDB on NODE2\SQL2022. HRDB: 36
  seconds. ReportingDB: 29 seconds. These values exceed the 30-second Critical threshold.
  NODE3\SQL2022 SalesDB: `estimated_data_loss_seconds = 8` (Warning threshold >5 sec, below
  Critical threshold of 30 sec).
- **Impact:** If NODE1\SQL2022 failed at the moment of this capture, up to 42 seconds of
  committed transactions would be unrecoverable from NODE2\SQL2022. This exceeds a typical
  RPO target for a SYNCHRONOUS_COMMIT replica (which should be 0 under normal conditions).
  The high value is a consequence of the disconnection (C1).
- **Fix:** Resolving C1 (reconnecting NODE2) will allow the secondary to catch up and
  estimated_data_loss_seconds to return to 0 for a sync-commit replica. For NODE3 (async),
  an 8-second data loss figure is acceptable for most async RPO targets but should be
  documented.

### [W3 — H9] Secondary Lag Critical — NODE2\SQL2022, SalesDB (85 sec)
- **Observed:** `secondary_lag_seconds = 85` for SalesDB on NODE2\SQL2022 (Critical: >60
  sec). HRDB: 77 seconds (Critical). ReportingDB: 68 seconds (Critical). NODE3\SQL2022
  SalesDB: `secondary_lag_seconds = 12` (Warning: >10 sec, below Critical).
- **Impact:** NODE2\SQL2022 is more than 85 seconds behind the primary on the most critical
  database. Failover to NODE2 would require redo of 85+ seconds of log, during which
  the database is unavailable to applications.
- **Fix:** Lag on NODE2 is entirely caused by the disconnection (C1). After reconnection,
  lag will reduce as the redo queue drains. Monitor `secondary_lag_seconds` to confirm
  recovery. For NODE3 SalesDB, the 12-second lag is borderline Warning — investigate
  `log_send_queue_size = 524,800 KB` (~512 MB), which suggests the send queue is growing
  (H11 co-fires below).

---

## Info

### [I1 — H20] Listener Not Configured — SalesAG
- **Observed:** `sys.availability_group_listeners` returned no rows for SalesAG. Application
  connections must currently target NODE1\SQL2022 (or the primary by server name) directly.
- **Impact:** After any failover (planned or unplanned), every application connection string
  referencing the primary by server name will need to be updated or the application will
  fail to connect to the new primary.
- **Fix:** Create an AG listener with a static IP on the same subnet:
  ```sql
  ALTER AVAILABILITY GROUP [SalesAG]
  ADD LISTENER N'salesag-listener' (
      WITH IP ((N'10.1.0.100', N'255.255.255.0')),
      PORT = 1433
  );
  ```
  Update application connection strings to use `salesag-listener` as the server name.

### [I2 — H21] Read-Only Routing Not Configured — NODE2\SQL2022, NODE3\SQL2022
- **Observed:** Both NODE2\SQL2022 and NODE3\SQL2022 have `read_only_routing_url = NULL`
  despite being configured as readable secondaries (`secondary_role_allow_connections_desc
  = ALL` for NODE2, `READ_ONLY` for NODE3).
- **Impact:** `ApplicationIntent=ReadOnly` connections are not automatically redirected to
  a readable secondary. Reporting workloads that could be offloaded to NODE3\SQL2022 are
  landing on the primary, adding unnecessary I/O load.
- **Fix:** Configure routing on both replicas and the primary:
  ```sql
  -- Set routing URLs on secondaries:
  ALTER AVAILABILITY GROUP [SalesAG]
  MODIFY REPLICA ON N'NODE3\SQL2022'
  WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://NODE3\SQL2022.domain.com:1433'));

  -- Set routing list on primary:
  ALTER AVAILABILITY GROUP [SalesAG]
  MODIFY REPLICA ON N'NODE1\SQL2022'
  WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = (N'NODE3\SQL2022')));
  ```
  Requires a listener (I1) — configure the listener first, then routing.

---

## Passed Checks

| Check | Result |
|-------|--------|
| H2 — Replica in Resolving State | PASS — no replica shows `role_desc = RESOLVING` |
| H5 — Last Connect Error (NODE3) | PASS — `last_connect_error_number = 0` for NODE3\SQL2022 |
| H6 — Manual Failover on Sync Replica | INFO — NODE2 is sync/manual; captured as W1 (H18); NODE2 itself is not currently operable for failover |
| H8 — Estimated Recovery Time (NODE3) | PASS — `estimated_recovery_time_seconds = 0` for NODE3 databases |
| H11 — Log Send Queue (NODE3 HRDB/ReportingDB) | PASS — `log_send_queue_size = 0` for HRDB and ReportingDB on NODE3 |
| H12 — Zero Redo Rate (NODE3) | PASS — `redo_rate > 0` for all SYNCHRONIZING databases on NODE3 |
| H13 — Zero Log Send Rate (NODE3) | PASS — `log_send_rate > 0` for all NODE3 databases with activity |
| H14 — Redo/Send Rate Mismatch (NODE3) | PASS — `redo_rate (18,400 KB/s)` ≥ `log_send_rate (14,200 KB/s)` for SalesDB; queue not accumulating |
| H16 — Commit Latency (NODE3 SalesDB) | INFO — NODE3 SalesDB is SYNCHRONIZING but NODE3 is ASYNC_COMMIT; no primary commit stall from async replica |
| H17 — Async Replica in Sole DR Position | PASS — NODE2 is sync-commit; NODE3 async is a third replica, not the sole DR target |
| H19 — Single Replica AG | PASS — three replicas are configured |
| H22 — Automatic Seeding Active | PASS — no rows in `sys.dm_hadr_automatic_seeding` with active state |

---

## Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Investigate network/service failure on NODE2\SQL2022; restart HADR endpoint if stopped | C1, C2, C3 | 15–30 min |
| 2 — After NODE2 reconnects | Monitor redo queue drain on NODE2 (target: redo_queue_size → 0) | C3 | Passive monitoring |
| 3 — Today | Enable AUTOMATIC failover on NODE2\SQL2022 once it reaches SYNCHRONIZED state | W1 | 10 min |
| 4 — This sprint | Create AG listener `salesag-listener` with static IP | I1 | 30 min |
| 5 — This sprint | Configure read-only routing on NODE3\SQL2022 (requires listener first) | I2 | 20 min |
