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

**[C1] Forced Plan Failure** (Q8)
- Query: dbo.ReportProc (query_hash 0x3A7F2B1)
- Observed: `is_forced_plan = 1`, `force_failure_count = 3`, `last_force_failure_reason_desc = NO_INDEX`
- Impact: The forced plan references an index that no longer exists. Query Store is failing silently to force the plan and the optimizer is choosing a new (possibly worse) plan on each execution. Current query averages 284,906 ms duration with 2,568,900 logical reads per execution.
- Fix: Unforce the failing plan (`sp_query_store_unforce_plan`). Identify which index was dropped from `force_failure_reason_desc` and either recreate it or capture a new good plan and force that one. Urgent: 3 plans exist (plan instability), 2 of which may be the failed forced plan + new auto-generated plans.

**[C2] Query Store Near Size Limit** (Q23)
- Observed: 892 MB used of 1024 MB max (87.1%). At current growth rate, will hit 100% in approximately 3–5 days. Stale query threshold is 30 days — data retention is very long for the storage available.
- Impact: When Query Store hits the size cap, it will switch to READ_ONLY mode and stop collecting runtime data. All query performance visibility will be lost.
- Fix: Increase `MAX_STORAGE_SIZE_MB` to 2048 MB or reduce `STALE_QUERY_THRESHOLD_DAYS` to 14 days to balance retention vs storage. Run: `ALTER DATABASE SalesDB SET QUERY_STORE = ON (MAX_STORAGE_SIZE_MB = 2048)`.

#### Warnings

**[W1] High Logical Reads Concentration** (Q15)
- Query: dbo.ReportProc (query_hash 0x3A7F2B1)
- Observed: 2,568,900 avg logical reads per execution × 156 executions = ~400 million logical reads in 7 days. Across all visible queries, this single query dominates read I/O.
- Impact: Drives buffer pool churn and I/O pressure even without physical reads. The forced plan failure (Q8) likely means the optimizer is choosing a scan-heavy plan.
- Fix: Fix the forced plan failure (Q8) and run `/sqlplan-index-advisor` on a current plan capture. The Key Lookup or full scan causing this read volume needs a covering index.

**[W2] Plan Instability — 4 Plans** (Q7)
- Query: SELECT COUNT(*) FROM dbo.OrderAudit... (query_hash 0xD2F7E3B)
- Observed: 4 distinct plans for the same query hash. 3,400 total executions. Max duration = 28,400 ms, min = 450 ms (63× variance).
- Impact: Parameter sniffing is causing wildly inconsistent performance. Some executions complete in 450 ms, others take 28 seconds.
- Fix: Run `/sqlplan-review` on the slowest plan. Add `OPTION (RECOMPILE)` as immediate mitigation for the 63× variance. Consider adding a filtered index on `CreatedDate` if the date range varies significantly between executions.

**[W3] Plan Instability — 3 Plans** (Q7)
- Query: dbo.ReportProc (query_hash 0x3A7F2B1)
- Observed: 3 distinct plans. Combined with forced plan failure (Q8) — the forced plan may be invalid, leaving 2 auto-generated plans competing.
- Impact: In addition to the performance problem, plan instability adds uncertainty to troubleshooting.
- Fix: Resolve the forced plan failure first (Q8). After fixing, force the best-performing plan to stabilize.

**[W4] High Duration Concentration** (Q14)
- Query: dbo.ReportProc (query_hash 0x3A7F2B1)
- Observed: 284,906 ms avg per execution (~4.7 minutes). 156 executions = ~12.4 hours of wall-clock time in 7 days.
- Impact: Dominates wall-clock time — blocks other queries during execution and holds locks for extended periods.
- Fix: After resolving forced plan failure (Q8), run `/sqlplan-review` to identify the bottleneck operator. At 2.5M logical reads per execution, a full scan is likely. Run `/sqlplan-index-advisor` for covering index DDL.

**[W5] High CPU Concentration** (Q13)
- Query: dbo.SyncInventory (query_hash 0xF4A8D6C)
- Observed: 280,000 ms avg CPU per execution × 96 executions = ~26.9 million ms of CPU. This is likely the #1 CPU consumer on the server.
- Impact: The MERGE statement is consuming enormous CPU. 452,000 ms duration with 280,000 ms CPU means 62% CPU-bound — the other 38% is waiting.
- Fix: Run `/sqlplan-review` on the MERGE plan. Check for large sorts, hash joins, or full scans on the source/target tables. Consider batching the MERGE into smaller chunks (`TOP 10000` in a loop). Ensure statistics on both source and target tables are up to date.

**[W6] High Execution Frequency — N+1 Signal** (Q16)
- Query: SELECT * FROM dbo.Products WHERE CategoryId... (query_hash 0xA3E9F1D)
- Observed: 156,000 executions in 7 days (~22,000/day, ~930/hour). Avg duration 2 ms — individually fast but massive volume.
- Impact: Classic N+1: the application is fetching products one category at a time. Total reads = 156,000 × 18 = 2.8M pages of wasted I/O from per-execution overhead.
- Fix: Batch the query: fetch all products with `WHERE CategoryId IN (...)` using a TVP, or join in the application layer. If batching is impossible, ensure a covering index on (CategoryId) INCLUDE (all selected columns) to minimize reads per execution.

**[W7] Memory Grant Concentration** (Q17)
- Query: dbo.ReportProc (query_hash 0x3A7F2B1)
- Observed: 2,048.5 MB avg memory grant per execution. This is likely a hash join or large sort with inflated row estimates from the forced plan failure.
- Impact: Blocks other queries from getting memory grants (RESOURCE_SEMAPHORE). When multiple users run this report concurrently, memory exhaustion is likely.
- Fix: Update statistics on involved tables. After fixing the forced plan failure (Q8), the row estimates should improve. Consider adding `OPTION (MAX_GRANT_PERCENT = 1)` as immediate mitigation.

**[W8] Exception Executions** (Q10)
- Query: dbo.UpdateInventory (query_hash 0x1C6A8F2)
- Observed: 3 exceptions in 12,500 executions (0.024%). Low rate but worth investigating — intermittent errors can cause data inconsistencies.
- Impact: Intermittent failures — 3 update transactions failed silently (from the user's perspective).
- Fix: Run `/tsql-review` on the stored procedure body. Check for: division by zero, arithmetic overflow on @Quantity, constraint violations, or conversion errors. Add TRY/CATCH to log the exact error and parameter values.

#### Info

**[I1] Workload Concentration — Concentrated** (Q18)
- Observed: The top 3 queries (SyncInventory, DeptSalaryReport, ReportProc) account for approximately 75%+ of total CPU and duration.
- Impact: Concentrated workload — targeted tuning of these 3 queries will resolve the majority of the server's performance problems.
- Fix: Prioritize: fix ReportProc forced plan failure (Q8) first, then tune SyncInventory (W5), then DeptSalaryReport.

**[I2] High Aborted Execution Rate** (Q9)
- Query: SELECT * FROM dbo.Orders WHERE CustomerId = ... (query_hash 0xB81D4E9)
- Observed: 4,800 aborted / 48,291 total = 9.9% aborted. Close to the 10% threshold.
- Impact: Nearly 1 in 10 executions is timing out or being cancelled. The avg duration (18 ms) is not the issue — the max (22 ms) is also fast. Check the application timeout setting — it may be set aggressively low.
- Fix: Investigate the application's command timeout. At 18 ms average, the query is performant. The aborts may be from a different cause: user cancelling in UI, application connection pool recycling, or Aggressive timeout settings like 15 ms.

**[I3] No Query Store Wait Stats** (Q25)
- Observed: `wait_stats_capture_mode_desc = OFF`. Query Store is collecting runtime stats but not wait stats.
- Impact: Cannot perform per-query wait analysis (Q19–Q22). Cannot determine whether ReportProc (284s duration) is waiting on locks, I/O, or memory.
- Fix: Enable with `ALTER DATABASE SalesDB SET QUERY_STORE = ON (WAIT_STATS_CAPTURE_MODE = ON)`. Overhead is < 2%. After enabling, wait data will be available in the next runtime stats interval (~60 minutes).

**[I4] RECOMPILE-Indicated Adhoc Variants** (Q11)
- Query: SELECT o.OrderId, o.CustomerId... (query_hash 0x7B1C4A8)
- Observed: 34,200 executions (high frequency ad-hoc). Avg duration 8 ms — query is fast.
- Impact: This query runs frequently but is fast. Each ad-hoc execution generates a separate plan stub in the plan cache. With 34,200 executions, this may contribute to plan cache bloat.
- Fix: If the query is from an ORM (Entity Framework), check the query pattern. Consider enabling `optimize for ad hoc workloads` if not already enabled. The query is fast — no performance tuning needed.

### Query Wait Summary (if Query B provided)

Query Store wait stats capture is not enabled on SalesDB. Enable with `WAIT_STATS_CAPTURE_MODE = ON` (see Q25). Without wait stats, cannot determine whether the high-duration queries (ReportProc, SyncInventory) are blocked on locks, waiting for I/O, or queued for memory.

### Passed Checks
Q1 ✓, Q2 ✓, Q3 ✓, Q4 ✓, Q5 ✓, Q6 ✓ (no regressions detected — no baseline provided), Q12 ✓ (no SQL 2022 plan feedback), Q19 ✓, Q20 ✓, Q21 ✓, Q22 ✓ (wait stats not enabled — cannot evaluate), Q24 ✓ (Query Store is READ_WRITE and capturing)
