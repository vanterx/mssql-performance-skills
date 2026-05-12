# ERRORLOG Review — Checks Explained

Plain-English explanations of all 28 checks (E1–E28) with examples, fix recipes, and a Quick Reference table.

---

## Category 1 — AG / High Availability (E1–E8)

### E1 — AG Failover Event

**What it means**
SQL Server recorded a role change in an Always On Availability Group — either planned
(administrator-initiated) or automatic (triggered by WSFC detecting the primary as unhealthy).
Even planned failovers cause a brief application outage while DNS/listener updates propagate.

**How to spot it**
```
2026-01-15 14:32:08.34 spid28s     Always On Availability Groups: The local replica of
availability group 'AG1' is changing roles from 'PRIMARY' to 'SECONDARY' because of an
automatic failover in response to a request from the Windows Server Failover Cluster (WSFC).
```

**Example (problem + fix)**

Problem — unplanned failover at 14:32:
```
14:28:44  spid5s     SQL Server has encountered 1 occurrence(s) of I/O requests taking longer
                     than 15 seconds to complete on file E:\Data\AG1_Primary.mdf
14:32:05  spid28s    The lease between the availability group 'AG1' and WSFC has expired
14:32:08  spid28s    AG1 is changing roles from PRIMARY to SECONDARY (automatic failover)
```

Fix — resolve the I/O latency on E:\Data (E15 root cause) so the sp_server_diagnostics
thread meets its deadline and the lease does not expire.

**Fix options**
1. For unplanned failovers, trace the causal chain: E15 (I/O slow) → E2 (lease expiry) → E1
2. For planned failovers in unexpected windows, check change-management records
3. After resolution, use `/sqlwait-review` to verify `HADR_SYNC_COMMIT` waits have subsided

**Related checks:** E2, E3, E6

---

### E2 — Lease Expiry

**What it means**
The sp_server_diagnostics thread on the primary missed its deadline for reporting to WSFC.
WSFC concluded the primary was unhealthy and initiated a failover. Lease expiry is the
most frequently misdiagnosed AG failure — it looks like a network problem but is almost
always caused by SQL Server being too busy to respond (I/O stall, non-yielding scheduler,
or memory pressure).

**How to spot it**
```
2026-01-15 14:32:05.12 spid28s    The lease between the availability group 'AG1' and the
Windows Server Failover Cluster has expired. A connectivity problem occurred between the
instance of SQL Server and the Windows Server Failover Cluster.
```

**Example (problem + fix)**

Problem — lease expiry caused by storage latency:
```
14:28:44  I/O requests taking longer than 15 seconds (E:\Data\AG1_Primary.mdf)
14:32:05  Lease between AG1 and WSFC has expired
14:32:08  AG1 changing roles PRIMARY -> SECONDARY (automatic failover)
```

Fix — the sp_server_diagnostics thread could not complete in time because I/O was blocked.
Reduce storage latency (SAN/NVMe queue depth, RAID controller cache, VM IOPS limits).

**Fix options**
1. Fix the root cause first (E15, E13, or E10 co-present in the same 5-min window)
2. Validate that sp_server_diagnostics thread is not blocked: look for SOS_SCHEDULER_YIELD
   or PREEMPTIVE_OS_GETPROCADDRESS waits in `/sqlwait-review`
3. Increase `LeaseTimeout` in WSFC only as a temporary measure while the root cause is fixed

**Related checks:** E1, E6, E13, E15

---

### E3 — Replica State Change

**What it means**
The local availability replica is transitioning between roles (PRIMARY, SECONDARY, RESOLVING).
Normal during planned failovers; unexpected transitions during business hours indicate an
operational problem.

**How to spot it**
```
2026-01-15 14:32:08.34 spid28s    Always On Availability Groups: The local replica of
availability group 'AG1' is preparing to transition to the primary role in response to a
request from the Windows Server Failover Cluster (WSFC) cluster.
```

**Example (problem + fix)**

Problem — replica cycling through RESOLVING state:
```
09:15:02  AG1: local replica transitioning to RESOLVING
09:15:45  AG1: local replica transitioning to SECONDARY
09:18:03  AG1: local replica transitioning to RESOLVING   ← second cycle
```

Fix — RESOLVING usually means a WSFC quorum vote is in flux. Check WSFC cluster log for
node evictions or network partition events at the same timestamp.

**Fix options**
1. Check Windows Event Log and WSFC cluster log for the triggering event at the same timestamp
2. Confirm WSFC quorum configuration — odd-number of votes, or file share witness, is required
3. For frequent transitions, review E6 (health-check timeout) and E2 (lease expiry)

**Related checks:** E1, E2, E6

---

### E4 — AG Database Joining Failure

**What it means**
A database that is part of an AG could not join or re-join on the secondary replica. The
secondary replica is running, but this specific database is not receiving log records from
the primary — providing false HA coverage that would not survive a failover.

**How to spot it**
```
2026-01-15 09:44:18.21 spid45s    Failed to join local availability database 'SalesDB'
to availability group 'AG1'. Refer to the SQL Server error log for error details.
```

**Example (problem + fix)**

Problem — database failed to join after a manual re-seed:
```
09:44:18  Failed to join local availability database 'SalesDB' to availability group 'AG1'
```

Diagnosis:
```sql
SELECT db_name(database_id), synchronization_state_desc, redo_queue_size, suspend_reason_desc
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1;
```

Fix — if `synchronization_state_desc` is `NOT SYNCHRONIZING`, re-join:
```sql
ALTER DATABASE [SalesDB] SET HADR AVAILABILITY GROUP = [AG1];
```

**Fix options**
1. Check `sys.dm_hadr_database_replica_states` for `synchronization_state_desc` and `suspend_reason_desc`
2. If the redo queue is growing faster than `redo_rate`, the secondary disk is too slow (E15)
3. If the database is in an error state, restore from backup and re-initialize with `WITH SEEDING`

**Related checks:** E5, E7

---

### E5 — Data Synchronisation Suspended

**What it means**
Log record movement from the primary to a secondary database has been paused. This may be
manual (intentional maintenance) or automatic (triggered by a redo thread error or I/O
problem on the secondary). While suspended, the RPO clock is running — any failover to this
replica will result in data loss equal to the redo queue at the time of suspension.

**How to spot it**
```
2026-01-15 10:22:47.90 spid44s    Data movement for availability database 'SalesDB'
on availability group 'AG1' has been suspended.
```

**Example (problem + fix)**

Problem — suspension triggered by redo thread error (E7):
```
10:22:33  An error occurred in the redo thread for database 'SalesDB' (E7)
10:22:47  Data movement for 'SalesDB' on AG1 has been suspended
```

Fix — resolve E7 first (identify and fix the redo thread error), then resume:
```sql
ALTER DATABASE [SalesDB] SET HADR RESUME;
```

**Fix options**
1. Determine cause: `SELECT suspend_reason_desc FROM sys.dm_hadr_database_replica_states`
2. Manual suspension (`suspend_reason_desc = 'SUSPEND_FROM_USER'`): resume when maintenance is complete
3. Automatic suspension: resolve E7 or E15 first; then resume and monitor redo queue

**Related checks:** E4, E7

---

### E6 — AG Health Check Timeout

**What it means**
The WSFC health check for this AG exceeded its configured timeout. WSFC polls SQL Server
via sp_server_diagnostics for health reports. When SQL Server cannot respond within the
`HealthCheckTimeout` window, WSFC initiates an automatic failover. This entry always
immediately precedes or co-occurs with E1 (failover) and E2 (lease expiry).

**How to spot it**
```
2026-01-15 14:31:58.07 spid5s     The availability group 'AG1' exceeded the health-check
timeout. SQL Server will perform automatic failover.
```

**Example (problem + fix)**

Problem — health-check timeout due to non-yielding scheduler (E13):
```
14:30:11  Process appears to be non-yielding on Scheduler 3 (E13)
14:31:58  AG1 exceeded the health-check timeout
14:32:05  Lease between AG1 and WSFC has expired (E2)
14:32:08  AG1 changing roles PRIMARY -> SECONDARY (E1)
```

Fix — resolve the non-yielding scheduler (E13). Health-check timeout is a symptom, not the cause.

**Fix options**
1. Identify root cause: check for E9, E10, E13, or E15 in the same 2-minute window
2. Do not increase `HealthCheckTimeout` without fixing the responsiveness problem
3. After resolving root cause, monitor `/sqlwait-review` for `HADR_WORK_QUEUE` latency

**Related checks:** E1, E2, E13, E15

---

### E7 — Redo Thread Error

**What it means**
The redo thread on the secondary replica encountered an error while applying log records from
the primary. The secondary has stopped applying log records and is now falling further behind.
Unlike a suspended state (E5), this is an error condition — the thread will not automatically
resume without intervention.

**How to spot it**
```
2026-01-15 11:03:22.44 spid67s    An error occurred in the redo thread for database 'SalesDB'.
Error: 824, Severity: 24, State: 2.
```

**Example (problem + fix)**

Problem — redo thread failed with error 824 (I/O consistency error):
```
11:03:22  An error occurred in the redo thread for database 'SalesDB'. Error 824 (I/O consistency)
```

This indicates corruption on the secondary — the page read from disk does not match the
expected checksum in the log record.

Fix — restore the secondary database from a verified backup and re-seed:
```sql
-- On primary: re-initialize secondary with automatic seeding
ALTER DATABASE [SalesDB] SET HADR AVAILABILITY GROUP = [AG1] WITH (SEEDING_MODE = AUTOMATIC);
```

**Fix options**
1. Error 824: corruption on secondary — restore from backup and re-seed
2. Disk full: free space on the secondary data/log volume and resume (E17 may co-fire)
3. Version mismatch after upgrade: ensure all replicas are on the same SQL Server major version

**Related checks:** E4, E5, E16

---

### E8 — Secondary Not Synchronising

**What it means**
The secondary redo queue is growing — log records are being generated on the primary faster
than the secondary can apply them. This is a throughput problem, not an error condition.
Failing over to this replica while it is lagging will result in data loss equal to the
current redo queue depth.

**How to spot it**
```
2026-01-15 12:15:03.80 spid44s    Waiting for redo catch-up. Redo thread is processing
log at a rate lower than the log send rate for database 'ReportingDB'.
```

Or check the DMV directly:
```sql
SELECT db_name(database_id) AS database_name, redo_queue_size, redo_rate,
       log_send_queue_size, log_send_rate
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 0;
```

**Example (problem + fix)**

Problem — redo rate (500 KB/s) < log generation rate (2,000 KB/s); redo queue growing at
1.5 MB/s.

Fix — investigate secondary disk I/O. The secondary may be on slower storage than the primary.
Check IOPS and latency using `/sqlwait-review` and E15 on the secondary.

**Fix options**
1. Secondary on slower storage: upgrade secondary storage or move redo-intensive databases to
   faster volumes
2. High network latency: check network bandwidth and latency between replicas
3. Large transaction on primary: monitor and wait for the transaction to complete; the redo
   thread will catch up once the burst subsides

**Related checks:** E4, E5, E15

---

## Category 2 — Memory and Resource Pressure (E9–E14)

### E9 — FAIL_PAGE_ALLOCATION

**What it means**
SQL Server attempted to allocate a memory page from the OS and was refused. This is a
harder failure than a grant timeout (E14) — it means SQL Server's internal memory manager
could not satisfy the request at all, not just slowly. This typically appears after E10
(OS paging) has already occurred or when max server memory is set too close to physical RAM.

**How to spot it**
```
2026-01-15 08:44:12.33 spid35s    FAIL_PAGE_ALLOCATION 3
```

**Example (problem + fix)**

Problem — SQL Server consuming all RAM, OS has no headroom:
```
08:44:12  FAIL_PAGE_ALLOCATION 3
08:44:18  A significant part of sql server process memory has been paged out (E10)
```

Fix — reduce `max server memory`:
```sql
EXEC sp_configure 'max server memory (MB)', 57344;  -- for a 64 GB server, leave 7 GB for OS
RECONFIGURE;
```

**Fix options**
1. Reduce `max server memory` to leave OS headroom (at least 10% RAM or 4 GB, whichever is larger)
2. Enable `Lock Pages in Memory` (LPIM) for the SQL Server service account to prevent paging
3. Identify largest memory consumers: `SELECT type, SUM(pages_kb)/1024 AS mb FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY 2 DESC`

**Related checks:** E10, E11, E26

---

### E10 — OS Memory Pressure

**What it means**
Windows has physically moved SQL Server buffer pool pages from RAM to the disk-based page
file. When SQL Server next accesses those pages, it triggers a physical disk read — turning
what should be microsecond memory access into millisecond disk I/O. Sustained paging
causes dramatic performance degradation across all queries.

**How to spot it**
```
2026-01-15 08:45:02.77 spid3s     A significant part of sql server process memory has been
paged out. This may result in a performance degradation. Duration: 0 seconds. Working set (KB):
4521234, committed (KB): 8823456, memory utilization: 51%.
```

**Example (problem + fix)**

Problem — antivirus software consuming 8 GB of RAM, leaving SQL Server's working set paged:
Fix — identify non-SQL Server processes consuming RAM, then enable LPIM:
```
-- In Local Security Policy → User Rights → Lock Pages in Memory
-- Add the SQL Server service account (not sysadmin — a service account login)
-- Restart SQL Server service for LPIM to take effect
```

**Fix options**
1. Enable `Lock Pages in Memory` (LPIM) for the SQL Server service account — prevents Windows
   from paging the buffer pool
2. Reduce `max server memory` so the OS has headroom without needing to page SQL Server
3. Eliminate competing processes (antivirus, ETL agents) consuming large amounts of RAM on
   the SQL Server host

**Related checks:** E9, E26

---

### E11 — Buffer Pool Insufficient

**What it means**
SQL Server's Resource Governor resource pool (or the default pool) has insufficient memory
to satisfy a query's memory grant request. Queries requiring sorts, hash joins, or parallel
operations need a memory grant before execution; when none is available, they wait on
`RESOURCE_SEMAPHORE`. If the wait exceeds the timeout, the query fails with error 8645.

**How to spot it**
```
2026-01-15 09:12:44.01 spid78s    There is insufficient system memory in resource pool
'default' to run this query.
```

**Example (problem + fix)**

Problem — a large reporting query requesting 4 GB grant on a server with only 2 GB available:
```sql
-- Query needing a large sort
SELECT * FROM BigTable ORDER BY LargeColumn;
-- Fails with: There is insufficient system memory in resource pool 'default'
```

Fix — use Resource Governor to cap ad-hoc grants, and tune the query:
```sql
-- Cap memory grants for reporting workload
ALTER RESOURCE POOL [ReportingPool] WITH (MAX_MEMORY_PERCENT = 40);
ALTER WORKLOAD GROUP [ReportingWG] WITH (REQUEST_MAX_MEMORY_GRANT_PERCENT = 25);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

**Fix options**
1. Increase physical RAM and `max server memory` if headroom exists
2. Tune the large-grant query — update statistics, add indexes to avoid sorts and hash joins
3. Use Resource Governor to cap ad-hoc query grants, leaving headroom for OLTP grants

**Related checks:** E9, E14

---

### E12 — Worker Thread Exhaustion

**What it means**
SQL Server uses a pool of worker threads to process requests. When all threads are in use
(each serving a query, waiting for a lock, or sleeping in a connection pool), new requests
queue on `THREADPOOL` waits. If the pool is exhausted, new connections receive error 17189
("SQL Server is not ready to accept new client connections").

**How to spot it**
```
2026-01-15 10:33:55.19 spid5s     There are no more threads available to process new requests
in the application domain. SQL Server has reached the maximum number of worker threads.
```

**Example (problem + fix)**

Problem — a blocking chain with 1,200 spids all waiting on a single lock:
```sql
-- Identify the head blocker
SELECT blocking_session_id, session_id, wait_type, wait_time, sql_handle
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0
ORDER BY wait_time DESC;
```

Fix — kill the head blocker; add an index to reduce lock duration on the blocking query.

**Fix options**
1. Identify and kill the blocking session (see above query)
2. Increase `max worker threads` via `sp_configure` only as a temporary measure
3. Reduce connection pool size at the application layer to match actual concurrency needs

**Related checks:** E13

---

### E13 — Scheduler Non-Yielding

**What it means**
A thread has been running on a SQLOS scheduler for more than 60 seconds without yielding
(voluntarily relinquishing the scheduler for other threads to run). All other threads
assigned to that scheduler are blocked until the non-yielding thread yields or is terminated.
This is a critical operational event that often triggers AG health-check failures (E6) and
lease expiry (E2).

**How to spot it**
```
2026-01-15 14:30:11.88 spid5s     Process 0:0:0 (0xa1bc0) Worker 0x00000003F6DC0160 appears
to be non-yielding on Scheduler 3. Thread creation time: 13263...
A mini dump may be produced.
```

**Example (problem + fix)**

Problem — XTP (In-Memory OLTP) garbage collection thread non-yielding under heavy delete load:
```
14:30:11  Process appears to be non-yielding on Scheduler 3
14:31:58  AG1 exceeded health-check timeout (E6)
14:32:05  Lease between AG1 and WSFC expired (E2)
```

Fix — check for a minidump file in the SQL Server Log directory; engage Microsoft Support
with the dump if the pattern is reproducible. As interim fix, add the index supporting the
deletes to reduce garbage collection load.

**Fix options**
1. Look for an `.mdmp` or `.dmp` file in the Log directory at the same timestamp
2. Check for a known bug in the current build (E28 version check) that matches this pattern
3. Run `DBCC TRACEON(8086, -1)` (with Microsoft guidance) to capture extended diagnostic info

**Related checks:** E2, E6, E28

---

### E14 — Memory Grant Timeout

**What it means**
A query requested a memory grant for sort or hash operations, waited in the
`RESOURCE_SEMAPHORE` queue for the configured timeout (25 seconds by default), and timed
out. The query may have been retried with a reduced grant (causing a TempDb spill) or
killed entirely with error 8645.

**How to spot it**
```
2026-01-15 11:47:33.02 spid91s    Memory grant request timed out after waiting 25 seconds.
The query will not be executed. Query id = 34502, workspace memory request = 512000 KB.
```

**Example (problem + fix)**

Problem — stale statistics causing the optimizer to request 512 MB for a query that needs 12 MB:
```sql
-- After updating statistics, the grant drops from 512 MB to 12 MB
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
-- Re-run the query: grant is now accurate, no timeout
```

**Fix options**
1. Update statistics on tables accessed by the affected query: `UPDATE STATISTICS [table] WITH FULLSCAN`
2. Run `/sqlplan-review` on the query to identify N21 (row estimate errors) causing the oversize grant
3. Set `min memory per query` lower via Resource Governor to allow more concurrent grants to fit

**Related checks:** E9, E11

---

## Category 3 — I/O and Storage (E15–E19)

### E15 — I/O Subsystem Slow

**What it means**
SQL Server detected that one or more pending I/O operations (reads or writes to data or log
files) took longer than 15 seconds. This threshold is hard-coded in SQL Server and cannot be
changed. I/O requests taking this long stall the threads waiting for those pages and, critically,
can prevent the sp_server_diagnostics thread from completing, triggering E2 (lease expiry).

**How to spot it**
```
2026-01-15 14:28:44.02 spid5s     SQL Server has encountered 1 occurrence(s) of I/O requests
taking longer than 15 seconds to complete on file [E:\Data\AG1_Primary.mdf] in database
[AG1_Primary] (database ID 7). The OS file handle is 0x000000000000016C.
The offset of the latest long I/O is: 0x000003a00000.
```

**Example (problem + fix)**

Problem — VM IOPS cap reached during a backup job running concurrently with OLTP:
```
14:28:44  I/O requests taking longer than 15 seconds on E:\Data\AG1_Primary.mdf
14:32:05  Lease between AG1 and WSFC expired
```

Fix — schedule the backup job to run during off-peak hours; increase VM IOPS allocation;
move data and backup volumes to separate storage controllers.

**Fix options**
1. Identify the concurrent backup or maintenance job and reschedule to off-peak hours
2. Move data files to storage with guaranteed lower latency (NVMe vs SAN HDD)
3. For VMs: increase IOPS allocation or move to Premium SSD/Ultra Disk
4. Run `/sqlwait-review` to confirm `PAGEIOLATCH_SH` is the dominant wait type

**Related checks:** E2, E6, E16

---

### E16 — Database Corruption Warning

**What it means**
SQL Server detected that a data page on disk does not match its expected state — either the
checksum on the page header does not match the page contents (torn write), or a database
consistency check (DBCC CHECKDB) found allocation or structural errors. Data corruption can
result in wrong query results, query failures, or database inaccessibility.

**How to spot it**
```
2026-01-15 15:03:44.77 spid88s    Error: 824, Severity: 24, State: 2.
SQL Server detected a logical consistency-based I/O error: incorrect checksum (expected:
0x3a1f44b2; actual: 0x00000000). It occurred during a read of page (1:77392) in database
ID 7 at offset 0x25D20000 in file 'E:\Data\AG1_Primary.mdf'.
```

**Example (problem + fix)**

Problem — torn write caused by storage controller failure:
```
15:03:44  Error 824: incorrect checksum on page (1:77392) in database ID 7
15:03:44  Data movement for 'SalesDB' on AG1 has been suspended (E5)
```

Fix sequence:
1. Do not bring the database offline yet — run DBCC CHECKDB in REPAIR_REBUILD mode first
2. Verify most recent backup is intact: `RESTORE VERIFYONLY FROM DISK = N'path\backup.bak'`
3. If backup is valid, restore; if not, engage Microsoft Support

**Fix options**
1. Run `DBCC CHECKDB ([database]) WITH NO_INFOMSGS` to assess corruption scope
2. Restore from the most recent verified backup if corruption is widespread
3. Investigate storage hardware: disk S.M.A.R.T. data, RAID controller cache battery status

**Related checks:** E7, E15

---

### E17 — TempDB Space Exhaustion

**What it means**
SQL Server could not allocate space in tempdb for an operation (sort, hash join, spool, row
versioning under RCSI/snapshot isolation). All queries requiring tempdb space on that instance
will fail with error 1105 until space is freed or a file is added.

**How to spot it**
```
2026-01-15 16:12:03.55 spid112s   Could not allocate space for object 'dbo.sort_worktable'
in database 'tempdb' because the 'PRIMARY' filegroup is full. Create disk space by deleting
unneeded files, dropping objects in the filegroup, adding additional files to the filegroup,
or setting autogrowth on for existing files in the filegroup.
```

**Example (problem + fix)**

Problem — a 200 GB sort operation during a monthly report exhausted 80 GB tempdb:
```sql
-- Find top tempdb consumers
SELECT session_id, user_objects_alloc_page_count, internal_objects_alloc_page_count
FROM sys.dm_db_session_space_usage
ORDER BY (user_objects_alloc_page_count + internal_objects_alloc_page_count) DESC;
```

Fix — kill the large sort query; add a covering index to eliminate the sort; expand tempdb:
```sql
-- Add a tempdb data file (one per logical CPU core, up to 8)
ALTER DATABASE [tempdb] ADD FILE (NAME = N'tempdev2',
    FILENAME = N'D:\tempdb\tempdev2.ndf', SIZE = 20480MB, FILEGROWTH = 0);
```

**Fix options**
1. Identify the session consuming space (query above) and kill if runaway
2. Add additional tempdb data files (one per logical core, up to 8)
3. Pre-size tempdb data files at startup to avoid autogrow during business hours

**Related checks:** E19

---

### E18 — Log Backup Overdue

**What it means**
For a database in FULL or BULK_LOGGED recovery model, the transaction log cannot be
truncated (its space reused) until a log backup is taken. If log backups are not occurring
on schedule, the transaction log will grow indefinitely, eventually filling the disk or
hitting the configured maximum file size. The ERRORLOG typically shows backup completion
entries — the absence of these entries is the signal.

**How to spot it**

Look for the presence of log backup entries in the log:
```
2026-01-14 22:00:01.03 Backup      Database backed up: Database: SalesDB, creation date ...
```

The absence of such entries for > 24 hours for a FULL recovery database is the trigger.
Also check:
```sql
SELECT name, log_reuse_wait_desc, log_size_mb = size * 8.0 / 1024,
       log_used_pct = FILEPROPERTY(name, 'SpaceUsed') * 8.0 / 1024
FROM sys.databases
WHERE log_reuse_wait_desc = 'LOG_BACKUP';
```

**Example (problem + fix)**

Problem — SQL Agent job running log backups was disabled after a server migration and not
re-enabled; transaction log grew from 2 GB to 47 GB over 3 days.

Fix — run an immediate log backup and re-enable the job:
```sql
BACKUP LOG [SalesDB] TO DISK = N'\\backup\SalesDB_log_recovery.bak' WITH COMPRESSION;
-- Re-enable the Agent job
EXEC msdb.dbo.sp_update_job @job_name = N'Transaction Log Backup - SalesDB', @enabled = 1;
```

**Fix options**
1. Take an immediate log backup to allow log truncation
2. Verify the Agent backup job schedule and that the job is enabled and not failing silently
3. Set up an alert on `ERRORLOG` backup entries to detect future lapses

**Related checks:** E19

---

### E19 — VLF Proliferation Signal

**What it means**
Virtual Log Files (VLFs) are internal segments of the transaction log. Each autogrow event
creates new VLFs. Thousands of VLFs degrade log-backup performance, transaction log restore
time, and database recovery time after a crash. This check fires when the ERRORLOG shows
repeated autogrow events on log files, indicating the log was not sized adequately for the
workload.

**How to spot it**
```
2026-01-15 08:12:44.01 spid44s    Autogrow of file 'SalesDB_log' in database 'SalesDB'
took 2345 milliseconds. Consider using ALTER DATABASE to set a fixed file size.
2026-01-15 09:45:01.77 spid78s    Autogrow of file 'SalesDB_log' in database 'SalesDB'
took 1923 milliseconds.
```

Check current VLF count:
```sql
DBCC LOGINFO([SalesDB]);  -- count the rows; > 1000 VLFs is problematic
```

**Example (problem + fix)**

Problem — log file started at 256 MB with 64 MB autogrow; after 6 months = 2,048 VLFs.

Fix — shrink and re-expand in one step to consolidate VLFs:
```sql
USE [SalesDB];
BACKUP LOG [SalesDB] TO DISK = N'NUL';  -- truncate log first
DBCC SHRINKFILE (SalesDB_log, 1);       -- shrink to minimum
-- Expand to expected working size in one operation (minimizes VLF count)
ALTER DATABASE [SalesDB] MODIFY FILE (NAME = N'SalesDB_log', SIZE = 20480MB);
```

**Fix options**
1. Size the log file at startup to cover the workload's maximum expected size
2. Disable autogrow on log files — if it autogrows, the pre-sizing was wrong
3. Schedule regular `BACKUP LOG` to keep log utilization below 50% so fewer autogrows occur

**Related checks:** E18

---

## Category 4 — Startup, Shutdown, and Connectivity (E20–E24)

### E20 — Abnormal Shutdown

**What it means**
SQL Server terminated unexpectedly — without receiving a normal shutdown request from the
OS (service stop, controlled restart). Causes include: Windows BSOD or forced restart, SQL
Server internal error triggering a self-dump and shutdown, out-of-memory kill by the OS, or
a hardware power event. Each abnormal shutdown triggers crash recovery on the next startup,
which can take seconds to minutes depending on the active transaction log volume.

**How to spot it**

Look for the absence of a clean shutdown message at the end of a prior ERRORLOG file:
```
-- Clean shutdown ends with:
2026-01-14 22:00:05  spid5s       SQL Server termination has been requested by
                                   'service shutdown request'.
-- Abnormal shutdown: ERRORLOG simply ends, or the next startup begins immediately
2026-01-15 14:33:01  spid5s       SQL Server is starting at normal priority base (=7)...
```

**Example (problem + fix)**

Problem — Windows forced a restart due to a critical kernel update at 02:00; SQL Server
was not in a maintenance window:

Fix — schedule SQL Server restarts within maintenance windows using the SQL Server Agent
or a pre/post-maintenance script. Configure Windows Update to defer restarts or notify
rather than restart automatically.

**Fix options**
1. Check Windows Event Log (`System` source) for the restart reason at the same timestamp
2. Look for a `.mdmp` file in the SQL Server Log directory indicating an internal crash dump
3. Review AG and database recovery state after the restart — check for E4 or E5

**Related checks:** E21

---

### E21 — Repeated Restarts

**What it means**
Two or more SQL Server startup messages appear within 60 minutes, indicating the instance is
crashing and restarting repeatedly. This is a critical operational state — on each restart,
all plan cache is lost, connections are dropped, and AG replicas must re-synchronize.
Applications experience repeated connection failures.

**How to spot it**
```
2026-01-15 14:33:01  spid5s     SQL Server is starting at normal priority base ...
2026-01-15 14:33:02  spid5s     This instance of SQL Server last reported using a process ID
                                 of 4821 at 2026-01-15 14:30:18 (local) ...
2026-01-15 14:45:11  spid5s     SQL Server is starting at normal priority base ...   ← 2nd restart
```

**Example (problem + fix)**

Problem — SQL Server crashing due to corrupt `master` database tempdb entry:
```
14:33:01  SQL Server is starting
14:44:55  Error 17120: SQL Server could not spawn FRunCM thread
14:45:11  SQL Server is starting  ← crash-loop
```

Fix — start SQL Server in single-user mode (`-m` startup parameter) and repair or restore
the master database.

**Fix options**
1. Check E20 entries between the two startups for the crash cause
2. Start SQL Server in minimal configuration mode (`-f`) to bypass startup errors
3. If crashing during startup, check Windows Event Log for the service failure reason

**Related checks:** E20

---

### E22 — Login Failure Burst

**What it means**
A high volume of authentication failures within a short window. This can indicate: a
misconfigured application after a password change (many connection pool attempts failing),
a brute-force attack from an external source, or a stale credential in a scheduled task.

**How to spot it**
```
2026-01-15 15:04:02.01 Logon      Error: 18456, Severity: 14, State: 8.
2026-01-15 15:04:02.03 Logon      Login failed for user 'sa'. Client: 203.0.113.44
2026-01-15 15:04:02.05 Logon      Login failed for user 'sa'. Client: 203.0.113.44
... (repeated 47 times in 30 seconds)
```

**Example (problem + fix)**

Problem — brute-force attack on `sa` account from external IP:
Fix — block the source IP at the firewall immediately; disable the `sa` login if not needed;
enable SQL Server Audit:
```sql
ALTER LOGIN [sa] DISABLE;  -- sa should not be used in production
-- Enable failed login auditing (requires SQL Server restart to take full effect)
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel', REG_DWORD, 2;  -- 2 = failed logins
```

**Fix options**
1. For external attacks: block at the network layer (firewall, NSG) immediately
2. For application misconfiguration: identify the app server by IP and update connection strings
3. Enable SQL Server Audit on Failed Logins to create a persistent audit trail

**Related checks:** E24

---

### E23 — Linked Server Error

**What it means**
SQL Server attempted to use an OLE DB provider to connect to a linked server and the
connection or query failed. This affects distributed queries, cross-server stored procedures,
and any T-SQL code using four-part names (`[server].[db].[schema].[table]`).

**How to spot it**
```
2026-01-15 16:22:14.33 spid88s    OLE DB provider "SQLNCLI11" for linked server "ReportServer"
returned message "Login timeout expired".
```

**Example (problem + fix)**

Problem — linked server credential expired after a service account password rotation:
```sql
-- Test connectivity
EXEC sp_testlinkedserver N'ReportServer';

-- Update credentials if using a specific login
EXEC sp_dropserver N'ReportServer', 'droplogins';
EXEC sp_addlinkedserver @server = N'ReportServer', @srvproduct = N'', @provider = N'SQLNCLI11',
     @datasrc = N'ReportServer\INST01';
EXEC sp_addlinkedsrvlogin @rmtsrvname = N'ReportServer', @useself = 0,
     @rmtuser = N'svc_linked', @rmtpassword = N'<new_password>';
```

**Fix options**
1. Test connectivity: `EXEC sp_testlinkedserver [linked_server_name]`
2. Update credentials if a password rotation is the cause (see above)
3. If target server is unreachable, verify network connectivity and firewall rules

**Related checks:** E24

---

### E24 — Connectivity Error

**What it means**
SQL Server logged an error from a network connection — either an outbound connection it
initiated (linked server, replication, mail, SSIS) or an incoming connection that was
established at the TCP level but failed during the login protocol (TLS handshake, SSPI
authentication, or database access check).

**How to spot it**
```
2026-01-15 17:01:22.88 spid5s     A connection was successfully established with the server,
but then an error occurred during the pre-login handshake.
(provider: SSL Provider, error: 0 - The certificate chain was issued by an authority that
is not trusted.)
```

**Example (problem + fix)**

Problem — TLS certificate expired on the SQL Server, causing all encrypted connections to fail:
```
17:01:22  Error during pre-login handshake: certificate chain authority not trusted
17:01:22  Error during pre-login handshake: certificate chain authority not trusted
... (repeated for all connection attempts)
```

Fix — renew the SQL Server TLS certificate in the SQL Server Configuration Manager and
restart the SQL Server service.

**Fix options**
1. For certificate errors: renew or replace the certificate in SQL Server Configuration Manager
2. For SSPI errors: check if the SQL Server service account's SPN is registered correctly
3. For `A network-related error` (not pre-login): check firewall rules and network path health

**Related checks:** E22

---

## Category 5 — Configuration and Informational (E25–E28)

### E25 — Trace Flag Active

**What it means**
One or more SQL Server trace flags are enabled at startup, changing engine behavior. Trace
flags are often added to work around specific bugs in a given build and should be reviewed
after each CU upgrade to determine if they are still needed.

**How to spot it**
```
2026-01-15 14:33:01  spid5s     Trace flag 3226 is set. This is an informational message.
2026-01-15 14:33:01  spid5s     Trace flag 4199 is set. This is an informational message.
```

List all active trace flags:
```sql
DBCC TRACESTATUS(-1);
```

**Example (problem + fix)**

Problem — trace flag 1117 enabled on SQL Server 2019 (where it is the default behavior):

Fix — remove the trace flag to reduce startup complexity:
```sql
DBCC TRACEOFF(1117, -1);
-- To make permanent: remove -T1117 from SQL Server startup parameters in Configuration Manager
```

**Fix options**
1. Document the intent of each active trace flag
2. Verify each trace flag is still needed for the current SQL Server version
3. Remove trace flags that address behavior already fixed in the current build (E28)

**Related checks:** E28

---

### E26 — Max Server Memory Default

**What it means**
SQL Server's `max server memory` configuration is set to 2,147,483,647 MB — the default
value that means "no limit." With this setting, SQL Server will grow its buffer pool to
consume virtually all available RAM, leaving no headroom for the OS, which can trigger
Windows to page SQL Server memory out (E10).

**How to spot it**
```sql
-- Check current setting
SELECT name, value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)';
-- If value_in_use = 2147483647, the setting has never been configured
```

Or at startup in the ERRORLOG:
```
-- No explicit max server memory message at startup = default (unlimited) is in use
```

**Example (problem + fix)**

Problem — 128 GB server with default max memory; OS has only 400 MB free; Windows pages
SQL Server buffer pool pages to disk.

Fix:
```sql
-- For a 128 GB server: leave 8 GB for OS (10% rule), cap at 118 GB
EXEC sp_configure 'max server memory (MB)', 120832;
RECONFIGURE;
```

**Fix options**
1. Rule of thumb: set `max server memory` = (Total RAM) - max(10% RAM, 4 GB) for OS headroom
2. Additional reductions needed for: SSIS, SSRS, SSAS, or other services on the same host
3. Check `sys.dm_os_sys_info` columns `physical_memory_in_use_kb` and `available_physical_memory_kb`
   to size the reduction accurately

**Related checks:** E9, E10

---

### E27 — ERRORLOG Rotation Gap

**What it means**
Only one ERRORLOG file was provided, covering a window shorter than 24 hours. SQL Server
rotates the ERRORLOG on each restart and can be configured to retain up to 99 prior files
(default 6). When analysis is limited to a single recent file, any events before the current
log file — including the original startup, earlier failovers, or the sequence of events
leading to an incident — are not visible.

**How to spot it**
If the provided log starts close to the current time and covers only hours, prior context is missing.

```sql
-- Retrieve earlier log files
EXEC xp_readerrorlog 1, 1;  -- previous
EXEC xp_readerrorlog 2, 1;  -- the one before that
EXEC xp_readerrorlog 3, 1;  -- etc., up to 6 by default
```

**Example (problem + fix)**

Problem — analysis requested at 15:00; current ERRORLOG only covers 14:30–15:00 because the
instance restarted at 14:33 and is now on a fresh log. The incident that caused the restart
is in ERRORLOG.1.

Fix — retrieve ERRORLOG.1:
```sql
EXEC xp_readerrorlog 1, 1;
```

**Fix options**
1. Retrieve prior ERRORLOG files using `xp_readerrorlog` (parameter 0 = current, 1 = previous)
2. Increase the number of retained logs: SSMS → Server Properties → General → Number of error
   log files (or `sp_cycle_errorlog` retention setting)
3. Consider shipping ERRORLOG to a central log aggregator (Elastic, Splunk, Azure Monitor)
   to ensure historical coverage

**Related checks:** E20, E21

---

### E28 — SQL Server Version

**What it means**
Every ERRORLOG file begins with a line identifying the SQL Server major version, build
number, and edition. This information is used to: determine whether the instance is running
on a supported build, check if known bugs in that build are relevant to the observed issues,
and identify whether a CU upgrade would resolve non-yielding scheduler or memory allocation
bugs.

**How to spot it**
```
2026-01-15 14:33:01  spid5s     Microsoft SQL Server 2019 (RTM-CU25) (KB5033688) -
                                 15.0.4345.5 (X64) Dec  1 2023 17:20:28 Copyright (C)
                                 Microsoft Corporation Enterprise Edition (64-bit)
                                 on Windows Server 2022 Standard 10.0 (Build 20348:)
```

**Example (problem + fix)**

Problem — SQL Server 2019 RTM (15.0.2000) without any CUs applied:
The RTM build has numerous known bugs fixed in subsequent CUs. Any non-yielding scheduler
or memory issues should be cross-referenced against the CU changelog.

Fix — apply the latest CU for the major version:
```
-- Check current CUs at: https://sqlserverbuilds.blogspot.com/
-- As of 2026-01: SQL 2019 CU29 (15.0.4415.2) is current
-- Apply via standard SQL Server patch process
```

**Fix options**
1. Compare the build number against the CU changelog for that major version
2. If past end-of-support, plan upgrade to a supported version
3. If a non-yielding scheduler or memory bug is present, check whether a specific CU fixes it

**Related checks:** E13, E25

---

## Quick Reference

| ID | Name | Category | Severity |
|----|------|----------|----------|
| E1 | AG Failover Event | AG/HA | Warning / Critical |
| E2 | Lease Expiry | AG/HA | Critical |
| E3 | Replica State Change | AG/HA | Warning |
| E4 | AG Database Joining Failure | AG/HA | Critical |
| E5 | Data Synchronisation Suspended | AG/HA | Warning |
| E6 | AG Health Check Timeout | AG/HA | Critical |
| E7 | Redo Thread Error | AG/HA | Critical |
| E8 | Secondary Not Synchronising | AG/HA | Warning |
| E9 | FAIL_PAGE_ALLOCATION | Memory | Critical |
| E10 | OS Memory Pressure | Memory | Critical |
| E11 | Buffer Pool Insufficient | Memory | Critical |
| E12 | Worker Thread Exhaustion | Memory | Critical |
| E13 | Scheduler Non-Yielding | Memory | Critical |
| E14 | Memory Grant Timeout | Memory | Warning |
| E15 | I/O Subsystem Slow | I/O | Critical |
| E16 | Database Corruption Warning | I/O | Critical |
| E17 | TempDB Space Exhaustion | I/O | Critical |
| E18 | Log Backup Overdue | I/O | Warning |
| E19 | VLF Proliferation Signal | I/O | Info |
| E20 | Abnormal Shutdown | Startup | Critical |
| E21 | Repeated Restarts | Startup | Critical |
| E22 | Login Failure Burst | Connectivity | Warning / Critical |
| E23 | Linked Server Error | Connectivity | Warning |
| E24 | Connectivity Error | Connectivity | Warning |
| E25 | Trace Flag Active | Config | Info |
| E26 | Max Server Memory Default | Config | Info |
| E27 | ERRORLOG Rotation Gap | Config | Info |
| E28 | SQL Server Version | Config | Info |
