---
name: sqlplan-index-advisor
description: Analyze SQL Server execution plans to produce a ranked CREATE INDEX script. Derives index recommendations from operator patterns (Key Lookups, scans, sorts, spools, nested loops — D1–D8) and the optimizer's explicit MissingIndexGroup suggestions. Use this skill whenever a user wants index recommendations from an execution plan; asks what indexes would help a query; mentions Key Lookup, index scan, missing index, or covering index; or asks to generate CREATE INDEX statements. Trigger after sqlplan-review findings or directly on any .sqlplan file.
triggers:
  - /sqlplan-index-advisor
  - /index-advisor
  - /missing-indexes
---

# SQL Server Index Advisor Skill

## Purpose

Produce a prioritized, ready-to-run `CREATE INDEX` script from two independent sources:

1. **Operator-derived recommendations** — index opportunities inferred directly from plan operator patterns (Key Lookups, expensive scans, Sort operators, Eager Index Spools, high-count Nested Loops, residual predicates, heap scans, backward scans)
2. **Optimizer suggestions** — the explicit `<MissingIndexGroup>` elements SQL Server emits, consolidated and de-duplicated

Both sources feed into a single unified merge and ranking pipeline. The final output contains one CREATE INDEX statement per table group — not one per source.

## Input

Accept any of:
- One or more `.sqlplan` file paths
- Raw `.sqlplan` XML pasted inline
- A description of plan operators if XML is not available

## How to Run

1. **Source A — Operator scan:** Walk every `<RelOp>` node and apply the derived rules (D1–D8) below
2. **Source B — Explicit extraction:** Extract all `<MissingIndexGroup>` elements
3. **Unified merge:** Combine A and B by table, apply merge rules, deduplicate
4. **Rank** the merged set by score
5. **Generate DDL** with width checks applied

---

## Source A: Operator-Derived Recommendations

Apply these rules to every operator node. Each fired rule produces a candidate recommendation with an estimated impact derived from the operator's `costPercent` or `actualExecutions`.
### D1 — Key Lookup / RID Lookup: Extend NC Index

**When:** `physicalOp` = Key Lookup or RID Lookup

**What to extract from the plan:**
- The nonclustered index being seeked (from the parent Nested Loops' seek predicate)
- The seek predicate columns → these become the key columns of the existing NC index
- The output list columns being fetched via the lookup → these become new INCLUDE candidates

**Recommendation:** Extend the seeked NC index with the lookup's output columns as INCLUDE columns. This eliminates the lookup entirely.

```xml
<!-- Key Lookup fetches Status and TotalAmount after seeking IX_Orders_CustomerId -->
<!-- Recommendation: ALTER INDEX or DROP/CREATE -->
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId]
ON [dbo].[Orders] ([CustomerId])
INCLUDE ([Status], [TotalAmount])   -- add these to kill the lookup
WITH (ONLINE = ON, DROP_EXISTING = ON);
```

**Estimated impact:** `min(90, costPercent × 2)` — Key Lookups at scale are high-value targets.

**Cross-reference:** sqlplan-review N5

---
### D2 — Expensive Scan: Add Seek Index

**When:** `physicalOp` = Index Scan or Table Scan AND `costPercent` ≥ 25% AND a predicate is present on the operator

**What to extract:**
- Table and schema name
- Predicate columns: equality columns first, then range/inequality columns
- Output columns that are always fetched (candidates for INCLUDE)

**Recommendation:** NC index on the predicate columns. Add frequently fetched output columns as INCLUDE only if they meaningfully narrow the query's I/O (avoid including every SELECT column).

```xml
<!-- Scan on dbo.Orders with predicate: CustomerId = @p AND CreatedDate > @d -->
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_CreatedDate]
ON [dbo].[Orders] ([CustomerId], [CreatedDate]);
```

**Estimated impact:** `costPercent` directly — the operator's plan share is the impact.

**Cross-reference:** sqlplan-review N4, N39

---
### D3 — Residual Predicate on Seek: Promote Column to Key

**When:** A Seek operator has both `<SeekPredicates>` AND `<Predicate>` (residual), AND when runtime data is present `actualRows / actualRowsRead` < 0.2 (seek fetches 5× more rows than it returns)

**What to extract:**
- Current seek key columns (from `<SeekPredicates>`)
- Residual predicate column and operator (= / > / LIKE etc.)

**Recommendation:** Create a new index that includes the residual column as a key column (not INCLUDE — it must narrow the B-tree traversal, not just be available at the leaf).

```xml
<!-- Seek on (CustomerId), residual filters on Status = 'Active' -->
<!-- Current index: IX_Orders_CustomerId -->
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_Status]
ON [dbo].[Orders] ([CustomerId], [Status]);   -- Status as key, not INCLUDE
```

**Note:** If the residual column is low-cardinality (e.g., a boolean or 3-value status), a filtered index is often better than adding it to every row's key entry.

**Estimated impact:** `min(80, (1 - actualRows/actualRowsRead) × 100)` — scaled by how much the residual discards.

**Cross-reference:** sqlplan-review N43

---
### D4 — Eager Index Spool: Replace with Permanent Index

**When:** `logicalOp` = Eager Spool AND operator name contains "Index" (distinguishes from table spools)

**What to extract:**
- The spool's seek predicate — this is exactly what the temporary index is built on at runtime
- Output columns of the spool — INCLUDE candidates

**Recommendation:** A permanent NC index matching the spool's seek predicate eliminates the runtime index build entirely.

```xml
<!-- Eager Index Spool seeks on LineItemId -->
CREATE NONCLUSTERED INDEX [IX_LineItems_LineItemId]
ON [dbo].[LineItems] ([LineItemId])
INCLUDE ([OrderId], [Quantity], [Price]);
```

**Estimated impact:** 85 — Eager Index Spools always indicate a missing index and always carry significant overhead.

**Cross-reference:** sqlplan-review N2

---
### D5 — Costly Sort: Add Pre-Sorted Index

**When:** `physicalOp` = Sort AND `costPercent` ≥ 10%

**What to extract:**
- Sort column list and direction (ASC/DESC for each)
- The WHERE predicate of the upstream scan or seek (to include as leading key columns)

**Recommendation:** NC index whose key columns match the upstream filter first (equality columns), then the sort columns in the correct direction. This allows SQL Server to read data pre-ordered and skip the Sort entirely.

```xml
<!-- Sort on OrderDate DESC after filtering on CustomerId = @p -->
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_OrderDate_Desc]
ON [dbo].[Orders] ([CustomerId], [OrderDate] DESC);
```

**Estimated impact:** `costPercent` directly.

**Cross-reference:** sqlplan-review N22

---
### D6 — High-Count Nested Loops: Index the Inner Side

**When:** `physicalOp` = Nested Loops AND `actualExecutions` > 1,000 AND the inner side operator is a Scan (no seek on the join column)

**What to extract:**
- Inner side table name
- Outer references — the correlated columns passed from the outer loop to the inner side (these are the join columns)

**Recommendation:** NC index on the inner table's join column(s). This converts the inner-side scan to a seek, reducing each loop iteration from O(n) to O(log n).

```xml
<!-- NL inner side: dbo.LineItems scanned on OrderId = outer.OrderId -->
CREATE NONCLUSTERED INDEX [IX_LineItems_OrderId]
ON [dbo].[LineItems] ([OrderId]);
```

**Estimated impact:** `min(85, actualExecutions / 100)` capped at 85 — high execution counts amplify the per-iteration seek benefit.

**Cross-reference:** sqlplan-review N15

---
### D7 — Heap Scan: Add Clustered Index

**When:** `physicalOp` = Table Scan (indicates a heap — table with no clustered index)

**What to extract:**
- Table name
- Filter predicate columns if present (suggest as clustered key candidates)

**Recommendation:** A clustered index converts the heap to a B-tree, enables ordered access, and reduces fragmentation. Suggest the most selective filter column as the clustering key, or the natural identity/PK column.

```xml
-- If no natural key exists, use an identity:
ALTER TABLE [dbo].[StagingOrders] ADD [Id] INT IDENTITY(1,1) NOT NULL;
CREATE CLUSTERED INDEX [CIX_StagingOrders_Id] ON [dbo].[StagingOrders] ([Id]);

-- If a natural key exists:
CREATE CLUSTERED INDEX [CIX_StagingOrders_OrderRef] ON [dbo].[StagingOrders] ([OrderRef]);
```

**Estimated impact:** 60 (fixed) — heaps have consistently higher scan overhead than clustered tables.

**Cross-reference:** sqlplan-review N39

---
### D8 — Backward Scan: Add DESC Index

**When:** Any scan or seek operator has `ScanDirection` = BACKWARD

**What to extract:**
- The index being scanned and its current key column directions
- The columns and directions needed for a forward scan that produces the same order

**Recommendation:** A new index with the sort direction reversed on the relevant key column eliminates the backward scan. Backward scans have higher CPU cost than forward scans due to page latch contention patterns.

```xml
<!-- Current index: IX_Orders_CreatedDate (ASC), query wants DESC order -->
CREATE NONCLUSTERED INDEX [IX_Orders_CreatedDate_Desc]
ON [dbo].[Orders] ([CreatedDate] DESC)
INCLUDE ([CustomerId], [Status]);
```

**Estimated impact:** 40 (fixed) — modest but consistent CPU saving.

**Cross-reference:** sqlplan-review N12

---

## Source B: Optimizer Explicit Suggestions

Extract all `<MissingIndexGroup>` elements across all input plans.

```xml
<MissingIndexGroup Impact="87.3">
  <MissingIndex Database="MyDb" Schema="dbo" Table="Orders">
    <ColumnGroup Usage="EQUALITY">
      <Column Name="CustomerId" />
    </ColumnGroup>
    <ColumnGroup Usage="INEQUALITY">
      <Column Name="CreatedDate" />
    </ColumnGroup>
    <ColumnGroup Usage="INCLUDE">
      <Column Name="Status" />
      <Column Name="TotalAmount" />
    </ColumnGroup>
  </MissingIndex>
</MissingIndexGroup>
```

Per suggestion, extract: `Impact`, `Database/Schema/Table`, EQUALITY columns, INEQUALITY columns, INCLUDE columns.

**Key column order rule:** EQUALITY columns always precede INEQUALITY columns, regardless of XML order.

---

## Unified Merge

After collecting all candidates from Source A and Source B, group by `(Schema, Table)` and apply:

### Merge Rules (within each table group)

1. **Identical keys** — merge INCLUDE columns, keep higher impact score
2. **One is a prefix of the other** — wider key subsumes narrower; merge INCLUDEs
3. **Overlapping, not prefix** — keep as separate indexes; flag the overlap
4. **Completely distinct keys** — keep as separate indexes

When a Source A (derived) candidate and Source B (optimizer) candidate overlap for the same table, merge them — the optimizer's explicit Impact score takes precedence over the derived estimate when both are available.

**Label each merged recommendation with its sources:** `[optimizer]`, `[derived: D1, D5]`, or `[both]` so it's clear how the recommendation was identified.

---

## Ranking

After merging, rank by:

```
Score = Impact × ln(1 + SourceCount)
```

- `Impact` — optimizer Impact if available; derived estimate otherwise
- `SourceCount` — how many original candidates (from either source) were merged here

Sort descending.

---

## Width Check

Before generating DDL, flag:

| Condition | Severity | Note |
|-----------|----------|------|
| Key columns > 4 | Info | B-tree pages hold fewer rows; seek cost increases |
| INCLUDE columns > 5 | Info | Evaluate whether all columns serve the same query |
| Total columns > 10 | Warning | High write amplification; review carefully |

---

## Output Format

```
## Index Advisor Report

### Input Summary
- Plans analyzed: N
- Operator-derived candidates (Source A): X
- Optimizer suggestions (Source B): Y
- After unified merge: Z
- Tables affected: T

### Recommended Indexes (Ranked)

#### [I1] dbo.Orders — Score: 94.2 [both: D1 + optimizer]
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_CreatedDate]
ON [dbo].[Orders] ([CustomerId], [CreatedDate])
INCLUDE ([Status], [TotalAmount])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```
- Source: Key Lookup elimination (D1) + optimizer suggestion (Impact 87.3)
- Covers: 3 plans, eliminates Key Lookup on dbo.Orders
- Prerequisite: [any query/schema change required before this index is effective — omit if none]
- Warnings: None [or: brief warning if index won't help without a predicate fix, or if it overlaps with an existing index]

#### [I2] dbo.LineItems — Score: 71.0 [derived: D6]
```sql
CREATE NONCLUSTERED INDEX [IX_LineItems_OrderId]
ON [dbo].[LineItems] ([OrderId])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```
- Source: Nested Loops inner-side scan (D6), 12,400 executions
- Covers: 2 plans
- Warnings: None

### Skipped / Flagged

| Table | Reason | Action |
|-------|--------|--------|
| dbo.LargeLog | 9 INCLUDE columns — too wide | Split by query |
| dbo.Users | Overlapping key with existing IX_Users_Email | Verify before creating |

### Deployment Script

[Full CREATE INDEX block for all recommended indexes, in ranked order]

### Summary
- Operator-derived only: N indexes
- Optimizer-suggested only: M indexes
- Combined (both sources agreed): K indexes
- Estimated queries improved: Q

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*
```

---

## Naming Convention

`IX_{Table}_{KeyCol1}_{KeyCol2}[_Desc][_etc]`

- Append `_Desc` when a key column is DESC
- Truncate to 128 characters
- Append `_2`, `_3` on collision

---

## Notes

- Operator-derived recommendations (Source A) are inferences — they are not guaranteed improvements. Always validate with `/sqlplan-review` findings before deploying.
- The optimizer's Impact score reflects a single query's estimated benefit. A derived recommendation from a Nested Loops with 50,000 executions may be more valuable than an optimizer suggestion with Impact 90 from a query that runs once a day.
- Always test in non-production first. New indexes can shift plan shapes for other queries on the same table.
- Include `WITH (ONLINE = ON)` by default. Remove for Standard edition pre-2016 or tables with LOB columns (xml, varchar(max), etc.).
- If `sys.dm_db_missing_index_group_stats` data is available, incorporate `UserSeeks × AverageQueryCost` into the Impact ranking for Source B.

## Companion Skills

- **sqlplan-review** — Run the full 99-check analysis on the same plan before generating indexes. The check findings (N5 Key Lookup, N4 Expensive Scan) directly inform the index recommendations.
- **sqlplan-compare** — After deploying the recommended indexes, capture a new plan and diff against the baseline to confirm the improvement.
- **sqlplan-batch** — Run index advisor across a folder of plans to produce a single consolidated `CREATE INDEX` script for the whole workload.
- **tsql-review** — If the plan shows implicit conversion warnings (S12), review the T-SQL source (T5) to fix the type mismatch that prevents index seeks.
- **query-store-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.
