# sqlindex-advisor — Explained

## Contents

- [Why Raw Suggestions Need Consolidation](#why-raw-suggestions-need-consolidation)
- [Key Concepts](#key-concepts)
- [Merge Rules Explained](#merge-rules-explained)
- [Ranking Formula](#ranking-formula)
- [Width Check](#width-check)
- [Naming Convention](#naming-convention)
- [Reading the Output](#reading-the-output)

---


A plain-English guide to how the index advisor consolidates missing index suggestions, what each concept means, and how to interpret the output before running any DDL.

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

## Key Concepts

### The Impact Score

Each `<MissingIndexGroup>` has an `Impact` attribute — a number between 0 and 100:

```xml
<MissingIndexGroup Impact="87.3">
```

**What it means:** The optimizer estimates this index would reduce the query's cost by 87.3%. It is computed as:

```
Impact = (UserSeeks + UserScans) × AverageQueryCost × (1 − 1/IndexBenefit)
```

normalized to 0–100. A score of 87 means the optimizer thinks the query would run roughly 7× faster.

**What it doesn't mean:**
- It is based on a single query's cost estimate — a high-impact suggestion on a query that runs once a day may be less valuable than a low-impact suggestion on a query that runs 10,000 times a day
- It does not account for the cost of maintaining the new index on writes (INSERT/UPDATE/DELETE)
- Optimizer cost estimates are estimates — the actual improvement may be more or less

### EQUALITY, INEQUALITY, and INCLUDE Columns

Every missing index suggestion groups its columns into three buckets:

```xml
<ColumnGroup Usage="EQUALITY">   <!-- exact match predicates: col = @val -->
<ColumnGroup Usage="INEQUALITY"> <!-- range predicates: col > @val, col LIKE 'x%' -->
<ColumnGroup Usage="INCLUDE">    <!-- columns needed in the SELECT but not for navigation -->
```

**Key column order rule (enforced by the advisor):**
1. EQUALITY columns first — they allow the B-tree to navigate directly to matching rows
2. INEQUALITY columns after — they narrow the range once the seek lands
3. INCLUDE columns are not part of the B-tree key — they're stored at the leaf level only

Wrong order (INEQUALITY before EQUALITY) wastes the B-tree navigation advantage. The advisor always reorders correctly regardless of what the XML suggests.

**Example:**
```sql
WHERE CustomerId = @cid   -- EQUALITY
  AND OrderDate > @date   -- INEQUALITY
```
Correct index: `(CustomerId, OrderDate) INCLUDE (Status, Total)`  
Not: `(OrderDate, CustomerId)` — this wastes the seek on a range scan of OrderDate first

### What "Covered" Means

An index *covers* a query if every column the query needs (in WHERE, JOIN, and SELECT) is either a key column or an INCLUDE column of that index. A covered query requires no Key Lookup — it never touches the clustered index. This is the goal.

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

---

## Ranking Formula

After merging, suggestions are ranked by:

```
Score = Impact × ln(1 + MergedQueryCount)
```

- **Impact** — optimizer's cost-reduction estimate (higher = better)
- **MergedQueryCount** — how many original suggestions were merged into this one (proxy for "how many queries benefit")
- **ln(1 + N)** — logarithmic scale so merging 10 suggestions isn't weighted 10× over merging 2

**In plain English:** A suggestion that benefits 5 queries at Impact 60 ranks higher than a suggestion that benefits 1 query at Impact 72. The formula balances single-query impact against breadth of benefit.

When `Impact` is not available (description-only input), rank by `MergedQueryCount` alone.

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

## Naming Convention

Generated index names follow: `IX_{Table}_{KeyCol1}_{KeyCol2}`

- Truncated to 128 characters (SQL Server's identifier limit)
- Numeric suffix appended (`_2`, `_3`) if a collision would occur with an existing index name
- Schema prefix not included in the name (only in `ON schema.table`)

Before running the generated DDL, verify the name doesn't conflict: `SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.YourTable')`

---

## Reading the Output

### Input Summary

```
Plans analyzed: 8
Raw missing index suggestions: 34
Suggestions after merging: 7
Tables affected: 5
```

If suggestions after merging is close to raw (e.g., 30 of 34 kept), most suggestions are for different tables or non-overlapping patterns — you genuinely need many indexes, or the workload is very broad. If merging collapses 34 → 5, there were many redundant suggestions all targeting the same tables.

### Recommended Indexes Section

Each entry shows:
- **Impact score** — after merging, this is the highest Impact among merged suggestions
- **Merged query count** — how many original suggestions were consolidated here
- **Covers queries** — which plan files triggered this suggestion (if file names are available)
- **Warnings** — width check results for this specific index

Read the `Covers queries` field before creating — if a suggestion only appears in one plan file and that plan runs once a day, weigh the Impact score against the write overhead on a high-write table.

### Skipped / Flagged Section

Suggestions that were not converted to DDL:
- **Too wide** — review manually, split by query
- **Overlaps existing index** — verify with `sys.indexes` before creating; the existing index may already cover the pattern with minor extension

### Deployment Script

The final `CREATE INDEX` block is in ranked order — deploy top to bottom. Each statement includes `WITH (ONLINE = ON, SORT_IN_TEMPDB = ON)`:

- `ONLINE = ON` — allows reads and writes during index build (requires Enterprise edition or SQL 2016+ Standard for some cases)
- `SORT_IN_TEMPDB = ON` — uses TempDB for sort runs during build, reducing contention on the data filegroup

Remove `ONLINE = ON` if the edition doesn't support it or if the table has LOB columns (xml, varchar(max), etc.).

**Always test in a non-production environment first.** New indexes can cause plan regressions for other queries on the same table by changing the optimizer's access path choices.
