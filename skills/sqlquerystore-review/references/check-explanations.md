# sqlquerystore-review — Checks Explained

## Contents

- [When to Use This Skill](#when-to-use-this-skill)
- [Key Concepts](#key-concepts)
- [Regressed Queries (Q1–Q6)](#regressed-queries-q1q6)
- [Plan Stability (Q7–Q12)](#plan-stability-q7q12)
- [Resource Hotspots (Q13–Q18)](#resource-hotspots-q13q18)
- [Query-Level Waits (Q19–Q22)](#query-level-waits-q19q22)
- [Operational Health (Q23–Q25)](#operational-health-q23q25)
- [IQP, PSP, and Feedback Checks (Q26–Q32)](#iqp-psp-and-feedback-checks-q26q32)
- [Quick Reference](#quick-reference)

---


A plain-English guide to every check in the Query Store review skill, how to spot each pattern, and what to do about it.

---

## When to Use This Skill

Use `/sqlquerystore-review` when you have Query Store DMV output and want to:
- Find which queries dominate your workload (CPU, duration, reads, executions)
- Detect queries that regressed after a deployment or statistics update
- Identify plan instability problems (multiple plans for the same query)
- Audit Query Store configuration health
- Check query-level wait patterns (SQL 2017+)

Query Store tells you **which** queries need attention. Follow up with `/sqlplan-review` on the worst plans to understand **why**.

---

## Key Concepts

### Query Store DMV Relationships

```
sys.query_store_query_text   (the SQL text, one per unique query text)
        └── sys.query_store_query     (query metadata, one per query_id)
                └── sys.query_store_plan      (compiled plans, one per plan_id)
                        └── sys.query_store_runtime_stats (execution metrics per interval)
                        └── sys.query_store_wait_stats   (wait metrics per interval, 2017+)
```

A single `query_hash` can have multiple `query_id` values (parameterized variants like ad-hoc literals). A single `query_id` can have multiple `plan_id` values (plan changes over time). Runtime and wait stats are collected per `plan_id` within time intervals.

### Query Store Time Intervals

Runtime stats are aggregated into fixed-length intervals (default: 60 minutes). Within an interval, all executions of a plan are summarized into `avg_`, `min_`, `max_`, `stdev_` metrics plus `count_executions`. This means:
- `max_duration` is the max per interval, not per individual execution
- An extreme outlier within a 60-minute interval may be averaged out
- `last_execution_time` is the last execution timestamp in that interval

### Execution Types

Query Store tracks three execution types (the `execution_type` column in `sys.query_store_runtime_stats` is `tinyint`; values 1 and 2 are not used):
| `execution_type` | Meaning |
|------------------|---------|
| 0 | Regular — completed normally |
| 3 | Aborted — client cancelled or timed out |
| 4 | Exception — query hit an error |

### Query Store Wait Categories (SQL 2017+)

| Category ID | Name | Wait types included |
|-------------|------|---------------------|
| 1 | CPU | SOS_SCHEDULER_YIELD |
| 3 | LOCK | LCK_M_* |
| 4 | LATCH | LATCH_* |
| 5 | BUFFER_LATCH | PAGELATCH_* |
| 6 | BUFFER_IO | PAGEIOLATCH_* |
| 14 | LOG_IO | LOGMGR, LOGBUFFER, WRITELOG, CHKPT |
| 15 | NETWORK_IO | ASYNC_NETWORK_IO, NET_WAITFOR_PACKET |
| 16 | PARALLELISM | CXPACKET, EXCHANGE, HT* |
| 17 | MEMORY | RESOURCE_SEMAPHORE, CMEMTHREAD |

---

## Regressed Queries (Q1–Q6)

### Q1 — Duration Regressed vs Baseline

**What it means:** A query's average wall-clock time has at least doubled compared to a previous time period. This is the most user-visible regression — it directly affects application response time.

**How to spot it:**
- Compare `avg_duration_ms` from current period to baseline period
- Current avg / baseline avg ≥ 2.0
- Baseline avg ≥ 100 ms (ignore trivial fast queries)
- Requires running Query A twice with different `@start_date`/`@end_date` ranges

**Example (problem + fix):**
```
-- Baseline (last month): avg_duration_ms = 1,200 ms
-- Current  (this week):  avg_duration_ms = 6,360 ms
-- Ratio: 5.3x — Critical regression
```
**Fix options:**
1. Export both plans from Query Store and run `/sqlplan-compare` to see what changed
2. Check if an index was dropped: compare `sys.indexes` between periods
3. Update statistics: `UPDATE STATISTICS dbo.TableName`
4. As immediate mitigation, add `OPTION (RECOMPILE)` to avoid the bad parameter sniffing plan
5. Force the baseline plan via `sp_query_store_force_plan` if it still exists in Query Store

**Related checks:** Q2, Q3, Q5, C1–C10 (sqlplan-compare), S9 (sqlplan-review)

---

### Q2 — CPU Regressed vs Baseline

**What it means:** The query is using more CPU than before, even if wall-clock time hasn't changed much (could be parallel vs serial plan shift).

**How to spot it:**
- Compare `avg_cpu_ms` between periods
- Current / baseline ≥ 2.0 and baseline ≥ 50 ms

**Example (problem + fix):**
```
-- Baseline: avg_cpu_ms = 842 ms, DOP = 8   (parallel, efficient)
-- Current:  avg_cpu_ms = 2,450 ms, DOP = 1 (serial, scans driving CPU)
```
**Fix options:**
1. Run `/sqlplan-review` on the current plan — look for N4 (expensive scan), N18 (hash match), N20 (sort)
2. Check if parallelism was lost (S1 in sqlplan-review): server MAXDOP change or scalar UDF introduced
3. Add covering indexes to eliminate scans driving the CPU cost
4. Check for implicit conversion (N14 in sqlplan-review)

**Related checks:** Q1, Q3, C5 (sqlplan-compare), S1 (sqlplan-review)

---

### Q3 — Logical Reads Regressed vs Baseline

**What it means:** The query is reading far more data pages than before. This often means a Seek degraded to a Scan, or a new Key Lookup was introduced.

**How to spot it:**
- Compare `avg_logical_reads` between periods
- Current / baseline ≥ 3.0 and baseline ≥ 1,000

**Example (problem + fix):**
```
-- Baseline: avg_logical_reads = 8,421 pages  (Index Seek on CustomerId)
-- Current:  avg_logical_reads = 256,890 pages (Index Scan — 30x more)
-- An index on CustomerId was dropped during a deployment
```
**Fix options:**
1. Check sys.indexes for recently dropped indexes
2. Run `/sqlindex-advisor` on the current plan to get exact CREATE INDEX DDL
3. Run `/sqlplan-compare` if you have both plans

**Related checks:** Q1, Q15, C1 (sqlplan-compare), N4 (sqlplan-review), D2 (sqlindex-advisor)

---

### Q4 — New Plan for Previously Stable Query

**What it means:** A query that previously had a single stable plan now has a second plan. The new plan may be better or worse — investigation is needed.

**How to spot it:**
- Baseline period: `plan_count = 1` for the query hash
- Current period: `plan_count ≥ 2`

**Example (problem + fix):**
```
-- query_hash 0x3A7F... had 1 plan for 3 months
-- After nightly statistics update, now has 2 plans
-- Plan 1: ~200 ms (the old plan, still present)
-- Plan 2: ~6,000 ms (new plan from bad parameter sniffing)
```
**Fix options:**
1. Compare both plans: `/sqlplan-compare`
2. If new plan is worse, force the old plan: `sp_query_store_force_plan`
3. Investigate why a new plan was generated: statistics update caused cardinality change, or new query pattern with different parameter values
4. If the new plan is actually better, no action needed

**Related checks:** Q5, Q7, C1–C10 (sqlplan-compare)

---

### Q5 — Variant Plan Performs Worse

**What it means:** A single query hash has multiple plans, and the worst plan is ≥ 3× slower than the best plan. Classic parameter sniffing signal.

**How to spot it:**
- Same `query_hash` has `plan_count ≥ 2`
- max(`avg_duration_ms`) across plans ≥ 3× min(`avg_duration_ms`)

**Example (problem + fix):**
```
-- dbo.GetOrders (query_hash 0xB2E1...)
-- Plan A (forced on 2025-03-01): 48 ms avg  (for CustomerId = 42, small customer)
-- Plan B (auto-generated):    8,420 ms avg (for CustomerId = 9999, large customer)
-- Same query, different parameter values
```
**Fix options:**
1. Force the plan that works for the most common parameter values: `sp_query_store_force_plan`
2. Add `OPTION (RECOMPILE)` if the query is small enough for compile overhead to be negligible
3. Create separate procedures or use `OPTION (OPTIMIZE FOR)` for known typical values
4. Use Parameter Sensitive Plan optimization (SQL 2022+): enable with database scoped configuration

**Related checks:** Q4, Q7, S9 (sqlplan-review), N21 (sqlplan-review)

---

### Q6 — Regressed Query with Forced Plan Failure

**What it means:** A plan that was deliberately forced (via `sp_query_store_force_plan`) is now failing — the optimizer cannot use it. The query is running with whatever plan the optimizer picks, which may be worse.

**How to spot it:**
- `is_forced_plan = 1` AND `force_failure_count > 0` AND `last_force_failure_reason_desc IS NOT NULL`
- Query appears in the regressed list (Q1–Q3 triggered)

**Example (problem + fix):**
```
-- Plan was forced for dbo.Report (plan_id 42) on 2025-02-15
-- Index IX_Orders_CustomerId was dropped during deployment on 2025-04-01
-- force_failure_count = 42, failure reason: "NO_INDEX"
-- Query is now scanning instead of seeking
```
**Fix options:**
1. Check `last_force_failure_reason_desc` in the capture output
2. Common causes: referenced index dropped (recreate it), schema changed (column type modified), statistics dropped (recreate them)
3. Unforce the failing plan: `sp_query_store_unforce_plan`
4. Fix the underlying cause, then re-force if the old plan is still optimal
5. If the schema change is permanent, capture a new good plan and force that one

**Related checks:** Q8, Q5, S9 (sqlplan-review)

---

## Plan Stability (Q7–Q12)

### Q7 — Plan Instability (Excessive Plans)

**What it means:** The optimizer has generated ≥ 3 different execution plans for the same query. This usually indicates parameter sniffing — different parameter values cause wildly different cardinality estimates, and the optimizer generates a new plan each time the estimate crosses a threshold.

**How to spot it:**
- `plan_count ≥ 3` for a single `query_hash`
- Especially concerning when `total_executions` is high but executions per plan are low (< 5 each)

**Example (problem + fix):**
```
-- dbo.SearchProducts (query_hash 0xF12A...)
-- 7 plans in 7 days, 3,400 total executions
-- Plans range from 15 ms to 45,000 ms
-- Each plan averages ~485 executions before being replaced
```
**Fix options:**
1. Check for parameter sniffing: does the query perform differently for different parameter values?
2. Force the most consistently good plan: `sp_query_store_force_plan`
3. Add `OPTION (RECOMPILE)` if compile overhead is acceptable (small query, infrequent execution)
4. Rewrite with `OPTION (OPTIMIZE FOR UNKNOWN)` for average-case performance
5. Create separate procedures for high/low cardinality parameter paths

**Related checks:** Q4, Q5, S9 (sqlplan-review)

---

### Q8 — Forced Plan Failure

**What it means:** A forced plan cannot be used by the optimizer. This is a silent failure — the query still runs, but with whatever plan the optimizer picks, which may be much worse. Users won't see an error.

**How to spot it:**
- `is_forced_plan = 1` AND `last_force_failure_reason_desc IS NOT NULL`
- `force_failure_count > 0`

**Example (problem + fix):**
```
-- last_force_failure_reason_desc = 'NO_INDEX'
-- The forced plan references IX_Orders_Status which was dropped
-- Query now does a full table scan instead of index seek
```
**Fix options:**
1. Read `last_force_failure_reason_desc` — it tells you exactly why
2. `NO_INDEX`: recreate the missing index
3. `SCHEMA_CHANGE`: the table structure changed — unforce, capture new plan, evaluate
4. `STATISTICS_CHANGE`: statistics dropped — recreate statistics on the relevant columns
5. After fixing, the forced plan will automatically work again; no need to re-force
6. If the plan can't be fixed, unforce with `sp_query_store_unforce_plan`

**Related checks:** Q6, S9 (sqlplan-review)

---

### Q9 — High Aborted Execution Rate

**What it means:** More than 10% of this query's executions are being aborted — the client is cancelling the query (timeout, user cancel, or application Attention event).

**How to spot it:**
- `aborted_count / total_executions > 0.10`

**Example (problem + fix):**
```
-- dbo.GenerateReport: 15,000 total execs, 3,200 aborted (21%)
-- Client timeout is set to 30 seconds
-- Query avg duration is 28,500 ms — borderline, some executions exceed 30s
-- Users are experiencing timeouts 21% of the time
```
**Fix options:**
1. Run `/sqlplan-review` on the query plan — find and fix the performance bottleneck
2. If the query is inherently long-running, increase client timeout only after confirming performance can't be improved
3. Add pagination if the query returns large result sets
4. Consider async processing: queue the request, process in background, notify when complete
5. Increase client timeout as last resort — fixes the symptom, not the cause

**Related checks:** Q10, W4 (sqlstats-review), X1 (sqltrace-review)

---

### Q10 — Exception Executions Present

**What it means:** One or more executions of this query hit a runtime error. The error might be intermittent (only for certain parameter values or data conditions).

**How to spot it:**
- `exception_count > 0` in the capture output

**Example (problem + fix):**
```
-- dbo.UpdateInventory: 50,000 total execs, 12 exceptions (0.024%)
-- Exception: "Arithmetic overflow error converting numeric to data type int"
-- Happens when @Quantity > 2,147,483,647 (INT max)
```
**Fix options:**
1. Run `/tsql-review` on the query text — pay attention to T16–T28 (correctness checks)
2. Check for implicit conversions, division by zero, overflow, or constraint violations
3. Add TRY/CATCH to log the exact error and parameter values
4. Add input validation before the query executes (application layer)
5. If exceptions are very rare (< 0.1%) and benign, they may be acceptable — but investigate to confirm

**Related checks:** Q9, T16–T28 (tsql-review)

---

### Q11 — RECOMPILE Hint on Infrequent Query

**What it means:** The query uses `OPTION (RECOMPILE)` but doesn't run often enough to justify the compile overhead. RECOMPILE adds ~50–200 ms of compilation per execution.

**How to spot it:**
- Query text contains `RECOMPILE`
- `total_executions < 100`
- `avg_duration_ms ≥ 100 ms`

**Example (problem + fix):**
```
-- dbo.GetCustomerDetails WITH RECOMPILE
-- 42 executions over 7 days (~6/day)
-- avg_duration_ms = 85 ms, but avg compile time is ~45 ms
-- RECOMPILE adds 50%+ overhead to every execution
```
**Fix options:**
1. If parameter sniffing is the issue, try `OPTION (OPTIMIZE FOR UNKNOWN)` instead — no recompilation
2. If data distribution is heavily skewed, keep RECOMPILE — the overhead is worth the better plan
3. For < 10 executions per day, RECOMPILE overhead is negligible — this check is advisory only
4. If the query was simply copy-pasted with RECOMPILE by habit, remove it

**Related checks:** Q5, Q7, T47 (tsql-review), W3 (sqlstats-review)

---

### Q12 — Plan Feedback Active (SQL 2022+)

**What it means:** SQL Server's automated plan correction (Parameter Sensitive Plan optimization or Memory Grant Feedback) has adjusted this query's plan. This is a feature, not a bug — SQL Server is automatically tuning based on observed execution patterns.

**How to spot it:**
- In expert mode or when `sys.query_store_plan_feedback` is queried, `feature_desc` indicates active feedback
- Documented `feature_desc` values: `'CE Feedback'`, `'DOP Feedback'`, `'Memory Grant Feedback'`. PSP optimization itself does not appear in `sys.query_store_plan_feedback` — detect it via `plan_type_desc IN ('Dispatcher Plan', 'Query Variant Plan')` in `sys.query_store_plan` (see Q26)

**Example (problem + fix):**
```
-- dbo.ProcessBatch has PSP optimization active
-- Original plan was optimized for median parameter values
-- PSP created 3 variants for small/medium/large parameter ranges
-- Avg duration dropped from 4,200 ms to 850 ms
```
**Fix options:**
1. Generally no action needed — this is beneficial automation
2. Monitor to confirm the feedback-adjusted plan is stable over time
3. If feedback caused a regression (rare), disable: `ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF`
4. Consider that feedback may mask an underlying problem (missing index, stale statistics) — investigate the root cause of why the original plan was suboptimal

**Related checks:** Q5, Q7, Q4

---

## Resource Hotspots (Q13–Q18)

### Q13 — High CPU Concentration

**What it means:** A single query is consuming more than 30% of total CPU across all tracked queries. Tuning this one query will have the largest impact on overall server CPU.

**How to spot it:**
- Compute each query's total CPU: `avg_cpu_ms × total_executions`
- Sum all queries' total CPU
- Single query share > 30%

**Example (problem + fix):**
```
-- dbo.MonthlySalesReport: 31,200 executions in 7 days
-- avg_cpu_ms = 842, total CPU = 31,200 × 842 = 26,270,400 ms
-- Server total CPU across all queries = 64,000,000 ms
-- This single query = 41% of all CPU
```
**Fix options:**
1. Run `/sqlplan-review` on the plan captured from Query Store
2. Focus on CPU-intensive operators: scans (N4), hash joins (N18), sorts (N20), implicit conversions (N14)
3. Add covering indexes to eliminate scans
4. Check if parallelism is being used effectively (S1, S5 in sqlplan-review)
5. After applying fixes, monitor Q13 again — the share should drop significantly

**Related checks:** Q14, Q15, Q17, Q18, N4, N18, N20 (sqlplan-review)

---

### Q14 — High Duration Concentration

**What it means:** A single query dominates total wall-clock time. Even if CPU is moderate, this query is holding resources (locks, memory, transactions) for a long time.

**How to spot it:**
- Single query's total duration > 30% of all queries' total duration

**Example (problem + fix):**
```
-- dbo.ReconcileAccounts: avg_duration_ms = 284,906 ms (~4.7 minutes)
-- Runs 12 times/day = 84 times in 7 days
-- Total duration = 84 × 284,906 = 23,932,104 ms (~6.6 hours)
-- 57% of all duration across all queries
```
**Fix options:**
1. Run `/sqlstats-review` on `SET STATISTICS IO, TIME ON` output — check W1 (I/O wait) vs W2 (parallel) vs W5 (CPU)
2. If CPU << elapsed (W1), the query is waiting — check blocking (Q20) or I/O (I3 in sqlstats-review)
3. If CPU >> elapsed (W2), parallelism is helping — check for thread imbalance (N30 in sqlplan-review)
4. If CPU ≈ elapsed, the query is compute-bound — add indexes
5. Consider batching large DML operations into smaller chunks

**Related checks:** Q13, Q19, W1, W2, W4 (sqlstats-review)

---

### Q15 — High Logical Reads Concentration

**What it means:** A single query is reading far more data pages than any other query. High logical reads drive I/O and buffer pool pressure, even if the reads are from cache.

**How to spot it:**
- Single query's total logical reads > 30% of all queries' total logical reads

**Example (problem + fix):**
```
-- dbo.ExportOrders: avg_logical_reads = 2,568,900 per execution
-- 100 executions in 7 days
-- Total reads = 256,890,000 pages — 68% of all reads on the server
```
**Fix options:**
1. Run `/sqlindex-advisor` on the plan — generating covering indexes is the highest-leverage fix
2. Check for Key Lookups (N5 in sqlplan-review): every lookup reads additional pages
3. Check for missing WHERE clause (T2 in tsql-review): the query may be selecting all rows
4. Verify the query actually needs all the columns it's reading (SELECT *)
5. Consider columnstore index for analytical queries scanning large volumes

**Related checks:** Q3, I1, I5 (sqlstats-review), N5 (sqlplan-review), D1 (sqlindex-advisor)

---

### Q16 — High Execution Frequency (N+1 Signal)

**What it means:** A single query runs extremely frequently — potentially an N+1 pattern where the application executes a query inside a loop instead of fetching all data in one batch.

**How to spot it:**
- Single query's `total_executions` > 30% of all queries' total executions
- Total executions ≥ 1,000 in the analysis period

**Example (problem + fix):**
```
-- SELECT * FROM dbo.OrderLines WHERE OrderId = @p0
-- 482,910 executions in 7 days (~69,000/day)
-- Each execution reads 48 pages
-- Total reads = 482,910 × 48 = 23,179,680 pages
-- This is an N+1: the application fetches order lines one order at a time
```
**Fix options:**
1. Check the application code: is a query being called inside a loop?
2. Batch the requests: pass all OrderIds in one call using a TVP or JSON array
3. If batching isn't possible, ensure the query uses a covering index (no Key Lookup per execution)
4. Run `/sqltrace-review` if a trace is available — X13 confirms the N+1 pattern
5. For ORM-generated queries (Entity Framework, Hibernate), check for lazy loading configuration

**Related checks:** Q18, X13 (sqltrace-review), T8 (tsql-review)

---

### Q17 — High Memory Grant Concentration

**What it means:** A single query is requesting large memory grants, which can cause RESOURCE_SEMAPHORE waits for other concurrent queries — they queue up waiting for memory.

**How to spot it:**
- Single query's `avg_memory_grant_mb × total_executions` > 30% of all queries' total memory

**Example (problem + fix):**
```
-- dbo.BuildDashboard: avg_memory_grant_mb = 2,048 MB per execution
-- This query requests 2 GB of memory for a hash join on 5M estimated rows
-- Actual rows: 50,000 (100x overestimate)
-- Memory grant is wasted and blocks other queries from getting memory
```
**Fix options:**
1. Update statistics on the tables involved — the row estimate is stale
2. Run `/sqlplan-review` S2 (excessive memory grant) and S3 (memory grant wait time)
3. Add an index to avoid the hash join entirely (replace with Nested Loops or Merge)
4. Check for parameter sniffing inflating row estimates
5. Add `OPTION (MIN_GRANT_PERCENT = 1)` to cap the memory grant if the estimate is unreliable

**Related checks:** Q13, S2, S3, S4 (sqlplan-review), V4 (sqlwait-review)

---

### Q18 — Workload Concentration

**What it means:** The top few queries dominate resource consumption. Tells you whether targeted tuning (concentrated workload) or systemic changes (flat workload) will have the most impact.

**How to spot it:**
- Top 3 queries > 80% of any metric (CPU, duration, reads)
- Concentration level: ≥ 50% = Concentrated, 25–49% = Moderate, < 25% = Flat

**Example (problem + fix):**
```
-- Concentrated workload: 4 queries = 88.2% of CPU, 76.1% of duration
-- Recommendation: Tune these 4 queries individually for maximum impact
-----------------------------------
-- Flat workload: top 20 queries = only 22% of CPU
-- Recommendation: Look for systemic issues — missing schema prefixes causing
--   plan cache bloat, RECOMPILE hints generating unique plans, or inadequate
--   parameterization of ad-hoc queries
```
**Fix options:**
1. Concentrated: run `/sqlplan-review` on each top query; apply index recommendations
2. Moderate: tune top queries, then investigate long tail
3. Flat: enable forced parameterization: `ALTER DATABASE CURRENT SET PARAMETERIZATION FORCED`
4. Flat: check for missing schema prefixes (dbo.Proc vs Proc generating different plans)
5. Flat: look for `RECOMPILE` hints on many different queries generating unique plans
6. Flat: ensure `optimize for ad hoc workloads` is enabled (reduces plan cache stub size)

**Related checks:** Q13, Q14, Q16

---

## Query-Level Waits (Q19–Q22)

### Q19 — Query Spending Majority of Time Waiting

**What it means:** More than 50% of this query's elapsed time is spent in a wait state (blocked, waiting for I/O, waiting for memory), not actively computing. The query is wait-bound, not CPU-bound.

**How to spot it:**
- From Query B output: `total_query_wait_time_ms` for the query
- Compare to `avg_duration_ms × total_executions` from Query A
- Wait time > 50% of total duration

**Example (problem + fix):**
```
-- dbo.TransferFunds: avg_duration_ms = 8,450 ms, total_executions = 5,200
-- Total duration = 8,450 × 5,200 = 43,940,000 ms
-- Query Store wait stats: total_query_wait_time_ms = 38,500,000 ms (87.6%)
-- Dominant wait: LOCK (LCK_M_X) — 92% of wait time
-- This query is mostly waiting for exclusive locks
```
**Fix options:**
1. Identify the dominant wait category from Query B output
2. LOCK dominant: investigate blocking → `/blocking-review` (future) or `sys.dm_exec_requests`
3. BUFFER_IO dominant: reduce logical reads via indexing → `/sqlindex-advisor`
4. MEMORY dominant: increase server memory or reduce memory grant → Q17
5. NETWORK_IO dominant: check client-side processing → Q22

**Related checks:** Q20, Q21, Q22, W1 (sqlstats-review), V1–V4 (sqlwait-review)

---

### Q20 — Lock Waits Dominant

**What it means:** Lock waits (LCK_M_*) are a significant portion of this query's wait time. The query is being blocked by other sessions holding incompatible locks.

**How to spot it:**
- From Query B: `wait_category_desc` = 'LOCK' and `total_query_wait_time_ms` ≥ 20% of total query wait time

**Example (problem + fix):**
```
-- dbo.UpdateInventory has 78% lock waits
-- Wait type breakdown: LCK_M_U (update locks) 62%, LCK_M_X (exclusive) 16%
-- Multiple sessions are trying to update the same rows concurrently
```
**Fix options:**
1. Enable RCSI: `ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON` — eliminates reader/writer blocking
2. Keep transactions short: commit immediately after the logical unit of work
3. Add covering indexes to speed up the queries, reducing the time locks are held
4. For update locks: ensure the WHERE clause uses an index seek to minimize rows locked
5. Check for missing indexes on FK columns (child table) — FK checks take shared locks on parent tables

**Related checks:** Q19, P2 (sqldeadlock-review), V2 (sqlwait-review)

---

### Q21 — Memory Grant Waits Present

**What it means:** This query had to wait for a memory grant before it could start executing (RESOURCE_SEMAPHORE wait). Other queries are consuming the available query execution memory.

**How to spot it:**
- From Query B: `wait_category_desc` = 'MEMORY' and `total_query_wait_time_ms > 0`

**Example (problem + fix):**
```
-- dbo.ComplexReport waited 45,200 ms for memory grants in past 7 days
-- The query estimates 50M rows for a hash join, but actual is 5M
-- Memory grant request is 4.8 GB per execution
-- When 3 concurrent executions run, they exhaust query memory
```
**Fix options:**
1. Update statistics: stale statistics are the #1 cause of misestimated memory grants
2. Run `/sqlplan-review` S2, S3, S4 for memory grant analysis
3. Add indexes to eliminate the sort/hash operators driving the memory grant
4. Add `OPTION (MAX_GRANT_PERCENT = 1)` to cap how much memory this query can request
5. Increase server memory if consistently under memory pressure

**Related checks:** Q17, S2, S3, S4 (sqlplan-review), V4 (sqlwait-review)

---

### Q22 — Network IO Waits Dominant

**What it means:** The query spent most of its wait time on network I/O. SQL Server has results ready, but the client is slow to consume them. This is almost never a SQL Server problem.

**How to spot it:**
- From Query B: `wait_category_desc` = 'NETWORK_IO' is the #1 wait for the query
- ASYNC_NETWORK_IO is typically the underlying wait type

**Example (problem + fix):**
```
-- dbo.ExportAllCustomers returns 500,000 rows
-- Network IO = 94% of wait time (ASYNC_NETWORK_IO)
-- The application is using a DataTable.Load() which buffers all rows in memory
-- SQL Server sends rows but the client can't consume them fast enough
```
**Fix options:**
1. Check the application: use streaming data readers (SqlDataReader with CommandBehavior.SequentialAccess)
2. Add pagination: `OFFSET ... FETCH NEXT` or keyset pagination
3. Add `SET NOCOUNT ON` at the start of the procedure
4. Reduce the result set: only SELECT columns the application actually needs
5. Check network latency between app server and SQL Server
6. If the query returns 500K+ rows for a UI, paginate — no user can consume that many rows

**Related checks:** Q19, V6 (sqlwait-review), W1 (sqlstats-review)

---

## Operational Health (Q23–Q25)

### Q23 — Query Store Near Size Limit

**What it means:** Query Store storage is approaching its configured maximum. When it hits 100%, Query Store switches to READ_ONLY mode and stops collecting new data — you lose visibility silently.

**How to spot it:**
- From Query C: `current_storage_size_mb > 80% of max_storage_size_mb`

**Example (problem + fix):**
```
-- current_storage_size_mb = 920 MB, max_storage_size_mb = 1,024 MB (89.8%)
-- Query Store has 7 days of data at this size
-- In ~3 more days, it will hit the cap and switch to READ_ONLY
```
**Fix options:**
1. Increase `max_storage_size_mb`: `ALTER DATABASE CURRENT SET QUERY_STORE = ON (MAX_STORAGE_SIZE_MB = 2048)`
2. Reduce `stale_query_threshold_days` to purge old data sooner: `ALTER DATABASE CURRENT SET QUERY_STORE = ON (STALE_QUERY_THRESHOLD_DAYS = 15)`
3. Change to `QUERY_CAPTURE_MODE = AUTO` instead of ALL — captures fewer queries but keeps important ones
4. Manually purge old data: `ALTER DATABASE CURRENT SET QUERY_STORE CLEAR`
5. Ensure `SIZE_BASED_CLEANUP_MODE = AUTO` is set (default) so Query Store automatically purges old data when approaching the limit

**Related checks:** Q24, Q25

---

### Q24 — Query Store Capture Disabled

**What it means:** Query Store is not capturing query data. This could be because it was explicitly disabled, or because it hit the size cap and switched to READ_ONLY mode.

**How to spot it:**
- From Query C: `actual_state_desc = 'READ_ONLY'` OR `query_capture_mode_desc = 'NONE'` OR `actual_state_desc = 'OFF'`

**Example (problem + fix):**
```
-- actual_state_desc = READ_ONLY, readonly_reason = 65536 (MAX_STORAGE_SIZE_MB limit hit)
-- Query Store hit the size cap and stopped collecting 3 days ago
-- All queries since then have no Query Store data
```
**Fix options:**
1. If READ_ONLY due to size cap (`readonly_reason = 65536`): increase `MAX_STORAGE_SIZE_MB`, then re-enable: `ALTER DATABASE CURRENT SET QUERY_STORE = ON`
2. If READ_ONLY for other reasons: check `readonly_reason` column (bitmask — multiple reasons can combine):
   - `1` = database is in read-only mode
   - `2` = database is in single-user mode
   - `4` = database is in emergency mode
   - `8` = database is a readable secondary replica (AG or geo-replication)
   - `65536` = Query Store reached the `max_storage_size_mb` limit (most common operational cause)
   - `131072` = number of statements in Query Store hit an internal memory limit
   - `262144` = in-memory items waiting to be flushed reached an internal limit
   - `524288` = the database itself reached its disk size limit (not the QS max_storage_size — fix the database file growth, not the QS settings)
3. If capture_mode = NONE: `ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = AUTO)`
4. If OFF entirely: `ALTER DATABASE CURRENT SET QUERY_STORE = ON`
5. Important: fixing READ_ONLY restores capture immediately — no data is lost, it just wasn't being collected during the READ_ONLY period

**Related checks:** Q23, Q25

---

### Q25 — No Wait Stats Collection

**What it means:** Query Store wait statistics capture is not enabled. You're missing per-query wait analysis, which is essential for diagnosing blocking, I/O waits, and memory contention at the query level.

**How to spot it:**
- Query A returns data (Query Store is ON) but Query B returns no rows
- From Query C: `wait_stats_capture_mode_desc != 'ON'`

**Example (problem + fix):**
```
-- Query Store is ON and collecting query runtime stats
-- But sys.query_store_wait_stats returns 0 rows
-- wait_stats_capture_mode_desc = OFF
-- Cannot determine WHY queries are slow (blocking? I/O? memory?)
```
**Fix options:**
1. Enable with minimal overhead (< 2%): `ALTER DATABASE CURRENT SET QUERY_STORE = ON (WAIT_STATS_CAPTURE_MODE = ON)`
2. Requires SQL Server 2017+
3. Wait stats capture persists across Query Store configuration changes and server restarts
4. After enabling, wait stats data begins accumulating within the next runtime stats interval (~60 minutes default)
5. For SQL 2016 or Azure SQL DB with compat level < 130: not available — upgrade or note limitation

**Related checks:** Q19–Q22, Q23, Q24

---

## IQP, PSP, and Feedback Checks (Q26–Q32)

### Q26 — PSP Optimization Active (SQL 2022+)

**What it means:** `sys.query_store_plan` has rows with `plan_type_desc IN ('Dispatcher Plan', 'Query Variant Plan')` — Parameter Sensitive Plan optimization is generating multiple variant plans for a query, one per distinct parameter range bucket. (PSP activity does not appear in `sys.query_store_plan_feedback`; that view is used by CE/DOP/Memory Grant Feedback instead — see Q27–Q29.)

**How to spot it:**
```sql
SELECT q.query_id, p.plan_id, p.plan_type_desc, p.count_compiles
FROM sys.query_store_plan p
JOIN sys.query_store_query q ON p.query_id = q.query_id
WHERE p.plan_type_desc IN ('Dispatcher Plan', 'Query Variant Plan')
ORDER BY q.query_id, p.plan_type_desc;
```

**Why it matters:** PSP optimization is beneficial when it converges on stable variants. However, if the engine switches between variants too frequently — because data distribution drifts between bucket boundaries — you get repeated compile overhead and inconsistent response times. The feature itself is a signal that parameter sniffing was severe enough to trigger automatic intervention.

**Fix options:**
1. Check variant plan stability: if the active variant switches frequently, the distribution may be too fluid for PSP to converge
2. Apply `OPTION (OPTIMIZE FOR UNKNOWN)` or `OPTION (OPTIMIZE FOR (@param = <value>))` to lock in a single plan for the common case
3. Add a Query Store hint to pin one plan: `EXEC sys.sp_query_store_set_hints @query_id = <id>, @query_hints = N'OPTION(OPTIMIZE FOR UNKNOWN)'` (`@query_id` is `bigint` — pass the integer value, not a quoted string)
4. Run `/sqlplan-review` check S34 to evaluate the variant plans directly
5. If PSP is causing regressions, disable at database scope: `ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF`

**Related checks:** Q7 (plan count per query), Q8 (plan regression)

---

### Q27 — CE Feedback Persistent Model Adjustment (SQL 2022+)

**What it means:** `sys.query_store_plan_feedback` has rows with `feature_desc = 'CE Feedback'` — the cardinality estimator model has been persistently adjusted for one or more queries based on observed versus estimated row counts.

**How to spot it:**
```sql
SELECT * FROM sys.query_store_plan_feedback WHERE feature_desc = 'CE Feedback';
```

**Why it matters:** CE Feedback refines cardinality estimates for specific queries without requiring statistics updates. This is beneficial when it reduces spills, hash join to nested loops regressions, or over-large memory grants. However, a persistent CE adjustment also signals that the base statistics or model assumptions are wrong — the root cause deserves investigation rather than just accepting the automated fix.

**Fix options:**
1. Cross-reference with runtime stats to confirm the adjustment improved actual elapsed time and logical reads
2. If runtime stats improved, no action is required — CE Feedback is working as designed
3. If a regression occurred after a CE Feedback adjustment, disable for the specific query:
   ```sql
   EXEC sys.sp_query_store_set_hints
       @query_id = <id>,
       @query_hints = N'OPTION(USE HINT(''DISABLE_CE_FEEDBACK''))';
   ```
4. Investigate the underlying cause: refresh statistics (`UPDATE STATISTICS`) and check histogram accuracy with `DBCC SHOW_STATISTICS`
5. Consider upgrading to a newer compatibility level if the CE model version mismatch is the root cause

**Related checks:** Q1 (regressed query), Q8 (plan regression)

---

### Q28 — DOP Feedback Applied (SQL 2022+)

**What it means:** `sys.query_store_plan_feedback` has rows with `feature_desc = 'DOP Feedback'` — the engine has automatically reduced the degree of parallelism for one or more queries because measured parallelism overhead exceeded the benefit.

**How to spot it:**
```sql
SELECT * FROM sys.query_store_plan_feedback WHERE feature_desc = 'DOP Feedback';
```

**Why it matters:** DOP Feedback lowers the effective DOP for queries where thread synchronization cost (CXPACKET/CXCONSUMER waits) outweighs the speedup from parallel execution. When it works correctly, elapsed time drops. When it does not converge — or when it reduces DOP for a query that genuinely benefits from parallelism — elapsed time increases.

**Fix options:**
1. Verify elapsed time improved after DOP was reduced: compare `avg_duration_ms` before and after the feedback rows appeared
2. If elapsed time improved, DOP Feedback is working correctly — no action needed
3. If elapsed time regressed after DOP reduction, disable for the specific query:
   ```sql
   EXEC sys.sp_query_store_set_hints
       @query_id = <id>,
       @query_hints = N'OPTION(USE HINT(''DISABLE_DOP_FEEDBACK''))';
   ```
4. If DOP was reduced inappropriately, set an explicit DOP hint: `OPTION (MAXDOP 8)`
5. Check Q19 and V41 in sqlwait-review for parallelism wait patterns that may explain why DOP Feedback triggered

**Related checks:** Q19 (query-level parallelism waits), V41 (sqlwait-review PSP wait)

---

### Q29 — Memory Grant Feedback Instability (SQL 2019+)

**What it means:** The same `plan_id` has three or more feedback rows in `sys.query_store_plan_feedback` with `feature_desc = 'Memory Grant Feedback'` and different grant values — Memory Grant Feedback (MGF) is oscillating between grant sizes rather than converging on a stable value.

**How to spot it:**
```sql
SELECT plan_id, COUNT(*) AS feedback_count, MIN(feedback_data) AS min_grant, MAX(feedback_data) AS max_grant
FROM sys.query_store_plan_feedback
WHERE feature_desc = 'Memory Grant Feedback'
GROUP BY plan_id
HAVING COUNT(*) >= 3;
```

**Why it matters:** MGF oscillation means the query alternates between spilling to `tempdb` (grant too small) and holding excess memory (grant too large). Neither outcome is good: spills cause disk I/O on `tempdb` and slow the query; over-grants starve concurrent queries of memory and cause RESOURCE_SEMAPHORE waits. The oscillation itself indicates that data distribution is too variable for MGF to find a stable midpoint.

**Fix options:**
1. Pin a specific grant percent to stop the oscillation:
   ```sql
   EXEC sys.sp_query_store_set_hints
       @query_id = <id>,
       @query_hints = N'OPTION(MIN_GRANT_PERCENT=<n>)';
   ```
   Start with a value midway between the min and max observed grants
2. Investigate and close the statistics maintenance gap: run `UPDATE STATISTICS` on all tables referenced by the query and check auto-update statistics thresholds
3. Add indexes to eliminate the sort or hash join operators driving the variable memory requirement
4. Run `/sqlplan-review` checks S2 and S3 to quantify the memory grant overestimate
5. Check if parameter sniffing is causing wildly different row estimates for different parameter values — if so, address Q5 first

**Related checks:** Q1 (regressed query), S2/S3 (sqlplan-review memory grant analysis)

---

### Q30 — Query Store Replica Coverage Gap (SQL 2022+)

**What it means:** Query Store is enabled, but `sys.query_store_replicas` returns fewer replicas than exist in the Always On Availability Group — secondary replica workloads are not being captured in Query Store.

**How to spot it:**
```sql
-- Check if the view exists and how many replicas are tracked
SELECT * FROM sys.query_store_replicas;

-- Compare against AG replica count
SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states;
```

**Why it matters:** By default, Query Store only captures queries executed on the primary replica. Read-scale secondaries, reporting workloads, or AG-redirected read-only connections are invisible. This creates a blind spot: you cannot detect regressions on secondary reads, cannot force plans for secondary-only queries, and cannot see secondary-specific wait patterns.

**Fix options:**
1. Enable Query Store on secondary replicas:
   ```sql
   ALTER DATABASE [YourDatabase] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);
   ALTER DATABASE [YourDatabase] FOR SECONDARY SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);
   ```
2. After enabling, verify all replicas appear: `SELECT * FROM sys.query_store_replicas` — each replica should have a row
3. Note that secondary replica Query Store data is read-only on the secondary and replicated to the primary's Query Store store — review it via the primary connection
4. Generally available starting with SQL Server 2025 (17.x) and in Azure SQL Database; on SQL Server 2022 the feature is limited preview behind trace flag 12606 and not supported for production
5. After enabling, allow one full statistics collection interval (default 60 minutes) before expecting data in `sys.query_store_replicas`

**Related checks:** Q23 (QS near size limit), H26 (sqlhadr-review RCSI)

---

### Q31 — Query Store Hint Ineffective or Stale (SQL 2022+)

**What it means:** `sys.query_store_query_hints` contains a row with a nonzero `query_hint_failure_count` (the hint failed to apply on at least one invocation), or one that references a `query_id` that no longer exists in `sys.query_store_query` — the hint is a dead artifact providing no protection.

**How to spot it:**
```sql
-- Find failed or orphaned hints
SELECT qh.query_hint_id, qh.query_id, qh.query_hint_text,
       qh.query_hint_failure_count, qh.last_query_hint_failure_reason_desc
FROM sys.query_store_query_hints qh
LEFT JOIN sys.query_store_query q ON qh.query_id = q.query_id
WHERE qh.query_hint_failure_count > 0
   OR q.query_id IS NULL;  -- orphaned
```

**Why it matters:** `sp_query_store_set_hints` accepts only a subset of `OPTION()` hints. Invalid hint names are not validated at creation time — they fail silently on first invocation and increment `query_hint_failure_count`, with the reason recorded in `last_query_hint_failure_reason` / `last_query_hint_failure_reason_desc`. Orphaned hints accumulate when query text changes enough to evict the original query from the store, leaving the hint attached to a ghost `query_id`. Both cases mean the intended plan shape is not being enforced.

**Fix options:**
1. For a nonzero `query_hint_failure_count`: remove the hint and re-apply with corrected syntax:
   ```sql
   EXEC sys.sp_query_store_clear_hints @query_id = <id>;
   EXEC sys.sp_query_store_set_hints @query_id = <id>,
        @query_hints = N'OPTION(RECOMPILE)';  -- or valid hint
   ```
2. For orphaned hints (no matching `query_id`): remove them:
   ```sql
   EXEC sys.sp_query_store_clear_hints @query_id = <orphaned_id>;
   ```
3. If IQP CE Feedback (Q27) or DOP Feedback (Q28) is active on the same query, consider removing the hint entirely and letting adaptive feedback manage the plan — manual hints block adaptive mechanisms
4. To list all active hints: `SELECT * FROM sys.query_store_query_hints`
5. Requires SQL Server 2022 (16.x); this DMV does not exist on earlier versions

**Related checks:** Q26 (PSP optimization), Q27 (CE feedback), Q28 (DOP feedback), Q8 (forced plan failure)

---

### Q32 — Automatic Tuning FORCE_LAST_GOOD_PLAN Not Enabled (SQL 2017+)

**What it means:** SQL Server's tuning recommendations engine (`sys.dm_db_tuning_recommendations`) has identified one or more plan regression candidates with auto-correction recommended (`FORCE_LAST_GOOD_PLAN`), but automatic tuning is disabled — the recommended corrections are not being applied automatically.

**How to spot it:**
```sql
-- Find active FORCE_LAST_GOOD_PLAN recommendations
SELECT name, type, state, score,
       JSON_VALUE(details, '$.implementationDetails.script') AS fix_script
FROM sys.dm_db_tuning_recommendations
WHERE type = 'FORCE_LAST_GOOD_PLAN'
  AND state IN ('Verifying', 'Active');

-- Check automatic tuning setting
SELECT desired_state_desc, actual_state_desc, reason_desc
FROM sys.database_automatic_tuning_options
WHERE name = 'FORCE_LAST_GOOD_PLAN';
```

**Why it matters:** SQL Server detected that a query regressed (new plan is slower than a previously cached plan) and identified the "last good" plan to force — but without automatic tuning enabled, it only reports the recommendation; it never acts. Plan regressions persist until a DBA manually forces the plan via Query Store or rewrites the query. In high-churn environments (frequent statistics updates, deployments), this creates a silent backlog of unresolved regressions.

**Fix options:**
1. Enable automatic plan correction for the database:
   ```sql
   ALTER DATABASE [YourDatabase]
   SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);
   ```
2. Verify Query Store is in `READ_WRITE` mode first — required for auto-tuning to force plans (check Q11)
3. Alternatively, manually force the recommended plan using the script from `JSON_VALUE(details, '$.implementationDetails.script')`
4. Auto-tuning coexists with IQP feedback mechanisms (Q26–Q30); the two work independently and do not conflict
5. Avoid enabling auto-tuning alongside active Query Store Hints (Q31) on the same query IDs — hints take precedence and may cause auto-forced plans to be silently ignored
6. Requires SQL 2017+ and database compatibility level 140+; `dm_db_tuning_recommendations` is absent on earlier versions

**Related checks:** Q8 (forced plan failure), Q11 (QS READ_WRITE mode), Q26–Q30 (IQP/feedback signals), Q31 (QS hints)

---

## Quick Reference

| Check | Name | Trigger |
|-------|------|---------|
| Q1 | Duration Regressed vs Baseline | avg_duration_current ≥ 2× avg_duration_baseline |
| Q2 | CPU Regressed vs Baseline | avg_cpu_current ≥ 2× avg_cpu_baseline |
| Q3 | Logical Reads Regressed vs Baseline | avg_reads_current ≥ 3× avg_reads_baseline |
| Q4 | New Plan for Stable Query | plan_count baseline=1, current ≥ 2 |
| Q5 | Variant Plan Performs Worse | max_avg_duration ≥ 3× min_avg_duration |
| Q6 | Regressed + Forced Plan Failure | Q1–Q3 triggered + force_failure_count > 0 |
| Q7 | Plan Instability | plan_count ≥ 3 |
| Q8 | Forced Plan Failure | is_forced_plan + failure_count > 0 |
| Q9 | High Aborted Rate | aborted / total > 0.10 |
| Q10 | Exception Executions | exception_count > 0 |
| Q11 | RECOMPILE on Infrequent Query | RECOMPILE + execs < 100 + duration ≥ 100ms |
| Q12 | Plan Feedback Active | plan_feedback present (SQL 2022+) |
| Q13 | High CPU Concentration | single query > 30% of total CPU |
| Q14 | High Duration Concentration | single query > 30% of total duration |
| Q15 | High Reads Concentration | single query > 30% of total reads |
| Q16 | High Exec Frequency (N+1) | single query > 30% of total executions |
| Q17 | High Memory Concentration | single query > 30% of total memory grant |
| Q18 | Workload Concentration | top 3 > 80% of any metric |
| Q19 | Majority Time Waiting | wait_time > 50% of total duration |
| Q20 | Lock Waits Dominant | LCK ≥ 20% of query wait time |
| Q21 | Memory Grant Waits | MEMORY wait time > 0 |
| Q22 | Network IO Waits Dominant | NETWORK_IO is #1 wait |
| Q23 | Near Size Limit | storage > 80% of max |
| Q24 | Capture Disabled | state = READ_ONLY or capture = NONE |
| Q25 | No Wait Stats | QS ON but wait stats not enabled |
| Q26 | PSP Optimization Active (SQL 2022+) | plan_type_desc IN ('Dispatcher Plan', 'Query Variant Plan') in sys.query_store_plan |
| Q27 | CE Feedback Persistent Model Adjustment (SQL 2022+) | feature_desc = 'CE Feedback' in sys.query_store_plan_feedback |
| Q28 | DOP Feedback Applied (SQL 2022+) | feature_desc = 'DOP Feedback' in sys.query_store_plan_feedback |
| Q29 | Memory Grant Feedback Instability (SQL 2019+) | ≥ 3 'Memory Grant Feedback' rows for same plan_id |
| Q30 | Query Store Replica Coverage Gap (SQL 2022+) | sys.query_store_replicas count < AG replica count |
| Q31 | Query Store Hint Ineffective or Stale (SQL 2022+) | query_hint_failure_count > 0 OR orphaned query_id |
| Q32 | Automatic Tuning FORCE_LAST_GOOD_PLAN Not Enabled (SQL 2017+) | dm_db_tuning_recommendations has Active/Verifying rows + auto-tuning OFF |
