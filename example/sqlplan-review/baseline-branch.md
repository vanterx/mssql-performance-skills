# Branch Analysis — improve/sqlplan-review-best-practices
# Generated: 2026-05-28 UTC
# Skill version: skills/sqlplan-review/SKILL.md @ improve/sqlplan-review-best-practices (~682 lines)
# Input: example/sqlplan-review/horrible.sqlplan

## Execution Plan Analysis

### Summary
- **3 Critical** issues, **10 Warnings**, **2 Info** items
- Primary bottleneck: Pervasive 1-row cardinality collapse driven by parameter sniffing (`@StartDate` compiled for `'1900-01-01'`, runtime `'2025-01-01'`) causes undersized memory grants, confirmed Sort and Hash spills to TempDB, and a 5-second memory grant wait — all 7 operators are underestimated by 2,000×–10,000,000×.

---

## Critical Issues

### [C1 — S4] Memory Grant Wait — 5,000 ms
- **Observed:** `GrantWaitTime="5000"` ms; `GrantedMemory=1,048,576 KB` (1 GB)
- **Impact:** The query waited 5 seconds before execution began, queuing for a memory grant slot. At high concurrency, every execution blocks the memory grant queue.
- **Fix:** Fix parameter sniffing (I1) to reduce grant size. Interim: Resource Governor pool cap.

### [C2 — N41] Confirmed Sort Spill to TempDB — SpillLevel 2, 8 Threads
- **Observed:** NodeId=5 (Sort), `SpillToTempDb SpillLevel="2"`, `SpilledThreadCount="8"`
- **Impact:** Multi-pass spill across all 8 threads; TempDB I/O saturation likely.
- **Fix:** Fix parameter sniffing (I1); add pre-ordering index.

### [C3 — N41] Confirmed Hash Aggregate Spill — SpillLevel 3
- **Observed:** NodeId=6 (Hash Aggregate), `HashSpillDetails SpillLevel="3"`
- **Impact:** 3-pass spill, compounds with C2 to drive TempDB contention.
- **Fix:** Fix parameter sniffing (I1).

---

## Warnings

### [W1 — N21] Pervasive Cardinality Collapse — 7 Operators

| NodeId | Operator | Estimated | Actual | Ratio |
|--------|----------|-----------|--------|-------|
| 1 | Hash Match (Inner Join) | 1 | 9,999,999 | 9,999,999× |
| 2 | Nested Loops (Inner Join) | 1 | 5,000,000 | 5,000,000× |
| 3 | Clustered Index Scan (Users) | 1 | 2,000,000 | 2,000,000× |
| 4 | Key Lookup (Orders) | 1 | 5,000,000 | 5,000,000× |
| 5 | Sort | 1 | 9,999,999 | 9,999,999× |
| 6 | Hash Aggregate | 1 | 9,999,999 | 9,999,999× |
| 8 | Index Scan (Orders) | 1,000 | 9,999,999 | 9,999× |

### [W2 — S18] Insufficient Memory Grant — Used 2,048 MB > Granted 1,024 MB
- **Observed:** `MaxUsedMemory=2,097,152 KB` (2,048 MB) > `GrantedMemory=1,048,576 KB` (1,024 MB)
- **Impact:** Grant was undersized at compile time due to 1-row cardinality estimates; query spilled to TempDB. This under-allocation (not over-allocation) directly causes C2 and C3.
- **Fix:** Fix root-cause cardinality errors (parameter sniffing — see I1). The grant will right-size once row estimates are accurate.

### [W3 — S3] Large Memory Grant — 1,024 MB
- **Observed:** `GrantedMemory=1,048,576 KB` (1 GB) meets the Warning threshold (≥ 1 GB).
- **Impact:** Even at 1 GB granted — and the query actually needed 2 GB — this is a large reservation competing with concurrent queries for server memory.
- **Fix:** Fix parameter sniffing (I1) to align the grant with actual data volumes.

### [W4 — N9] Leading Wildcard LIKE — Users.Email LIKE '%gmail.com'
- **Observed:** NodeId=3 (Clustered Index Scan), predicate `[Users].[Email] like '%gmail.com'`
- **Impact:** Leading wildcard prevents index seek on any index covering `Email`. The optimizer must scan the full table and apply the predicate as a residual filter. Index seek on Email is impossible until the leading wildcard is removed.
- **Fix:** Reverse the string and store `REVERSE(Email)` in a persisted computed column with an index, then query `WHERE ReversedEmail LIKE REVERSE('%gmail.com')` — i.e. `'moc.liamg%'`. Alternatively, use a full-text index if partial-string search across many domains is needed.

### [W5 — N8] Implicit Conversion on Orders.CreatedDate — CONVERT_IMPLICIT
- **Observed:** NodeId=8 (Index Scan), predicate `CONVERT_IMPLICIT(datetime,[Orders].[CreatedDate]) >= @StartDate`
- **Impact:** SQL Server is converting the stored column to match the parameter type, preventing a seek on any index covering `CreatedDate`. Every row must be converted and compared.
- **Fix:** Align the `@StartDate` parameter type to match the column's declared type. If `CreatedDate` is `date`, declare `@StartDate DATE`; if `datetime2`, use `DATETIME2`. Eliminate the mismatch at source.

### [W6 — N3] Function on Scan Predicate — CONVERT on Index Scan (NodeId=8)
- **Observed:** NodeId=8 predicate wraps `[Orders].[CreatedDate]` in `CONVERT_IMPLICIT`, making the predicate non-sargable.
- **Impact:** The index on `CreatedDate` cannot be used for a seek; a full scan is performed instead.
- **Fix:** Fix the type mismatch (see W5). Once the implicit conversion is removed, the predicate becomes sargable and allows a range seek.

### [W7 — N5] Key Lookup Explosion — 5,000,000 executions (NodeId=4)
- **Observed:** NodeId=4 (Key Lookup), `ActualRows=5,000,000`, `ActualExecutions=5,000,000`
- **Impact:** Each of the 5 million rows from the outer loop triggers a separate Key Lookup into the clustered index, producing 5 million random I/O operations. This is one of the most expensive patterns in the plan.
- **Fix:** Add a covering index on `Orders` that includes all columns referenced by this query, eliminating the need to return to the clustered index. Use the `/sqlplan-index-advisor` skill to generate the `CREATE INDEX` DDL with correct INCLUDE columns.

### [W8 — N6] Sort Spill Risk — actualRows 9,999,999 vs estimateRows 1
- **Observed:** NodeId=5 (Sort), `ActualRows=9,999,999` vs `EstimatedRows=1` — ratio 9,999,999× exceeds 10× spill-risk threshold.
- **Impact:** The Sort memory was sized for 1 row but processed ~10 million. Spill confirmed as Critical (C2); this check explains why it was structurally inevitable given the cardinality collapse.
- **Fix:** Fix parameter sniffing (I1) to produce an accurate row estimate so the Sort receives a correctly-sized memory grant.

### [W9 — N38] Operator-Level Warnings — Sort (NodeId=5), Hash Aggregate (NodeId=6)
- **Observed:** Both operators carry `<Warnings>` children in the plan XML (SpillToTempDb and HashSpillDetails respectively).
- **Impact:** These are the same spills surfaced as C2/C3 — N38 fires on the presence of any operator-level warning element.
- **Fix:** Fix parameter sniffing (I1); see C2 and C3 for spill-specific remediation.

### [W10 — N27] Parallel Thread Skew — Thread 0: 1 row, Thread 1: 9,999,999 rows
- **Observed:** NodeId=0 (Gather Streams), `Thread 0 ActualRows=1`, `Thread 1 ActualRows=9,999,999`
- **Impact:** Thread 1 carries the entire workload; Thread 0 is idle. DOP=8 but only 1 thread is doing meaningful work, delivering near-zero parallelism benefit while paying the full parallelism overhead.
- **Fix:** The skew is a symptom of the cardinality collapse and data distribution mismatch. Fix parameter sniffing (I1). If skew persists after accurate estimates, investigate statistics on the partition key and consider filtered statistics for the common runtime value range.

---

## Info Items

### [I1] Parameter Sniffing — @StartDate compiled '1900-01-01', runtime '2025-01-01'
- **Observed:** `ParameterCompiledValue="'1900-01-01'"` vs `ParameterRuntimeValue="'2025-01-01'"`
- **Impact:** The plan was compiled for a value (`1900-01-01`) that returns essentially 0 rows — the minimum sentinel date. At runtime, `2025-01-01` returns ~10 million rows from a date range that spans the entire active dataset. This single sniff explains the 1-row estimates at all 7 operators in W1, the undersized memory grant in W2, and directly causes both TempDB spills (C2, C3) and the grant wait (C1).
- **Fix options:** See `references/output-format.md` for the four-option fix template with SQL (RECOMPILE, OPTIMIZE FOR, local variable, filtered statistics).

### [I2 — S28] Large Cached Plan — 2,048 KB
- **Observed:** `CachedPlanSize="2048"` KB — meets the Info threshold (≥ 1,024 KB, below the 5,120 KB Warning threshold).
- **Impact:** The compiled plan consumes 2 MB in the plan cache. Benign at low frequency, but at high call frequency it adds to plan cache memory pressure.
- **Fix:** No immediate action required. Monitor with `sys.dm_exec_cached_plans` if plan cache pressure is observed.

---

## Missing Indexes

### XML-Suggested Indexes

```sql
-- Impact: 99.999 (highest possible) — from MissingIndexGroup in plan XML
CREATE NONCLUSTERED INDEX [IX_Users_Email]
    ON [ProdDB].[dbo].[Users] ([Email]);
```

> **Warning:** This index will NOT help with `[Email] LIKE '%gmail.com'` (W4) because the leading wildcard prevents an index seek regardless of the index. Fix the predicate first (add `REVERSE(Email)` computed column and index), or this CREATE INDEX will create an index that is never used for this query pattern.

### Recommended Additional Indexes

```sql
-- Addresses W7 (Key Lookup Explosion): covering index to eliminate 5M Key Lookups
-- Replace col1, col2, ... with actual columns referenced in SELECT/JOIN
CREATE NONCLUSTERED INDEX [IX_Orders_CreatedDate_Covering]
    ON [ProdDB].[dbo].[Orders] ([CreatedDate])
    INCLUDE (/* all columns from Orders referenced in the SELECT list */);
-- Note: also fixes W5/W6 if CreatedDate type is aligned to @StartDate type first.
```

---

## Prioritized Fix Sequence

See `references/output-format.md` for the exact table template.

| Step | Action | Resolves |
|------|--------|----------|
| 1 | Fix parameter sniffing: add `OPTION (RECOMPILE)` or `OPTION (OPTIMIZE FOR (@StartDate = '2025-01-01'))` | I1, C1, C2, C3, W1, W2, W3, W8, W10 |
| 2 | Fix type mismatch: align `@StartDate` parameter type to `Orders.CreatedDate` column type | W5, W6 |
| 3 | Add covering index on `Orders (CreatedDate) INCLUDE (...)` after fixing type mismatch | W7 |
| 4 | Fix leading wildcard: add `REVERSE(Email)` computed column + index, rewrite predicate | W4 |

---

## Passed Checks

| Check | Result |
|-------|--------|
| S1 — Serial Plan | PASS — DOP=8, plan is parallel |
| S2 — Excessive Memory Grant | PASS — grant undersized, not over-sized (S18/W2 fired instead) |
| S5 — Compile Timeout | PASS — `StatementOptmEarlyAbortReason` absent |
| S6 — Compile Memory Exceeded | PASS — `StatementOptmEarlyAbortReason` absent |
| S7 — High Compile CPU | PASS — `CompileCPU="512"` ms, below 1,000 ms warning threshold |
| S8 — Ineffective Parallelism | NOT ASSESSED — `elapsedTimeMs` / `cpuTimeMs` not present in RunTimeCountersPerThread |
| S9 — Parallel Wait Bottleneck | NOT ASSESSED — elapsed and CPU time not recorded in this plan |
| S10 — Downlevel CE | PASS — `CardinalityEstimationModelVersion="160"` (≥ 130) |
| S11 — Plan-Level Warnings | PASS — no `<Warnings>` element directly under `<QueryPlan>` (spill warnings are operator-level, caught by N41) |
| S12 — Implicit Conversion Affects Seek | PASS — no `<PlanAffectingConvert ConvertIssue="Seek Plan">` under `<QueryPlan><Warnings>` |
| S13 — Table Variable (Read) | PASS — no `@`-prefixed objectName nodes |
| S14 — Table Variable (Write) | PASS — no write operators targeting `@` objects |
| S15 — High Compile Memory | PASS — `CompileMemory` attribute not present |
| S16 — Trivial Plan | PASS — `StatementOptmLevel` not TRIVIAL (DOP=8 parallel plan) |
| S17 — Unparameterized Query | PASS — `<ParameterList>` is present |
| S19 — FORCE ORDER Hint | PASS — no `FORCE ORDER` in `StatementText` |
| S20 — RECOMPILE Hint with Expensive Compile | PASS — no `OPTION (RECOMPILE)` in `StatementText` |
| S21 — Recursive CTE | PASS — no recursive CTE pattern in `StatementText` |
| S22 — SET ROWCOUNT Active | PASS — `RowCountAssignment` attribute absent |
| S23 — Excessive Parameter Count | PASS — 1 parameter (`@StartDate`) |
| S24 — Query Store Forced Plan | PASS — `PlanGuideName` absent |
| S25 — Interleaved Execution | PASS — `ContainsInterleavedExecutionCandidates` absent |
| S26 — Batch Mode Adaptive Join | PASS — no `IsAdaptive=1` operators |
| S27 — Excessive Missing Index Suggestions | PASS — 1 MissingIndexGroup (threshold > 5) |
| S29 — Memory Request Denied | PASS — `RequestedMemory=1,048,576` = `GrantedMemory=1,048,576`, ratio 1.0 (< 1.1 threshold) |
| S30 — High Serial Required Memory | PASS — `SerialRequiredMemory="1024"` KB (1 MB), below 524,288 KB threshold |
| S31 — Non-QDS Forced Plan | PASS — `PlanGuideName` absent |
| S32 — Compile Wall-Clock vs CPU Gap | PASS — `CompileTime="512"` = `CompileCPU="512"`, no gap |
| S33 — Non-Standard SET Options | PASS — `StatementSetOptions` absent |
| N1 — Filter Late in Plan | PASS — predicates applied as scan residuals, no standalone Filter operator |
| N2 — Eager Index Spool | PASS — no Eager Spool operators |
| N4 — Expensive Scan | NOT ASSESSED — `actualRowsRead` attribute not separately recorded in XML |
| N7 — Hash Join Spill Risk | NOT ASSESSED — per-side probe/build row counts not individually specified |
| N10 — Cartesian Product | PASS — all joins have explicit predicates |
| N11 — Non-Sargable Residual Predicate | PASS — non-sargable predicates already caught as N3 (CONVERT) and N9 (LIKE) |
| N12 — Backward Index Scan | PASS — no `ScanDirection="Backward"` |
| N13 — Implicit Conversion (CE) | PASS — no `CONVERT_IMPLICIT` on join columns affecting CE (W5 covers the scan predicate) |
| N14 — Unnecessary Sort | PASS — Sort is required by plan structure; not tagged as avoidable |
| N15 — High Nested Loop Count | PASS — Key Lookup executions (5,000,000) fired N5; N15 separately covers general loops > 10,000 with high inner cost; already addressed via W7 |
| N16 — Scalar UDF in Plan | PASS — no scalar UDF operators |
| N17 — Adaptive Join | PASS — no adaptive join nodes (S26 covers) |
| N18 — Spool Operator | PASS — no Spool operators |
| N19 — RID Lookup | PASS — no heap RID Lookups |
| N20 — Table Scan (Heap) | PASS — no Table Scan operators |
| N22 — Unordered Prefetch | PASS — no unordered prefetch signals |
| N23 — Remote Query | PASS — no remote/linked-server operators |
| N24 — Clustered Index Delete/Update | PASS — read-only SELECT plan |
| N25 — Index Fragmentation Signal | NOT ASSESSED — fragmentation data not available in plan XML |
| N26 — Parallelism Repartition Streams | PASS — one Repartition Streams (NodeId=7) is expected for DOP=8; no excessive repartition |
| N28 — Bitmap Filter | PASS — no Bitmap operators |
| N29 — Missing Statistics | PASS — no missing statistics warnings |
| N30 — Outdated Statistics Signal | NOT ASSESSED — last-updated date not in plan XML |
| N31 — Window Aggregate Large Frame | PASS — no window aggregate operators |
| N32 — Interleaved Execution MSTVF | PASS — no MSTVF operators |
| N33 — Large IN List | PASS — no SeekPredicates with > 20 discrete ranges |
| N34 — Wide Index Suggestion | PASS — one missing index suggestion (Email column only; width not excessive) |
| N35 — Excessive DOP | PASS — DOP=8 within normal range |
| N36 — Missing Index High Impact | PASS — one suggestion at Impact=99.999; not > 5 groups (S27 threshold) |
| N37 — Clustered Index Scan on Large Table | PASS — scan caught at NodeId=3; absence of alternative index noted in W4 |
| N39 — Heap Scan | PASS — no Table Scan (heap) operators |
| N40 — Index Seek with Many Ranges | PASS — no multi-range seeks present |
| N42 — Forced Hash Join Hint | PASS — no `USE HASH` hints |
| N43 — Forced Loop Join Hint | PASS — no `LOOP` join hints; Nested Loops at NodeId=2 is optimizer-chosen |
| N44 — Greedy Optimizer Join Order | PASS — `StatementOptmLevel` not Greedy-triggering; plan has 3 tables, below exhaustive-enumeration threshold |
| N45 — Non-Clustered Index Scan | PASS — Index Scan at NodeId=8 already surfaced as W5/W6 |
| N46 — Excessive OutputList Width | NOT ASSESSED — `EstimatedAvgRowSize` not present; `SELECT u.*, o.*, p.*` is a wide-star pattern but attribute absent from XML |
| N47 — Wide Row | NOT ASSESSED — `EstimatedAvgRowSize` attribute absent from this plan |
| N48 — Elapsed Time Hotspot | NOT ASSESSED — `ActualElapsedms` not present in RunTimeCountersPerThread |
| N49 — Thread Starvation | PASS — Thread 0 has 1 row (not 0); skew caught by N27/W10 |
| N50 — Partition Elimination Failure | NOT ASSESSED — partition count attributes absent from this plan |
| N51 — Actual Rebind Excess | NOT ASSESSED — `ActualRebinds` / `EstimateRebinds` not present |
| N52 — Adaptive Memory Grant Feedback | PASS — no adaptive memory grant feedback indicators |
| N53–N66 — Remaining node checks | PASS or NOT ASSESSED — no triggers found in plan XML; attributes required for these checks are absent |

---
*Analyzed by: Claude Sonnet 4.6 · 2026-05-28 UTC*
