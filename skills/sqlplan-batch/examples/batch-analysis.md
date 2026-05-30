# Batch Plan Analysis

> **Input:** `skills/sqlplan-batch/examples/plans/` + `skills/sqlplan-review/examples/horrible.sqlplan` — 3 plans
> Run with: `/sqlplan-batch skills/sqlplan-batch/examples/plans/ skills/sqlplan-review/examples/horrible.sqlplan`
>
> Plans: `plans/order_report.sqlplan`, `plans/customer_lookup.sqlplan`, `skills/sqlplan-review/examples/horrible.sqlplan`

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Plans analyzed | 3 |
| Total Critical issues | 7 |
| Total Warnings | 17 |
| Plans with confirmed spills | 2 (`horrible.sqlplan`, `order_report.sqlplan`) |
| Plans with memory grant ≥ 512 MB | 2 (`horrible.sqlplan` 1,024 MB, `order_report.sqlplan` 512 MB) |
| Distinct tables with missing index suggestions | 2 (`dbo.OrderLines`, `dbo.Users`) |

**Primary finding:** `horrible.sqlplan` and `order_report.sqlplan` account for all Critical findings and all spills. `customer_lookup.sqlplan` is clean. Fix `horrible.sqlplan` first (highest cost, most violations); then address the Sort spill in `order_report.sqlplan`.

---

## Top Plans by Statement Cost

| Rank | File | Statement Cost | DOP | Critical | Warnings |
|------|------|---------------|-----|----------|---------|
| 1 | `horrible.sqlplan` | 98,765 | 8 | 3 | 10 |
| 2 | `order_report.sqlplan` | 4,821 | 4 | 4 | 6 |
| 3 | `customer_lookup.sqlplan` | 0.003 | 1 | 0 | 1 |

---

## Top Plans by Critical Issues

| Rank | File | Critical | Highest-Severity Finding |
|------|------|---------|------------------------|
| 1 | `order_report.sqlplan` | 4 | N41: Confirmed Sort Spill Level 1 (4 threads), S3: 512 MB grant |
| 2 | `horrible.sqlplan` | 3 | N41: Sort Spill Level 2 + Hash Spill Level 3, S3: 1,024 MB grant |
| 3 | `customer_lookup.sqlplan` | 0 | — |

---

## Check Violation Frequency (All Plans)

| Check | Description | Plans Fired | Occurrences |
|-------|-------------|------------|-------------|
| N21 | Bad Row Estimate (> 100×) | 2 | 5 |
| N41 | Confirmed Spill to TempDb | 2 | 3 |
| N4 | Expensive Scan (≥ 25% plan cost) | 2 | 5 |
| S3 | Large Memory Grant (≥ 512 MB) | 2 | 2 |
| N5 | Key Lookup | 1 | 1 |
| S12 | Implicit Conversion — Affects Seek | 1 | 2 |
| S9 | Parameter Sniffing Signal | 1 | 1 |
| S2 | Excessive Memory Grant (used < 10% of grant) | 1 | 1 |
| S4 | Memory Grant Wait (≥ 5,000 ms) | 1 | 1 |
| N12 | Non-Sargable LIKE Predicate | 1 | 1 |

---

## Spill Report

| File | Operator | Spill Level | Threads Spilled | Est. Rows | Actual Rows | Note |
|------|---------|------------|----------------|-----------|-------------|------|
| `order_report.sqlplan` | Sort (Node 1) | 1 | 4 | 100 | 842,100 | 8,421× cardinality error |
| `horrible.sqlplan` | Sort (Node 5) | 2 | 8 | 1 | 9,999,999 | Stale stats + implicit conversion |
| `horrible.sqlplan` | Hash Match Aggregate (Node 6) | 3 | — | 1 | 9,999,999 | Cascades from Sort spill |

---

## Memory Grant Summary

| File | Granted MB | Max Used MB | Efficiency | Wait ms |
|------|-----------|-------------|------------|---------|
| `horrible.sqlplan` | 1,024 | 2,048 | 200% overused (grant too small for actual rows) | 5,000 |
| `order_report.sqlplan` | 512 | 512 | 100% used (grant matches actual; Sort still spills at DOP 4) | 0 |
| `customer_lookup.sqlplan` | 0 | 0 | N/A — no sort/hash | 0 |

---

## Cardinality Accuracy Report

| File | Node | Operator | Est. Rows | Actual Rows | Error Factor |
|------|------|---------|-----------|-------------|-------------|
| `horrible.sqlplan` | Sort (5) | Sort | 1 | 9,999,999 | **9,999,999×** |
| `order_report.sqlplan` | Parallelism (0) | Gather Streams | 100 | 842,100 | **8,421×** |
| `order_report.sqlplan` | Sort (1) | Sort | 100 | 842,100 | **8,421×** |
| `order_report.sqlplan` | Hash Aggregate (2) | Aggregate | 100 | 842,100 | **8,421×** |
| `order_report.sqlplan` | Hash Join (3) | Inner Join | 100 | 4,820,000 | **48,200×** |
| `customer_lookup.sqlplan` | Seek (0) | Clustered Index Seek | 1 | 1 | ✓ Accurate |

---

## Consolidated Missing Index Script

```sql
-- ================================================================
-- Consolidated Missing Index Recommendations
-- Sources: horrible.sqlplan (Users.Email Impact 99.999),
--          order_report.sqlplan (OrderLines.OrderId Impact 82.1)
-- Ranked by: Impact × ln(1 + SourceCount)
-- ================================================================

-- [I1] dbo.OrderLines — Score: 56.9 [optimizer: order_report.sqlplan]
-- Eliminates full Clustered Index Scan; 4.82M rows scanned per execution
CREATE NONCLUSTERED INDEX [IX_OrderLines_OrderId]
ON [dbo].[OrderLines] ([OrderId])
INCLUDE ([LineTotal])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);

-- [I2] dbo.Users — Score: 45.0 [optimizer: horrible.sqlplan, Impact 99.999 — PARTIAL]
-- WARNING: Standard NC index will NOT help LIKE '%gmail.com' (leading wildcard).
-- Use a computed persisted column for exact domain matching instead:
ALTER TABLE [dbo].[Users]
    ADD [EmailDomain] AS REVERSE(LEFT(REVERSE([Email]),
        CHARINDEX('@', REVERSE([Email])) - 1)) PERSISTED;

CREATE NONCLUSTERED INDEX [IX_Users_EmailDomain]
ON [dbo].[Users] ([EmailDomain])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
-- Rewrite query: WHERE Email LIKE '%gmail.com'
--            →  WHERE EmailDomain = 'gmail.com'

-- ================================================================
-- Additional recommended actions (not index DDL):
-- ================================================================
-- horrible.sqlplan:
--   Fix implicit conversion on Orders.CreatedDate (@StartDate type mismatch)
--   — see horrible-analysis.md S12. Fixes the 9.9M row estimate error that
--   causes Sort Level 2 and Hash Level 3 spills.
--
-- order_report.sqlplan:
--   UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
--   UPDATE STATISTICS dbo.Customers WITH FULLSCAN;
--   UPDATE STATISTICS dbo.OrderLines WITH FULLSCAN;
--   — Estimated 100 rows for all nodes; actual rows 842K-4.8M.
--   Stale stats is causing the Sort spill (wrong memory grant sizing).
```

---

## Per-Plan Summary Table

| File | Cost | DOP | Critical | Warn | Info | Spills | Grant MB | Missing Indexes |
|------|------|-----|---------|------|------|--------|---------|----------------|
| `horrible.sqlplan` | 98,765 | 8 | 3 | 10 | 1 | 2 (L2+L3) | 1,024 | 1 (Users.Email) |
| `order_report.sqlplan` | 4,821 | 4 | 4 | 6 | 1 | 1 (L1, 4 threads) | 512 | 1 (OrderLines.OrderId) |
| `customer_lookup.sqlplan` | 0.003 | 1 | 0 | 1 | 1 | 0 | 0 | 0 |
| **Total** | | | **7** | **17** | **3** | **3** | | **2** |

---

## Per-Plan Findings Summary

### `horrible.sqlplan`

| ID | Severity | Finding |
|----|----------|---------|
| S3 | Critical | Memory grant 1,024 MB — over-budget |
| S4 | Critical | Memory grant wait 5,000 ms before query starts |
| N41 | Critical | Sort spill Level 2 + Hash spill Level 3 |
| S12 | Warning | Implicit conversion on `Orders.CreatedDate` — prevents seek, destroys estimates |
| S9 | Warning | Parameter sniffing: compiled rows 1, runtime rows 9.9M |
| N5 | Warning | Key Lookup on `Orders.PK_Orders` — 5,000,000 executions |
| N21 | Warning | Row estimate 1 vs actual 9,999,999 (N21 × 6 nodes) |

Full analysis: `/sqlplan-review skills/sqlplan-review/examples/horrible.sqlplan`

### `order_report.sqlplan`

| ID | Severity | Finding |
|----|----------|---------|
| N41 | Critical | Sort spill Level 1 — 4 threads spilled to TempDb |
| N21 | Critical | Estimate 100 vs actual 842,100 (8,421× error — root of spill) |
| N4 | Critical | 3 Clustered Index Scans (Orders 842K, Customers 50K, OrderLines 4.82M) |
| S3 | Critical | Memory grant 512 MB — fully consumed; spill occurs at DOP 4 because per-thread grant is 512/4 = 128 MB |
| N4 | Warning | OrderLines scan (4.82M rows) — missing index on OrderId (Impact 82.1) |

Root cause: Statistics are stale — all nodes estimate 100 rows. Update statistics and add `IX_OrderLines_OrderId` to eliminate the full scan.

### `customer_lookup.sqlplan`

| ID | Severity | Finding |
|----|----------|---------|
| — | Info | Clustered Index Seek on `Customers.PK_Customers` — single-row point lookup, cost 0.003, DOP 1. Clean plan. |

---

## Recommended Next Steps

1. **`horrible.sqlplan`** — Fix implicit conversion first (restores cardinality estimates → eliminates spills); then run `/sqlplan-index-advisor skills/sqlplan-review/examples/horrible.sqlplan` for DDL. Full check: `/sqlplan-review skills/sqlplan-review/examples/horrible.sqlplan`.
2. **`order_report.sqlplan`** — Update statistics on Orders, Customers, OrderLines immediately. Deploy `IX_OrderLines_OrderId`. Recapture actual plan (this plan has estimated-rows-only at runtime context — confirm with `Ctrl+M` in SSMS).
3. **Index deployment** — Run consolidated script above in a maintenance window. Validate with `/sqlplan-compare` against pre-index baseline.
4. **`customer_lookup.sqlplan`** — No action needed; 1 info-level note only.
