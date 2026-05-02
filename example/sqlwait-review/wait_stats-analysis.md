# Wait Statistics Analysis — `wait_stats.txt`

> **Input:** `example/sqlwait-review/wait_stats.txt`
> Run with: `/sqlwait-review example/sqlwait-review/wait_stats.txt`
>
> Server: PROD-SQL-01 · SQL Server 2019 CU23 · 16 cores / 128 GB RAM
> Capture window: 30-minute differential (2025-05-02 10:00–10:30)

---

## Input Summary

- Source: `sys.dm_os_wait_stats` 30-minute differential snapshot
- Capture window: 30-minute differential — 2025-05-02 10:00 to 10:30
- Wait types captured: 19 (benign idle waits excluded by capture query)
- Total actionable wait time: **20,363,780 ms**
- In context: 20,363,780 ms ÷ 1,800,000 ms (30-minute window) ≈ **11.3 sessions blocked on average** throughout the period. A ratio of 11× means the server was heavily congested — for every 1 minute of clock time, 11 session-minutes of work were blocked waiting.
- Signal wait ratio: **7.5%** — below the 15% warning threshold. CPU is not yet saturated despite the heavy load; the bottleneck is I/O and locks, not processor availability.

---

## Server Configuration Context

| Setting | Value | Affects | Interpretation |
|---------|-------|---------|---------------|
| MAXDOP | 0 (all 16 cores) | V3 | High CXPACKET is expected and partly by design — but with CTPfP at default 5, too many medium-cost queries also go parallel unnecessarily |
| Cost Threshold for Parallelism | 5 (default) | V3 | Far too low for a 16-core server; any query costing > 5 units gets a parallel plan. Raise to 50 to eliminate unnecessary parallelism without touching MAXDOP |
| RCSI enabled | No | V2 | Reader sessions take shared locks that block writers and vice versa. Enabling RCSI is the single highest-leverage fix for LCK_M_S and most reader/writer lock conflicts |
| TempDB data files | 2 (of 8 recommended for 16 cores) | V9 | All TempDB allocation flows through 2 PFS/GAM pages instead of 8 — add 6 files immediately |
| Recovery model | FULL | V16 | Log space freed by log backup — take one immediately if LOGMGR_RESERVE_APPEND fires |
| Delayed Durability | DISABLED | V5 | Every COMMIT flushes log synchronously. Consider DELAYED_DURABILITY = ALLOWED for non-critical workloads if WRITELOG worsens |
| Always On commit mode | Synchronous (same-datacenter secondary) | V12 | Every COMMIT waits for secondary to acknowledge log hardening. Secondary storage and network latency add directly to primary commit time |
| Max Server Memory (MB) | 122,880 (120 GB of 128 GB) | V4 | Memory is correctly bounded — 6 GB reserved for OS. RESOURCE_SEMAPHORE waits are from over-estimated grants (stale statistics), not a total RAM shortage |

---

## Top Wait Types (V17)

| Rank | Wait Type | Category | Waiting Tasks | Total Wait ms | % of Total | Max Wait ms | Signal ms |
|------|-----------|----------|--------------|--------------|------------|------------|-----------|
| 1 | PAGEIOLATCH_SH | I/O | 312,480 | 9,842,100 | **48.3%** | 6,840 | 184,200 |
| 2 | LCK_M_IX | Locks | 18,420 | 4,210,500 | **20.7%** | 284,906 | 28,100 |
| 3 | CXPACKET | Parallelism | 248,100 | 2,184,200 | **10.7%** | 12,100 | 840,500 |
| 4 | RESOURCE_SEMAPHORE | Memory | 8,420 | 1,040,200 | **5.1%** | 42,100 | 4,200 |
| 5 | WRITELOG | Log | 1,204,180 | 682,400 | 3.4% | 2,100 | 64,210 |

### Dominant Bottleneck

This server has **three concurrent bottlenecks requiring immediate action**: physical I/O pressure (48.3% PAGEIOLATCH), severe lock contention on `LCK_M_IX` (20.7%, max 284 seconds), and two emergency-level poison waits (`IO_RETRY` and `LOGMGR_RESERVE_APPEND`). The I/O and locking problems likely share a root cause — full table scans holding shared locks across thousands of pages.

---

## Performance Findings

### Critical Issues

**[C1] Hardware I/O Failure — IO_RETRY Present** (V18 — Poison Wait)
- Observed: `IO_RETRY` — 420 waiting tasks, 28,420 ms total, max single wait **14,200 ms**
- **User impact:** Users experienced up to 14-second unexplained delays on queries reading from disk — indistinguishable from a slow query at the application layer. Depending on retry count, some operations may have surfaced SQL Server errors 823/824/825.
- Impact: I/O retries indicate hardware or driver errors on the storage subsystem. Each retry adds up to 14 seconds of latency per page. Data integrity risk escalates if retries are exhausting. This is the most urgent finding — storage faults must be ruled out before tuning anything else.
- Fix:
  1. **Immediately** check Windows System Event Log and SQL Server error log: `EXEC xp_readerrorlog 0, 1, N'I/O error'; EXEC xp_readerrorlog 0, 1, N'retrying';`
  2. Check storage health: disk diagnostics, RAID/SAN error counters, controller event logs
  3. If cloud storage: check for throttled or degraded volumes
  4. Escalate to the infrastructure team — do not defer this finding

**[C2] Log Space Exhaustion — LOGMGR_RESERVE_APPEND Present** (V16 — Critical)
- Observed: `LOGMGR_RESERVE_APPEND` — 84 waiting tasks, 18,420 ms total, max **4,200 ms**
- **User impact:** Every INSERT, UPDATE, and DELETE during this period was stalled waiting for log space. Users experienced write timeouts or unexplained write failures. Read-only queries were unaffected.
- Impact: The transaction log is full or nearly full and cannot release space for reuse. All write activity blocks until space is freed.
- Fix:
  1. **Immediately** check log space: `DBCC SQLPERF('LOGSPACE');`
  2. Find the log reuse blocker: `SELECT log_reuse_wait_desc FROM sys.databases WHERE name = 'ProdDB';`
  3. **Configuration note (Recovery model = FULL):** Log space is freed by log backup — take one immediately: `BACKUP LOG ProdDB TO DISK = 'path\log_emergency.bak' WITH COMPRESSION;`
  4. If `log_reuse_wait_desc = 'ACTIVE_TRANSACTION'` — a long-running transaction is holding the log open: `SELECT * FROM sys.dm_tran_active_transactions ORDER BY transaction_begin_time;`
  5. Pre-size the log file after resolution to prevent recurrence

**[C3] Intent Exclusive Lock Waits — LCK_M_IX Dominant** (V2 — Critical)
- Observed: `LCK_M_IX` — 18,420 waiting tasks, 4,210,500 ms (20.7%), max single wait **284,906 ms (4 minutes 44 seconds)**
- **User impact:** At least some users waited nearly 5 minutes for a lock that normally resolves in milliseconds. For users in the blocking chain this appeared as a hung application or an explicit timeout error.
- Impact: Intent Exclusive locks are acquired when escalating from row-level to table-level locks, or during schema modification conflicts. The 284-second max wait means a head blocker held a lock for nearly 5 minutes — every session queued behind it experienced the full duration.
- Fix:
  1. Capture the blocking chain: `SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time/1000.0 AS wait_sec, s.open_transaction_count FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id WHERE r.blocking_session_id > 0 OR r.wait_type LIKE 'LCK%';`
  2. **Configuration note (RCSI = OFF):** Enabling RCSI eliminates all reader-caused `LCK_M_S` and shared-lock conflicts in a single command — this is the highest-leverage fix: `ALTER DATABASE ProdDB SET READ_COMMITTED_SNAPSHOT ON;`
  3. Add indexes on WHERE clause columns to reduce scan-based lock scope (shorter scan = fewer pages locked = shorter lock hold time)
  4. `LCK_M_RX_X` is also present (W4) confirming SERIALIZABLE isolation is in use for some sessions — those require explicit `SET TRANSACTION ISOLATION LEVEL SNAPSHOT` after enabling snapshot isolation

**[C4] Physical I/O Dominant — PAGEIOLATCH 49.2% Combined** (V1 — Critical)
- Observed: `PAGEIOLATCH_SH` 48.3% + `PAGEIOLATCH_EX` 0.9% = **49.2%** of all wait time. 312,480 tasks waiting on reads. Max 6,840 ms per page.
- **User impact:** Nearly half of all user-visible query latency was the server waiting for disk reads. A query that should run in 50 ms could take 2–7 seconds because the pages it needs are not in memory and must be fetched from disk.
- Impact: The working set exceeds buffer pool capacity, or queries are performing full scans that force large sequential reads. Combined with C1 (IO_RETRY), the storage subsystem is under severe dual stress.
- Fix:
  1. **Root cause is inefficient queries, not storage** — identify the heaviest-read queries: run `/sqlstats-review` on `SET STATISTICS IO, TIME ON` output; look for tables with scan count > 1 and hundreds of thousands of reads per execution
  2. Run `/sqlplan-index-advisor` on execution plans to generate covering indexes — missing indexes are the primary driver of unnecessary reads
  3. After index tuning, if PAGEIOLATCH remains above 20%: check buffer pool pressure via `sys.dm_os_buffer_descriptors`; RAM expansion is a valid secondary fix
  4. Resolve C1 (IO_RETRY) in parallel — index tuning does not fix hardware failures

**[C5] Memory Grant Queue — RESOURCE_SEMAPHORE 5.1%** (V4 — Critical)
- Observed: `RESOURCE_SEMAPHORE` 5.1%, max **42,100 ms** (42 seconds queuing before execution begins). `RESOURCE_SEMAPHORE_QUERY_COMPILE` also present (0.4%).
- **User impact:** Some queries waited up to 42 seconds just to *start* executing. From the user's perspective the query was "running" but doing nothing — the application appeared frozen before the first result arrived.
- Impact: Stale statistics cause the optimizer to overestimate row counts → oversized memory grants → few concurrent grants available → all other queries queue. At 5.1% this is at the Critical threshold.
- Fix:
  1. Update statistics: `UPDATE STATISTICS dbo.HeavyTable WITH FULLSCAN;`
  2. Run `/sqlplan-review` on memory-intensive plans; check S2, S3, S4 for oversized grants
  3. Add indexes to reduce sort/hash input sizes — smaller inputs = smaller grants needed
  4. **Configuration note (Max Server Memory = 122,880 MB — correctly bounded):** The issue is grant sizing from stale statistics, not total RAM shortage. Updating statistics is the fix.
  5. For RESOURCE_SEMAPHORE_QUERY_COMPILE: `EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;`

---

### Warnings

**[W1] Non-Page Latch Contention — LATCH_EX 2.1%** (V15)
- Observed: `LATCH_EX` 2.1%, 84,210 tasks, max 1,840 ms
- **User impact:** Brief (~2 ms average) stalls on internal SQL Server structure access. Individually invisible to users; cumulative throughput reduction of 2.1% is measurable.
- Impact: The specific internal structure contended cannot be determined from `sys.dm_os_wait_stats` alone. Given the context (2 TempDB files, high parallelism, high DML), the most likely candidates are `ACCESS_METHODS_SCAN_RANGE_GENERATOR` (parallel scan range allocation) or `LOG_MANAGER` (log growth events).
- Fix:
  1. Identify the latch class: `SELECT TOP 10 latch_class, wait_time_ms, waiting_requests_count FROM sys.dm_os_latch_stats WHERE latch_class NOT IN ('BUFFER') ORDER BY wait_time_ms DESC;`
  2. If `ACCESS_METHODS_*` — resolves as a side effect of adding indexes (C4) which eliminates parallel scans
  3. If `LOG_MANAGER` — pre-size the log to eliminate autogrow (C2 fix)
  4. If `FGCB_ADD_REMOVE` — pre-size data files to eliminate data file autogrow

**[W2] Parallelism — CXPACKET 10.7%** (V3)
- Observed: `CXPACKET` 10.7% + `CXCONSUMER` 1.4% = **12.1% combined**. Max CXPACKET 12,100 ms.
- **User impact:** Parallel queries consume more CPU threads than necessary, reducing concurrency for other queries. Users see slower response times across the board, not just for the queries running in parallel.
- Impact: CXPACKET is not inherently a problem on a 16-core server. However, with CTPfP at default 5, medium-cost queries go parallel unnecessarily. The high CXPACKET combined with PAGEIOLATCH strongly suggests parallel scans are driving both issues simultaneously.
- Fix:
  1. Do not reduce MAXDOP — investigate first
  2. **Configuration note (MAXDOP = 0, CTPfP = 5):** Raising CTPfP to 50 is the first action: `EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;` — this eliminates unnecessary parallelism on medium-cost queries without any MAXDOP change
  3. Adding covering indexes (C4 fix) eliminates the parallel scans driving both CXPACKET and PAGEIOLATCH simultaneously

**[W3] Transaction Log I/O — WRITELOG 3.4%** (V5)
- Observed: `WRITELOG` 3.4%, **1,204,180 tasks** (highest task count in the capture), max 2,100 ms
- **User impact:** Each application COMMIT required a synchronous log flush. The 2.1-second max flush latency means users on those transactions experienced a 2-second delay before their COMMIT returned to the application.
- Impact: High task count with moderate per-wait time indicates many small transactions committing frequently. The elevated max suggests the log file is competing with data file I/O — confirmed by C1 (IO_RETRY). The synchronous AG secondary adds ack latency to every commit.
- Fix:
  1. Move the transaction log to dedicated storage, separate from data files
  2. Resolve C1 — hardware errors directly increase log flush latency
  3. **Configuration note (Delayed Durability = DISABLED):** Consider `ALTER DATABASE ProdDB SET DELAYED_DURABILITY = ALLOWED` for non-critical workloads — but note the synchronous AG secondary still requires per-commit acks regardless of primary delayed durability setting

**[W4] Serializable Range Lock — LCK_M_RX_X Present** (V2 — Serializable variant)
- Observed: `LCK_M_RX_X` — 840 tasks, 4,200 ms, 0.0% of total
- **User impact:** Sessions using SERIALIZABLE isolation hold range locks that block other readers and writers even on non-overlapping key ranges. RCSI (C3 fix) cannot help these sessions.
- Impact: Range Exclusive locks confirm SERIALIZABLE isolation is active for some sessions. Enabling RCSI resolves most lock contention but does not help SERIALIZABLE sessions.
- Fix: `ALTER DATABASE ProdDB SET ALLOW_SNAPSHOT_ISOLATION ON;` — then switch affected sessions to `SET TRANSACTION ISOLATION LEVEL SNAPSHOT;`

**[W5] TempDB Allocation Contention — PAGELATCH_EX 0.7%** (V9)
- Observed: `PAGELATCH_EX` 0.7%, 120,480 tasks, max 420 ms
- **User impact:** Brief stalls when creating or dropping temporary objects. Each temp table creation during high-concurrency periods adds ~1 ms average delay — multiplied across 120K tasks this is a meaningful throughput loss.
- Impact: With only 2 TempDB data files on a 16-core server, all temp object creation contends for 2 PFS/GAM allocation pages. High parallelism makes this worse.
- Fix:
  1. **Configuration note (TempDB files = 2, target = 8):** Add 6 TempDB data files — all must be equal size: `ALTER DATABASE tempdb ADD FILE (NAME=tempdev3, FILENAME='D:\TempDB\tempdev3.mdf', SIZE=4096MB, FILEGROWTH=512MB);` — repeat for tempdev4 through tempdev8
  2. Verify equal file sizes after adding — unequal sizes defeat proportional fill and re-centralise contention on the largest file

**[W6] HA Synchronization — HADR_SYNC_COMMIT 0.2%** (V12)
- Observed: `HADR_SYNC_COMMIT` 0.2%, 84,210 tasks, max **840 ms**
- **User impact:** Every COMMIT on the primary waited for the secondary to acknowledge. The 840 ms max means some commits added nearly 1 second of invisible latency before returning to the application.
- Impact: Synchronous-commit secondary on the same datacenter. The 840 ms occasional peak suggests the secondary's storage or network stalls occasionally — possibly also affected by the same storage issues as C1.
- Fix:
  1. Check secondary replica health: `SELECT database_name, log_send_queue_size, redo_queue_size, redo_rate FROM sys.dm_hadr_database_replica_states WHERE is_local = 0;`
  2. **Configuration note (commit mode = Synchronous):** HADR_SYNC_COMMIT waits at this level are expected for a synchronous secondary — 840 ms max is elevated but not catastrophic. If the secondary's `redo_queue_size` is large and growing, the secondary storage needs upgrading.

---

### Info

**[I1] OLEDB Present — Monitoring Tool Pattern** (V11)
- Observed: `OLEDB` 0.2%, 42,100 tasks, max 18,420 ms
- Impact: 42,100 tasks at 48,210 ms total = avg **1.1 ms per wait** — the millisecond-level, high-frequency OLEDB signature of monitoring tools polling DMVs. The 18.4-second max is an outlier (possibly a linked server call during peak contention).
- **User impact:** Negligible — monitoring tool overhead. No action required.

**[I2] SOS_SCHEDULER_YIELD 1.2%** (V7)
- Observed: `SOS_SCHEDULER_YIELD` 1.2%, signal_wait_ms 218,400 (88% of its own wait is signal wait)
- Impact: At 1.2% this does not reach the V7 threshold of 15%. The high signal proportion (88%) confirms CPU is contended for runnable threads, but the overall signal ratio of 7.5% shows this is localised. Most likely source: parallel scan threads burning CPU quanta on in-memory page scans.
- **User impact:** Minimal independently; resolves as a side effect of the index additions in C4.

**[I3] ASYNC_NETWORK_IO 0.6%** (V6)
- Observed: `ASYNC_NETWORK_IO` 0.6% — below the 20% investigative threshold
- Impact: SQL Server has results ready but the client is consuming them slowly. At 0.6% this is not a concern. Monitor if this rises above 10% after resolving I/O and lock issues.
- **User impact:** None currently.

**[I4] PAGEIOLATCH Approaching Single-Type Dominance** (V14)
- Observed: PAGEIOLATCH combined = 49.2% — approaching the 60% single-type dominance threshold but not reached (LCK_M_IX at 20.7% keeps this a multi-bottleneck server)
- Impact: Both PAGEIOLATCH and LCK_M must be addressed. The index additions (C4) address both simultaneously: better indexes → fewer scans → fewer pages locked → shorter LCK_M hold times.

---

### Passed Checks
V6 ✓ (ASYNC_NETWORK_IO 0.6% < 20%), V8 ✓ (THREADPOOL absent), V10 ✓ (signal ratio 7.5% < 15%), V13 ✓ (PREEMPTIVE_OS_AUTHENTICATIONOPS 0% < 10%)

---

## Recommended Action Order

| Priority | Action | Checks resolved | Effort |
|----------|--------|----------------|--------|
| 1 — Immediately | Check Windows event log and SQL error log for IO_RETRY hardware errors | C1 | 30 min |
| 2 — Immediately | Take a log backup: `BACKUP LOG ProdDB TO DISK = '...' WITH COMPRESSION` | C2 | 5 min |
| 3 — Today | Enable RCSI: `ALTER DATABASE ProdDB SET READ_COMMITTED_SNAPSHOT ON` | C3, W4 | 5 min (requires brief exclusive access) |
| 4 — Today | Add TempDB data files 3–8 (all equal size, 4 GB each) | W5 | 15 min |
| 5 — Today | Raise CTPfP from 5 to 50: `EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE` | W2 | 5 min |
| 6 — This sprint | Add covering indexes on heaviest-read tables (`/sqlstats-review` + `/sqlplan-index-advisor`) | C1, C4, W2, W1 | Days |
| 7 — This sprint | Update statistics with FULLSCAN on heavy tables | C5 | Hours |
| 8 — Next sprint | Move transaction log to dedicated storage | W3, W6 | Infrastructure |

**Root cause summary:** Three independent problems are occurring simultaneously — (1) a storage hardware problem (`IO_RETRY`) compounding I/O pressure from missing indexes; (2) a log space exhaustion crisis (`LOGMGR_RESERVE_APPEND`); and (3) pervasive lock contention from missing RCSI and missing indexes. The index additions in step 6 are the highest-leverage structural fix — they simultaneously reduce PAGEIOLATCH (C4), reduce LCK_M scope (C3), shrink RESOURCE_SEMAPHORE grants (C5), and eliminate parallel scans driving CXPACKET (W2). Resolve the two emergencies first, then apply the quick configuration wins while the index work is under way.
