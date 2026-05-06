---
name: sqlplan-review
description: Analyze SQL Server execution plans for performance anti-patterns. Applies all 99 checks (S1–S33 statement-level, N1–N66 node-level). Use when a user pastes a .sqlplan XML, describes operators, or asks why a query is slow.
triggers:
  - /sqlplan-review
  - /plan-review
---

# SQL Server Execution Plan Review Skill

## Purpose

Analyze a SQL Server execution plan for performance anti-patterns and produce a prioritized, actionable report. Based on the same ruleset used by SentryOne Plan Explorer and similar tools. Covers 99 checks across statement-level (S1–S33) and node-level (N1–N66) categories.

## Input

Accept any of:
- Raw `.sqlplan` XML (paste or file contents)
- A description of the plan tree (operator names, row counts, costs)
- A question like "why is this query slow?" with plan details included

If the user provides XML, extract the relevant attributes yourself before running checks. If the input is a description, apply the checks based on what is mentioned.

## How to Run

Work top-down: statement-level checks first, then walk node-level checks for each operator. Report every triggered finding — do not stop at the first match.

---

## Thresholds Reference

| Metric | Value |
|--------|-------|
| Expensive operator | costPercent ≥ 25% |
| High-cost operator | costPercent ≥ 50% |
| Memory grant info | granted ≥ 512 MB |
| Large memory grant | granted ≥ 1,024 MB |
| Excessive memory grant | granted / used ≥ 10× AND granted ≥ 1 GB |
| Memory grant critical | ≥ 4,096 MB |
| Grant wait warning | > 0 ms |
| Grant wait critical | ≥ 5,000 ms |
| High compile CPU warning | ≥ 1,000 ms |
| High compile CPU critical | ≥ 5,000 ms |
| Downlevel CE | CardinalityEstimationModelVersion < 130 |
| Expensive scan | rowsRead / rowsReturned > 100× |
| Key lookup concern | actualRows > 1,000 OR actualExecutions > 1,000 |
| Sort spill risk | actualRows > estimateRows × 10 |
| Hash spill risk | probeRows > buildRows × 100 |
| High loop count (warning) | actualExecutions > 10,000 |
| High loop count (info) | actualExecutions > 1,000 with high inner cost |
| Bad row estimate (warning) | actual vs estimated > 1,000× in either direction |
| Bad row estimate (info) | actual vs estimated > 100× in either direction |
| Expensive sort | (estimateIO + estimateCPU) ≥ 50% of subtree cost |
| Busy loops | (rebinds + rewinds + 1) > estimateRows × 100 |
| Parallel efficiency low | < 50% AND speedup < DOP × 0.5 AND elapsed ≥ 1,000 ms |
| Large IN list | SeekPredicates with > 20 discrete seek ranges |
| Missing indexes excessive | > 5 MissingIndexGroup children in plan |
| Excessive parameters | > 50 ColumnReference children in ParameterList |
| Window frame large | RANGE UNBOUNDED PRECEDING with actualRows > 100,000 |
| Cached plan size (info) | CachedPlanSize ≥ 1,024 KB |
| Cached plan size (warning) | CachedPlanSize ≥ 5,120 KB |
| Memory request denied (warning) | RequestedMemory > GrantedMemory × 1.1 |
| Serial required memory (info) | SerialRequiredMemory ≥ 524,288 KB (512 MB) |
| Compile wait (info) | CompileTime > CompileCPU × 2 AND CompileTime > 1,000 ms |
| Wide row (warning) | EstimatedAvgRowSize > 8,192 bytes |
| Wide row (critical) | EstimatedAvgRowSize > 32,768 bytes |
| Wide output list (info) | OutputList ColumnReference count > 20 |
| Elapsed time hotspot | ActualElapsedms sum for operator > 1,000 ms AND > 50% of statement elapsed |
| Thread starvation | any RunTimeCountersPerThread ActualRows = 0 while total > 0 |
| Partition elimination failure | ActualPartitionsAccessed = PartitionCount with predicate present |
| Actual rebind excess | ActualRebinds > EstimateRebinds × 10 AND ActualRebinds > 1,000 |

---

## Statement-Level Checks (S1–S33)

Run these once per statement before inspecting individual operators.

### S1 — Serial Plan
- **Trigger:** `NonParallelPlanReason` attribute is present AND `StatementSubTreeCost` ≥ 1.0 AND `StatementOptmLevel` ≠ TRIVIAL
- **Severity:** Warning if reason is actionable (see below), Info otherwise
- **Actionable reasons:** MaxDOPSetToOne, QueryHintNoParallelSet, ParallelismDisabledByTraceFlag, CouldNotGenerateValidParallelPlan, TSQLUserDefinedFunctionsNotParallelizable, TableVariableTransactionsDoNotSupportParallelNestedTransaction
- **Fix:** Remove MAXDOP 1 hint, rewrite scalar UDFs as inline TVFs, replace table variables with temp tables, check server MAXDOP setting

### S2 — Excessive Memory Grant
- **Trigger:** `GrantedMemory` / `MaxUsedMemory` ≥ 10× AND `GrantedMemory` ≥ 1,048,576 KB
- **Severity:** Warning
- **Fix:** Add `OPTION (OPTIMIZE FOR (@param = value))`, update statistics, use `OPTION (RECOMPILE)` to get a per-execution grant

### S3 — Large Memory Grant
- **Trigger:** `GrantedMemory` ≥ 524,288 KB (512 MB) for Info; ≥ 1,048,576 KB (1 GB) for Warning; ≥ 4,194,304 KB (4 GB) for Critical
- **Severity:** Info (≥ 512 MB); Warning (≥ 1 GB); Critical (≥ 4 GB)
- **Fix:** Reduce sort/hash operations, filter earlier in the plan, check for stale statistics causing row overestimates. The 512 MB Info tier surfaces plans that are large but not yet alarming — worth noting before they grow.

### S4 — Memory Grant Wait
- **Trigger:** `GrantWaitTime` > 0
- **Severity:** Warning; Critical if `GrantWaitTime` ≥ 5,000 ms
- **Fix:** Reduce memory grant size (see S2/S3), add Resource Governor pool, or increase `max server memory`

### S5 — Compile Timeout
- **Trigger:** `StatementOptmEarlyAbortReason` = TimeOut
- **Severity:** Critical
- **Fix:** Break the query into smaller pieces, use query hints to guide the optimizer, eliminate unnecessary joins or subqueries, consider a stored procedure with forced plan

### S6 — Compile Memory Exceeded
- **Trigger:** `StatementOptmEarlyAbortReason` = MemoryLimitExceeded
- **Severity:** Critical
- **Fix:** Simplify the query, reduce the number of tables/joins, split into multiple queries

### S7 — High Compile CPU
- **Trigger:** `CompileCPU` ≥ 1,000 ms
- **Severity:** Warning if < 5,000 ms, Critical if ≥ 5,000 ms
- **Fix:** Use `OPTION (RECOMPILE)` sparingly, parameterize the query, use plan guides, reduce query complexity

### S8 — Ineffective Parallelism
- **Trigger:** `DegreeOfParallelism` > 1 AND `elapsedTimeMs` ≥ 1,000 AND parallel efficiency < 50%
- **Calculation:** speedup = cpuTimeMs / elapsedTimeMs; efficiency = ((speedup − 1) / (DOP − 1)) × 100
- **Severity:** Warning
- **Fix:** Investigate thread synchronization, reduce DOP via MAXDOP hint, check for skew in data distribution across threads

### S9 — Parallel Wait Bottleneck
- **Trigger:** `elapsedTimeMs` > `cpuTimeMs` × 2 (threads spending more time waiting than working)
- **Severity:** Warning
- **Fix:** Look for repartition streams, gather streams operators; check for blocking, lock waits, or I/O contention

### S10 — Downlevel Cardinality Estimator
- **Trigger:** `CardinalityEstimationModelVersion` > 0 AND < 130
- **Severity:** Warning
- **Fix:** Update database compatibility level to 130+ (SQL 2016+), or use `OPTION (USE HINT('ENABLE_QUERY_OPTIMIZER_HOTFIXES'))`. Test first — some queries perform better on the old CE.

### S11 — Plan-Level Warnings
- **Trigger:** `<Warnings>` element exists under `<QueryPlan>`
- **Severity:** Warning
- **Fix:** Inspect the specific warning type. Common types: SpillToTempDb, NoJoinPredicate, PlanAffectingConvert

### S12 — Implicit Conversion Affects Seek
- **Trigger:** `<PlanAffectingConvert ConvertIssue="Seek Plan">` present in Warnings
- **Severity:** Critical
- **Fix:** Match the data type of the parameter/literal to the column type. Common mismatch: VARCHAR column with NVARCHAR parameter, or INT column with VARCHAR literal.

### S13 — Table Variable (Read)
- **Trigger:** Any node has `objectName` starting with `@` and statement is not a modification
- **Severity:** Warning
- **Fix:** Replace with a temporary table (`#temp`) so statistics are available, especially when the table variable holds > ~100 rows

### S14 — Table Variable (Write / Modification)
- **Trigger:** Any node has `objectName` starting with `@` and a write operator (Insert/Update/Delete) targets it
- **Severity:** Critical
- **Fix:** Replace with a temp table. Writing to a table variable forces single-threaded execution regardless of DOP.

### S15 — High Compile Memory
- **Trigger:** `CompileMemory` ≥ 1,048,576 KB (1 GB) on `StmtSimple`
- **Severity:** Warning
- **Fix:** The optimizer consumed over 1 GB of memory just to compile this query. Simplify joins and subqueries. Use stored procedures to promote plan reuse and avoid repeated expensive compilations.

### S16 — Trivial Plan
- **Trigger:** `StatementOptmLevel` = TRIVIAL AND `StatementSubTreeCost` ≥ 1.0
- **Severity:** Info
- **Fix:** SQL Server bypassed full optimization and used a trivial plan. Usually benign, but if performance is poor, check for missing indexes or consider forcing full optimization with a query hint.

### S17 — Unparameterized Query
- **Trigger:** No `<ParameterList>` element present on `StmtSimple` AND `StatementType` = SELECT/INSERT/UPDATE/DELETE (not stored procedure)
- **Severity:** Info
- **Fix:** The query has no parameters — it may be an ad-hoc query with literal values baked in. Each unique set of literals produces a new plan cache entry. Use parameterized queries or `sp_executesql` to improve plan reuse and reduce plan cache bloat.

### S18 — Insufficient Memory Grant (Used > Granted)
- **Trigger:** `MemoryGrantInfo/@MaxUsedMemory` > `MemoryGrantInfo/@GrantedMemory` (query used more memory than it was granted)
- **Severity:** Warning — always Warning regardless of the magnitude of under-allocation. The confirmed spills caused by this under-grant are caught as Critical via N41/N38; do not escalate S18 itself.
- **Fix:** The memory grant was undersized because the optimizer underestimated row counts at compile time. This causes the query to spill to tempdb. Fix root-cause cardinality errors (parameter sniffing, stale statistics). Unlike S2/S3 which flag over-allocation, this flags the opposite — the grant was too small.

### S19 — FORCE ORDER Hint
- **Trigger:** `StatementText` matches `/OPTION\s*\([^)]*FORCE\s*ORDER/i`
- **Severity:** Warning
- **Fix:** FORCE ORDER freezes the join order from the query text, overriding the optimizer's cost-based join reordering. Becomes incorrect as data distribution changes. Remove the hint and fix the root cause (missing statistics, missing indexes) so the optimizer can choose the correct order itself.

### S20 — RECOMPILE Hint with Expensive Compile
- **Trigger:** `StatementText` contains `OPTION (RECOMPILE)` AND `CompileCPU` ≥ 500 ms; Critical if `CompileCPU` ≥ 2,000 ms
- **Severity:** Warning / Critical
- **Fix:** OPTION (RECOMPILE) discards the plan after every execution. At high compile CPU, every execution pays a heavy compilation tax. Use `OPTIMIZE FOR` or `OPTION (OPTIMIZE FOR UNKNOWN)` instead. If parameter sniffing is the root cause, address it with filtered statistics or local variable sniffing-prevention.

### S21 — Recursive CTE Without Max Recursion
- **Trigger:** `StatementText` contains `WITH ... AS` and a self-referencing CTE name AND no `OPTION (MAXRECURSION N)` is present
- **Severity:** Warning
- **Fix:** Add `OPTION (MAXRECURSION N)` to avoid runaway recursion on bad data. The default limit is 100; an explicit limit documents intent and prevents accidental infinite loops when hierarchy data has cycles.

### S22 — SET ROWCOUNT Active
- **Trigger:** `RowCountAssignment` attribute > 0 on `StmtSimple`
- **Severity:** Warning
- **Fix:** `SET ROWCOUNT` is deprecated, silently changes plan shapes, and can truncate results without warning. Replace with `TOP (N)` — the optimizer understands TOP and factors it into cost estimation.

### S23 — Excessive Parameter Count
- **Trigger:** `<ParameterList>` has > 50 `<ColumnReference>` children
- **Severity:** Info
- **Fix:** Very high parameter counts inflate plan cache entry size and compile time. Consider batching via table-valued parameters (`CREATE TYPE ... AS TABLE`) or splitting into smaller parameterized queries.

### S24 — Query Store Forced Plan Active
- **Trigger:** `PlanGuideName` attribute starts with `QDS_` on `StmtSimple`
- **Severity:** Warning
- **Fix:** A Query Store forced plan is overriding normal optimization. QDS-forced plans bypass the optimizer and become stale as data changes. Validate the forced plan is still beneficial and that the underlying regression (bad statistics, missing index) has been resolved. If fixed, unforce via `sys.sp_query_store_unforce_plan`.

### S25 — Interleaved Execution (MSTVF) Active
- **Trigger:** `ContainsInterleavedExecutionCandidates = true` on `StmtSimple` (SQL 2017+, compatibility level 140+)
- **Severity:** Info
- **Fix:** SQL Server is using interleaved execution to feed actual row counts from multi-statement TVFs back into optimization. This is beneficial. Verify it has not been suppressed via `OPTION (USE HINT('DISABLE_INTERLEAVED_EXECUTION_TVF'))`, which would revert to the static 1-row estimate.

### S26 — Batch Mode Adaptive Join Active
- **Trigger:** Any operator has `IsAdaptive = 1` AND `executionMode = Batch` (SQL 2019+, compatibility level 150+)
- **Severity:** Info
- **Fix:** SQL Server is deferring the join strategy (Hash vs Nested Loops) to runtime. This is generally good. Flag only if the `AdaptiveThresholdRows` does not match actual row distribution, indicating the threshold was calibrated on a non-representative execution.

### S27 — Excessive Missing Index Suggestions
- **Trigger:** `<MissingIndexes>` element contains > 5 `<MissingIndexGroup>` children
- **Severity:** Warning
- **Fix:** More than 5 distinct missing index suggestions indicate the query touches many under-indexed tables. Prioritize by the `Impact` attribute descending (not document order). Use the `sqlplan-index-advisor` skill to consolidate and de-duplicate suggestions before creating indexes.

### S28 — Large Cached Plan (Plan Cache Bloat)
- **Trigger:** `CachedPlanSize` attribute on `<QueryPlan>` ≥ 1,024 KB
- **Severity:** Info if < 5,120 KB; Warning if ≥ 5,120 KB
- **Fix:** Large cached plans consume plan cache memory and increase the cost of plan cache lookup on every execution. Common causes: queries with many joins, many parameters (see S23), or dynamic SQL with large literals baked in. Parameterize the query or split into smaller units. Also run: `SELECT TOP 10 usecounts, size_in_bytes, text FROM sys.dm_exec_cached_plans CROSS APPLY sys.dm_exec_sql_text(plan_handle) ORDER BY size_in_bytes DESC;`

### S29 — Memory Request Denied by Server
- **Trigger:** `RequestedMemory` > `GrantedMemory` × 1.1 in `MemoryGrantInfo` (the optimizer requested more memory than the server could grant)
- **Severity:** Warning
- **Fix:** The server was under memory pressure at execution time and reduced the grant below what was requested. This is distinct from S4 (grant wait, which measures delay) — this shows the request was cut. Sort and hash operators will spill to TempDb even when statistics are accurate. Increase `max server memory`, add Resource Governor, or reduce concurrent memory demand from other queries.

### S30 — High Serial Required Memory
- **Trigger:** `SerialRequiredMemory` ≥ 524,288 KB (512 MB) in `MemoryGrantInfo`
- **Severity:** Info
- **Fix:** Even in serial mode (DOP 1), this query needs 512 MB+ just for its sort and hash operators. This is an absolute size problem independent of parallelism. Filter data earlier in the plan, add indexes to avoid sorts, or reduce the number of sort/hash operations in the query.

### S31 — Non-QDS Forced Plan (Plan Guide)
- **Trigger:** `PlanGuideName` attribute present on `StmtSimple` AND does NOT start with `QDS_`
- **Severity:** Warning
- **Fix:** A traditional `sp_create_plan_guide` is forcing this plan — distinct from S24 which catches Query Store forced plans. Traditional plan guides are fragile: they break silently when the query text changes, when statistics update dramatically, or when the hinted plan's index is dropped. Validate the guide is still beneficial: `SELECT * FROM sys.plan_guides WHERE name = '<PlanGuideName>';` then capture the current plan without the guide and compare with `/sqlplan-compare`.

### S32 — Compile Wall-Clock vs CPU Gap (Compilation Contention)
- **Trigger:** `CompileTime` > `CompileCPU` × 2 AND `CompileTime` > 1,000 ms (wall-clock compile time significantly exceeds CPU time)
- **Severity:** Info
- **Fix:** SQL Server spent compile time waiting rather than working — typically a latch contention on plan cache bucket locks, or memory pressure forcing the optimizer to wait. `CompileTime` is wall-clock; `CompileCPU` is CPU-only. A large gap means idle CPU during compilation. Check `sys.dm_os_wait_stats` for `RESOURCE_SEMAPHORE_QUERY_COMPILE` waits. Use `OPTION (RECOMPILE)` sparingly or plan guides to reduce compile frequency.

### S33 — Non-Standard Compilation SET Options
- **Trigger:** `StatementSetOptions` element on `StmtSimple` has `QuotedIdentifier="false"` OR `AnsiNulls="false"` OR `AnsiWarnings="false"`
- **Severity:** Info
- **Fix:** The plan was compiled with non-standard SET options — usually because the application sets `SET ANSI_NULLS OFF` or `SET QUOTED_IDENTIFIER OFF`. This creates a separate plan cache entry from SSMS-compiled plans (SSMS always uses standard options), causing plan cache bloat. It also affects query semantics: `SET ANSI_NULLS OFF` changes how NULL comparisons work, and `SET QUOTED_IDENTIFIER OFF` allows double-quoted strings. Align application connection options with SQL Server defaults.

---

## Node-Level Checks (N1–N66)

Apply these to every operator node in the plan tree.

### N1 — Filter Late in Plan
- **Trigger:** `physicalOp` = Filter AND predicate is present AND children exist AND (child elapsed ≥ 10 ms OR child subtree cost ≥ 1.0)
- **Severity:** Warning
- **Fix:** Push the filter condition into the WHERE clause or earlier join condition. Add an index that allows the predicate to be applied as a seek or residual predicate closer to the data source.

### N2 — Eager Index Spool
- **Trigger:** `logicalOp` = Eager Spool AND operator name contains "index"
- **Severity:** Critical
- **Fix:** SQL Server is building a temporary index at runtime because a suitable index does not exist. Add a permanent index matching the spool's seek predicate. Check the Missing Indexes section first.

### N3 — Function on Scan Predicate
- **Trigger:** Operator is a scan AND predicate contains any of: UPPER, LOWER, SUBSTRING, LEFT, RIGHT, LTRIM, RTRIM, REPLACE, CAST, CONVERT, ISNULL, COALESCE, CASE, ABS, CEILING, FLOOR, ROUND, DATEADD, DATEDIFF, DATEPART, YEAR, MONTH, DAY, GETDATE, GETUTCDATE, SYSUTCDATETIME, TRY_CONVERT, PARSE, TRY_PARSE
- **Severity:** Warning
- **Fix:** Rewrite the predicate to be sargable. Examples:
  - `WHERE YEAR(OrderDate) = 2024` → `WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'`
  - `WHERE UPPER(Name) = 'FOO'` → use a case-insensitive collation or a computed column with an index

### N4 — Expensive Scan
- **Trigger:** Operator is a scan AND `actualRowsRead` / `actualRows` > 100× (only when actual stats present)
- **Severity:** Warning
- **Fix:** Add an index with the scan's predicate columns as key columns. If the scan is on a large table, this is your primary optimization target.

### N5 — Key Lookup / RID Lookup at Scale
- **Trigger:** `physicalOp` is Key Lookup or RID Lookup AND (`actualRows` > 1,000 OR `actualExecutions` > 1,000)
- **Severity:** Warning if `costPercent` ≥ 25%, Info otherwise
- **Fix:** Extend the non-clustered index to include (INCLUDE columns) the columns being fetched in the lookup. This eliminates the lookup entirely.

### N6 — Sort Spill Risk
- **Trigger:** `physicalOp` = Sort AND actual stats present AND `actualRows` > `estimateRows` × 10
- **Severity:** Warning
- **Fix:** Update statistics on the table(s) feeding the sort. If spilling is confirmed (check sys.dm_exec_query_stats or Extended Events), add an index that returns data pre-sorted, or increase sort memory with Resource Governor.

### N7 — Hash Spill Risk
- **Trigger:** `physicalOp` = Hash Match AND actual stats present AND probe side rows > build side rows × 100
- **Severity:** Warning
- **Fix:** Update statistics. Consider adding an index to make the build side smaller, or rewrite the join order so the smaller table is the build input. Use `OPTION (HASH JOIN)` to prevent plan flips.

### N8 — Implicit Conversion in Predicate
- **Trigger:** Predicate text contains "convert" or "implicit"
- **Severity:** Warning
- **Fix:** Align data types between the column and the parameter/literal. Inspect `sys.dm_exec_plan_attributes` and `sys.dm_exec_cached_plans` for parameter sniffing issues.

### N9 — Leading Wildcard LIKE
- **Trigger:** Predicate contains `LIKE` followed immediately by a quote character (`'`, `"`) or `%`
- **Severity:** Warning
- **Fix:** Leading wildcards (`LIKE '%foo'`) prevent index seeks and force full scans. Options: Full-Text Search (`CONTAINS`), reverse-indexed column, or an application-level search strategy.

### N10 — No Join Predicate (Cartesian Product)
- **Trigger:** `NoJoinPredicate` flag = 1 or true on the Warnings element of the node
- **Severity:** Critical
- **Fix:** Almost always a bug. Verify the JOIN or WHERE clause includes all intended conditions. If a cross join is intentional, add a comment confirming intent.

### N11 — Columns With No Statistics
- **Trigger:** `<ColumnsWithNoStatistics>` element present in node Warnings
- **Severity:** Warning
- **Fix:** Run `UPDATE STATISTICS <table>` or enable Auto Create Statistics. The optimizer is using a fixed 1-row estimate, which almost always leads to a suboptimal plan.

### N12 — Backward Scan
- **Trigger:** `ScanDirection` = BACKWARD
- **Severity:** Warning
- **Fix:** Add a DESC index that matches the ORDER BY direction, or rewrite the query to avoid reversing the scan direction. Backward scans have higher CPU cost than forward scans.

### N13 — MSTVF Bad Row Estimate
- **Trigger:** `logicalOp` = "Table-valued function" AND `estimateRows` = 1 or 100
- **Severity:** Warning
- **Fix:** SQL Server cannot estimate multi-statement TVF output. Rewrite as an inline TVF (single SELECT statement) so the optimizer can see through it. In SQL 2019+ with compatibility level 150, Interleaved Execution may help.

### N14 — TVF Inside Join
- **Trigger:** `logicalOp` = "Table-valued function" AND parent operator is any join type
- **Severity:** Warning
- **Fix:** TVF row estimates are unreliable (see N13). A bad estimate here can force a nested loops join where a hash join would be far faster. Materialize the TVF into a temp table first, then join.

### N15 — High Nested Loop Count
- **Trigger:** `physicalOp` = Nested Loops AND `actualExecutions` > 10,000 (Warning); Info if > 1,000 AND inner subtree `estimatedTotalSubtreeCost` ≥ 0.5
- **Severity:** Warning (> 10,000 executions); Info (> 1,000 with non-trivial inner cost)
- **Fix:** This is often an N+1 query pattern. Consider Hash Match or Merge Join. Check if an index on the inner side would reduce the per-iteration cost. Look for missing indexes on the inner table's join columns.

### N16 — Busy Loop Pattern
- **Trigger:** `physicalOp` = Nested Loops AND (rebinds + rewinds + 1) > `estimateRows` × 100
- **Severity:** Warning
- **Fix:** The optimizer expects many loops but few output rows. This is a row goal optimization gone wrong. Use `OPTION (DISABLE_OPTIMIZER_ROWGOAL)` (SQL 2016+) or restructure the query to eliminate the row goal.

### N17 — Row Goal Applied
- **Trigger:** `EstimateRowsWithoutRowGoal` > 0
- **Severity:** Info
- **Fix:** The optimizer reduced its row estimate to optimize for returning the first N rows fast (e.g., due to TOP, EXISTS, FAST N hint). This is normal but can cause full-scan plans when more rows are needed. If the full result set is always consumed, use `OPTION (DISABLE_OPTIMIZER_ROWGOAL)`.

### N18 — Adaptive Join
- **Trigger:** `IsAdaptive` = 1 or true
- **Severity:** Info
- **Fix:** No action required. SQL Server will choose between Hash Match and Nested Loops at runtime based on actual row counts. If the adaptive threshold is firing unexpectedly, check for parameter sniffing.

### N19 — ColumnStore in Row Mode
- **Trigger:** `storageType` = ColumnStore AND `executionMode` = Row
- **Severity:** Warning
- **Fix:** Batch mode is 5–10× faster for ColumnStore. Mixed row/column joins, scalar UDFs, or compatibility level < 130 can force row mode. Remove scalar UDFs, ensure compatibility level ≥ 130, and avoid mixing row-store and column-store tables in the same query when possible.

### N20 — Many-to-Many Merge Join
- **Trigger:** `ManyToMany` = 1 or true on the Merge element
- **Severity:** Warning
- **Fix:** A worktable is being written to TempDB. Ensure the join keys are unique on at least one side, or use a Hash Match join instead. Check for missing unique constraints or indexes.

### N21 — Bad Row Estimate
- **Trigger:** Actual stats present AND (`estimateRows` × 1,000 < `actualRows` OR `estimateRows` > `actualRows` × 1,000) for Warning; same check at 100× threshold for Info
- **Severity:** Warning (> 1,000× mismatch); Info (100×–999× mismatch)
- **Fix:** Update statistics (`UPDATE STATISTICS <table> WITH FULLSCAN`). Investigate parameter sniffing (`OPTION (RECOMPILE)` or `OPTIMIZE FOR`). Consider a filtered statistic if the skew is on a specific value range. The 100× Info tier is an early warning; the 1,000× Warning tier indicates the optimizer is likely choosing the wrong join strategy.

### N22 — Expensive Sort
- **Trigger:** `physicalOp` = Sort AND (`estimateIO` + `estimateCPU`) ≥ 50% of `estimatedTotalSubtreeCost` AND parent exists
- **Severity:** Warning
- **Fix:** Add an index whose key columns match the ORDER BY expression and direction. This lets SQL Server avoid the sort entirely by reading data pre-ordered.

### N23 — Remote Query
- **Trigger:** `physicalOp` contains "Remote"
- **Severity:** Warning
- **Fix:** Remote operators (linked servers, OPENQUERY) add network latency and reduce optimizer visibility. Pull data locally into a temp table first, or use a distributed view. Avoid JOINs between local and remote tables in the same query.

### N24 — High Cost Operator
- **Trigger:** `costPercent` ≥ 50%
- **Severity:** Info
- **Fix:** This is your primary optimization target. Focus all index and query rewrite efforts on reducing the cost of this operator before tuning anything else.

### N25 — Scalar UDF Execution
- **Trigger:** `physicalOp` contains "UDF" OR a `<UserDefinedFunction>` element is present on the operator
- **Severity:** Warning
- **Fix:** Scalar UDFs execute once per row and prevent batch mode and parallelism. Rewrite as an inline table-valued function (iTVF) using a single SELECT statement, or inline the logic directly into the query.

### N26 — Exchange Spill
- **Trigger:** `physicalOp` contains "Parallelism" AND `SpillLevel` > 0 OR `SpillCount` > 0 on the operator
- **Severity:** Warning
- **Fix:** The exchange iterator ran out of memory and spilled to TempDB. Fix row estimates feeding the parallel exchange. Increase memory if the grant is too small, or reduce DOP to lower memory pressure.

### N27 — Parallel Thread Skew
- **Trigger:** Actual stats present AND `physicalOp` = "Parallelism" AND max thread rows / avg thread rows > 2×
- **Severity:** Warning
- **Fix:** Work is unevenly distributed across threads, limiting parallel speedup. Investigate data skew on the partitioning column. Consider a different distribution key or use HASH partitioning hints.

### N28 — Lazy Spool Ineffective
- **Trigger:** `logicalOp` = "Lazy Spool" AND actual stats present AND `ActualRebinds` > `ActualRewinds` × 10
- **Severity:** Warning
- **Fix:** The spool cache is rarely reused (high rebinds vs rewinds), making it a net cost rather than a benefit. Investigate why the outer loop produces many unique values. Adding an index on the inner side may eliminate the need for the spool.

### N29 — Join OR Clause
- **Trigger:** Any join operator (`physicalOp` = Hash Match, Merge Join, or Nested Loops) whose predicate text contains ` OR `
- **Severity:** Warning
- **Fix:** OR predicates in joins prevent seek operations and force SQL Server to expand the join into multiple lookup iterations. Rewrite using UNION ALL to split the OR branches, or use a covering index on each branch column.

### N30 — CTE Multiple References
- **Trigger:** A Spool operator (`logicalOp` = Eager Spool or Lazy Spool) is present AND `StatementText` contains a CTE declaration (`WITH ... AS`)
- **Severity:** Warning
- **Fix:** CTEs referenced more than once are re-evaluated on each reference — there is no automatic materialization. Materialize the CTE into a #temp table to compute it once, then reference the temp table multiple times.

### N31 — Top Above Scan
- **Trigger:** `logicalOp` = "Top" AND the direct child operator is a Scan with `costPercent` ≥ 25%
- **Severity:** Warning
- **Fix:** TOP is reading rows from a full scan when an index could provide pre-ordered rows, allowing SQL Server to stop early. Add an index whose key columns match the ORDER BY and WHERE clauses to enable an index seek with early termination.

### N32 — OPTIMIZE FOR UNKNOWN
- **Trigger:** `StatementText` matches `/OPTIMIZE\s+FOR\s+.*UNKNOWN/i`
- **Severity:** Info
- **Fix:** OPTIMIZE FOR UNKNOWN forces the optimizer to use average column density instead of actual parameter values, which can produce plans that are mediocre for all values instead of optimal for common ones. Remove the hint and test; if parameter sniffing is the root cause, address it with filtered indexes, plan guides, or OPTION (RECOMPILE) on the specific problematic executions.

### N33 — NOT IN with Nullable Column
- **Trigger:** `logicalOp` = "Row Count Spool" AND actual stats present AND `ActualRewinds` > 1000
- **Severity:** Warning
- **Fix:** A high-rewind Row Count Spool typically indicates a `NOT IN` against a nullable column. SQL Server must verify the absence of NULLs on every iteration. Rewrite as `NOT EXISTS` or add a `WHERE col IS NOT NULL` filter on the subquery to eliminate the NULL-safety check.

### N35 — Estimated Plan CE Guess
- **Trigger:** Estimated plan only (no runtime stats) AND operator is a Scan AND selectivity (`EstimateRows` / `TableCardinality`) matches a known CE default: 30%, 10%, 9%, 16.4%, or 1% (± 0.5%)
- **Severity:** Info
- **Fix:** The optimizer is using a hardcoded selectivity guess because no statistics exist for the predicate column. Create statistics on the filtered column: `CREATE STATISTICS [stat_col] ON table (col)`. These telltale percentages are reliable indicators of missing statistics.

---

## Missing Index Checks

### N36 — Forced Plan
- **Trigger:** `PlanGuideName` attribute is present on `StmtSimple` OR `StatementText` contains `USE PLAN`
- **Severity:** Warning
- **Fix:** A plan guide or USE PLAN hint is forcing the optimizer to use a specific plan. This can mask underlying issues (bad statistics, missing indexes). Validate that the forced plan is still appropriate — forced plans become stale as data and schema change.

### N37 — Unmatched Indexes
- **Trigger:** `<UnmatchedIndexes>` element is present under `<QueryPlan>`
- **Severity:** Warning
- **Fix:** An index hint was specified but SQL Server could not use it (wrong columns, filtered index mismatch, etc.). The optimizer fell back to a different access path. Remove or correct the index hint, or create an index that matches the hint exactly.

### N38 — Operator-Level Warnings
- **Trigger:** A `<Warnings>` element is present as a direct child of a `<RelOp>` node (distinct from the plan-level `<Warnings>` caught by S11)
- **Severity:** Warning
- **Fix:** Individual operators have flagged warnings — common causes include sort spills, hash spills, and residual I/O issues. Inspect each operator's warning type and address the root cause (statistics, indexes, memory).

### N39 — Heap Scan
- **Trigger:** `physicalOp` = "Table Scan" (indicates a scan on a heap — a table with no clustered index)
- **Severity:** Warning
- **Fix:** Heap scans read every row with no ordering guarantees. Add a clustered index to the table to enable ordered access and reduce I/O. If the table is intentionally a heap (e.g., staging table), add a nonclustered index on the filter column instead.

### N40 — Forced Index / Seek / Scan Hint
- **Trigger:** `ForcedIndex` = 1, `ForceSeek` = 1, or `ForceScan` = 1 attribute on any `RelOp`
- **Severity:** Warning
- **Fix:** An INDEX, FORCESEEK, or FORCESCAN hint is overriding the optimizer's access path choice. Hints become incorrect as data grows and statistics change. Remove the hint and let the optimizer choose, or ensure the hinted index is kept up to date and the hint is still beneficial.

### N41 — Confirmed Spill to TempDb
- **Trigger:** `<SpillToTempDb SpillLevel="N">` element present under `QueryPlan/Warnings` with `SpillLevel` > 0 (requires an actual execution plan, not estimated)
- **Severity:** Warning if `SpillLevel` = 1; Critical if `SpillLevel` ≥ 2
- **Fix:** The sort or hash operator ran out of memory and wrote to tempdb. Fix root-cause cardinality errors (parameter sniffing, stale statistics) so the optimizer requests an adequate memory grant. If estimates are correct but spills persist, increase `min memory per query` via Resource Governor. Unlike N6/N7 which flag spill *risk* from estimates, this is a confirmed actual spill.

### N42 — Implicit Conversion Degrades Cardinality
- **Trigger:** `<PlanAffectingConvert ConvertIssue="Cardinality">` element present in `QueryPlan/Warnings`
- **Severity:** Warning
- **Fix:** An implicit type conversion is distorting the cardinality estimator's histogram lookup, causing it to fall back to a default density vector instead of the actual histogram. This causes wrong join strategies and memory grants even when seeks are still possible. Match the data types of the column and parameter to eliminate the conversion entirely.

### N43 — Residual Predicate on Index Seek
- **Trigger:** A Seek operator (`PhysicalOp` contains "Seek") has both `<SeekPredicates>` AND `<Predicate>` child elements present, AND when runtime data is available `actualRows / actualRowsRead` < 0.1 (seek retrieves 10× more rows than it returns)
- **Severity:** Warning
- **Fix:** The index navigates to matching rows via the seek predicate, but then a residual predicate filters out most of them at the leaf level — wasting I/O on rows that are discarded. Extend the index key to include the residual predicate column (make it a key column, not INCLUDE) so the seek can filter during B-tree traversal rather than at the leaf.

### N44 — Many Joins (Greedy Optimizer Threshold)
- **Trigger:** Count of join operators (`PhysicalOp` = Hash Match, Merge Join, or Nested Loops) ≥ 8 in the plan
- **Severity:** Info
- **Fix:** SQL Server's optimizer uses exhaustive join reordering up to approximately 7–8 tables, then switches to greedy heuristics that may miss the optimal order. This can combine with S5 (compile timeout) to produce a suboptimal plan. Break the query into smaller units using temp tables or CTEs materialised into temp tables to reduce the join count below the greedy threshold.

### N45 — Non-Index Eager Spool (Halloween Protection / Subquery Materialisation)
- **Trigger:** `LogicalOp` = "Eager Spool" AND `PhysicalOp` does NOT contain "Index" AND cost ≥ 10% of plan (distinguishes from N2 which catches index spools)
- **Severity:** Warning
- **Fix:** A non-index Eager Spool (Table Spool) caches a full subtree into a worktable. This typically indicates Halloween protection (DML statement reads and writes the same table — unavoidable) or subquery materialisation. For DML, restructure using a staging temp table. For subqueries, rewrite as a JOIN so the optimizer has more flexibility to avoid the spool.

### N46 — Window Aggregate Without Partition
- **Trigger:** `physicalOp` = "Window Aggregate" or "Sequence Project" AND no `<Partition>` element is present in the window specification
- **Severity:** Warning
- **Fix:** A window function with no PARTITION BY runs over the entire result set as a single partition. If this is intentional (e.g., `ROW_NUMBER() OVER (ORDER BY col)` for a global rank), no fix is needed. If a partition key was omitted accidentally, add `PARTITION BY` to scope the window — this also allows parallelism across partitions.

### N47 — Window Aggregate RANGE Frame (Spool Risk)
- **Trigger:** `physicalOp` = "Window Aggregate" AND `FrameType` = RANGE AND `StartBound` = "UnboundedPreceding" AND `EndBound` = "CurrentRow" AND actual stats present AND `actualRows` > 100,000
- **Severity:** Warning
- **Fix:** `RANGE UNBOUNDED PRECEDING` uses an internal spool that writes one row per pass. `ROWS UNBOUNDED PRECEDING` does not. If there are no duplicate ORDER BY values in the window (or duplicates don't affect correctness), change `RANGE` to `ROWS` in the OVER clause — this eliminates the spool and is 2–10× faster on large datasets.

### N48 — In-Memory OLTP Cross-Container Join
- **Trigger:** Any operator node has `StorageType = InMemory` AND a sibling operator within the same join has `StorageType = RowStore`
- **Severity:** Warning
- **Fix:** Mixing memory-optimized and disk-based tables in a single join forces a cross-container execution context. This prevents natively compiled execution and limits DOP. Separate the workloads: read the memory-optimized table into a `#temp` table, then join against disk-based tables in a separate step.

### N49 — Columnstore Segment Elimination Not Occurring
- **Trigger:** `physicalOp` contains "Columnstore" AND runtime stats present AND `SegmentsPurged` = 0 AND `SegmentsTotal` > 10
- **Severity:** Warning
- **Fix:** Zero segments were eliminated by the predicate — the filter column has no natural sort order within rowgroups. On SQL 2022+, rebuild the columnstore index with `ORDER (col)` to sort rowgroups. On earlier versions, restructure data loads so rows arrive pre-sorted on the filter column. Without elimination, every query does a full columnstore scan.

### N50 — Columnstore Delta Store Read
- **Trigger:** `physicalOp` contains "Columnstore" AND runtime stats present AND `DeltaStoreRows` > 0
- **Severity:** Info
- **Fix:** Open delta stores (not yet compressed rowgroups) are being scanned row-by-row, negating columnstore batch-mode benefits for those rows. This is expected immediately after inserts. If delta stores persist (check `sys.dm_db_column_store_row_group_physical_stats` for OPEN rowgroups with large row counts), force compression: `ALTER INDEX ... REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)`.

### N51 — Batch Mode on Rowstore (SQL 2019+)
- **Trigger:** `executionMode` = Batch AND `storageType` != ColumnStore (SQL 2019+, compatibility level 150+)
- **Severity:** Info
- **Fix:** SQL Server is applying batch mode execution to a rowstore table — a SQL 2019 feature. This is beneficial and typically 2–4× faster for aggregation-heavy queries. No action required. If you see this disabled on similar queries, check for scalar UDFs or row-mode-only operators blocking batch mode propagation.

### N52 — Constant Scan
- **Trigger:** `physicalOp` = "Constant Scan"
- **Severity:** Info
- **Fix:** A Constant Scan produces a fixed set of rows without reading any table. This is normal for `VALUES` lists, system function results, and CTEs folded at compile time. An unexpected Constant Scan — especially when a large table was expected — may indicate a `WHERE 1=0` condition, a parameter value that eliminated all rows at compile time, or a contradiction in the predicate. Verify the plan was compiled with representative parameter values.

### N53 — Assert Operator
- **Trigger:** `physicalOp` = "Assert"
- **Severity:** Info
- **Fix:** An Assert operator enforces a constraint (CHECK, referential integrity, or uniqueness) at runtime. High-cost or high-execution Assert nodes mean constraint validation is a measurable bottleneck. For bulk DML, disable constraints with `ALTER TABLE ... NOCHECK CONSTRAINT`, load, re-enable and re-validate. For FK lookups, ensure the referenced table has a covering index on the FK key column.

### N54 — Lazy Spool on Correlated Subquery (Ineffective Cache)
- **Trigger:** `logicalOp` = "Lazy Spool" AND parent operator is Nested Loops AND runtime stats present AND `ActualRewinds` > 1,000
- **Severity:** Warning
- **Fix:** The spool is attempting to cache the inner side of a correlated subquery, but high rewinds indicate the outer loop produces many unique values, causing cache misses on every iteration. The spool provides no benefit and adds overhead. Rewrite the correlated subquery as a JOIN or `CROSS APPLY` with a derived table so the optimizer can use a hash or merge strategy instead.

### N55 — Large IN List Expanded to Seek Ranges
- **Trigger:** A Seek operator has `SeekPredicates` with > 20 discrete seek ranges (from an `IN` list expansion)
- **Severity:** Warning
- **Fix:** SQL Server expands `WHERE col IN (v1, v2, ...)` into individual seek ranges. Above ~20 values, a `#temp` table + JOIN is more efficient and gives the optimizer accurate cardinality: `INSERT #ids VALUES ...; SELECT ... FROM table JOIN #ids ON id = #ids.id`. This also avoids plan cache bloat from distinct literal sets.

### N56 — Cross Apply with High-Cost Correlated Inner Side
- **Trigger:** `physicalOp` = "Nested Loops" AND `LogicalOp` = "Inner Join" AND `Outer References` are present (correlated apply) AND inner subtree `estimatedTotalSubtreeCost` ≥ 1.0 AND `actualExecutions` > 1,000
- **Severity:** Warning
- **Fix:** A `CROSS/OUTER APPLY` is re-executing an expensive correlated subquery once per outer row. Materialize the inner side into a `#temp` table (pre-joined or pre-aggregated), then join the temp table to the outer set. This allows the optimizer to use a hash or merge join strategy and avoids repeated inner execution.

### N57 — STRING_SPLIT at Scale
- **Trigger:** `physicalOp` = "Table-valued function" AND the operator name or object reference contains "STRING_SPLIT" AND `actualRows` > 10,000
- **Severity:** Warning
- **Fix:** STRING_SPLIT has no statistics — the optimizer always estimates 50 output rows regardless of the input string. At scale, this causes join strategy errors and memory undersizing. For large volumes, pre-split strings in the application layer or load them into a staging table. On SQL 2022+, pass `ENABLE_ORDINAL` as the third argument if the ordinal position is needed; without it the ordinal column is not available.

### N58 — Columnstore Plan with Mixed Batch/Row Mode Operators
- **Trigger:** The plan contains operators with `executionMode = Batch` AND other operators with `executionMode = Row` when a columnstore index is present as a data source
- **Severity:** Warning
- **Fix:** Mixed batch/row mode means the optimizer could not propagate batch mode across the entire plan. Batch mode is 5–10× faster for analytical operators. Common causes: scalar UDFs (rewrite as inline TVFs), row-mode-only join types, or version/compat-level limitations. Check for scalar UDF references (N25) and ensure compatibility level ≥ 130.

### N59 — Index Seek on Column With No Statistics
- **Trigger:** A Seek operator has `<SeekPredicates>` AND a `<ColumnsWithNoStatistics>` warning on the same operator node
- **Severity:** Warning
- **Fix:** The seek is using a column with no statistics histogram. The optimizer falls back to a fixed default selectivity (see N35 for the known default percentages), which will be wrong for any non-uniform distribution. Run `UPDATE STATISTICS <table>` or create statistics explicitly: `CREATE STATISTICS [stat_col] ON table (col)`. This is especially harmful when the seek feeds a nested loops join — a wrong estimate here propagates into every downstream operator.

### N60 — Non-Sargable JSON Predicate
- **Trigger:** Predicate text contains `JSON_VALUE(` or `JSON_QUERY(` in a filter position (WHERE clause or join predicate)
- **Severity:** Warning
- **Fix:** JSON path functions evaluated in WHERE clauses are computed per row and cannot use index seeks. Options: (1) Add a computed column `AS JSON_VALUE(col, '$.path') PERSISTED` and create an index on it — seeks will use the computed column index. (2) On SQL 2022+, use the native JSON index: `CREATE INDEX ... ON table (col) INCLUDE (json_col) WHERE JSON_VALUE(json_col, '$.path') IS NOT NULL`. (3) Filter JSON parsing to the application layer when the result set is small enough.

### N61 — High Estimated Average Row Size
- **Trigger:** Any operator node has `EstimatedAvgRowSize` > 8,192 bytes; Critical if > 32,768 bytes
- **Severity:** Info if > 8,192 bytes; Warning if > 32,768 bytes
- **Fix:** `EstimatedAvgRowSize` is the width (in bytes) of a single row passing through this operator. When rows exceed one 8-KB page, sort and hash operators must allocate at least one buffer page per row — multiplying memory grant requirements dramatically. This is the hidden root cause of unexpectedly large memory grants. Fix: stop projecting columns that are not needed downstream. Replace `SELECT *` with explicit column lists. A 4,000-byte row in a sort of 1 million rows requires ~4 GB of sort memory — check `RequestedMemory` (S29) alongside this check.

### N62 — Actual Elapsed Time Hotspot
- **Trigger:** An operator's total `ActualElapsedms` across all threads (sum of `RunTimeCountersPerThread/@ActualElapsedms`) > 1,000 ms AND represents > 50% of total statement elapsed time (requires actual execution plan)
- **Severity:** Warning
- **Fix:** This operator is the dominant wall-clock bottleneck — not just the highest estimated cost (N24), but the actual time sink at runtime. Estimated cost (N24) reflects the optimizer's model; actual elapsed time reflects I/O waits, lock waits, and memory pressure that cost models do not account for. Focus optimization effort on this operator first regardless of its estimated cost percentage.

### N63 — Thread Starvation (Zero-Row Thread)
- **Trigger:** A `Parallelism` operator has one or more `RunTimeCountersPerThread` entries with `ActualRows = 0` while the total across threads is > 0 (requires actual execution plan)
- **Severity:** Warning
- **Fix:** One or more parallel threads processed zero rows while others did all the work. This is a stronger signal than N27 (skew ratio) — a zero-row thread consumed full thread setup and teardown overhead with zero productive contribution. Causes: hash distribution on a column where all values hash to the same bucket (extreme skew), or partition-aware parallelism where all data falls on one partition. Fix the partitioning column or use `OPTION (MAXDOP 1)` if parallelism consistently starves threads.

### N64 — Wide Projection (SELECT * Anti-Pattern)
- **Trigger:** A Scan or Seek operator's `<OutputList>` contains > 20 `<ColumnReference>` children
- **Severity:** Info
- **Fix:** The scan is projecting more than 20 columns upward through the plan tree. Every downstream Sort, Hash Match, or Nested Loops operator carries this wide row, inflating memory grants (see N61), row buffer sizes, and network I/O. Identify the SELECT list in the query text and replace `SELECT *` with only the columns actually needed. This is especially impactful when the scan feeds a sort or hash join — each wide row multiplies the operator's memory requirement.

### N65 — Partition Elimination Not Occurring
- **Trigger:** A scan operator has `Partitioned="1"` (or `PartitionedScan` element present) AND `ActualPartitionsAccessed` equals the full partition count of the table AND a predicate on the partition column exists (requires actual execution plan)
- **Severity:** Warning
- **Fix:** The query has a predicate on the partition key but SQL Server scanned all partitions anyway — partition elimination failed. Common causes: (1) implicit type conversion on the partition column (matches N8/N42); (2) predicate uses a function wrapping the partition column (matches N3); (3) the partition scheme uses a computed expression that the optimizer cannot simplify at compile time. Fix the predicate to be sargable on the partition column type. After fixing, actual partitions accessed should drop to 1 or a small subset.

### N66 — Actual Rebinds Exceed Estimated Rebinds
- **Trigger:** `PhysicalOp` = Nested Loops AND `ActualRebinds` > `EstimateRebinds` × 10 AND `ActualRebinds` > 1,000 (requires actual execution plan)
- **Severity:** Warning
- **Fix:** The Nested Loops operator executed far more inner-side iterations than the optimizer estimated at compile time. `EstimateRebinds` comes from the outer side cardinality estimate; when the actual outer side is much larger, every under-estimated join drives N66. This is a complement to N16 (Busy Loop based on estimates alone) that fires on actual execution evidence. Fix: correct the cardinality error on the outer side of the join (statistics update, parameter sniffing fix), or force a Hash Match join that is less sensitive to outer cardinality: `INNER HASH JOIN`.

### N34 — Wide Index Suggestion
- **Trigger:** A `MissingIndexGroup` suggestion contains > 4 key columns OR > 5 INCLUDE columns
- **Severity:** Info
- **Fix:** Wide index suggestions are often the result of the optimizer combining multiple independent access patterns. A wide index is costly to maintain and may not be the right solution. Evaluate the suggestion critically — split into narrower targeted indexes, or address the queries individually to reduce column requirements.

---

## Output Format

Structure your report as follows. Follow every formatting rule below exactly — the reference
output in `example/sqlplan-review/horrible-analysis.md` demonstrates the expected quality level.

---

### Section: Summary

```
## Execution Plan Analysis

### Summary
- **X Critical** issues, **Y Warnings**, **Z Info** items
- Primary bottleneck: [one sentence identifying the root cause and which operators it affects]
```

---

### Section: Findings (Critical / Warnings / Info)

Each finding header **must** include the check ID that fired:

```
### [C1 — S4] Issue Name — key metric
- **Observed:** [exact values from the XML — operator name, NodeId, row counts, cost]
- **Impact:** [why this matters at runtime — concurrency, I/O, elapsed time]
- **Fix:** [concrete action with code where applicable]
```

Rules:
- The bracket suffix (`— S4`, `— N21`, etc.) is the check ID from the sections above. Always include it.
- **Table and index names in Observed lines and finding text must use schema-qualified format
  when the plan XML includes a `Schema` attribute on the `<Object>` or `<RelOp>` element.**
  Format: `[Schema].[Table]` preserving SQL Server bracket notation, or `Schema.Table` in prose.
  Example: `dbo.Orders` not `Orders`; `[dbo].[Orders].[IX_Orders_Status]` in DDL.
  When the plan XML omits the Schema attribute (estimated plans, simplified XML), bare table
  names are acceptable.
- Findings reference each other by ID where one is the root cause of another (e.g. "see W7", "caused by W4").
- **N21 pervasive cardinality collapse** (fires on > 3 operators): replace the bullet list with a table:

  ```
  | NodeId | Operator | Estimated | Actual | Ratio |
  |--------|----------|-----------|--------|-------|
  | 1      | ...      | 1         | ...    | ...×  |
  ```

#### Info section — parameter sniffing

If `<ParameterList>` shows `ParameterCompiledValue` ≠ `ParameterRuntimeValue` on any parameter,
report it as a named Info item — never bury it in a prose note:

```
### [I1] Parameter Sniffing — @ParamName compiled 'X', runtime 'Y'
- **Observed:** ParameterCompiledValue="X" vs ParameterRuntimeValue="Y"
- **Impact:** [how this explains the N21 estimate errors above]
- **Fix options:**
  ```sql
  -- Option 1: Recompile per execution
  OPTION (RECOMPILE)
  -- Option 2: Optimize for representative value
  OPTION (OPTIMIZE FOR (@Param = 'value'))
  -- Option 3: Local variable (breaks sniffing, uses average density)
  DECLARE @Local type = @Param; -- use @Local in query
  -- Option 4: Filtered statistics for the common range
  CREATE STATISTICS stat_col ON table (col) WHERE col >= 'value';
  ```
```

S25, S26, N17, N32, and N52 findings also go in the Info section.

---

### Section: Missing Indexes

```
### Missing Indexes

#### XML-Suggested Indexes

For each MissingIndexGroup in the plan XML:
- Write the full CREATE INDEX statement using the database/schema from the XML.
- If the query has a non-sargable predicate on the indexed column (leading wildcard LIKE,
  implicit conversion, wrapped function), add a blockquote warning:
  > **Warning:** This index will NOT help with [predicate] because [reason]. Fix the predicate
  > (see Wx) before creating this index.

#### Recommended Additional Indexes

After the XML suggestions, add analyst-inferred indexes that are NOT in the XML but are implied
by the findings — for example:
- A covering index to eliminate a Key Lookup (N5 finding) — include the INCLUDE columns needed
- An index on a join column to allow a Seek instead of Scan when N15 fires at scale
- Indexes on the build/probe inputs of a Hash Match when N7 fires
Use comments to explain which finding each index addresses.
```

---

### Section: Prioritized Fix Sequence

Always end the findings with a fix sequence table. Order: (a) fixes that unblock other fixes
first, (b) highest severity, (c) lowest effort. Reference the finding IDs in Resolves.

```
### Prioritized Fix Sequence

| Step | Action | Resolves |
|------|--------|----------|
| 1    | ...    | C1, W4   |
| 2    | ...    | I1, W7   |
```

---

### Section: Passed Checks

Format as a two-column table. Include every check explicitly evaluated and not triggered.
A thorough PASS table signals that the full ruleset was applied — completeness is a feature.

```
### Passed Checks

| Check | Result |
|-------|--------|
| S1 — Serial Plan | PASS — DOP=8, plan is parallel |
| S2 — Excessive Memory Grant | PASS — grant is under-sized, not over-sized (S18 fired instead) |
| ...   | ...    |
```

---

## Notes

- When actual execution stats are absent (estimated-only plan), skip checks that require actual rows/elapsed time and note this limitation.
- For checks where the threshold is ambiguous from the description, state your assumption explicitly.
- If the user provides only a partial plan (one operator), analyze what is visible and note what cannot be assessed.
- Do not invent warnings not triggered by the rules above. If nothing fires, say the plan is clean.

## Companion Skills

- **tsql-review** — Analyze the T-SQL source code of this query before capturing a plan. Catches static anti-patterns (SQL injection, non-sargable predicates, cursor usage, deprecated syntax) that are detectable without execution.
- **sqlstats-review** — Parse and analyze `SET STATISTICS IO, TIME ON` output for the same query. Provides per-table IO counts and timing that cross-reference operator behavior visible in this plan.
- **sqlplan-compare** — Diff two execution plans (baseline vs regression) to identify what changed in join strategies, memory grants, and operator topology.
- **sqlplan-index-advisor** — Consolidate and de-duplicate missing index recommendations from one or more plans into a ranked, ready-to-run `CREATE INDEX` script.
- **sqlplan-deadlock** — Analyze SQL Server deadlock XML to identify root cause (lock order, missing index, isolation level) and produce a remediation plan.
- **sqlplan-batch** — Batch-analyze a folder of `.sqlplan` files and produce a summary dashboard of top issues, most common violations, and deduplicated missing indexes across all plans.
- **query-store-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.
