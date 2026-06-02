# SQL Server Wait Statistics Checks — Explained for All

## Contents

- [Before You Start: Key Concepts](#before-you-start-key-concepts)
- [Wait Statistics Checks (V1–V44)](#wait-statistics-checks-v1v44)
- [Trend Analysis Checks (V19–V26)](#trend-analysis-checks-v19v26)
- [Operational Checks (V27–V29)](#operational-checks-v27v29)
- [Modern Feature Checks (V30–V36)](#modern-feature-checks-v30v36)
- [Quick Reference: Checks by Category](#quick-reference-checks-by-category)

---


A detailed guide to every check the analyser applies to `sys.dm_os_wait_stats` and `sys.dm_exec_requests` output.

---

## Before You Start: Key Concepts

### What are wait statistics?

When SQL Server cannot immediately continue executing a thread — because it needs a page from disk, a lock held by another session, CPU time, or memory — the thread enters a **wait state**. SQL Server records each wait in `sys.dm_os_wait_stats`, accumulating the counts and durations since the last restart.

The **Waits and Queues** methodology (pioneered by Microsoft's SQL Server team) treats wait statistics as the primary diagnostic signal: find the biggest waits, understand their root cause, fix it.

### The three wait time components

| Column | What it measures |
|--------|----------------|
| `wait_time_ms` | Total time threads spent waiting (the primary metric) |
| `signal_wait_time_ms` | Time waiting for CPU *after* the original resource was available — pure CPU saturation |
| `waiting_tasks_count` | How many times threads waited — frequency, not duration |

A high `max_wait_time_ms` with low `waiting_tasks_count` suggests infrequent but severe single waits (e.g., a nightly backup). High `waiting_tasks_count` with moderate `wait_time_ms` suggests a frequent, moderate bottleneck.

### Signal wait ratio

```
signal_wait_ratio = signal_wait_time_ms / wait_time_ms × 100
```

This ratio across all wait types is a **CPU pressure indicator**. If > 25%, threads are frequently ready to run but cannot get CPU — the server is CPU-saturated regardless of which wait type is dominant.

### Benign vs actionable waits

Many wait types are normal background activity and should be excluded before analysis: `SLEEP_TASK`, `WAITFOR`, `LAZYWRITER_SLEEP`, `CHECKPOINT_QUEUE`, `XE_DISPATCHER_WAIT`, etc. The capture query in `SKILL.md` excludes them. If the input includes them, skip them during analysis.

### Point-in-time vs cumulative

`sys.dm_os_wait_stats` is **cumulative since last restart or CLEAR**. A high `WRITELOG` value might reflect a bulk import that ran once two weeks ago, not a current problem. `sys.dm_exec_requests` shows **current active waits only** — a point-in-time snapshot. Both have value; interpret them accordingly.

---

## Wait Statistics Checks (V1–V44)

---

### V1 — Physical I/O Wait (PAGEIOLATCH)

**What it means**
`PAGEIOLATCH_SH` (shared — read), `PAGEIOLATCH_EX` (exclusive — write), and `PAGEIOLATCH_UP` (update) occur when a thread needs a database page that is not in the buffer pool and must wait for it to be read from disk. This is the direct measure of physical I/O latency from SQL Server's perspective.

**Why it matters**
Physical I/O is 100–1,000× slower than memory access. Even modern SSDs take 50–200 µs per read; spinning disk can take 5–15 ms. A server spending 60% of its wait time on PAGEIOLATCH is spending most of its time waiting for disk — all query parallelism and optimization is wasted while threads sit idle.

**How to spot it**
```
wait_type           waiting_tasks  wait_time_ms   pct_total
PAGEIOLATCH_SH      48,291         2,568,900      62.4%
PAGEIOLATCH_EX      1,204          84,210         2.0%
```
Combined 64.4% → Critical (≥ 40% threshold)

**Fix options (ranked by impact)**
1. **Add indexes** — the primary driver of PAGEIOLATCH is table/index scans reading large numbers of pages. A covering index reduces 48,000 pages to 3. Use `/sqlplan-index-advisor` on the worst plans.
2. **Add RAM** — more buffer pool = more pages cached = fewer physical reads. Use `sys.dm_os_buffer_descriptors` to find what's consuming buffer pool.
3. **Faster storage** — move data files to NVMe (0.1 ms latency vs 5 ms for SATA SSD). Especially effective when RAM-based fixes aren't feasible.
4. **Partition hot tables** — if one table dominates buffer pool, partition it so only the hot partition stays in cache.

**Related checks:** V10 (signal wait ratio — if CPU is also a bottleneck), V4 (RESOURCE_SEMAPHORE — if memory is also contended)

---

### V2 — Lock Waits (LCK_M)

**What it means**
`LCK_M_S` (shared), `LCK_M_X` (exclusive), `LCK_M_U` (update), `LCK_M_IS`, `LCK_M_IX`, etc. — a session is waiting for a lock held by another session. Unlike deadlocks (mutual lock cycles), this is one-directional blocking: session A holds a lock session B needs.

**Why it matters**
Lock waits cause cascading delays. If session A holds a table lock for 30 seconds, every session needing that table queues behind it. Response times go from milliseconds to tens of seconds. If the head blocker is a long-running transaction, thousands of users can be affected simultaneously.

**How to spot it**
```
wait_type    waiting_tasks  wait_time_ms  pct_total
LCK_M_S      8,420          842,100       18.2%
LCK_M_X      1,204          248,000       5.4%
```
Combined 23.6% → Critical (≥ 20% threshold; triggered at ≥ 1% minimum)

**Example — common cause**
```sql
-- Session A: long-running transaction holds X lock on Orders
BEGIN TRANSACTION;
UPDATE dbo.Orders SET Status = 'Processing' WHERE CustomerId = 42;
-- (session does network call or long computation)
-- Session B, C, D ... all queue behind this X lock
```

**Fix options (ranked by impact)**
1. **Add indexes on filter columns** — a full table scan (`WHERE Status = 'Processing'` with no index on Status) holds shared locks on every scanned row/page. An index seek holds locks only on matching rows — dramatically reducing lock scope and duration.
2. **Enable READ_COMMITTED_SNAPSHOT (RCSI)** — eliminates reader/writer conflicts. Readers take no shared locks; they read from the version store instead. `ALTER DATABASE YourDb SET READ_COMMITTED_SNAPSHOT ON` — requires brief exclusive access.
3. **Shorten transactions** — COMMIT faster, do less work per transaction. Don't hold transactions open during network calls or user interaction.
4. **Use `/sqlblock-review`** — paste `sys.dm_exec_requests` to identify the head blocker (session with no `blocking_session_id`) and its running query.

**Related checks:** `/sqlplan-deadlock` (if LCK includes deadlock patterns), `/sqlblock-review`

---

### V3 — Parallelism (CXPACKET / CXCONSUMER / HT*)

**What it means**
`CXPACKET` records the control thread waiting for parallel worker threads to finish their portion of a parallel query. `CXCONSUMER` (SQL Server 2016 SP2 CU3+) records consumer threads waiting for data from producer threads — this is the more benign component of parallelism waits. `HTBUILD`, `HTDELETE`, `HTMEMO`, `HTREINIT`, and `HTREPARTITION` are **batch-mode hash build/repartition waits** — they appear on queries using batch mode execution (columnstore indexes, batch mode on rowstore SQL 2019+) and represent threads synchronizing at hash build or repartition phases. Treat HT* the same as CXPACKET: investigate skew before adjusting MAXDOP.

**Critical misconception to avoid**
The most common mistake DBA teams make with CXPACKET is reducing MAXDOP reflexively. The SQL Server team and the broader community explicitly warn against this. CXPACKET is *expected* for parallel queries — it does not indicate a problem by itself. The question to ask is: **is the work evenly distributed across threads?** If yes, CXPACKET is fine. If one thread does 90% of the work while others wait, *that* is the problem.

**CXCONSUMER (SQL 2016 SP2 CU3+)**
CXCONSUMER was introduced to separate the benign consumer-side wait from CXPACKET. After this split, CXPACKET became more actionable — it now specifically represents producer thread waits. CXCONSUMER is generally ignorable.

**Why it matters**
When CXPACKET genuinely indicates a problem: (1) Too many queries go parallel because Cost Threshold for Parallelism is too low (default 5 is designed for 1990s hardware — try 25–50); (2) Data skew causes uneven work distribution across threads.

**How to spot it**
```
wait_type      waiting_tasks  wait_time_ms  pct_total
CXPACKET       84,210         4,210,500     45.2%
CXCONSUMER     48,100         1,840,200     19.7%
```
CXPACKET 45.2% → investigate (but do not reduce MAXDOP yet)

**Diagnosis — distinguish normal from problematic**
```sql
-- Find queries with high CXPACKET waits (use sys.dm_exec_requests, NOT dm_os_waiting_tasks)
SELECT r.session_id, r.wait_type, r.wait_time, r.status,
       t.text AS sql_text, r.query_hash
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.wait_type IN ('CXPACKET','CXCONSUMER')
ORDER BY r.wait_time DESC;
```

**Fix options (ranked by impact)**
1. **Raise Cost Threshold for Parallelism to 25–50** — reduces unnecessary parallelism on medium-cost queries: `EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE`.
2. **Update statistics** — data skew from stale statistics causes uneven thread distribution.
3. **Investigate specific queries** — capture execution plans with `/sqlplan-review`, check N30 (Parallel Thread Skew). Fix the skewed query rather than server-wide MAXDOP.
4. **Reduce MAXDOP only after confirming** parallelism is hurting — not as the first response.

**Related checks:** V7 (SOS_SCHEDULER_YIELD), V10 (signal wait ratio), `/sqlconfig-review`

---

### V4 — Memory Grant Queue (RESOURCE_SEMAPHORE / RESOURCE_SEMAPHORE_QUERY_COMPILE)

**What it means**
Before a query can execute its Sort or Hash Match operators, SQL Server reserves memory (a "grant") from the memory broker. If insufficient memory is available, the query waits on `RESOURCE_SEMAPHORE` until a grant is available. These waits happen *before* a single row is processed — the query is stuck at the starting gate.

`RESOURCE_SEMAPHORE_QUERY_COMPILE` is a separate wait for **compile memory** — a smaller pool used exclusively during query plan compilation. Unlike runtime grants (which scale with row estimates), compile memory pressure is driven by plan complexity and compilation concurrency, not data volume.

**Why it matters**
A `RESOURCE_SEMAPHORE` queue means queries are serialized waiting for runtime memory. Under concurrency, 10 queries each requesting 1 GB grants queue behind each other. Response time degrades proportionally to queue length. Often co-occurs with V1 (the same queries requesting large grants are also causing I/O via scan-heavy plans).

`RESOURCE_SEMAPHORE_QUERY_COMPILE` means the compile memory pool is exhausted — SQL Server cannot compile new plans for arriving queries. This is independent of data size: a query joining 50 views each referencing 10 tables uses disproportionate compile memory even with zero rows.

**How to spot it**
```
wait_type                        waiting_tasks  wait_time_ms  pct_total
RESOURCE_SEMAPHORE               4,210          820,000       8.2%
RESOURCE_SEMAPHORE_QUERY_COMPILE 1,840          184,200       1.8%
```
Any RESOURCE_SEMAPHORE → Warning; 8.2% → Critical (≥ 5% threshold). RESOURCE_SEMAPHORE_QUERY_COMPILE at 1.8% → Warning (≥ 0.5%); approaching Critical at ≥ 2%.

**Distinguishing runtime vs compile pressure**
- **High RESOURCE_SEMAPHORE + low RESOURCE_SEMAPHORE_QUERY_COMPILE** → runtime bottleneck — large sorts/hashes with overestimated grants. Stale statistics are the primary suspect.
- **High RESOURCE_SEMAPHORE_QUERY_COMPILE + low RESOURCE_SEMAPHORE** → compile bottleneck — too many complex plans being compiled concurrently. Enable "optimize for ad hoc workloads."
- **Both high** → general memory pressure — address runtime first (larger pool), then compile.

**Root cause trace**
Runtime: The root cause is almost always stale statistics: SQL Server estimates 100 rows → plans a Hash Match needing 1 GB memory grant. Actually 10 million rows arrive → the 1 GB is used, Sort spills, and the next query queues for another 1 GB grant. Use `/sqlplan-review` checks S2, S3, S4 on the plans of memory-intensive queries.

Compile: Deeply nested views, queries referencing hundreds of tables, very long IN lists, or stored procedures with dozens of branches each compiling a separate plan consume disproportionate compile memory. Enable `sp_configure 'optimize for ad hoc workloads', 1` — this prevents storing a full compiled plan for single-use ad-hoc queries, dramatically reducing compile memory pressure.

**Fix options (ranked by impact)**

*For RESOURCE_SEMAPHORE (runtime):*
1. **Update statistics** — `UPDATE STATISTICS dbo.HeavyTable WITH FULLSCAN` — accurate row estimates → correct grant sizes → no queue.
2. **Add indexes** — eliminate scans that drive sort/hash operations. Fewer input rows = smaller grants needed.
3. **OPTION (MIN_GRANT_PERCENT = n)** — caps a query's maximum grant. Use on known heavy queries.
4. **Resource Governor** — limit the memory grant per workload group. Prevents any single group from monopolizing grant memory.
5. **Add RAM** — more memory = larger grant pool = less queuing. Address root cause first.

*For RESOURCE_SEMAPHORE_QUERY_COMPILE (compile):*
1. **Enable optimize for ad hoc workloads** — highest-leverage fix. `sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE`.
2. **Simplify complex queries** — break deeply nested views into temp tables; avoid queries referencing > 100 objects.
3. **OPTION (KEEPFIXED PLAN)** — suppresses recompilation from statistics changes on stable queries.
4. **Use sp_executesql with parameters** — allows plan reuse across executions, reducing compile frequency.

**Related checks:** V1 (PAGEIOLATCH often co-occurs with runtime RESOURCE_SEMAPHORE), `/sqlplan-review` S2 S3 S4

---

### V5 — Transaction Log I/O (WRITELOG)

**What it means**
Every `COMMIT` in SQL Server triggers a synchronous write to the transaction log file — SQL Server does not return control to the application until the log is hardened to disk. `WRITELOG` is the wait for that log write to complete.

**Why it matters**
High WRITELOG directly extends transaction duration. If committing takes 50 ms instead of 1 ms, throughput for commit-bound OLTP workloads drops 50×. Everything blocked by those transactions also waits longer, amplifying LCK_M waits.

**How to spot it**
```
wait_type  waiting_tasks  wait_time_ms  pct_total
WRITELOG   182,140        1,820,000     22.1%
```
22.1% → Critical (≥ 30% = Critical; but already significant at 22%)

**Fix options (ranked by impact)**
1. **Move log file to dedicated fast storage** — transaction log is write-intensive and sequential. A dedicated NVMe with low write latency (< 0.2 ms) eliminates most WRITELOG waits.
2. **Separate log from data files** — if log and data share the same volume, I/O competes. Separate them onto different disks.
3. **Batch commits** — if the application commits after every row insert, batch 100–1,000 rows per transaction instead. Amortizes the log flush cost.
4. **Delayed Durability** (SQL Server 2014+) — for workloads where occasional data loss on crash is acceptable (e.g., telemetry, staging): `ALTER DATABASE YourDb SET DELAYED_DURABILITY = FORCED`. Log flushes are batched, not per-commit.
5. **Check for long-running transactions** — a single long transaction generates large log growth; the commit flush of that large log entry dominates WRITELOG.

**Related checks:** V2 (LCK_M — long transactions holding locks amplify both)

---

### V6 — Client Result Consumption (ASYNC_NETWORK_IO)

**What it means**
`ASYNC_NETWORK_IO` occurs when SQL Server has query results ready in its output buffer but the client application is not consuming them fast enough. SQL Server is waiting for the application to acknowledge the data and ask for more.

**Critical point**
`ASYNC_NETWORK_IO` is never indicative of a problem with SQL Server. This is an application-side bottleneck, always. Do not tune SQL Server queries or indexes to fix this wait. Do not flag it as a SQL Server performance problem. The investigation must focus on the client application and network.

**Why it appears in the top waits**
On busy systems with many concurrent queries, even small per-query ASYNC_NETWORK_IO accumulates to a large total. It can appear in the top 5 without indicating any actionable SQL Server issue.

**How to spot it**
```
wait_type          waiting_tasks  wait_time_ms  pct_total
ASYNC_NETWORK_IO   48,291         4,210,500     52.1%
```
52.1% → this means the application is slow, not SQL Server.

**Root causes (all client-side)**
- Application processes each row with business logic before reading the next (RBAR — row-by-row processing)
- Application buffers the entire result set into memory before processing (DataTable.Fill pattern)
- Network congestion or high latency between SQL Server and application
- VM host oversubscription on the application server
- MARS (Multiple Active Result Sets) with large concurrent result sets

**Fix options**
1. **Fix the application** — stream results row by row rather than buffering. In .NET: `SqlDataReader` (streaming) instead of `DataTable.Fill()` (buffering).
2. **Reduce result set size** — return only necessary columns and rows. Each extra column increases transfer volume.
3. **Add `SET NOCOUNT ON`** — suppresses "N rows affected" TDS messages after each DML, reducing round-trips.
4. **Pagination** — `OFFSET/FETCH` instead of fetching millions of rows then filtering in the application.
5. **Network** — investigate latency and bandwidth between app server and SQL Server.

**Related checks:** none — investigate client application and network, not SQL Server

---

### V7 — Scheduler Yield (SOS_SCHEDULER_YIELD)

**What it means**
SQL Server uses cooperative scheduling — threads voluntarily yield the CPU after a 4 ms quantum. `SOS_SCHEDULER_YIELD` fires when a thread completes its quantum and yields. This is normal behavior; high accumulated wait time here means threads are burning through many quanta, not that they are blocked.

**Two common misconceptions**

**Misconception 1: SOS_SCHEDULER_YIELD means CPU pressure.**
Not necessarily. The most common cause is queries doing large in-memory page scans — for example, a missing index forcing a full table scan that repeatedly accesses buffer pool pages. The thread stays RUNNABLE (never suspends) and burns through quantum after quantum scanning in-memory pages. Add the missing index and the wait disappears — no CPU was actually the bottleneck.

**Misconception 2: SOS_SCHEDULER_YIELD is caused by LOCK_HASH spinlock contention.**
Incorrect. Threads backing off from spinlock collisions use Windows `Sleep()` — they do not show up in wait statistics at all. High SOS_SCHEDULER_YIELD and high LOCK_HASH spinlock contention are independent problems that can coexist but are not causally related. Investigate spinlocks separately via `sys.dm_os_spinlock_stats`.

**Virtual machine inflation**
On a VM, the clock counter SQL Server uses to measure quantum duration includes time the hypervisor spent scheduling other VMs. If the VM host is oversubscribed, SOS_SCHEDULER_YIELD appears inflated even when SQL Server workload is light. Always ask: *is this server virtualized?*

**How to spot it**
```
wait_type              waiting_tasks  wait_time_ms  pct_total
SOS_SCHEDULER_YIELD    248,100        1,840,200     18.4%
```

**Diagnosis**
Use `sys.dm_exec_requests` (not `sys.dm_os_waiting_tasks` — these threads are RUNNABLE, not SUSPENDED):
```sql
SELECT r.session_id, r.status, r.cpu_time, r.total_elapsed_time,
       t.text AS sql_text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.status = 'runnable'
ORDER BY r.cpu_time DESC;
```

**Fix options**
1. **Add indexes to eliminate in-memory scans** — the most common cause. A query scanning a million buffer pool pages burns quanta continuously.
2. **Check VM host oversubscription** — if virtualized, confirm the host is not oversubscribed before assuming a SQL Server problem.
3. **Identify spinlock contention separately** — `SELECT TOP 10 * FROM sys.dm_os_spinlock_stats ORDER BY spins DESC` — this is a separate investigation.
4. **Add CPU if genuinely saturated** — only after eliminating inefficient queries as the root cause.

**Related checks:** V3 (CXPACKET), V10 (signal wait ratio)

---

### V8 — Thread Pool Exhaustion (THREADPOOL)

**What it means**
SQL Server has a finite pool of worker threads. When all threads are busy, new connection requests queue on `THREADPOOL` waiting for a thread to become available. No new queries can start executing.

**Why it matters**
This is one of the most severe conditions — the server is completely unresponsive to new requests. Users see timeouts and connection failures regardless of whether the server has CPU or memory available.

**How to spot it**
```
wait_type    waiting_tasks  wait_time_ms  pct_total
THREADPOOL   8,420          420,500       5.1%
```
Any presence → Critical.

**Common causes**
- Many long-running or blocked sessions consuming threads
- Many parallel queries, each consuming multiple threads (32 threads × MAXDOP 8 = 4 queries fill the pool)
- Application creating too many connections (no connection pool, or pool set too large)
- Worker thread max set too low for the workload

**Fix options (ranked by immediate impact)**
1. **Kill blocking head blockers** — if blocking chains are consuming threads, resolving them frees threads immediately.
2. **Reduce MAXDOP** — parallel queries consume multiple threads. Reducing MAXDOP from 8 to 4 doubles the number of parallel queries the thread pool can support.
3. **Enable connection pooling in the application** — applications that open a new connection per request exhaust the thread pool quickly.
4. **Increase `max worker threads`** — `sp_configure 'max worker threads', 1024` — but this is a band-aid; investigate root cause.

**Related checks:** V2 (LCK_M — blocking chains), V3 (CXPACKET — parallel threads)

---

### V9 — TempDB Allocation Contention (PAGELATCH)

**What it means**
TempDB maintains special allocation pages (PFS at page 1, GAM at page 2, SGAM at page 3 of each 64 MB extent) that track which pages are in use. When many sessions simultaneously create or drop temp objects, they all contend for exclusive access to these same allocation pages via `PAGELATCH_EX` waits.

**Why it matters**
This is a global serialization point: only one session can modify a TempDB allocation page at a time. On busy OLTP servers with many concurrent temp table operations, this becomes a throughput bottleneck that scales with core count — more cores = more concurrent temp object creation = more contention.

**How to spot it**
```
wait_type     waiting_tasks  wait_time_ms  pct_total
PAGELATCH_EX  48,291         420,500       8.2%
```
Look for PAGELATCH on TempDB (database_id = 2) specifically.

**Fix options (ranked by impact)**
1. **Add TempDB data files** — one per logical CPU core (up to 8). SQL Server distributes allocation across files, so 8 files = 8 independent PFS/GAM pages = 8× less contention. `ALTER DATABASE tempdb ADD FILE (NAME=tempdev2, FILENAME='...tempdb2.mdf')`.
2. **Enable trace flag 1118** (SQL 2014 and earlier) — forces uniform extent allocation, reducing GAM page contention.
3. **SQL 2016+** — set `Mixed Page Allocation = 0` in TempDB properties (same effect as TF 1118, now a database-level setting).
4. **Use table variables for small sets** — table variables do not use TempDB allocation pages for small row counts (stored in memory).
5. **Reuse temp tables** — truncate instead of drop/recreate inside loops.

**Related checks:** V1 (PAGEIOLATCH — if TempDB is also on slow storage), `/sqlconfig-review` K4 (TempDB file count)

---

### V10 — Signal Wait Ratio (CPU Saturation Indicator)

**What it means**
The signal wait ratio is computed across all wait types:

```
ratio = SUM(signal_wait_time_ms) / SUM(wait_time_ms) × 100
```

Signal wait time = the time a thread waited for CPU *after its resource was released*. It had its lock, its page was in cache, its grant was approved — but no CPU was available to run it. This is pure CPU saturation.

**Why it matters**
A high signal wait ratio means CPU is the true bottleneck, even if the dominant wait type looks like something else. A server with 50% PAGEIOLATCH and 30% signal wait ratio has both an I/O problem and a CPU problem — fixing I/O alone will not fully resolve performance.

**How to spot it**
```
Total wait_time_ms:         4,200,000
Total signal_wait_time_ms:  1,260,000
Signal wait ratio:          30.0%  → Critical (≥ 25%)
```

**Fix options**
1. **Identify top CPU consumers** — high signal waits mean CPU-intensive queries. Use `/sqltrace-review` or Query Store top-by-CPU.
2. **Reduce CPU work** — add indexes to eliminate scans, reduce sort/hash operations.
3. **Reduce parallelism** — CXPACKET often co-occurs; each parallel thread competes for CPU.
4. **Add CPU capacity** — if workload is legitimately CPU-bound after index optimization.

**Related checks:** V3 (CXPACKET), V7 (SOS_SCHEDULER_YIELD)

---

### V11 — Linked Server / Distributed Query (OLEDB)

**What it means**
`OLEDB` waits occur when SQL Server makes a call to an OLE DB provider — typically a linked server query — and waits for the remote server to respond.

**Why it matters**
Linked server queries are opaque to the local optimizer. They generate a `OLEDB` wait for the full duration of the remote call. If linked server queries are frequent or slow, this wait dominates and there is nothing the local server can do to speed it up.

**How to spot it**
```
wait_type  waiting_tasks  wait_time_ms  pct_total
OLEDB      4,210          420,500       9.1%
```

**Fix options**
1. **Replicate remote data locally** — the most effective fix. Query a local copy instead of reaching across the network.
2. **Use `OPENQUERY` with server-side filters** — push the WHERE clause to the remote server: `SELECT * FROM OPENQUERY([RemoteServer], 'SELECT col FROM db.dbo.table WHERE id = 42')`.
3. **Audit linked server usage** — identify which queries use linked servers with `/sqltrace-review`.
4. **Ensure dedicated network** — linked server traffic should use a low-latency, high-bandwidth path.

**Related checks:** `/tsql-review` T37 (linked server query)

---

### V12 — High Availability Synchronization (HADR / DBMIRROR)

**What it means**
`HADR_SYNC_COMMIT` and related waits occur on an Always On Availability Group primary replica that uses synchronous-commit mode. The primary cannot confirm a COMMIT until all synchronous secondaries have hardened the log record to their disk. This adds the secondary's log write latency to every commit on the primary. `HADR_SYNC_COMMIT` is the primary synchronous-commit latency signal — when this type dominates HADR waits, the bottleneck is the secondary's log I/O throughput or the network round-trip, not SQL Server itself. `PWAIT_HADR_*` waits are the preemptive variants of HADR waits (OS-level blocking calls in the HADR stack) and are treated identically.

**Why it matters**
In synchronous-commit mode, the primary's commit latency = max(primary log flush, secondary log flush + network RTT). If the secondary is on a slow disk or a distant network, every transaction on the primary is slowed by the replication lag.

**How to spot it**
```
wait_type          waiting_tasks  wait_time_ms  pct_total
HADR_SYNC_COMMIT   48,291         820,500       9.2%
```

**Fix options**
1. **Switch non-critical replicas to asynchronous commit** — async replicas do not block the primary commit. Accept the risk of data loss on failover.
2. **Improve secondary log I/O** — move secondary's log file to faster storage.
3. **Improve network** — reduce latency between primary and secondary (co-locate in same datacenter).
4. **Monitor with `sys.dm_hadr_database_replica_states`** — identify which secondary is lagging: `SELECT * FROM sys.dm_hadr_database_replica_states`.

**Related checks:** V5 (WRITELOG — primary log I/O also contributes)

---

### V13 — External / OS Calls (PREEMPTIVE Waits)

**What it means**
SQL Server normally uses cooperative scheduling — threads yield voluntarily. `PREEMPTIVE_*` waits occur when SQL Server must make a blocking OS call that bypasses cooperative scheduling: CLR code, extended stored procedures, COM objects, or Windows authentication. The thread is "preempted" by the OS.

**Why it matters**
Preemptive threads are invisible to SQL Server's scheduler — they block a scheduler slot without yielding it, reducing effective parallelism for other work. High preemptive waits indicate that non-SQL work is consuming significant server time inside SQL Server's process space.

**How to spot it**
```
wait_type                              wait_time_ms  pct_total
PREEMPTIVE_OS_PIPEOPS                  420,500       5.1%
PREEMPTIVE_XE_CALLBACKEXECUTE          84,200        1.0%
```

**Fix options**
1. **Identify the source** — use Extended Events to capture which queries trigger preemptive waits.
2. **Remove xp_cmdshell** — replace with SQL Server Agent jobs. `xp_cmdshell` is the most common source of `PREEMPTIVE_OS_*` waits.
3. **Move CLR to application layer** — CLR assemblies running inside SQL Server generate preemptive waits. Move complex logic to the application tier.
4. **Disable unused Extended Events sessions** — XE sessions add `PREEMPTIVE_XE_*` overhead.
5. **PREEMPTIVE_OS_WRITEFILEGATHERER + WRITELOG co-occurrence** — when both are prominent together, the root cause is usually frequent autogrowth events. Check: `SELECT * FROM sys.dm_os_performance_counters WHERE counter_name = 'Log Growths'` or query the default trace for autogrowth events. Fix: pre-size data and log files to avoid autogrowth during production, or set autogrowth to a large fixed increment rather than a percentage.

**Related checks:** `/tsql-review` T36 (xp_cmdshell), V5 (WRITELOG — frequent autogrowth co-occurrence)

---

### V14 — Single Wait Type Dominance

**What it means**
One wait type accounts for ≥ 60% of total wait time. The server has one overwhelming bottleneck rather than a diffuse mix.

**Why it matters**
This is actually good news: the root cause is clear. Fixing that one wait type will have the highest marginal impact on the server. Knowing which wait type dominates determines the investigation path.

**How to spot it**
```
wait_type       wait_time_ms  pct_total
PAGEIOLATCH_SH  5,120,000     72.4%   ← dominates
LCK_M_S         481,000       6.8%
CXPACKET        420,500       5.9%
```

**No fix for this check itself** — cross-reference the dominant wait type with its specific check (V1–V13) and focus all effort there before addressing secondary waits.

**Related checks:** all V1–V13 depending on which type dominates

---

### V15 — Non-Page Latch Contention (LATCH_EX / LATCH_SH)

**What it means**
`LATCH_EX` (exclusive) and `LATCH_SH` (shared) are non-page latches — they protect internal SQL Server data structures such as index trees, log manager state, parallel scan infrastructure, and file group control blocks. They are **distinct from `PAGELATCH_*`** (V9), which protects in-memory data pages.

**Why it matters**
Without knowing which specific latch class is contended, it is impossible to diagnose or fix. `sys.dm_os_wait_stats` tells you the wait type but not the latch class. Always follow up with `sys.dm_os_latch_stats`.

**How to identify the specific latch**
```sql
SELECT TOP 10
    latch_class,
    wait_time_ms,
    waiting_requests_count,
    max_wait_time_ms
FROM sys.dm_os_latch_stats
WHERE latch_class NOT IN ('BUFFER')
ORDER BY wait_time_ms DESC;
```

**Most common non-page latch classes and their fixes**

| Latch Class | Cause | Fix |
|-------------|-------|-----|
| `ACCESS_METHODS_DATASET_PARENT` | Parallel scan page range allocation | Usually pairs with CXPACKET — fix data skew |
| `ACCESS_METHODS_SCAN_RANGE_GENERATOR` | Parallel scan range generation | Same as above |
| `LOG_MANAGER` | Transaction log autogrowth contention | Pre-size the log file to avoid autogrowth |
| `TRACE_CONTROLLER` | SQL Trace (Profiler) enabled with high overhead | Switch to Extended Events; disable excess traces |
| `FGCB_ADD_REMOVE` | File group autogrowth | Pre-size data files; enable instant file initialization |
| `DATABASE_MIRRORING_CONNECTION` | Mirroring message throughput | Check network between primary and mirror |
| `ACCESS_METHODS_HOBT_VIRTUAL_ROOT` | Index root page access control | Heavy concurrent index access — consider partitioning |

**Related checks:** V9 (PAGELATCH — page-level latches, different problem)

---

### V16 — Log Space Exhaustion (LOGMGR_RESERVE_APPEND)

**What it means**
A thread needs to write a log record but no space is available in the transaction log file. The thread suspends and waits for log space to be freed (via checkpoint reuse in SIMPLE recovery, or log backup truncation in FULL/BULK_LOGGED recovery).

**Why it matters**
This is very unusual to see as a top wait type, and when it appears it indicates a serious configuration problem. All DML on the affected database blocks until log space is freed. This is a database-wide hang, not a single query problem.

**How to spot it**
```
wait_type                waiting_tasks  wait_time_ms  pct_total
LOGMGR_RESERVE_APPEND    4,210          820,500       8.2%
```
Any presence → Critical.

**Diagnosis**
```sql
-- Find log space usage and why space cannot be reused
SELECT name, log_size_mb = size * 8.0 / 1024,
       log_used_mb = FILEPROPERTY(name, 'SpaceUsed') * 8.0 / 1024,
       recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE database_id = DB_ID();  -- check log_reuse_wait_desc for the blocker

-- Check log space percent used
DBCC SQLPERF('LOGSPACE');
```

**Common `log_reuse_wait_desc` values and fixes**

| log_reuse_wait_desc | Meaning | Fix |
|--------------------|---------|-----|
| `ACTIVE_TRANSACTION` | Long-running open transaction | Find and commit/kill the long transaction |
| `LOG_BACKUP` | FULL recovery, no log backup taken | Take a log backup immediately; schedule regular log backups |
| `CHECKPOINT` | SIMPLE recovery, checkpoint not triggered | Checkpoint runs automatically; check for very large transactions |
| `NOTHING` | Log is available — transient | Autogrowth settings too small; increase log size |

**Fix options**
1. **FULL recovery without log backups:** Take a log backup immediately: `BACKUP LOG YourDb TO DISK = 'path\log.bak'`. Schedule regular log backups.
2. **SIMPLE recovery with stuck log:** Find the active transaction blocking checkpoint: `SELECT * FROM sys.dm_tran_active_transactions ORDER BY transaction_begin_time`.
3. **Autogrowth set to 0 or too small:** Increase log file size: `ALTER DATABASE YourDb MODIFY FILE (NAME=YourDb_log, SIZE=10240MB)`. Never set autogrowth to 0%.
4. **Pre-size the log:** Set the log file to its expected working size at provisioning time to avoid autogrowth during production.

**Related checks:** V5 (WRITELOG — log I/O throughput), V2 (LCK_M — blocking during the log-full period)

---

### V17 — Top Wait Types Summary

**What it means**
This check always fires and produces the ranked table of top wait types — the foundation for all other checks. It is the starting point of every wait analysis session.

**Why it matters**
The top-5 table immediately orients the analysis: is this server I/O bound, CPU bound, or lock bound? The percentages show relative priority — fix the biggest wedge first.

**No fix required** — this check is informational output that all other checks build on.

---

### V18 — Poison / Throttle Waits

**What it means**
A small set of wait types that, when present in non-trivial amounts, always indicate a severe problem. These are known as "poison waits" in the SQL Server community — unlike most wait types that exist on a spectrum of severity, these are almost always emergencies.

**Why it matters**
These waits indicate SQL Server is being actively throttled, experiencing I/O hardware failures, or a secondary replica is so far behind that the primary is being held back. Normal performance analysis tools often miss them because they don't appear in the top waits until the situation is severe.

**The poison wait types**

| Wait Type | What it means | Primary fix |
|-----------|--------------|-------------|
| `IO_QUEUE_LIMIT` | Storage queue full — I/O requests are piling up | Reduce I/O via indexes; upgrade storage |
| `IO_RETRY` | SQL Server I/O failed and is retrying | Check Windows Event Log; hardware/driver error |
| `RESMGR_THROTTLED` | Resource Governor CPU cap is actively throttling | Review Resource Governor pool MAX_CPU_PERCENT |
| `LOG_RATE_GOVERNOR` | Log generation rate throttled (SQL 2019+, Azure) | Reduce write volume; check service tier limits |
| `POOL_LOG_RATE_GOVERNOR` | Resource pool log rate throttled | Same as LOG_RATE_GOVERNOR |
| `INSTANCE_LOG_RATE_GOVERNOR` | Instance-level log rate throttled | Check secondary replica health |
| `HADR_THROTTLE_LOG_RATE_GOVERNOR` | AG secondary lagging → primary throttled | Check `sys.dm_hadr_database_replica_states` |
| `SE_REPL_CATCHUP_THROTTLE` | Primary slowed because secondary is catching up | Investigate secondary replica redo rate |
| `SE_REPL_COMMIT_ACK` | Waiting for synchronous secondary commit ack | Secondary I/O or network latency |
| `SE_REPL_SLOW_SECONDARY_THROTTLE` | Primary throttled due to slow secondary | Reduce redo lag or switch to async commit |

**Threshold**
Flag as Critical when: `SUM(wait_time_ms) > 60,000` AND `SUM(wait_time_ms) > (5000 × hours_since_startup)`. The proportional component prevents false alarms on freshly restarted servers.

**Azure SQL relevance**
`LOG_RATE_GOVERNOR` and `POOL_LOG_RATE_GOVERNOR` are especially common in Azure SQL, where each service tier enforces a maximum log generation rate (e.g., 25 MB/s on General Purpose). Applications that generate log faster than the tier allows are throttled here. Fix: reduce DML volume, upgrade the service tier, or batch writes.

**How to spot IO_RETRY**
```sql
-- Check for I/O errors in the SQL Server error log
EXEC xp_readerrorlog 0, 1, N'I/O error';
EXEC xp_readerrorlog 0, 1, N'retrying';
-- Also check Windows System Event Log for disk errors
```

**Related checks:** V1 (PAGEIOLATCH — related I/O pressure), V5 (WRITELOG — log I/O volume), V12 (HADR — secondary lag)

---

## Trend Analysis Checks (V19–V26)

These checks apply only when the input contains **3 or more distinct time windows** (2 for V20/V21/V23). They operate on the per-period delta series — the change in wait time between consecutive snapshots — not on cumulative totals.

---

### V19 — Trend Direction

**What it means**
Checks whether any wait type's share of total wait time (delta %) increases or decreases monotonically across ≥ 3 consecutive capture periods. A monotonically increasing wait type is actively getting worse with every measurement — not random noise, but a systematic deterioration.

**Why it matters**
A single snapshot tells you the current state. Trend direction tells you whether the problem started before the first snapshot and is still worsening, which determines urgency: a 30% PAGEIOLATCH that is stable is less urgent than a 20% PAGEIOLATCH that grows 5% every 15 minutes.

**How to spot it**
```
Period         PAGEIOLATCH_SH   LCK_M_IX   CXPACKET
10:00–10:15    48.3%            19.3%      10.7%
10:15–10:30    52.1%            14.0%      11.2%
10:30–10:45    58.7%            13.5%      10.9%
10:45–11:00    61.2%            12.1%      10.8%
```
PAGEIOLATCH_SH increases every period (↑↑ monotonic worsening). LCK_M_IX decreases every period (↓ improving — perhaps RCSI was enabled mid-capture). CXPACKET is stable.

**Fix options**
1. Identify what changed at or before the first snapshot — new query, increased concurrent users, job schedule change, growing table, fragmentation accumulating
2. Run V1–V18 on the most recent period for root cause analysis; the trend direction confirms the root cause is still active
3. If improving: confirm the fix applied is working; continue monitoring

**Related checks:** V20 (spikes within a trend), V22 (velocity — how fast it's worsening), V26 (overall pattern classification)

---

### V20 — Spike Detection

**What it means**
Identifies any single period where a wait type's delta % is ≥ 200% of that wait type's own average across all periods. A 2× spike is not noise — it is a discrete event that occurred within one capture window.

**Why it matters**
A spike in isolation (without trend context) is indistinguishable from noise in a single snapshot. Multi-snapshot analysis makes it visible: PAGEIOLATCH at 48% in every period except one period at 95% is a clear event, not a chronic problem. Treating it as a chronic problem leads to wrong remediation.

**How to spot it**
```
Period         PAGEIOLATCH_SH   % of avg
10:00–10:15    48.3%            1.0×
10:15–10:30    52.1%            1.1×
10:30–10:45    95.8%            2.0×  ← spike
10:45–11:00    49.2%            1.0×
```
PAGEIOLATCH_SH average = 61.4%; the 10:30–10:45 period is 95.8% = 1.56× average. Below 200% threshold in this example, but the spike is still visible. If it hit 123%, that would be 2× and trigger V20.

**Fix options**
1. Correlate the spike timestamp with SQL Agent job history, deployment events, application log entries, or database maintenance jobs (index rebuild, statistics update, DBCC)
2. Check for large ad-hoc queries: `SELECT TOP 10 ... FROM sys.dm_exec_query_stats ORDER BY total_logical_reads DESC` — did a new top reader appear?
3. Cross-reference V24 (Correlated Spikes) — if multiple wait types spiked in the same period, they share a root cause

**Related checks:** V24 (correlated spikes), V25 (did it resolve?), V21 (was this the peak period?)

---

### V21 — Peak Period Identification

**What it means**
Always fires when 2+ periods are present. Identifies the time window with the highest total accumulated wait (sum of all delta_wait_ms values across all wait types). This is the period where users experienced the worst conditions.

**Why it matters**
"The server was slow today" is not actionable. "The server was worst between 10:30 and 10:45 — 38% more total wait than the average period" is actionable. Knowing the exact window lets you correlate with monitoring alerts, user-reported tickets, and SQL Server logs.

**How to spot it**
```
Period         Total delta_wait_ms   vs avg
10:00–10:15    18,420,000 ms         −12%
10:15–10:30    20,840,000 ms         −1%
10:30–10:45    29,100,000 ms         +38%  ← peak
10:45–11:00    22,640,000 ms         +7%
```

**Fix options**
No fix required for this check — it is orientation. Use the peak period timestamp to:
1. Check SQL Server error log for errors during that window: `EXEC xp_readerrorlog 0, 1, NULL, NULL, '2025-05-02 10:30', '2025-05-02 10:45';`
2. Cross-reference with monitoring alerts and user-reported incidents

**Related checks:** V20 (was the peak caused by a spike?), V19 (was the peak the endpoint of a worsening trend?)

---

### V22 — Velocity Ranking

**What it means**
Always fires when 3+ periods are present. Ranks the top 3 wait types by their average rate of change (percentage points per period). A wait type at 20% growing 5 pp/period will reach 40% in 4 periods — it will overtake a static 30% wait type.

**Why it matters**
Velocity identifies the fastest-developing bottleneck, not just the current largest one. In a crisis it tells you which problem to fix first before it becomes dominant.

**How to spot it**
```
Wait Type          P1     P2     P3     P4     Avg Δ/period
PAGEIOLATCH_SH     48.3%  52.1%  58.7%  61.2%  +4.3 pp/period
RESOURCE_SEMAPHORE  5.1%   5.4%   5.8%   6.2%  +0.4 pp/period
CXPACKET           10.7%  11.2%  10.9%  10.8%  +0.03 pp/period (stable)
```

**Fix options**
No fix from this check alone — it is a ranking tool. Use velocity to prioritize: apply the V1–V18 fix for the highest-velocity wait type first.

**Related checks:** V19 (direction), V26 (pattern)

---

### V23 — Emerging Wait Types

**What it means**
A wait type that was < 0.5% in period 1 but reached ≥ 2.0% in any later period is classified as "emerging". This is a problem that developed mid-observation, not a pre-existing condition.

**Why it matters**
Pre-existing conditions and mid-incident developments require different responses. An emerging wait type often maps to a specific event: a new query started, a batch job began, a blocking session appeared, or a configuration change took effect.

**How to spot it**
```
Period         LOGMGR_RESERVE_APPEND
10:00–10:15    0.0% (absent)
10:15–10:30    0.1%
10:30–10:45    0.0%
10:45–11:00    2.4%  ← emerged — log space exhaustion developing
```

**Fix options**
1. Note the period when the wait type first crossed 2%
2. Correlate with external events at that time
3. Apply the corresponding V1–V18 fix (e.g., for LOGMGR_RESERVE_APPEND emerging: V16 — take a log backup immediately)

**Related checks:** V20 (did the emerging wait spike?), V16 (for LOGMGR_RESERVE_APPEND specifically)

---

### V24 — Correlated Spikes

**What it means**
Two or more wait types each spike (≥ 150% of their own average) in the same time period. Correlated spikes are strong evidence that the spiking wait types share a root cause.

**Why it matters**
Without correlation analysis, a DBA might address PAGEIOLATCH and RESOURCE_SEMAPHORE as two separate problems. Discovering that both spiked at the same time reveals they are symptoms of the same missing index: a large scan reads many pages (PAGEIOLATCH) and requests a large memory grant (RESOURCE_SEMAPHORE) in the same query.

**Common correlated pairs**

| Wait A | Wait B | Common root cause |
|--------|--------|-------------------|
| PAGEIOLATCH_SH | RESOURCE_SEMAPHORE | Missing index → large scan + large sort/hash memory grant |
| LCK_M_IX | SOS_SCHEDULER_YIELD | Long scan holding locks while burning CPU quanta |
| WRITELOG | HADR_SYNC_COMMIT | Log I/O pressure — secondary can't keep up with primary commit rate |
| CXPACKET | PAGEIOLATCH_SH | Parallel scan — multiple threads each doing I/O |
| RESOURCE_SEMAPHORE | SOS_SCHEDULER_YIELD | CPU-heavy query with oversized memory grant |

**Fix options**
1. Identify the common root cause from the pair above
2. Fix the primary wait type (higher absolute delta_wait_ms) — the correlated wait often resolves as a side effect
3. Cross-reference V1–V18 for the specific fix for each wait type

**Related checks:** V20 (spike detection), V25 (did the correlated spike resolve?)

---

### V25 — Transient Event Detection

**What it means**
A wait type that spiked (≥ 200% of own average in one period) AND returned to below its own average in a subsequent period. The spike was a discrete event, not an ongoing condition.

**Why it matters**
A transient spike that fully resolved requires a different response than an ongoing problem. Spending effort tuning a wait type that has already self-resolved may produce no measurable benefit. However, identifying the root cause of a transient event is still valuable — if it happened once, it will happen again.

**How to spot it**
```
Period         IO_RETRY   % of own avg
10:00–10:15    0 ms       —
10:15–10:30    0 ms       —
10:30–10:45    28,420 ms  ∞ (spike from baseline 0)
10:45–11:00    0 ms       ← resolved
```
IO_RETRY appeared in one period and resolved. A one-time I/O error (disk timeout, retry succeeded) rather than an ongoing hardware problem.

**Fix options**
1. Despite resolution, investigate the root cause — a single IO_RETRY means a disk operation failed at least once
2. Check SQL Server error log around the spike period for the specific error
3. If the spike was a scheduled job (WRITELOG spike during nightly backup), note it for the baseline

**Related checks:** V20 (spike detection), V23 (is it truly resolved or still emerging?)

---

### V26 — Pattern Classification

**What it means**
Always fires when 3+ periods are present. Produces a single-sentence classification of the overall server behavior pattern across the observation period, using standard pattern names.

**Why it matters**
A concise pattern name communicates the situation to stakeholders and guides the remediation approach. "Single spike then recovery" requires a different response than "consistently degrading."

**Standard patterns**

| Pattern | Signal | Implication |
|---------|--------|-------------|
| `Consistently degrading` | V19 worsening for dominant wait type | Ongoing problem getting worse — fix urgently |
| `Single spike then recovery` | V20 + V25 for same wait type | Discrete event — identify and prevent recurrence |
| `Steadily elevated` | All periods above historical baseline, no clear trend | Chronic problem at a fixed level — schedule fix |
| `Multi-spike` | V20 fires for 2+ non-overlapping periods | Recurring events — find the common trigger |
| `Improving` | V19 improving for dominant wait type | Fix in progress or workload dropped — confirm and monitor |
| `Multi-bottleneck worsening` | 2+ wait types both show V19 worsening | Multiple independent root causes — triage by velocity (V22) |
| `Stable` | No V19/V20 events; all waits within ±10% | No acute trend — use for baseline documentation |

**Fix options**
No fix from this check — it is a classification. Report the pattern and which wait type(s) drive it.

**Related checks:** V19 (direction), V20 (spikes), V22 (velocity), all V1–V18 for root causes

---

## Operational Checks (V27–V29)

These checks complement V1–V26 for both single-snapshot and trend mode.

---

### V27 — PAGELATCH on User Databases (Insert Hotspots / Page Splits)

**What it means**
`PAGELATCH_EX` or `PAGELATCH_SH` on pages that belong to **user databases** (not TempDB). Unlike V9 (TempDB PFS/GAM/SGAM allocation page contention), user-database PAGELATCH indicates contention on actual data pages — most commonly the **last page** of a clustered index with sequentially increasing keys.

**Why it matters**
All INSERT operations on a table with an IDENTITY or SEQUENCE clustered key target the same last page in the B-tree. Only one thread can hold the exclusive page latch at a time — every concurrent INSERT serializes behind this latch. On high-throughput OLTP systems, this can be the single largest bottleneck, limiting insert throughput regardless of CPU or I/O capacity.

**How to spot it**
```
wait_type     waiting_tasks  wait_time_ms  pct_total
PAGELATCH_EX  120,480        148,200       0.7%     ← on user database
```
The key distinction: PAGELATCH on TempDB (database_id=2, pages 1/2/3) = V9 (allocation contention). PAGELATCH on any other database or page number = V27 (data page contention).

**How to identify which database**
```sql
SELECT r.session_id, r.wait_type, r.wait_resource, DB_NAME(r.database_id) AS db_name
FROM sys.dm_exec_requests r
WHERE r.wait_type IN ('PAGELATCH_EX', 'PAGELATCH_SH')
  AND r.database_id > 4;  -- exclude system databases
```
The `wait_resource` column shows the database_id:file_id:page_number.

**Common causes**
- **Last-page insert contention:** All INSERTs target the same clustered index last page (IDENTITY, SEQUENCE with NEXT VALUE FOR). Every write acquires an exclusive latch on that page — effectively single-threading inserts.
- **Page splits:** Inserting into a full page triggers a page split, which holds the latch for the duration of the split operation (moving ~50% of rows to a new page + updating parent pages).
- **Heavy update patterns:** UPDATEs that modify key columns cause row movement, similar to insert-then-delete internally.

**Fix options (ranked by impact)**
1. **OPTIMIZE_FOR_SEQUENTIAL_KEY = ON** (SQL Server 2019+) — the most effective fix for last-page contention with IDENTITY keys: `ALTER INDEX PK_TableName ON dbo.TableName SET (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)`. This improves throughput without redesigning the key.
2. **Change the clustered key** — use a non-sequential key (random GUID, business key) to spread inserts across the B-tree. Trade-off: index fragmentation from random inserts.
3. **SEQUENCE with cache** — `CREATE SEQUENCE MySeq AS INT START WITH 1 CACHE 1000` — reduces metadata contention but does not change page-level contention.
4. **Reduce FILLFACTOR** — `ALTER INDEX PK_TableName ON dbo.TableName REBUILD WITH (FILLFACTOR = 80)` — each page has 20% free space, delaying page splits and reducing their frequency.
5. **Hash partitioning** — partition the table by a computed hash column to spread inserts across multiple B-trees (each partition has its own last page).

**Related checks:** V9 (TempDB PAGELATCH — different root cause, same wait type), V1 (PAGEIOLATCH — often co-occurs when the insert-heavy table is also scanned heavily)

---

### V28 — Backup I/O (BACKUPIO / BACKUPBUFFER)

**What it means**
`BACKUPIO` occurs when a database backup is reading data pages into the backup buffer — SQL Server waits for the I/O to complete. `BACKUPBUFFER` occurs when the backup is generating buffers faster than the backup media can consume them — threads wait for a free buffer.

**Why it matters**
Backup I/O is real I/O. On large databases or during business hours, backup I/O competes with user query I/O. Unlike most wait types, BACKUPIO/BACKUPBUFFER are expected during backup windows and should be correlated with backup job schedules. The question is whether they appear *outside* backup windows (rogue job, misconfigured schedule) or at sufficient volume *during* windows to degrade concurrent user performance.

**How to spot it**
```
wait_type        waiting_tasks  wait_time_ms  pct_total
BACKUPIO         84,210         420,500       5.1%
BACKUPBUFFER     12,400         84,200        1.0%
```
Combined 6.1% → Info. At ≥ 15% combined → Warning (backup I/O is competing significantly with user I/O).

**Fix options**
1. **Schedule off-hours** — move backups to the lowest-activity window. This is the simplest and most effective fix.
2. **Backup compression** — `BACKUP DATABASE YourDb TO DISK = 'path.bak' WITH COMPRESSION` — reduces backup size, I/O volume, and buffer consumption by 2–10× depending on data compressibility.
3. **Backup striping** — write to N files in parallel: `TO DISK = 'file1.bak',..., 'fileN.bak'` — each stripe uses its own buffer set, reducing single-buffer contention. Use with `MAXTRANSFERSIZE = 4194304` (4 MB) for optimal throughput.
4. **Increase BUFFERCOUNT** — `BACKUP DATABASE YourDb TO DISK = 'path.bak' WITH BUFFERCOUNT = 64` — doubles the default buffer pool. Specifically addresses BACKUPBUFFER waits.
5. **Dedicated backup network** — if backing up to a UNC path, use a dedicated NIC so backup traffic doesn't saturate the client-access network.

**Related checks:** V1 (PAGEIOLATCH — overall I/O pressure), V5 (WRITELOG — log backups also generate I/O)

---

### V29 — Cumulative Skew Detection (Outlier Dominance)

**What it means**
For any wait type, compute `avg_wait_ms = wait_time_ms / waiting_tasks_count`. If `max_wait_time_ms > 100 × avg_wait_ms`, a small number of extreme outlier waits are disproportionately inflating the cumulative total. The wait type appears to be a major problem when in reality it is driven by one or two extreme events.

**Why it matters**
`sys.dm_os_wait_stats` is cumulative since the last restart. A single 30-minute `PAGEIOLATCH_SH` event (e.g., from a `DBCC CHECKDB` that ran once last month) can dominate the cumulative total, giving a false impression of chronic I/O problems. Without this check, users waste time tuning a wait type that has no ongoing impact.

**How to spot it**
```
wait_type        waiting_tasks  wait_time_ms  max_wait_time_ms  avg_wait
PAGEIOLATCH_SH   48,291         5,120,000     1,800,000          106 ms  → ratio 1,800,000/106 = 16,981× — skewed!
CXPACKET         248,100        2,184,200     12,100             8.8 ms  → ratio 1,375× — normal range
```
PAGEIOLATCH_SH has `max_wait_time_ms` 16,981× the average — almost certainly one extreme event dominating. CXPACKET has a 1,375× ratio, which is within normal variance for parallel workloads where individual wait times vary by a few orders of magnitude.

**How it helps**
- **Cumulative data:** Identifies when the cumulative total is unreliable for assessing current state. Recommend re-capturing a differential snapshot to exclude the outlier.
- **Single-snapshot (differential):** If the differential window captured a one-time event (e.g., a SQL Agent job that ran once during the 30-minute window), flag it so the user knows the snapshot is not representative.
- **Trend mode:** Less relevant — V20 (spike detection) and V25 (transient events) already catch outliers per-period. But V29 adds the specific metric to support those findings.

**Correlating the outlier**
Correlate the high `max_wait_time_ms` with known maintenance windows:
- `PAGEIOLATCH_*`: DBCC CHECKDB, index rebuilds, large SELECT INTO operations
- `LCK_M_*`: Schema modification (SCH-M lock held during index rebuild or ALTER TABLE)
- `WRITELOG`: Bulk import operations, large batch DELETE/UPDATE
- `BACKUPIO`: Full database backups (even if they complete within schedule, the max wait reflects the largest single I/O during backup)

**Related checks:** V20 (spike detection), V25 (transient events), V14 (single wait dominance — may be triggered by the outlier)

---

## Modern Feature Checks (V30–V36)

---

### V30 — In-Memory OLTP / Hekaton Waits

**What it means**
`XTP*` and `WAIT_XTP*` waits occur when memory-optimized (Hekaton) tables are under pressure. The XTP engine is SQL Server's in-memory OLTP subsystem — it has its own checkpoint, transaction, and I/O threads. When these are contended, waits accumulate outside the normal buffer pool path and appear under XTP-prefixed wait types.

**Why it matters**
In-Memory OLTP is designed for extreme OLTP throughput. If XTP waits are significant, the in-memory optimization benefit is being eroded by checkpoint I/O, off-row column access, or thread scheduling overhead — meaning the tables may behave no better than disk-based tables under the current load.

**How to spot it**
```
wait_type                     waiting_tasks  wait_time_ms  pct_total
WAIT_XTP_CKPT_CLOSE           8,420          182,000       4.2%
XTP_PREEMP_CKPT_MAIN          1,204          48,200        1.1%
```

**Fix options**
1. **Check XTP checkpoint throughput** — `SELECT * FROM sys.dm_db_xtp_checkpoint_stats` to identify whether checkpoint I/O is the bottleneck. Move XTP checkpoint files to faster storage.
2. **Investigate transaction stats** — `SELECT * FROM sys.dm_xtp_transaction_stats` for commit/rollback rates and GC (garbage collection) pressure.
3. **Review off-row columns** — `VARCHAR(MAX)`, `NVARCHAR(MAX)`, or columns exceeding 8 KB in memory-optimized tables are stored off-row and bypass the in-memory path, causing additional I/O.
4. **Natively compiled stored procedures** — switching to natively compiled procs reduces interpreter overhead and XTP scheduling wait time.

**Related checks:** V4 (RESOURCE_SEMAPHORE — sometimes co-occurs if In-Memory OLTP grants are competing with rowstore workloads)

---

### V31 — Columnstore Waits

**What it means**
`COLUMNSTORE*` waits occur during columnstore delta store compression, tuple mover operations, or batch mode synchronization. The tuple mover is a background thread that compresses OPEN delta rowgroups (each holding up to ~1 million rows) into compressed columnstore segments. When the delta store grows faster than the tuple mover can compress it, these waits appear.

**Why it matters**
A growing delta store degrades columnstore query performance — rows in OPEN delta rowgroups are scanned in row mode rather than batch mode, losing the primary performance benefit of columnstore indexes. Significant `COLUMNSTORE*` waits indicate the delta store is a bottleneck.

**How to spot it**
```
wait_type                  waiting_tasks  wait_time_ms  pct_total
COLUMNSTORE_BUILD_THROTTLE  4,210          82,000        2.1%
```
Cross-reference with delta store health:
```sql
SELECT object_name(object_id) AS table_name,
       state_description, COUNT(*) AS rowgroup_count, SUM(row_count) AS total_rows
FROM sys.dm_db_column_store_row_group_physical_stats
GROUP BY object_name(object_id), state_description
ORDER BY 1, 2;
```
If many `OPEN` or `CLOSED` rowgroups exist, the tuple mover is lagging.

**Fix options**
1. **Trigger manual compression** — `ALTER INDEX CCI_TableName ON dbo.TableName REORGANIZE WITH (COMPRESS_DELAY = 0)` flushes all CLOSED rowgroups immediately.
2. **Reduce delta store pressure** — batch larger inserts (≥ 102,400 rows per batch) to bypass the delta store and write directly to compressed segments.
3. **Check memory grant pressure** (V4) — if batch mode memory grants are insufficient, the optimizer spills to row mode, inflating delta store work. Update statistics and add indexes to reduce sort/hash input sizes.
4. **SQL Server 2019+** — Batch Mode on Rowstore reduces COLUMNSTORE waits by enabling batch execution on standard rowstore indexes.

**Related checks:** V3 (CXPACKET / HT* — batch mode parallelism waits often co-occur), V4 (RESOURCE_SEMAPHORE)

---

### V32 — Query Store Overhead Waits

**What it means**
`QDS*` (Query Data Store) waits occur when Query Store capture, flush, cleanup, or async queue processing consumes significant SQL Server thread time. Query Store is a background feature — when its overhead appears in the top wait types, it is competing with production workloads for execution resources.

**Why it matters**
Query Store is designed to be lightweight, but on very high-churn workloads (many distinct ad-hoc queries, high plan turnover) or with aggressive collection settings, its overhead becomes measurable. `QDS_PERSIST_TASK_MAIN_LOOP_SLEEP` is normally idle, but `QDS_ASYNC_QUEUE` indicates the async write thread is falling behind.

**How to spot it**
```
wait_type           waiting_tasks  wait_time_ms  pct_total
QDS_ASYNC_QUEUE     48,291         82,000        2.1%
```

**Fix options**
1. **Increase flush interval** — `ALTER DATABASE [YourDb] SET QUERY_STORE (DATA_FLUSH_INTERVAL_SECONDS = 1800)` reduces how often Query Store writes to disk.
2. **Switch to AUTO capture** — `ALTER DATABASE [YourDb] SET QUERY_STORE (QUERY_CAPTURE_MODE = AUTO)` suppresses single-execution and trivial queries from being captured.
3. **Use CUSTOM capture policy** (SQL 2019+) — `QUERY_CAPTURE_POLICY` allows filtering by execution count, CPU, and duration thresholds.
4. **Check store capacity** — `SELECT * FROM sys.database_query_store_options` — if `current_storage_size_mb` is near `max_storage_size_mb`, auto-cleanup runs continuously. Increase `MAX_STORAGE_SIZE_MB` or purge old data: `EXEC sys.sp_query_store_flush_db`.

**Related checks:** V4 (RESOURCE_SEMAPHORE — if QDS memory usage is competing), V7 (SOS_SCHEDULER_YIELD — high-churn workloads that tax QDS also tax the scheduler)

---

### V33 — Transaction / DTC Waits

**What it means**
`XACT*`, `DTC*`, `TRAN_MARKLATCH_*`, `MSQL_XACT_*`, and `TRANSACTION_MUTEX` waits indicate distributed transaction coordination overhead or transaction marker latch contention. `DTC_*` waits explicitly confirm that Microsoft Distributed Transaction Coordinator (MS DTC) is involved — cross-server transactions that require two-phase commit.

**Why it matters**
Distributed transactions are inherently slower than local transactions — they require a two-phase commit protocol across all participating servers plus a network round-trip through MS DTC for every commit. Under concurrency, DTC becomes a serialization point. Even with DTC properly configured, distributed transaction overhead can be 10–100× that of a local transaction.

**How to spot it**
```
wait_type           waiting_tasks  wait_time_ms  pct_total
DTC_STATE           4,210          820,000       8.2%
TRANSACTION_MUTEX   1,840          184,200       1.8%
```

**Fix options**
1. **Eliminate distributed transactions** — consolidate operations onto a single server or database. This is almost always possible with proper schema design.
2. **Identify active distributed transactions** — `SELECT * FROM sys.dm_tran_active_transactions WHERE transaction_type = 2 ORDER BY transaction_begin_time`.
3. **Check MS DTC configuration** — if DTC is required: ensure DTC is running and configured on all nodes (`Component Services → Distributed Transaction Coordinator`); network DTC access must be enabled for cross-machine transactions.
4. **`TRANSACTION_MUTEX` / `MSQL_XACT_*`** — these are internal transaction manager latches. If prominent, investigate `sys.dm_tran_locks` for the specific transactions consuming lock manager resources.
5. **`TRAN_MARKLATCH_*`** — these appear when using named transaction marks (`BEGIN TRANSACTION <name>`); ensure marks are necessary and not held excessively long.

**Related checks:** V2 (LCK_M — long distributed transactions hold locks longer, amplifying lock waits)

---

### V34 — Service Broker Waits

**What it means**
`BROKER_*` waits (excluding the idle background waits filtered from the standard capture query such as `BROKER_EVENTHANDLER`, `BROKER_TASK_STOP`, `BROKER_TO_FLUSH`, `BROKER_TRANSMITTER`) indicate Service Broker queue depth, message delivery latency, or activation procedure contention. Service Broker is SQL Server's asynchronous messaging system — high broker waits indicate messages are piling up faster than they are being consumed.

**Why it matters**
A growing Service Broker queue causes memory pressure (queued messages consume buffer pool) and can cause application-visible delays when dialogs wait for acknowledgements.

**How to spot it**
```
wait_type              waiting_tasks  wait_time_ms  pct_total
BROKER_RECEIVE_WAITFOR  84,210         420,500       4.2%
BROKER_WAIT_RESULT       4,210          82,000        0.8%
```
Note: `BROKER_RECEIVE_WAITFOR` is normally idle (excluded from the standard capture list) — if it appears in a non-filtered snapshot, the application is actively waiting for messages.

**Fix options**
1. **Check queue depth** — `SELECT name, is_receive_enabled, activation_procedure FROM sys.service_queues; SELECT COUNT(*) FROM sys.transmission_queue`.
2. **Check activation status** — `SELECT * FROM sys.dm_broker_activated_tasks` to verify activation procedures are running and not deadlocked.
3. **Poison message diagnosis** — a failing activation procedure that repeatedly rolls back blocks the queue. Identify with `SELECT * FROM sys.conversation_endpoints WHERE state_desc NOT IN ('CONVERSING', 'CLOSED')`. Fix the activation proc, then `END CONVERSATION` the blocked dialog, or enable poison message handling.
4. **Scale activation** — increase `MAX_QUEUE_READERS` on the queue to allow more concurrent activation procedures: `ALTER QUEUE dbo.YourQueue WITH ACTIVATION (MAX_QUEUE_READERS = 10)`.

**Related checks:** none — Service Broker is typically isolated from other wait types

---

### V35 — Full Text Search Waits

**What it means**
`FT_*`, `FULLTEXT GATHERER`, `MSSEARCH`, and `PWAIT_RESOURCE_SEMAPHORE_FT_PARALLEL_QUERY_SYNC` waits indicate full-text index population (crawl) I/O competing with the production workload, or full-text query memory semaphore contention. The full-text engine is a separate process (`fdhost.exe`) that communicates with SQL Server via shared memory — waits accumulate when SQL Server threads block waiting for the FT process.

**Why it matters**
Full-text crawls read every row of the indexed table to rebuild the full-text index. On large tables this is a significant I/O and CPU operation that competes with user queries. Full-text query execution also requires a memory semaphore for parallel queries — when saturated, FT queries queue similarly to `RESOURCE_SEMAPHORE`.

**How to spot it**
```
wait_type                                    wait_time_ms  pct_total
PWAIT_RESOURCE_SEMAPHORE_FT_PARALLEL_QUERY_SYNC  420,500   4.2%
FT_IFTS_SCHEDULER_IDLE_WAIT                       82,000   0.8%
```

**Fix options**
1. **Check crawl status** — `SELECT * FROM sys.dm_fts_index_population` to see whether a full population or incremental crawl is running.
2. **Throttle crawl resource usage** — `EXEC sp_fulltext_service 'resource_usage', 1` (scale 1–5; 1 = minimum resource usage).
3. **Schedule crawls off-peak** — stop and restart the FT crawl during low-activity windows.
4. **Reduce crawl scope** — use incremental or change tracking populations instead of full populations where possible.
5. **Offload full-text search** — for very high search volumes, consider Elasticsearch, Azure Cognitive Search, or SQL Server 2022's full-text integration with external search engines.

**Related checks:** V1 (PAGEIOLATCH — crawl I/O competes with user query I/O on shared storage)

---

### V36 — Parallel Redo Waits (Always On Secondary)

**What it means**
`PARALLEL_REDO*` waits appear on Always On secondary replicas when parallel redo threads are contending or the redo queue is growing. The redo log thread on a secondary replica applies log records generated by the primary — parallel redo uses multiple threads to apply log in parallel to improve throughput. When the secondary cannot keep pace with the primary's log generation rate, redo queue depth grows and these waits appear.

**Why it matters**
A lagging secondary replica has several consequences: (1) readable secondary queries return stale data; (2) if the primary uses synchronous commit and relies on this secondary for quorum, its lag adds back-pressure to the primary (V18 `HADR_THROTTLE_LOG_RATE_GOVERNOR`); (3) the RPO (recovery point objective) grows — a larger redo queue means more data at risk on secondary failure.

**How to spot it**
```
wait_type                      waiting_tasks  wait_time_ms  pct_total
PARALLEL_REDO_CACHE_EXCHANGE    48,291         820,500       8.2%
PARALLEL_REDO_DRAIN_WORKER       4,210          82,000        0.8%
```
Cross-reference redo queue size:
```sql
SELECT database_name,
       redo_queue_size,        -- KB waiting to be applied on this secondary
       redo_rate,              -- KB/s at which redo is being applied
       last_hardened_lsn,
       secondary_lag_seconds
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1
ORDER BY redo_queue_size DESC;
```

**Fix options**
1. **Check redo throughput vs. log generation rate** — if `redo_rate` < primary log generation rate, the gap will grow. The fix must increase redo throughput on the secondary.
2. **Improve secondary I/O** — the redo thread is write-bound on the secondary's data and log files. Move them to faster storage (NVMe).
3. **Increase parallel redo workers**:
   - SQL Server 2022+: `ALTER DATABASE SCOPED CONFIGURATION SET PARALLEL_REDO_WORKER_POOL_SIZE = N` (default 0 = automatic)
   - SQL Server 2016–2019: trace flag 3468 enables extended parallel redo (`DBCC TRACEON(3468, -1)`)
4. **Consider async commit** for replicas that are not required for synchronous quorum — this removes the back-pressure on the primary.
5. **Reduce primary write workload** — if the primary is generating more log than the secondary can apply, addressing the primary's write volume (batch inserts, reduced index maintenance) reduces the redo backlog.

**Related checks:** V12 (HADR_SYNC_COMMIT — primary-side wait for secondary ack), V18 (HADR_THROTTLE_LOG_RATE_GOVERNOR — primary throttled because secondary redo queue is full)

---

### V37 — Forced Memory Grants

**What it means:** Queries are being forced to run with less memory than the optimizer requested. The Resource Governor / Resource Semaphore is reducing memory grants because there isn't enough free query execution memory. These queries will run, but with insufficient memory for sort/hash operations — causing tempdb spills and longer execution times. This is invisible in V4 (RESOURCE_SEMAPHORE waits) because the query IS running, just running poorly.

**How to spot it:**
Check `sys.dm_exec_query_resource_semaphores`:
```
resource_semaphore_id  forced_grant_count  timeout_error_count
---------------------- ------------------  ----------------------
0 (small query pool)   0                   0
1 (large query pool)   12                  0
```
The `forced_grant_count = 12` on the large query pool means 12 queries are currently running with reduced memory. Each of these is likely spilling to tempdb.

**Example (problem + fix):**
```
-- Large pool: forced_grant_count = 12, total_memory_gb = 4.2, available = 0
-- Mean every large query is getting forced grants — system has no free grant memory
-- Root cause: stale statistics on dbo.SalesFact (5M estimated → 50 actual, optimizer requested 2GB grant)
-- Fix: UPDATE STATISTICS dbo.SalesFact WITH FULLSCAN
-- After: forced_grant_count → 0, query durations dropped 60%
```
**Fix options:**
1. **Update statistics with FULLSCAN** on large tables — stale stats → overestimated row counts → oversized grants → fewer concurrent grants possible
2. **Add indexes** to avoid the sort/hash operators driving large grants (eliminate the need rather than increasing the grant)
3. **Cap individual grants**: `ALTER WORKLOAD GROUP [default] WITH (REQUEST_MAX_MEMORY_GRANT_PERCENT = 25)` via Resource Governor
4. **Increase max server memory**: if `max server memory` leaves too little room for query grants, raise it (especially if `available_memory_kb` is consistently near 0)
5. **Run `/sqlplan-review`** on the plans of memory-hungry queries (identify via `sys.dm_exec_query_memory_grants` WHERE `granted_memory_kb > 1048576`)

**Related checks:** V4 (RESOURCE_SEMAPHORE waits), V38 (grant timeouts), S2/S3/S4 (sqlplan-review memory grant analysis)

---

### V38 — Memory Grant Timeouts

**What it means:** One or more queries gave up waiting for a memory grant entirely — the query never executed. Users received timeouts or errors. This is the most severe form of memory pressure: V4 = queries waiting, V37 = queries running with less memory, V38 = queries failing.

**How to spot it:**
Check `sys.dm_exec_query_resource_semaphores`:
```
timeout_error_count > 0
```
The `resource_semaphore_id` identifies which pool is starving: 0 = regular queries, 1 = large queries.

**Example (problem + fix):**
```
-- Pool 1: timeout_error_count = 45, waiter_count = 23, granted_memory_gb = 4.0 (maxed out)
-- 23 queries are queued, 45 have already timed out
-- This server has max_server_memory = 256 GB, but large pool is only 4 GB
-- A nightly ETL process is requesting 8 GB grants for MERGE statements with inflated estimates
```
**Fix options:**
1. **Kill long-running grant holders**: query `sys.dm_exec_query_memory_grants` for `grant_time > 5 minutes` — kill those sessions (`KILL spid`)
2. **Lower `query wait (s)`**: `sp_configure 'query wait (s)', 60` — fail fast (60s) rather than hold connections indefinitely (default 1200s = 20 minutes)
3. **Identify oversized grants**: query `sys.dm_exec_query_memory_grants` WHERE `requested_memory_kb > granted_memory_kb * 5` — these are requesting 5× what they got, inflating grant estimates
4. **Apply V4/V37 fixes**: update statistics, cap grants, add indexes
5. **Scale up**: if this is chronic under normal workload, the server needs more `max server memory` or the workload needs restructuring

**Related checks:** V4 (RESOURCE_SEMAPHORE waits), V37 (forced grants), V8 (THREADPOOL — memory exhaustion often coincides with thread exhaustion)

---

### V39 — High Stolen Memory

**What it means:** Non-buffer-pool components are consuming a significant portion of SQL Server's memory. "Stolen" memory (Microsoft's term) is memory allocated to components other than the data cache: plan cache, Query Store, lock manager, security cache, CLR, linked servers, etc. When stolen memory grows too large, it reduces the memory available for the buffer pool (data cache) and query execution grants.

**How to spot it:**
From the memory clerk query output, sum all `pages_gb`. Compare to `max server memory`. ALternatively, compute rapidly from `sys.dm_os_performance_counters`:
```
Buffer Pool: Buffer cache hit ratio < 90% with large stolen memory = buffer pool starved
```

**Example (problem + fix):**
```
-- Top clerks:
-- CACHESTORE_SQLCP:    4.8 GB (plan cache — ad-hoc queries without parameterization)
-- USERSTORE_TOKENPERM: 3.2 GB (security token cache — excessive application roles)
-- MEMORYCLERK_SQLQERESERVATIONS: 2.1 GB (Query Store — 90 days retention with ALL capture mode)
-- Total stolen: 12.1 GB out of 64 GB max memory = 18.9%
```
**Fix options:**
1. **Plan cache bloat** (> 2 GB): enable `optimize for ad hoc workloads` (`sp_configure 'optimize for ad hoc workloads', 1`) — stores only a plan stub for single-use ad-hoc queries
2. **Security token cache** (> 1 GB): reduce application role usage, or periodically flush with `DBCC FREESYSTEMCACHE('TokenAndPermUserStore')`
3. **Query Store** (> 2 GB): reduce retention to 30 days, switch to `QUERY_CAPTURE_MODE = AUTO`, increase `MAX_STORAGE_SIZE_MB`
4. **Lock manager** (> 1 GB): reduce lock escalation or batch large DML operations
5. **Overall**: if stolen memory persistently exceeds 25%, the server likely needs more `max server memory` or cleanup of caching components

**Related checks:** V4 (RESOURCE_SEMAPHORE), V32 (Query Store overhead), V37 (forced grants)

---

### V40 — High File I/O Latency

**What it means:** Individual database file read or write latency exceeds 100 ms. This is the file-level complement to V1 (PAGEIOLATCH) — while V1 tells you *how much* I/O wait exists, V40 tells you *which specific files and drives* are slow. The two checks together provide the complete I/O picture: V1 = symptom (buffer pool waiting for pages), V40 = root cause (slow disks).

**How to spot it:**
From the File I/O latency query: `avg_read_latency_ms` or `avg_write_latency_ms` ≥ 100 ms.

**Example (problem + fix):**
```
-- database_name  file_name     avg_read_latency_ms  avg_write_latency_ms
-- TempDB         tempdev       12                   842      (WRITE critical)
-- SalesDB        SalesDB_log   3                    520      (WRITE critical)
-- SalesDB        SalesDB_data  285                  18       (READ warning)
-- ReportDB       ReportDB_data 2                    2        (OK)
--
-- TempDB writes at 842ms: either TempDB on slow shared storage, or synchronous mirroring on TempDB drive
-- SalesDB log writes at 520ms: log drive shared with other workloads, or slow SAN
-- SalesDB data reads at 285ms: data drive I/O bottlenecked by large scans
```
**Fix options:**
1. **TempDB write latency**: add more TempDB data files (8 for 8 cores), move to dedicated fast storage (local SSD/NVMe), ensure no synchronous mirroring on TempDB
2. **Log file write latency**: move transaction log to dedicated low-latency drive separate from data files, verify no other I/O shares the log drive (no backups, no OS page file)
3. **Data file read latency**: check `sys.dm_io_pending_io_requests` for queued I/O — if pending I/O > 10, the storage subsystem is saturated; add indexes to reduce reads; move hot tables to faster storage
4. **All files slow**: shared storage bottleneck — check SAN/cloud disk IOPS and throughput limits; consider storage QoS/throttling in cloud environments (Azure data disks, AWS gp2/io1 burst balance)
5. **Cross-reference**: if latency is high but PAGEIOLATCH (V1) is low, the buffer pool is masking read latency — writes may still be impacted, and the system may slow under memory pressure

**Related checks:** V1 (PAGEIOLATCH waits), V9 (TempDB PAGELATCH contention), V5 (WRITELOG log writes)

---

### V41 — PSP Optimization Selector Wait (SQL 2022+)

**What it means**
`QUERY_OPTIMIZER_PSP_WAIT` appears in wait stats with cumulative wait > 1,000 ms. The Parameter Sensitive Plan (PSP) optimizer is spending significant time selecting the correct variant plan for incoming parameters — indicating either an excessive variant plan count or high plan-switching frequency across executions.

**Why it matters**
PSP optimization generates multiple variant plans (dispatcher + variants) for queries with significant parameter-driven cardinality differences. When many variants exist or switching is very frequent, the selector logic runs on every execution before the plan is dispatched. This overhead accumulates and can become measurable on high-throughput workloads calling affected queries thousands of times per second.

**How to spot it**
```sql
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       wait_time_ms / NULLIF(waiting_tasks_count, 0) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type = 'QUERY_OPTIMIZER_PSP_WAIT'
  AND wait_time_ms > 1000;
```

**Fix options**
1. **Identify affected queries** — `SELECT * FROM sys.query_store_plan_feedback WHERE feedback_type = 'PSP'` — find queries where the optimizer is generating and switching between variant plans.
2. **Pin a single plan with OPTION(OPTIMIZE FOR UNKNOWN)** — if plan switching is frequent and providing little benefit: add the query hint to suppress per-parameter variant selection and use a generic plan instead.
3. **Apply a Query Store hint** — use `sys.sp_query_store_set_hints` to bind the query to a specific plan without code changes: `EXEC sys.sp_query_store_set_hints @query_id = <id>, @query_hints = N'OPTION(OPTIMIZE FOR UNKNOWN)'`.
4. **Review variant count** — if SQL Server generated more than 3 variants for a query, the cardinality ranges may be too narrow; investigate the predicate column's histogram and consider manual statistics updates.

**Related checks:** V3 (CXPACKET — parallelism overhead that may co-occur with PSP-selected parallel plans), S34 in sqlplan-review (PSP Dispatcher Plan Detected)

---

### V42 — IQP DOP Feedback Adjustment Wait (SQL 2022+)

**What it means**
`DOP_FEEDBACK_WAIT` appears in wait stats with cumulative wait > 500 ms. Intelligent Query Processing (IQP) DOP Feedback is actively evaluating and adjusting the degree of parallelism for one or more queries. The wait itself is brief per occurrence, but recurring instances indicate feedback is frequently applying new DOP settings across executions.

**Why it matters**
DOP Feedback evaluation adds a brief wait before each adjusted execution while the feedback mechanism verifies whether the proposed DOP change improves elapsed time. When many queries are simultaneously receiving DOP adjustments, these waits accumulate. If DOP adjustments result in worse elapsed times (e.g., by eliminating parallelism on a genuinely parallel-friendly query), the feedback loop may repeatedly re-adjust, adding unnecessary overhead.

**How to spot it**
```sql
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       wait_time_ms / NULLIF(waiting_tasks_count, 0) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type = 'DOP_FEEDBACK_WAIT'
  AND wait_time_ms > 500;
```

Cross-reference which queries are receiving DOP adjustments:
```sql
SELECT query_id, plan_id, feedback_type, feedback_data
FROM sys.query_store_plan_feedback
WHERE feedback_type = 'DOP';
```

**Fix options**
1. **Verify DOP adjustments are beneficial** — compare elapsed time before and after DOP reduction for the flagged queries. If regressions are observed, disable DOP Feedback for those queries.
2. **Disable DOP Feedback for a specific query** — apply a Query Store hint: `EXEC sys.sp_query_store_set_hints @query_id = N'<id>', @query_hints = N'OPTION(USE HINT(''DISABLE_DOP_FEEDBACK''))'`.
3. **Review COST_THRESHOLD_FOR_PARALLELISM** — if the cost threshold is too low, many marginal parallel plans are selected; DOP Feedback may be fighting against an underlying MAXDOP misconfiguration. Set to 25–50 and re-evaluate.
4. **Disable globally if overall regression** — `ALTER DATABASE SCOPED CONFIGURATION SET DOP_FEEDBACK = OFF` — use only if DOP Feedback is causing broad regressions across many queries.

**Related checks:** V3 (CXPACKET — parallelism), V4 (RESOURCE_SEMAPHORE — memory grants interact with DOP changes)

---

### V43 — ADR PVS Cleanup Worker Wait (SQL 2019+)

**What it means**
`PVSVERSIONSTORE_WAIT` or `ADR_CLEANUP_WAIT` appears in wait stats with cumulative wait > 5,000 ms. The Accelerated Database Recovery (ADR) Persistent Version Store (PVS) cleanup worker is blocked or stalled, preventing version store space reclamation. When the cleanup worker cannot advance, the PVS grows unboundedly until either the database's PVS filegroup or tempdb (the default PVS location prior to a dedicated filegroup) is exhausted.

**Why it matters**
ADR uses a persistent version store to enable instant rollback and faster log truncation. Unlike classic version store (in tempdb), the ADR PVS persists across restarts. If PVS cleanup stalls — typically because a long-running or idle open transaction holds a snapshot that cleanup cannot advance past — the PVS grows continuously. On write-heavy systems this growth can exhaust available space within hours, causing all further DML to fail.

**How to spot it**
```sql
SELECT wait_type, waiting_tasks_count, wait_time_ms,
       wait_time_ms / NULLIF(waiting_tasks_count, 0) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('PVSVERSIONSTORE_WAIT', 'ADR_CLEANUP_WAIT')
  AND wait_time_ms > 5000;
```

Check PVS size and oldest active transaction:
```sql
-- PVS current size and cleanup state
SELECT * FROM sys.dm_tran_persistent_version_store_stats;

-- Find long-running or idle transactions blocking cleanup
SELECT transaction_id, transaction_begin_time,
       DATEDIFF(MINUTE, transaction_begin_time, GETUTCDATE()) AS age_minutes,
       name AS transaction_name
FROM sys.dm_tran_active_transactions
WHERE transaction_begin_time < DATEADD(MINUTE, -5, GETUTCDATE())
ORDER BY transaction_begin_time;
```

**Fix options**
1. **Find and commit or kill the blocking transaction** — the most common cause is an open transaction (application bug, orphaned connection, long-running report) that holds a snapshot PVS cleanup cannot advance past. Kill it: `KILL <spid>`.
2. **Monitor PVS growth** — if `sys.dm_tran_persistent_version_store_stats` shows `persistent_version_store_size_kb` growing continuously, cleanup is stalled — treat as urgent.
3. **Move PVS to a dedicated filegroup** — `ALTER DATABASE [db] SET PERSISTENT_VERSION_STORE_FILEGROUP = [pvs_fg]` — isolates PVS growth from user data and tempdb, preventing cross-contamination of space.
4. **Disable ADR if not required** — if ADR was enabled incidentally (Azure SQL Managed Instance enables it by default) and instant recovery is not needed: `ALTER DATABASE [db] SET ACCELERATED_DATABASE_RECOVERY = OFF`. This triggers a full PVS cleanup. Note: disabling ADR requires an exclusive database connection and may take time proportional to current PVS size.
5. **Set application transaction timeouts** — prevent open-ended transactions from ever reaching multi-minute age; most ORMs and ADO.NET have a `CommandTimeout` and `TransactionTimeout` setting.

**Related checks:** V9 (PAGELATCH TempDB contention — PVS uses tempdb by default unless a dedicated filegroup is configured), V4 (RESOURCE_SEMAPHORE — PVS cleanup can consume memory)

---

### V44 — TempDB Metadata Latch Contention — Memory-Optimized Metadata Not Enabled (SQL 2019+)

**What it means**
`PAGELATCH_EX` or `PAGELATCH_SH` appears in the top 10 waits but the contended pages are TempDB data pages beyond the allocation bitmap pages (resource pages 4+), meaning the latch is on system catalog rows — not on allocation pages (PFS/GAM/SGAM, which are pages 1–3 and covered by V9). This pattern occurs when many concurrent sessions create, use, and drop temporary objects: temp tables, TVPs, or worktables, and their metadata rows contend on the same TempDB system pages.

**Why it matters**
TempDB system object creation serializes on catalog page latches even when TempDB has many data files (which fixes PFS/GAM contention from V9). Memory-optimized TempDB metadata, introduced in SQL 2019, moves the system object metadata for TempDB into in-memory structures, eliminating this latch class entirely without any application changes required.

**How to spot it**
```sql
-- Identify TempDB page contention beyond allocation pages
SELECT resource_description, wait_type, COUNT(*) AS waiters
FROM sys.dm_os_waiting_tasks
WHERE wait_type IN ('PAGELATCH_EX', 'PAGELATCH_SH')
  AND resource_description LIKE '2:1:%'
GROUP BY resource_description, wait_type
ORDER BY waiters DESC;
-- Pages 2:1:1, 2:1:2, 2:1:3 = PFS/GAM/SGAM (V9)
-- Pages 2:1:4+ = system metadata pages (V44 territory)
```

**Fix options**
1. Enable TempDB memory-optimized metadata (requires restart):
   ```sql
   ALTER SERVER CONFIGURATION
   SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;
   ```
   Then restart the SQL Server service. After restart, verify: `SELECT * FROM sys.configurations WHERE name = 'tempdb metadata memory-optimized'`
2. Before restarting, verify the contention is on pages > 3 using `sys.dm_os_waiting_tasks` above — page 1 (PFS), 2 (GAM), and 3 (SGAM) contention means V9 (add more TempDB files) is the right fix instead
3. Not available on Azure SQL Database or Azure SQL Managed Instance — both platforms manage TempDB internally and the feature is not exposed to users
4. If the environment cannot be restarted immediately: reduce concurrent temp object creation (connection pooling, reuse temp tables within sessions, use table variables for small result sets), or partition the workload to reduce peak TempDB concurrency
5. Requires SQL Server 2019 (15.x) or later; the `ALTER SERVER CONFIGURATION` syntax for this option does not exist on SQL 2017 or earlier

**Related checks:** V9 (TempDB PFS/GAM/SGAM allocation page contention — different page range), V14 (LATCH_EX/SH on non-page latches)

---

## Quick Reference: Checks by Category

### Emergency / Poison (investigate immediately)
| Check | Wait Type | Meaning |
|-------|-----------|---------|
| V18 | IO_QUEUE_LIMIT | Storage queue full — hardware / volume issue |
| V18 | IO_RETRY | I/O failure retrying — hardware / driver error |
| V18 | LOG_RATE_GOVERNOR | Log generation throttled — Azure tier limit |
| V18 | SE_REPL_* | Always On secondary too far behind → primary throttled |

### I/O bound (fix storage or reduce page reads)
| Check | Wait Type | Primary Fix |
|-------|-----------|------------|
| V1 | PAGEIOLATCH_SH/EX | Add indexes, add RAM, faster storage |
| V5 | WRITELOG | Dedicated log on NVMe, batch commits |

### Lock bound (fix concurrency)
| Check | Wait Type | Primary Fix |
|-------|-----------|------------|
| V2 | LCK_M_* | Add indexes, enable RCSI, shorten transactions |

### CPU / Parallelism bound
| Check | Wait Type | Primary Fix | Common Mistake |
|-------|-----------|------------|----------------|
| V3 | CXPACKET | Raise CTPfP to 25–50; fix data skew | Reducing MAXDOP reflexively |
| V7 | SOS_SCHEDULER_YIELD | Add indexes to eliminate in-memory scans | Assuming CPU pressure or LOCK_HASH spinlock |
| V10 | Signal wait ratio | Reduce CPU-intensive queries | — |

### Memory bound (fix grants or RAM)
| Check | Wait Type | Primary Fix |
|-------|-----------|------------|
| V4 | RESOURCE_SEMAPHORE | Update statistics, add indexes, add RAM |

### Memory Bound (DMV Detail — requires optional capture queries)
| Check | Trigger | Primary Fix |
|-------|---------|------------|
| V37 | forced_grant_count > 0 | Update statistics, cap grants, add indexes |
| V38 | timeout_error_count > 0 | Kill grant holders, lower query wait(s), V4/V37 fixes |
| V39 | Stolen memory ≥ 15% | Identify top clerk, enable optimize for ad hoc workloads |

### I/O Detail (DMV Detail — requires optional capture queries)
| Check | Trigger | Primary Fix |
|-------|---------|------------|
| V40 | File avg latency ≥ 100 ms | Move files to faster storage, add TempDB files, isolate log |

### Modern Query Processing / ADR (SQL 2019+/2022+)
| Check | Name | Version | Severity |
|-------|------|---------|----------|
| V41 | PSP Optimization Selector Wait | SQL 2022+ | Warning |
| V42 | IQP DOP Feedback Adjustment Wait | SQL 2022+ | Info |
| V43 | ADR PVS Cleanup Worker Wait | SQL 2019+ | Warning |
| V44 | TempDB Metadata Latch Contention — Memory-Optimized Metadata Not Enabled | SQL 2019+ | Warning |

### Capacity bound (fix server limits)
| Check | Wait Type | Primary Fix |
|-------|-----------|------------|
| V8 | THREADPOOL | Kill blockers, reduce MAXDOP, pool connections |
| V9 | PAGELATCH (TempDB pages 1/2/3) | Add TempDB files (one per core) |
| V15 | LATCH_EX/SH (non-page) | Identify latch class via sys.dm_os_latch_stats, then fix |
| V16 | LOGMGR_RESERVE_APPEND | Take log backup (FULL recovery) or find blocking transaction (SIMPLE) |

### External bound (fix outside SQL Server)
| Check | Wait Type | Primary Fix | Common Mistake |
|-------|-----------|------------|----------------|
| V6 | ASYNC_NETWORK_IO | Fix application consumption speed | Treating as a SQL Server problem |
| V11 | OLEDB | Short waits = benign (monitoring); long waits = linked server | Treating all OLEDB as linked server |
| V12 | HADR_SYNC_COMMIT | Async commit, faster secondary storage | — |
| V13 | PREEMPTIVE_* | Remove xp_cmdshell, move CLR to app layer | — |

### Diagnostic
| Check | Trigger | Purpose |
|-------|---------|---------|
| V14 | Single type ≥ 60% | Focus effort on dominant bottleneck |
| V17 | Always | Top-5 table — orientation for all other checks |
| V29 | max_wait > 100× avg per task | Identify when cumulative totals are skewed by outlier events |

### Operational / Specialized
| Check | Wait Type | Primary Fix | Common Mistake |
|-------|-----------|------------|----------------|
| V27 | PAGELATCH on user DBs | OPTIMIZE_FOR_SEQUENTIAL_KEY, change clustered key, lower FILLFACTOR | Confusing with V9 (TempDB PAGELATCH — different root cause) |
| V28 | BACKUPIO / BACKUPBUFFER | Off-hours scheduling, compression, striping | Treating backup I/O as a chronic SQL Server problem |

### Modern Features
| Check | Wait Type | Threshold | Primary Fix |
|-------|-----------|-----------|------------|
| V30 | In-Memory OLTP | XTP*, WAIT_XTP* ≥ 2% | Check checkpoint I/O, off-row columns, natively compiled procs |
| V31 | Columnstore | COLUMNSTORE* ≥ 2% | Trigger manual compression, batch larger inserts, fix memory grants |
| V32 | Query Store overhead | QDS* ≥ 1% | Increase flush interval, switch to AUTO capture mode |

### Distributed / HA
| Check | Wait Type | Threshold | Primary Fix |
|-------|-----------|-----------|------------|
| V33 | Transaction / DTC | XACT*, DTC*, TRAN_MARKLATCH_* ≥ 2% | Eliminate distributed transactions; consolidate onto single server |
| V36 | Parallel Redo | PARALLEL_REDO* ≥ 2% | Improve secondary I/O, increase parallel redo workers |

### Platform Services
| Check | Wait Type | Threshold | Primary Fix |
|-------|-----------|-----------|------------|
| V34 | Service Broker | BROKER_* ≥ 3% | Check queue depth, activation procedures, poison messages |
| V35 | Full Text Search | FT_*, MSSEARCH ≥ 3% | Throttle crawl, schedule off-peak, offload to dedicated search engine |

### Trend Analysis (requires 3+ time windows; V20/V21/V23 require 2+)
| Check | Trigger | Purpose |
|-------|---------|---------|
| V19 | Monotonic direction across ≥ 3 periods | Is a wait type systematically worsening or improving? |
| V20 | Single period ≥ 200% of own average | Discrete spike event — find the trigger |
| V21 | Always (2+ periods) | Which time window was worst? |
| V22 | Always (3+ periods) | Which wait type is growing fastest? |
| V23 | < 0.5% → ≥ 2.0% mid-capture | New problem developed during observation |
| V24 | 2+ waits spike ≥ 150% in same period | Shared root cause across multiple wait types |
| V25 | Spike resolved by next period | Transient event — still investigate root cause |
| V26 | Always (3+ periods) | One-sentence pattern: degrading / stable / spike / improving |
