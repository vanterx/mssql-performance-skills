# SQL Server Trace / Extended Events Checks — Explained for All

A detailed guide to every check the analyser performs on SQL Server Profiler trace output and Extended Events session data.
Each entry explains what the check means, why it matters, how to spot it, real-world examples, and fix options ranked by impact.

---

## Before You Start: Key Concepts

### What is a SQL Server trace?

A **trace** is a recording of SQL Server activity over time. Unlike an execution plan (a snapshot of one query's strategy) or STATISTICS IO (a measurement of one query's I/O), a trace captures thousands of events from many queries, many sessions, across a time window. This makes it the primary tool for workload-level analysis.

Two mechanisms exist:

**SQL Server Profiler / `.trc` files** (older, GUI-based):
- Captures events as rows in a table: query text, timing, I/O counts, session info
- Output saved as `.trc` (binary) or exported as table via `sys.fn_trace_gettable()`
- Still widely used; deprecated in favour of XE but not removed

**Extended Events (XE) / `.xel` files** (modern):
- Lower overhead than Profiler
- More flexible event and field selection
- Output saved as `.xel` (binary) or queried live via `sys.dm_xe_session_targets`
- The recommended approach for all new diagnostic work

Both produce the same core data: per-event rows with a query, timing, and resource metrics.

### Key columns

| Column (Profiler) | Column (XE) | What it is |
|---|---|---|
| `EventClass` | `event_name` | What type of event this is |
| `TextData` | `sql_text` / `statement` | The SQL query text |
| `Duration` | `duration` | Elapsed time in **microseconds** |
| `CPU` | `cpu_time` | CPU consumed in **milliseconds** |
| `Reads` | `logical_reads` | Logical page reads from buffer pool |
| `Writes` | `writes` | Pages written (tempdb spill or DML) |
| `SPID` | `session_id` | Session that ran the query |
| `ApplicationName` | `client_app_name` | Application that connected |
| `StartTime` | `timestamp` | When the event started |

### Duration vs CPU

**Duration** = wall-clock time from start to end (in microseconds in `.trc` and XE).
**CPU** = processor time consumed (in milliseconds).

`CPU << Duration`: the query spent most of its time waiting (I/O, locks, network) — not computing.
`CPU ≈ Duration`: single-threaded, CPU-bound query.
`CPU >> Duration`: parallel query — CPU is the sum across all threads.

### Query normalization

Raw trace output has one row per execution. The same stored procedure called 10,000 times with different parameters produces 10,000 rows. To identify the pattern, normalize: replace all literal values (`42`, `'Smith'`, `'2024-01-01'`) with a placeholder (`?`) and group by the normalized text. This is how you identify "the same query" across executions.

### What `Writes` means for SELECT queries

SELECT queries should not write pages. If a SELECT has `Writes > 0`, SQL Server created a worktable or workfile in `tempdb` — a sort or hash join spilled to disk because it exceeded its memory grant. This is the same spill detected by Sort Warning (X9) and Hash Warning (X10) events.

---

## Event-Level Checks (X1–X12)

---

### X1 — Long-Duration Query

**What it means**
A single query execution took 5 seconds or more (30 seconds or more for Critical). The Duration column in `.trc` files is in microseconds — divide by 1,000 to get milliseconds.

**Why it matters**
Long-running queries hold resources for extended periods: buffer pool pages, memory grants, and — crucially — row/page locks. A 30-second query holding shared locks blocks any concurrent writer on the same rows for the entire duration. On a busy transactional system, this cascades to blocking chains.

**How to spot it**
```
EventClass  TextData                                          CPU    Reads   Duration
12          SELECT * FROM dbo.Orders WHERE CustomerId=42     156    48291   142800000
```
Duration 142,800,000 µs = 142,800 ms = 142.8 seconds → Critical (≥ 30,000 ms)

**Example — problem**
```sql
-- Full table scan: no index on CustomerId
SELECT * FROM dbo.Orders WHERE CustomerId = 42;
-- Duration: 142,800 ms (full scan of 10M-row table)
```

**Example — fix**
```sql
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId)
INCLUDE (OrderDate, TotalAmount, Status);
-- After: Duration: 8 ms
```

**Fix options (ranked by impact)**
1. Add a covering index — eliminates the scan driving long duration.
2. Run `/sqlplan-review` to find the dominant operator; run `/sqlplan-index-advisor` for DDL.
3. If `CPU << Duration` (waiting, not computing): investigate lock blocking or I/O waits rather than the query plan.
4. Set a query timeout as a safety net: only after optimizing, not instead of.

**Related checks:** X2 (high CPU), X3 (high reads), X5 (attention/timeout), X14 (duration variance)

---

### X2 — High CPU Query

**What it means**
A single query execution consumed ≥ 5,000 ms of CPU time. This means the query kept processor cores busy for at least 5 seconds of compute time.

**Why it matters**
A query consuming 60 seconds of CPU on a 4-core server monopolizes all cores for 15 seconds of wall time. This reduces throughput for every concurrent session on the server. High CPU consistently correlates with: full table/index scans, large hash joins, large sorts, or implicit type conversions applied to every row.

**How to spot it**
```
EventClass  TextData                                 CPU      Reads    Duration
12          SELECT SUM(LineTotal) FROM OrderLines    84200    2568900  12100000
```
CPU 84,200 ms → triggers X2 (≥ 5,000 ms)

**Example — problem**
```sql
-- No index on Status; full scan computes SUM across all rows
SELECT SUM(LineTotal) FROM dbo.OrderLines WHERE Status = 'Open';
-- CPU: 84,200 ms (scanning 50M rows)
```

**Example — fix**
```sql
CREATE NONCLUSTERED INDEX IX_OrderLines_Status_LineTotal
ON dbo.OrderLines (Status) INCLUDE (LineTotal);
-- After: CPU: 42 ms (index seek, 1,200 rows)
```

**Fix options**
1. Add an index to eliminate the scan driving CPU consumption.
2. Use `/sqlplan-review` to identify the high-CPU operator (N4 Expensive Scan, N18 Hash Match, N20 Sort).
3. If `CPU > 1.5 × Duration` (parallel): check for thread skew — check N30 in `/sqlplan-review`.

**Related checks:** X1 (long duration), X3 (high reads), X9 (sort warning), X10 (hash warning)

---

### X3 — High Logical Reads Query

**What it means**
A single query execution read ≥ 100,000 pages from the buffer pool. Each page is 8 KB: 100,000 reads = 800 MB of data accessed; 1,000,000 reads = 8 GB.

**Why it matters**
Even though logical reads are served from RAM (fast), they are not free: they consume CPU cycles for buffer pool latch acquisition, displace other queries' pages from cache, and indicate the query is reading far more data than necessary.

**How to spot it**
```
EventClass  TextData                              CPU   Reads     Duration
12          SELECT * FROM dbo.Products WHERE...   312   1204180   284000
```
Reads 1,204,180 → Critical (≥ 1,000,000)

**Fix options**
1. Run `/sqlstats-review` on this query's STATISTICS IO output to identify which table has the most reads.
2. Run `/sqlplan-index-advisor` for covering index recommendations.
3. Check X13 — if this query runs 1,000+ times, reads compound: 1,000 × 1,200 reads = 1.2 B total reads per trace window.

**Related checks:** X1 (duration), X2 (CPU), X4 (writes), X13 (frequency)

---

### X4 — High Write Count

**What it means**
A single query execution wrote ≥ 10,000 pages. For SELECT queries, writes indicate a tempdb spill (worktable/workfile). For DML queries (INSERT, UPDATE, DELETE, MERGE), writes indicate the volume of data modified.

**Why it matters**
- **SELECT with writes**: a spill — the query is doing I/O to tempdb mid-execution, dramatically slowing it (X9, X10).
- **DML with writes**: fills the transaction log proportionally, holds locks for the transaction duration, and must be replicated to any subscribers.

**How to spot it**
```
EventClass  TextData                              CPU   Reads   Writes  Duration
12          SELECT * FROM dbo.OrderLines...       8420  182140  45280   24000000
```
Writes 45,280 on a SELECT → tempdb spill (worktable created)

**Fix options**
1. For SELECT writes: update statistics, add indexes to reduce input row count to hash/sort operators. See X9, X10.
2. For DML writes: verify the WHERE clause filters appropriately (`/tsql-review` T2). Consider batching large DML.

**Related checks:** X9 (sort warning), X10 (hash warning), X1 (duration)

---

### X5 — Attention Event (Client Timeout or Cancel)

**What it means**
An `Attention` event fires when a client disconnects or cancels a query mid-execution. SQL Server rolls back any open transaction and abandons the query. The query was running long enough for the client's timeout to expire, or the user manually cancelled it.

**Why it matters**
Attention events are wasted work: SQL Server ran the query for N seconds, consuming CPU, reads, and locks — then discarded all of it. If attention events are frequent, they also generate rollback activity that adds further load.

**How to spot it**
```
EventClass  TextData                              SPID  Duration
16          (Attention)                           51    30000000
12          SELECT * FROM dbo.Reports WHERE...    51    29998000
```
The preceding completed (or uncompleted) query for SPID 51 took 30 seconds before the attention fired.

**Fix options**
1. Optimize the query so it completes within the client timeout — use X1 fixes.
2. Increase the client timeout only after optimizing, and only if the long duration is genuinely expected (e.g., a batch report).
3. Track which application is sending the most attention events (`ApplicationName` column) — it may have a misconfigured timeout.

**Related checks:** X1 (long duration), X6 (lock timeout)

---

### X6 — Lock Timeout Event

**What it means**
A session waited for a lock and the wait exceeded the `SET LOCK_TIMEOUT` value for that session. SQL Server returned error 1222 to the application without killing the session (unlike a deadlock, where error 1205 terminates one session).

**Why it matters**
Lock timeouts indicate contention — sessions are blocking each other. Frequent lock timeouts mean the application is competing for the same locked resources and losing. Unreported lock timeouts silently return errors that the application may retry (amplifying the contention) or swallow (causing data inconsistency).

**How to spot it**
```
EventClass  TextData              SPID  Duration
54          (Lock:Timeout)        72    5000000
```

**Common causes and fixes**

| Cause | Fix |
|-------|-----|
| Missing index → long scan holds shared locks | Add index to reduce scan duration |
| Long-running transaction holds exclusive lock | Commit transactions sooner; move work outside the transaction |
| High contention on hotspot row | Consider row-level vs page-level locking; re-architect hot row access |
| READ COMMITTED default causing reader/writer contention | Enable READ_COMMITTED_SNAPSHOT isolation at database level |

**Related checks:** X5 (attention), X8 (errors), `/sqlplan-deadlock` if deadlock events also present

---

### X7 — Recompile Event

**What it means**
SQL Server discarded a cached execution plan and recompiled the query or stored procedure. Each recompile acquires a schema stability lock, consumes CPU for optimization, and briefly blocks other sessions that need the same schema lock.

**Why it matters**
Recompiles are expensive on hot paths — a procedure called 10,000 times/minute that recompiles on 10% of calls is recompiling 1,000 times/minute. Each recompile takes CPU away from actual query execution. This check fires when the same object recompiles 3 or more times within the trace window.

**How to spot it**
```
EventClass  ObjectName          EventSubClass           SPID
37          dbo.GetOrders       Statistics Changed       51
37          dbo.GetOrders       Statistics Changed       82
37          dbo.GetOrders       Statistics Changed       104
```
Three recompiles of `dbo.GetOrders` → triggers X7

**Common recompile causes (`EventSubClass`)**

| SubClass | Cause | Fix |
|----------|-------|-----|
| Schema Changed | DDL on referenced object | Avoid DDL on hot objects during production hours |
| Statistics Changed | Auto-stats update triggered | Use `OPTION(KEEP PLAN)` or `OPTION(KEEPFIXED PLAN)` |
| Deferred Compile | Object didn't exist at compile time | Create temp tables before the procedure references them |
| SET Option Changed | Connection has different SET options | Standardize SET options across all connections |
| Forced Recompile | `OPTION(RECOMPILE)` in query | Only use on high-variance queries (see `/tsql-review` T28) |

**Related checks:** X16 (global recompile rate), X14 (parameter sniffing)

---

### X8 — Exception / Error Event

**What it means**
SQL Server raised an error during the trace window. Severity < 20: application-level errors (constraint violations, deadlock victims, row not found). Severity ≥ 20: fatal errors (out of memory, hardware failure, data corruption) that terminate the connection.

**How to spot it**
```
EventClass  TextData                                    Error  Severity
33          Transaction (Process ID 51) was deadlocked  1205   13
33          Violation of UNIQUE KEY constraint          2627   14
33          Fatal error 823 occurred                    823    24
```

**Fix options**
1. **Error 1205 (deadlock victim)**: extract the deadlock XML and run `/sqlplan-deadlock`.
2. **Error 2627 / 2601 (duplicate key)**: the application is inserting duplicates — use `INSERT ... WHERE NOT EXISTS` or handle the error in the application.
3. **Error 547 (FK violation)**: application is violating referential integrity — review DML ordering.
4. **Severity ≥ 20**: escalate immediately — these indicate server-level problems.

**Related checks:** X5 (attention), X6 (lock timeout), `/sqlplan-deadlock`

---

### X9 — Sort Warning Event

**What it means**
A Sort operator ran out of its allocated memory and spilled intermediate data to tempdb. SQL Server writes sorted partial runs to disk and merges them — this is called an **external merge sort**. Each spill level (1 = single-pass, 2 = multi-pass) is progressively more expensive.

**Why it matters**
A sort spill on a large dataset converts an in-memory sort (fast) into a disk I/O operation (slow). A Level 2 spill (multiple merge passes) can be 10–100× slower than a non-spilling sort. Spills also consume tempdb space and can interfere with other queries using tempdb.

**How to spot it**
```
EventClass  TextData                   EventSubClass
69          (Sort Warnings)            Single Pass      ← Level 1 spill
69          (Sort Warnings)            Multiple Passes  ← Level 2 spill (worse)
```

**Fix options (ranked by impact)**
1. **Update statistics** — stale stats produce bad row estimates → wrong memory grant → spill.
2. **Add an index** that pre-orders the data, eliminating the Sort operator entirely.
3. **Reduce input rows** to the sort (filter earlier, narrow result set).
4. **Increase the memory grant**: `OPTION (MIN_GRANT_PERCENT = 25)` to request at least 25% of total server memory.

**Related checks:** X4 (high writes), X10 (hash warning), `/sqlplan-review` N41–N43

---

### X10 — Hash Warning Event (Bailout or Recursion)

**What it means**
A Hash Match operator (used for hash joins or hash aggregates) ran out of memory. SQL Server either **bailed out** (abandoned the hash strategy and switched to a slower approach) or **recursed** (partitioned the data into multiple smaller hash tables on disk).

**Why it matters**
Hash bailout drastically changes the join algorithm mid-execution. Recursive hash operations write multiple partition files to tempdb. Both result in dramatically longer execution times for the affected query.

**How to spot it**
```
EventClass  TextData              EventSubClass
65          (Hash Warning)        Bailout    ← abandoned hash, fell back
65          (Hash Warning)        Recursion  ← recursive disk partitioning
```

**Fix options**
1. **Update statistics** — same root cause as X9 (wrong row estimate → wrong memory grant).
2. **Add an index on the join column** — may allow the optimizer to choose a Merge Join (requires pre-sorted input, no memory grant) instead of a Hash Match.
3. **Reduce input rows** to the hash build side.
4. **Increase the memory grant** with a query hint.

**Related checks:** X4 (high writes), X9 (sort warning), `/sqlplan-review` N41, N18

---

### X11 — Missing Column Statistics Event

**What it means**
The query optimizer needed a statistics object for a column to estimate row counts but found none. It used a default guess (usually 10% selectivity) instead. Bad estimates lead to bad plan choices.

**Why it matters**
Missing statistics is the root cause of many "bad plan" problems. If the optimizer guesses 100 rows but actually receives 1,000,000 rows, it may choose Nested Loops (good for 100) that become catastrophically slow for 1,000,000.

**How to spot it**
```
EventClass  TextData                     ObjectName          ColumnName
79          (Missing Column Statistics)  dbo.Orders          RegionCode
```

**Fix options**
1. **Create statistics manually**: `CREATE STATISTICS stat_Orders_RegionCode ON dbo.Orders (RegionCode) WITH FULLSCAN`
2. **Verify auto-create statistics is enabled**: `SELECT is_auto_create_stats_on FROM sys.databases WHERE name = 'YourDb'` — should be 1.
3. **Create an index on the column** — index creation automatically creates statistics.

**Related checks:** X14 (parameter sniffing), X7 (recompile), `/sqlplan-review` N21 (bad row estimate)

---

### X12 — Missing Join Predicate Event

**What it means**
SQL Server detected a Cartesian product — a join with no ON condition, or a FROM clause with multiple tables separated by commas but no WHERE join condition. Every row from the left input is combined with every row from the right input.

**Why it matters**
A Cartesian product of a 10,000-row table and a 5,000-row table produces 50,000,000 rows. This is almost always accidental — a forgotten JOIN condition or a typo in the FROM clause.

**How to spot it**
```
EventClass  TextData
80          (Missing Join Predicate)
12          SELECT a.ProductId, b.RegionId FROM dbo.Products a, dbo.Regions b
```

**Fix options**
1. Add the missing JOIN condition: `FROM dbo.Products a INNER JOIN dbo.Regions r ON a.RegionId = r.RegionId`
2. If a Cartesian product is intentional (generating a grid), document it with a comment and use `CROSS JOIN` explicitly (see `/tsql-review` T10).

**Related checks:** `/tsql-review` T10 (CROSS JOIN without comment)

---

## Workload-Level Checks (X13–X20)

---

### X13 — High-Frequency Query (N+1 Signal)

**What it means**
The same logical query (normalized) executed ≥ 1,000 times within the trace window. The name "N+1" comes from the classic ORM anti-pattern: fetch N parent rows, then issue 1 query per row to get related data — producing N+1 total queries.

**Why it matters**
1,000 executions × 50 ms each = 50 seconds of serial latency per cycle. Even 1,000 × 1 ms = 1 second per cycle — and in a web application processing multiple requests concurrently, thousands of round trips per second saturate the network and connection pool. The fix — batching — often eliminates 99% of the queries.

**How to spot it**
```
Normalized query: SELECT OrderId, Total FROM dbo.Orders WHERE CustomerId = ?
Executions: 48,291  |  Avg CPU: 2 ms  |  Avg Reads: 84  |  Avg Duration: 3 ms
```
48,291 executions → triggers X13 (≥ 1,000)

**Example — problem (ORM N+1)**
```csharp
var customers = db.Customers.ToList();           // 1 query: all customers
foreach (var customer in customers)
{
    var orders = db.Orders                       // N queries: one per customer
                   .Where(o => o.CustomerId == customer.Id)
                   .ToList();
}
// Total: 1 + N queries
```

**Example — fix**
```csharp
// Single query with JOIN — 1 query total
var data = db.Customers
             .Include(c => c.Orders)
             .ToList();
```

**Or in SQL:**
```sql
-- Replace N+1 with one set-based query
SELECT c.CustomerId, c.Name, o.OrderId, o.Total
FROM dbo.Customers c
LEFT JOIN dbo.Orders o ON o.CustomerId = c.CustomerId;
```

**Fix options**
1. **JOIN-based query** — replaces N queries with 1.
2. **Table-Valued Parameter** — batch the lookup keys into one query: `WHERE CustomerId IN (SELECT Id FROM @customerIds)`.
3. **Caching** — if the data is static, cache it application-side and eliminate the queries entirely.

**Related checks:** X1 (duration), X3 (reads), X14 (duration variance)

---

### X14 — Parameter Sniffing Signal (High Duration Variance)

**What it means**
The same normalized query has wildly inconsistent execution times across calls — some fast, some slow. When SQL Server first compiles a parameterized query or stored procedure, it creates a plan optimized for the parameter values seen on that first call. If those values are unrepresentative (e.g., the first call used a rare `CustomerId` with 2 orders, but most calls use a `CustomerId` with 50,000 orders), the cached plan is wrong for most callers.

**Why it matters**
A plan sniffed on a rare "small" parameter value uses Nested Loops (correct for 2 rows, catastrophically wrong for 50,000 rows). All subsequent calls get the Nested Loops plan regardless of their actual parameter values.

**How to spot it**
```
Normalized query: EXEC dbo.GetCustomerOrders @customerId = ?
Executions: 12,841  |  Avg Duration: 45 ms  |  Min: 1 ms  |  Max: 142,800 ms
```
Max / Min = 142,800 — triggers X14 (> 10×, ≥ 10 executions)

**Confirming parameter sniffing vs other variance causes:**
- Run the slow call and fast call through `/sqlplan-review` separately
- Use `/sqlplan-compare` to diff the two plans — if they differ structurally (different join types), sniffing is confirmed
- If the plans are identical but durations differ, the variance is data-driven (blocking, I/O cold cache) not sniffing

**Fix options (ranked by impact)**
1. `OPTION(RECOMPILE)` on the query — per-execution plan eliminates sniffing. Cost: ~1–5 ms compile per call.
2. `OPTION(OPTIMIZE FOR (@param = typical_value))` — pin a representative plan.
3. `OPTION(OPTIMIZE FOR UNKNOWN)` — disable sniffing entirely; uses average selectivity.
4. Use Query Store to force the good plan: `EXEC sp_query_store_force_plan`.
5. Separate procedures for high/low cardinality callers.

**Related checks:** X7 (recompile), X11 (missing statistics), X1 (duration), `/sqlplan-compare`

---

### X15 — Ad-Hoc / Unparameterized Workload

**What it means**
The application is sending queries with literal values embedded in the SQL text, rather than using parameterized queries or stored procedures. Each unique literal produces a unique plan cache entry.

**Why it matters**
Plan cache pollution: 10,000 unique `WHERE Id = N` queries fill the plan cache with 10,000 single-use plans. SQL Server constantly evicts useful cached plans to make room. The cache churns, compilation overhead rises, and the effective cache hit rate collapses. On servers with heavy ad-hoc workloads, this can consume several GB of `CACHESTORE_SQLCP` memory.

**How to spot it**
```
SELECT * FROM dbo.Orders WHERE CustomerId = 1842    -- unique plan
SELECT * FROM dbo.Orders WHERE CustomerId = 9314    -- unique plan
SELECT * FROM dbo.Orders WHERE CustomerId = 22      -- unique plan
-- Each is a distinct cache entry
```

Versus parameterized (one plan shared by all):
```sql
SELECT * FROM dbo.Orders WHERE CustomerId = @customerId
```

**Fix options**
1. **Fix the application** — use parameterized queries (`sp_executesql` with `@params`), ORM parameterization, or stored procedures.
2. **Short-term mitigation**: enable "optimize for ad hoc workloads": `EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE` — stores only a plan stub on first execution, reducing cache bloat.
3. **Forced parameterization**: `ALTER DATABASE YourDb SET PARAMETERIZATION FORCED` — SQL Server auto-parameterizes simple queries. Use with caution — may cause plan quality issues for queries that should not be parameterized.

**Related checks:** X13 (high frequency), X7 (recompile)

---

### X16 — Excessive Global Recompilations

**What it means**
Across the entire trace, recompile events constitute more than 5% of total completed query events. This is a server-wide recompile pressure signal, not a single-object issue (see X7 for single-object recompile).

**Why it matters**
Each recompile acquires a schema stability (Sch-S) lock on referenced objects. While this lock is held, DDL on those objects (Sch-M lock) is blocked. In extreme cases, high recompile rates cause cascading blocking. Recompile CPU also reduces throughput for actual query work.

**How to spot it**
```
Total SQL:BatchCompleted + RPC:Completed events: 42,000
Total SP:Recompile + SQL:StmtRecompile events:    3,800
Recompile ratio: 3,800 / 42,000 = 9.0% → triggers X16 (> 5%)
```

**Fix options**
1. Identify the most-recompiled objects: `SELECT TOP 20 ObjectName, COUNT(*) FROM trace GROUP BY ObjectName ORDER BY 2 DESC`
2. Investigate recompile sub-class (schema change, statistics, deferred compile) — see X7 fix table.
3. Standardize SET options across all connections — SET option mismatches are a common cause of widespread recompilation.
4. Use `OPTION(KEEP PLAN)` on queries that recompile due to statistics changes on temp tables.

**Related checks:** X7 (per-object recompile), X15 (ad-hoc workload)

---

### X17 — Top Resource Consumers Summary

**What it means**
This check always fires — it produces the top-5 queries by total CPU, total logical reads, and max duration. It is the primary output that guides where to focus tuning effort.

**Why it matters**
On a busy server, hundreds of distinct queries may appear in a trace. Without ranking, there is no clear starting point. The top-5 by CPU almost always accounts for 60–90% of total server CPU — fixing these queries has the highest marginal impact.

**How to spot it**
This check always fires — there is no threshold to trigger it. It aggregates all completed query events.

**Output (produced by this check):**

```
By Total CPU (top 5):
#1  EXEC dbo.GetReportSummary   — 8,420 exec × avg 18,200 ms CPU = 153 M ms total (41.2%)
#2  SELECT * FROM dbo.OrderLines — 1,284 exec × avg 84,200 ms CPU = 108 M ms total (29.1%)
...

By Total Logical Reads (top 5):
#1  SELECT * FROM dbo.OrderLines — 1,284 exec × avg 2,568,900 reads = 3.3 B total reads
...

By Max Duration (top 5):
#1  EXEC dbo.MonthlyReport       — 1 exec, 284,906 ms (4m 44s)
...
```

**Fix options**
1. Run `/sqlplan-review` on the #1 query by CPU.
2. Run `/sqlplan-index-advisor` on the #1 query by reads.
3. If the #1 query by max duration is a reporting job, schedule it off-peak.

**Related checks:** X18 (workload concentration), X1, X2, X3

---

### X18 — Workload Concentration (Few Queries Dominate)

**What it means**
The top 3 normalized query patterns account for more than 80% of total CPU time across all events. The workload is highly concentrated.

**Why it matters**
This is good news for tuning: if 3 queries own 80% of CPU, fixing those 3 queries improves the server for everyone. A diffuse workload (100 queries each at 1%) is much harder to tune. Concentration means maximum leverage.

**How to spot it**
```
#1 query: 42.1% of CPU
#2 query: 29.0% of CPU
#3 query: 11.8% of CPU
─────────────────────
Top 3 total: 82.9% → triggers X18
```

**No fix required** — this check is informational. Note the concentration and report it as a positive finding for prioritization.

**Related checks:** X17 (top consumers)

---

### X19 — Auto-Grow Event Detected

**What it means**
SQL Server expanded a data file or transaction log file automatically during the trace window. Auto-grow is a safety net, not a normal operating mode: while a file grows, SQL Server pauses all activity on that database until the grow completes.

**Why it matters**
- **Data file auto-grow**: if instant file initialization is not enabled (Windows privilege `SE_MANAGE_VOLUME_NAME` for the SQL Server service account), data file growth zeros out the new space — pausing the database for seconds to minutes per grow.
- **Log file auto-grow**: always requires log file zeroing. Frequent log grows indicate the log backup frequency is too low, or a large transaction is generating excessive log.

**How to spot it**
```
EventClass  ObjectName        FileName            Duration
92          YourDatabase      C:\Data\YourDb.mdf  8420000   ← data file grew, 8.4 seconds
93          YourDatabase      E:\Log\YourDb.ldf   2100000   ← log file grew, 2.1 seconds
```

**Fix options**
1. **Pre-size the data file** to its expected maximum (eliminates grows entirely for known workloads).
2. **Enable instant file initialization** for the SQL Server service account — eliminates zeroing overhead for data files (not log files).
3. **Increase log backup frequency** to keep log space available — shrink-then-grow cycles are expensive; instead keep the log backing up so space is reused.
4. **Investigate large transactions** if log file grows are frequent — identify uncommitted transactions with `sys.dm_tran_active_transactions`.

**Related checks:** X4 (high writes)

---

### X20 — ShowPlan XML Events Present in Trace

**What it means**
The trace captured inline execution plan XML — the same data as a `.sqlplan` file — for queries executed during the trace window. Class 146 (`Showplan XML`) or XE `query_post_execution_showplan` captures the actual plan after each execution.

**Why it matters**
Having the execution plan inline with the trace metrics is the most complete diagnostic available: you can correlate a 142-second query (X1) with its exact operator tree and row estimates without a separate plan capture session. This data should be extracted and fed directly to `/sqlplan-review`.

**How to spot it**
```
EventClass  TextData (XML truncated)          Duration   CPU    Reads
146         <ShowPlanXML ...><StmtSimple...>  142800000  84200  1204180
```

**Fix options**
1. Extract the `TextData` XML for the slowest/highest-reads events and run `/sqlplan-review` on each.
2. Save each plan XML as a `.sqlplan` file and batch them with `/sqlplan-batch`.
3. **Important**: disable Showplan XML capture on production traces after initial diagnosis — it adds ~10–30% overhead to every captured query.

**Related checks:** X1 (duration), X2 (CPU), X3 (reads), `/sqlplan-review`, `/sqlplan-batch`

---

## How to Capture Trace Data

### Method 1 — sys.fn_trace_gettable() (existing .trc file)

```sql
SELECT
    EventClass,
    TextData,
    CPU,
    Reads,
    Writes,
    Duration,
    StartTime,
    EndTime,
    SPID,
    ApplicationName,
    LoginName,
    DatabaseName
FROM sys.fn_trace_gettable('C:\Traces\workload.trc', DEFAULT)
WHERE EventClass IN (10, 12, 16, 37, 50, 54, 65, 69, 79, 80, 92, 93, 146)
ORDER BY StartTime;
```

Export results as CSV or tab-separated and paste into Claude.

### Method 2 — Extended Events session query (live or saved .xel)

```sql
-- Read from a saved .xel file
SELECT
    event_data.value('(event/@name)[1]', 'NVARCHAR(100)') AS event_name,
    event_data.value('(event/data[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'BIGINT') AS duration_us,
    event_data.value('(event/data[@name="cpu_time"]/value)[1]', 'BIGINT') AS cpu_time_us,
    event_data.value('(event/data[@name="logical_reads"]/value)[1]', 'BIGINT') AS logical_reads,
    event_data.value('(event/data[@name="writes"]/value)[1]', 'BIGINT') AS writes,
    event_data.value('(event/@timestamp)[1]', 'DATETIME2') AS event_time
FROM sys.fn_xe_file_target_read_file('C:\XE\workload*.xel', NULL, NULL, NULL)
CROSS APPLY (SELECT CAST(event_data AS XML)) AS ed(event_data)
ORDER BY event_time;
```

### Method 3 — SQL Server Profiler (GUI)

1. SSMS → Tools → SQL Server Profiler
2. File → New Trace → connect to server
3. Use the **TSQL_Duration** template or a custom template selecting: `SQL:BatchCompleted`, `RPC:Completed`, `Attention`, `SP:Recompile`, `SQL:StmtRecompile`, `Lock:Timeout`, `Hash Warning`, `Sort Warnings`, `Missing Column Statistics`
4. Add filters: `Duration >= 1000000` (≥ 1 second, in microseconds) to reduce noise
5. Run → File → Save As → Trace File (`.trc`)
6. Re-open with `sys.fn_trace_gettable()` (Method 1) to query the data

> **Production warning:** SQL Server Profiler with Showplan XML capture adds 10–30% overhead. On production, use Extended Events with server-side filtering instead.

---

## Quick Reference: Checks by Severity

### Critical
| Check | Issue |
|-------|-------|
| X1 | Duration ≥ 30 s |
| X3 | Logical reads ≥ 1 M |
| X8 | Error severity ≥ 20 |

### Warning
| Check | Issue |
|-------|-------|
| X1 | Duration ≥ 5 s |
| X2 | CPU ≥ 5,000 ms |
| X3 | Logical reads ≥ 100 K |
| X4 | Writes ≥ 10,000 pages |
| X5 | Attention event present |
| X6 | Lock timeout present |
| X7 | ≥ 3 recompiles same object |
| X8 | Error severity < 20 |
| X9 | Sort warning present |
| X10 | Hash warning present |
| X12 | Missing join predicate present |
| X13 | ≥ 1,000 executions same query |
| X14 | Max duration > 10× min, same query |
| X16 | Recompiles > 5% of batch events |
| X19 | Auto-grow event present |

### Info
| Check | Issue |
|-------|-------|
| X11 | Missing column statistics |
| X15 | Ad-hoc / unparameterized workload |
| X17 | Top resource consumers (always fires) |
| X18 | Top 3 queries > 80% of CPU |
| X20 | ShowPlan XML events present |
