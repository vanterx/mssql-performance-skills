# SQL Server Performance Review — Unified Report

## Summary

- Files analyzed: 4 (`slow-proc.sql`, `slow-proc.sqlplan`, `stats-iotime.txt`, `wait-stats.txt`)
- Skills applied: 5 (tsql-review, sqlstats-review, sqlwait-review, sqlplan-review, sqlplan-index-advisor)
- Hypotheses considered: 2 (primary + 1 adversarial alternative)
- Findings: 2 Critical, 3 Warning, 2 Info
- Primary bottleneck: Parameter sniffing on `dbo.usp_GetOrdersByCustomer` — single cached plan scans 1.84M rows regardless of parameter cardinality
- Highest-priority fix: Add covering index on `Orders(CustomerId, OrderDate) INCLUDE (Status, TotalAmount)` — confirmed by sqlplan-review N5 (Key Lookup avoidance), advisor Impact 93.2, sqlstats-review I1 (1.84M logical reads), wait stats SOS_SCHEDULER_YIELD dominant
- Early termination: No — full dispatch ran (only 5 applicable skills given the artifact set)

## Hypothesis Trace

| Rank | Hypothesis | Initial confidence | Probes run | Final confidence | Status |
|------|-----------|-------------------|------------|------------------|--------|
| 1 | Parameter sniffing on usp_GetOrdersByCustomer | MEDIUM | sqlstats-review, sqlplan-review, sqlwait-review | HIGH | Confirmed (3 skills agree) |
| 2 | Server-wide I/O bottleneck | LOW | sqlwait-review | LOW | Refuted (PAGEIOLATCH_SH only 14.7% of waits) |

## Adversarial Check

- Primary hypothesis: Parameter sniffing
- Disproof attempt: "If parameter sniffing was the root cause, wait profile should be CPU-dominant (SOS_SCHEDULER_YIELD prominent). If PAGEIOLATCH_SH > 25% of wait time instead, the bottleneck is I/O — reconsider whether sniffing matters here."
- Result: `no_contradiction` — SOS_SCHEDULER_YIELD is 41.3% of total wait time, signal wait ratio 6.1%, PAGEIOLATCH_SH only 14.7% (below 25% I/O-bound threshold). CPU-dominant profile is consistent with sniffing.
- Alternative considered (server-wide I/O): refuted. PAGEIOLATCH_SH share too low; reads concentrated on a single query.

## Findings

### Critical

[C1] Parameter sniffing on `dbo.usp_GetOrdersByCustomer`
- Confidence: HIGH (primary skill: sqlplan-review)
- Evidence:
  - sqlplan-review S9 fired
    - Source: `slow-proc.sqlplan` (Stmt 1, NodeId 1)
    - Observed: cached plan compiled with `@CustomerId = N'CUST-00001'` (high-cardinality customer); runtime parameter `N'CUST-99999'` (single matching row) re-uses the same plan with `ActualRows = 1,842,734`
    - Threshold: cached vs runtime parameter divergence + ActualRows >> EstimateRows = parameter sniffing (Critical)
  - sqlstats-review I1 corroborates
    - Source: `stats-iotime.txt` (Statement 1, Table `Orders`)
    - Observed: 1,842,734 logical reads on Orders for both invocations (high-cardinality AND single-row)
    - Threshold: > 1,000,000 logical reads = Critical
  - sqlwait-review V-class signal corroborates
    - Source: `wait-stats.txt`
    - Observed: SOS_SCHEDULER_YIELD = 41.3% of wait time; signal wait ratio 6.1%; CPU-dominant execution
    - Threshold: CPU-dominant + sniffing signal in stats = corroborating wait profile
- Impact: Low-cardinality calls (single-row lookup by CustomerId) execute in 7.1s instead of < 100ms because they re-use a plan optimised for high-cardinality. Affects p99 latency on the orders API; users report timeouts during peak.

[C2] Missing covering index on `Orders(CustomerId, OrderDate) INCLUDE (Status, TotalAmount)`
- Confidence: HIGH (primary skill: sqlplan-index-advisor)
- Evidence:
  - sqlplan-review N5 fired
    - Source: `slow-proc.sqlplan` (Stmt 1, NodeId 1)
    - Observed: Clustered Index Scan on PK_Orders reading 1.84M rows; no useful seekable index for the `CustomerId = ? AND OrderDate >= ?` predicate
    - Threshold: predicate selectivity < 5% with no supporting index = Critical scan
  - sqlplan-index-advisor (optimizer suggestion) corroborates
    - Source: `slow-proc.sqlplan` (MissingIndexGroup)
    - Observed: optimizer Impact 93.2 on EQUALITY(CustomerId), INEQUALITY(OrderDate), INCLUDE(Status, TotalAmount)
    - Threshold: Impact >= 75 = Warning; Impact >= 90 = Critical
  - sqlstats-review I1 corroborates (same evidence as C1 above)
- Impact: Every execution scans the entire Orders clustered index because no seek path exists. The new index makes both the high-cardinality and the single-row call return in milliseconds, and is the structural fix that makes [C1] (parameter sniffing) much less damaging — even with the wrong plan, the operator becomes an Index Seek, not a 1.84M-row scan.

### Warning

[W1] `SELECT *` in `usp_GetOrdersByCustomer` (tsql-review T7)
- Confidence: MEDIUM
- Evidence:
  - tsql-review T7 fired
    - Source: `slow-proc.sql` (line 14)
    - Observed: `SELECT *` returns all columns including potentially-large columns
    - Threshold: `SELECT *` in production procedure = Warning
- Impact: Forces the optimizer to read every column, preventing covering-index strategies and increasing network payload.

[W2] CXPACKET dominant secondary wait (sqlwait-review V3)
- Confidence: MEDIUM
- Evidence:
  - sqlwait-review V3 fired
    - Source: `wait-stats.txt`
    - Observed: CXPACKET = 38.5% of total wait time
    - Threshold: > 25% = Warning
- Impact: Parallel plans for the 1.84M-row scan are spending substantial time in parallelism coordination, not productive work. The index in [C2] will reduce row count and likely eliminate parallel plans for this query.

[W3] Memory grant over-allocation (sqlplan-review S2)
- Confidence: MEDIUM
- Evidence:
  - sqlplan-review S2 fired
    - Source: `slow-proc.sqlplan` (Stmt 1)
    - Observed: GrantedMemory = 4096 KB; MaxUsedMemory = 3072 KB; over-allocation 33%
    - Threshold: over-allocation > 25% = Warning
- Impact: 1 MB of memory grant wasted per execution. Compounds at high concurrency.

### Info

[I1] Procedure parameter `@StartDate` defaulted in body (tsql-review T9)
- Confidence: HIGH
- Evidence:
  - tsql-review T9 fired
    - Source: `slow-proc.sql` (lines 8-10)
    - Observed: `IF @StartDate IS NULL SET @StartDate = DATEADD(DAY, -30, GETDATE())`
    - Threshold: parameter mutation in body = Info (sniffing-amplifier)
- Impact: The mutated parameter is what the optimizer uses for cardinality estimation; this can hide the sniffing problem during testing if the default branch is taken with a value the test data does not represent.

[I2] DELETED_FLAG predicate could benefit from filtered index
- Confidence: MEDIUM
- Evidence:
  - sqlplan-review N6 fired (residual predicate noted, not flagged)
    - Source: `slow-proc.sqlplan` (Stmt 1, NodeId 1)
    - Observed: `DELETED_FLAG = 0` evaluated as residual after scan
    - Threshold: residual predicate on a low-selectivity column = Info
- Impact: If most rows have `DELETED_FLAG = 0`, a filtered index `WHERE DELETED_FLAG = 0` on Orders(CustomerId, OrderDate) is marginally cheaper than the covering index in [C2]. Not worth pursuing unless storage matters.

## Per-Skill Section (raw outputs, for drill-down)

### tsql-review
- T7 SELECT * — line 14
- T9 Parameter mutation in body — lines 8-10
- T2 Passed — UPDATE/DELETE without WHERE: not applicable (no DML)
- T20 Passed — `= NULL` comparison: not present
- ... (full passthrough omitted in this example)

### sqlwait-review
- Dominant: SOS_SCHEDULER_YIELD 41.3%, CXPACKET 38.5%, PAGEIOLATCH_SH 14.7%, WRITELOG 3.4%, LCK_M_S 1.5%, RESOURCE_SEMAPHORE 0.7%
- Signal wait ratio: 6.1% (CPU not saturated on the signal queue)
- V1 PAGEIOLATCH_SH share — Info (below 25% threshold)
- V3 CXPACKET share — Warning (above 25%)
- V10 Signal wait ratio — Passed (< 15%)

### sqlstats-review
- Statement 1: 1,842,734 logical reads on Orders, 4 on Customers, 4297 ms CPU, 8221 ms elapsed
- I1 Large logical reads — Critical (1.84M > 1M threshold)
- W1 Low CPU-to-elapsed ratio — Info (52% ratio, suggests some waiting but not severe)

### sqlplan-review
- Statement 1 (NodeId 0 Sort, NodeId 1 Clustered Index Scan):
  - S9 Parameter sniffing signal — Critical (compiled @CustomerId = CUST-00001, runtime @CustomerId = CUST-99999, same 1.84M rows)
  - S2 Memory grant over-allocation — Warning
  - N5 Predicate without supporting index — Critical (CustomerId, OrderDate not indexed)
  - N6 Residual predicate (DELETED_FLAG) — Info
  - S1 Passed — plan is parallel
  - N4 Passed — Clustered Index Scan is on the access path, just over-broad

### sqlplan-index-advisor
- Recommendation: `CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_OrderDate ON [OrdersDB].[dbo].[Orders] ([CustomerId], [OrderDate]) INCLUDE ([Status], [TotalAmount]) WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);`
- Source: optimizer suggestion (Impact 93.2) + operator-derived (N5 elimination)

## Cross-Cutting Findings

| Finding | Source skills | Evidence link | Impact |
|---------|---------------|---------------|--------|
| Parameter sniffing + missing index together | sqlplan-review + sqlstats-review + sqlwait-review + sqlplan-index-advisor | C1, C2 | The index fix [C2] structurally reduces the damage from sniffing [C1] — even with the wrong plan, the operator becomes a Seek not a Scan |
| CXPACKET share will drop after index | sqlwait-review + sqlplan-review | W2, C2 | The 1.84M-row scan currently goes parallel; the seek-based plan after [C2] will be serial, removing CXPACKET coordination overhead |

## Recommendation Conflicts

None detected.

## Consolidated Fix Priority

| Rank | Action | Effort | Window | Risk | Side effects | Rollback | Verification | Confidence | Resolves |
|------|--------|--------|--------|------|--------------|----------|--------------|------------|----------|
| 1 | `CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_OrderDate ON OrdersDB.dbo.Orders (CustomerId, OrderDate) INCLUDE (Status, TotalAmount) WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);` | 5 min (online build) | Anytime — ONLINE = ON, no blocking | Low | +1.2 GB storage (estimate from 48M Orders rows x ~28 bytes); ~3% write overhead on inserts/updates of CustomerId/OrderDate/Status/TotalAmount | `DROP INDEX IX_Orders_CustomerId_OrderDate ON OrdersDB.dbo.Orders;` (Low rollback risk if no plans have recompiled to use it; Medium if plans now depend on it) | Re-run `skills/sqlplan-review/scripts/01_capture_from_cache.sql` 24h later; expect Clustered Index Scan replaced by Index Seek; statement cost < 5 (was 124.3); sqlstats logical reads on Orders < 1,000 (was 1,842,734) | HIGH | C1, C2, W2 |
| 2 | Add `OPTION (OPTIMIZE FOR (@CustomerId UNKNOWN))` to the `SELECT` statement in `usp_GetOrdersByCustomer` | 5 min code change | Anytime (procedure alter, brief plan invalidation) | Low | Forces optimizer to use the histogram-average density estimate instead of the first-compile parameter's specific cardinality. Slightly worse for the average call but consistent across all parameter values. | Remove the hint; `sp_recompile dbo.usp_GetOrdersByCustomer` | Re-run sqlstats-review on five invocations spanning high- and low-cardinality customers; expect duration variance < 30% (was ~80% from sniffing) | HIGH | C1 |
| 3 | Replace `SELECT *` with explicit column list (Order columns actually consumed by the calling app) | 15 min code review + deploy | Standard deploy window | Low | Smaller network payload; enables covering-index strategy | Revert procedure body | sqlplan-review on the next captured plan should show the same operator topology with smaller `EstimateRowSize` | MEDIUM | W1 |
| 4 | Add filtered index `WHERE DELETED_FLAG = 0` instead of including it in the covering index from rank 1 | 5 min (online build) — only if rank 1 not chosen | Anytime | Low | Smaller index footprint; less write overhead | DROP INDEX | sqlplan-review should show filtered index seek; residual predicate removed | LOW | I2 |

## Missing Artifacts

- [ ] Query Store output for `query_hash` of `usp_GetOrdersByCustomer` — would confirm plan instability over time and back the sniffing diagnosis with cross-period evidence (capture: `skills/query-store-review/scripts/01_capture_queries.sql`)
- [ ] Procstats snapshot showing usp_GetOrdersByCustomer execution counts and CPU share — would confirm the procedure is in the top consumers (capture: `skills/procstats-review/scripts/collection/04_report_queries.sql`)
- [ ] Trace excerpt covering the slow window — would catch any other procedure on the same hot path (capture: `skills/sqltrace-review/scripts/01_create_xe_session.sql`)

## Passed Checks

### tsql-review
- T1 PASS, T2 PASS (no UPDATE/DELETE without WHERE), T5 PASS (no implicit conversion), T8 PASS (no scalar UDF), ... (full list elided here)

### sqlplan-review
- S1 Parallel plan, S6 PASS, S15 PASS, S24 PASS, ... (full list elided)
- N1 PASS, N2 PASS, N4 PASS (scan is on the access path, just unfortunate), N12 PASS, N18 PASS, ...

### sqlstats-review
- I3 PASS (no intentional full-table scan), I4 PASS, I9 PASS, ...
- W1 PASS, W3 PASS, ...

### sqlwait-review
- V1 PAGEIOLATCH_SH PASS (below 25% threshold)
- V10 Signal wait ratio PASS (< 15%)
- V13 Poison waits PASS (no THREADPOOL/RESOURCE_SEMAPHORE_QUERY_COMPILE pressure)
- ... (full list elided)

### sqlplan-index-advisor
- D1 PASS, D6 PASS, D8 PASS (consolidation rules applied without conflict)

## Skills Skipped

| Skill | Reason |
|-------|--------|
| sqlplan-compare | Only one plan provided (no regression pair) |
| sqlplan-deadlock | No deadlock XML in input |
| sqlplan-batch | Only one plan provided (use sqlplan-review directly) |
| query-store-review | No Query Store DMV output in input (listed in Missing Artifacts) |
| procstats-review | No `sys.dm_exec_procedure_stats` output in input (listed in Missing Artifacts) |
| sqltrace-review | No trace data in input (listed in Missing Artifacts) |
| hadr-health-review | No AG DMV output in input; no AG context in the symptom |
| clusterlog-review | No CLUSTER.LOG in input |
| errorlog-review | No ERRORLOG excerpt in input |
| spn-review | No Kerberos / login signals in any artifact |

---
*Analyzed by: Claude Sonnet 4.6 · 2026-05-17 09:42 NZST*
