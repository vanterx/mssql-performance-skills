# Execution Plan Analysis — `horrible.sqlplan`

> **Input:** `skills/sqlplan-review/examples/horrible.sqlplan` — Run with: `/sqlplan-review skills/sqlplan-review/examples/horrible.sqlplan`
>
> See also: [sqlindex-advisor analysis](sqlindex-advisor/index-advisor-analysis.md) · [sqlplan-batch analysis](sqlplan-batch/batch-analysis.md)

## Summary

- **3 Critical** issues, **10 Warnings**, **1 Info** item
- Primary bottleneck: pervasive cardinality collapse — every operator estimates 1 row but processes millions. Root cause is parameter sniffing (`@StartDate` compiled as `'1900-01-01'`, executed as `'2025-01-01'`) compounded by an implicit type conversion forcing a full index scan on `dbo.Orders.CreatedDate` and a leading-wildcard LIKE on `dbo.Users.Email`.

---

## Critical Issues

### [C1 — S4] Memory Grant Wait — 5,000 ms
- **Observed:** `GrantWaitTime="5000"` ms — exactly at the Critical threshold.
- **Impact:** Every execution of this query blocks for 5 full seconds in the memory broker before a single row is processed. Under concurrency, queued executions add 5 s per slot to elapsed time. `RESOURCE_SEMAPHORE` waits will appear in `sys.dm_os_wait_stats`.
- **Fix:** Reduce grant pressure by fixing cardinality errors (see W7). As an immediate workaround, add `OPTION (RECOMPILE)` to get a per-execution grant sized to the actual row count. If concurrent queuing is happening, configure Resource Governor with `REQUEST_MAX_MEMORY_GRANT_PERCENT`.

### [C2 — N41] Confirmed Sort Spill to TempDb — SpillLevel 2, All 8 Threads (NodeId=5)
- **Observed:** `<SpillToTempDb SpillLevel="2" SpilledThreadCount="8"/>` on the Sort operator. Estimated rows = 1; actual = 9,999,999.
- **Impact:** SpillLevel 2 means the sort's worktable itself overflowed — a recursive spill. All 8 parallel threads wrote to TempDb simultaneously, causing extreme I/O saturation. Sort spills are synchronous; this is likely the largest single contributor to elapsed time.
- **Fix:** Fix cardinality (W7) so the memory grant is sized correctly. Separately, consider whether a pre-sorted index on the join columns can eliminate the Sort operator entirely.

### [C3 — N41] Confirmed Hash Aggregate Spill — SpillLevel 3 (NodeId=6)
- **Observed:** `<HashSpillDetails SpillLevel="3"/>` on the Hash Match (Aggregate). Estimated rows = 1; actual = 9,999,999.
- **Impact:** A 3-level spill means the hash table overflowed into TempDb, then that partition overflowed again, then again. Three-pass TempDb I/O on 10 million rows. Combined with C2, TempDb is under extreme concurrent write pressure from both this and the Sort.
- **Fix:** Same root cause as C2. After fixing cardinality, evaluate whether the aggregation can be pushed earlier in the plan to reduce the row count entering the aggregate.

---

## Warnings

### [W1 — S3] Large Memory Grant — 1,024 MB
- **Observed:** `GrantedMemory="1048576"` KB (exactly 1 GB, the Warning threshold).
- **Impact:** 1 GB reserved from the server's memory broker per execution. Under concurrency this accelerates the C1 grant-wait problem. Notably this 1 GB grant was still insufficient — the query used 2 GB (see W2).
- **Fix:** Fixing cardinality will right-size the grant. The legitimate grant for 10 million rows may still be large, but it will be accurately requested rather than arbitrarily wrong.

### [W2 — S18] Insufficient Memory Grant — Used 2× More Than Granted
- **Observed:** `MaxUsedMemory="2097152"` KB (2 GB) vs `GrantedMemory="1048576"` KB (1 GB). The query consumed exactly double its grant.
- **Impact:** This is the direct cause of C2 and C3 — the Sort and Hash Aggregate both spilled because the grant ran out. The grant was sized for ~1 estimated row; 10 million showed up at runtime.
- **Fix:** Fix parameter sniffing (see Info). Once estimates are accurate the optimizer will request a grant sized for the real workload. Update statistics: `UPDATE STATISTICS dbo.Orders WITH FULLSCAN; UPDATE STATISTICS dbo.Users WITH FULLSCAN;`

### [W3 — N5] Key Lookup at Scale — 5,000,000 Executions (NodeId=4)
- **Observed:** Key Lookup with `ActualRows="5000000"` and `ActualExecutions="5000000"`. Estimated = 1.
- **Impact:** 5 million single-row random I/O lookups into the clustered index. At 0.1 ms per lookup that is 500 seconds of serialized I/O work (distributed across threads, but each thread still performing millions of lookups). This is an N+1 pattern at extreme database scale.
- **Fix:** Extend the non-clustered index on Orders to INCLUDE the columns being fetched in the lookup. Identify those columns from the Key Lookup's output list in the full plan. Example:
  ```sql
  CREATE NONCLUSTERED INDEX [IX_Orders_UserId_Covering]
    ON dbo.Orders (UserId)
    INCLUDE (CreatedDate /*, other selected columns */);
  ```
  This eliminates all 5 million lookups entirely.

### [W4 — N8] Implicit Conversion on dbo.Orders.CreatedDate — Full Scan Forced (NodeId=8)
- **Observed:** Predicate: `CONVERT_IMPLICIT(datetime, [Orders].[CreatedDate]) >= @StartDate`. The column is wrapped in an implicit conversion.
- **Impact:** When the column is wrapped in any function or conversion, no index seek is possible — SQL Server must convert every stored value and then compare. This forces a full index scan of 9,999,999 rows instead of a date-range seek that would return a small fraction of that. This is a primary driver of the cardinality explosion in the Orders/Payments branch.
- **Fix:** Ensure `@StartDate` is declared with the same type as `dbo.Orders.CreatedDate`. Never wrap the column — cast the parameter instead:
  ```sql
  -- If CreatedDate is DATE and @StartDate is DATETIME:
  WHERE o.CreatedDate >= CAST(@StartDate AS DATE)
  -- Or simply declare @StartDate as DATE to match the column type
  ```

### [W5 — N9] Leading Wildcard LIKE on dbo.Users.Email (NodeId=3)
- **Observed:** `[Users].[Email] LIKE '%gmail.com'` on a Clustered Index Scan. 2,000,000 rows read.
- **Impact:** The leading `%` prevents any index seek. SQL Server reads all 2 million Users rows and evaluates the LIKE as a residual predicate. The suggested index on `dbo.Users.Email` (see Missing Indexes) will **not** help with this pattern — B-tree indexes cannot seek on leading wildcards.
- **Fix options in order of preference:**
  1. Full-Text Search: `WHERE CONTAINS(u.Email, '"gmail.com"')` with a full-text index on Email.
  2. Persisted computed column: `EmailDomain AS RIGHT(Email, LEN(Email) - CHARINDEX('@', Email))` with an index, queried as `WHERE u.EmailDomain = 'gmail.com'`.
  3. Reverse-indexed column: store `REVERSE(Email)` and query `WHERE u.EmailReversed LIKE 'moc.liamg%'` — converts leading wildcard to trailing.

### [W6 — N15] High Nested Loop Count — 5,000,000 Inner Executions (NodeId=2)
- **Observed:** Nested Loops driving the Key Lookup (NodeId=4). The outer input (Users scan, 2,000,000 rows) drives 5,000,000 Key Lookup executions on the inner side.
- **Impact:** The optimizer chose Nested Loops because it estimated 1 row on the outer side. With 2 million outer rows this is a catastrophic join strategy. Nested Loops is optimal only when the outer side is very small (typically < a few hundred rows).
- **Fix:** Immediate workaround — force a hash join: `INNER HASH JOIN Orders o ON u.Id = o.UserId`. Structural fix — address the cardinality errors (W7) so the optimizer selects Hash Match automatically.

### [W7 — N21] Pervasive Bad Row Estimates — >1,000× Mismatch on All Operators
- **Observed:**

  | NodeId | Operator | Estimated | Actual | Ratio |
  |--------|----------|-----------|--------|-------|
  | 1 | Hash Match Join | 1 | 9,999,999 | 10,000,000× |
  | 2 | Nested Loops | 1 | 5,000,000 | 5,000,000× |
  | 3 | Clustered Index Scan (Users) | 1 | 2,000,000 | 2,000,000× |
  | 4 | Key Lookup | 1 | 5,000,000 | 5,000,000× |
  | 5 | Sort | 1 | 9,999,999 | 10,000,000× |
  | 6 | Hash Aggregate | 1 | 9,999,999 | 10,000,000× |
  | 8 | Index Scan (Orders) | 1,000 | 9,999,999 | 10,000× |

- **Impact:** The entire plan is structured for a 1-row result. Every join strategy, memory grant, parallelism decision, and operator sizing is wrong. This is not a marginal error — the estimates are off by 5–10 million times.
- **Fix:** Root cause is parameter sniffing (see Info section). Fix with `OPTION (RECOMPILE)` or `OPTION (OPTIMIZE FOR (@StartDate = '2025-01-01'))`. Then run `UPDATE STATISTICS` with FULLSCAN on Users, Orders, and Payments.

### [W8 — N6] Sort Spill Risk — Actual Rows 10,000,000× Estimate (NodeId=5)
- **Observed:** Sort with `EstimatedRows="1"` and actual 9,999,999 rows. Actual far exceeds estimate × 10.
- **Impact:** The sort memory was allocated for 1 row. This directly caused the C2 SpillLevel-2 spill. Even after the memory grant is fixed, if the estimate remains at 1 the next execution will repeat the same spill.
- **Fix:** Fix cardinality (W7). If a pre-sorted index can provide rows in the required ORDER BY direction, add it to eliminate the Sort entirely.

### [W9 — N27] Extreme Parallel Thread Skew (NodeId=0, Gather Streams)
- **Observed:** Thread 0: 1 row; Thread 1: 9,999,999 rows. With DOP=8, essentially 100% of work lands on one thread.
- **Impact:** The query pays full parallel overhead (thread coordination, exchange operators, memory for all threads) but receives zero parallel benefit. The single hot thread becomes the bottleneck; all other threads are idle most of the time.
- **Fix:** The skew is a downstream symptom of the implicit conversion on `dbo.Orders.CreatedDate` (W4) concentrating all rows into one partition bucket. Fix W4 first. If skew persists post-fix, investigate data distribution on the Repartition Streams (NodeId=7) partitioning column.

### [W10 — N38] Operator-Level Warnings — Sort (NodeId=5) and Hash Aggregate (NodeId=6)
- **Observed:** `<SpillToTempDb SpillLevel="2">` on the Sort and `<HashSpillDetails SpillLevel="3">` on the Hash Aggregate — both as direct `<Warnings>` children of their respective `<RelOp>` nodes.
- **Impact:** Both operators independently confirmed their spill conditions. The Hash Aggregate's Level-3 spill means three rounds of TempDb recursive partitioning — the worst possible state for a hash operator. Every pass multiplies TempDb I/O.
- **Fix:** Same as C2 and C3 — fix cardinality to right-size the memory grant. No workaround exists for a hash aggregate that receives 10 million rows with a 1-row memory allocation.

---

## Info

### [I1] Parameter Sniffing — @StartDate Compiled '1900-01-01', Runtime '2025-01-01'
- **Observed:** `ParameterCompiledValue="'1900-01-01'"` vs `ParameterRuntimeValue="'2025-01-01'"`. The plan was compiled against a date 125 years in the past.
- **Impact:** A plan compiled for `CreatedDate >= '1900-01-01'` expects essentially all rows in Orders. A plan compiled for `'2025-01-01'` should expect only recent rows. The optimizer built the entire plan — join strategy, memory grant, DOP decisions — for the wrong population. This is the root cause of all N21 mismatch findings.
- **Fix options in priority order:**
  ```sql
  -- Option 1: Recompile per execution (optimal plan every time; acceptable if query runs < few times/sec)
  OPTION (RECOMPILE)

  -- Option 2: Optimize for the common-case value
  OPTION (OPTIMIZE FOR (@StartDate = '2025-01-01'))

  -- Option 3: Local variable — breaks sniffing, uses average density (mediocre but consistent)
  DECLARE @LocalStart DATETIME = @StartDate;
  -- use @LocalStart in the query body

  -- Option 4: Filtered statistics for the common date range
  CREATE STATISTICS stat_Orders_CreatedDate_2025
    ON dbo.Orders (CreatedDate)
    WHERE CreatedDate >= '2025-01-01';
  ```

---

## Missing Indexes

### MI1 — dbo.Users.Email (Optimizer Impact: 99.999%)
```sql
CREATE NONCLUSTERED INDEX [IX_Users_Email]
  ON [ProdDB].[dbo].[Users] ([Email]);
```
> **Warning:** This index will **not** help with `LIKE '%gmail.com'` (leading wildcard forces a scan regardless). The optimizer's 99.999% impact assumes an equality seek. Fix the predicate (W5) before creating this index — otherwise it wastes storage and maintenance overhead with no query benefit.

### Recommended Additional Indexes (not in XML — implied by analysis)
```sql
-- Eliminates the Key Lookup (W3) and converts Index Scan to Seek (W4):
CREATE NONCLUSTERED INDEX [IX_Orders_CreatedDate_UserId]
  ON dbo.Orders (CreatedDate, UserId)
  INCLUDE (/* all Orders columns in the SELECT list */);

-- Supports the Payments side of the Hash Match Join (NodeId=1):
CREATE NONCLUSTERED INDEX [IX_Payments_OrderId]
  ON dbo.Payments (OrderId)
  INCLUDE (/* all Payments columns in the SELECT list */);
```

---

## Prioritized Fix Sequence

| Step | Action | Resolves |
|------|--------|----------|
| 1 | Match `@StartDate` data type to `dbo.Orders.CreatedDate` | W4 — removes implicit conversion, enables Index Seek |
| 2 | Add `OPTION (RECOMPILE)` | I1, W7 — eliminates parameter sniffing, cascades into all estimate fixes |
| 3 | Create covering index on Orders | W3, W6 — eliminates 5M Key Lookups and the Nested Loops N+1 pattern |
| 4 | Rewrite `LIKE '%gmail.com'` predicate | W5 — eliminates 2M-row Users full scan |
| 5 | Run `UPDATE STATISTICS … WITH FULLSCAN` on all three tables | W2, W7 — baseline statistics refresh after structural changes |
| 6 | Re-evaluate DOP and parallelism | W9, C1 — after row counts drop, verify the plan is still benefiting from parallelism |

---

## Passed Checks

| Check | Result |
|-------|--------|
| S1 — Serial Plan | PASS — DOP=8, plan is parallel |
| S2 — Excessive Memory Grant (over-grant ≥ 10×) | PASS — grant is under-sized, not over-sized (S18 triggered instead) |
| S5 — Compile Timeout | PASS — no `StatementOptmEarlyAbortReason` |
| S6 — Compile Memory Exceeded | PASS — not present |
| S7 — High Compile CPU | PASS — CompileCPU=512 ms (threshold: 1,000 ms) |
| S10 — Downlevel Cardinality Estimator | PASS — CE version 160 (SQL 2022, current) |
| S11 — Plan-Level Warnings element | PASS — no `<Warnings>` directly under `<QueryPlan>` (operator-level warnings caught by N38) |
| S12 — Implicit Conversion Affects Seek (plan-level) | PASS — no `<PlanAffectingConvert ConvertIssue="Seek Plan">` in plan warnings |
| S13 / S14 — Table Variables | PASS — no table variable objects in plan |
| S16 — Trivial Plan | PASS — StatementSubTreeCost=98,765; full optimization used |
| S17 — Unparameterized Query | PASS — `@StartDate` present in `<ParameterList>` |
| S19 — FORCE ORDER Hint | PASS — not present |
| S20 — RECOMPILE with Expensive Compile | PASS — no RECOMPILE hint in statement text |
| N2 — Eager Index Spool | PASS — no spool operators |
| N3 — Function on Scan Predicate | PASS — Users scan predicate is a LIKE, not a wrapping function (N9 fires instead) |
| N10 — Cartesian Product / No Join Predicate | PASS — all joins have explicit predicates |
| N11 — Columns With No Statistics | PASS — no `<ColumnsWithNoStatistics>` elements |
| N12 — Backward Scan | PASS — no `ScanDirection="BACKWARD"` |
| N13 / N14 — Multi-Statement TVF | PASS — no TVFs in plan |
| N18 — Adaptive Join | PASS — no `IsAdaptive` attribute |
| N19 — ColumnStore in Row Mode | PASS — no ColumnStore operators |
| N20 — Many-to-Many Merge Join | PASS — no Merge Join operators |
| N23 — Remote Query | PASS — no linked-server/remote operators |
| N25 — Scalar UDF | PASS — no UDF references |
| N29 — Join OR Clause | PASS — no OR in any join predicate |
| N30 — CTE Multiple References | PASS — no CTE in statement text |
| N36 — Forced Plan | PASS — no plan guide or USE PLAN hint |
| N37 — Unmatched Indexes | PASS — no `<UnmatchedIndexes>` element |
| N39 — Heap Scan | PASS — all scans are clustered or non-clustered index scans |
| N40 — Forced Index/Seek/Scan Hint | PASS — no ForcedIndex attributes |
| N44 — Many Joins (Greedy Threshold) | PASS — 2 join operators (threshold: 8) |
| N45 — Non-Index Eager Spool | PASS — no Eager Spool operators |

---
*Analyzed by: Claude Sonnet 4.6 · 2026-05-17 08:30 NZST*
