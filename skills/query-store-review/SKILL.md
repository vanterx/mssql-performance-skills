---
name: query-store-review
description: Analyze SQL Server Query Store data to identify regressed queries, plan instability, top resource consumers, query-level wait patterns, and configuration issues. Applies 25 checks (Q1–Q25). Use when a user pastes Query Store DMV output or asks about workload performance trends.
triggers:
  - /query-store-review
  - /qs-review
  - /query-store
---

# SQL Server Query Store Review Skill

## Purpose

Analyze SQL Server Query Store (`sys.query_store_*` DMV) output to identify the most impactful queries in a workload, detect performance regressions, surface plan instability, flag resource hotspots, and audit Query Store configuration health. Applies 25 checks across five categories: regressed queries (Q1–Q6), plan stability (Q7–Q12), resource hotspots (Q13–Q18), query-level waits (Q19–Q22), and operational health (Q23–Q25).

Query Store is the most powerful built-in monitoring tool in SQL Server 2016+. It persists query execution history, plan history, runtime statistics, and wait statistics across server restarts — enabling trend analysis without external monitoring tools. This skill is the diagnostic counterpart to `sqlplan-review`: Query Store tells you *which* queries need attention; execution plan review tells you *why*.

Based on patterns from Erik Darling's sp_QuickieStore and the Microsoft Query Store DMV documentation.

## Input

Accept any of:
- Raw `sys.query_store_runtime_stats` + `sys.query_store_query` + `sys.query_store_plan` query output (paste result grid)
- `sys.query_store_wait_stats` output (SQL 2017+, optional)
- Query Store configuration output from `sys.database_query_store_options`
- A `.csv` or `.txt` file containing any of the above
- A natural language description of Query Store findings ("3 queries regressed after the deployment, Proc_Report went from 200ms to 8s")

### Recommended capture queries

Run these in SSMS and paste the output. The primary query (A) is required; queries B and C provide richer analysis.

**Query A — Top Resource Consumers (SQL 2016+)**

```sql
-- Replace the date range as needed. Default: last 7 days.
DECLARE @start_date datetimeoffset = DATEADD(DAY, -7, GETUTCDATE());
DECLARE @end_date   datetimeoffset = GETUTCDATE();
DECLARE @top_n      integer = 20;

SELECT TOP (@top_n)
    database_name   = DB_NAME(),
    query_sql_text  = TRY_CAST(qt.query_sql_text AS nvarchar(200)),
    object_name     = OBJECT_NAME(q.object_id),
    query_id        = q.query_id,
    query_hash      = q.query_hash,
    plan_count      = COUNT(DISTINCT p.plan_id),
    total_executions    = SUM(rs.count_executions),
    avg_duration_ms     = SUM(rs.avg_duration) / NULLIF(SUM(rs.count_executions), 0) / 1000.0,
    avg_cpu_ms          = SUM(rs.avg_cpu_time) / NULLIF(SUM(rs.count_executions), 0) / 1000.0,
    avg_logical_reads   = SUM(rs.avg_logical_io_reads) / NULLIF(SUM(rs.count_executions), 0),
    avg_physical_reads  = SUM(rs.avg_physical_io_reads) / NULLIF(SUM(rs.count_executions), 0),
    avg_logical_writes  = SUM(rs.avg_logical_io_writes) / NULLIF(SUM(rs.count_executions), 0),
    avg_memory_grant_mb = SUM(rs.avg_query_max_used_memory) / NULLIF(SUM(rs.count_executions), 0) * 8.0 / 1024.0,
    max_duration_ms     = MAX(rs.max_duration) / 1000.0,
    min_duration_ms     = MIN(rs.min_duration) / 1000.0,
    max_cpu_ms          = MAX(rs.max_cpu_time) / 1000.0,
    min_cpu_ms          = MIN(rs.min_cpu_time) / 1000.0,
    last_execution_time = MAX(rs.last_execution_time),
    is_forced_plan      = MAX(CASE WHEN p.is_forced_plan = 1 THEN 1 ELSE 0 END),
    force_failure_count = MAX(p.force_failure_count),
    last_force_failure_reason_desc = MAX(p.last_force_failure_reason_desc),
    aborted_count       = SUM(CASE WHEN rs.execution_type = 1 THEN rs.count_executions ELSE 0 END),
    exception_count     = SUM(CASE WHEN rs.execution_type = 2 THEN rs.count_executions ELSE 0 END),
    avg_tempdb_mb       = SUM(rs.avg_tempdb_space_used) / NULLIF(SUM(rs.count_executions), 0) * 8.0 / 1024.0
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt
    ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan AS p
    ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats AS rs
    ON p.plan_id = rs.plan_id
WHERE rs.last_execution_time >= @start_date
  AND rs.last_execution_time <  @end_date
  AND rs.execution_type IN (0, 1, 2) -- regular, aborted, exception
GROUP BY qt.query_sql_text, q.query_id, q.query_hash, q.object_id
HAVING SUM(rs.count_executions) > 0
ORDER BY SUM(rs.avg_cpu_time * rs.count_executions) DESC;
```

**Query B — Wait Stats Per Query (SQL 2017+)**

```sql
-- Requires Query Store wait stats capture enabled:
-- ALTER DATABASE CURRENT SET QUERY_STORE = ON (WAIT_STATS_CAPTURE_MODE = ON);

SELECT TOP 20
    ws.wait_category_desc,
    query_sql_text = TRY_CAST(qt.query_sql_text AS nvarchar(200)),
    q.query_hash,
    total_wait_time_ms   = SUM(ws.total_query_wait_time_ms),
    avg_wait_time_ms     = AVG(ws.avg_query_wait_time_ms),
    wait_category_rank   = ROW_NUMBER() OVER (PARTITION BY q.query_hash ORDER BY SUM(ws.total_query_wait_time_ms) DESC)
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_plan AS p
    ON ws.plan_id = p.plan_id
JOIN sys.query_store_query AS q
    ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt
    ON q.query_text_id = qt.query_text_id
WHERE ws.last_execution_time >= DATEADD(DAY, -7, GETUTCDATE())
GROUP BY ws.wait_category_desc, qt.query_sql_text, q.query_hash
ORDER BY total_wait_time_ms DESC;
```

**Query C — Query Store Configuration**

```sql
SELECT
    database_name            = DB_NAME(),
    desired_state_desc,
    actual_state_desc,
    readonly_reason,
    current_storage_size_mb,
    max_storage_size_mb,
    flush_interval_seconds,
    interval_length_minutes,
    max_plans_per_query,
    stale_query_threshold_days,
    size_based_cleanup_mode_desc,
    wait_stats_capture_mode_desc,
    capture_mode_desc,
    query_capture_mode_desc
FROM sys.database_query_store_options;
```

**Query D — Regressed Queries (requires two date ranges)**

```sql
-- Run against baseline period, note avg_* values per query_hash.
-- Run again against current period.
-- Compare: current_avg / baseline_avg > 2 indicates regression.
-- Or use sp_QuickieStore with @regression_baseline_start_date and @regression_baseline_end_date.
```

---

## Thresholds Reference

| Metric | Value |
|--------|-------|
| Duration regression | current avg ≥ 2× baseline avg |
| CPU regression | current avg ≥ 2× baseline avg |
| Logical reads regression | current avg ≥ 3× baseline avg |
| Plan instability | ≥ 3 plans for same query hash |
| Aborted execution rate | > 10% of total executions |
| Single query CPU share | > 30% of total CPU |
| Single query duration share | > 30% of total duration |
| Single query reads share | > 30% of total logical reads |
| Single query execution share | > 30% of total executions (N+1 signal) |
| Single query memory share | > 30% of total memory grant |
| Workload concentration | top 3 queries > 80% of any metric |
| Wait dominant | > 50% of query duration spent on a single wait category |
| Lock wait dominant | LCK category ≥ 20% of query wait time |
| Query Store storage | > 80% of max_storage_size_mb |
| Force failure count | any failure > 0 |
| Parameter sensitivity variance | max_duration > 10× min_duration AND ≥ 10 executions |
| Volatile metric variance | (max - min) / avg > 10× with absolute max > 1000 ms |
| Adhoc query variant count | > 10 query_ids sharing same query_hash |

---

## Regressed Queries (Q1–Q6)

Evaluate whether query performance changed between two time periods.

### Q1 — Duration Regressed vs Baseline
- **Trigger:** A query's `avg_duration_ms` in the current period is ≥ 2× the baseline period AND baseline `avg_duration_ms` ≥ 100 ms
- **Severity:** Critical
- **Fix:** Capture the current execution plan (via Query Store `query_plan` XML or `Ctrl+M` in SSMS) and run `/sqlplan-review`. Compare against the baseline plan using `/sqlplan-compare`. Common causes: stale statistics causing the optimizer to choose a worse plan, parameter sniffing (one plan shape for all parameter values), or a new missing index after schema change.

### Q2 — CPU Regressed vs Baseline
- **Trigger:** A query's `avg_cpu_ms` in the current period is ≥ 2× the baseline period AND baseline `avg_cpu_ms` ≥ 50 ms
- **Severity:** Warning
- **Fix:** Increased CPU usually means a scan replaced a seek, a hash join replaced a nested loops join, or an implicit conversion was introduced. Run `/sqlplan-review` on the current plan and `/sqlplan-compare` if you have the baseline plan.

### Q3 — Logical Reads Regressed vs Baseline
- **Trigger:** A query's `avg_logical_reads` in the current period is ≥ 3× the baseline period AND baseline `avg_logical_reads` ≥ 1,000
- **Severity:** Warning
- **Fix:** A large increase in logical reads usually indicates a new Key Lookup or an index seek that degraded to a scan. Run `/sqlplan-index-advisor` on the current plan to generate covering index DDL.

### Q4 — New Plan for Previously Stable Query
- **Trigger:** A query has `plan_count ≥ 2` in the current period but had `plan_count = 1` in the baseline period
- **Severity:** Info
- **Fix:** A new plan appeared. Check if the new plan is better or worse. If worse, force the good plan via `sp_query_store_force_plan`. Investigate why the new plan was generated: statistics update, schema change, or compatibility level change. Run `/sqlplan-compare` if you have both plans.

### Q5 — Variant Plan Performs Worse
- **Trigger:** A query has `plan_count ≥ 2` AND the max `avg_duration_ms` across its plans is ≥ 3× the min `avg_duration_ms` across its plans
- **Severity:** Warning
- **Fix:** One plan performs significantly worse than another for the same query. This is a parameter sniffing signal — different parameter values trigger different plan shapes. Evaluate: `OPTION (RECOMPILE)` for high-variance small queries, `OPTION (OPTIMIZE FOR)` for known typical values, or separate procedures for high/low cardinality paths.

### Q6 — Regressed Query with Forced Plan Failure
- **Trigger:** A query has `is_forced_plan = 1` AND `force_failure_count > 0` AND appears in the regressed list
- **Severity:** Critical
- **Fix:** A plan that was previously forced is now failing to force — the optimizer cannot use the stored plan (schema changed, index dropped, or compatibility level change invalidated it). Unforce the plan (`sp_query_store_unforce_plan`), capture the new plan, and re-evaluate whether forcing is still appropriate.

---

## Plan Stability (Q7–Q12)

Evaluate whether query plans are stable or exhibiting problems.

### Q7 — Plan Instability (Excessive Plans)
- **Trigger:** A query has `plan_count ≥ 3` for the same `query_hash`
- **Severity:** Warning
- **Fix:** The optimizer is generating multiple different plans for the same query. This is usually a parameter sniffing problem: different parameter values cause the optimizer to estimate different row counts and choose different strategies. If all plans perform well, no action needed. If one plan is consistently bad, force the best-performing plan. If variance is unavoidable, add `OPTION (RECOMPILE)` at the cost of compilation overhead.

### Q8 — Forced Plan Failure
- **Trigger:** A query has `is_forced_plan = 1` AND `last_force_failure_reason_desc IS NOT NULL` AND `force_failure_count > 0`
- **Severity:** Critical
- **Fix:** The forced plan cannot be used. Common reasons: index referenced in the stored plan was dropped, schema changed (column data type, table structure), or statistics on a computed column were dropped. Unforce the plan, fix the underlying cause (recreate missing index, update statistics), and then re-force if appropriate.

### Q9 — High Aborted Execution Rate
- **Trigger:** A query has `aborted_count / total_executions > 0.10` (10% aborted)
- **Severity:** Warning
- **Fix:** More than 10% of executions are being aborted (client timeout, attention event, or query cancel). This wastes resources and indicates the query is slower than the client is willing to wait. Run `/sqlplan-review` on the plan. Increase client timeout only after confirming the query cannot be made faster.

### Q10 — Exception Executions Present
- **Trigger:** A query has `exception_count > 0`
- **Severity:** Warning
- **Fix:** One or more executions terminated with an error. Run `/tsql-review` on the query text for correctness issues (T16–T28). Common causes: division by zero, overflow, conversion errors, or constraint violations on specific parameter values.

### Q11 — RECOMPILE Hint on Infrequent Query
- **Trigger:** Query text contains `RECOMPILE` AND `total_executions < 100` in the analysis period AND `avg_duration_ms ≥ 100 ms`
- **Severity:** Info
- **Fix:** RECOMPILE is being used but the query runs infrequently and takes ≥ 100 ms — the compile overhead may be noticeable. Consider whether the parameter sniffing issue this RECOMPILE is fixing could be handled with `OPTION (OPTIMIZE FOR)` instead. For very infrequent queries (< 10 executions per day), RECOMPILE overhead is negligible.

### Q12 — Plan Feedback Active (SQL 2022+)
- **Trigger:** Query Store data includes `plan_feedback` information (plan was adjusted by automated feedback)
- **Severity:** Info
- **Fix:** SQL Server's automated plan correction (PSP optimization or memory grant feedback) has adjusted this query's plan. This is generally desirable. Monitor to confirm the adjusted plan is stable. If feedback causes a regression, disable it with `ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF`.

---

## Resource Hotspots (Q13–Q18)

Evaluate whether individual queries consume a disproportionate share of server resources.

### Q13 — High CPU Concentration
- **Trigger:** A single query accounts for > 30% of total CPU (`avg_cpu_ms × total_executions`) across all captured queries
- **Severity:** Warning
- **Fix:** This query is the dominant CPU consumer. Prioritize it for tuning. Run `/sqlplan-review` on its plan. Focus on: expensive scans (N4), hash joins (N18), sorts (N20), and implicit conversions (N14) — all of which are CPU-intensive.

### Q14 — High Duration Concentration
- **Trigger:** A single query accounts for > 30% of total duration across all captured queries
- **Severity:** Warning
- **Fix:** This query dominates wall-clock time. Determine whether duration is driven by CPU (W5) or waits (W1): run `/sqlstats-review` on `SET STATISTICS TIME ON` output. If CPU-bound, focus on scan/join reduction. If wait-bound, investigate locks, I/O, or network waits.

### Q15 — High Logical Reads Concentration
- **Trigger:** A single query accounts for > 30% of total logical reads across all captured queries
- **Severity:** Warning
- **Fix:** This query is reading far more data than any other query. High logical reads usually indicate: missing index causing a full scan, a Key Lookup executing many times (N5), or a large hash join spilling to tempdb. Run `/sqlplan-index-advisor` to generate covering index DDL.

### Q16 — High Execution Frequency (N+1 Signal)
- **Trigger:** A single query accounts for > 30% of total executions across all captured queries
- **Severity:** Warning
- **Fix:** This query runs frequently — possible N+1 pattern where the application executes a query inside a loop instead of fetching data in one batch. Run `/tsql-review` on the query text (T8 correlated subqueries, T47 nested subqueries). Run `/sqltrace-review` if a trace is available for cross-event pattern confirmation (X13 high-frequency). Consider batching: fetch all data first, then join in application code.

### Q17 — High Memory Grant Concentration
- **Trigger:** A single query accounts for > 30% of total memory grant (`avg_memory_grant_mb × total_executions`) across all captured queries
- **Severity:** Warning
- **Fix:** This query is requesting large memory grants, which can cause RESOURCE_SEMAPHORE waits for other queries. Large memory grants are driven by large sorts and hash joins with inflated row estimates. Update statistics on the involved tables, check for parameter sniffing inflating estimates (S2 in `sqlplan-review`), or add indexes to avoid the sort/hash operation entirely.

### Q18 — Workload Concentration
- **Trigger:** The top 3 queries account for > 80% of total CPU, duration, reads, or executions
- **Severity:** Info
- **Fix:** The workload is concentrated — a few queries dominate. This is the ideal scenario for targeted tuning: fixing one or two queries can resolve most of the server load. Run `/sqlplan-review` on the top 3 plans. If the workload is flat (< 25% concentration), look for systemic issues: forced parameterization opportunities, missing schema prefixes causing plan cache bloat, or `RECOMPILE` hints generating unique plans.

---

## Query-Level Waits (Q19–Q22)

Evaluate wait statistics per query (requires SQL 2017+ with `WAIT_STATS_CAPTURE_MODE = ON`).

### Q19 — Query Spending Majority of Time Waiting
- **Trigger:** For a given query, `total_query_wait_time_ms > 50% of avg_duration_ms × total_executions`
- **Severity:** Warning
- **Fix:** More than half of this query's elapsed time is spent waiting, not computing. Check the dominant wait category (from Query B output). Lock waits → investigate blocking source. Buffer IO waits → reduce logical reads via indexing. Network IO waits → investigate client-side row-by-row processing.

### Q20 — Lock Waits Dominant
- **Trigger:** The `LCK` wait category accounts for ≥ 20% of a query's total wait time
- **Severity:** Warning
- **Fix:** This query is blocked by locks from other sessions. Run `/sqlplan-deadlock` if deadlocks occur. For blocking: check whether `READ_COMMITTED_SNAPSHOT` is enabled (RCSI). If not, enabling it eliminates reader/writer blocking. If already enabled, investigate the blocking session via `sys.dm_exec_requests`.

### Q21 — Memory Grant Waits Present
- **Trigger:** The `MEMORY` wait category has `total_query_wait_time_ms > 0`
- **Severity:** Warning
- **Fix:** This query waited for a memory grant before executing (RESOURCE_SEMAPHORE). The optimizer overestimated the memory needed or the server is under memory pressure. Run `/sqlplan-review` S2 (excessive memory grant) and S3 (memory grant wait time). Update statistics to improve row estimates, or increase server memory.

### Q22 — Network IO Waits Dominant
- **Trigger:** The `NETWORK_IO` wait category is the #1 wait for a query
- **Severity:** Info
- **Fix:** The query spent most of its wait time on network I/O (ASYNC_NETWORK_IO). This is almost always a client-side issue: the application is consuming results slowly (row-by-row processing, buffering the entire result set, or slow network). Check: is the application using a streaming data reader? Add `SET NOCOUNT ON`. Add pagination (TOP/FETCH/OFFSET) if the result set is large.

---

## Operational Health (Q23–Q25)

Evaluate Query Store configuration health.

### Q23 — Query Store Near Size Limit
- **Trigger:** `current_storage_size_mb > 80% of max_storage_size_mb` (or > 800 MB if `max_storage_size_mb` is 1 GB)
- **Severity:** Warning
- **Fix:** Query Store is approaching its maximum size. When it hits the limit, it will switch to READ_ONLY mode and stop collecting new data. Increase `max_storage_size_mb` (the default 1 GB is often insufficient for busy servers). Alternatively: reduce the data collection window by lowering `stale_query_threshold_days`, change `capture_mode` to AUTO or CUSTOM, or purge old data with `sp_query_store_flush_db` followed by `sp_query_store_remove_query`.

### Q24 — Query Store Capture Disabled
- **Trigger:** `actual_state_desc = 'READ_ONLY'` OR `capture_mode_desc = 'NONE'`
- **Severity:** Critical
- **Fix:** Query Store is not capturing new query data. If READ_ONLY: the size cap was reached — increase `max_storage_size_mb`, then run `ALTER DATABASE CURRENT SET QUERY_STORE = ON (SIZE_BASED_CLEANUP_MODE = AUTO)` to resume capture. If capture_mode = NONE: run `ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = AUTO)` to start collecting.

### Q25 — No Wait Stats Collection
- **Trigger:** Query Store is enabled (Query A returns data) but Query B returns no rows, AND `wait_stats_capture_mode_desc != 'ON'` in Query C
- **Severity:** Info
- **Fix:** Query Store wait statistics capture is not enabled. Enable it with: `ALTER DATABASE CURRENT SET QUERY_STORE = ON (WAIT_STATS_CAPTURE_MODE = ON)`. This adds minor overhead (< 2%) and enables per-query wait analysis (Q19–Q22). Recommended for all production databases.

---

## Output Format

Structure your report as follows:

```
## Query Store Analysis

### Input Summary
- Source: Query Store DMVs (SQL Server [version])
- Database: [name]
- Time range: [start] to [end] (UTC)
- Queries analyzed: N (top N by CPU)
- Total distinct query hashes: M

### Query Store Health
| Setting | Value | Status |
|---------|-------|--------|
| Current mode | [actual_state_desc] | OK |
| Storage | [current_mb] / [max_mb] MB ([pct]%) | OK/Warning |
| Capture mode | [capture_mode_desc] | OK/Warning |
| Wait stats capture | [ON/OFF] | OK/Info |

---

### Top Resource Consumers

| # | Query | Object | Execs | Avg CPU ms | Avg Dur ms | Avg Reads | Plans | Forced? |
|---|-------|--------|-------|------------|------------|-----------|-------|---------|
| 1 | SELECT ... | dbo.Proc | 12,400 | 842 | 920 | 48,291 | 1 | No |
| 2 | EXEC ... | dbo.Report | 156 | 78,200 | 284,906 | 2,568,900 | 3 | Yes |

### Performance Findings

#### Critical Issues
**[C1] Regressed Query: Duration 5.3× Baseline** (Q1)
- Query: dbo.Report (query_hash 0x...)
- Observed: avg duration increased from 1,200 ms (baseline) to 6,360 ms (current)
- Impact: 5.3× slower; 28% of total server CPU
- Fix: Capture the current plan from Query Store and run /sqlplan-compare against the baseline plan. Add OPTION (RECOMPILE) as immediate mitigation while investigating root cause.

**[C2] Forced Plan Failure** (Q8)
...

#### Warnings
**[W1] Plan Instability: 4 Plans for Single Query** (Q7)
- Query: dbo.GetOrders (query_hash 0x...)
- Observed: 4 distinct plans; durations range from 48 ms to 8,420 ms
- Impact: Unpredictable performance — some executions fast, others slow
- Fix: Force the best-performing plan via sp_query_store_force_plan. Capture plans for slow parameters with /sqlplan-review.

#### Info
**[I1] Workload Concentrated — 3 Queries = 88% of CPU** (Q18)
...

### Query Wait Summary (if Query B provided)

| Query | Dominant Wait | % of Duration | Signal |
|-------|-------------|---------------|--------|
| dbo.Report | LOCK (LCK_M_S) | 68% | Blocking likely |
| SELECT ... | BUFFER_IO (PAGEIOLATCH) | 52% | Scan heavy |

### Passed Checks
Q4 ✓ (brief reason), Q5 ✓ (brief reason) [always include a one-clause reason in parens]

### Prioritized Fix Sequence

Always end the report with this table. Order: (a) fixes that unblock others first,
(b) highest-severity findings, (c) lowest effort. Reference finding IDs in Resolves column.

| Step | Action | Resolves |
|------|--------|----------|
| 1    | [concrete action] | C1, W4 |
| 2    | [concrete action] | I1, W2 |
```

**Formatting rules:**
- Time values: display as `N ms` (e.g., `842 ms`) or `N s` (e.g., `8.4 s`) for values ≥ 10,000 ms
- IO values: comma-formatted thousands separators (e.g., `2,568,900`)
- Query text: truncate to 200 characters with "..." suffix if longer
- Query hash: display as `0x` + hex string (8 bytes)
- Include baseline comparison numbers only when regression data (Query D) is provided
- If Query B (wait stats) is not provided, note "Query Store wait stats capture not enabled — run Query C and see Q25" in the Wait Summary section

---

## Notes

- Query Store data is cumulative within runtime stats intervals (default: 60 minutes). A query that ran 10,000 times in one hour has `count_executions = 10,000` for that interval's row.
- On SQL 2016, `avg_tempdb_space_used` is not available — tempdb metrics will be absent.
- On SQL 2016, Query Store does not include `sys.query_store_wait_stats` — wait checks (Q19–Q22) require SQL 2017+.
- `max_duration` and `min_duration` in the runtime stats represent the max/min per interval, not per execution. An extreme outlier execution within an interval may not be visible.
- Query Store captures only queries that complete (not in-flight queries) — long-running active queries won't appear until they finish.
- Do not invent findings not triggered by the rules above. If a check cannot be evaluated because the input data is missing (e.g., no baseline period for Q1–Q6), note "Cannot evaluate — no baseline data provided" rather than skipping silently.
- For SQL 2022+ databases, note the availability of query feedback and query variants but do not add extra checks beyond Q12.
- If Query Store is disabled or in error state, skip Q1–Q22 entirely and report Q23–Q25 only.
- When Query Store data is very large (> 500 query hashes), focus on the top 20 by CPU and report total hash counts.

## Companion Skills

- **sqlplan-review** — Deep-dive execution plan analysis for any high-cost or regressed query identified here. After identifying *which* queries need attention, use `/sqlplan-review` on each plan to understand *why*.
- **sqlplan-index-advisor** — Generate `CREATE INDEX` DDL for queries with high logical reads (Q15) or plan instability (Q7). Run on specific plans from Query Store's `query_plan` XML.
- **sqlplan-compare** — Diff baseline vs regressed plan for queries flagged by Q1–Q5. Query Store retains old plans — export them as `.sqlplan` files and diff them.
- **sqlplan-deadlock** — If Q20 detects dominant lock waits, capture deadlock XML from `system_health` XE session and analyze the deadlock cycle.
- **tsql-review** — Review the T-SQL source of high-frequency queries (Q16) for N+1 patterns, non-sargable predicates, and dynamic SQL risks.
- **sqlstats-review** — Run `SET STATISTICS IO, TIME ON` on regressed queries to cross-reference I/O metrics with Query Store runtime stats.
- **sqltrace-review** — If a Profiler/XE trace captured the same workload period, cross-reference event-level patterns with Query Store aggregates.
- **sqlwait-review** — If Query Store shows widespread memory or I/O waits (Q19–Q21), run wait statistics analysis at the server level to confirm the bottleneck category.
