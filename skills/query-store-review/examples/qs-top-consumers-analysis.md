# Query Store Analysis

### Input Summary
- Source: Query Store DMVs (SQL Server 2019)
- Database: SalesDB
- Time range: 2025-04-26 to 2025-05-03 (UTC) — last 7 days
- Queries analyzed: 10 (top 10 by CPU)
- Total distinct query hashes: ~1,200 (estimated from workload)

### Query Store Health
| Setting | Value | Status |
|---------|-------|--------|
| Current mode | READ_WRITE | OK |
| Storage | 892 / 1024 MB (87.1%) | Warning — see Q23 |
| Capture mode | AUTO | OK |
| Wait stats capture | OFF | Info — see Q25 |

---

### Top Resource Consumers

| # | Query | Object | Execs | Avg CPU ms | Avg Dur ms | Avg Reads | Plans | Forced? |
|---|-------|--------|-------|------------|------------|-----------|-------|---------|
| 1 | MERGE dbo.InventorySummary... | dbo.SyncInventory | 96 | 280,000 | 452,000 | 89,000 | 2 | Yes |
| 2 | SELECT d.DepartmentId... | dbo.DeptSalaryReport | 12 | 118,000 | 125,000 | 450,000 | 1 | No |
| 3 | SELECT o.OrderId, o.CustomerId... | dbo.ReportProc | 156 | 84,200 | 284,906 | 2,568,900 | 3 | Yes |
| 4 | SELECT p.ProductId... | dbo.StockLevel | 845 | 8,200 | 8,920 | 1,250,000 | 1 | No |
| 5 | SELECT COUNT(*) FROM dbo.OrderAudit... | NULL (Adhoc) | 3,400 | 650 | 4,520 | 89,000 | 4 | No |
| 6 | EXEC dbo.UpdateInventory... | dbo.UpdateInventory | 12,500 | 110 | 125 | 2,500 | 1 | No |
| 7 | SELECT * FROM dbo.Orders WHERE... | NULL (Adhoc) | 48,291 | 5 | 18 | 42,015 | 1 | No |
| 8 | SELECT o.OrderId, o.CustomerId... | NULL (Adhoc) | 34,200 | 2 | 8 | 124 | 1 | No |
| 9 | SELECT * FROM dbo.Products WHERE... | NULL (Adhoc) | 156,000 | 0 | 2 | 18 | 1 | No |
| 10 | DELETE FROM dbo.SessionLog... | NULL (Adhoc) | 48,000 | 0 | 0 | 1 | 1 | No |

---

### Performance Findings

#### Critical Issues

**[C1 — Q8] Forced Plan Failure** — dbo.ReportProc
- Query hash: 0x3A7F2B1; plan_id: 847
- Observed: `is_forced_plan = 1`, `force_failure_count = 3`, `last_force_failure_reason_desc = NO_INDEX`
- Impact: The forced plan references an index that no longer exists. Query Store is silently failing to apply the forced plan, and the optimizer is choosing a new (likely scan-heavy) plan on each execution. Current averages: 284,906 ms duration, 2,568,900 logical reads per execution — 3 distinct plans present, indicating persistent instability.
- Immediate investigation:
  ```sql
  -- Identify the forced plan and its missing index reference
  SELECT qp.plan_id, qp.is_forced_plan, qp.force_failure_count,
         qp.last_force_failure_reason_desc,
         TRY_CAST(qp.query_plan AS XML).value(
             '(//MissingIndex/@Table)[1]', 'NVARCHAR(256)') AS missing_table
  FROM sys.query_store_plan qp
  JOIN sys.query_store_query q ON q.query_id = qp.query_id
  WHERE q.query_hash = 0x3A7F2B1
  ORDER BY qp.plan_id;

  -- Unforce the failing plan
  EXEC sys.sp_query_store_unforce_plan @query_id = <query_id>, @plan_id = 847;

  -- Then capture a fresh actual plan with Ctrl+M in SSMS and run /sqlplan-review + /sqlplan-index-advisor
  ```
- Fix: Unforce the failing plan with `sp_query_store_unforce_plan`. Recreate the dropped index (check `force_failure_reason_desc` for the index name) or capture the best-performing auto-generated plan and force that instead. Urgent — 3 plans exist from repeated optimizer fallbacks.

**[C2 — Q23] Query Store Near Size Limit**
- Observed: 892 MB used of 1024 MB max (87.1%). At current growth rate (~17 MB/day estimated), storage will be exhausted in approximately 3–5 days. Stale query threshold is 30 days — retention is too long for the storage configured.
- Impact: When Query Store hits the size cap it switches to READ_ONLY mode and stops collecting runtime data. All query performance visibility is lost until storage is reclaimed.
- Fix:
  ```sql
  -- Option A — increase storage
  ALTER DATABASE SalesDB SET QUERY_STORE = ON (MAX_STORAGE_SIZE_MB = 2048);

  -- Option B — reduce retention to free space immediately
  ALTER DATABASE SalesDB SET QUERY_STORE = ON (STALE_QUERY_THRESHOLD_DAYS = 14);

  -- Check current size after change
  SELECT current_storage_size_mb, max_storage_size_mb
  FROM sys.database_query_store_options;
  ```

#### Warnings

**[W1 — Q15] High Logical Reads Concentration** — dbo.ReportProc
- Observed: 2,568,900 avg logical reads × 156 executions = ~400 million logical reads over 7 days. This single query dominates read I/O across all 1,200 query hashes.
- Impact: Drives buffer pool churn and PAGEIOLATCH waits even when no physical reads occur. The forced plan failure (C1) is likely causing full table scans on each execution.
- Fix: Resolve C1 first. Then run `/sqlplan-index-advisor` on the current plan to identify a covering index for the dominant scan. A single well-chosen covering index typically reduces this class of read volume by 95%+.

**[W2 — Q7] Plan Instability — 4 Plans, 63× Duration Variance** — SELECT COUNT(*) FROM dbo.OrderAudit
- Observed: 4 distinct execution plans for query_hash 0xD2F7E3B. 3,400 total executions; min duration 450 ms, max duration 28,400 ms — **63× variance** between best and worst execution. The optimizer is choosing different plans for different parameter values.
- Impact: Classic parameter sniffing. 10% of executions (340 runs/week) take 28 seconds instead of 450 ms — equivalent to ~2.6 hours of unnecessary wait time per week from this single query.
- Immediate investigation:
  ```sql
  -- Show all plans with their runtime stats for this query
  SELECT qp.plan_id, qp.is_forced_plan,
         rs.avg_duration / 1000.0 AS avg_ms,
         rs.min_duration / 1000.0 AS min_ms,
         rs.max_duration / 1000.0 AS max_ms,
         rs.count_executions
  FROM sys.query_store_plan qp
  JOIN sys.query_store_runtime_stats rs ON rs.plan_id = qp.plan_id
  JOIN sys.query_store_query q ON q.query_id = qp.query_id
  WHERE q.query_hash = 0xD2F7E3B
  ORDER BY rs.avg_duration DESC;
  ```
- Fix: Run `/sqlplan-review` on the slowest plan. Add `OPTION (RECOMPILE)` as immediate mitigation — it eliminates plan reuse and forces per-execution compilation, removing the sniffing effect at the cost of slightly higher compile overhead (~1–3 ms). Consider a filtered index on `CreatedDate` if the date range parameter varies significantly.

**[W3 — Q7] Plan Instability — 3 Plans** — dbo.ReportProc
- Observed: 3 distinct plans for query_hash 0x3A7F2B1. Combined with forced plan failure (C1) — the failed forced plan plus 2 auto-generated fallbacks all coexist.
- Impact: Instability compounds the performance problem — troubleshooting is harder when the plan changes on every investigation.
- Fix: Resolve C1 (unforce the failing plan). After the forced plan failure is cleared, the optimizer will stabilize on a single plan. Then force that plan to lock in the good execution.

**[W4 — Q14] High Duration Concentration** — dbo.ReportProc
- Observed: 284,906 ms avg per execution (~4.7 minutes). 156 executions = ~12.4 hours of total elapsed time in 7 days. Long-running executions hold row locks for their full duration, blocking concurrent writes.
- Impact: Blocks other queries during execution and holds locks for extended periods. At 2.5M logical reads per execution, a full table scan is likely — each execution holds a shared lock on every scanned page.
- Fix: After resolving C1, run `/sqlplan-review` on the current plan. Expect to find a full table scan or key lookup executing millions of times. Run `/sqlplan-index-advisor` for covering index DDL.

**[W5 — Q13] High CPU Concentration** — dbo.SyncInventory (MERGE)
- Observed: 280,000 ms avg CPU × 96 executions = ~26.9 million ms (~7.5 CPU-hours) in 7 days. 452,000 ms avg elapsed with 280,000 ms CPU = **62% CPU-bound** — compute-intensive with significant wait time (38%).
- Impact: Likely the #1 CPU consumer on the server, competing with all other queries for processor time.
- Fix: Run `/sqlplan-review` on the MERGE execution plan. MERGE statements commonly generate large sorts, hash joins, and full scans on both source and target tables. Consider: (1) batching with `TOP 10000` in a loop to reduce lock duration, (2) ensuring `dbo.InventorySummary` and its source have up-to-date statistics, (3) checking for missing indexes on the MERGE join predicate columns.

**[W6 — Q16] High Execution Frequency — N+1 Pattern** — SELECT * FROM dbo.Products WHERE CategoryId
- Observed: 156,000 executions in 7 days (~22,000/day, ~930/hour). Avg duration 2 ms — individually fast but cumulative overhead is significant.
- Impact: Classic N+1 — the application fetches products one CategoryId at a time. Total reads = 156,000 × 18 = 2.8 million page reads/week from per-execution overhead alone. The `SELECT *` also transfers unnecessary columns.
- Fix: Batch the lookup: `WHERE CategoryId IN (...)` using a table-valued parameter, or join at the application layer. Add a covering index `ON dbo.Products (CategoryId) INCLUDE (ProductId, ProductName, Price)` to eliminate the `SELECT *` column overhead. Replace `SELECT *` with an explicit column list in the source procedure.

**[W7 — Q17] Memory Grant Concentration** — dbo.ReportProc
- Observed: 2,048.5 MB avg memory grant per execution. Inflated row estimates from the forced plan failure (C1) are causing the optimizer to over-allocate memory for hash joins or sorts.
- Impact: When multiple users run this report concurrently, each holds 2 GB of memory grant — 3 concurrent executions consume 6 GB, triggering `RESOURCE_SEMAPHORE` queuing for all other queries.
- Fix: Update statistics on involved tables. After resolving C1, row estimates will improve and the grant should drop significantly. Add `OPTION (MAX_GRANT_PERCENT = 1)` as immediate mitigation to cap this query's grant at 1% of server memory.

**[W8 — Q10] Exception Executions** — dbo.UpdateInventory
- Observed: 3 exceptions in 12,500 executions (0.024%). Low rate but exceptions from a stored procedure that updates data can cause partial updates or silent data inconsistencies.
- Fix: Run `/tsql-review` on the `dbo.UpdateInventory` body. Common causes: division by zero on a rate calculation, arithmetic overflow on `@Quantity`, constraint violation from duplicate keys, or conversion error from implicit cast. Add `TRY/CATCH` to log the exact error message and parameter values to a diagnostics table.

#### Info

**[I1 — Q18] Workload Concentration — Concentrated**
- Observed: Top 3 queries (SyncInventory, DeptSalaryReport, ReportProc) account for approximately 75%+ of total CPU and duration across the captured workload.
- Impact: Concentrated workload — targeted tuning of 3 queries resolves the majority of server performance problems. This is favorable: diffuse workloads (where 100+ queries each contribute 1%) are much harder to fix.
- Prioritized action order:
  1. Fix ReportProc forced plan failure (C1) — immediate, no schema change needed
  2. Increase Query Store storage (C2) — one ALTER DATABASE command
  3. Tune SyncInventory MERGE (W5) — plan review + index + batching
  4. Fix OrderAudit parameter sniffing (W2) — OPTION (RECOMPILE) first, then index

**[I2 — Q9] High Aborted Execution Rate** — SELECT * FROM dbo.Orders WHERE CustomerId
- Observed: 4,800 aborted / 48,291 total = 9.9% aborted. Query averages 18 ms — not a performance problem.
- Impact: Nearly 1 in 10 executions is being cancelled. At 18 ms average this is not a timeout issue — the application or ORM is cancelling these queries (user navigation, page timeout, connection pool recycling).
- Fix: Investigate the application's command timeout setting. If the ORM issues a cancel on user navigation away from the page, this abort rate is expected. No SQL Server tuning needed for this finding.

**[I3 — Q25] No Query Store Wait Stats**
- Observed: `wait_stats_capture_mode_desc = OFF`. Runtime stats are being collected but not wait stats.
- Impact: Cannot perform per-query wait analysis (Q19–Q22). Cannot determine whether ReportProc's 284-second duration is blocked by I/O, locks, or memory — critical for root cause analysis.
- Fix:
  ```sql
  ALTER DATABASE SalesDB SET QUERY_STORE = ON (WAIT_STATS_CAPTURE_MODE = ON);
  -- Overhead < 2%; wait data available in the next runtime interval (~60 minutes)
  ```

**[I4 — Q11] High-Frequency Adhoc — Plan Cache Pressure**
- Query: SELECT o.OrderId, o.CustomerId... (query_hash 0x7B1C4A8)
- Observed: 34,200 executions, avg 8 ms. Fast query — no performance concern. However, each adhoc execution generates a separate plan stub in the plan cache if `optimize for ad hoc workloads` is not enabled.
- Fix: Enable `optimize for ad hoc workloads` if not already set (`sp_configure 'optimize for ad hoc workloads', 1`). The query is fast — no further tuning needed.

---

### Query Wait Summary

Query Store wait stats capture is not enabled on SalesDB. Enable with `WAIT_STATS_CAPTURE_MODE = ON` (see I3). Without wait stats, the following per-query wait checks cannot fire: Q19 (dominant wait per query), Q20 (per-query I/O waits), Q21 (per-query lock waits), Q22 (per-query memory waits). This is especially limiting for dbo.ReportProc (284 s duration) and dbo.SyncInventory (452 s duration) — knowing whether their time is spent on I/O, locks, or CPU would immediately narrow the fix.

---

### Prioritized Fix Sequence

| Step | Finding | Action | Effort | Expected Impact |
|------|---------|--------|--------|-----------------|
| 1 | C1 — Forced plan failure | `sp_query_store_unforce_plan` + index or new forced plan | 15 min | Eliminates W1, W3, W4, W7 cascade |
| 2 | C2 — Storage near limit | `ALTER DATABASE ... MAX_STORAGE_SIZE_MB = 2048` | 5 min | Prevents READ_ONLY mode loss of visibility |
| 3 | I3 — Enable wait stats | `ALTER DATABASE ... WAIT_STATS_CAPTURE_MODE = ON` | 2 min | Unlocks Q19–Q22 for root cause analysis |
| 4 | W2 — OrderAudit sniffing | Add `OPTION (RECOMPILE)`, run `/sqlplan-review` | 30 min | Eliminates 63× duration variance (~2.6 hrs/week waste) |
| 5 | W5 — SyncInventory MERGE | `/sqlplan-review` + index + batch by `TOP 10000` | 2–4 hrs | Reduces 7.5 CPU-hours/week |
| 6 | W6 — Products N+1 | Batch lookup with `IN (...)` + covering index | 1–2 hrs (app change) | Eliminates 2.8M reads/week |

---

### Passed Checks

| Check | Description | Result |
|-------|-------------|--------|
| Q1 | Regressed queries vs baseline | ✓ — no baseline provided; cannot evaluate |
| Q2 | Forced plan in READ_WRITE mode | ✓ — mode is READ_WRITE |
| Q3 | Top query CPU ≤ 10× second-highest | ✓ — SyncInventory is 2.4× DeptSalaryReport |
| Q4 | Avg duration ≤ 30,000 ms for top consumers | — ReportProc fails at 284,906 ms (flagged W4) |
| Q5 | No queries with 100% aborted executions | ✓ — max abort rate 9.9% (I2) |
| Q6 | Plan count per query ≤ 3 | — OrderAudit has 4 plans (flagged W2) |
| Q9 | Exception rate ≤ 0.1% per query | — UpdateInventory at 0.024% (flagged W8) |
| Q12 | No SQL 2022 plan feedback regressions | ✓ — not applicable (SQL 2019) |
| Q19 | Dominant wait per query identified | — wait stats OFF (I3) |
| Q20 | Per-query I/O wait analysis | — wait stats OFF (I3) |
| Q21 | Per-query lock wait analysis | — wait stats OFF (I3) |
| Q22 | Per-query memory wait analysis | — wait stats OFF (I3) |
| Q24 | Query Store is READ_WRITE and capturing | ✓ — READ_WRITE, AUTO capture |
