---
name: sqlindex-advisor
description: Analyze SQL Server execution plans to produce a ranked CREATE INDEX script. Derives index recommendations from operator patterns (Key Lookups, scans, sorts, spools, nested loops, filtered index opportunities, hash match probe-side scans — D1–D10) and the optimizer's explicit MissingIndexGroup suggestions. Also accepts sys.dm_db_missing_index_details + sys.dm_db_missing_index_group_stats DMV output directly, without a plan file. Use this skill whenever a user wants index recommendations from an execution plan; asks what indexes would help a query; mentions Key Lookup, index scan, missing index, filtered index, or covering index; or asks to generate CREATE INDEX statements. Trigger after sqlplan-review findings or directly on any .sqlplan file or missing index DMV output.
triggers:
  - /sqlindex-advisor
  - /index-advisor
  - /missing-indexes
---

# SQL Server Index Advisor Skill

## Purpose

Produce a prioritized, ready-to-run `CREATE INDEX` script from three independent sources:

1. **Operator-derived recommendations** — index opportunities inferred directly from plan operator patterns (Key Lookups, expensive scans, Sort operators, Eager Index Spools, high-count Nested Loops, residual predicates, heap scans, backward scans, filtered index candidates, hash match probe-side scans)
2. **Optimizer suggestions** — the explicit `<MissingIndexGroup>` elements SQL Server emits, consolidated and de-duplicated
3. **DMV data** — `sys.dm_db_missing_index_details` + `sys.dm_db_missing_index_group_stats` output, which provides server-wide frequency data (`UserSeeks × AvgQueryCost`) unavailable in plan files

All sources feed into a single unified merge and ranking pipeline. The final output contains one CREATE INDEX statement per table group — not one per source.

## Input

Accept any of:
- One or more `.sqlplan` file paths
- Raw `.sqlplan` XML pasted inline
- A description of plan operators if XML is not available
- Output from `sys.dm_db_missing_index_details` + `sys.dm_db_missing_index_group_stats` (Source C — no plan file required):

```sql
-- Capture server-wide missing index data (run on the target instance)
SELECT
    mig.index_group_handle,
    mig.index_handle,
    mig.unique_compiles,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_total_user_cost,
    migs.avg_user_impact,
    ROUND(migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact / 100.0), 2) AS weighted_impact,
    mid.statement            AS table_name,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns
FROM sys.dm_db_missing_index_groups  mig
JOIN sys.dm_db_missing_index_details mid
  ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats migs
  ON mig.index_group_handle = migs.group_handle
ORDER BY weighted_impact DESC;
```

When DMV output is provided, treat each row as a Source C candidate and use `weighted_impact` as the ranking score rather than the optimizer's static Impact percentage.

## How to Run

1. **Source A — Operator scan:** Walk every `<RelOp>` node and apply the derived rules (D1–D10) below
2. **Source B — Explicit extraction:** Extract all `<MissingIndexGroup>` elements
3. **Source C — DMV parsing:** If DMV output is present, parse each row into a candidate (table, equality cols, inequality cols, include cols, weighted_impact)
4. **Unified merge:** Combine A, B, and C by table, apply merge rules, deduplicate
5. **Rank** the merged set by score
6. **Generate DDL** with width checks applied

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
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId]
ON [dbo].[Orders] ([CustomerId])
INCLUDE ([Status], [TotalAmount])   -- add these to kill the lookup
WITH (ONLINE = ON, DROP_EXISTING = ON, SORT_IN_TEMPDB = ON);
```

**Estimated impact:** `min(90, costPercent)` — the lookup's plan share is the impact; no multiplier needed since Key Lookup cost already reflects the round-trip penalty.

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
-- Current index: IX_Orders_CustomerId
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_Status]
ON [dbo].[Orders] ([CustomerId], [Status]);   -- Status as key, not INCLUDE
```

**Note:** If the residual column is low-cardinality (e.g., a boolean or 3-value status), consider D9 (Filtered Index) instead — a filtered index avoids including the low-cardinality column on all rows.

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

**Recommendation:** A new index with the sort direction reversed on the relevant key column eliminates the backward scan. Backward scans have modestly higher CPU cost than forward scans due to latch ordering differences.

```xml
<!-- Current index: IX_Orders_CreatedDate (ASC), query wants DESC order -->
CREATE NONCLUSTERED INDEX [IX_Orders_CreatedDate_Desc]
ON [dbo].[Orders] ([CreatedDate] DESC)
INCLUDE ([CustomerId], [Status]);
```

**Estimated impact:** 22 (fixed) — modest CPU saving; backward scans are rarely the primary bottleneck. Validate with `sys.dm_os_wait_stats` PAGELATCH data before prioritizing this fix over higher-impact recommendations.

**Cross-reference:** sqlplan-review N12

---

### D9 — Filtered Index Opportunity

**When:** A seek or scan has an equality predicate on a **low-cardinality column** (≤ 10 distinct values estimated) AND the predicate's selectivity discards > 80% of rows — e.g., `IsDeleted = 0` where 98% of rows have `IsDeleted = 1`, or `Status = 'Active'` on a table where most rows are 'Completed'

**What to extract:**
- Table and schema name
- The highly selective equality predicate column and constant value
- The remaining predicate and output columns (→ key and INCLUDE of the filtered index)

**Why a filtered index rather than a standard key-column index:** Adding a low-cardinality column to the key of a full index writes an index entry for every row, including the 98% your query never touches. A filtered index stores only the matching subset — it is narrower, cheaper to maintain on writes, and faster to scan because the entire index fits in far fewer pages.

```xml
<!-- Scan on dbo.Tasks WHERE Status = 'Pending' (2% of rows); rest are 'Completed' -->
CREATE NONCLUSTERED INDEX [IX_Tasks_Status_Pending_AssignedUserId]
ON [dbo].[Tasks] ([AssignedUserId], [CreatedDate])
INCLUDE ([Priority], [DueDate])
WHERE Status = 'Pending'
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

**Caveats:**
- Filtered indexes only benefit queries that include the filter predicate as a literal constant or a properly typed parameter — the query optimizer will not use `IX_..._Pending` to satisfy `WHERE Status = @status` unless the plan is forced or the parameter value is sniffed to 'Pending'.
- Filtered statistics generated by the optimizer (auto-created) may not cover filtered index predicates correctly; manual statistics update may be needed after creation.
- Do not use on columns with high cardinality or evenly distributed values — a standard seek index is better in that case.

**Estimated impact:** `min(85, (1 − selectivity_pct) × 100)` — scaled by what fraction of the table is excluded from the filtered index.

**Cross-reference:** sqlplan-review N4, D3

---

### D10 — Hash Match Probe Side: Add Join Index

**When:** `physicalOp` = Hash Match (Join, not Aggregate) AND the **probe-side** input operator is a Scan (no seek) AND `costPercent` ≥ 20%

Hash Match joins are build-then-probe: the optimizer builds a hash table from the smaller input, then probes it for each row from the larger input. When the probe side is a scan, adding an index on the probe-side join column often allows the optimizer to switch to Merge Join (which requires no hash table build) or a much cheaper nested-loops seek pattern.

**What to extract:**
- Probe-side table name (typically the larger input — identified by the `Probe` child of the Hash Match node)
- The join predicate column(s) on the probe side — these become the key columns
- Probe-side output columns referenced further up the plan — INCLUDE candidates

**Recommendation:**

```xml
<!-- Hash Match joining dbo.OrderLines probe side (OrderId) to dbo.Orders build side -->
CREATE NONCLUSTERED INDEX [IX_OrderLines_OrderId]
ON [dbo].[OrderLines] ([OrderId])
INCLUDE ([ProductId], [Quantity], [UnitPrice])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

**Note:** The optimizer will not always switch to Merge Join — it depends on whether both sides can now be presented in sorted order. If after adding this index the plan still uses Hash Match, check whether the build side also lacks a sorted seek; if so, both sides may need indexes to unlock Merge Join.

**Estimated impact:** `min(80, costPercent)` — the hash match's plan share is the upper bound.

**Cross-reference:** sqlplan-review N6 (Hash Match spill), N7 (Hash Match memory grant)

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

**Note on Impact scores:** The Impact percentage reflects the optimizer's single-query cost estimate. A score of 99.999 (the cap) means the optimizer thinks the query would be effectively free with the index — treat these as high-priority but verify the query actually runs frequently enough to justify the write overhead.

---

## Source C: DMV-Based Suggestions

When `sys.dm_db_missing_index_group_stats` output is pasted, treat each row as a candidate. The `weighted_impact` column (`user_seeks × avg_total_user_cost × avg_user_impact / 100`) is a much better ranking signal than the static optimizer Impact because it accounts for how frequently the query actually runs.

Extract per row: `table_name`, `equality_columns`, `inequality_columns`, `included_columns`, `weighted_impact`.

**Note:** Missing index DMV data is cleared on SQL Server restart. If `user_seeks` is low but the server was recently restarted, the data may be incomplete.

---

## Unified Merge

After collecting all candidates from Sources A, B, and C, group by `(Schema, Table)` and apply:

### Merge Rules (within each table group)

1. **Identical keys** — merge INCLUDE columns, keep higher impact score
2. **One is a prefix of the other** — wider key subsumes narrower; merge INCLUDEs
3. **Overlapping, not prefix** — keep as separate indexes; flag the overlap
4. **Completely distinct keys** — keep as separate indexes

When a Source A (derived) candidate and Source B/C (optimizer/DMV) candidate overlap for the same table, merge them — the optimizer's Impact or the DMV's weighted_impact takes precedence over the derived estimate when both are available.

**Filtered index candidates (D9) are never merged with full indexes.** A filtered index serves only queries containing its filter predicate; merging it into a full index defeats the purpose.

**Label each merged recommendation with its sources:** `[optimizer]`, `[dmv]`, `[derived: D1, D5]`, `[both]`, etc.

---

## Ranking

After merging, rank by:

```
Score = Impact × ln(1 + QueryCount)
```

- `Impact` — DMV `weighted_impact` if available (preferred); optimizer Impact if only a plan file; derived estimate otherwise
- `QueryCount` — how many distinct queries (plan files or DMV entries) were merged here; logarithmic to avoid over-weighting broad but shallow suggestions

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

## Version-Aware Check Suppression

If the SQL Server version is known — from the `ServerVersion` attribute in the plan XML or stated by the user — read `VERSION_COMPATIBILITY.md` (`~/.claude/skills/VERSION_COMPATIBILITY.md` if installed, or `skills/VERSION_COMPATIBILITY.md` from the repo). If unavailable, skip silently. For checks whose minimum version exceeds the instance version: verbose mode → log as `SKIP (version: requires SQL 20XX+, instance is SQL 20YY)`; standard report → omit entirely.

---

## Output Format

```
## Index Advisor Report

### Input Summary
- Plans analyzed: N
- Operator-derived candidates (Source A): X
- Optimizer suggestions (Source B): Y
- DMV candidates (Source C): Z [or "none"]
- After unified merge: M
- Tables affected: T

### Recommended Indexes (Ranked)

#### [I1] dbo.Orders — Score: 94.2 [both: D1 + optimizer]
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_CreatedDate]
ON [dbo].[Orders] ([CustomerId], [CreatedDate])
INCLUDE ([Status], [TotalAmount])
WITH (ONLINE = ON, DROP_EXISTING = ON, SORT_IN_TEMPDB = ON);
-- Note: DROP_EXISTING = ON assumes IX_Orders_CustomerId already exists and is being extended.
-- Verify: SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Orders')
-- Remove DROP_EXISTING if this is a new index name.
```
- Source: Key Lookup elimination (D1) + optimizer suggestion (Impact 87.3)
- Covers: 3 plans, eliminates Key Lookup on dbo.Orders
- Prerequisite: [any query/schema change required before this index is effective — omit if none]
- Warnings: None [or: brief warning if index won't help without a predicate fix, or if it overlaps with an existing index]

#### [I2] dbo.Tasks — Score: 71.0 [derived: D9, filtered]
```sql
CREATE NONCLUSTERED INDEX [IX_Tasks_AssignedUserId_CreatedDate_Pending]
ON [dbo].[Tasks] ([AssignedUserId], [CreatedDate])
INCLUDE ([Priority], [DueDate])
WHERE Status = 'Pending'
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```
- Source: Filtered index candidate (D9): Status = 'Pending' excludes 97% of table rows
- Covers: Queries containing literal WHERE Status = 'Pending' — will NOT be used for parameterized @status queries unless sniffed to 'Pending'
- Warnings: Verify query uses the literal constant, not a parameter

### Skipped / Flagged

| Table | Reason | Action |
|-------|--------|--------|
| dbo.LargeLog | 9 INCLUDE columns — too wide | Split by query |
| dbo.Users | Overlapping key with existing IX_Users_Email | Verify before creating |

### Deployment Script

```sql
-- ============================================================
-- Deploy in ranked order. Test each index in non-production first.
-- ============================================================

-- STEP 1: [description]
CREATE NONCLUSTERED INDEX [IX_...]
ON [dbo].[...] ([...])
INCLUDE ([...])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON
      -- SQL 2017+ on large tables: add RESUMABLE = ON, MAX_DURATION = 120 MINUTES
      -- Remove ONLINE = ON for Standard edition pre-2016 or tables with LOB columns
     );

-- Validate before promoting to production:
-- SELECT TOP 100 ... FROM dbo.Orders WITH (INDEX = IX_Orders_CustomerId_CreatedDate) WHERE ...;
-- Confirm the query uses the new index in the execution plan before removing the hint.
```

### Summary
- Operator-derived only: N indexes
- Optimizer-suggested only: M indexes
- DMV-derived only: K indexes
- Combined (multiple sources agreed): J indexes
- Filtered indexes: F indexes
- Estimated queries improved: Q

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*
```

---

## Naming Convention

`IX_{Table}_{KeyCol1}_{KeyCol2}[_Desc][_etc]`

- Append `_Desc` when a key column is DESC
- For filtered indexes, append a suffix describing the filter: `IX_Tasks_AssignedUserId_Pending`
- Truncate to 128 characters
- Append `_2`, `_3` on collision

---

## Notes

- Operator-derived recommendations (Source A) are inferences — they are not guaranteed improvements. Always validate with `/sqlplan-review` findings before deploying.
- The optimizer's Impact score reflects a single query's estimated benefit. A derived recommendation from a Nested Loops with 50,000 executions may be more valuable than an optimizer suggestion with Impact 90 from a query that runs once a day. DMV `weighted_impact` data is the most reliable ranking signal when available.
- Always test in non-production first. New indexes can shift plan shapes for other queries on the same table.
- Include `WITH (ONLINE = ON)` by default. Remove for Standard edition pre-2016 or tables with LOB columns (xml, varchar(max), etc.). SQL Server 2017+ supports `RESUMABLE = ON, MAX_DURATION = N MINUTES` for large tables, which allows pausing and resuming a long index build.
- `DROP_EXISTING = ON` is appropriate when extending an existing index (D1 Key Lookup pattern). Always verify the current index name against `sys.indexes` before using it.

---

### Section: Output Filters (--brief / --critical-only)

**`--brief`** — Omit the Passed Checks table and attribution footer. Output the Summary, Findings, and Prioritized Fix Sequence sections only. Use when a quick scan of what fired is all that's needed.

**`--critical-only`** — Suppress Warning and Info findings. Show only Critical findings. The Passed Checks table is also omitted. Use when triaging an incident and only actionable blockers matter.

Both flags can be combined: `--brief --critical-only` produces the Summary section plus Critical findings only.

When neither flag is present, produce the full report as documented above.

---

### Section: Verbose Output (--verbose)

When the user's request includes `--verbose`, `--trace`, or the word `verbose`:

**1. Append a `## Check Evaluation Log` section** after the Passed Checks table.

Include one row for every check in this skill's ruleset, in check-ID order:

| Check | Evidence | Threshold | Result |
|-------|----------|-----------|--------|
| [ID — Name] | [key attribute(s) and value found, or "absent"] | [threshold or condition] | PASS / **FIRE → [severity]** / NOT ASSESSED |

Result conventions:
- `PASS` — attribute present, threshold not met
- `**FIRE → Critical/Warning/Info**` — threshold met; bold to distinguish from passes
- `NOT ASSESSED` — required attribute absent from input

**2. Save both files** to the current working directory using the Write tool:

  output/<skill-name>/<YYYY-MM-DD-HHmmss>-<input-prefix>/analysis.md  ← full report
  output/<skill-name>/<YYYY-MM-DD-HHmmss>-<input-prefix>/trace.md     ← Check Evaluation Log

Derive `<input-prefix>`:
1. Filename stem if a file path was provided (e.g. `horrible.sqlplan` → `horrible`)
2. First meaningful identifier from the artifact (top wait type, first table name, procedure name, etc.)
3. Fallback: `run`
Sanitize: alphanumeric + hyphens/underscores only, max 32 chars.

Create directories as needed. When `--verbose` is not present, write nothing to disk.

---

## Companion Skills

- **sqlplan-review** — Run the full 108-check analysis on the same plan before generating indexes. The check findings (N5 Key Lookup, N4 Expensive Scan) directly inform the index recommendations.
- **sqlplan-compare** — After deploying the recommended indexes, capture a new plan and diff against the baseline to confirm the improvement.
- **sqlplan-batch** — Run index advisor across a folder of plans to produce a single consolidated `CREATE INDEX` script for the whole workload.
- **tsql-review** — If the plan shows implicit conversion warnings (S12), review the T-SQL source (T5) to fix the type mismatch that prevents index seeks.
- **sqlquerystore-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.
- **mssql-performance-review** — Orchestrator that routes mixed artifacts to multiple specialised skills (this one included), runs an adversarial root-cause check, and produces a single consolidated report with evidence chain, risk-rated fixes, and rollback. Use when you have several artifact types together or describe a symptom without knowing which skill to run.
