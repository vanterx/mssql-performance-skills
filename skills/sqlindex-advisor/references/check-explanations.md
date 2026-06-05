# sqlindex-advisor — Checks Explained (D1–D10)

## Contents

- [D1 — Key Lookup / RID Lookup: Extend NC Index](#d1--key-lookup--rid-lookup-extend-nc-index)
- [D2 — Expensive Scan: Add Seek Index](#d2--expensive-scan-add-seek-index)
- [D3 — Residual Predicate on Seek: Promote Column to Key](#d3--residual-predicate-on-seek-promote-column-to-key)
- [D4 — Eager Index Spool: Replace with Permanent Index](#d4--eager-index-spool-replace-with-permanent-index)
- [D5 — Costly Sort: Add Pre-Sorted Index](#d5--costly-sort-add-pre-sorted-index)
- [D6 — High-Count Nested Loops: Index the Inner Side](#d6--high-count-nested-loops-index-the-inner-side)
- [D7 — Heap Scan: Add Clustered Index](#d7--heap-scan-add-clustered-index)
- [D8 — Backward Scan: Add DESC Index](#d8--backward-scan-add-desc-index)
- [D9 — Filtered Index Opportunity](#d9--filtered-index-opportunity)
- [D10 — Hash Match Probe Side: Add Join Index](#d10--hash-match-probe-side-add-join-index)
- [Concepts: Why Raw Suggestions Need Consolidation](#why-raw-suggestions-need-consolidation)
- [Concepts: Merge Rules Explained](#merge-rules-explained)
- [Concepts: Ranking Formula](#ranking-formula)
- [Concepts: Width Check](#width-check)

---

### D1 — Key Lookup / RID Lookup: Extend NC Index

**What it means:** A Key Lookup operator means SQL Server seeked a nonclustered index to find row identifiers, but then had to go back to the clustered index (or heap) a second time to fetch columns that weren't stored in the nonclustered index. Each "round trip" is an extra random I/O per row. On a 5-million-row result set, that's 5 million extra random reads.

**How to spot it:** `physicalOp = "Key Lookup"` or `"RID Lookup"` in the XML. The parent of the Key Lookup is always a Nested Loops operator whose outer side has the initial seek.

**Example:**
```xml
<!-- Plan shows: NC Seek on IX_Orders_CustomerId → Key Lookup → Nested Loops -->
<!-- The lookup fetches Status, TotalAmount from the clustered index -->
```
What the plan is saying: "I found the rows with a fast seek, but the nonclustered index doesn't store `Status` or `TotalAmount`, so I have to fetch them separately."

**Fix options:**
1. **Extend the existing NC index with INCLUDE columns** (preferred — adds leaf-level columns without affecting seek behavior):
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId]
ON [dbo].[Orders] ([CustomerId])
INCLUDE ([Status], [TotalAmount])
WITH (ONLINE = ON, DROP_EXISTING = ON, SORT_IN_TEMPDB = ON);
-- DROP_EXISTING = ON rebuilds in place; verify the name matches sys.indexes first
```
2. **Make the fetched columns key columns** — only if they appear in WHERE or ORDER BY and need to narrow the B-tree.
3. **Create a new covering index** if the existing NC index serves many other queries and extending it would make it too wide.

**Related checks:** D3 (residual predicate after seek), sqlplan-review N5

---

### D2 — Expensive Scan: Add Seek Index

**What it means:** SQL Server read the entire index (or table) to find rows matching a predicate instead of seeking directly to matching rows. A scan reads every page in the index regardless of how many rows match the predicate.

**How to spot it:** `physicalOp = "Index Scan"` or `"Table Scan"` with a Predicate attribute and `costPercent ≥ 25`.

**Example:**
```xml
<!-- Scan on dbo.Orders: Predicate: CustomerId = @p AND CreatedDate > @d -->
<!-- costPercent: 62%, actualRows: 150, actualRowsRead: 8,400,000 -->
```
SQL Server read 8.4M rows to return 150 — seeking on `(CustomerId, CreatedDate)` would have read ~150 rows instead.

**Fix options:**
1. **Add an NC index on the equality predicate columns first, then range columns:**
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_CreatedDate]
ON [dbo].[Orders] ([CustomerId], [CreatedDate])
INCLUDE ([Status], [TotalAmount]);  -- add output columns if they're always fetched
```
2. **Check for implicit conversions** — if the predicate is `CONVERT_IMPLICIT(datetime, CreatedDate)`, no index will help until the type mismatch is fixed (see tsql-review T5).
3. **Consider a filtered index (D9)** if the predicate is always a specific constant value.

**Related checks:** D3, D9, sqlplan-review N4

---

### D3 — Residual Predicate on Seek: Promote Column to Key

**What it means:** The seek jumped to the right B-tree range using the SeekPredicate columns, but then a residual Predicate filtered down the results further — after fetching them from the index. The residual predicate is not part of the B-tree navigation; rows are read and discarded rather than never read at all.

**How to spot it:** A seek operator has both `<SeekPredicates>` (the seek) AND a `<Predicate>` (the residual). At runtime, `actualRowsRead >> actualRows` confirms the filter is discarding many rows after the seek.

**Example:**
```xml
<!-- Seek on IX_Orders_CustomerId (CustomerId = @cid), 
     Residual: Status = 'Active' 
     actualRowsRead=85000, actualRows=230 -->
```
85,000 rows were fetched from the index; only 230 passed the `Status = 'Active'` residual. Adding `Status` as a key column after `CustomerId` would have read only ~230 rows.

**Fix options:**
1. **Add the residual column as the next key column:**
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_Status]
ON [dbo].[Orders] ([CustomerId], [Status]);
```
2. **Use a filtered index (D9)** if the residual value is always the same constant and cardinality is low (e.g., `Status = 'Active'` when only 2% of rows are active).

**Note:** Adding a low-cardinality column to the full index key increases the index size unnecessarily when most rows will never be sought with that value. Prefer D9 in those cases.

**Related checks:** D1, D9, sqlplan-review N43

---

### D4 — Eager Index Spool: Replace with Permanent Index

**What it means:** SQL Server built a temporary index at query execution time because no suitable permanent index existed. The Eager Index Spool creates a B-tree in TempDB, populates it from the input, then allows seeks against it. The build cost is paid on every execution.

**How to spot it:** `logicalOp = "Eager Spool"` AND the operator name contains "Index" (as opposed to "Table Spool" or "Row Count Spool").

**Example:**
```xml
<!-- Eager Index Spool (seeks on LineItemId), costPercent 38% -->
```
SQL Server is telling you: "I needed an index here but didn't find one, so I built one myself — at your expense."

**Fix options:**
1. **Create a permanent NC index matching the spool's seek predicate:**
```sql
CREATE NONCLUSTERED INDEX [IX_LineItems_LineItemId]
ON [dbo].[LineItems] ([LineItemId])
INCLUDE ([OrderId], [Quantity], [Price]);
```
The spool's seek columns become the key; the spool's output columns become INCLUDE.
2. **Do not use `OPTION (LOOP JOIN)`** to force the optimizer to expose spools — fix the underlying index instead.

**Related checks:** sqlplan-review N2

---

### D5 — Costly Sort: Add Pre-Sorted Index

**What it means:** SQL Server sorted a large result set in memory (or TempDB if a spill occurred) because it couldn't read the data in the required order from storage. Sorting is O(N log N) — eliminating it by reading pre-sorted data from an index reduces this to O(N).

**How to spot it:** `physicalOp = "Sort"` AND `costPercent ≥ 10`. Check for `SpillOccurred` attribute — if the sort spilled to TempDB, the actual cost is higher than the plan estimate.

**Example:**
```xml
<!-- Sort on OrderDate DESC, costPercent: 24%, SpillOccurred: 1 -->
<!-- Upstream: seek on IX_Orders_CustomerId (CustomerId = @cid) -->
```

**Fix options:**
1. **Add an index that delivers data pre-sorted:**
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId_OrderDate_Desc]
ON [dbo].[Orders] ([CustomerId], [OrderDate] DESC);
```
The equality predicate column (`CustomerId`) must come first; the sort column (`OrderDate DESC`) follows. This allows an index scan/seek in the right order without a sort.
2. **If the sort spills:** address the root cause (stale statistics → bad cardinality estimate → oversized sort) before assuming an index is the fix.

**Related checks:** sqlplan-review N22, N15 (sort spill)

---

### D6 — High-Count Nested Loops: Index the Inner Side

**What it means:** A Nested Loops join executed its inner side many thousands of times, and the inner side was a scan (not a seek). Each iteration read the entire inner table to find one matching row. With 10,000 outer rows and a 50,000-row inner table, that's 500,000,000 row evaluations.

**How to spot it:** `physicalOp = "Nested Loops"` AND `actualExecutions > 1,000` on the operator AND the inner child is a scan.

**Example:**
```xml
<!-- Nested Loops, actualExecutions: 12,400 -->
<!-- Inner side: Table Scan on dbo.LineItems, Predicate: OrderId = Outer.OrderId -->
```

**Fix options:**
1. **Add an NC index on the inner table's join column:**
```sql
CREATE NONCLUSTERED INDEX [IX_LineItems_OrderId]
ON [dbo].[LineItems] ([OrderId]);
```
With this index, each of the 12,400 iterations does a seek instead of a scan — O(log n) instead of O(n) per iteration.
2. **Check if a Hash Match join would be better** for this cardinality — nested loops are optimal for low outer row counts; at very high counts consider whether the query would benefit from a hash or merge join strategy.

**Related checks:** sqlplan-review N15

---

### D7 — Heap Scan: Add Clustered Index

**What it means:** The table has no clustered index (it's a "heap"). Heaps store rows in arbitrary insertion order with no B-tree structure. Every query that accesses the table reads pages via a full allocation scan (IAM scan) rather than a navigable B-tree. Heap tables also suffer from forwarded records (row forwarding) when variable-length columns grow after insertion.

**How to spot it:** `physicalOp = "Table Scan"` (not "Index Scan" — a Table Scan always means a heap).

**Fix options:**
1. **Create a clustered index using the table's natural key:**
```sql
CREATE CLUSTERED INDEX [CIX_StagingOrders_OrderRef]
ON [dbo].[StagingOrders] ([OrderRef]);
```
2. **If no natural key exists, add a surrogate:**
```sql
ALTER TABLE [dbo].[StagingOrders] ADD [Id] INT IDENTITY(1,1) NOT NULL;
CREATE CLUSTERED INDEX [CIX_StagingOrders_Id] ON [dbo].[StagingOrders] ([Id]);
```
3. **Staging/temporary tables** intentionally built as heaps (INSERT-only, bulk-loaded, then dropped) may not need a clustered index — evaluate based on whether the table has SELECT queries with predicates.

**Related checks:** sqlplan-review N39

---

### D8 — Backward Scan: Add DESC Index

**What it means:** SQL Server read an index in reverse order to satisfy a descending sort requirement. While SQL Server supports backward scans, they are slightly more expensive than forward scans — the page latch acquisition order is reversed, which can cause contention under concurrent workloads. The performance difference is usually modest.

**How to spot it:** A scan or seek operator has `ScanDirection = "BACKWARD"`.

**Example:**
```xml
<!-- Index Seek on IX_Orders_CreatedDate (ASC), ScanDirection: BACKWARD -->
<!-- Query has: ORDER BY CreatedDate DESC -->
```

**Fix options:**
1. **Add a new index with the sort direction matching the query:**
```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CreatedDate_Desc]
ON [dbo].[Orders] ([CreatedDate] DESC)
INCLUDE ([CustomerId], [Status]);
```
2. **Before creating:** verify backward scans are actually causing measurable PAGELATCH contention (`sys.dm_os_wait_stats` for PAGELATCH_SH/EX). D8 has the lowest impact score (22) in this skill — only prioritize it after all higher-impact recommendations are addressed.

**Related checks:** sqlplan-review N12

---

### D9 — Filtered Index Opportunity

**What it means:** A query filters on a column with very low cardinality (e.g., `Status = 'Active'`, `IsDeleted = 0`, `TenantId = 5`), and that predicate is highly selective — it excludes 80%+ of the table's rows. A filtered index stores only the matching subset, making it far smaller and cheaper than a full index. The smaller size means it fits in fewer buffer pool pages, is faster to scan, and has lower write overhead because rows that don't match the filter predicate don't generate index maintenance.

**How to spot it:** A seek or scan has:
- An equality predicate on a column with ≤ 10 distinct values estimated
- The predicate eliminates > 80% of the table's rows (low selectivity value)

**Example:**
```xml
<!-- Scan on dbo.Tasks: WHERE Status = 'Pending' -->
<!-- Table has 10M rows; only 200,000 are 'Pending' (2%) -->
```
A full index on `(Status, AssignedUserId)` would have 10M entries; a filtered index with `WHERE Status = 'Pending'` has only 200,000 entries — 50× smaller.

**Fix options:**
1. **Create a filtered index:**
```sql
CREATE NONCLUSTERED INDEX [IX_Tasks_AssignedUserId_Pending]
ON [dbo].[Tasks] ([AssignedUserId], [CreatedDate])
INCLUDE ([Priority], [DueDate])
WHERE Status = 'Pending'
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```
2. **Verify the query uses literal constants, not parameters.** The optimizer will only use a filtered index when it can prove the query result falls within the filter. For parameterized queries (`WHERE Status = @status`), the optimizer cannot use the filtered index unless it sniffs the parameter to `'Pending'` or the query is forced.
3. **For parameterized queries** that always pass the same value: add `OPTION (RECOMPILE)` to force per-execution plan generation, or use a plan guide, or ensure the parameter is sniffed correctly via an explicit constant comparison.

**Caveats:**
- Filtered indexes require the filter column to be specified in every query that should use the index, either in WHERE, JOIN, or a computed column
- Filtered statistics are created separately and may need manual `UPDATE STATISTICS` after significant data changes
- Cannot be used as a clustered index
- Not supported on computed columns (only persisted computed columns)

**Related checks:** D2, D3, sqlplan-review N4

---

### D10 — Hash Match Probe Side: Add Join Index

**What it means:** A Hash Match join works in two phases: (1) build a hash table from the smaller input, (2) probe the hash table with each row from the larger input. When the probe side is a scan, every probe-side row must be read before matching can begin, and the hash table must be held in memory (or spilled to TempDB). Adding an index on the probe side's join column allows the optimizer to switch to a Merge Join or a nested-loops seek, which avoids the hash table entirely.

**How to spot it:** `physicalOp = "Hash Match"` AND `logicalOp` contains "Join" (not "Aggregate") AND the probe child is a scan AND `costPercent ≥ 20`.

**Example:**
```xml
<!-- Hash Match (Inner Join), costPercent: 45% -->
<!-- Build side: dbo.Orders (small, 50K rows) — has seek -->
<!-- Probe side: dbo.OrderLines (large, 2M rows) — Table Scan, no seek -->
```
The probe-side scan reads 2M rows. An index on `OrderLines.OrderId` would allow the optimizer to reconsider the join strategy.

**Fix options:**
1. **Add an NC index on the probe-side join column:**
```sql
CREATE NONCLUSTERED INDEX [IX_OrderLines_OrderId]
ON [dbo].[OrderLines] ([OrderId])
INCLUDE ([ProductId], [Quantity], [UnitPrice])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```
2. **After adding the index, capture a new plan** and verify the optimizer chose Merge Join or Nested Loops. If it still chooses Hash Match, the optimizer has decided the hash join is still cheaper (possibly because the new index doesn't cover all needed columns, or cardinality estimates are wrong).
3. **Check Hash Match spills** (`sys.dm_exec_query_stats` `total_spills` or sqlplan-review N6) — a spilling hash join has higher urgency than a non-spilling one.

**Note on Hash Aggregate vs Hash Match Join:** This check only applies to Hash Match **joins**. Hash Aggregate operators (grouping/aggregation) have different index remediation patterns — they benefit more from covering indexes that pre-aggregate-order the data or eliminate the aggregation entirely.

**Related checks:** sqlplan-review N6, N7, D6

---

## Why Raw Suggestions Need Consolidation

SQL Server generates missing index suggestions independently per query execution. It does not:
- Check whether an existing index already covers the suggestion
- Merge overlapping suggestions for the same table across different queries
- Rank by how frequently the query runs (only by optimizer cost estimate)
- Consider the maintenance overhead of the indexes it suggests

The result: a typical slow workload produces 20–50 raw suggestions, many of which overlap, some of which conflict with each other, and none of which account for write overhead. Running all of them verbatim would create redundant indexes that slow down writes without proportionally improving reads.

The advisor applies merge rules, deduplication, ranking, and width checks — turning 20+ raw suggestions into 3–7 targeted indexes worth actually creating.

---

## Merge Rules Explained

When two suggestions target the same table, the advisor applies these rules in order:

### Rule 1 — Identical Keys → Merge INCLUDEs

Both suggestions have exactly the same key columns (same columns, same order).

```
Suggestion A: (CustomerId, OrderDate) INCLUDE (Status)         Impact: 72
Suggestion B: (CustomerId, OrderDate) INCLUDE (TotalAmount)    Impact: 65
```

Result: `(CustomerId, OrderDate) INCLUDE (Status, TotalAmount)` — Impact: 72 (keep higher)

**Why:** One index serves both queries. No reason to have two identical-key indexes.

### Rule 2 — Prefix Subsumption → Merge into Wider

One suggestion's key columns are the leading prefix of the other's key columns.

```
Suggestion A: (CustomerId) INCLUDE (Status)
Suggestion B: (CustomerId, OrderDate) INCLUDE (Status, TotalAmount)
```

Result: `(CustomerId, OrderDate) INCLUDE (Status, TotalAmount)`

**Why:** An index on `(CustomerId, OrderDate)` can serve queries that seek only on `CustomerId` — the B-tree supports partial key seeks. The narrower suggestion is subsumed. INCLUDEs are merged.

**Caveat:** This only holds when the prefix relationship is strict. `(CustomerId, OrderDate)` subsumes `(CustomerId)` but not `(OrderDate, CustomerId)`.

### Rule 3 — Overlapping but Not Prefix → Keep Separate

```
Suggestion A: (CustomerId, Status)
Suggestion B: (CustomerId, OrderDate)
```

These share the leading `CustomerId` but diverge after it. An index on `(CustomerId, Status)` cannot serve a range seek on `OrderDate`, and vice versa. Keep as two separate indexes.

**Note:** The advisor flags the overlap so you're aware — two indexes on the same table with the same leading column increase write amplification.

### Rule 4 — Completely Distinct Keys → Keep Separate

No shared columns at all. These serve entirely different query patterns. Keep both.

### Filtered indexes are never merged with full indexes

A filtered index (D9) only covers rows matching its WHERE clause. Merging it into a full index defeats the size and maintenance benefits that make filtered indexes worthwhile.

---

## Ranking Formula

After merging, suggestions are ranked by:

```
Score = Impact × ln(1 + QueryCount)
```

- **Impact** — DMV `weighted_impact` (preferred; accounts for frequency); optimizer's Impact percentage (static); or derived estimate
- **QueryCount** — how many original suggestions (from any source) were merged into this one — proxy for "how many queries benefit"
- **ln(1 + N)** — logarithmic scale so merging 10 suggestions isn't weighted 10× over merging 2

**In plain English:** A suggestion that benefits 5 queries at Impact 60 ranks higher than a suggestion that benefits 1 query at Impact 72. The formula balances single-query impact against breadth of benefit.

When `Impact` is not available (description-only input), rank by `QueryCount` alone.

---

## Width Check

Wide indexes are expensive to maintain. Before generating DDL, the advisor flags:

| Condition | Severity | Meaning |
|-----------|----------|---------|
| Key columns > 4 | Info | B-tree pages hold fewer rows; seek cost per row increases |
| INCLUDE columns > 5 | Info | Leaf page size grows; scans and lookups read more data |
| Total columns > 10 | Warning | High write amplification; every INSERT/UPDATE/DELETE pays to maintain all columns |

**Why wide indexes hurt writes:**
Every index is updated separately on write operations. An INSERT into a table with 6 indexes writes 6 B-tree entries. A very wide index also has larger page entries, reducing the number of entries per page and increasing the number of pages touched per write.

**What to do when flagged wide:**
1. Check if all INCLUDE columns are needed by the same query — if two different queries each need 3 different INCLUDE columns, split into two narrower indexes
2. Check if the INEQUALITY column could be dropped (if queries always filter on EQUALITY columns anyway)
3. Consider whether a covering index is worth the write cost for this table's write frequency

---

## Quick Reference

| Check | Trigger condition | Impact formula |
|-------|-------------------|----------------|
| D1 | Key Lookup / RID Lookup present | `min(90, costPercent)` |
| D2 | Scan with predicate, costPercent ≥ 25% | `costPercent` |
| D3 | Seek with residual predicate, actualRows/actualRowsRead < 0.2 | `min(80, (1 − ratio) × 100)` |
| D4 | Eager Index Spool | 85 (fixed) |
| D5 | Sort, costPercent ≥ 10% | `costPercent` |
| D6 | Nested Loops inner-side scan, actualExecutions > 1,000 | `min(85, executions / 100)` |
| D7 | Table Scan (heap) | 60 (fixed) |
| D8 | ScanDirection = BACKWARD | 22 (fixed) |
| D9 | Equality predicate on low-cardinality column, > 80% rows excluded | `min(85, (1 − selectivity) × 100)` |
| D10 | Hash Match Join, probe-side scan, costPercent ≥ 20% | `min(80, costPercent)` |
