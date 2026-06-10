# SQL Server Execution Plan Checks — Explained for All

## Contents

- [Before You Start: Key Concepts](#before-you-start-key-concepts)
- [Statement-Level Checks (S1–S27)](#statement-level-checks-s1s27)
- [Node-Level Checks (N1–N72)](#node-level-checks-n1n72)
- [Quick Reference Tables](#quick-reference-tables)

---


A detailed guide to every check the analyser performs.  
Each entry explains what the check means, why it matters, how to spot it, what the XML looks like, real-world examples, and multiple fix options.

---

## Before You Start: Key Concepts

### What is an execution plan?

When you submit a SQL query, SQL Server doesn't execute it immediately. It first hands it to the **Query Optimizer** — an internal component that evaluates many possible strategies for retrieving the data and chooses the one it estimates will be cheapest. The result of that process is an **execution plan**: a tree of steps, each called an *operator*.

You can view execution plans two ways in SSMS:
- **Ctrl+L** — *Estimated plan*: generated without running the query. No actual row counts. Fast.
- **Ctrl+M** then run — *Actual plan*: runs the query and records what really happened. Has actual row counts, elapsed times, and spill information. Required for many checks.

### What are operators?

Each box in the plan diagram is an operator. Common ones:

| Operator | What it does |
|----------|-------------|
| `Index Seek` | Navigates the index B-tree to find specific rows. Fast. |
| `Index Scan` | Reads every leaf page of an index. Slower on large indexes. |
| `Table Scan` | Reads every page of a heap (table without a clustered index). |
| `Key Lookup` | After an index seek, fetches additional columns from the clustered index. |
| `Nested Loops` | For each row from the outer input, scans/seeks the inner input. Good for small outer inputs. |
| `Hash Match` | Builds a hash table from one input, probes it with the other. Good for large unsorted inputs. |
| `Merge Join` | Merges two pre-sorted inputs. Very fast when data is already sorted. |
| `Sort` | Sorts all input rows before passing them on. Requires all rows in memory. |
| `Filter` | Applies a predicate and discards non-matching rows. |
| `Eager Spool` | Caches a full result set into a worktable in tempdb. |

Each operator shows a cost percentage — its estimated share of the total plan cost.

### What are statistics?

SQL Server maintains **statistics objects** for index key columns and some other columns. A statistics object contains a **histogram** showing how data is distributed. The optimizer uses histograms to estimate how many rows will satisfy a predicate — e.g., "how many orders have OrderDate in 2024?"

Bad or missing statistics → bad row estimates → wrong operator choices → slow queries.

### What is a memory grant?

Operators like `Sort` and `Hash Match` need to hold all their working data in RAM. Before the query runs, SQL Server calculates how much memory to **reserve** (grant) based on estimated row counts. The grant is locked in before execution begins.

- **Too large**: wastes RAM that other queries need; they queue and wait for their grant.
- **Too small**: the operator runs out of memory mid-execution and spills overflow data to **tempdb** (disk) — much slower.

### Estimated vs Actual plans

An **estimated plan** is generated without running the query. All row counts are estimates. Some checks (those requiring actual row counts, elapsed times, or confirmed spills) cannot fire on estimated plans.

An **actual plan** runs the query and records real values alongside estimates. This is required for checks marked *(requires actual plan)*.

### How to read the plan XML

Every plan in the analyser is stored as XML. Most checks inspect specific attributes and elements. Understanding the XML helps you cross-reference what the analyser found:

```xml
<StmtSimple StatementText="SELECT ..."
            StatementSubTreeCost="12.5"
            CardinalityEstimationModelVersion="160"
            CompileCPU="234"
            CompileMemory="1024">
  <QueryPlan DegreeOfParallelism="4" NonParallelPlanReason="">
    <MemoryGrantInfo GrantedMemory="524288" MaxUsedMemory="12000" GrantWaitTime="0"/>
    <Warnings>
      <PlanAffectingConvert ConvertIssue="Seek Plan" Expression="[col] = @param"/>
    </Warnings>
    <RelOp PhysicalOp="Hash Match" LogicalOp="Inner Join"
           EstimateRows="50000" EstimatedTotalSubtreeCost="8.2"
           NodeId="0" Parallel="1">
      <RunTimeInformation>
        <RunTimeCountersPerThread Thread="0" ActualRows="49200"
                                   ActualExecutions="1" ActualElapsedms="1203"
                                   ActualCPUms="4800"/>
      </RunTimeInformation>
    </RelOp>
  </QueryPlan>
</StmtSimple>
```

---

## Statement-Level Checks (S1–S27)

These checks fire once per query statement before individual operators are examined. They look at plan-wide attributes like memory grants, compile stats, and hints.

---

### S1 — Serial Plan

**What it means**  
SQL Server compiled a plan that runs on a single CPU thread instead of distributing work across multiple threads. This is called a *serial* plan, as opposed to a *parallel* plan.

SQL Server automatically decides whether to parallelize a query based on its estimated cost. The threshold is the **Cost Threshold for Parallelism** server setting (default: 5). Any query with an estimated cost above that threshold *can* be parallelized — but only if nothing prevents it.

This check fires when something has actively prevented parallelism on a query that's expensive enough to benefit from it.

**Why it matters**  
On an 8-core server, a well-parallelized query can finish in roughly 1/8th the elapsed time of a serial execution. Forcing an expensive query serial wastes the hardware you're paying for.

**Common causes and how to fix each**

| Cause | XML signal | Fix |
|-------|-----------|-----|
| `OPTION (MAXDOP 1)` hint in query | `NonParallelPlanReason = QueryHintNoParallelSet` | Remove the hint |
| Server MAXDOP = 1 | `NonParallelPlanReason = MaxDOPSetToOne` | `EXEC sp_configure 'max degree of parallelism', 8; RECONFIGURE` |
| Scalar UDF in query | `NonParallelPlanReason = TSQLUserDefinedFunctionsNotParallelizable` | Rewrite UDF as an inline TVF |
| Table variable involved | `NonParallelPlanReason = TableVariableTransactionsDoNotSupportParallelNestedTransaction` | Replace `@tableVar` with `#tempTable` |
| Trace flag 8649 not set | `NonParallelPlanReason = ParallelismDisabledByTraceFlag` | Review the trace flag justification |

**XML attribute**
```xml
<QueryPlan NonParallelPlanReason="MaxDOPSetToOne">
```

**Example — problem**
```sql
-- Developer added MAXDOP 1 to "fix" a plan regression; now it's always serial:
SELECT o.OrderId, SUM(d.Quantity * d.UnitPrice) AS Total
FROM dbo.Orders o
JOIN dbo.OrderDetails d ON o.OrderId = d.OrderId
WHERE o.OrderDate BETWEEN '2020-01-01' AND '2023-12-31'
GROUP BY o.OrderId
OPTION (MAXDOP 1)
```

**Example — fix**
```sql
-- Remove the hint. If a plan regression was the reason it was added,
-- fix the underlying problem (update statistics, add index):
SELECT o.OrderId, SUM(d.Quantity * d.UnitPrice) AS Total
FROM dbo.Orders o
JOIN dbo.OrderDetails d ON o.OrderId = d.OrderId
WHERE o.OrderDate BETWEEN '2020-01-01' AND '2023-12-31'
GROUP BY o.OrderId
-- Optionally set a specific DOP instead of blanket 1:
-- OPTION (MAXDOP 4)
```

**Related checks:** S8 (ineffective parallelism), S9 (parallel wait bottleneck), N25 (scalar UDF), S13/S14 (table variable)

---

### S2 — Excessive Memory Grant

**What it means**  
SQL Server reserved a large block of RAM for this query but the query barely touched it. The ratio of reserved-to-used memory was ≥ 10×, AND the reservation was at least 1 GB.

Memory grants are calculated at compile time from row estimates. If the optimizer estimates 10 million rows will flow through a Sort, it reserves enough memory to sort 10 million rows. If only 50,000 rows actually arrive, 95% of that reserved memory sits idle — locked out from other queries — for the entire execution duration.

**Why it matters**  
Every MB held by your query is unavailable to every other query on the server. On a busy system with many concurrent queries, over-provisioned grants cascade: queries queue waiting for memory, appearing slow even though they barely use any resources. This shows up as `RESOURCE_SEMAPHORE` waits in `sys.dm_exec_requests`.

**How to spot it in SSMS**  
In the actual plan, right-click the root operator (leftmost box, typically "SELECT") → Properties. Look at:
- `MemoryGrant (KB)` — what was reserved
- `Used Memory (KB)` — what was actually used

**XML attributes**
```xml
<MemoryGrantInfo GrantedMemory="2097152"  <!-- 2 GB reserved -->
                 MaxUsedMemory="15000"    <!-- only 15 MB used -->
                 SerialRequiredMemory="512000"/>
```

**Root cause: bad row estimates**  
Over-grants almost always trace back to the optimizer overestimating how many rows a Sort or Hash Match will process. Find the operator with the biggest discrepancy between Estimated Rows and Actual Rows — that's causing the inflated grant. Fix the estimate, and the grant corrects itself.

**Example — problem**
```sql
-- Stored procedure was written when the Orders table had 1M rows.
-- Statistics were last updated then. Now the table has 50M rows
-- but the query filter makes it return only 200 rows.
-- Optimizer estimates 1M rows (stale stats), grants 4 GB.
CREATE PROCEDURE GetRecentCancelledOrders @CutoffDate DATE AS
SELECT * FROM dbo.Orders
WHERE Status = 'Cancelled' AND OrderDate >= @CutoffDate
ORDER BY OrderDate DESC
```

**Fix options (in order of preference)**

1. **Update statistics** — cheapest fix, often sufficient:
```sql
UPDATE STATISTICS dbo.Orders WITH FULLSCAN
```

2. **Force recompile** — builds plan with actual runtime parameter values:
```sql
-- Append to the query or stored procedure:
OPTION (RECOMPILE)
```

3. **Hint a typical value** — builds plan for a representative value:
```sql
OPTION (OPTIMIZE FOR (@CutoffDate = '2023-01-01'))
```

4. **Cap the grant** — last resort via Resource Governor:
```sql
ALTER RESOURCE POOL [OLTP] WITH (MAX_MEMORY_GRANT_PERCENT = 10)
```

**Related checks:** S3 (large grant), S4 (grant wait), S18 (insufficient grant), N21 (bad row estimate)

---

### S3 — Large Memory Grant

**What it means**  
The query reserved ≥ 1 GB of memory before executing (Warning), or ≥ 4 GB (Critical). Unlike S2 (which fires when the grant is *wasted*), this fires whenever the reservation is large — even if the query legitimately uses it all.

**Why it matters**  
A single query holding 4 GB of memory on a 16 GB server is occupying 25% of total RAM. On a server running 50 concurrent queries, one greedy query can cause all others to queue for memory, appearing slow even when they're not CPU-bound.

**How a large grant happens**  
Large grants come from Sort and Hash Match operators processing many rows. Each operator's memory need scales with the number of rows × the average row size. A query sorting 100 million 200-byte rows needs ~20 GB of Sort memory.

**Finding the culprit operator**  
In SSMS, hover over each Sort or Hash Match in the plan. The tooltip shows "Memory Fractions" — the proportion of the grant allocated to that operator. The one with the highest fraction is your target.

**Fix options**

1. **Add an index to eliminate the Sort** — if the Sort is for ORDER BY, create an index with keys matching the ORDER BY direction:
```sql
-- Query: SELECT * FROM Orders ORDER BY CustomerId, OrderDate
-- Fix:
CREATE INDEX IX_Orders_Customer_Date ON dbo.Orders (CustomerId, OrderDate)
-- SQL Server reads pre-sorted from the index and skips the Sort entirely
```

2. **Filter earlier to reduce row count** — push WHERE conditions earlier in the plan:
```sql
-- Before: SELECT * FROM BigTable b JOIN SmallTable s ... WHERE b.Status = 'A'
-- After: put Status filter in a CTE/subquery processed before the join
WITH filtered AS (SELECT * FROM BigTable WHERE Status = 'A')
SELECT * FROM filtered f JOIN SmallTable s ON ...
```

3. **Use columnstore indexes** for analytical workloads — batch mode processing needs far less memory than row mode.

**Related checks:** S2 (excessive grant), S4 (grant wait), S18 (insufficient grant)

---

### S4 — Memory Grant Wait

**What it means**  
Your query could not start executing immediately because the memory it needed for its grant was not available. It had to wait in a queue (`RESOURCE_SEMAPHORE` wait) until other queries released memory. Warning if any wait occurred; Critical at ≥ 5,000 ms.

**Why it matters**  
This is pure dead time. The server accepted your query, understood what it needed to do, but couldn't start because RAM was occupied. A 5-second wait before the first row is even read is devastating for interactive workloads.

**Under concurrent load, this compounds:**  
- Query A holds 8 GB, waits for B to finish
- Query B holds 8 GB, waits for C to finish
- Query C is queued...
- Result: chains of blocked queries, all looking "slow" but actually just waiting

**XML attribute**
```xml
<MemoryGrantInfo GrantWaitTime="5234" GrantedMemory="2097152"/>
```

**How to confirm the problem**  
While the wait is happening:
```sql
SELECT session_id, wait_type, wait_time_ms, blocking_session_id
FROM sys.dm_exec_requests
WHERE wait_type = 'RESOURCE_SEMAPHORE'
```

**Fix options**
1. **Fix over-grants** — if queries are reserving far more than they use (S2/S3), fix those first. Reducing individual grants frees memory faster.
2. **Resource Governor** — cap per-query memory to prevent monopolization:
```sql
ALTER RESOURCE POOL OLTP_POOL WITH (MAX_MEMORY_GRANT_PERCENT = 20)
```
3. **Add RAM** — hardware fix, but may only delay the problem if root grants aren't reduced.
4. **Reduce `max server memory`** — counterintuitively, leaving more RAM for the OS buffer reduces grant waiting in memory-constrained environments.

---

### S5 — Compile Timeout

**What it means**  
The Query Optimizer ran out of time while searching for a good execution plan and gave up early. SQL Server sets an internal time limit on optimization; when hit, it uses whatever plan it has at that moment — which may be far from optimal.

**Why the optimizer has a time limit**  
Finding a truly optimal plan across all possible join orders, index choices, and operator strategies is an NP-hard problem. For a query with 10 joins, there are 3,628,800 possible join orders alone. The optimizer uses heuristics, cost estimates, and time limits to find a "good enough" plan without taking hours.

**Impact on your query**  
The plan you get may have a cost 10× or 100× higher than the optimal plan. You're essentially running a worst-case execution strategy that the optimizer didn't have time to improve.

**XML attribute**
```xml
<StmtSimple StatementOptmEarlyAbortReason="TimeOut">
```

**Fix options**

1. **Break the query into pieces with temp tables** — the optimizer solves each piece separately:
```sql
-- Instead of one 15-table query, do:
SELECT a.*, b.value INTO #step1
FROM TableA a JOIN TableB b ON a.id = b.fk
-- ... 4 more joins

SELECT s.*, c.* INTO #step2
FROM #step1 s JOIN TableC c ON s.x = c.y
-- ... 3 more joins

SELECT * FROM #step2 JOIN TableD d ON ...
```

2. **Use a plan guide** — force a known-good plan once you've found one:
```sql
EXEC sp_create_plan_guide @name = N'GuideForComplexQuery',
    @stmt = N'SELECT ...',
    @type = N'SQL',
    @hints = N'OPTION (USE PLAN N''<ShowPlanXML .../>'')'
```

3. **Review join count** — queries with 12+ tables almost always time out. See N44.

**Related checks:** S6 (compile memory exceeded), S7 (high compile CPU), N44 (many joins)

---

### S6 — Compile Memory Exceeded

**What it means**  
The Query Optimizer ran out of *memory* while trying to compile the plan and was forced to stop early — similar to S5 (timeout) but hitting a memory wall instead of a time wall.

**Why it happens**  
The optimizer builds internal data structures (join order trees, cardinality estimates, memo tables) that grow with query complexity. For very complex queries these structures can consume gigabytes of server RAM during compilation.

**XML attribute**
```xml
<StmtSimple StatementOptmEarlyAbortReason="MemoryLimitExceeded">
```

**Impact**  
Same as S5 — you're executing a partially-optimized plan. Combined with S5, it means your query is so complex that the optimizer cannot complete its work in any reasonable budget of time or memory.

**Fix options**  
Same as S5: break the query into smaller pieces. This is a strong signal that the query needs architectural redesign — not just hints.

**Related checks:** S5 (compile timeout), S7 (high compile CPU), S15 (high compile memory), N44 (many joins)

---

### S7 — High Compile CPU

**What it means**  
SQL Server spent a significant amount of CPU time *compiling* (optimizing) the query before executing it. Warning at ≥ 1,000 ms; Critical at ≥ 5,000 ms.

Compilation is normally fast (< 100 ms for typical queries). Hitting 5+ seconds means the optimizer is working extremely hard evaluating plan alternatives.

**Why it matters — the concurrency problem**  
If this query runs frequently (say, 10 times/second), and each execution must recompile (e.g., `OPTION (RECOMPILE)` is used), the server burns 50 seconds of CPU per second on pure compilation overhead. Under high concurrency, this alone can saturate all CPU cores.

**XML attribute**
```xml
<StmtSimple CompileCPU="4823" CompileTime="5102" CompileMemory="524288">
```

**Note the difference:**
- `CompileCPU` — CPU time used by the optimizer
- `CompileTime` — wall-clock time (includes waiting)
- `CompileMemory` — RAM used during compilation (see S15)

**Fix options**

1. **Use stored procedures** — compiled once, plan cached and reused across all connections:
```sql
-- Instead of:
EXEC sp_executesql N'SELECT ... FROM t1 JOIN t2 ...'

-- Create a stored procedure:
CREATE PROCEDURE GetOrders @StartDate DATE AS
SELECT ... FROM Orders WHERE OrderDate >= @StartDate
-- First call compiles; subsequent calls reuse the cached plan
```

2. **Parameterize the query** — prevents per-literal-value recompilation:
```sql
-- Bad: new plan for every value
SELECT * FROM Orders WHERE CustomerId = 12345

-- Good: one plan reused for all values
EXEC sp_executesql N'SELECT * FROM Orders WHERE CustomerId = @id',
    N'@id INT', @id = 12345
```

3. **Check S20** — if `OPTION (RECOMPILE)` is involved, see that check for targeted fixes.

**Related checks:** S5 (compile timeout), S6 (compile memory exceeded), S15 (high compile memory), S20 (RECOMPILE hint with expensive compile)

---

### S8 — Ineffective Parallelism

**What it means**  
The query ran in parallel (multiple CPU threads) but achieved less than 50% of the theoretical speedup. For example: using 8 threads but only running 1.5× faster than a single thread — the overhead of parallelism nearly consumed its own benefit.

**How efficiency is calculated:**
```
speedup    = total CPU time / elapsed time
efficiency = (speedup - 1) / (DOP - 1) × 100%

Example: DOP 8, CPU 12,000ms, elapsed 3,000ms
speedup    = 12,000 / 3,000 = 4.0
efficiency = (4 - 1) / (8 - 1) × 100% = 43%   ← below 50%, fires
```

**Why it matters**  
A parallel query with 43% efficiency is consuming 8 CPU cores but only getting the benefit of ~4 cores. The other 4 cores are burning CPU on synchronization overhead, waiting for other threads, or processing skewed data. Meanwhile those 4 wasted cores could be serving other queries.

**Common root causes**

| Cause | Symptom | Check |
|-------|---------|-------|
| Data skew | One thread processes 90% of rows | N27 (Thread Skew) |
| Lock waits | Threads waiting on each other | S9 (Parallel Wait) |
| I/O bottleneck | Threads waiting for disk | S9 (Parallel Wait) |
| Low cost query | Not worth parallelizing | Lower server CTFP |

**XML attributes**
```xml
<!-- From RunTimeCountersPerThread on root operator: -->
<RunTimeCountersPerThread Thread="0" ActualRows="9999000"
                           ActualElapsedms="3000" ActualCPUms="1500"/>
<RunTimeCountersPerThread Thread="1" ActualRows="1000"
                           ActualElapsedms="2800" ActualCPUms="200"/>
<!-- Thread 0 did all the work → data skew → ineffective parallelism -->
```

**Fix options**
1. **Investigate thread skew (N27)** — look for a low-cardinality distribution key.
2. **Reduce DOP** — if parallel is barely faster, sometimes serial is actually better:
```sql
SELECT ... OPTION (MAXDOP 2)  -- try different values
```
3. **Raise the Cost Threshold for Parallelism** — prevents marginally-qualifying queries from going parallel:
```sql
EXEC sp_configure 'cost threshold for parallelism', 50
RECONFIGURE
```

**Related checks:** S9 (parallel wait), N27 (thread skew), S1 (serial plan)

---

### S9 — Parallel Wait Bottleneck

**What it means**  
In a parallel query, the total elapsed time was more than twice the total CPU time. This means threads spent more time *waiting* than *working*. A thread that's waiting is burning wall-clock time but not making progress.

*(Note: This check only fires for parallel plans with `DOP > 1`.)*

**Why threads wait in parallel queries**  
- **Exchange operators** (`Repartition Streams`, `Gather Streams`) — threads must synchronize at these points. If one thread finishes its partition early, it waits for others.
- **Lock waits** — a thread tries to read a row another transaction has locked.
- **I/O stalls** — threads waiting for disk reads to complete.
- **CXPACKET waits** — the most common parallel wait; threads waiting at a synchronization point.

**XML attributes**
```xml
<!-- Root operator runtime on a 4-thread plan: -->
<RunTimeCountersPerThread Thread="0" ActualElapsedms="8000" ActualCPUms="800"/>
<!-- elapsed = 8s, cpu = 0.8s → 10% utilization → threads mostly waiting -->
```

**How to investigate further**
```sql
-- Check current waits:
SELECT session_id, wait_type, wait_time_ms
FROM sys.dm_exec_requests
WHERE session_id = <your_spid>

-- Historical wait analysis:
SELECT TOP 20 wait_type, waiting_tasks_count,
       wait_time_ms / NULLIF(waiting_tasks_count, 0) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ('SLEEP_DBSTARTUP', 'LAZYWRITER_SLEEP', ...)
ORDER BY wait_time_ms DESC
```

**Fix options**
1. **Check for blocking** — are other transactions holding locks this query needs?
2. **I/O optimization** — add indexes to reduce I/O, move to faster storage.
3. **Reduce exchange operators** — in SSMS, look for orange `Parallelism` boxes; each is a synchronization point. Fewer joins between parallel regions = fewer sync points.
4. **Consider MAXDOP 1** — if the query is I/O bound rather than CPU bound, parallelism adds overhead without helping.

---

### S10 — Downlevel Cardinality Estimator

**What it means**  
Your database is using a legacy version of SQL Server's Cardinality Estimator (CE). The CE is the component that predicts how many rows an operator will return. SQL Server 2016+ (compatibility level 130+) introduced a substantially improved CE with better multi-column correlation handling and more realistic estimates for complex predicates.

**The two CE versions:**
- **CE70/CE80** (`version < 130`) — original algorithm, used in SQL Server 2014 and earlier compatibility modes
- **CE120+** (`version ≥ 130`) — modern algorithm, SQL Server 2016+

**XML attribute**
```xml
<StmtSimple CardinalityEstimationModelVersion="120">
```

**Why it matters**  
The legacy CE makes systematic errors on:
- Queries with multiple predicates on the same table (it assumes independence)
- JOIN cardinality with many tables
- Ascending key columns (dates, auto-increment IDs) where statistics are always slightly stale

These errors lead to wrong join strategies, wrong memory grants, and wrong operator choices.

**How to check your compatibility level**
```sql
SELECT name, compatibility_level
FROM sys.databases
WHERE name = DB_NAME()
```

**Fix options**

1. **Upgrade compatibility level** (test on a non-production copy first):
```sql
ALTER DATABASE YourDB SET COMPATIBILITY_LEVEL = 150  -- SQL Server 2019
-- Or 140 for SQL 2017, 130 for SQL 2016
```

2. **Use a hint to enable the new CE without changing compat level**:
```sql
SELECT ... OPTION (USE HINT('FORCE_DEFAULT_CARDINALITY_ESTIMATION'))
```

3. **Test for regressions** — some queries genuinely run better on the old CE. Use Query Store to compare before/after.

---

### S11 — Plan-Level Warnings

**What it means**  
SQL Server embedded one or more warning messages directly in the execution plan XML. These are SQL Server's own built-in diagnostics — it detected something worth flagging about this plan.

**Common warning types**

| Warning type | Meaning |
|-------------|---------|
| `SpillToTempDb` | A Sort or Hash operator ran out of memory and wrote to disk |
| `NoJoinPredicate` | A join has no ON condition (Cartesian product) |
| `PlanAffectingConvert` | A type mismatch is affecting the plan (seek blocked or cardinality degraded) |
| `ColumnsWithNoStatistics` | An operator referenced a column with no statistics |
| `UnmatchedIndexes` | An index hint couldn't be matched to a usable index |

**XML element**
```xml
<QueryPlan>
  <Warnings>
    <PlanAffectingConvert ConvertIssue="Seek Plan" Expression="[dbo].[Orders].[Status]=[@p1]"/>
    <ColumnsWithNoStatistics>
      <ColumnReference Database="AdventureWorks" Schema="dbo" Table="Orders" Column="Notes"/>
    </ColumnsWithNoStatistics>
  </Warnings>
</QueryPlan>
```

**What to do**  
S11 is intentionally broad — it catches any warnings. More specific sub-checks (S12, N10, N11, N38, N41, N42) drill into the individual warning types with targeted fixes.

---

### S12 — Implicit Conversion Blocks Index Seeks

**What it means**  
You're comparing a column to a value of a different data type. SQL Server is converting every single row in the table to perform the comparison — making index seeks physically impossible.

This is one of the most impactful and common SQL Server performance problems.

**How index seeks work**  
An index is built on the stored values in a specific data type. When you seek `WHERE OrderId = 12345`, SQL Server looks up `12345` in the INT index. But if you write `WHERE OrderId = '12345'` (a string), SQL Server cannot look up a string in an INT index. Instead it must:
1. Read every row
2. Convert each `OrderId` value to VARCHAR
3. Compare the converted string to `'12345'`

This converts an O(log n) seek into an O(n) scan.

**XML element**
```xml
<Warnings>
  <PlanAffectingConvert ConvertIssue="Seek Plan"
                        Expression="CONVERT_IMPLICIT(nvarchar(50),[dbo].[Orders].[Email],0)=[@email_param]"/>
</Warnings>
```

**Common mismatches**

| Column type | Wrong parameter type | Impact |
|------------|---------------------|--------|
| `INT` | `VARCHAR('12345')` | Full scan instead of seek |
| `VARCHAR` | `NVARCHAR(N'text')` | Full scan instead of seek |
| `DATE` | `DATETIME` | Seek blocked in some cases |
| `DECIMAL` | `FLOAT` | Precision loss + seek issues |

**Example — problem**
```sql
-- The column Email is VARCHAR(100), but the ORM is sending NVARCHAR:
SELECT * FROM dbo.Users WHERE Email = N'user@example.com'
--                                    ^ N prefix = NVARCHAR
-- SQL Server converts every Email from VARCHAR to NVARCHAR for comparison
-- The index on Email is useless
```

**Example — fix**
```sql
-- Option 1: Use the correct type in the query:
SELECT * FROM dbo.Users WHERE Email = 'user@example.com'  -- no N prefix

-- Option 2: Fix the column type to match application expectations:
ALTER TABLE dbo.Users ALTER COLUMN Email NVARCHAR(100) NOT NULL

-- Option 3: Fix in the application layer — ensure the ORM/driver
-- sends the right data type for each parameter
```

**Related checks:** N8 (implicit conversion in predicate — cardinality affected but seek still works), N42 (cardinality-only conversion)

---

### S13 — Table Variable (Read)

**What it means**  
The plan accesses a `@tableVariable` declared with `DECLARE @t TABLE (...)`. Table variables in SQL Server have two critical limitations compared to temp tables:

1. **No statistics** — the optimizer doesn't know how many rows are in the table variable. It uses a fixed guess: 1 row in older versions, 100 rows in SQL Server 2019+ with compatibility level 150.
2. **No parallel reads** — table variables cannot be scanned in parallel, limiting the benefit of parallelism for large variable contents.

**Why it matters**  
If your table variable holds 50,000 rows but the optimizer thinks it holds 1, every plan that reads from it is designed for a 1-row input. This cascades: joins choose Nested Loops (good for 1 row, terrible for 50,000), memory grants are undersized (S18), sort spills occur (N41).

**Example — problem**
```sql
DECLARE @ActiveCustomers TABLE (
    CustomerId INT,
    Name NVARCHAR(100),
    TotalSpend DECIMAL(10,2)
)

INSERT INTO @ActiveCustomers
SELECT CustomerId, Name, SUM(Total)
FROM dbo.Orders
GROUP BY CustomerId, Name
HAVING SUM(Total) > 10000
-- Inserts 75,000 rows but optimizer thinks 1 row

SELECT o.* FROM dbo.Orders o
JOIN @ActiveCustomers ac ON o.CustomerId = ac.CustomerId
-- ↑ Plan uses Nested Loops designed for 1-row join → catastrophically slow
```

**Example — fix**
```sql
-- Use a temp table instead:
CREATE TABLE #ActiveCustomers (
    CustomerId INT,
    Name NVARCHAR(100),
    TotalSpend DECIMAL(10,2)
)

INSERT INTO #ActiveCustomers
SELECT CustomerId, Name, SUM(Total)
FROM dbo.Orders
GROUP BY CustomerId, Name
HAVING SUM(Total) > 10000
-- SQL Server creates statistics on #ActiveCustomers automatically

SELECT o.* FROM dbo.Orders o
JOIN #ActiveCustomers ac ON o.CustomerId = ac.CustomerId
-- ↑ Optimizer now knows there are 75,000 rows → chooses Hash Match
```

**When table variables are fine**  
For sets of < 100 rows where you're certain the data will be small, table variables are perfectly acceptable and avoid the overhead of temp table creation.

**Related checks:** S14 (table variable modification), S1 (table variables prevent parallelism)

---

### S14 — Table Variable (Write / Modification)

**What it means**  
The plan includes an INSERT, UPDATE, or DELETE targeting a `@tableVariable`. Beyond the statistics problem in S13, modifications to table variables have additional costs:

1. **Row-level locking** — table variable modifications use row-level locks, which can cause blocking in concurrent scenarios.
2. **Forces serial execution** — DML against table variables cannot run in parallel, regardless of server MAXDOP settings.
3. **Log writes** — despite what many believe, table variable changes *are* written to the transaction log (just in tempdb rather than your database log).

**Fix**  
Replace with `#temp` tables for any table that receives DML and might have concurrent access or more than ~100 rows.

---

### S15 — High Compile Memory

**What it means**  
SQL Server used more than 1 GB of RAM just to compile (optimize) the query plan — before a single row was processed.

Compilation memory is used by the optimizer to build its internal search structures: join order trees, operator cost tables, memo structures. It's drawn from a shared pool used by all query compilations server-wide.

**XML attribute**
```xml
<StmtSimple CompileMemory="2097152">  <!-- 2 GB in KB -->
```

**Why it matters**  
Compilation is normally cheap (< 10 MB). A 1 GB compilation event is extremely unusual and indicates a very complex query. If this query is frequently compiled (high frequency + `OPTION (RECOMPILE)`, or many ad-hoc literal variants), the compilation memory consumption compounds across all concurrent compilations.

**Fix options**  
This is almost always a sign of a query with 10+ joins or deeply nested subqueries. Break it into smaller queries using temp tables. Use stored procedures to compile once and reuse.

---

### S16 — Trivial Plan

**What it means**  
SQL Server bypassed its full multi-phase optimization process and used a "trivial plan" — the single obviously-correct strategy for a very simple query. This is informational.

Examples of queries that qualify for trivial plans:
- `SELECT * FROM table WHERE id = 1` (point lookup, only one reasonable strategy)
- `SELECT COUNT(*) FROM table` (no joins, no filters)

**XML attribute**
```xml
<StmtSimple StatementOptmLevel="TRIVIAL">
```

**When to act**  
This check only fires when the plan is trivial AND the cost is ≥ 1.0 — which is unusual because trivial queries are normally cheap. If this fires, it suggests a query that *should* be simple is unexpectedly expensive, likely due to a missing index on the filter column.

**Example**
```sql
-- Point lookup but no index on Email — full scan required:
SELECT * FROM dbo.Users WHERE Email = 'user@example.com'
-- Trivial plan (one obvious strategy: scan) but costs 5.0 due to table size
-- Fix: CREATE INDEX IX_Users_Email ON dbo.Users (Email)
```

---

### S17 — Unparameterized Query

**What it means**  
The query has no parameters — literal values are baked directly into the SQL text. SQL Server identifies plans in its cache by exact query text hash. An unparameterized query generates a new cache entry for every unique combination of literal values.

*(Note: this check skips stored procedure bodies — a stored procedure is itself the reuse unit.)*

**Why it matters — plan cache bloat**  
```
SELECT * FROM Orders WHERE CustomerId = 12345   → cache entry 1
SELECT * FROM Orders WHERE CustomerId = 12346   → cache entry 2
SELECT * FROM Orders WHERE CustomerId = 12347   → cache entry 3
... (one per unique customer ID — potentially thousands)
```

On a busy system, this fills the plan cache with near-identical plans. When the cache is full, SQL Server starts evicting entries — causing constant recompilations and higher CPU usage.

**XML signal**  
The `<ParameterList>` element is absent from the `StmtSimple` element.

**Example — problem**
```sql
-- ORM generates a new SQL string for each request:
SELECT TOP 10 * FROM Products WHERE CategoryId = 5 AND Price < 99.99
SELECT TOP 10 * FROM Products WHERE CategoryId = 7 AND Price < 149.99
-- Each is treated as a unique query
```

**Fix options**

1. **sp_executesql with parameters** — most reliable:
```sql
EXEC sp_executesql
    N'SELECT TOP 10 * FROM Products WHERE CategoryId = @cat AND Price < @maxPrice',
    N'@cat INT, @maxPrice DECIMAL(10,2)',
    @cat = 5, @maxPrice = 99.99
```

2. **Stored procedure** — parameterized by definition:
```sql
CREATE PROCEDURE GetProducts @cat INT, @maxPrice DECIMAL(10,2) AS
SELECT TOP 10 * FROM Products WHERE CategoryId = @cat AND Price < @maxPrice
```

3. **Enable Forced Parameterization** (database-level) — SQL Server auto-parameterizes simple queries:
```sql
ALTER DATABASE YourDB SET PARAMETERIZATION FORCED
-- Use with caution — can cause parameter sniffing issues for non-uniform data
```

---

### S18 — Insufficient Memory Grant (Used > Granted)

**What it means**  
The opposite of S2/S3. The query used *more* memory than SQL Server granted it at compile time. The optimizer underestimated how many rows would be processed, reserved too little memory, and the query had to spill excess data to tempdb during execution.

**XML attributes**
```xml
<MemoryGrantInfo GrantedMemory="102400"    <!-- 100 MB granted -->
                 MaxUsedMemory="524288"/>   <!-- 512 MB actually needed -->
```

**Why it happens**  
The grant is sized at compile time from row estimates. If the optimizer estimates 10,000 rows will flow through a Sort but 1 million actually arrive at runtime (due to parameter sniffing or stale statistics), the Sort runs out of its 100 MB grant and spills 900 MB worth of data to tempdb.

**Impact**  
Every MB that spills to tempdb involves disk I/O — typically 100× slower than in-memory processing. A Sort that should take 50ms can take 5 seconds when spilling.

**Fix**  
Identify and fix the row estimate problem:
- Update statistics: `UPDATE STATISTICS dbo.TableName WITH FULLSCAN`
- Check for parameter sniffing: try `OPTION (RECOMPILE)` to see if the grant improves
- Add filtered statistics for skewed value distributions

**Related checks:** N41 (confirmed spill — the actual overflow that S18 causes), N6/N7 (spill risk based on estimates), S2/S3 (the opposite problem)

---

### S19 — FORCE ORDER Hint

**What it means**  
The query contains `OPTION (FORCE ORDER)`, which instructs SQL Server to join tables in exactly the order written in the query — overriding the optimizer's cost-based join reordering.

**Why join reordering matters**  
One of the optimizer's most powerful capabilities is choosing the order in which to join tables. Filtering out most rows early (with a selective table first) can reduce work by orders of magnitude. For example:

```
Scenario: Join Customers (1M rows) with PremiumCustomers (500 rows)
Bad order:  Scan Customers (1M rows), then look up each in PremiumCustomers
Good order: Scan PremiumCustomers (500 rows), then look up each in Customers
Difference: 2000× less work with the good order
```

**FORCE ORDER prevents this optimization entirely.**

**XML signal**  
The StatementText contains `OPTION (FORCE ORDER)` or `OPTION (FORCEORDER)`.

**Fix options**
1. **Remove the hint** — and let the optimizer reorder.
2. **Fix root cause** — if FORCE ORDER was added because the optimizer kept choosing a bad order, fix that:
   - Update statistics on all tables in the join
   - Add missing indexes
   - Consider whether the join logic itself is wrong (N10 — cartesian product?)

**Note:** There are rare legitimate cases for FORCE ORDER — e.g., when a specific join order is required for correctness in certain recursive or correlated queries. Validate before removing.

---

### S20 — RECOMPILE Hint with Expensive Compile

**What it means**  
The query uses `OPTION (RECOMPILE)`, which forces SQL Server to discard and rebuild the execution plan on *every single execution*. This check fires when compilation is also expensive (≥ 500ms CPU) — meaning every execution pays a heavy compilation tax.

**Why RECOMPILE is used**  
`OPTION (RECOMPILE)` is a valid solution for parameter sniffing — where a plan compiled for one parameter value performs badly for other values. By recompiling every time, SQL Server builds a plan tailored to the current parameter values.

**When it becomes a problem**  
For low-frequency queries (once per minute or less), even a 2-second compilation overhead is acceptable. For high-frequency queries (100/second), 2,000ms × 100/s = 200 seconds of compilation CPU per second — which will saturate all server CPUs.

**XML attributes**
```xml
<StmtSimple StatementText="SELECT ... OPTION (RECOMPILE)"
            CompileCPU="2340"/>
```

**Fix options**

1. **Remove RECOMPILE and use OPTIMIZE FOR** — builds a plan for a representative value:
```sql
-- Instead of:
SELECT * FROM Orders WHERE CustomerId = @id OPTION (RECOMPILE)

-- Use a typical value:
SELECT * FROM Orders WHERE CustomerId = @id
OPTION (OPTIMIZE FOR (@id = 12345))  -- plan built assuming @id=12345
```

2. **Use local variable sniffing prevention** — local variables prevent sniffing while avoiding recompile:
```sql
CREATE PROCEDURE GetOrders @id INT AS
DECLARE @local_id INT = @id  -- optimizer can't sniff local variables
SELECT * FROM Orders WHERE CustomerId = @local_id
```

3. **Filtered indexes** — create separate indexes for different value ranges:
```sql
-- For a Status column where 'Active' = 99% and 'Closed' = 1% of data:
CREATE INDEX IX_Orders_Active ON dbo.Orders (CustomerId) WHERE Status = 'Active'
CREATE INDEX IX_Orders_Closed ON dbo.Orders (CustomerId) WHERE Status = 'Closed'
```

**Related checks:** S7 (high compile CPU), N32 (OPTIMIZE FOR UNKNOWN)

---

### S21 — Recursive CTE Without Max Recursion

**What it means**  
The query uses a recursive Common Table Expression but does not specify `OPTION (MAXRECURSION N)`. SQL Server's default recursion limit is 100 levels. If the hierarchy data is deeper than that — or contains a cycle — the query will fail with error 530 ("The statement terminated. The maximum recursion 100 has been exhausted").

**Why it matters**  
In production data, hierarchies that were designed to be shallow can grow unexpectedly. An employee hierarchy that is 4 levels deep today can become 150 levels deep after a reorganisation. Without an explicit limit, that will cause unexpected errors rather than controlled behavior.

**Example — problem**
```sql
WITH OrgChart AS (
    SELECT EmployeeId, ManagerId, 0 AS Level
    FROM dbo.Employees
    WHERE ManagerId IS NULL          -- anchor: top of tree

    UNION ALL

    SELECT e.EmployeeId, e.ManagerId, oc.Level + 1
    FROM dbo.Employees e
    JOIN OrgChart oc ON e.ManagerId = oc.EmployeeId  -- recursive member
)
SELECT * FROM OrgChart;
-- No MAXRECURSION hint — will fail at depth 101
```

**Fix**
```sql
SELECT * FROM OrgChart
OPTION (MAXRECURSION 500);   -- set to the maximum depth you actually expect
-- OPTION (MAXRECURSION 0) means unlimited — only use if you've verified no cycles
```

Also add a cycle-detection guard for data that might have circular references:
```sql
WITH OrgChart AS (
    SELECT EmployeeId, ManagerId, CAST(EmployeeId AS VARCHAR(MAX)) AS Path
    FROM dbo.Employees WHERE ManagerId IS NULL

    UNION ALL

    SELECT e.EmployeeId, e.ManagerId, oc.Path + ',' + CAST(e.EmployeeId AS VARCHAR(10))
    FROM dbo.Employees e
    JOIN OrgChart oc ON e.ManagerId = oc.EmployeeId
    WHERE oc.Path NOT LIKE '%,' + CAST(e.EmployeeId AS VARCHAR(10)) + ',%'  -- cycle guard
)
SELECT * FROM OrgChart OPTION (MAXRECURSION 1000);
```

---

### S22 — SET ROWCOUNT Active

**What it means**  
The plan was compiled while `SET ROWCOUNT N` was active in the session. This deprecated setting tells SQL Server to stop processing after returning N rows — similar to `TOP (N)` but with important differences that make it dangerous.

**Why `SET ROWCOUNT` is worse than `TOP`**  
- The optimizer does not factor `SET ROWCOUNT` into its cost estimates — it plans as if all rows will be returned, then stops early at runtime. `TOP (N)` is understood by the optimizer and can change the chosen plan shape (e.g., using an ordered index to stop early).
- `SET ROWCOUNT` affects DML statements too — `UPDATE ... SET ROWCOUNT 10` will silently update only 10 rows even if 10,000 match. This is a frequent source of data corruption bugs.
- It affects all statements in the session until turned off — easy to leave active accidentally.

**XML attribute**
```xml
<StmtSimple RowCountAssignment="10" ... />  <!-- [Unverified] attribute; also detect SET ROWCOUNT in the batch text -->
```

**Fix**
```sql
-- Instead of:
SET ROWCOUNT 10
SELECT * FROM dbo.Orders ORDER BY CreatedDate DESC
SET ROWCOUNT 0  -- turn off

-- Use:
SELECT TOP (10) * FROM dbo.Orders ORDER BY CreatedDate DESC
-- The optimizer now knows only 10 rows are needed and can use a row goal
```

**Related checks:** N31 (TOP above scan — the optimizer understands TOP correctly)

---

### S23 — Excessive Parameter Count

**What it means**  
The query's parameter list contains more than 50 parameters. This is unusual for typical queries and indicates either a large number of individual parameters passed to an IN-style query or an auto-generated query with many bound parameters.

**Why it matters**  
Each unique combination of parameter count produces a different plan cache entry. Queries with 200 parameters generate enormous plan cache entries and take disproportionately long to compile and cache. This is a common cause of `PAGELATCH_EX` waits on the plan cache and "out of plan cache" situations on busy servers.

**How it happens**  
ORMs and data-access layers often generate queries like:
```sql
SELECT * FROM Products WHERE ProductId IN (@p1, @p2, @p3, ... @p200)
```
Each distinct set of values (different count or different values) produces a new plan cache entry.

**Fix options**

1. **Table-Valued Parameter** — pass the ID list as a single structured parameter:
```sql
-- Define type once:
CREATE TYPE dbo.IdList AS TABLE (Id INT NOT NULL PRIMARY KEY)

-- Procedure:
CREATE PROCEDURE GetProductsByIds @Ids dbo.IdList READONLY AS
SELECT p.* FROM dbo.Products p JOIN @Ids i ON p.ProductId = i.Id

-- Caller:
DECLARE @ids dbo.IdList
INSERT @ids VALUES (1),(2),(3),...
EXEC GetProductsByIds @ids
```

2. **Staging temp table** — for very large lists, insert into a `#temp` table and join.

3. **STRING_SPLIT** — pass a delimited string (but note N57 — STRING_SPLIT has no statistics; use for small lists only).

**Related checks:** N55 (large IN list expanded to seek ranges)

---

### S24 — Query Store Forced Plan Active

**What it means**  
A Query Store forced plan is controlling this query's execution. Query Store can "force" a specific plan that was previously identified as good — when the query next executes, SQL Server uses the forced plan instead of running the optimizer normally.

**When forcing is useful**  
After a plan regression (e.g., a statistics update caused the optimizer to switch from a fast plan to a slow one), forcing the old good plan is a fast emergency fix that stops the bleeding immediately.

**When it becomes a problem**  
Forced plans are static. They don't adapt to:
- Schema changes (new index that would be faster)
- Data growth (a plan optimal for 1M rows may be terrible at 100M rows)
- Query changes (if the query text changes, the force may silently stop applying)

A forced plan that was correct six months ago may now be the worst possible plan.

**XML attribute**
```xml
<StmtSimple PlanGuideName="QDS_0000000000001234" ... />
```
(Query Store forced plans appear with a `QDS_` prefixed name)

**Fix**  
1. Identify the forced plan: `SELECT * FROM sys.query_store_plan WHERE is_forced_plan = 1`
2. Determine the root cause of the original regression (stale statistics? dropped index? parameter sniffing?)
3. Fix the root cause, then unforce the plan and test:
```sql
EXEC sys.sp_query_store_unforce_plan @query_id = 123, @plan_id = 456
```

**Related checks:** N36 (Forced Plan via plan guide or USE PLAN hint — similar issue, different mechanism)

---

### S25 — Interleaved Execution (MSTVF) Active

**What it means**  
SQL Server is using *interleaved execution* for a multi-statement table-valued function (MSTVF). This is a SQL 2017+ feature (compatibility level 140+) that addresses one of the most persistent problems with MSTVFs: their row estimates were always 1 or 100, regardless of actual output.

**How interleaved execution works**  
Instead of estimating MSTVF output at compile time (and always getting it wrong), SQL Server pauses optimization when it reaches the MSTVF, executes it once to count the actual output rows, then resumes optimization with the real count. This typically produces dramatically better downstream plans.

**Why this check fires as Info**  
Interleaved execution is a net positive — this check surfaces it so you can:
1. Confirm it hasn't been disabled by a hint
2. Verify the real row count is feeding correctly into the plan (check `EstimateRows` on operators after the MSTVF)

**How to check if it's been suppressed**
```sql
-- This hint disables interleaved execution — watch for it in query text:
OPTION (USE HINT('DISABLE_INTERLEAVED_EXECUTION_TVF'))
```

**Related checks:** N13 (MSTVF bad row estimate — what happens without interleaved execution), N14 (TVF inside join)

---

### S26 — Batch Mode Adaptive Join Active

**What it means**  
SQL Server is deferring the choice between Hash Join and Nested Loops until runtime, based on the actual number of rows flowing into the join. This is a SQL 2019+ feature (compatibility level 150+) called *batch mode adaptive join*.

**How it works**  
The optimizer sets an *adaptive threshold*. When execution reaches the join operator:
- If actual rows < threshold → use Nested Loops (better for small inputs)
- If actual rows ≥ threshold → use Hash Match (better for large inputs)

This avoids the classic failure mode where a plan compiled for small inputs gets a Nested Loops join that performs catastrophically when a large input arrives at runtime (or vice versa).

**Why this check fires as Info**  
Adaptive joins are a net positive. The check surfaces it so you can:
1. Confirm the feature is available (compat level 150+ required)
2. Verify the threshold is calibrated correctly — if the query always takes one path, the adaptivity is not helping
3. Identify cases where the adaptive threshold fires unexpectedly, which may indicate parameter sniffing is still causing a plan shape mismatch

**Related checks:** N18 (row-mode adaptive join — the SQL 2017 predecessor), N21 (bad row estimate — the root cause the adaptive join is compensating for)

---

### S27 — Excessive Missing Index Suggestions

**What it means**  
The plan contains more than 5 distinct missing index suggestions. This is unusual — a typical well-structured query against a properly indexed database might have 0–2 suggestions. More than 5 indicates the query is touching multiple tables that all lack appropriate indexes, or that one poorly indexed table generates multiple suggestions for different predicates.

**Why bulk suggestions are misleading**  
SQL Server generates missing index suggestions independently per access pattern. It does not consider:
- Whether suggested indexes overlap (two suggestions for the same table may be served by one index)
- Index maintenance overhead (more indexes = slower writes)
- Whether the suggestions are for rare or frequent access patterns

Creating all suggestions verbatim is almost always wrong.

**Fix**  
Use the `sqlindex-advisor` skill (or follow its merge rules manually):

1. Group suggestions by table
2. Check if any suggested key columns overlap — merge overlapping suggestions
3. Rank by `Impact` attribute descending
4. Evaluate the top 2–3 only; do not create all suggestions

```sql
-- Check existing indexes before creating new ones:
SELECT i.name, i.type_desc, ic.key_ordinal, c.name AS column_name
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('dbo.YourTable')
ORDER BY i.index_id, ic.key_ordinal
```

**Related checks:** N34 (wide index suggestion — fires when individual suggestions are already too wide), N2 (Eager Index Spool — SQL Server building indexes at runtime because no permanent ones exist)

---

## Node-Level Checks (N1–N60)

These checks examine individual operators within the plan tree.

These checks examine individual operators within the plan tree.

---

### N1 — Filter Late in Plan

**What it means**  
A `Filter` operator is applying a predicate and discarding rows *after* an expensive operation (a join, a scan, etc.) has already processed them. You're paying full price to fetch, join, and process data that gets thrown away immediately afterwards.

**Why it matters**  
In a well-optimized plan, filters are applied as early as possible — ideally during an Index Seek that only retrieves matching rows from the start. A Filter operator late in the plan means the optimizer couldn't push the condition closer to the data source.

**How to spot it in SSMS**  
Look for a `Filter` box with an expensive subtree feeding into it. The tooltip on the Filter will show the predicate. The tooltip on its child operator will show its cost — if that cost is ≥ 25% of the plan, the filter is too late.

**Example — problem**
```sql
-- SQL Server can't push the derived column filter into the index:
SELECT * FROM (
    SELECT *, YEAR(OrderDate) AS OrderYear
    FROM dbo.Orders
    JOIN dbo.Customers ON Orders.CustomerId = Customers.Id
) sub
WHERE OrderYear = 2024
-- The JOIN runs first (millions of rows), THEN year is computed, THEN filter
```

**Example — fix**
```sql
-- Push the filter before the join:
SELECT * FROM dbo.Orders o
JOIN dbo.Customers c ON o.CustomerId = c.Id
WHERE o.OrderDate >= '2024-01-01' AND o.OrderDate < '2025-01-01'
-- Index on OrderDate can now filter BEFORE the join
```

**Related checks:** N3 (function on scan predicate — root cause of many late filters), N31 (TOP above scan)

---

### N2 — Eager Index Spool

**What it means**  
SQL Server is building a **temporary index** in tempdb at query runtime. It does this because no suitable permanent index exists that can satisfy the query's access pattern. The temporary index is built, used for the query, then discarded — all within a single execution.

**Why it's Critical**  
Creating an index is an expensive DDL operation normally done once and maintained forever. Doing it inside a query, on every execution, is an enormous waste of resources. The Eager Spool operator in the plan is SQL Server saying: "I need an index here and there isn't one."

**How to spot it in SSMS**  
Look for an `Index Spool` operator (orange cylinder icon). Hover over it to see the seek predicate — that tells you which columns the missing permanent index should cover.

**Fix**  
Create the permanent index. The Missing Indexes section of the analysis report should suggest the exact index. If it doesn't, look at the spool's seek predicate in SSMS:

```sql
-- Example: Spool seeks on (CustomerId, OrderDate)
CREATE NONCLUSTERED INDEX IX_Orders_Customer_Date
ON dbo.Orders (CustomerId, OrderDate)
INCLUDE (Total, Status)  -- columns referenced elsewhere in the query
```

**Related checks:** N45 (non-index eager spool — different kind of spool)

---

### N3 — Function on Scan Predicate

**What it means**  
A function is being applied to a **column** (not a parameter) in a WHERE clause. This makes the predicate **non-sargable** (not Search ARGument ABLE) — SQL Server cannot use an index to locate matching rows and must read every row.

**The sargable vs non-sargable distinction:**
```sql
-- NON-sargable (function wraps the column):
WHERE YEAR(OrderDate) = 2024        -- can't seek on YEAR(OrderDate)
WHERE UPPER(LastName) = 'SMITH'     -- can't seek on UPPER(LastName)
WHERE SUBSTRING(Code, 1, 3) = 'ABC' -- can't seek on SUBSTRING

-- SARGABLE (function wraps a constant, not the column):
WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'  -- CAN seek
WHERE LastName = 'Smith'            -- CAN seek (use collation for case)
WHERE Code LIKE 'ABC%'              -- CAN seek (front-anchored wildcard)
```

**Impact**  
A table with 100 million rows and a non-sargable predicate on an indexed column must read all 100 million rows. The same table with a sargable predicate might read 1,000 rows via an index seek. This is a 100,000× difference in I/O.

**Common rewrites**

| Non-sargable | Sargable equivalent |
|-------------|---------------------|
| `WHERE YEAR(col) = 2024` | `WHERE col >= '2024-01-01' AND col < '2025-01-01'` |
| `WHERE MONTH(col) = 3` | `WHERE col >= '2024-03-01' AND col < '2024-04-01'` (for a specific year) |
| `WHERE UPPER(col) = 'FOO'` | `WHERE col = 'foo' COLLATE Latin1_General_CI_AS` or add case-insensitive collation to column |
| `WHERE DATEADD(day,-7,GETDATE()) < col` | `WHERE col > DATEADD(day,-7,GETDATE())` — move function to the constant side! |
| `WHERE LEN(col) > 10` | Add a computed persisted column: `LenCol AS LEN(col) PERSISTED` then index it |
| `WHERE ISNULL(col, 0) = 0` | `WHERE col IS NULL OR col = 0` |

**Related checks:** N4 (expensive scan — often caused by N3), N9 (leading wildcard), S12 (implicit conversion blocking seeks)

---

### N4 — Expensive Scan

**What it means**  
A scan operator (Index Scan or Table Scan) is either:
- Reading far more rows than it returns (actual rows read / rows returned > 100×), *or*
- Consuming ≥ 25% of the plan's total estimated cost

**Index Scan vs Index Seek — the core concept**  
An **Index Seek** navigates the B-tree to exactly the matching rows. Like finding a name in a phone book alphabetically.  
An **Index Scan** reads every leaf page of the index from beginning to end. Like reading every page of the phone book to find all Smiths.

For a 100-million-row table, a seek finding 1,000 rows reads ~10 pages. A scan reads ~500,000 pages. The difference in time can be 10,000× or more.

**How to spot it in SSMS**  
Look for `Index Scan` or `Table Scan` operators with high cost percentages. Hover to see:
- `Estimated Number of Rows` vs `Actual Number of Rows`  
- `Estimated I/O Cost` — if this is high, you're reading a lot of data

**Why scans happen even with indexes**  
- No index on the filter column
- The filter column has a function applied (N3)
- Implicit type conversion (S12)
- The optimizer estimated the scan would be cheaper than a seek + key lookup (can be fixed with better statistics or a covering index)
- Leading wildcard LIKE (N9)

**Fix**
```sql
-- Find out which predicate is on the scan (hover in SSMS → Predicate)
-- Then create an index on that column:
CREATE NONCLUSTERED INDEX IX_Orders_Status
ON dbo.Orders (Status)
INCLUDE (OrderId, CustomerId, OrderDate, Total)
-- INCLUDE covers all columns in SELECT so no Key Lookup is needed
```

**Related checks:** N3 (function prevents seek), N9 (leading wildcard), N39 (heap scan), S12 (implicit conversion)

---

### N5 — Key Lookup / RID Lookup

**What it means**  
SQL Server used a nonclustered index to find which rows match the filter (fast, using the index B-tree), but then needed to fetch additional columns not present in the index. This requires a second lookup into the clustered index (Key Lookup) or heap (RID Lookup) for each matching row.

**The two-step problem:**
```
Step 1: Index Seek on IX_Orders_Status (Status = 'Pending')
        → finds 5,000 row locators (clustered key values)

Step 2: Key Lookup × 5,000
        → for each row, jumps to the clustered index to get OrderDate, Total, etc.
        → 5,000 random I/O operations
```

**Why it matters at scale**  
A Key Lookup is a random I/O operation. For 5,000 lookups, you're making 5,000 random reads from disk (or cache misses). This is far slower than 5,000 sequential reads. At 10,000+ lookups, this becomes the dominant cost of the query.

**How to spot it in SSMS**  
The plan will have a `Nested Loops Inner Join` with a `Key Lookup` as the inner child. The number next to the lookup is how many times it executed.

**Fix**
```sql
-- Current index:
CREATE INDEX IX_Orders_Status ON dbo.Orders (Status)

-- Query needs: Status (seek), OrderDate, Total, CustomerId
-- Add them as INCLUDE columns:
DROP INDEX IX_Orders_Status ON dbo.Orders
CREATE INDEX IX_Orders_Status ON dbo.Orders (Status)
INCLUDE (OrderDate, Total, CustomerId)  -- ← covers all needed columns
-- Now: seek finds rows AND has all needed columns → no lookup needed
```

**When it's acceptable**  
If the lookup retrieves < 100 rows AND the Nested Loops + Lookup costs less than a scan of the whole clustered index, the plan is correct. The check flags it as `Info` in that case.

---

### N6 — Sort Spill Risk

**What it means**  
A Sort operator received many more rows than the optimizer expected (actual rows > estimated rows × 10). This means the memory reserved for sorting was likely insufficient — the sort may have spilled to tempdb.

*(This is a risk indicator. For a confirmed actual spill, see N41.)*

**Why sort memory is fixed at compile time**  
The memory grant for Sort is calculated before execution: estimated rows × average row size × sort overhead factor. If estimated rows = 1,000 but actual rows = 50,000, the memory reserved was 50× too small.

**Impact of a sort spill**  
A sort spill writes data to tempdb in multiple passes:
- Level 1 spill: writes once → reads back once → 2× extra I/O
- Level 2 spill: writes twice → 4× extra I/O
- Level 3+ spill: exponentially more I/O

**Fix options**

1. **Fix row estimates** (primary fix):
```sql
UPDATE STATISTICS dbo.TableName WITH FULLSCAN
```

2. **Add an index that pre-sorts the data**:
```sql
-- Query: SELECT * FROM Orders ORDER BY CustomerId, OrderDate
-- Current: Sort operator sorts 1M rows at runtime
-- Fix: Create index in the same order
CREATE INDEX IX_Orders_CustomerId_Date ON dbo.Orders (CustomerId, OrderDate)
-- SQL Server reads from the index in order → no Sort operator needed at all
```

3. **Increase sort memory** (last resort, via Resource Governor):
```sql
ALTER RESOURCE POOL OLTP_POOL WITH (MIN_MEMORY_GRANT_PERCENT = 5)
```

**Related checks:** N41 (confirmed spill), S18 (insufficient grant — root cause), N21 (bad row estimate — root cause)

---

### N7 — Hash Spill Risk

**What it means**  
A Hash Match operator's probe side has far more rows than its build side (probe rows > build rows × 100). If the hash table built from the smaller input was itself undersized due to bad estimates, the hash will spill to tempdb.

**How Hash Match works:**
1. **Build phase**: reads the smaller input and builds an in-memory hash table
2. **Probe phase**: reads the larger input and looks up each row in the hash table

**Why probe >> build is risky**  
A well-sized hash join has a build side of X rows and a probe side of Y rows where the ratio is reasonable. If the optimizer thought the build side would be 100 rows but it's actually 1 million, the hash table is dramatically under-allocated — it will spill.

**Fix options**

1. **Update statistics on both join inputs** — bad estimates on either side affect hash memory sizing.

2. **Reverse the join sides** — hint SQL Server to use the smaller table as the build input:
```sql
SELECT * FROM LargeTable l
INNER HASH JOIN SmallTable s  -- force HASH JOIN with SmallTable as build input
    ON l.Id = s.LargeTableId
```

3. **Add a filter to the build side** — reduce its size so the hash table fits in memory:
```sql
-- Before join, pre-filter the smaller table more aggressively
WITH SmallFiltered AS (
    SELECT * FROM SmallTable WHERE Active = 1 AND Region = 'US'
)
SELECT * FROM LargeTable l JOIN SmallFiltered s ON l.Id = s.LargeTableId
```

---

### N8 — Implicit Conversion in Predicate

**What it means**  
A predicate (WHERE clause or join condition) contains an implicit data type conversion (`CONVERT_IMPLICIT`). Unlike S12 (which blocks seeks entirely), this conversion may still allow a seek but adds CPU overhead on every row evaluated.

**The difference from S12**  
- **S12**: The conversion makes seeks *impossible* — SQL Server must convert the indexed column itself
- **N8**: The conversion is happening but seeks may still work — typically the parameter is being converted, not the column

**Example**
```sql
-- Column is INT, parameter is BIGINT (a "safe" implicit conversion):
WHERE OrderId = @bigintParam
-- SQL Server converts @bigintParam to INT for comparison
-- The index is still usable but there's extra CPU per row
```

**Fix**  
Match the parameter type to the column type. Check the column definition and ensure application code uses the correct ADO.NET/JDBC type.

---

### N9 — Leading Wildcard LIKE

**What it means**  
A `LIKE` predicate starts with `%` or `_`, meaning "match anything before this text." SQL Server cannot use an index to find rows matching this pattern — it must read every row in the table and test each one.

**Why leading wildcards are problematic**  
A B-tree index orders data by value. A `LIKE 'Smith%'` search can seek to the first 'Smith...' entry and scan forward. But `LIKE '%Smith'` has no predictable starting position — 'ASmith', 'BSmith', '123Smith' could all be anywhere in the index. The only option is a full scan.

**Fix options**

1. **Full-text search** — for suffix/contains patterns:
```sql
-- Create a full-text index first:
CREATE FULLTEXT INDEX ON dbo.Users (Email) KEY INDEX PK_Users
-- Then query:
WHERE CONTAINS(Email, '"gmail.com"')
```

2. **Reverse the string** — store and index a reversed version:
```sql
-- Add a computed column with the reversed value:
ALTER TABLE dbo.Users ADD EmailReversed AS REVERSE(Email) PERSISTED
CREATE INDEX IX_Users_EmailReversed ON dbo.Users (EmailReversed)
-- Query becomes front-anchored (fast):
WHERE EmailReversed LIKE REVERSE('%gmail.com')
-- Which is: WHERE EmailReversed LIKE 'moc.liamg%'
```

3. **Computed domain column** — for email domain searches:
```sql
ALTER TABLE dbo.Users
    ADD EmailDomain AS SUBSTRING(Email, CHARINDEX('@', Email)+1, 100) PERSISTED
CREATE INDEX IX_Users_Domain ON dbo.Users (EmailDomain)
WHERE EmailDomain = 'gmail.com'  -- fast equality seek
```

4. **Elasticsearch / dedicated search engine** — for complex text search requirements.

---

### N10 — No Join Predicate (Cartesian Product)

**What it means**  
Two tables are being joined with no matching condition. Every row from Table A is combined with every row from Table B. If A has 1,000 rows and B has 1,000 rows, the result is 1,000,000 rows — 999,000 of which are probably wrong.

This is almost always a bug.

**How it happens**
```sql
-- Missing ON clause:
SELECT * FROM dbo.Orders, dbo.Customers
-- or with JOIN syntax but wrong condition:
SELECT * FROM dbo.Orders o
JOIN dbo.Customers c ON 1 = 1  -- always true = cross join
-- or:
SELECT * FROM dbo.Orders o
JOIN dbo.Customers c ON o.CustomerId > 0  -- not an equi-join
```

**Why it's Critical**  
Even "small" tables produce explosive results:
- Orders (10K rows) × Customers (5K rows) = 50 million rows
- On large tables this can produce billions of rows and run for hours

**XML signal**
```xml
<RelOp ...>
  <NestedLoops Optimized="false">
    <Warnings NoJoinPredicate="true"/>
```

**Fix**
```sql
-- Add the correct join condition:
SELECT * FROM dbo.Orders o
JOIN dbo.Customers c ON o.CustomerId = c.CustomerId
```

If a cross join is truly intentional (generating all combinations for a report), add a comment to suppress future alerts.

---

### N11 — Missing Statistics

**What it means**  
An operator's predicate references a column for which SQL Server has no statistics. Without statistics, the optimizer uses a fixed default selectivity (typically 1 row or a hardcoded percentage). This default is almost always wrong.

**XML element**
```xml
<Warnings>
  <ColumnsWithNoStatistics>
    <ColumnReference Database="DB" Schema="dbo" Table="Orders" Column="Notes"/>
  </ColumnsWithNoStatistics>
</Warnings>
```

**Common reasons statistics are missing**
- `AUTO_CREATE_STATISTICS` is OFF on the database
- Column was added to the table after statistics were created
- Column is a computed column that's not persisted
- Statistics were manually dropped and not recreated

**Fix options**

1. **Create the missing statistics**:
```sql
CREATE STATISTICS stat_Orders_Notes ON dbo.Orders (Notes)
```

2. **Enable auto-create** (usually the right choice for OLTP):
```sql
ALTER DATABASE YourDB SET AUTO_CREATE_STATISTICS ON
```

3. **Update all statistics** with a full scan for maximum accuracy:
```sql
EXEC sp_updatestats  -- updates stale statistics
-- or:
UPDATE STATISTICS dbo.Orders WITH FULLSCAN  -- full scan, more accurate
```

---

### N12 — Backward Scan

**What it means**  
SQL Server is reading an index in reverse order (high values to low values) instead of the natural forward direction. This happens when the ORDER BY direction doesn't match the index key direction.

**Example**
```sql
-- Index: CREATE INDEX IX_Orders_Date ON dbo.Orders (OrderDate ASC)
-- Query:
SELECT TOP 10 * FROM dbo.Orders ORDER BY OrderDate DESC
-- SQL Server must read the ASC index backwards to produce DESC results
```

**Why it's slower**  
Index B-trees are optimized for forward traversal. Backward traversal has higher CPU cost per page and makes prefetch less effective. The performance difference is typically 10–30% on large scans.

**Fix**
```sql
-- Create a DESC index matching the ORDER BY:
CREATE INDEX IX_Orders_Date_Desc ON dbo.Orders (OrderDate DESC)
-- Or add both directions:
CREATE INDEX IX_Orders_Date_Both ON dbo.Orders (OrderDate ASC)
-- SQL Server can now use this forward OR backward efficiently
```

---

### N13 — MSTVF Bad Row Estimate

**What it means**  
A multi-statement table-valued function (MSTVF) appears in the query. SQL Server cannot look inside an MSTVF to estimate output rows — it always uses a hardcoded default (1 row in pre-2019, 100 rows in SQL 2019 compatibility level 150 with Interleaved Execution). The actual output could be millions of rows.

**Multi-statement TVF structure (the problem):**
```sql
CREATE FUNCTION dbo.GetActiveOrders(@startDate DATE)
RETURNS @results TABLE (OrderId INT, Total DECIMAL)
AS
BEGIN
    INSERT INTO @results
    SELECT OrderId, Total FROM dbo.Orders WHERE OrderDate >= @startDate
    -- Can also have complex logic, conditionals, multiple inserts...
    RETURN
END
```

The optimizer sees this as a black box. It has no way to estimate what's inside.

**Inline TVF structure (the fix):**
```sql
CREATE FUNCTION dbo.GetActiveOrders(@startDate DATE)
RETURNS TABLE  -- ← RETURNS TABLE (no AS BEGIN)
AS RETURN (
    SELECT OrderId, Total FROM dbo.Orders WHERE OrderDate >= @startDate
)
-- The optimizer can see through this single SELECT and estimate accurately
```

**Why this matters so much**  
Every operator downstream of an MSTVF is planned for 1 or 100 rows. If the function returns 100,000 rows, all join strategies, memory grants, and operator choices are catastrophically wrong.

**When rewriting isn't possible**  
In SQL Server 2019 with compatibility level 150, enable Interleaved Execution:
```sql
ALTER DATABASE SCOPED CONFIGURATION SET INTERLEAVED_EXECUTION_TVF = ON
```
This re-compiles the query after the MSTVF runs to get actual row counts.

---

### N14 — TVF Inside Join

**What it means**  
A table-valued function is being used as one side of a join. Because TVF row estimates are unreliable (see N13), the join strategy is likely wrong.

**The cascading problem**  
```
TVF returns 50,000 rows (estimated: 1 row)
          ↓
Nested Loops join chosen (optimal for 1 row)
          ↓
At runtime: 50,000 iterations × per-iteration cost
          ↓
Query runs 500× slower than a Hash Join would
```

**Fix**  
Materialize the TVF result into a temp table before joining:
```sql
-- Before:
SELECT * FROM dbo.Orders o
JOIN dbo.GetActiveCustomers() c ON o.CustomerId = c.Id

-- After:
SELECT * INTO #customers FROM dbo.GetActiveCustomers()
CREATE INDEX IX_tmp_customers ON #customers (Id)  -- optional but helpful
SELECT * FROM dbo.Orders o
JOIN #customers c ON o.CustomerId = c.Id
-- #customers has real statistics → optimizer chooses correct join strategy
```

---

### N15 — High Nested Loop Count

**What it means**  
A Nested Loops join executed more than 10,000 times. For each row from the outer input, SQL Server executes the inner input once. At 10,000+ iterations, the cumulative cost of all those inner executions becomes substantial.

**When Nested Loops is the right choice**  
Nested Loops is optimal when the outer input has few rows (< ~1,000) AND the inner input can be accessed via an index seek. In that case, each iteration is a fast O(log n) seek.

**When it becomes a problem**  
At 10,000+ iterations, the cumulative cost of 10,000 separate seeks — even fast ones — exceeds what a single Hash Match scan would cost. Plus, at this scale, the optimizer almost certainly *chose* Nested Loops based on a bad row estimate (it thought there would be far fewer outer rows).

**Fix options**

1. **Add an index on the inner side's join columns** — if one doesn't exist, each iteration is a full scan:
```sql
-- If joining Orders to OrderDetails on OrderId:
CREATE INDEX IX_OrderDetails_OrderId ON dbo.OrderDetails (OrderId)
```

2. **Switch to Hash Match or Merge Join**:
```sql
SELECT * FROM dbo.Orders o
INNER HASH JOIN dbo.OrderDetails d ON o.OrderId = d.OrderId
-- Or use MERGE JOIN if both sides can be pre-sorted
```

3. **Fix the row estimate causing the wrong plan choice** — see N21.

---

### N16 — Busy Loop Pattern

**What it means**  
A Nested Loops join has actual rebinds (new outer values requiring a fresh inner scan) far exceeding rewinds (same outer value, inner result cached). High rebinds with low rewinds means the spool/cache on the inner side provides no benefit — the outer loop generates too many unique values.

**Rebinds vs Rewinds explained:**
- **Rewind**: outer input sends the same value again → inner result is cached → no re-execution
- **Rebind**: outer input sends a new value → inner input must be re-executed

A high rebind count means the cache is constantly being invalidated — the spool exists but never helps.

**Common cause — row goal interference**  
This often occurs when a `TOP`, `EXISTS`, or `IN` clause causes SQL Server to apply a row goal: it estimates far fewer outer rows than actually arrive (because it's optimizing for early termination). At runtime, all rows arrive and the loop runs far more than planned.

**Fix**
```sql
-- Disable row goal interference (SQL 2016+):
SELECT * FROM dbo.Orders o
WHERE EXISTS (SELECT 1 FROM dbo.OrderDetails d WHERE d.OrderId = o.OrderId)
OPTION (DISABLE_OPTIMIZER_ROWGOAL)

-- Or restructure to avoid the row goal:
SELECT DISTINCT o.OrderId FROM dbo.Orders o
JOIN dbo.OrderDetails d ON o.OrderId = d.OrderId
```

---

### N17 — Row Goal Applied

**What it means**  
The optimizer reduced its row estimates for this operator because the query has a `TOP`, `EXISTS`, `IN`, or `FAST N` clause. The optimizer detected it only needs to return N rows and chose a plan optimized for stopping early.

**When it's beneficial**  
```sql
-- "Does any order exist from 2024?" — only need 1 matching row:
IF EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderDate >= '2024-01-01')
-- Row goal: optimizer builds plan to find ONE row fast (correct!)
```

**When it causes problems**  
```sql
-- Want all orders, just sorted with TOP:
SELECT TOP 1000 * FROM dbo.Orders ORDER BY OrderDate DESC
-- Row goal: optimizer optimizes for early exit
-- But all rows are consumed via the ORDER BY → the optimization backfires
-- Plan may do a full scan + sort instead of an efficient index range read
```

**XML attribute**
```xml
<RelOp EstimateRows="50" EstimateRowsWithoutRowGoal="10000">
<!-- Without row goal: 10,000 rows; with row goal: 50 rows — 200× reduction -->
```

**Fix (when it's causing problems)**
```sql
OPTION (DISABLE_OPTIMIZER_ROWGOAL)  -- SQL Server 2016+
-- or:
OPTION (NO_PERFORMANCE_SPOOL)       -- prevents row goal spool creation
```

---

### N18 — Adaptive Join

**What it means**  
An Adaptive Join operator (`IsAdaptive=1`) is present. This is a SQL Server 2017+ feature that defers the choice between Nested Loops and Hash Match until runtime, after it knows the actual row count from the build input.

**How it works:**
1. SQL Server reads the build (smaller) input
2. If actual rows < adaptive threshold: switch to Nested Loops (better for small inputs)
3. If actual rows ≥ adaptive threshold: use Hash Match (better for large inputs)

**This is usually good**  
Adaptive joins are SQL Server protecting itself against parameter sniffing and bad estimates. No action required.

**When to investigate**  
If an Adaptive Join fires and performance is poor, check whether parameter sniffing is causing dramatically different row counts between executions. The adaptive threshold may be set wrong for your data distribution.

---

### N19 — ColumnStore in Row Mode

**What it means**  
A ColumnStore index is being accessed in **row mode** instead of **batch mode**. ColumnStore indexes are designed for batch mode processing, where thousands of rows are processed simultaneously in vectorized operations. Row mode processes one row at a time — completely negating the primary performance benefit of ColumnStore.

**Batch mode vs Row mode — the difference**  
- **Row mode**: each operator calls the next with one row at a time. For 1 million rows: 1 million function calls.
- **Batch mode**: operators exchange batches of ~900 rows. For 1 million rows: ~1,100 batch exchanges. 5–10× less function call overhead.

**Common causes of row mode on ColumnStore**

| Cause | Fix |
|-------|-----|
| Scalar UDF anywhere in query | Rewrite as inline TVF |
| Compatibility level < 130 | `ALTER DATABASE ... SET COMPATIBILITY_LEVEL = 150` |
| Row-store table in same query | Separate the queries or use batch mode hints |
| `OPTION (RECOMPILE)` | Remove if not needed |
| Cursor or RBAR patterns | Rewrite as set-based |

**XML attributes**
```xml
<RelOp StorageType="ColumnStore" EstimatedExecutionMode="Row">
<!-- Should be EstimatedExecutionMode="Batch" for full performance -->
```

---

### N20 — Many-to-Many Merge Join

**What it means**  
A Merge Join is running in "many-to-many" mode, which requires a worktable in tempdb. Normal Merge Join requires that at least one side has unique join keys — this guarantees that when a match is found, you can move forward in both inputs. When both sides have duplicates, SQL Server must store rows from one side temporarily to handle the multiple matches.

**XML attribute**
```xml
<Merge ManyToMany="1">
```

**Why it happens**  
Missing unique constraints or indexes on the join columns. The optimizer doesn't know whether keys are unique unless you've enforced it with a constraint.

**Fix options**

1. **Add a unique constraint** if the data is truly unique:
```sql
ALTER TABLE dbo.Products ADD CONSTRAINT UQ_Products_SKU UNIQUE (SKU)
-- Optimizer now knows SKU is unique → no worktable needed
```

2. **Switch to Hash Match** if uniqueness can't be guaranteed:
```sql
SELECT * FROM TableA a
INNER HASH JOIN TableB b ON a.Id = b.Id
```

---

### N21 — Bad Row Estimate

**What it means**  
The number of rows this operator actually produced differs from what the optimizer predicted by more than 1,000×. This is a severe cardinality estimation error — the optimizer was working with fundamentally wrong data.

**Why this is the root of many problems**  
Row estimates drive almost every plan decision:
- Which join algorithm to use (NL for small inputs, Hash for large)
- How much memory to grant (Sort, Hash Match)
- Whether to use parallelism
- Which index access path to choose

A 1,000× error in row estimates means all of these decisions were made based on completely wrong data. The resulting plan can be orders of magnitude slower than optimal.

**Common causes**

| Cause | Description |
|-------|-------------|
| Parameter sniffing | Plan compiled for @value=1 (1 row), runs with @value=99999 (1M rows) |
| Stale statistics | Table has grown 100× but statistics still reflect old data |
| Ascending key columns | New data is always beyond the histogram — estimate defaults to 0 |
| Correlated columns | Multi-column predicates where columns are correlated |
| Missing statistics | See N11 |

**Fix options**

1. **Update statistics with full scan**:
```sql
UPDATE STATISTICS dbo.Orders WITH FULLSCAN
```

2. **Check for parameter sniffing**:
```sql
-- Add RECOMPILE to test if the plan improves:
SELECT * FROM dbo.Orders WHERE CustomerId = @id
OPTION (RECOMPILE)
-- If this is faster, you have a sniffing problem
```

3. **Create filtered statistics** for skewed columns:
```sql
-- If 99% of orders have Status='Active' and 1% have Status='Closed':
CREATE STATISTICS stat_Closed ON dbo.Orders (CustomerId)
WHERE Status = 'Closed'
-- Gives the optimizer accurate estimates specifically for 'Closed' queries
```

---

### N22 — Expensive Sort

**What it means**  
A Sort operator accounts for ≥ 50% of its own subtree's estimated cost. Sorting is inherently expensive — it must accumulate all input rows, sort them, then release them. It blocks the query pipeline (no rows flow downstream until all rows are sorted).

**Why sorts are expensive**  
1. **Memory** — all rows must be in memory simultaneously (or spill to tempdb)
2. **CPU** — O(n log n) comparison operations
3. **Blocking** — downstream operators can't start until the sort completes
4. **Grant requirement** — sort size is fixed at compile time from row estimates

**When sorts appear in plans**  
- `ORDER BY` with no pre-sorted index
- `GROUP BY` when using Stream Aggregate (which requires pre-sorted input)
- `MERGE JOIN` (both inputs must be sorted)
- `DISTINCT` (requires sorted/hashed input)
- Window functions with `ORDER BY`

**Fix**  
The best fix is always an index that provides pre-sorted data:
```sql
-- Query: SELECT * FROM Orders ORDER BY CustomerId, OrderDate
-- Fix:
CREATE INDEX IX_Orders_Cust_Date ON dbo.Orders (CustomerId, OrderDate)
-- SQL Server reads from the index in order → Sort operator disappears entirely
```

---

### N23 — Remote Query

**What it means**  
Part of the query executes on a remote server (linked server, `OPENQUERY`, or distributed query). Network latency becomes part of query execution time, and the optimizer has very limited knowledge of the remote server's data statistics.

**The optimizer's blind spot**  
For local tables, the optimizer uses statistics to estimate rows. For remote tables, it often assumes 10,000 rows (fixed default). This makes join strategies involving remote tables largely guesswork.

**Fix options**

1. **Pull data locally first** — most reliable approach:
```sql
-- Instead of joining remote directly:
SELECT l.*, r.*
FROM LocalOrders l
JOIN LinkedServer.RemoteDB.dbo.RemoteCustomers r ON l.CustomerId = r.Id

-- Pull remote data into a local temp table:
SELECT * INTO #remoteData FROM LinkedServer.RemoteDB.dbo.RemoteCustomers
-- Now optimizer has statistics on #remoteData
SELECT l.*, r.* FROM LocalOrders l JOIN #remoteData r ON l.CustomerId = r.Id
```

2. **Distributed view** — define a view that abstracts the distribution, allowing better optimization:

3. **Reduce remote data size** — push filters to the remote server via OPENQUERY:
```sql
SELECT * FROM OPENQUERY(LinkedServer,
    'SELECT Id, Name FROM RemoteDB.dbo.Customers WHERE Active = 1')
-- Sends filter to remote server; receives only matching rows
```

---

### N24 — High Cost Operator

**What it means**  
A single operator accounts for ≥ 50% of the plan's total estimated cost. This is your primary optimization target — fixing this operator will have the largest impact on query performance.

This is informational: it tells you *where* to focus, not necessarily *what* is wrong.

**How to use this information**  
Look at what type of operator has the high cost:
- `Table Scan` or `Index Scan` → add an index (N4)
- `Key Lookup` → add INCLUDE columns to the index (N5)
- `Sort` → add a pre-sorting index (N22)
- `Hash Match` → check for bad estimates or missing indexes feeding it
- `Filter` → push the filter earlier (N1)

---

### N25 — Scalar UDF Execution

**What it means**  
A scalar user-defined function (UDF) is being called per-row. Scalar UDFs are opaque to the optimizer — it can't look inside them, can't estimate their cost, and can't parallelize them.

**The per-row execution problem**  
```sql
-- This innocent-looking query:
SELECT OrderId, dbo.GetCustomerDiscount(CustomerId) AS Discount
FROM dbo.Orders

-- Internally runs:
-- dbo.GetCustomerDiscount(1001)  → separate query execution
-- dbo.GetCustomerDiscount(1002)  → separate query execution
-- dbo.GetCustomerDiscount(1003)  → separate query execution
-- ... × number of orders
-- Each call has function call overhead and may execute SQL internally
```

**Three layers of harm**
1. **Per-row overhead** — function call and context switch for every row
2. **No parallelism** — even a 32-core server runs the UDF calls serially
3. **No batch mode** — prevents ColumnStore batch processing (N19)

**How to rewrite as an inline TVF**
```sql
-- Original scalar UDF:
CREATE FUNCTION dbo.GetCustomerDiscount(@customerId INT)
RETURNS DECIMAL(5,2) AS
BEGIN
    DECLARE @disc DECIMAL(5,2)
    SELECT @disc = DiscountRate FROM dbo.CustomerDiscounts
    WHERE CustomerId = @customerId
    RETURN @disc
END

-- Inline TVF replacement (no BEGIN/END, single SELECT):
CREATE FUNCTION dbo.GetCustomerDiscount(@customerId INT)
RETURNS TABLE AS RETURN (
    SELECT DiscountRate AS Discount
    FROM dbo.CustomerDiscounts
    WHERE CustomerId = @customerId
)

-- Usage change:
-- Old: SELECT OrderId, dbo.GetCustomerDiscount(CustomerId) AS Discount FROM Orders
-- New:
SELECT o.OrderId, d.Discount
FROM dbo.Orders o
CROSS APPLY dbo.GetCustomerDiscount(o.CustomerId) d
```

The inline TVF version is fully parallelizable, allows batch mode, and the optimizer can see inside it.

---

### N26 — Exchange Spill

**What it means**  
An Exchange operator (which distributes work across parallel threads) ran out of memory during execution and spilled overflow data to tempdb. The `SpillLevel` attribute indicates severity (1 = single spill, 2+ = recursive/multi-pass spill).

**How exchange operators work**  
In parallel plans, data flows between threads via Exchange operators (`Repartition Streams`, `Distribute Streams`, `Gather Streams`). Each thread produces data into a buffer; the exchange redistributes it to the correct consumer threads. These buffers require memory.

**Fix**  
Exchange spills are almost always caused by bad row estimates that undersized the memory grant. Fix the estimate:
```sql
UPDATE STATISTICS dbo.TableName WITH FULLSCAN
```

---

### N27 — Parallel Thread Skew

**What it means**  
In a parallel plan, work is distributed unevenly across CPU threads. One thread processes most of the data while others sit mostly idle.

**Why this matters**  
Query duration is determined by the **slowest thread**. If Thread 0 processes 9,000,000 rows and Threads 1–7 process 1,000 rows each, the query takes as long as a serial query processing 9 million rows — but consumes 8× the CPU.

**How data is distributed**  
Parallel plans repartition data across threads using a **hash function** on a distribution key column. If that column has highly skewed values (e.g., 80% of orders belong to one customer), most rows hash to the same thread.

**Detecting the skew**  
In the actual plan, right-click a Parallelism operator and select Properties. Look at the `RunTimeCountersPerThread` entries — if one thread has ActualRows >> all others, that's the skewed thread.

**Fix options**
1. **Investigate the distribution key** — which column is used to split work? Is it skewed?
2. **Change the distribution column** — sometimes a join on a less-skewed column produces better thread distribution.
3. **Reduce DOP** — if most threads are idle anyway, fewer threads wastes less CPU: `OPTION (MAXDOP 2)`.

---

### N28 — Lazy Spool Ineffective

**What it means**  
A Lazy Spool is a caching operator that stores query results and replays them when the same input is requested again. It's only beneficial when the outer loop sends the same values repeatedly (high rewinds). This check fires when almost every outer loop value is different (high rebinds) — meaning the cache is constantly invalidated without being useful.

**Rebinds vs Rewinds:**
- **Rewind**: outer input sends the same value again → cache is valid → no re-execution → good
- **Rebind**: outer input sends a new value → cache is invalidated → re-execute → spool overhead with no benefit

**Fix**  
The spool exists because there's no index on the inner side of the join. Adding an index often makes the spool unnecessary:
```sql
-- If the spool is on the inner side of a Nested Loops join on OrderId:
CREATE INDEX IX_OrderDetails_OrderId ON dbo.OrderDetails (OrderId)
-- SQL Server now seeks directly → no spool needed
```

---

### N29 — Join OR Clause

**What it means**  
A join condition contains an `OR` predicate. SQL Server cannot use a B-tree index to satisfy an OR condition in a single scan — it must expand the query into multiple lookup passes or fall back to a full scan.

**Example — problem**
```sql
SELECT p.Name, o.Quantity
FROM dbo.Products p
JOIN dbo.OrderDetails o
    ON o.ProductId = p.Id OR o.BackupProductId = p.Id
-- SQL Server can't seek on "matches either ProductId or BackupProductId"
-- Must scan OrderDetails for every product
```

**Fix using UNION ALL**
```sql
SELECT p.Name, o.Quantity
FROM dbo.Products p
JOIN dbo.OrderDetails o ON o.ProductId = p.Id

UNION ALL

SELECT p.Name, o.Quantity
FROM dbo.Products p
JOIN dbo.OrderDetails o ON o.BackupProductId = p.Id
    WHERE o.BackupProductId IS NOT NULL  -- avoid NULL matches
```

Each branch can independently use an index seek.

---

### N30 — CTE Multiple References

**What it means**  
A CTE (Common Table Expression) is referenced multiple times in the same query. Despite looking like a temporary result set, a CTE has **no materialization** — it is re-evaluated from scratch every time it's referenced.

**Example — problem**
```sql
WITH ExpensiveCTE AS (
    SELECT CustomerId, SUM(Total) AS Spend
    FROM dbo.Orders
    GROUP BY CustomerId         -- runs this aggregation TWICE
)
SELECT a.CustomerId, a.Spend, b.Spend AS PreviousSpend
FROM ExpensiveCTE a
JOIN ExpensiveCTE b ON a.CustomerId = b.CustomerId  -- second reference
```

**Example — fix**
```sql
-- Materialize into a temp table (executes once, referenced twice):
SELECT CustomerId, SUM(Total) AS Spend
INTO #CustomerSpend
FROM dbo.Orders
GROUP BY CustomerId

CREATE INDEX IX_tmp ON #CustomerSpend (CustomerId)

SELECT a.CustomerId, a.Spend, b.Spend AS PreviousSpend
FROM #CustomerSpend a
JOIN #CustomerSpend b ON a.CustomerId = b.CustomerId
```

**Note:** In some cases the optimizer will internally materialize a CTE — but you cannot rely on this behavior.

---

### N31 — Top Above Scan

**What it means**  
A `TOP N` clause is sitting above a full scan. SQL Server is reading the entire table/index to find the top N rows, when an index could provide them pre-sorted, allowing early termination.

**Example — problem**
```sql
-- No index on OrderDate
SELECT TOP 10 * FROM dbo.Orders ORDER BY OrderDate DESC
-- Plan: Full scan of Orders (1M rows) → Sort (1M rows) → Take top 10
-- Reading 1M rows to return 10
```

**Example — fix**
```sql
CREATE INDEX IX_Orders_Date ON dbo.Orders (OrderDate DESC)
-- Plan: Index seek → read 10 rows from the index tip → done
-- Reading 10 rows to return 10
```

**The dramatic efficiency gain**  
Without the index: O(n) scan + O(n log n) sort.  
With the index: O(1) seek + O(k) forward scan where k = TOP count.

---

### N32 — OPTIMIZE FOR UNKNOWN

**What it means**  
The query uses `OPTION (OPTIMIZE FOR UNKNOWN)`, which instructs the optimizer to ignore the actual parameter values passed in and instead use statistical averages (all-rows density) for estimates.

**When it's useful**  
It avoids parameter sniffing: the plan won't be cached as optimal for one specific value and terrible for others. It produces a "generic" plan suitable for typical values.

**When it's harmful**  
If your data is highly skewed — some values are very common (few rows) and others are rare (many rows) — a "generic" plan may be:
- Too aggressive for common values (over-allocates resources)
- Too conservative for rare values (under-allocates resources)

**Alternative approaches**  
Instead of UNKNOWN, which covers all values equally poorly, target specific problematic executions:
```sql
-- Option 1: Plan for a typical value:
OPTION (OPTIMIZE FOR (@id = 12345))

-- Option 2: Use Plan Store to force specific plans for specific values:
-- (requires Query Store enabled)

-- Option 3: Multiple procedures for different cardinality scenarios:
IF @date < '2020-01-01'
    EXEC GetOldOrders @date  -- plan optimized for large result sets
ELSE
    EXEC GetRecentOrders @date  -- plan optimized for small result sets
```

---

### N33 — NOT IN with Nullable Column

**What it means**  
A `NOT IN` subquery is running against a column that allows `NULL` values. SQL Server has to verify the absence of `NULL` on every outer row iteration, requiring a Row Count Spool with many rewinds.

**Why NULLs make NOT IN expensive**  
In SQL's three-valued logic:
- `5 NOT IN (1, 2, 3)` = TRUE (5 is not in the list)
- `5 NOT IN (1, 2, NULL)` = UNKNOWN (is 5 = NULL? Unknown!)

When the subquery can return NULL, `NOT IN` can never definitively return TRUE — SQL Server must check every row of the subquery result for every outer row.

**Example — problem**
```sql
-- ManagerId is nullable (NULL = top-level manager)
SELECT Name FROM dbo.Employees e
WHERE e.Id NOT IN (SELECT ManagerId FROM dbo.Employees)
-- If ManagerId can be NULL, result set may be empty even with valid non-managers
```

**Example — fix**
```sql
-- Option 1: NOT EXISTS (doesn't have NULL problem):
SELECT Name FROM dbo.Employees e
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Employees m WHERE m.ManagerId = e.Id
)

-- Option 2: Filter NULLs from subquery:
SELECT Name FROM dbo.Employees e
WHERE e.Id NOT IN (
    SELECT ManagerId FROM dbo.Employees WHERE ManagerId IS NOT NULL
)
```

---

### N34 — Wide Index Suggestion

**What it means**  
SQL Server is suggesting a missing index, but the suggestion has more than 4 key columns or more than 5 INCLUDE columns. Wide suggestions typically result from the optimizer combining multiple different query patterns into one index recommendation.

**Why wide indexes are problematic**
- **Maintenance overhead**: every INSERT/UPDATE/DELETE must update all index leaf pages
- **Space**: wide indexes consume significantly more storage
- **False economy**: the index serves many queries mediocrely rather than a few queries well

**How to evaluate a wide suggestion**  
Look at which queries triggered the suggestion. Often:
- Query 1 needs (A, B) INCLUDE (C)
- Query 2 needs (A, D) INCLUDE (E)
- Optimizer suggests (A, B, D) INCLUDE (C, E) — wide!

Better approach: create two narrow targeted indexes, one per query pattern.

---

### N35 — Estimated Plan CE Guess

**What it means**  
For an estimated plan (no runtime data), a scan operator has a selectivity (fraction of rows returned) that exactly matches one of SQL Server's hardcoded fallback values used when no statistics exist.

**Known CE default selectivity values:**
| Percentage | When used |
|-----------|-----------|
| 30% | Inequality predicates (>, <, !=) with no statistics |
| 20% | Some join selectivity defaults |
| 10% | Equality predicates with no statistics |
| 9% | Certain range predicates |
| 16.4% | Multi-predicate defaults in some CE versions |
| 5% | Some inequality defaults |
| 3.33% | 1/3 of 10% for correlated predicates |
| 1% | Minimum selectivity floor |

**Why this matters**  
If you see exactly 30% or exactly 10% selectivity, that's a strong signal: SQL Server didn't actually estimate this from data — it used a fixed constant because there are no statistics for the predicate column.

**Fix**
```sql
CREATE STATISTICS stat_Col ON dbo.TableName (ColumnName)
-- Or enable auto-create:
ALTER DATABASE YourDB SET AUTO_CREATE_STATISTICS ON
```

---

### N36 — Forced Plan

**What it means**  
A plan guide or `USE PLAN` hint is forcing SQL Server to use a specific execution plan. The optimizer's cost-based decisions are overridden entirely.

**Why forced plans are used**  
Usually to fix parameter sniffing or a regression where the optimizer kept choosing a bad plan. Instead of fixing the root cause, the developer captured a good plan and forced it.

**The staleness problem**  
Forced plans become wrong over time:
- Data volumes change
- New indexes are added (the forced plan ignores them)
- Statistics become outdated
- A previously optimal plan is now suboptimal

**XML signal**
```xml
<StmtSimple PlanGuideName="FixForBugXYZ">
<!-- or: StatementText contains "OPTION (USE PLAN '...')" -->
```

**Fix**  
Validate whether the forced plan is still appropriate. Capture a new plan:
```sql
-- Test without the plan guide:
EXEC sp_control_plan_guide N'DISABLE', N'FixForBugXYZ'
-- Run the query and compare performance
-- If performance is now acceptable, delete the guide:
EXEC sp_control_plan_guide N'DROP', N'FixForBugXYZ'
```

---

### N37 — Unmatched Indexes

**What it means**  
An index hint was specified in the query (e.g., `WITH (INDEX = IX_SomeIndex)`), but SQL Server couldn't use the hinted index. The hint was ignored and a different access path was chosen.

**Common reasons a hint goes unmatched**
- The index was dropped or renamed
- Filtered index conditions aren't satisfied by the query's WHERE clause
- The hinted index doesn't cover the columns needed
- NOLOCK/TABLOCK hint conflict with the index type

**XML element**
```xml
<UnmatchedIndexes>
  <Parameterization>
    <Object Database="MyDB" Schema="dbo" Table="Orders" Index="IX_Orders_OldIndex"/>
  </Parameterization>
</UnmatchedIndexes>
```

**Fix**  
Remove the hint and let the optimizer choose. If the hint was there to force a specific access path, achieve the same result properly:
```sql
-- Instead of: WITH (INDEX = IX_Orders_Status)
-- Ensure the index exists and create it if needed:
CREATE INDEX IX_Orders_Status ON dbo.Orders (Status) INCLUDE (CustomerId, OrderDate)
-- Then the optimizer will naturally choose it (no hint needed)
```

---

### N38 — Operator-Level Warnings

**What it means**  
An individual operator (not the overall plan) has embedded warning messages. These are more specific than S11 (plan-level warnings) — they pinpoint the exact operator and execution context of the problem.

**Common operator-level warning types**
- Sort spill — `SpillToTempDb` on the Sort operator
- Hash spill — `SpillToTempDb` on the Hash Match operator
- Residual I/O — excessive rows read vs. returned at the leaf level
- Memory fraction — the operator requested more than its allocated fraction

**Relationship to other checks**  
N38 is a catch-all that fires before specific checks like N41 (confirmed spill). If N41 or other specific checks fire, they're more informative. N38 catches remaining operator-level warnings not covered by other specific checks.

---

### N39 — Heap Scan

**What it means**  
A `Table Scan` operator is reading a **heap** — a table that has no clustered index. The rows in a heap are stored in no particular order across the data pages. A heap scan reads every data page to find matching rows.

**Heap vs Clustered Table:**
| Property | Heap | Clustered Table |
|----------|------|-----------------|
| Row order | None (insertion order) | Sorted by cluster key |
| Scan efficiency | Poor (fragmented pages) | Better (ordered sequential I/O) |
| Forwarded records | Yes (UPDATE row growth causes extra indirection) | No |
| Seek support | Only via nonclustered indexes + RID Lookup | Via clustered index key |

**The forwarded record problem**  
When an UPDATE causes a heap row to grow beyond its current page space, the row is moved to a new page and a forwarded record pointer is left behind. Future reads of the original location must follow the pointer — doubling I/O for that row. Over time, heavily-updated heaps accumulate many forwarded records.

**Fix**
```sql
-- Add a clustered index (choose the most frequently used filter/join column):
CREATE CLUSTERED INDEX CIX_Orders_OrderId ON dbo.Orders (OrderId)
-- Now rows are stored in OrderId order; seeks and range scans are efficient
```

---

### N40 — Forced Index / Seek / Scan Hint

**What it means**  
An `INDEX`, `FORCESEEK`, or `FORCESCAN` hint in the query is overriding the optimizer's access path choice. Unlike N37 (where the hint was ignored), here the hint was applied.

**The three hint types:**
- `WITH (INDEX = IX_name)` — forces use of a specific index
- `WITH (FORCESEEK)` — forces an index seek (cannot scan)
- `WITH (FORCESCAN)` — forces an index scan (cannot seek)

**Why hints become wrong over time**  
The hint was usually added because the optimizer was choosing a bad plan. But the underlying reasons for the bad plan (stale statistics, missing indexes) often get fixed later — while the hint remains, preventing the optimizer from choosing the now-better plan.

**Fix process**
```sql
-- 1. Remove the hint
-- 2. Check query performance without it
-- 3. If performance is good: done
-- 4. If performance regresses:
--    a. Update statistics
--    b. Verify indexes are current
--    c. Check for parameter sniffing
--    d. Use sp_create_plan_guide instead of inline hint (easier to manage)
```

---

### N41 — Confirmed Spill to TempDb

**What it means**  
An actual execution plan (not estimated) contains explicit evidence that a Sort or Hash Match operator ran out of memory and wrote overflow data to tempdb. The `SpillLevel` attribute indicates how severe:

| SpillLevel | Meaning | Impact |
|------------|---------|--------|
| 1 | Single-level spill — wrote once to disk | Moderate — 2× I/O overhead |
| 2 | Two-level recursive spill | Severe — 4× I/O overhead |
| 3+ | Multi-level recursive spill | Critical — exponential I/O overhead |

*(Requires an actual execution plan — estimated plans don't record spills.)*

**How it differs from N6/N7**  
N6 and N7 are *risk indicators* based on estimate mismatches. N41 is *confirmed evidence* — the spill actually happened during this execution.

**XML element**
```xml
<Warnings>
  <SpillToTempDb SpillLevel="2" SpilledThreadCount="8"/>
</Warnings>
```

**Example impact**  
A Sort that processes 10 million 100-byte rows needs ~1 GB of memory. If only 100 MB was granted (due to estimating 1 million rows), the Sort writes 9× in extra tempdb I/O:
- Level 1: writes ~900 MB to disk, reads back = 1.8 GB extra I/O
- Level 2: writes partitioned runs, merges = multiple GB of I/O

**Fix steps**
1. Identify the root cause of bad row estimates (parameter sniffing or stale statistics)
2. `UPDATE STATISTICS dbo.TableName WITH FULLSCAN`
3. Test with `OPTION (RECOMPILE)` — if grant improves, it's a sniffing issue
4. If estimates are now correct and spills still occur: add an index to eliminate the Sort, or increase `min memory per query` via Resource Governor

**Related checks:** N6 (sort spill risk estimate), N7 (hash spill risk estimate), N26 (exchange spill), S18 (insufficient grant), N21 (bad row estimate)

---

### N42 — Implicit Conversion Degrades Cardinality

**What it means**  
An implicit type conversion is present in the plan, and it's specifically flagged as affecting cardinality estimates (not seeks). Unlike S12 (which blocks index seeks entirely), the conversion here still allows seeks — but it forces the optimizer to use statistical density averages instead of the column's actual histogram.

**Why histograms can't be used through conversions**  
A histogram for an INT column stores INT values. If your parameter is BIGINT, the optimizer can't directly look up BIGINT values in the INT histogram — it has to fall back to using the overall column density (average selectivity), which may be wildly inaccurate for specific values.

**Example**
```sql
-- Column: OrderId INT  |  Parameter: @id BIGINT
WHERE OrderId = @id
-- Histogram shows: value 12345 occurs 50,000 times (0.05% of 100M rows)
-- But optimizer can't use histogram → uses density = 1% → estimates 1M rows
-- Plan built for 1M rows when only 50K exist
```

**Fix**  
Match the parameter type to the column type:
```sql
DECLARE @id INT = 12345  -- not BIGINT
SELECT * FROM dbo.Orders WHERE OrderId = @id
```

---

### N43 — Residual Predicate on Index Seek

**What it means**  
An Index Seek has two types of predicates:
- **Seek predicate**: applied during B-tree navigation — narrows the search to a small range of leaf pages
- **Residual predicate**: applied at the leaf level *after* seeking — filters out rows that the seek retrieved but don't fully satisfy the query

When the residual predicate discards most of what the seek retrieved (rows read / rows returned > 10×), the seek is doing far more I/O than necessary.

**Example — the problem**
```sql
-- Index: CREATE INDEX IX_Orders_Status ON dbo.Orders (Status)
-- Query: SELECT * FROM Orders WHERE Status = 'Pending' AND YEAR(OrderDate) = 2024

-- Seek predicate: Status = 'Pending' → seeks to 50,000 Pending rows
-- Residual predicate: YEAR(OrderDate) = 2024 → keeps 2,000, discards 48,000
-- Read 50,000 rows to return 2,000 → 25× waste
```

**How to fix**  
Add the residual column as a key column (not INCLUDE) in the index:
```sql
-- Bad index (OrderDate as INCLUDE):
CREATE INDEX IX_Orders_Status ON dbo.Orders (Status)
INCLUDE (OrderDate)  -- can't seek on INCLUDE columns

-- Good index (OrderDate as key):
CREATE INDEX IX_Orders_Status_Date ON dbo.Orders (Status, OrderDate)
-- Now seek predicate: Status = 'Pending' AND OrderDate range
-- Only reads matching rows → no residual waste
```

**Note:** The residual predicate must also be made sargable (see N3). `YEAR(OrderDate) = 2024` can't be a seek predicate regardless of index structure.

---

### N44 — Many Joins (Greedy Optimizer Threshold)

**What it means**  
The plan contains 8 or more join operators. SQL Server's query optimizer uses different strategies for join reordering based on complexity:

| Join count | Strategy | Quality |
|-----------|---------|---------|
| 1–7 tables | Exhaustive search — tries all permutations | Optimal |
| 8–11 tables | Greedy search with limited heuristics | Good |
| 12+ tables | Greedy with aggressive pruning | May miss optimal |

**Why the threshold matters**  
With 8 tables, there are 40,320 possible join orderings. With 12 tables: 479 million. Exhaustive search becomes computationally infeasible, so the optimizer switches to greedy heuristics that make locally reasonable but globally suboptimal choices.

**How to know if it's causing problems**  
Check for S5 (compile timeout) or S7 (high compile CPU) alongside N44 — these indicate the optimizer is working very hard on your many-join query.

**Fix**  
Break the query into stages:
```sql
-- 12-table query → split into 3 stages of 4 tables each
SELECT ... INTO #stage1 FROM t1 JOIN t2 JOIN t3 JOIN t4
SELECT ... INTO #stage2 FROM #stage1 JOIN t5 JOIN t6 JOIN t7
SELECT * FROM #stage2 JOIN t8 JOIN t9 JOIN t10 JOIN t11 JOIN t12
-- Each stage uses exhaustive optimization → overall result is better
```

**Related checks:** S5 (compile timeout — often co-occurs with N44), S7 (high compile CPU)

---

### N45 — Non-Index Eager Spool (Halloween Protection / Subquery)

**What it means**  
An Eager Spool that is *not* building a temporary index (see N2 for that case) but rather caching an entire subtree result into a tempdb worktable. There are two main causes:

**Cause 1: Halloween Protection**  
Named after a 1976 bug where an UPDATE that increased employee salaries ran until the power went out (it kept updating the newly-raised salaries again). SQL Server prevents this by separating the read and write phases using a spool:

```sql
-- This query reads from and writes to the same table:
UPDATE dbo.Orders SET Status = 'Processed'
WHERE OrderId IN (
    SELECT OrderId FROM dbo.Orders WHERE Status = 'Pending'
)
-- Without the spool, the UPDATE could read rows it just wrote
-- The spool caches all Pending orders before any writes begin
```

For Halloween protection, the spool is unavoidable with this query structure.

**Cause 2: Subquery Materialisation**  
The optimizer chose to materialize a subquery into a worktable:

```sql
SELECT * FROM dbo.Orders o
WHERE o.Total > (SELECT AVG(Total) FROM dbo.Orders)
-- The average subquery may be materialized once and reused for each outer row
```

**Fix for Halloween Protection**  
Use a staging temp table to separate reads and writes:
```sql
-- Capture rows to update first:
SELECT OrderId INTO #toProcess FROM dbo.Orders WHERE Status = 'Pending'
-- Now update using the temp table (no self-referential risk):
UPDATE o SET Status = 'Processed'
FROM dbo.Orders o JOIN #toProcess t ON o.OrderId = t.OrderId
```

**Fix for subquery materialisation**  
Rewrite as a JOIN or CTE to give the optimizer more options:
```sql
-- Instead of scalar subquery:
SELECT o.* FROM dbo.Orders o
JOIN (SELECT AVG(Total) AS AvgTotal FROM dbo.Orders) avg_orders
    ON o.Total > avg_orders.AvgTotal
```

---

### N46 — Window Aggregate Without Partition

**What it means**  
A window function (using `OVER(...)`) has no `PARTITION BY` clause, meaning it runs across the entire result set as a single partition. SQL Server must process every row before it can return any result.

**When this is expected**  
Global ranking across all rows is a legitimate pattern:
```sql
SELECT *, ROW_NUMBER() OVER (ORDER BY SaleAmount DESC) AS GlobalRank
FROM dbo.Sales
```
Here, no partition is intentional — you want a global rank.

**When this is a problem**  
If the intent was to rank *within* groups (e.g., per customer, per region) but the `PARTITION BY` was accidentally omitted:
```sql
-- Probably wrong — ranks all orders globally, not per customer:
SELECT *, ROW_NUMBER() OVER (ORDER BY OrderDate) AS CustomerOrderNum
FROM dbo.Orders

-- Correct — ranks per customer:
SELECT *, ROW_NUMBER() OVER (PARTITION BY CustomerId ORDER BY OrderDate) AS CustomerOrderNum
FROM dbo.Orders
```

**Performance impact**  
Without partitioning, the entire dataset must be sorted and processed as a single unit. Adding `PARTITION BY` allows parallelism across partitions and often enables better index usage.

**Related checks:** N47 (window frame spool risk), N22 (expensive sort — windows without partitions require sorts)

---

### N47 — Window Aggregate RANGE Frame (Spool Risk)

**What it means**  
The window function uses `RANGE UNBOUNDED PRECEDING` (which is the default when you write `OVER (ORDER BY col)` without specifying a frame). SQL Server implements RANGE frames using an internal spool that writes one pass per row — this is significantly slower than the `ROWS` frame equivalent.

**RANGE vs ROWS — what's the difference?**

```sql
-- ROWS: processes exactly the physical rows you specify
SUM(Amount) OVER (ORDER BY OrderDate ROWS UNBOUNDED PRECEDING)
-- Processes rows in order, accumulating as it goes — no spool needed

-- RANGE: processes rows with the same ORDER BY value together
SUM(Amount) OVER (ORDER BY OrderDate RANGE UNBOUNDED PRECEDING)
-- If two rows have the same OrderDate, they're in the same "range frame"
-- SQL Server must check all ties before finalising each row's value
-- Requires an internal spool
```

**When the distinction matters**  
If your ORDER BY column has no duplicate values (e.g., a unique timestamp or identity), `RANGE` and `ROWS` produce identical results. Use `ROWS` — it's faster.

If your ORDER BY column has duplicates and you need all ties to receive the same cumulative total, `RANGE` is semantically required.

**Fix**
```sql
-- Change RANGE (implicit default) to ROWS:
SUM(SaleAmount) OVER (
    PARTITION BY RegionId
    ORDER BY SaleDate
    ROWS UNBOUNDED PRECEDING   -- explicit ROWS, no spool
)
```

*(Requires actual plan to confirm performance impact)*

**Related checks:** N46 (window without partition), N6 (sort spill — window operations with large datasets)

---

### N48 — In-Memory OLTP Cross-Container Join

**What it means**  
A join is happening between a memory-optimized table (In-Memory OLTP, also called Hekaton) and a traditional disk-based rowstore table. This forces a *cross-container* execution that prevents natively compiled execution and often limits parallelism.

**How In-Memory OLTP is supposed to work**  
Memory-optimized tables are designed to be accessed via natively compiled stored procedures — procedures compiled directly to machine code, bypassing the SQL Server interpreted execution engine. This eliminates latching, lock overhead, and interpretation cost.

**What happens in a cross-container join**  
When a query mixes memory-optimized and disk-based tables, SQL Server cannot use native compilation for the memory-optimized side. Instead it must use an interpreted execution context that crosses between the two storage engines. This is slower than pure rowstore in many cases.

**XML indicator**
```xml
<RelOp ... >
  <IndexScan Storage="MemoryOptimized" ... />   <!-- in-memory table -->
</RelOp>
<RelOp ... >
  <IndexScan Storage="RowStore" ... />           <!-- disk-based table -->
</RelOp>
```

**Fix**  
Separate the workloads:
```sql
-- Instead of joining directly:
SELECT m.*, d.*
FROM dbo.InMemoryOrders m          -- memory-optimized
JOIN dbo.DiskProducts d ON m.ProductId = d.Id  -- disk-based

-- Read the disk-based data into a temp table first:
SELECT Id, Name, Price INTO #products FROM dbo.DiskProducts WHERE ...
-- Now join in a natively compiled context (or a separate query):
SELECT m.*, p.*
FROM dbo.InMemoryOrders m
JOIN #products p ON m.ProductId = p.Id
```

---

### N49 — Columnstore Segment Elimination Not Occurring

**What it means**  
A columnstore index scan is reading every segment (compressed rowgroup) in the index — none are being eliminated by the query's WHERE clause predicate. Segment elimination is the primary mechanism that makes columnstore indexes fast for analytical queries.

**How segment elimination works**  
Each columnstore segment stores the minimum and maximum value for its column. Before reading a segment, SQL Server checks whether the predicate can be satisfied by any value in [min, max]. If not, the entire segment is skipped — typically 100,000+ rows per segment.

**Why elimination might not occur**  
- The filter column is not the columnstore ordering column — values are scattered across all segments, so every segment overlaps with the predicate
- The predicate uses a non-sargable expression (function on the column)
- The columnstore index was created without a natural sort order for this query pattern

**XML indicators** *(requires actual plan)*
```xml
<RunTimeCountersPerThread SegmentReads="48" SegmentSkips="0" ... />
<!-- 0 out of 48 segments eliminated = full scan -->
```

**Fix options**

1. **SQL 2022+ — ordered columnstore index:**
```sql
CREATE CLUSTERED COLUMNSTORE INDEX CCI_Sales
ON dbo.Sales ORDER (SaleDate)
-- Rows are sorted by SaleDate before compression
-- Segments now have tight min/max ranges for SaleDate predicates
```

2. **Ensure data is loaded in sort order** — for older SQL versions, insert rows sorted by the filter column so segments naturally have tight ranges.

3. **Avoid functions on the filter column** — `WHERE YEAR(SaleDate) = 2024` prevents elimination; `WHERE SaleDate >= '2024-01-01' AND SaleDate < '2025-01-01'` enables it.

*(Requires actual plan)*

**Related checks:** N50 (delta store read), N3 (function on scan predicate)

---

### N50 — Columnstore Delta Store Read

**What it means**  
The columnstore index scan is reading rows from the *delta store* — the uncompressed, rowstore-format buffer where newly inserted rows live before being compressed into columnstore segments. Delta store rows are scanned row-by-row and do not benefit from batch mode or segment elimination.

**How the delta store works**  
Columnstore compression is CPU-intensive and only efficient on large batches. Rather than compressing every insert immediately, SQL Server accumulates inserted rows in a delta store (up to 1,048,576 rows per rowgroup). A background thread called the *tuple mover* periodically compresses closed delta stores into proper columnstore segments.

**When it's expected**  
Immediately after bulk inserts, delta store reads are normal. The data will be compressed once the tuple mover runs or when `REORGANIZE` is called.

**When it's a problem**  
If delta stores persist for hours or days with large row counts, the tuple mover is not keeping up. Queries will consistently scan uncompressed rows.

**How to check** *(requires actual plan)*
```xml
<RunTimeCountersPerThread DeltaStoreRows="150000" SegmentSkips="12" ... />
```

**Fix**
```sql
-- Force compression of open delta stores:
ALTER INDEX CCI_Sales ON dbo.Sales
REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)

-- Check current rowgroup state:
SELECT state_description, COUNT(*) AS rowgroup_count, SUM(total_rows) AS total_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.Sales')
GROUP BY state_description
```

**Related checks:** N49 (segment elimination), N51 (batch mode on rowstore)

---

### N51 — Batch Mode on Rowstore (SQL 2019+)

**What it means**  
SQL Server is using batch mode execution on a traditional rowstore (B-tree) table — not a columnstore index. This is a SQL 2019 feature (compatibility level 150+) that extends batch mode's performance advantages beyond columnstore-only workloads.

**What batch mode is**  
Traditional SQL Server execution processes one row at a time through each operator (row mode). Batch mode processes 64–900 rows simultaneously in a vectorized operation, using CPU SIMD instructions. For aggregation and hash join-heavy analytical queries, batch mode is typically 2–4× faster.

Before SQL 2019, batch mode required a columnstore index to be present in the query. SQL 2019 removes this restriction.

**Why this fires as Info**  
It's a positive signal — no action required. It surfaces so you can:
1. Confirm the feature is active (compat level 150+ is required; verify with `SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()`)
2. Check whether other similar queries are missing batch mode (scalar UDFs and certain operators block it — see N25 and N58)

**How to verify**
```xml
<RelOp ... ExecutionMode="Batch" ... >
  <IndexScan Storage="RowStore" ... />
```

**Related checks:** N58 (mixed batch/row mode — when batch mode only partially applies), N25 (scalar UDF — blocks batch mode propagation)

---

### N52 — Constant Scan

**What it means**  
A Constant Scan operator produces a fixed set of rows without reading any table. It's the optimizer's way of generating synthetic row sets that are known at compile time.

**When it's expected**  
- `VALUES` clauses in `INSERT ... VALUES` statements
- System functions like `SELECT GETDATE()` that don't need a table
- CTEs that the optimizer folds to a constant at compile time
- The anchor of a recursive CTE

**When it signals a problem**  
An unexpected Constant Scan where a large table was expected often means:
- A `WHERE 1=0` condition (the optimizer determined no rows can ever match)
- A parameter value that makes the predicate always false — e.g., `WHERE Status = @s` where `@s` was `NULL` at compile time (NULL comparisons never match)
- A schema change that invalidated a predicate

```sql
-- This compiles to a Constant Scan — no rows will ever return:
SELECT * FROM dbo.Orders WHERE 1 = 0

-- This may compile to a Constant Scan if @status is sniffed as NULL:
SELECT * FROM dbo.Orders WHERE Status = @status
-- NULL = NULL is never true in SQL, so the optimizer eliminates the scan
```

**Fix**  
Verify the query was compiled with representative parameter values. If the Constant Scan appears in production but not during testing, check for parameter sniffing on `NULL` or unusual values.

**Related checks:** S16 (trivial plan — often accompanies Constant Scans), N21 (bad row estimate — sniffed parameters causing wrong plan shapes)

---

### N53 — Assert Operator

**What it means**  
An Assert operator enforces a constraint check at runtime. SQL Server uses Assert to verify:
- `CHECK` constraint conditions are met
- Referential integrity (FK relationships) is maintained
- Uniqueness constraints are not violated
- `WITH CHECK` on views

**Why it appears in plans**  
For DML statements (INSERT, UPDATE, DELETE), SQL Server must validate constraints after modifying rows. The Assert operator takes each modified row, evaluates the constraint expression, and raises an error (e.g., "The DELETE statement conflicted with the REFERENCE constraint") if it fails.

**When it's a performance concern**  
An Assert that executes millions of times — because the DML affects many rows and the constraint validation is expensive — adds measurable overhead. Common scenario: a FK validation that scans a parent table because the parent table's PK column has no index.

**How to identify which constraint**  
The Assert operator's tooltip in SSMS shows the predicate being evaluated. A `NOT NULL` check looks like `[col] IS NOT NULL`; a FK check looks like `EXISTS (SELECT ... FROM parent WHERE ...)`.

**Fix for high-volume FK validation**
```sql
-- Ensure the parent table has an index on the FK column it's being checked against
-- (It should be the PK, which is always indexed, but composite FKs may miss this)

-- For bulk loads, temporarily disable FK checks:
ALTER TABLE dbo.ChildTable NOCHECK CONSTRAINT FK_ChildTable_Parent
-- ... bulk insert ...
ALTER TABLE dbo.ChildTable WITH CHECK CHECK CONSTRAINT FK_ChildTable_Parent
-- WITH CHECK re-validates all existing rows — omit if you trust the data
```

**Related checks:** N2 (Eager Index Spool — FK validation spool), N10 (no join predicate — accidental cartesian sometimes surfaces through Assert)

---

### N54 — Lazy Spool on Correlated Subquery (Ineffective Cache)

**What it means**  
A Lazy Spool is attempting to cache the inner side of a correlated subquery. A Lazy Spool uses a cache: when the outer input repeats the same value, the spool returns the cached result without re-executing the inner side. But when `ActualRewinds` is very high and `ActualRewinds >> ActualRebinds`, the cache is almost never hitting — meaning the spool provides no benefit and adds overhead.

**Rewinds vs Rebinds**  
- **Rewind**: cache hit — the outer value was the same as last time, return cached result
- **Rebind**: cache miss — new outer value, re-execute the inner side and cache the new result

High rebinds with few rewinds = the outer loop is producing mostly unique values = the spool never gets to use its cache.

**Example — the pattern**
```sql
SELECT o.OrderId, o.Total,
       (SELECT SUM(Total) FROM dbo.Orders WHERE CustomerId = o.CustomerId) AS CustomerTotal
FROM dbo.Orders o
-- The correlated subquery runs once per distinct CustomerId
-- If there are 500,000 distinct customers, there are 500,000 rebinds — no caching benefit
```

**Fix**  
Rewrite the correlated subquery as a JOIN or aggregated CTE:
```sql
WITH CustomerTotals AS (
    SELECT CustomerId, SUM(Total) AS CustomerTotal
    FROM dbo.Orders
    GROUP BY CustomerId
)
SELECT o.OrderId, o.Total, ct.CustomerTotal
FROM dbo.Orders o
JOIN CustomerTotals ct ON o.CustomerId = ct.CustomerId
-- CustomerTotals is computed once; join uses hash or merge
```

*(Requires actual plan)*

**Related checks:** N30 (CTE multiple references — similar materialization issue), N15 (high nested loop count — the outer loop of the spool pattern)

---

### N55 — Large IN List Expanded to Seek Ranges

**What it means**  
An `IN (v1, v2, v3, ...)` predicate with more than 20 values has been converted by SQL Server into individual seek ranges — one range per value. The seek operator navigates the index 20+ times.

**Why this is a problem at scale**  
Above a certain size, multiple index seeks become less efficient than a single scan plus a hash join against the value list. The optimizer cannot accurately estimate cardinality for large IN lists (it uses average density, not actual list size), leading to wrong join strategy choices downstream.

Additionally, each distinct set of literal values produces a separate plan cache entry — 50 queries with 50-item IN lists (different values each time) = 50 plan cache entries.

**Fix**  
Replace the literal IN list with a table-valued parameter or temp table:
```sql
-- Instead of:
SELECT * FROM dbo.Products WHERE ProductId IN (1, 2, 3, ... 200)

-- Use a temp table:
CREATE TABLE #ids (Id INT PRIMARY KEY)
INSERT #ids VALUES (1),(2),(3),...(200)

SELECT p.*
FROM dbo.Products p
JOIN #ids i ON p.ProductId = i.Id
-- The optimizer now has accurate cardinality from the temp table's statistics
```

**For ORMs** generating large IN lists, configure the ORM to use TVPs or batch the lookups into smaller chunks (≤ 20 values per query is a reasonable threshold).

**Related checks:** S23 (excessive parameter count — large IN lists parameterized individually), N15 (nested loops executing many times — what a large seek range list becomes)

---

### N56 — Cross Apply with High-Cost Correlated Inner Side

**What it means**  
A `CROSS APPLY` or `OUTER APPLY` is executing an expensive correlated subquery once per outer row. Unlike a regular join (which the optimizer can freely reorder), a correlated apply must execute its inner side for each outer row in order — the inner side references columns from the outer side that aren't known until each outer row is processed.

**When APPLY is appropriate**  
APPLY is designed for per-row operations that cannot be expressed as a regular join:
- Calling a table-valued function per row
- The inner query has a `TOP (N)` correlated to the outer row
- The inner side must vary structurally based on the outer row

**When it becomes a problem**  
If the inner side is expensive and the outer side is large, the total cost multiplies:
```
Total cost ≈ (inner cost per execution) × (outer row count)
```

If inner cost = 10ms and outer rows = 100,000, the total is 1,000 seconds.

**Fix**  
When the inner side doesn't structurally need to vary per row, rewrite as a regular join:
```sql
-- Expensive APPLY:
SELECT o.*, ca.MaxLineItemAmount
FROM dbo.Orders o
CROSS APPLY (
    SELECT MAX(Amount) AS MaxLineItemAmount
    FROM dbo.LineItems li WHERE li.OrderId = o.OrderId
) ca

-- Rewrite as JOIN with aggregation:
SELECT o.*, li_agg.MaxLineItemAmount
FROM dbo.Orders o
JOIN (
    SELECT OrderId, MAX(Amount) AS MaxLineItemAmount
    FROM dbo.LineItems
    GROUP BY OrderId
) li_agg ON o.OrderId = li_agg.OrderId
-- The aggregation runs once; the optimizer can use hash join
```

*(Requires actual plan)*

**Related checks:** N54 (lazy spool on correlated subquery), N15 (high nested loop count)

---

### N57 — STRING_SPLIT at Scale

**What it means**  
The built-in `STRING_SPLIT` function is being used and has returned more than 10,000 rows. `STRING_SPLIT` has a fixed row estimate of 50 rows, regardless of the actual input string length or the number of delimiters it contains.

**The statistics problem**  
Because STRING_SPLIT is a table-valued function without statistics, every join against it uses the 50-row estimate. If the actual output is 10,000 rows, every downstream operator (joins, aggregations, sorts) is sized for 50 rows. This produces wrong memory grants, wrong join types, and potential spills.

**SQL 2022 improvements**  
SQL 2022 adds an optional third argument `enable_ordinal`:
```sql
SELECT value, ordinal
FROM STRING_SPLIT('a,b,c,d', ',', 1)  -- 1 = enable ordinal column
```
The ordinal allows ordering the results, which was not possible before (STRING_SPLIT previously had no guaranteed order). However, the statistics problem remains.

**Fix options**

1. **For small lists (< 20 values)** — use a literal IN list or a VALUES table (avoid STRING_SPLIT entirely)

2. **For medium lists (20–1,000 values)** — use a temp table with statistics:
```sql
-- Parse in application code, insert into #temp:
INSERT #split_values (Value) VALUES ('a'),('b'),('c'),...
SELECT t.* FROM dbo.TargetTable t JOIN #split_values s ON t.Col = s.Value
```

3. **For large lists** — pass as a Table-Valued Parameter (see S23)

**Related checks:** N13 (MSTVF bad row estimate — same root cause: TVF without statistics), N55 (large IN list — often the reason STRING_SPLIT is used in the first place)

---

### N58 — Columnstore Plan with Mixed Batch/Row Mode Operators

**What it means**  
The plan contains some operators running in batch mode and others running in row mode, despite a columnstore index being present. Batch mode is 2–10× faster for analytical operators — mixed mode means the optimizer could not propagate batch mode through the entire plan, leaving a significant performance gain on the table.

**What blocks batch mode propagation**  
SQL Server processes operators in a pipeline. If any operator in the pipeline cannot run in batch mode, the pipeline switches back to row mode at that point, and all subsequent operators must also run in row mode.

Common blockers:
- **Scalar UDFs** (N25) — always force row mode; rewrite as inline TVF
- **Row-mode-only operators** — certain OUTER APPLY patterns, some XML/spatial functions
- **Compatibility level < 130** — batch mode on columnstore requires compat level 130+; batch mode on rowstore requires 150+
- **Unsupported data types** — varchar(max), xml, and other LOB types in the batch pipeline

**How to spot it**
```xml
<RelOp ExecutionMode="Batch" ... />   <!-- batch mode operator -->
<RelOp ExecutionMode="Row" ... />     <!-- row mode operator — mode switched here -->
```

**Fix**  
1. Find the operator where mode switches from Batch to Row
2. Identify the blocker (scalar UDF, incompatible operator, compat level)
3. Rewrite scalar UDFs as inline TVFs (biggest win)
4. Check compatibility level: `SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()`

**Related checks:** N25 (scalar UDF — most common batch mode blocker), N51 (batch mode on rowstore), N19 (columnstore in row mode — closely related)

---

### N59 — Index Seek on Column With No Statistics

**What it means**  
An index seek is navigating a B-tree using a predicate on a column for which SQL Server has no statistics histogram. Without a histogram, the optimizer cannot estimate how many rows satisfy the predicate — it falls back to a fixed default selectivity (see N35 for the specific default percentages used: 30%, 10%, 9%, 16.4%, or 1%).

**Why this is worse on seeks than scans**  
A seek's selectivity estimate directly determines how many rows are expected to flow out of it. Everything downstream — join types, memory grants, sort memory — is sized from this number. A wrong seek estimate propagates errors through the entire plan.

On a scan, the estimate is at least bounded by the table size. On a seek, the optimizer might estimate 5 rows when 500,000 actually match, causing the plan to choose Nested Loops (appropriate for 5 rows) instead of Hash Join (appropriate for 500,000 rows).

**How to check**
```xml
<RelOp PhysicalOp="Index Seek" ... >
  <Warnings>
    <ColumnsWithNoStatistics>
      <ColumnReference Column="CreatedDate" />
    </ColumnsWithNoStatistics>
  </Warnings>
</RelOp>
```

**Fix**
```sql
-- Let auto-create statistics handle it (if enabled):
-- SQL Server will create statistics the next time the query runs after this
SELECT * FROM sys.databases WHERE is_auto_create_stats_on = 1 AND name = DB_NAME()

-- Or create explicitly for immediate effect:
CREATE STATISTICS [stat_Orders_CreatedDate]
ON dbo.Orders (CreatedDate)
WITH FULLSCAN  -- FULLSCAN for accuracy; default samples a subset

-- Or update all statistics on the table:
UPDATE STATISTICS dbo.Orders WITH FULLSCAN
```

**Related checks:** N11 (columns with no statistics — similar, fires when the warning appears on any operator, not just seeks), N35 (CE guess — the fixed-percentage fallback that fires when the optimizer has to guess)

---

### N60 — Non-Sargable JSON Predicate

**What it means**  
A `JSON_VALUE()` or `JSON_QUERY()` call appears in a WHERE clause or join predicate. JSON path expressions are computed per row — SQL Server cannot use an index seek to jump directly to matching rows. The entire table or index must be scanned, and the JSON function is evaluated for every row.

**What sargable means**  
A predicate is *sargable* (Search ARGument ABLE) if SQL Server can use an index to satisfy it without evaluating every row. `WHERE CustomerId = 5` is sargable — the index can seek to exactly the rows with `CustomerId = 5`. `WHERE JSON_VALUE(Metadata, '$.CustomerId') = '5'` is not — there is no index on the JSON path.

**Example — problem**
```sql
SELECT * FROM dbo.Orders
WHERE JSON_VALUE(Metadata, '$.CustomerId') = '12345'
-- SQL Server scans all rows, extracts CustomerId from JSON for each, then filters
```

**Fix option 1 — Computed column with index (SQL 2016+)**
```sql
ALTER TABLE dbo.Orders
ADD CustomerIdFromJson AS JSON_VALUE(Metadata, '$.CustomerId') PERSISTED

CREATE INDEX IX_Orders_CustomerIdJson ON dbo.Orders (CustomerIdFromJson)
-- Now the predicate can seek the computed column index
```

**Fix option 2 — SQL 2022 JSON index**
SQL 2022 introduces native JSON indexing support:
```sql
-- Create a full-text-style index on the JSON column:
CREATE INDEX IX_Orders_Metadata ON dbo.Orders (Metadata)
-- Queries using JSON_VALUE on this column can now use segment elimination (columnstore)
-- or index seeks (rowstore) depending on the index type
```

**Fix option 3 — Application-layer extraction**  
If the JSON query is infrequent or the result set is small after other filters, accept the scan but ensure other sargable predicates (dates, IDs) are applied first to minimize the rows JSON must evaluate.

**Related checks:** N3 (function on scan predicate — same category of non-sargable filter), N4 (expensive scan — what JSON predicates cause)

---

### S28 — Large Cached Plan (Plan Cache Bloat)

**What it means**  
The compiled plan stored in the plan cache is unusually large. Every cached plan occupies space in the plan cache (a section of buffer pool memory). Very large plans also take longer to match during plan cache lookup on each execution, adding per-call overhead.

**How to spot it**  
`CachedPlanSize` attribute on the `<QueryPlan>` element, in KB.

```xml
<QueryPlan DegreeOfParallelism="4" CachedPlanSize="6144" ...>
```
6,144 KB = 6 MB cached plan — Warning threshold.

**Why plans get large**  
- Queries joining many tables (each join adds operators and output columns)
- Large parameter lists (S23 — > 50 parameters)
- Dynamic SQL with many branches compiled into a single plan
- Deeply nested subqueries or CTEs

**Fix**
```sql
-- Find the largest plans in cache:
SELECT TOP 10
    usecounts,
    size_in_bytes / 1024 AS size_kb,
    LEFT(text, 200) AS sql_preview
FROM sys.dm_exec_cached_plans
CROSS APPLY sys.dm_exec_sql_text(plan_handle)
ORDER BY size_in_bytes DESC;

-- Parameterize the query, split into smaller units, or use sp_executesql
```

**Related checks:** S23 (excessive parameters — common contributor to large plans)

---

### S29 — Memory Request Denied by Server

**What it means**  
The optimizer calculated how much memory the query needed (`RequestedMemory`) but the server could not grant that amount — `GrantedMemory` < `RequestedMemory`. The server was under memory pressure at the moment of execution and reduced the grant. Sort and hash operators will spill to TempDb even though statistics are accurate.

**How to spot it**  
In `MemoryGrantInfo`: `RequestedMemory` > `GrantedMemory` × 1.1 (more than a 10% shortfall).

```xml
<MemoryGrantInfo RequestedMemory="2097152" GrantedMemory="524288" .../>
```
Requested 2 GB, granted only 512 MB — severe reduction.

**Difference from other memory checks**  
- S4 (Grant Wait): the query *waited* to get a grant — this says the grant was *reduced*, not delayed
- S2/S18: focus on over-grant or under-grant relative to actual use — S29 is about server-side denial

**Fix**  
```sql
-- Check overall memory pressure:
SELECT physical_memory_in_use_mb, memory_utilization_percentage
FROM sys.dm_os_process_memory;

-- Check for concurrent heavy queries consuming grants:
SELECT session_id, requested_memory_kb, granted_memory_kb
FROM sys.dm_exec_query_memory_grants
ORDER BY requested_memory_kb DESC;
```
Increase `max server memory`, add Resource Governor to cap individual grants, or reduce concurrent query memory demands.

**Related checks:** S4 (grant wait), S3 (large grant), S18 (insufficient grant)

---

### S30 — High Serial Required Memory

**What it means**  
`SerialRequiredMemory` is how much memory the sort and hash operators need even if the query runs with DOP 1 (serially). When this value is very high, the query is expensive regardless of parallelism — the individual operators are reading and sorting too much data.

**How to spot it**  
`SerialRequiredMemory` ≥ 524,288 KB (512 MB) in `MemoryGrantInfo`.

```xml
<MemoryGrantInfo SerialRequiredMemory="1048576" GrantedMemory="2097152" .../>
```
Serial mode needs 1 GB. With DOP 8, the granted amount is higher — but even removing parallelism won't solve the underlying problem.

**Fix**  
Add indexes to avoid large sorts. Filter data earlier in the plan to reduce the row count entering sort/hash operators. Replace ORDER BY on large result sets with a pre-sorted index.

**Related checks:** S2 (excessive over-grant), S3 (large grant), N22 (expensive sort)

---

### S31 — Non-QDS Forced Plan (Traditional Plan Guide)

**What it means**  
A `sp_create_plan_guide` is forcing the optimizer to use a specific plan — distinct from S24 which catches Query Store forced plans. Traditional plan guides are fragile: they must exactly match the query text (including whitespace in some cases), and become stale silently as data distribution, statistics, and schema change.

**How to spot it**  
`PlanGuideName` attribute present on `StmtSimple` AND does NOT start with `QDS_`.

```xml
<StmtSimple PlanGuideName="GuideGetOrders_2023" ...>
```

**How to audit plan guides**
```sql
SELECT name, scope_type_desc, query_text, hints
FROM sys.plan_guides
WHERE is_disabled = 0
ORDER BY name;

-- Test if the guide is still valid:
EXEC sys.sp_validate_plan_guide @name = N'GuideGetOrders_2023';
```

**Fix**  
Validate the guide is still beneficial by capturing the plan without the guide (temporarily disable it) and running `/sqlplan-compare` against the forced plan. If the guide is no longer needed (the underlying statistics or index issue was fixed), drop it. If still needed, consider migrating to Query Store plan forcing which is more robust.

**Related checks:** S24 (QDS forced plan), N36 (forced plan general), N37 (unmatched index hint)

---

### S32 — Compile Wall-Clock vs CPU Gap (Compilation Contention)

**What it means**  
`CompileTime` (wall-clock seconds to compile) greatly exceeds `CompileCPU` (CPU time spent compiling). The gap represents time SQL Server's optimizer thread spent *waiting* rather than working — typically for plan cache latch contention or memory broker pressure during optimization.

**How to spot it**  
`CompileTime` > `CompileCPU` × 2 AND `CompileTime` > 1,000 ms (both in milliseconds on QueryPlan).

```xml
<QueryPlan CompileTime="4200" CompileCPU="800" ...>
```
4.2 seconds wall-clock, only 800 ms CPU — 3.4 seconds spent waiting during compilation.

**Fix**  
```sql
-- Check for compilation-related waits:
SELECT wait_type, wait_time_ms, waiting_tasks_count
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('RESOURCE_SEMAPHORE_QUERY_COMPILE', 'SOS_SCHEDULER_YIELD')
ORDER BY wait_time_ms DESC;
```
Use plan guides or `sp_executesql` parameterization to reduce plan cache churn. Increase plan cache via `max server memory` adjustment. Consider `optimize for ad hoc workloads`.

**Related checks:** S7 (high compile CPU), S15 (high compile memory)

---

### S33 — Non-Standard Compilation SET Options

**What it means**  
The plan was compiled with `SET ANSI_NULLS OFF`, `SET QUOTED_IDENTIFIER OFF`, or `SET ANSI_WARNINGS OFF`. Standard SQL Server behavior requires all three to be ON. Non-standard options change query semantics and, critically, cause a separate plan cache entry from standard-compiled plans — even for identical query text. This means every SSMS-submitted version of the query misses the application's cached plan and compiles a new one.

**How to spot it**  
`StatementSetOptions` element on `StmtSimple` with non-standard attribute values.

```xml
<StmtSimple ...>
  <StatementSetOptions QUOTED_IDENTIFIER="false" ANSI_NULLS="true" .../>
```

**Semantic impact of non-standard options**  
- `ANSI_NULLS OFF`: `NULL = NULL` evaluates to TRUE (non-standard NULL comparison)
- `QUOTED_IDENTIFIER OFF`: double quotes denote string literals, not identifiers — breaks code using `"ColumnName"` syntax
- `ANSI_WARNINGS OFF`: suppresses divide-by-zero and NULL aggregate warnings

**Fix**  
Identify the application connection string or driver setting that sets non-standard options. ODBC and OLE DB drivers default to `ANSI_NULLS=ON`, `QUOTED_IDENTIFIER=ON`. Legacy VB6 / classic ADO applications and some ORMs default to OFF. Add explicit `SET` statements at the start of the stored procedure, or fix the connection string.

**Related checks:** S17 (unparameterized query — related plan cache bloat), S23 (excessive parameters)

---

### N61 — High Estimated Average Row Size

**What it means**  
`AvgRowSize` is the optimizer's estimate of how wide (in bytes) each row is as it passes through this operator. When rows are very wide, every sort and hash operator must allocate one or more 8-KB buffer pages *per row* — dramatically multiplying memory grant requirements. A 10,000-byte row in a sort of 1 million rows requires ~10 GB of sort memory.

**How to spot it**  
`AvgRowSize` attribute on `<RelOp>` elements (SSMS displays it as "Estimated Row Size").

```xml
<RelOp PhysicalOp="Sort" AvgRowSize="12480" ...>
```
12,480 bytes = 1.5 pages per row. Every sort row requires at least 2 buffer pages.

**Why rows get wide**  
- `SELECT *` on a wide table carries every column through the plan
- Large string/VARBINARY/XML/JSON columns in the projection
- Many JOIN columns accumulated through nested loops

**Fix**  
```sql
-- Replace SELECT * with explicit columns:
-- WRONG:
SELECT * FROM dbo.Orders o JOIN dbo.Customers c ON o.CustomerId = c.CustomerId

-- RIGHT:
SELECT o.OrderId, o.CreatedDate, o.TotalAmount, c.Email, c.Name
FROM dbo.Orders o JOIN dbo.Customers c ON o.CustomerId = c.CustomerId
```
Identify which columns are wide (VARCHAR(MAX), NVARCHAR(MAX), XML, VARBINARY(MAX)) and filter them out of the projection until the final result set.

**Related checks:** N61 drives S3/S29 (large/denied memory grants), N22 (expensive sort — wide rows inflate sort cost)

---

### N62 — Actual Elapsed Time Hotspot

**What it means**  
`ActualElapsedms` in `RunTimeCountersPerThread` records how long (in milliseconds) a specific thread actually spent in a specific operator — including time waiting for I/O, locks, memory, and CPU scheduling. Summing across threads gives the operator's total wall-clock contribution. When one operator dominates actual elapsed time, it is the true bottleneck regardless of its estimated cost percentage (N24).

**How to spot it**  
`RunTimeCountersPerThread/@ActualElapsedms` on any `<RelOp>` in an actual execution plan.

```xml
<RunTimeCountersPerThread Thread="1" ActualRows="9999999" ActualElapsedms="28450" />
<RunTimeCountersPerThread Thread="2" ActualRows="8120344" ActualElapsedms="31200" />
```
Sum = 59,650 ms actual elapsed. If statement total was 62,000 ms, this operator consumed 96% of wall-clock time.

**Why estimated cost can mislead**  
N24 uses the optimizer's cost model percentage — which does not account for I/O stalls, lock waits, or memory spills. A hash match with low estimated cost can have very high actual elapsed time if it spills to TempDb or waits for memory. Actual elapsed time cuts through this noise.

**Fix**  
Once the elapsed-time hotspot operator is identified, run the appropriate companion check for its type: Sort → N6/N22/N41; Hash Match → N7/N41; Scan → N4/N39/N65; Seek → N43/N5; Exchange → N26/N27.

**Related checks:** N24 (high cost operator by estimated %), N41 (confirmed spill), N27 (thread skew)

---

### N63 — Thread Starvation (Zero-Row Thread)

**What it means**  
In a parallel plan, work is distributed across threads via an exchange operator. When one or more threads process zero rows while others process millions, those threads wasted their entire setup, scheduling, and teardown overhead with no productive output. This is a more extreme form of N27 (thread skew) — skew can be 10× or 100×; starvation is infinite skew.

**How to spot it**  
A `Parallelism` operator with `RunTimeCountersPerThread` entries where at least one thread has `ActualRows = 0` and total `ActualRows` > 0.

```xml
<RunTimeCountersPerThread Thread="1" ActualRows="9999999" .../>
<RunTimeCountersPerThread Thread="2" ActualRows="0"       .../>
<RunTimeCountersPerThread Thread="3" ActualRows="0"       .../>
```
Thread 1 did everything; threads 2 and 3 were wasted.

**Causes**  
1. Hash distribution on a high-cardinality column where all values hash to one bucket
2. Partition-aware parallelism where all data is in one partition
3. DOP set too high for the data volume (small table with many threads)

**Fix**  
For partition-aware skew: check partition distribution with `sys.dm_db_partition_stats`. For hash distribution skew: the partitioning column in the Repartition Streams operator has extreme value skew. Consider reducing MAXDOP or reorganizing the query to use a better partitioning column.

**Related checks:** N27 (parallel thread skew — ratio-based), N26 (exchange spill), S8 (ineffective parallelism)

---

### N64 — Wide Projection (SELECT * Anti-Pattern)

**What it means**  
The `<OutputList>` of a scan or seek operator lists every column being carried upward through the plan. When more than 20 columns are projected, every downstream Sort, Hash Match, and Nested Loops operator must allocate buffers for this wide row — inflating memory grants (N61) and row transfer costs between operators.

**How to spot it**  
`<OutputList>` element with many `<ColumnReference>` children on a Scan or Seek.

```xml
<OutputList>
  <ColumnReference Table="[Orders]" Column="OrderId"/>
  <ColumnReference Table="[Orders]" Column="CustomerId"/>
  ...  <!-- 35 more columns -->
  <ColumnReference Table="[Orders]" Column="LastModifiedAt"/>
</OutputList>
```

**Impact example**  
Orders table: 40 columns, average width 150 bytes = 6,000 bytes/row. With 10 million rows in a sort, sort memory = 60 GB requested. With explicit projection of 5 columns at 40 bytes each: sort memory = 4 GB. Selecting only needed columns reduces sort memory by 15×.

**Fix**  
```sql
-- WRONG (carries all 40 columns):
SELECT * FROM dbo.Orders WHERE Status = 'Pending'

-- RIGHT (carries only 4 columns):
SELECT OrderId, CustomerId, CreatedDate, TotalAmount
FROM dbo.Orders WHERE Status = 'Pending'
```

**Related checks:** N61 (high avg row size — directly caused by wide projection), S3 (large memory grant — symptom of wide projection feeding sort/hash)

---

### N65 — Partition Elimination Not Occurring

**What it means**  
SQL Server's table/index partitioning allows queries to skip entire partition ranges when the WHERE clause matches the partition column. When `ActualPartitionsAccessed` equals the total `PartitionCount`, no partitions were eliminated — the query scanned every partition despite having a predicate on the partition key.

**How to spot it**  
`Partitioned="1"` on a RelOp AND `ActualPartitionsAccessed` = full count in RunTimeInformation (requires actual plan).

```xml
<RelOp Partitioned="1" ...>
  <RunTimeCountersPerThread Thread="1" ActualPartitionsAccessed="24" .../>
```
If the table has 24 partitions and all 24 were accessed, elimination failed.

**Why elimination fails**  
1. Implicit type conversion on the partition column — wrapping the column in CONVERT prevents seek (N8/N42)
2. Function applied to the partition column (`WHERE YEAR(OrderDate) = 2024`)
3. Parameter sniffed with a non-representative value that forces a full scan plan
4. Dynamic partition key (variable not yet evaluated at parse time)

**Fix**  
```sql
-- WRONG (implicit conversion prevents elimination):
WHERE PartitionDate >= @StartDate  -- if @StartDate is DATETIME but column is DATE

-- RIGHT:
WHERE PartitionDate >= CAST(@StartDate AS DATE)

-- Check actual partition access:
SELECT partition_number, row_count
FROM sys.dm_db_partition_stats
WHERE object_id = OBJECT_ID('dbo.Orders')
ORDER BY partition_number;
```

**Related checks:** N8 (implicit conversion in predicate — common cause), N42 (implicit conversion degrades cardinality), N3 (function on scan predicate)

---

### N66 — Actual Rebinds Exceed Estimated Rebinds

**What it means**  
In a Nested Loops join, `ActualRebinds` counts how many times the inner side was re-executed from scratch. `EstimateRebinds` is the optimizer's prediction based on the outer side cardinality estimate. When actual far exceeds estimated, the outer side had far more rows than planned — every extra outer row drives an additional inner execution.

**How to spot it**  
Nested Loops RelOp where `ActualRebinds` >> `EstimateRebinds` in RunTimeCountersPerThread (requires actual plan).

```xml
<RelOp PhysicalOp="Nested Loops" EstimateRebinds="1.2" ...>
  <RunTimeCountersPerThread Thread="1" ActualRebinds="84200" .../>
```
Estimated 1.2 rebinds, actual 84,200 — a 70,000× underestimate. The outer side returned 84,200 rows when the optimizer thought it would return 1.

**Difference from N16 (Busy Loop)**  
N16 fires based on *estimated* values — useful for estimated plans. N66 fires based on *actual* evidence — confirms the problem occurred at runtime and quantifies the true extent.

**Fix**  
```sql
-- Fix the cardinality error on the outer side first (update statistics):
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;

-- If parameter sniffing is the root cause:
OPTION (OPTIMIZE FOR (@CustomerId = 12345))

-- Force a hash join if cardinality cannot be fixed:
FROM dbo.Orders o
INNER HASH JOIN dbo.OrderLines ol ON ol.OrderId = o.OrderId
-- Hash join cost is O(N+M) regardless of outer cardinality
```

**Related checks:** N16 (busy loop pattern — estimate-based version), N21 (bad row estimate — the root cause), N15 (high nested loop count — count-based)

---

### S34 — Parameter Sensitive Plan Dispatcher Detected

**What it means**
SQL Server 2022 PSP (Parameter Sensitive Plan) optimization detected significant data skew on a parameterized predicate and compiled a dispatcher plan with multiple variants — one per distinct parameter range. Each variant is a full execution plan optimized for a specific row count range (e.g., low-selectivity vs high-selectivity parameter values). SQL 2022+ with compat level 160 only.

**How to spot it**
`ParameterSensitivePredicate` element, or a `<Dispatcher>` element, in the plan XML.

**Fix**
Check `sys.query_store_query_variant` to verify variants and their boundaries. If a boundary is poorly calibrated, use `sys.sp_query_store_set_hints` to pin a specific plan for a parameter range. Related: N68.

---

### S35 — ADR Long-Transaction Version Store Accumulation

**What it means**
Accelerated Database Recovery (ADR) moves the version store from the log to a Persistent Version Store (PVS) in user-defined filegroups or TempDB. Unlike the traditional version store, PVS entries do not block log truncation but they do grow continuously for the lifetime of any open transaction. A long-running transaction causes PVS to accumulate rows at the rate of all concurrent DML. SQL 2019+ only.

**How to spot it**
Long transaction duration combined with high DML activity on the database. Cross-reference `sys.dm_tran_persistent_version_store_stats` for PVS size and `E29` in sqlerrorlog-review for PVS cleanup stall messages.

**Fix**
Keep transactions short and commit promptly. Monitor PVS size with:
```sql
SELECT pvss_used_page_count, pvss_reserved_page_count
FROM sys.dm_tran_persistent_version_store_stats;
```

---

### S36 — Cardinality Estimation Feedback Applied

**What it means**
CE Feedback (SQL 2022 Intelligent Query Processing) automatically adjusts cardinality estimates across executions when the CE model consistently underestimates or overestimates row counts. When `ContainsCEFeedback="true"` [Unverified attribute — confirm via sys.query_store_plan_feedback feature_desc = 'CE Feedback'] appears on a plan, the estimates reflect the engine's learned corrections rather than the base CE model. SQL 2022+ only.

**How to spot it**
`ContainsCEFeedback="true"` attribute on `StmtSimple` in the plan XML [Unverified — cross-check `sys.query_store_plan_feedback`].

**Fix**
CE Feedback is generally beneficial. Monitor query stability using Query Store: if the plan shape or performance oscillates after feedback applies, the workload characteristics are changing too frequently for the feedback model to converge. Related: Q27 in sqlquerystore-review.

---

### N67 — Ordered Columnstore Scan Segment Pruning Confirmed

**What it means**
SQL Server 2022 supports ordered clustered columnstore indexes (`CREATE CLUSTERED COLUMNSTORE INDEX ... ORDER (col)`). When a query's WHERE predicate matches the ORDER column, the engine can skip entire row groups without decompressing them — segment elimination. This check fires as a positive signal when at least half the segments were pruned. SQL 2022+ only.

**How to spot it**
Columnstore Index Scan with `Ordered="true"` and `SegmentSkips >= (SegmentReads + SegmentSkips) * 0.5` in the actual plan.

**Fix**
No fix needed when this fires — it is confirmatory. If pruning is lower than expected, verify the filter predicate matches the column in the `ORDER (...)` clause exactly (including data type). Related: N7 (segment read count for unordered CS), N50 (delta store read).

---

### N68 — PSP Variant Cardinality Error

**What it means**
Inside a PSP dispatcher plan, each variant is a specialized sub-plan for a particular parameter value range. If a variant still shows a large `actualRows / estimateRows` ratio, the variant's row-count boundary does not match the actual data distribution — the optimizer cut the parameter space at the wrong threshold. SQL 2022+ only.

**How to spot it**
Within a PSP plan, a variant node with `actualRows / estimateRows > 100` and `actualRows > 1,000` (requires actual plan).

**Fix**
Use `sys.query_store_query_variant` to inspect variant boundaries. Use Query Store hints (`sys.sp_query_store_set_hints`) to force the correct variant for the problem parameter range, or disable PSP for this query with `OPTION (USE HINT ('DISABLE_PARAMETER_SNIFFING'))` and fix the underlying cardinality issue instead. Related: S34.

---

### N69 — IQP Approximate Count Distinct Active

**What it means**
`APPROX_COUNT_DISTINCT` (SQL 2019+ IQP) computes distinct counts using HyperLogLog — much faster than `COUNT(DISTINCT)` for large datasets, with approximately 2% error. When this check fires, it confirms IQP is using HLL approximation rather than exact distinct counting. SQL 2019+ only.

**How to spot it**
An aggregate operator whose defined values or statement text reference `APPROX_COUNT_DISTINCT`.

**Fix**
If approximate results are acceptable (dashboards, analytics), this is a positive optimization — no action needed. If exact count semantics are required (financial reconciliation, integrity validation), replace `APPROX_COUNT_DISTINCT` with `COUNT(DISTINCT col)`. Related: T84 in tsql-review.

---

### N70 — DOP Feedback Adjusted Plan

**What it means**
IQP DOP Feedback (SQL 2022) monitors parallel query thread utilization across executions. When a query consistently underutilizes its parallel threads, DOP Feedback reduces the degree of parallelism at compile time to free resources for other queries. The `DegreeOfParallelismFeedback` element in the plan confirms the adjustment [Unverified — cross-check `sys.query_store_plan_feedback` with feature_desc = 'DOP Feedback']. SQL 2022+ only.

**How to spot it**
`DegreeOfParallelismFeedback` element present in the plan XML [Unverified].

**Fix**
DOP Feedback is generally beneficial. Verify the adjusted DOP is improving elapsed time and reducing CXPACKET waits. If performance worsened after adjustment, disable feedback for the specific query using `OPTION (USE HINT ('DISABLE_DOP_FEEDBACK'))`. Related: S8 (DOP forcing), S9 (DOP threshold).

---

### N71 — Adaptive Join Threshold Evaluation

**What it means**
An Adaptive Join operator defers the join type decision (Nested Loops vs Hash Match) until runtime, switching based on whether the build-side row count exceeds the `AdaptiveThresholdRows` threshold. This check surfaces the threshold and actual row count so you can assess whether the adaptive join is correctly switching — or whether one join type is always chosen, making the overhead unnecessary. SQL 2017+.

**How to spot it**
`physicalOp="Adaptive Join"` with `AdaptiveThresholdRows` attribute in the plan XML.

**Fix**
If `actualRows` is consistently above the threshold across all executions → Hash Match is always chosen → replace with an explicit `INNER HASH JOIN` hint to eliminate adaptive overhead. If consistently below → Nested Loops always chosen → use `INNER LOOP JOIN`. If rows straddle the threshold → the adaptive join is beneficial — leave it in place.

---

### N72 — Low Statistics Sampling Percent on Hot Statistics

**What it means**
`StatisticsInfo/@SamplingPercent` is below 10% for a statistic used to compile this plan on a table with more than 100,000 actual rows. SQL Server builds histograms from a sample of the table by default. When the sample rate is very low, the histogram has fewer steps and reduced resolution — the optimizer may miss data skew, producing poor cardinality estimates even for recently updated statistics.

**How to spot it**
`StatisticsInfo` elements appear in actual execution plans only (not estimated plans). Search the plan XML for `SamplingPercent`:

```xml
<StatisticsInfo
  LastUpdate="2026-01-15T08:30:00"
  ModificationCount="12500"
  SamplingPercent="3.8"
  Statistics="[_WA_Sys_00000003_3A81B327]"
  Table="[Orders]"
  Schema="[dbo]"
  Database="[AdventureWorks]" />
```

`SamplingPercent="3.8"` means only 3.8% of rows were read when building the histogram. For a 10M-row table that is 380,000 rows — plausible, but not representative of skewed distributions.

In SSMS: right-click an operator → Properties → look for StatisticsInfo entries under the operator node, or open the plan XML directly and search for `SamplingPercent`.

**Why it matters**
A histogram built from 3% of rows may completely miss a value spike that accounts for 40% of actual query rows. The optimizer sees a flat distribution and underestimates rows for queries hitting that spike — leading to bad join choices, undersized memory grants, and sort/hash spills. Critically, even if `LastUpdate` is recent (yesterday), a low-sample recent update is less reliable than a full-scan from months ago for skewed columns.

SQL Server's auto-update threshold (20% row modifications) triggers a re-sample — but uses the same low sample rate unless explicitly overridden. `PERSIST_SAMPLE_PERCENT = ON` locks in a higher rate across future auto-updates.

**Fix options**
1. Rebuild with a full scan — most accurate, appropriate for tables up to ~200 GB:
   ```sql
   UPDATE STATISTICS dbo.Orders ([_WA_Sys_00000003_3A81B327]) WITH FULLSCAN;
   ```
2. Lock in the rate so future auto-updates don't revert to the default (SQL 2016 SP1 CU4+, SQL 2017 SP1+, SQL 2019+, Azure SQL):
   ```sql
   UPDATE STATISTICS dbo.Orders ([_WA_Sys_00000003_3A81B327])
   WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;
   ```
3. For very large tables where FULLSCAN is too slow, use a higher explicit sample:
   ```sql
   UPDATE STATISTICS dbo.Orders ([_WA_Sys_00000003_3A81B327])
   WITH SAMPLE 30 PERCENT, PERSIST_SAMPLE_PERCENT = ON;
   ```
4. Update all statistics on the table in one pass:
   ```sql
   UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
   ```
5. After updating, capture a new actual plan and confirm `SamplingPercent` rises above 10% and that N21 (bad row estimate) no longer fires on the same operators.

**Related checks:** N21 (bad row estimate — the downstream symptom of low-quality stats), N11 (no statistics at all), N35 (CE default selectivity guess — also caused by absent or low-quality statistics), S36 (CE Feedback — SQL 2022 auto-correction for persistent cardinality errors)

---

## Quick Reference Tables

### Severity Levels

| Severity | Color | Meaning | Action |
|----------|-------|---------|--------|
| **Critical** | Red | Active performance disaster, data correctness risk, or catastrophic plan | Fix immediately before anything else |
| **Warning** | Yellow | Significant performance problem requiring attention | Fix in this optimization session |
| **Info** | Blue | Noteworthy pattern — may or may not need action | Investigate; often acceptable |

### Most Common Root Causes

| Root Cause | Checks It Typically Triggers |
|------------|------------------------------|
| Stale statistics | S2, S3, S6, S7, N6, N7, N21, N41, S18 |
| Parameter sniffing | S2, S18, N21, N41, S20, S24, N52 |
| Missing index | N2, N4, N5, N15, N22, N31, N39, N43, S27 |
| Data type mismatch | S12, N8, N42 |
| Scalar UDF in query | S1, N19, N25, N58 |
| Table variable instead of #temp | S1, S13, S14, N21 |
| Optimizer hints overriding choices | S19, S20, N36, N37, N40, S24 |
| No statistics on column | N11, N35, N59 |
| Low statistics sample rate | N72, N21, N35 |
| Query too complex (too many joins) | S5, S6, S7, S15, N44 |
| Heap table (no clustered index) | N5 (RID lookup), N39 |
| Non-sargable predicate | N3, N4, N9, N43, N60, N65 |
| Cartesian join (missing ON clause) | N10 |
| TVF/MSTVF black box | N13, N14, N57 |
| CTE used multiple times | N30 |
| OR in join predicate | N29 |
| Columnstore not fully utilized | N49, N50, N58, N19 |
| Window function overhead | N46, N47, N22 |
| Correlated subquery per row | N54, N56, N15 |
| Large value list / IN clause | N55, S23 |
| JSON data in WHERE clause | N60, N3, N4 |
| In-Memory OLTP mixed workload | N48 |
| Forced plan becoming stale | S24, S31, N36 |
| Plan cache bloat | S28, S23, S33 |
| Server memory pressure | S29, S30, N61 |
| SELECT * / wide projection | N64, N61, S3 |
| Compilation contention | S32, S7, S15 |
| Partition elimination failure | N65, N8, N42, N3 |
| Parallel inefficiency | N63, N27, S8, N62 |

### Checks that Require an Actual Plan

These checks fire only when actual execution statistics are present (Ctrl+M in SSMS before running):

S8, S9, N4 (rowsRead threshold), N6, N7, N15, N16, N21, N26, N27, N28, N33, N41, N43 (ratio check), N47, N49, N50, N54, N56, N62, N63, N65, N66, N72

All other checks can fire on estimated plans.

### Checks that Are Usually Benign (Info Level)

These fire to provide context but rarely require immediate action:

| Check | When to ignore it |
|-------|------------------|
| S16 — Trivial Plan | Query is simple and fast; no action needed |
| S17 — Unparameterized | One-off query or stored procedure; not ad-hoc traffic |
| S25 — Interleaved Execution Active | SQL Server using the feature correctly; confirm not suppressed |
| S26 — Batch Mode Adaptive Join | SQL Server adapting correctly; no action needed |
| N17 — Row Goal | EXISTS/TOP pattern working as designed |
| N18 — Adaptive Join | SQL Server adapting correctly; no action needed |
| N24 — High Cost Operator | Use this to guide where to focus, not as a problem itself |
| N32 — Optimize For Unknown | Acceptable if you've tested and it's stable |
| N34 — Wide Index Suggestion | Evaluate carefully; don't blindly create the suggested index |
| N35 — CE Guess | Create statistics, but not urgent if query is fast |
| N44 — Many Joins | Awareness check; only act if S5/S7 also fire |
| N50 — Delta Store Read | Expected after recent inserts; only act if delta stores persist |
| N51 — Batch Mode on Rowstore | Positive signal; confirm compat level 150+ is set |
| N52 — Constant Scan | Normal for VALUES/system functions; investigate only if unexpected |
| N53 — Assert Operator | Normal for DML; investigate only if high execution count |
| S30 — High Serial Required Memory | Informational unless also triggering S3/S29 |
| S32 — Compile Wall-Clock vs CPU Gap | Note the contention but only act if CompileTime > 5,000 ms |
| S33 — Non-Standard SET Options | Fix the connection string but non-urgent if query is fast |
| N61 — High Estimated Avg Row Size | Act when paired with S3 (large grant) or N22 (expensive sort) |
| N64 — Wide Projection | Always worth fixing; SELECT * is rarely intentional in production |
