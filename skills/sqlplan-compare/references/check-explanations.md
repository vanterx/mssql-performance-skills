# sqlplan-compare — Checks Explained

## Contents

- [When to Use Compare vs Review](#when-to-use-compare-vs-review)
- [Key Concepts](#key-concepts)
- [Comparison Checks (C1–C10)](#comparison-checks-c1c10)
- [Regression Root Cause Checks (C11–C20)](#regression-root-cause-checks-c11c20)
- [Reading the Output](#reading-the-output)

---


A plain-English guide to everything the comparison skill does: when to use it, how it reads plans, and what each of the twenty regression checks (C1–C20) actually means.

---

## When to Use Compare vs Review

Use `/sqlplan-review` when you have **one plan** and want to know what's wrong with it.

Use `/sqlplan-compare` when you have **two plans for the same query** and want to know what *changed* between them. Typical triggers:

- A deployment (schema change, new code, index added or dropped) made a query slower
- A statistics update or maintenance job changed plan shapes overnight
- A SQL Server or compatibility-level upgrade produced different plans
- You want to prove to a colleague that the plan was better before a specific change

The skill needs two plans for the **same query** — comparing plans for different queries produces meaningless output.

---

## Key Concepts

### Baseline vs New

The **baseline** is the known-good plan — the one that ran well before the regression. The **new plan** is the current, slower one.

If you don't have the baseline plan file, check:
- Query Store: `sys.query_store_plan` — stores historical plans per query
- Plan cache: `sys.dm_exec_cached_plans` — plans currently in cache (may have been evicted)
- Extended Events session captures from before the change

### Estimated vs Actual Plans

An **estimated plan** has no runtime statistics — no actual row counts, elapsed times, or confirmed spills. An **actual plan** (captured with Ctrl+M in SSMS) has all of these.

When comparing:
- Checks C1, C2, C9, C10 fire on estimated plans
- Checks C3, C4, C6 are more meaningful on actual plans (memory used, confirmed spill)
- If one plan is estimated and the other actual, note this — runtime-dependent metrics can't be directly compared

### Why Join Types Matter

The optimizer chooses a join strategy based on estimated row counts:

| Join type | Best for | Chosen when optimizer thinks… |
|-----------|----------|-------------------------------|
| Nested Loops | Small outer input | Inner side is small, or outer side tiny |
| Hash Match | Large, unsorted inputs | Both sides are large |
| Merge Join | Pre-sorted inputs | Both sides sorted on join key |

A change from **Hash Match → Nested Loops** on a large table is almost always a regression — it means the optimizer now thinks fewer rows are involved than actually are. This is C2.

---

## Comparison Checks (C1–C10)

### C1 — Seek Degraded to Scan

**What changed:** A table that was accessed via an Index Seek in the baseline is now being scanned (Index Scan or Table Scan).

**Why this causes a slowdown**  
An Index Seek navigates the B-tree directly to the matching rows — O(log n) I/O. A Scan reads every leaf page — O(n) I/O. On a 10-million-row table, this is the difference between reading 3 pages and reading 80,000 pages.

**Common causes**
- The index was dropped
- An implicit data type conversion was introduced (e.g., the column is `INT` but the parameter is now `VARCHAR`) — the optimizer can't seek across a type mismatch
- Statistics changed enough that the optimizer decided a scan was cheaper (rare but possible on very low-selectivity predicates)
- A new query hint forced a scan

**Fix**  
Identify which index was used in the baseline (visible in the tooltip on the old Seek operator). Check if it still exists: `SELECT * FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.YourTable')`. If it was dropped, recreate it. If a type mismatch was introduced, fix the parameter type to match the column.

---

### C2 — Hash Join Degraded to Nested Loops on Large Table

**What changed:** A join that used Hash Match in the baseline now uses Nested Loops, and the probe side has more than 10,000 actual rows.

**Why this causes a slowdown**  
Hash Match scans both inputs once and builds a hash table — O(n + m). Nested Loops scans the inner side once per outer row — O(n × m). When n = 100,000 and m = 1,000, Nested Loops does 100 million inner lookups vs Hash Match's 101,000 reads.

**Common causes**  
The optimizer chose Nested Loops because it now estimates fewer rows than actually arrive. This is almost always a **cardinality error** — stale statistics, parameter sniffing, or a row-reducing filter that was removed.

**Fix**  
Update statistics on the tables involved: `UPDATE STATISTICS dbo.Table WITH FULLSCAN`. If parameter sniffing is the cause, add `OPTION (RECOMPILE)` temporarily to verify — if the plan reverts to Hash Match with recompile, sniffing is confirmed.

---

### C3 — Memory Grant Inflated > 2×

**What changed:** The new plan requests more than twice the memory the baseline needed.

**Why this is a problem**  
Memory grants are reserved before execution begins. An oversized grant blocks other queries from getting their grants — they queue on `RESOURCE_SEMAPHORE` waits. On a busy server, doubling one query's grant can cascade into a queue of waiting queries.

**Common causes**  
The optimizer now estimates more rows flowing through Sort or Hash operators than before. This is typically caused by a statistics update that overcorrected, or parameter sniffing picking up an outlier execution.

**Fix**  
Check if the new row estimates are accurate (compare estimated vs actual rows in the new plan's Sort/Hash operators). If estimates are inflated, the root cause is in the statistics or parameters — not the grant itself. Use `OPTION (OPTIMIZE FOR ...)` to pin the grant to a representative value.

---

### C4 — Memory Grant Deflated > 2× (Spill Risk)

**What changed:** The new plan requests less than half the memory the baseline needed, and the query used more memory than it was granted.

**Why this causes a slowdown**  
An undersized grant means Sort or Hash operators run out of memory mid-execution and spill overflow data to TempDB. Disk I/O is typically 100× slower than memory. A sort that took 50ms in the baseline can take 5 seconds when spilling.

**Common causes**  
The optimizer now underestimates rows — the opposite of C3. Statistics that were updated to reflect a filtered sample, or a new parameter value that sniffs a low-selectivity path, can deflate estimates dramatically.

**Fix**  
Confirm spilling by checking `MaxUsedMemory > GrantedMemory` in the actual plan's `MemoryGrantInfo`. Then fix the estimate: update statistics, or use `OPTION (MIN_GRANT_PERCENT = N)` as a temporary floor while investigating root cause.

---

### C5 — Parallelism Lost

**What changed:** The baseline ran with DOP > 1 (parallel) and the new plan runs serially (DOP = 1).

**Why this causes a slowdown**  
For expensive queries, parallel execution distributes work across multiple CPU threads. Losing parallelism on a query that costs 10 seconds on one thread means it now takes 10 seconds instead of 2.5 (at DOP 4).

**Common causes** (check `NonParallelPlanReason` attribute in the plan XML)
- A `MAXDOP 1` hint was added to the query or procedure
- A scalar UDF was introduced — scalar UDFs always prevent parallelism
- A table variable replaced a temp table — table variables block parallel plans in most cases
- The cost threshold for parallelism was raised above this query's estimated cost

**Fix**  
Read the `NonParallelPlanReason` in the new plan XML. If `MaxDOPSetToOne`, find and remove the hint. If `TSQLUserDefinedFunctionsNotParallelizable`, rewrite the scalar UDF as an inline TVF.

---

### C6 — New Spill to TempDb

**What changed:** The new plan has a confirmed `SpillToTempDb` entry that did not exist in the baseline.

**Why this causes a slowdown**  
See C4 — spilling to TempDB is 100× slower than in-memory operation. This check fires on confirmed actual spills (not just risk), so it is definitive evidence of a performance problem.

**Fix**  
Identify the spilling operator (Sort or Hash Match) and its estimated vs actual row counts. If estimates are severely wrong, fix root-cause statistics or parameter sniffing. If estimates are correct but the grant is still too small, increase the minimum grant with `Resource Governor` or `OPTION (MIN_GRANT_PERCENT)`.

---

### C7 — New Key Lookup Introduced

**What changed:** A Key Lookup (or RID Lookup) operator appears in the new plan but was not present in the baseline.

**Why this causes a slowdown**  
A Key Lookup means a nonclustered index seek found matching rows but had to make a second trip to the clustered index (PK) to fetch columns not stored in the NC index. Each lookup is a random I/O. At scale (thousands of lookups), this dominates plan cost.

**Common causes**  
- The baseline used a different, wider index that included the needed columns
- A column was added to the SELECT list after the index was designed
- The query was rewritten to join a new column from the same table

**Fix**  
Add the missing column(s) to the NC index as INCLUDE columns:
```sql
CREATE INDEX IX_Orders_CustomerId
ON dbo.Orders (CustomerId)
INCLUDE (Status, TotalAmount)   -- add the columns being looked up
WITH (ONLINE = ON)
```

---

### C8 — New High-Impact Missing Index Suggestion

**What changed:** The new plan contains a missing index suggestion (Impact > 50) that was not present in the baseline.

**Why this matters**  
The optimizer generates missing index suggestions when it encounters an access pattern with no suitable index. Impact > 50 means the optimizer estimates this index would reduce the query's cost by more than 50%. A new suggestion that didn't exist in the baseline means either the query changed, the data distribution changed, or an index was dropped.

**Fix**  
Evaluate the suggestion (don't blindly create it — see the `sqlplan-index-advisor` skill for consolidation). Check if a similar index already exists that could be extended with INCLUDE columns before creating a new one.

---

### C9 — Sort Operator Added

**What changed:** A Sort operator appears in the new plan consuming ≥ 10% of plan cost, but was not present in the baseline.

**Why this causes a slowdown**  
A Sort must consume all input rows before producing any output — it's a blocking operator. It also requires a memory grant sized for all rows. Adding a Sort to a plan that previously avoided it means the new plan can no longer use pre-ordered data from an index.

**Common causes**  
- An index that provided pre-sorted data was dropped
- An ORDER BY was added to the query
- A join strategy change (Hash Join → Merge Join requires both inputs sorted)

**Fix**  
Check what column(s) the Sort is ordering on. If an index on those columns existed in the baseline and was dropped, recreate it. If the sort appeared due to a join strategy change, investigate whether the join strategy change (C2) is the root cause.

---

### C10 — Cardinality Model Downgraded

**What changed:** The `CardinalityEstimationModelVersion` in the new plan is lower than in the baseline.

**Why this matters**  
SQL Server uses different cardinality estimation (CE) algorithms depending on the database compatibility level. CE 70 (SQL 7.0) through CE 160 (SQL 2022) represent successive improvements. A downgrade means plans are being compiled under an older, less accurate CE — typically producing worse join orders and more cardinality errors.

**Common causes**  
- Database compatibility level was lowered (sometimes done as a "rollback" after a SQL Server upgrade)
- The query was executed in a different database context (e.g., a linked server query compiled under the remote server's compat level)
- A `USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION')` hint was added

**Fix**  
Check `SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()`. If it was recently lowered, restore it after testing. If the compat level is correct but CE is still downgraded, look for `QUERYTRACEON 9481` or the legacy CE hint in the query text.

---

## Reading the Output

### Summary Table

The first thing to check. Look at the **Change** column:
- A cost increase > 50% with no clear operator explanation = look for C10 (CE model change) or C5 (lost parallelism)
- Memory grant change > 2× = check C3 or C4 immediately
- New spills = always Critical, go to C6 first

### Regression Findings

Each finding is labeled R1, R2, etc. in order of severity (Critical first). Read:
- **Was / Now** — the before/after values that triggered the check
- **Impact** — why this specific change causes the observed slowdown
- **Fix** — the concrete action, specific to what changed

### Unchanged (Confirmed Stable)

This section lists operators and metrics that are identical in both plans. It narrows the search space — if a table's access method is confirmed unchanged, that table is not the problem.

### Recommended Fix Order

Follow this order strictly — fixing C1 (seek → scan) often also resolves C6 (new spill) and C3 (inflated grant) because they share a root cause in cardinality errors.

---

## Regression Root Cause Checks (C11–C20)

### C11 — Adaptive Join Threshold Changed

**What changed:** The `AdaptiveThresholdRows` value on an Adaptive Join operator differs between baseline and new plan — SQL 2017+.

**Why this matters**
The threshold is the row count at which SQL Server switches between Nested Loops and Hash Join at runtime. If the threshold itself changed (not just which side was chosen), the cardinality estimate that sets it changed at compile time. A lower threshold makes Hash Join less likely to be chosen; a higher threshold makes it more aggressive.

**Common causes**
Statistics update changed the estimated row count for the build side; parameter sniffing caused compilation under a different row estimate; a schema change (column added/removed) affected the cost model.

**Fix**
Verify the threshold makes sense against actual row counts. If the new threshold causes the wrong join type to be chosen at runtime, the root cause is a cardinality error — fix statistics or sniffing, not the join hint. Related: C2 (join type changed), C14 (row divergence).

---

### C12 — Batch Mode Lost

**What changed:** Baseline plan used batch-mode execution (`executionMode="Batch"` on one or more operators); the new plan executes entirely in row mode — SQL 2017+ (Columnstore), SQL 2019+ (Batch Mode on Rowstore).

**Why this causes a slowdown**
Batch mode processes 64–900 rows per CPU instruction rather than one at a time. For aggregation, sort, and hash join operators over large row sets, batch mode typically delivers 5–10× higher throughput than row mode. Losing it on a large scan or hash join can multiply elapsed time significantly.

**Common causes**
- A columnstore index was dropped (batch mode on Columnstore required it)
- `DISABLE_BATCH_MODE_ON_ROWSTORE` hint was added (SQL 2019+)
- Database compat level was lowered below 150, disabling Batch Mode on Rowstore
- A scalar UDF was introduced — scalar UDFs block batch mode
- An operator incompatible with batch mode (certain XML, spatial, or CLR operations) was added

**Fix**
Identify which compat-level or hint change disabled batch mode. If a compat level drop is responsible, restore it. If a scalar UDF is blocking, rewrite it as an inline TVF.

---

### C13 — New Implicit Conversion Warning

**What changed:** A `PlanAffectingConvert` element appears in the new plan but was absent from the baseline. This signals that SQL Server is implicitly converting a data type, which makes an index predicate non-sargable.

**Why this causes a slowdown**
A non-sargable predicate cannot use an index seek — the engine must scan the entire index and apply the conversion row-by-row. This turns an O(log n) seek into an O(n) scan. Related: C1 (seek degraded to scan) often has C13 as its root cause.

**Common causes**
- A parameter or variable type was changed (e.g., `INT` → `VARCHAR`)
- A column was `ALTER`ed to a different type
- A new `CONVERT()` or `CAST()` wraps the column in the WHERE clause
- A function was applied to the column side of a predicate

**Fix**
Match the parameter/variable type exactly to the column definition. Remove any function applied to the column in the predicate. If the column itself changed type, evaluate whether the old indexes need to be rebuilt or repopulated.

---

### C14 — Estimated vs Actual Row Divergence Worsened

**What changed:** The maximum `actualRows / estimateRows` ratio across all plan operators (with `actualRows > 100`) increased by more than 10× between plans. Requires actual execution plans — not available on estimated plans.

**Why this matters**
Cardinality errors compound: an underestimate at one join leads to the wrong join type, which causes a spill, which triggers a serial plan. Measuring the divergence ratio across all operators reveals whether the new plan has materially worse cardinality quality than the baseline, even if individual checks (C2, C3) didn't fire.

**Common causes**
Statistics quality degraded (auto-update missed a large data change); a parameter value changed causing sniffing to compile for a skewed value; a predicate was changed to reference a correlated column pair the CE doesn't model well.

**Fix**
`UPDATE STATISTICS` with `FULLSCAN` on the tables with the highest divergence. If sniffing is suspected, add `OPTION (RECOMPILE)` temporarily — if the ratio drops, sniffing is confirmed. Related: C2, C3, C4.

---

### C15 — Compile CPU Regression

**What changed:** The `CompileCPU` attribute in the new plan is more than 3× the baseline value.

**Why this matters**
Compile CPU is the time the optimizer spent searching for a good plan. A large increase means the optimizer is working much harder — either the query became more complex, the schema it references grew, or the optimizer is timing out and falling back to a suboptimal plan. In high-concurrency environments, excessive compile time also holds shared compile locks.

**Common causes**
- Additional joins or subqueries added to the query
- A view was expanded and now resolves many more base tables
- Optimizer timeout (plan complexity exceeded the cost threshold) — check `StatementOptmEarlyAbortReason="TimeOut"` in the plan XML

**Fix**
Check for `StatementOptmEarlyAbortReason="TimeOut"` — if present, the optimizer gave up early. Simplify the query, break it into stages, or use indexed views to pre-aggregate expensive joins.

---

### C16 — Plan Guide or Forced Plan Introduced

**What changed:** A `PlanGuideName` attribute appears in the new plan, indicating a plan guide is shaping the execution plan. It was absent from the baseline.

**Why this matters**
Plan guides override the optimizer's natural choices. The forced plan may be the right fix, but it also freezes the plan shape — future statistics updates, index changes, or data growth will not improve the plan. If the forced plan itself was created during an incident and is suboptimal, this check surfaces it.

**Common causes**
A DBA applied a plan guide (`sp_create_plan_guide`) or used Query Store plan forcing after noticing a regression. The guide addresses the symptom but may not have fixed the underlying cardinality or index issue.

**Fix**
Verify the forced plan is still optimal by running the query with `OPTION (RECOMPILE)` and comparing to the forced shape. If the optimizer now finds a better plan naturally, remove the guide and fix the root cause (statistics, indexes, or type mismatch). Related: C1, C2, C13.

---

### C17 — New Eager Index Spool

**What changed:** An `Eager Index Spool` operator appears in the new plan but was not present in the baseline.

**Why this causes a slowdown**
An Eager Index Spool materializes all input rows into a temporary index structure in TempDB before any rows are returned. It is a full blocking operator that consumes significant I/O and memory. The optimizer chooses it when no permanent index matches the query's access pattern — it's the last resort before a full scan.

**Common causes**
A permanent index that the baseline used was dropped. Alternatively, a new join or filter condition was added to the query that no existing index covers.

**Fix**
Identify the columns the spool is indexing (visible in the node's Properties tooltip). Create a permanent nonclustered index on those columns. Use `/sqlplan-index-advisor` to generate the DDL. Related: C7 (Key Lookup), C9 (Sort added).

---

### C18 — Partition Elimination Lost

**What changed:** The new plan accesses more partitions than the baseline for the same partitioned table, despite using the same filter predicate. Applies to partitioned tables — SQL 2005+.

**Why this matters**
Partition elimination reduces I/O by scanning only the partitions that can contain matching rows. Losing it means the engine scans all partitions. On a 24-month partitioned table where the query filters on the current month, losing elimination means 24× the I/O.

**Common causes**
- The partition key column's data type was changed — the predicate no longer aligns with the partition function's input type, disabling elimination
- A parameter type was changed, introducing an implicit conversion on the partition key (related: C13)
- A computed partition key column was altered

**Fix**
Ensure the filter predicate's data type exactly matches the partition function's boundary type. Check for implicit conversions with C13. If the partition function itself changed, review whether the boundaries still reflect the query's filtering patterns.

---

### C19 — Parameter Sensitive Plan Dispatcher Added

**What changed:** A `ParameterSensitivePredicate` dispatcher node appears in the new plan, indicating SQL Server 2022 PSP optimization created a dispatcher plan with multiple variants. This node was absent in the baseline — SQL 2022+ only.

**Why this matters**
PSP optimization is generally beneficial — it creates separate plans for different parameter value ranges to handle data skew. However, if the threshold boundaries are poorly calibrated, the wrong variant may be selected at runtime, producing a worse plan than the original single plan would have.

**Common causes**
SQL Server 2022 PSP optimization activated after detecting significant cardinality skew on a parameter predicate. The optimization is enabled automatically at compat level 160.

**Fix**
Verify the variant boundaries using `sys.query_store_query_variant`. If a specific parameter range is receiving the wrong variant, use Query Store hints to force a specific variant for that range, or adjust compat settings. Related: C14 (row divergence in variants).

---

### C20 — New Cross-Database or Linked Server Access

**What changed:** The new plan references a four-part name (`server.db.schema.table`) or a linked server operator that was absent from the baseline.

**Why this causes a slowdown**
Cross-database and linked server queries cannot fully participate in local optimization. Join order, statistics, and index selection for the remote table are limited — the optimizer must often choose sub-optimal strategies because it lacks row count and distribution data for the remote object.

**Common causes**
- A view was modified to join a table in another database
- A stored procedure was updated to call a linked server
- The query was refactored to reference a cross-database synonym
- A database rename or migration moved a table to a different database

**Fix**
Evaluate whether the cross-database access can be replaced with a local copy (materialized via a staging table or indexed view). If the linked server is required, ensure statistics are updated on the remote side and consider using `OPENQUERY` to push more of the filter to the remote server before joining locally.
