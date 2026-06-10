# sqlprocstats-review — Checks Explained

## Contents

- [Category 1: Top Resource Consumers (R1–R5)](#category-1-top-resource-consumers-r1r5)
- [Category 2: Per-Execution Efficiency (R6–R10)](#category-2-per-execution-efficiency-r6r10)
- [Category 3: Pattern Detection (R11–R15)](#category-3-pattern-detection-r11r15)
- [Category 4: Trend Analysis (R16–R25)](#category-4-trend-analysis-r16r25)
- [Quick Reference Table](#quick-reference-table)

---


Plain-English explanations for all 25 R-checks. For check trigger conditions and thresholds,
see `SKILL.md`. This file is for human reference only — it is not loaded by the skill.

---

## Category 1: Top Resource Consumers (R1–R5)

### R1 — CPU Hotspot

**What it means**
One stored procedure, trigger, or function is consuming a disproportionate share of the
server's CPU during the collection interval. `cpu_ms_per_sec` tells you how many milliseconds
of CPU time this object consumed per second of wall-clock time during the sample window.
A value of 500 ms/s means the object alone occupied half a CPU core for the entire interval.

**How to spot it**
In the Q1 report, look at the `cpu_ms_per_sec` column. If the top row is ≥ 50, R1 fires.
Also compute: top object's `total_worker_time_delta` / SUM of all `total_worker_time_delta`
in the result. If > 50%, R1 fires even if the absolute rate is below 50 ms/s.

**Example (problem)**
```
object_name          cpu_ms_per_sec   execs_in_interval
usp_GetSalesReport   842.5            18
usp_SyncInventory    12.3             4,210
```
`usp_GetSalesReport` at 842 ms/s = Critical. It runs infrequently (18 times) but each
execution burns enormous CPU.

**Fix options**
1. Run `/sqlplan-review` on the procedure's cached plan to identify the expensive operator.
2. Check for missing indexes (key lookups, full scans) using `/sqlindex-advisor`.
3. If `max_to_avg_cpu_ratio` is high (see R9), add `OPTION (RECOMPILE)` to address sniffing.

**Related checks:** R6, R9, R14

---

### R2 — Read Hotspot

**What it means**
One object is reading a disproportionate number of 8 KB buffer pool pages per second. High
logical reads pressure the buffer pool, evicting other objects' pages and increasing physical
reads (cache misses) for the rest of the workload.

**How to spot it**
In Q1 or Q2, look at `reads_per_sec`. Also compare the object's `total_logical_reads_delta`
to the sum of all reads in the result set.

**Example (problem)**
```
object_name          reads_per_sec   avg_logical_reads
usp_MonthlyReport    48,200          289,000
usp_GetProduct       1.2             72
```
`usp_MonthlyReport` reads 289,000 pages on average per execution at 48,200/s. At 8 KB per
page, each execution touches ~2.2 GB of buffer pool.

**Fix options**
1. Run `/sqlindex-advisor` on the procedure's plan to generate covering index DDL.
2. Check for index scans that could become seeks with proper predicates.
3. If `physical_pct` is high, the data is not cached — add RAM or reduce scan scope.

**Related checks:** R5, R7, R14

---

### R3 — Duration Hotspot

**What it means**
The procedure takes a long time per call, holding database connections open and potentially
blocking dependent code. `avg_elapsed_ms` is wall-clock time — it includes time waiting for
locks, I/O, and CPU, unlike `avg_cpu_ms` which only counts active CPU time.

**How to spot it**
In Q4, look at `avg_elapsed_ms`. If ≥ 5,000 ms for an actively executing object, R3 fires.

**Example (problem)**
```
object_name          avg_elapsed_ms   avg_cpu_ms   execs_in_interval
usp_GenerateReport   28,400           850          3
```
28 seconds per execution, but only 850 ms of CPU — see R8 (CPU-elapsed skew). The other
27 seconds is spent waiting, likely on locks or I/O.

**Fix options**
1. If `avg_elapsed_ms` >> `avg_cpu_ms`: investigate blocking with `/sqlwait-review`.
2. If `avg_elapsed_ms` ≈ `avg_cpu_ms`: the work itself is slow — run `/sqlplan-review`.
3. Consider breaking large procedures into smaller units.

**Related checks:** R8, R6

---

### R4 — Execution Frequency Hotspot

**What it means**
The object was called ≥ 10,000 times in a single collection interval (default 5 minutes =
300 seconds → 33+ calls/sec minimum). Even if each call is cheap, this volume creates
significant plan-cache lookup overhead, lock acquisition pressure, and connection pool load.

**How to spot it**
In Q3, look at `execs_in_interval`. Also check `execs_per_sec` for rate.

**Example (problem)**
```
object_name          execs_in_interval   avg_cpu_ms   avg_logical_reads
usp_GetUserProfile   84,210              0.8          12
```
84,000 calls in 5 minutes = 280/sec. At 12 reads/call, that's 1 million reads/sec total
from this one procedure — reported individually as R2 or as aggregate background noise.

**Fix options**
1. Look for application-layer loops calling this per-record — batch with TVPs.
2. Consider result caching at the application layer (Redis, in-process cache).
3. Evaluate whether the high call rate reflects a design problem (see R11/R12).

**Related checks:** R11, R12

---

### R5 — Physical I/O Hotspot (Cache Miss Rate)

**What it means**
A significant fraction of the object's page reads go to disk rather than being served from
the buffer pool. `physical_pct` = `physical_reads_delta` / `logical_reads_delta` × 100.
A healthy server has physical reads near 0%; > 10% indicates buffer pool pressure.

**How to spot it**
In Q2, look at `physical_reads_delta` and `physical_pct`.

**Example (problem)**
```
object_name          logical_reads_delta   physical_reads_delta   physical_pct
usp_SearchOrders     1,200,000             480,000                40.0
```
40% of page reads go to disk — the working set for this procedure doesn't fit in RAM.

**Fix options**
1. Check available memory: `SELECT physical_memory_in_use_mb FROM sys.dm_os_process_memory`.
2. Add covering indexes to reduce the number of pages read per execution.
3. If the server has insufficient RAM, physical reads will remain high regardless.

**Related checks:** R2, R7

---

## Category 2: Per-Execution Efficiency (R6–R10)

### R6 — High Average CPU per Execution

**What it means**
Each call to this procedure burns ≥ 1,000 ms of CPU on average. This is the per-execution
equivalent of R1. A procedure can have low `cpu_ms_per_sec` (because it runs rarely) while
still having high `avg_cpu_ms` (because each call is expensive).

**How to spot it**
In Q4, sort by `avg_cpu_ms` descending.

**Example (problem)**
```
object_name          avg_cpu_ms   execs_in_interval   cpu_ms_per_sec
usp_YearEndSummary   42,000       2                   0.3
```
42 seconds of CPU per execution. Only runs twice in the interval, so it flies under the R1
radar — but each call is extremely expensive.

**Fix options**
1. Capture the actual execution plan and run `/sqlplan-review`.
2. Look for missing parallelism (S1), sort spills (N6), or full scans (N4).
3. Filter data earlier in the query to reduce the working set.

**Related checks:** R1, R9, R3

---

### R7 — High Average Reads per Execution

**What it means**
Each call reads ≥ 50,000 8-KB buffer pool pages. At 8 KB per page, 50,000 reads = 400 MB
of data touched per execution. This is almost always a missing index problem.

**How to spot it**
In Q4, sort by `avg_logical_reads` descending.

**Example (problem + fix)**
```sql
-- Problem: full clustered index scan
SELECT * FROM Orders WHERE CustomerId = @id AND Status = 'Pending';
-- 180,000 logical reads (scans all 180,000 order rows)

-- Fix: covering index
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_Status
ON dbo.Orders (CustomerId, Status)
INCLUDE (OrderId, CreatedDate, TotalAmount);
-- Reduces to ~15 logical reads (index seek)
```

**Fix options**
1. Run `/sqlindex-advisor` on the procedure's plan XML.
2. Look for Key Lookup operators (N5 in sqlplan-review) — extend the non-clustered index.
3. Verify WHERE clause predicates are sargable (no function wrapping on columns).

**Related checks:** R2, R5, R15

---

### R8 — CPU-Elapsed Skew

**What it means**
The ratio of `avg_cpu_ms` to `avg_elapsed_ms` reveals what the procedure is actually doing:
- **Ratio > 1.5** (CPU > elapsed): parallelism is active but may be poorly utilized (CXPACKET)
- **Ratio < 0.2** (elapsed >> CPU): the procedure spends most of its time waiting, not computing

**How to spot it**
In Q4, look at `cpu_to_elapsed_ratio`.

**Example (blocking signal)**
```
object_name          avg_cpu_ms   avg_elapsed_ms   cpu_to_elapsed_ratio
usp_ProcessPayment   45           8,200            0.005
```
45 ms of CPU but 8.2 seconds elapsed = 99.5% of time waiting. Almost certainly blocked on
a lock. The payment procedure is waiting for another transaction to release a resource.

**Example (parallel waste signal)**
```
object_name          avg_cpu_ms   avg_elapsed_ms   cpu_to_elapsed_ratio
usp_AnalyticsReport  24,000       4,200            5.7
```
CPU > elapsed × 5 means 5+ threads are active. But check: is the speedup proportional?
24 seconds of CPU compressed into 4.2 seconds = 5.7× speedup, which is reasonable for
DOP 8. If DOP is 8 but speedup is only 2×, investigate CXPACKET waits (see R1/N27).

**Fix options (blocking):** `/sqlwait-review` to identify the wait type, then `/sqldeadlock-review` if applicable.
**Fix options (parallel waste):** `/sqlplan-review` → check N27 (thread skew) and S8 (ineffective parallelism).

**Related checks:** R3, R1

---

### R9 — Max vs Average CPU Skew (Parameter Sniffing Signal)

**What it means**
`max_to_avg_cpu_ratio` = `max_cpu_ms` / `avg_cpu_ms`. A ratio ≥ 10 means the worst single
execution used 10× the average CPU. This is the signature of parameter sniffing: the plan
was compiled for a "cheap" parameter set, but some executions use a "expensive" parameter
set that makes the compiled plan catastrophically wrong.

**How to spot it**
In Q4, look at `max_to_avg_cpu_ratio`. Also compare `max_cpu_ms` to `avg_cpu_ms`.

**Example (problem + fix)**
```
object_name          avg_cpu_ms   max_cpu_ms   max_to_avg_cpu_ratio
usp_SearchCustomers  12           148,000      12,333
```
Average call takes 12 ms. But one execution took 148 seconds. The plan was compiled for
a parameter that returns 1 row (fast nested loops), but someone passed a parameter that
returns 2 million rows (nested loops × 2M = catastrophic).

```sql
-- Fix option 1: recompile per execution
CREATE PROCEDURE dbo.usp_SearchCustomers @Status nvarchar(20)
WITH RECOMPILE   -- or add OPTION (RECOMPILE) to the problem statement
AS ...

-- Fix option 2: optimize for typical value
SELECT ... OPTION (OPTIMIZE FOR (@Status = 'Active'));

-- Fix option 3: local variable (breaks sniffing, uses average density)
DECLARE @LocalStatus nvarchar(20) = @Status;
SELECT ... WHERE Status = @LocalStatus;
```

**Related checks:** R1, R6, R16

---

### R10 — High Spills per Execution

**What it means**
`avg_spills` is the average number of TempDb page spills per execution. A spill occurs when
SQL Server allocates more memory for a sort or hash operation than the optimizer expected,
causing intermediate data to overflow to TempDb. This dramatically slows the operation and
creates I/O pressure on TempDb.

**How to spot it**
In Q4, look at `avg_spills`. NULL means SQL Server 2016 (spill tracking not available).

**Example (problem)**
```
object_name       avg_spills   avg_cpu_ms   avg_logical_reads
usp_MonthlyRpt    14.2         18,400       92,000
```
14 TempDb spills per execution on average. This procedure almost certainly has bad row
estimates causing undersized memory grants.

**Fix options**
1. Run `/sqlplan-review` — look for N6 (sort spill risk), N7 (hash spill risk), S18 (insufficient grant).
2. Update statistics with FULLSCAN on the tables the procedure reads.
3. Add `OPTION (RECOMPILE)` to get a per-execution memory grant.

**Related checks:** R6, R9

---

## Category 3: Pattern Detection (R11–R15)

### R11 — N+1 Caller Pattern

**What it means**
A procedure with high `execs_in_interval`, very low `avg_logical_reads` (< 100), and very
low `avg_cpu_ms` (< 10 ms) is the telltale signature of an N+1 query pattern: application
code that fetches a list of N items, then calls a procedure N times to look up each item
individually.

**How to spot it**
In Q3, look for rows with high `execs_in_interval` but `avg_logical_reads` < 100 and
`avg_cpu_ms` < 10.

**Example (problem + fix)**
```csharp
// Application code (N+1 — bad):
var orders = db.GetOrders(); // returns 10,000 orders
foreach (var o in orders)
    var customer = db.GetCustomer(o.CustomerId); // calls usp_GetCustomer 10,000 times
```

```sql
-- Fix: batch lookup with TVP
CREATE TYPE dbo.IdList AS TABLE (Id int NOT NULL PRIMARY KEY);

CREATE PROCEDURE dbo.usp_GetCustomersBatch @Ids dbo.IdList READONLY
AS
    SELECT c.* FROM dbo.Customers c JOIN @Ids i ON c.Id = i.Id;
```

**Related checks:** R4, R12

---

### R12 — Chatty High-Frequency Procedure

**What it means**
`execs_per_sec` ≥ 10 means the procedure fires at least 10 times every second continuously.
Even at 1 ms per call, 10/sec = 600 executions/minute = every single execution acquires
and releases shared locks, checks permissions, and looks up the plan cache.

**How to spot it**
In Q3, look at `execs_per_sec`.

**Example (problem)**
```
object_name          execs_per_sec   avg_cpu_ms   avg_logical_reads
usp_GetSessionStatus  84.2           0.4          3
```
84 calls/second. At 3 reads each, that's 252 reads/sec from this one procedure. Cheap
individually, but at scale this is scheduling overhead.

**Fix options**
1. Batch N calls into one using TVPs or JSON parameter arrays.
2. Cache results at the application tier (session state, Redis) if the data changes rarely.
3. Investigate whether the high call rate reflects a missing set-based operation.

**Related checks:** R11, R4

---

### R13 — Plan Instability / Frequent Recompile Signal

**What it means**
When multiple rows in the result share the same object name but have different `plan_handle`
values, the procedure's plan is being replaced frequently. Short `cache_age_minutes` (< 60)
on any of those plans confirms the churn. Each recompile costs CPU and may produce a
suboptimal plan.

**How to spot it**
Group the result by `database_name` + `object_name` and count distinct `plan_handle` values.
If > 1 AND min(`cache_age_minutes`) < 60, R13 fires.

**Example (problem)**
```
object_name       plan_handle    cache_age_minutes
usp_GetOrders     0xABCD...      2
usp_GetOrders     0x1234...      47
usp_GetOrders     0x9876...      8
```
Three plans, two under 10 minutes old. The procedure is recompiling every few minutes.

**Fix options**
1. Identify the recompile reason: `EXEC sys.sp_recompile N'dbo.usp_GetOrders';` followed by
   Extended Events session capturing `sql_statement_recompile`.
2. Common causes: `WITH RECOMPILE`, SET option mismatches (ARITHABORT between app and SSMS),
   statistics updates, schema changes, or temp table DDL inside the procedure.
3. If intentional (parameter sniffing fix), document the recompile reason in the procedure header.

**Related checks:** R20, R9

---

### R14 — Workload Concentration

**What it means**
When the top 1 or top 3 procedures account for a large share of total CPU in the result,
the workload is concentrated. This is informational — it tells you where to focus tuning
effort (high leverage) and highlights fragility (if the top procedure degrades, the whole
server degrades).

**How to spot it**
Compute: top object's `total_worker_time_delta` / SUM of all `total_worker_time_delta`.

**Example**
```
Top 3 procedures share of total CPU delta: 94%
Top 1 procedure share: 71%
```
Tuning the top procedure alone will resolve 71% of the server's CPU consumption.

**Fix options**
No fix required — this is a prioritization signal. Focus R1/R6/R9 remediation on the top
objects. For resilience, consider read-scale (read replicas, caching) for the top consumers.

**Related checks:** R1, R2

---

### R15 — Infrequent but Expensive

**What it means**
An object that runs rarely (`execs_in_interval` ≤ 5) but reads ≥ 100,000 pages per call
does not show up as a top consumer in R1/R2 during the collection window — but represents
a latent performance problem. The next time it runs during peak hours, it could cause a
major buffer pool disruption.

**How to spot it**
In Q4, filter for `execs_in_interval` ≤ 5 AND `avg_logical_reads` ≥ 100,000.

**Example**
```
object_name            execs_in_interval   avg_logical_reads   avg_elapsed_ms
usp_AnnualSalesReport  1                   1,240,000           284,000
```
Ran once, read ~10 GB of buffer pool, took 4.7 minutes. A full index scan on a large table.

**Fix options**
1. Add covering indexes to eliminate the scan.
2. Schedule during off-peak hours with Resource Governor to limit CPU/memory impact.
3. Consider materializing the report data incrementally rather than scanning live tables.

**Related checks:** R2, R7

---

## Category 4: Trend Analysis (R16–R25)

### R16 — Worsening CPU Trend

**What it means**
`avg_cpu_ms` or `cpu_ms_per_sec` increases monotonically across 3+ consecutive snapshots
for the same object. This indicates progressive degradation — the procedure is getting slower
over time, not just varying with load.

**How to spot it**
In Q5 output, for each object, plot `avg_cpu_ms` by `collection_time`. Monotonic increase
across ≥ 3 rows = R16 fires.

**Example**
```
collection_time      object_name     avg_cpu_ms
08:00:00             usp_GetOrders   280
08:05:00             usp_GetOrders   410
08:10:00             usp_GetOrders   640
08:15:00             usp_GetOrders   980
```
Doubling every interval — a runaway growth pattern.

**Fix options**
1. Check for data growth: `SELECT SUM(row_count) FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('dbo.Orders')`.
2. Check for statistics staleness: `EXEC sys.sp_updatestats;` or `UPDATE STATISTICS dbo.Orders WITH FULLSCAN;`.
3. Capture a plan at the latest snapshot and compare to an earlier one with `/sqlplan-compare`.

**Related checks:** R9, R18, R20

---

### R17 — Execution Rate Spike

**What it means**
The most recent snapshot shows `execs_in_interval` more than 2× the mean of prior snapshots.
A sudden execution surge — not a gradual increase — indicates an event: a batch job fired,
an application retry loop started, or a deployment triggered unusual traffic.

**How to spot it**
In Q5 output, compute mean of prior `execs_in_interval` rows, compare to latest.

**Example**
```
collection_time      execs_in_interval
08:00:00             120
08:05:00             115
08:10:00             112
08:15:00             8,402   ← spike (74× mean)
```

**Fix options**
1. Identify the caller: `SELECT * FROM sys.dm_exec_sessions WHERE program_name LIKE '%BatchJob%'`.
2. Check application logs for errors at 08:10 — retry loops often cause spikes.
3. If a legitimate batch job, schedule it during off-peak or throttle with Resource Governor.

**Related checks:** R12, R4

---

### R18 — Read Regression

**What it means**
`avg_logical_reads` increases by > 50% between the oldest and newest snapshot for the same
object. This means the procedure is reading progressively more data per call — usually
caused by a plan change (new plan reads more pages) or data growth (the same plan now
reads a larger table).

**How to spot it**
In Q5, compare min(`avg_logical_reads`) to max(`avg_logical_reads`) for each object.

**Example**
```
collection_time      avg_logical_reads
08:00:00             1,240
08:05:00             1,255
08:10:00             4,892   ← sudden jump (plan changed)
```
A 4× jump between snapshots = plan regression. Correlate with R20 to check if `plan_handle` changed.

**Fix options**
1. Check if `plan_handle` changed at the same collection_time (see R20).
2. If plan regressed: use Query Store to force the prior good plan.
3. If data grew: rebuild indexes and update statistics, then re-evaluate.

**Related checks:** R20, R16

---

### R19 — New High-Cost Entry

**What it means**
A procedure appears in the monitoring window for the first time (or `cache_age_minutes` is
very short relative to the monitoring window) with high resource usage. New high-cost
entries can indicate: newly deployed procedures, batch jobs that just started, or procedures
that were previously fast but now have a bad plan.

**How to spot it**
In Q5, look for objects where the first `collection_time` in the result is recent AND
`cpu_ms_per_sec` ≥ 50 or `avg_logical_reads` ≥ 50,000.

**Example**
```
first_seen           object_name       cpu_ms_per_sec   avg_logical_reads
08:12:00 (today)     usp_NewFeature    280.4            192,000
```
This procedure just appeared and is immediately a top consumer.

**Fix options**
1. Capture its execution plan immediately (before cache eviction) and run `/sqlplan-review`.
2. Check recent deployment history — was this procedure recently modified?
3. Check Query Store for the first execution time and plan.

**Related checks:** R1, R6

---

### R20 — Plan Instability Signal (Trend)

**What it means**
The same `database_name` + `object_name` shows different `plan_handle` values across
consecutive snapshots in Q5 output. A plan change mid-monitoring window indicates a
recompile event — which may or may not have produced a worse plan. Correlate with R18
(reads changed) and R16 (CPU changed) to determine if the new plan is better or worse.

**How to spot it**
In Q5, group by `database_name` + `object_name` and count distinct `plan_handle` values.
If > 1, R20 fires.

**Example**
```
collection_time      plan_handle      avg_cpu_ms   avg_logical_reads
08:00:00             0xABCD...        180          1,240
08:05:00             0xABCD...        175          1,238
08:10:00             0x9876...        1,450        8,920   ← plan changed
08:15:00             0x9876...        1,410        8,840
```
New plan is 8× worse on CPU and 7× worse on reads. This is a plan regression.

**Fix options**
1. Force the old plan via Query Store:
   ```sql
   EXEC sys.sp_query_store_force_plan @query_id = N, @plan_id = M;
   ```
2. Run `/sqlplan-compare` on the old and new plan XML to understand what changed.
3. Investigate root cause: statistics update, schema change, parameter set, or SET options.

**Related checks:** R16, R18, R13

---

### R21 — Natively Compiled Proc Regression (SQL 2014+)

**What it means**
A natively compiled procedure's `avg_cpu_ms` has increased ≥ 100% across snapshots. Native
procs are compiled directly to machine code and should run in sub-millisecond time. A CPU
regression of this magnitude signals a schema change to the underlying memory-optimized
table, a statistics shift affecting the compiled plan, or lock contention on memory-optimized
table rows that forces the engine to spin-wait.

**How to spot it**
Filter proc_stats snapshots on procedures whose objects reside in memory-optimized filegroups
(check `sys.filegroups WHERE type = 'FX'`). Compare `avg_cpu_ms` across snapshots — a
doubling or worse across consecutive intervals triggers R21.

**Example (problem)**
```
snapshot             object_name              avg_cpu_ms
08:00:00             usp_InsertOrderLine      0.12
08:05:00             usp_InsertOrderLine      0.31
08:10:00             usp_InsertOrderLine      0.84   ← 7× from baseline
```
A native proc that was 0.12 ms per call is now 0.84 ms — still fast in absolute terms but
regression of 600% indicates something changed in the memory-optimized table or its indexes.

**Fix options**
1. Recompile the native proc: `EXEC sp_recompile N'schema.proc';` — this drops and regenerates
   the native DLL.
2. Check for schema changes to the underlying memory-optimized table: added/removed columns,
   index changes, or hash bucket count misconfiguration.
3. Verify the underlying table's durability setting is intact (DURABILITY = SCHEMA_AND_DATA):
   ```sql
   SELECT durability_desc, memory_optimized
   FROM sys.tables WHERE name = 'YourTable';
   ```
4. Check for row-level lock contention: natively compiled procs use optimistic concurrency;
   contention shows as elevated `avg_elapsed_ms` with `avg_cpu_ms` unchanged.

**Related checks:** R16 (CPU worsening trend), R8 (parameter sniffing)

---

### R22 — High CLR Assembly Execution Ratio (All versions)

**What it means**
`total_clr_time_ms / total_elapsed_ms` ≥ 40% for a procedure, meaning CLR assembly code
dominates execution time. CLR functions run outside the SQL Server query engine and cannot
be optimized by the query processor. High CLR ratios indicate the procedure is doing
work that may be expressible more efficiently in native T-SQL.

**How to spot it**
CLR time is not exposed in `sys.dm_exec_procedure_stats` — identify CLR procedures via `type = 'PC'` (CLR_STORED_PROCEDURE), and compute the CLR ratio from statement-level stats (`sys.dm_exec_query_stats.total_clr_time`, reported in microseconds) collected into the snapshot:
```sql
SELECT object_name,
       total_clr_time_ms,
       total_elapsed_ms,
       CAST(total_clr_time_ms * 100.0 / NULLIF(total_elapsed_ms, 0) AS decimal(5,1))
           AS clr_pct
FROM #procstats_snapshot
WHERE total_clr_time_ms * 100.0 / NULLIF(total_elapsed_ms, 0) >= 40;
```

**Example (problem)**
```
object_name          total_elapsed_ms   total_clr_time_ms   clr_pct
usp_ParseXmlData     180,400            92,000              51.0
```
51% of elapsed time spent in CLR. The procedure is parsing XML inside a CLR assembly
when `OPENXML` or `nodes()` methods in T-SQL may be sufficient.

**Fix options**
1. Profile the CLR assembly if source is available — identify which CLR method dominates.
2. Evaluate replacing CLR logic with built-in SQL Server functions:
   - String splitting → `STRING_SPLIT` (SQL 2016+)
   - JSON parsing → `OPENJSON` (SQL 2016+)
   - String aggregation → `STRING_AGG` (SQL 2017+)
   - XML parsing → `.nodes()`, `.value()`, `.query()` methods
3. If the CLR function performs file or network I/O, consider moving that logic to the
   application layer and passing results in as parameters or TVPs.
4. Check CLR assembly permissions — UNSAFE assemblies have higher overhead than SAFE ones.

**Related checks:** R5 (top elapsed consumer), R6 (high avg elapsed)

---

### R23 — Trigger Dominating Proc Elapsed Time (All versions)

**What it means**
A trigger on a table is adding hidden overhead not visible in the procedure's own DMV entry.
When a trigger's `total_elapsed_ms` (from `sys.dm_exec_trigger_stats`) is ≥ 50% of the
calling DML procedure's `total_elapsed_ms`, the trigger is the dominant cost — but it
appears as blocking or I/O wait time in the procedure's elapsed, not as CPU.

**How to spot it**
Cross-reference `sys.dm_exec_trigger_stats` with proc_stats for the same table:
```sql
SELECT ts.object_id, OBJECT_NAME(ts.object_id) AS trigger_name,
       ts.total_elapsed_time / 1000.0 AS trigger_elapsed_ms
FROM sys.dm_exec_trigger_stats ts
WHERE ts.database_id = DB_ID();
```
If a trigger's elapsed is ≥ 50% of the proc that writes to its parent table, R23 fires.

**Example (problem)**
```
object_name              total_elapsed_ms   role
usp_InsertOrder          48,200             caller proc
trg_Order_AfterInsert    31,400             trigger on Orders table
```
The trigger consumes 65% of the proc's total elapsed time. The proc looks expensive in
procstats, but the root cause is the trigger.

**Fix options**
1. Identify all triggers on the target table:
   ```sql
   SELECT name, is_disabled, is_instead_of_trigger
   FROM sys.triggers
   WHERE parent_id = OBJECT_ID('schema.table');
   ```
2. Capture the trigger body and run it through `/tsql-review` to find anti-patterns.
3. Consider moving trigger logic to the application layer (event-driven architecture)
   or to an async process (Service Broker, queue table + background job).
4. If the trigger does referential integrity work, evaluate whether a FK constraint
   with cascades would be faster.

**Related checks:** R5 (top elapsed consumer), R1 (top CPU consumer)

---

### R24 — Parallel Proc Became Serial (CPU/Elapsed Ratio Drop) (All versions)

**What it means**
The `avg_cpu_ms / avg_elapsed_ms` ratio (CPU-to-elapsed ratio) drops from ≥ 1.5 to ≤ 1.0
across snapshots for the same procedure. A ratio above 1.5 indicates parallelism was active
(CPU > elapsed because multiple threads run concurrently). Dropping to ≤ 1.0 means the
procedure has become serial — elapsed time increases while CPU time drops, which is the
unmistakable signature of lost parallelism.

**How to spot it**
Calculate CPU/elapsed ratio per snapshot from proc_stats trend data:
```sql
SELECT collection_time, object_name,
       avg_cpu_ms, avg_elapsed_ms,
       CAST(avg_cpu_ms * 1.0 / NULLIF(avg_elapsed_ms, 0) AS decimal(6,2))
           AS cpu_elapsed_ratio
FROM #procstats_trend
ORDER BY object_name, collection_time;
```
If ratio was ≥ 1.5 in early snapshots and ≤ 1.0 in later snapshots, R24 fires.

**Example (problem)**
```
collection_time      avg_cpu_ms   avg_elapsed_ms   cpu_elapsed_ratio
08:00:00             18,400       4,200            4.38   ← parallel (DOP ~4)
08:05:00             17,900       4,350            4.11
08:10:00             6,200        8,800            0.70   ← serial (plan changed)
08:15:00             6,100        9,100            0.67
```
The procedure lost its parallel plan at 08:10. Elapsed time doubled, CPU halved.

**Fix options**
1. Check Query Store for plan changes at that timestamp:
   ```sql
   SELECT qp.plan_id, qp.last_compile_start_time, qp.query_plan
   FROM sys.query_store_plan qp
   JOIN sys.query_store_query qq ON qp.query_id = qq.query_id
   WHERE qq.object_id = OBJECT_ID('schema.proc')
   ORDER BY qp.last_compile_start_time DESC;
   ```
2. Use Query Store to force the parallel plan: `sys.sp_query_store_force_plan`.
3. Run `/sqlplan-review` on both plans to confirm DOP change (check S7 — DOP threshold,
   N30 — parallelism suppression).
4. Check for MAXDOP hints, Resource Governor limits, or CTFP changes that suppress parallelism.

**Related checks:** R20 (plan instability trend), R16 (CPU worsening)

---

### R25 — QS Plan Instability Correlated to Procstats Variance (SQL 2016+)

**What it means**
A procedure appears in Query Store with ≥ 3 distinct plans AND `avg_cpu_ms` variance between
proc_stats snapshots is ≥ 50%. The combination of multiple Query Store plans and high
snapshot-to-snapshot variance in procstats confirms parameter-sensitive plan selection or
plan cache churn — the optimizer is choosing different plans on different executions, causing
unpredictable performance.

**How to spot it**
Correlate proc_stats variance with `sys.query_store_plan` plan count for the same proc:
```sql
-- Step 1: count Query Store plans for the proc
SELECT qq.object_id, COUNT(DISTINCT qp.plan_id) AS plan_count
FROM sys.query_store_plan qp
JOIN sys.query_store_query qq ON qp.query_id = qq.query_id
WHERE qq.object_id = OBJECT_ID('schema.proc')
GROUP BY qq.object_id
HAVING COUNT(DISTINCT qp.plan_id) >= 3;

-- Step 2: check proc_stats avg_cpu_ms variance across snapshots
-- R25 fires when plan_count >= 3 AND (MAX(avg_cpu_ms) - MIN(avg_cpu_ms)) / MIN(avg_cpu_ms) >= 0.50
```

**Example (problem)**
```
object_name          QS plan count   min avg_cpu_ms   max avg_cpu_ms   variance_pct
usp_SearchProducts   5               85               920              982%
```
Five plans in Query Store, CPU ranging from 85 ms to 920 ms per execution — a 10× spread.

**Fix options**
1. Force the best plan in Query Store:
   ```sql
   EXEC sys.sp_query_store_force_plan @query_id = N, @plan_id = M;
   ```
2. Investigate why plans are changing — common causes:
   - Ad-hoc parameter values triggering plan recompilation
   - `WITH RECOMPILE` or `OPTION (RECOMPILE)` producing many ad-hoc plans
   - Statistics updates during business hours causing automatic recompilation
   - SET option mismatches (ARITHABORT, ANSI_NULLS) producing parallel plan variants
3. Use `/sqlquerystore-review` checks Q7–Q12 for full plan instability analysis including
   regressed query detection and forced plan health verification.
4. Consider `OPTIMIZE FOR UNKNOWN` or local variable pattern to stabilize plan selection.

**Related checks:** R20 (plan instability trend), R11 (plan instability pattern)

---

## Quick Reference Table

| Check | Category | Key Column(s) | Warning Threshold |
|-------|----------|---------------|-------------------|
| R1 | Consumer | `cpu_ms_per_sec`, CPU share | ≥ 50 ms/s or > 50% share |
| R2 | Consumer | `reads_per_sec`, read share | ≥ 5,000/s or > 50% share |
| R3 | Consumer | `avg_elapsed_ms` | ≥ 5,000 ms |
| R4 | Consumer | `execs_in_interval` | ≥ 10,000 |
| R5 | Consumer | `physical_pct` | > 10% |
| R6 | Efficiency | `avg_cpu_ms` | ≥ 1,000 ms |
| R7 | Efficiency | `avg_logical_reads` | ≥ 50,000 |
| R8 | Efficiency | `cpu_to_elapsed_ratio` | > 1.5 or < 0.2 |
| R9 | Efficiency | `max_to_avg_cpu_ratio` | ≥ 10 |
| R10 | Efficiency | `avg_spills` | ≥ 1 |
| R11 | Pattern | execs ≥ 1,000 + reads < 100 + cpu < 10 | (all three) |
| R12 | Pattern | `execs_per_sec` | ≥ 10/s |
| R13 | Pattern | distinct plan_handle + cache_age | > 1 handle + < 60 min |
| R14 | Pattern | top proc CPU share | > 50% (1 proc) |
| R15 | Pattern | execs ≤ 5 + avg_reads ≥ 100K | (both) |
| R16 | Trend | `avg_cpu_ms` monotonic increase | 3+ snapshots |
| R17 | Trend | execs_in_interval spike | > 2× mean |
| R18 | Trend | `avg_logical_reads` increase | > 50% oldest→newest |
| R19 | Trend | new entry + high resources | first seen + R1/R7 threshold |
| R20 | Trend | distinct plan_handle across time | > 1 plan in window |
| R21 | Trend | native proc `avg_cpu_ms` increase | ≥ 100% across snapshots |
| R22 | Trend | `total_clr_time_ms / total_elapsed_ms` | ≥ 40% |
| R23 | Trend | trigger elapsed vs proc elapsed | trigger ≥ 50% of proc |
| R24 | Trend | `avg_cpu_ms / avg_elapsed_ms` ratio drop | ≥ 1.5 → ≤ 1.0 |
| R25 | Trend | QS plan count + procstats CPU variance | ≥ 3 plans + ≥ 50% variance |
