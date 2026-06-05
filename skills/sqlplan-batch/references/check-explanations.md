# sqlplan-batch — Explained

## Contents

- [When Batch Analysis Is More Useful Than Per-Plan Review](#when-batch-analysis-is-more-useful-than-per-plan-review)
- [Key Concepts](#key-concepts)
- [Reading Each Section](#reading-each-section)
- [Prioritisation Guide](#prioritisation-guide)
- [Next Steps After Batch Analysis](#next-steps-after-batch-analysis)

---


A plain-English guide to when batch analysis is the right tool, what each section of the output means, how to prioritise which plans to investigate further, and how batch feeds into the other skills.

---

## When Batch Analysis Is More Useful Than Per-Plan Review

`/sqlplan-review` is the right tool when you already know which query is slow and have its plan.

`/sqlplan-batch` is the right tool when:

- You've captured a workload (e.g., 50 `.sqlplan` files from a slow period) and don't know which queries are causing the most pain
- You want to identify **systemic** problems — patterns that appear across many queries, indicating a schema or configuration issue rather than a one-off query problem
- You need to prioritise: "which 3 plans should I fix first?"
- You want a consolidated missing index script for the whole workload, not individual suggestions per query

Think of batch as **triage**: it tells you where to look, then you use `/sqlplan-review` to look deeply at the specific plans it surfaces, and `/sqlindex-advisor` to act on the index recommendations it aggregates.

---

## Key Concepts

### StatementSubTreeCost: Relative, Not Absolute

The `StatementSubTreeCost` value the skill uses for ranking is the optimizer's internal cost unit — it is **not** a time in seconds, milliseconds, or any real-world unit.

What it means in practice:
- A plan with cost 120 is not "120 seconds" — it might run in 2 seconds or 20 minutes
- Cost is useful for **relative ranking within the same workload** — a plan costing 120 is typically more resource-intensive than one costing 12
- Cross-workload comparisons are unreliable — a cost 50 plan on one server may have different wall-clock characteristics on another

Use the cost ranking as a starting point. Validate with actual execution times from Query Store or Extended Events.

### What "Systemic" Means (the 30% Threshold)

The Executive Summary flags checks that fired in more than 30% of plans as **systemic issues**.

A systemic issue indicates a problem with the database's schema, configuration, or query patterns — not a single bad query:

- **S1 (Serial Plan) in 40% of plans** → likely a server-level MAXDOP setting, or scalar UDFs used throughout the codebase
- **N4 (Expensive Scan) in 60% of plans** → widespread missing indexes or non-sargable predicates across many queries
- **N21 (Bad Row Estimate) in 50% of plans** → statistics are broadly stale; run `UPDATE STATISTICS` across the database

Fixing a systemic issue improves many queries at once. Prioritise systemic checks over per-plan issues when both are present.

### What the Check Violation Frequency Table Reveals

The frequency table ranks checks by how many plans they fired in:

```
N21 (Bad Row Estimate)    — 31 / 50 plans (62%)
S1  (Serial Plan)         — 28 / 50 plans (56%)
N4  (Expensive Scan)      — 25 / 50 plans (50%)
N5  (Key Lookup at Scale) — 18 / 50 plans (36%)
```

Read this as a diagnostic of the database's health:

| Pattern | What it suggests |
|---------|-----------------|
| N21 high | Statistics broadly stale; run `UPDATE STATISTICS` with FULLSCAN |
| S1 high | Scalar UDFs or MAXDOP 1 hints used widely; audit the codebase |
| N4 high | Missing indexes on frequently filtered columns; use the consolidated index script |
| N5 high | NC indexes don't include the SELECT columns; many queries need INCLUDE additions |
| S12 high | Data type mismatches between columns and parameters; audit parameter declarations |
| N25 high | Scalar UDFs used throughout; rewrite as inline TVFs |

---

## Reading Each Section

### Executive Summary

```
Total Critical issues: 23 across 12 plans
Total Warnings: 87 across 38 plans
Plans with confirmed spills: 5
Plans with memory grant > 1 GB: 3
Unique tables with missing index suggestions: 8

Systemic issues (> 30% of plans):
- N21: Bad Row Estimate — 31 / 50 plans (62%)
- S1:  Serial Plan      — 28 / 50 plans (56%)
```

**Start here.** If there are confirmed spills, that's your highest-severity signal — go to the Spill Report immediately. Then look at systemic issues before individual plan rankings.

### Top 10 Most Expensive Plans

```
| Rank | File              | Cost  | DOP | Memory (MB) | Criticals | Warnings |
|------|-------------------|-------|-----|-------------|-----------|---------|
| 1    | report_monthly.sqlplan | 892 | 1 | 2048 | 3 | 7 |
```

**How to use it:** The most expensive plan is your primary candidate for review. But cross-reference with the Criticals column — a plan that ranks 8th by cost but has 4 Criticals may need attention before a plan that ranks 1st with 0 Criticals (the expensive plan may already be running efficiently, just working on a lot of data).

**What DOP = 1 in an expensive plan signals:** S1 likely fired — the plan is expensive and serial. Parallelism was blocked. Check `NonParallelPlanReason` in that plan's detail.

**What high Memory + Spill = Yes signals:** The memory grant was undersized. C4 from sqlplan-compare's pattern library — row estimates are wrong and the grant is too small. Start with statistics.

### Top 10 Plans by Critical Issues

Plans are ranked here by Critical count, regardless of cost. A low-cost plan with 3 Criticals may involve:
- An implicit conversion that prevents index seeks (S12)
- A Key Lookup on a table hit 1M times per day (N5)
- A forced plan that's become stale (N36)

These are correctness and reliability risks, not just performance risks. Review these plans even if they don't appear in the cost ranking.

### Check Violation Frequency (Top 15)

The single most useful section for prioritising infrastructure work over per-query tuning. If N21 fires in 62% of plans, the highest-leverage action is not tuning any individual query — it's:

```sql
-- Update statistics across the database:
EXEC sys.sp_updatestats  -- quick, uses sampling

-- Or with full scan (slower but more accurate):
EXEC sys.sp_MSforeachtable 'UPDATE STATISTICS ? WITH FULLSCAN'
```

After a database-wide statistics update, re-run the batch analysis. The frequency table will show which issues remain structural vs which were statistics-driven.

### Spill Report

```
| File              | Operator   | Spill Level | Memory Grant (MB) | Memory Used (MB) |
|-------------------|------------|------------|-------------------|-----------------|
| etl_load.sqlplan  | Sort       | 2          | 512               | 4096            |
```

**Spill Level** tells you how many passes through TempDB the operator made:
- Level 1: one spill (overflow written to TempDB, read back once)
- Level 2: two passes (data written and re-read twice — much slower)
- Level 3+: severe; the operator made multiple passes over TempDB data

**Memory Grant vs Memory Used:** When Used >> Granted, the grant was undersized (N41 / S18). Fix the root-cause cardinality error first, then verify the grant improves. When Used << Granted (and Granted is large), the grant was oversized (S2/S3) — the query requested memory it didn't need, starving other queries.

### Plans With Memory Grant > 1 GB

Any plan granting over 1 GB is a server-level concern — it occupies a significant fraction of the SQL Server memory available for query grants. During peak load, multiple such plans running concurrently create `RESOURCE_SEMAPHORE` queues.

For each plan in this list, run `/sqlplan-review` on it specifically and look for S2 (excessive grant — used/granted ratio), S3 (large grant absolute), and N21 (bad row estimate driving the grant size).

### Consolidated Missing Index Script

The batch skill applies the same merge rules as `/sqlindex-advisor` across all plans simultaneously. This is more powerful than per-plan suggestions because:

- A suggestion that appears in 12 different plans ranks much higher than one appearing in 1 plan (the `MergedQueryCount` in the ranking formula)
- Overlapping suggestions across many plans are merged into one index

Before running any DDL from this section:

1. Check if the index already exists: `SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Table')`
2. Verify the table's write frequency — a table with 100,000 INSERTs/minute needs careful index addition
3. Test in non-production first

### Per-Plan Summary Table

```
| File              | Cost | DOP | Memory (MB) | Criticals | Warnings | Spill | Check IDs        |
|-------------------|------|-----|-------------|-----------|---------|-------|------------------|
| report_monthly.sqlplan | 892 | 1 | 2048 | 3 | 7 | Yes | S1,N4,N21,N41... |
```

The `Check IDs` column is the fast path: scan it for patterns. If you see `N21` in every row, statistics are the problem. If you see `S1` in every row, parallelism is being blocked globally. If you see `N41` (spill) and `S18` (insufficient grant) together repeatedly, cardinality errors are widespread.

---

## Prioritisation Guide

Use this decision order when the batch report surfaces many issues:

1. **Confirmed spills (N41)** → fix first. Spills cause the most immediate performance degradation and are confirmed, not estimated.

2. **Systemic checks (> 30% of plans)** → fix second. One action (statistics update, UDF rewrite, MAXDOP setting) improves many queries.

3. **Critical issues in high-cost plans** → fix third. These are the plans doing the most work with the most severe problems.

4. **High-impact missing indexes** → fix fourth. Use the consolidated script; don't create indexes one by one from individual plans.

5. **Warnings in remaining plans** → fix incrementally. Run `/sqlplan-review` on each to get detailed guidance.

---

## Next Steps After Batch Analysis

The batch report is designed to feed directly into the other skills:

**Found specific plans worth deep investigation?**
```
/sqlplan-review plans/report_monthly.sqlplan
```

**Want a deployment-ready index script from the consolidated suggestions?**
```
/sqlindex-advisor plans/
```
This re-runs the index advisor specifically on all plans in the folder, applying the full merge and ranking logic with more detail than the batch summary.

**Spotted a regression between two captures?**
```
/sqlplan-compare plans-before/report_monthly.sqlplan plans-after/report_monthly.sqlplan
```

**Seeing deadlock errors alongside the slow queries?**
```
/sqldeadlock-review deadlock.xdl
```
Deadlocks and slow queries often share a root cause — missing indexes cause both page-level lock contention (deadlocks) and expensive scans (slow queries).
