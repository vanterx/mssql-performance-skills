# SQL Server Statistics IO/Time Checks — Explained for All

## Contents

- [Before You Start: Key Concepts](#before-you-start-key-concepts)
- [IO Checks (I1–I18)](#io-checks-i1i18)
- [Time Checks (W1–W9)](#time-checks-w1w9)
- [Quick Reference: Checks by Severity](#quick-reference-checks-by-severity)
- [Example Input and Expected Output](#example-input-and-expected-output)
- [Statistics IO/Time Analysis](#statistics-iotime-analysis)

---


A detailed guide to every check the analyser performs on `SET STATISTICS IO, TIME ON` output.
This guide covers 27 checks (I1–I18 IO checks, W1–W9 time checks).
Each entry explains what the check means, why it matters, how to spot it, real-world examples, and multiple fix options ranked by impact.

---

## Before You Start: Key Concepts

### What is SET STATISTICS IO, TIME ON?

Running `SET STATISTICS IO, TIME ON` before a query instructs SQL Server to report, after execution:

- **STATISTICS IO**: How many page reads were performed for each table/index involved in the query
- **STATISTICS TIME**: How long compilation and execution took (CPU time and wall-clock elapsed time)

These numbers are the ground truth of what actually happened at the storage and scheduling layers. An execution plan tells you what SQL Server *planned*; STATISTICS IO tells you what it *did*.

Enable in SSMS with:
```sql
SET STATISTICS IO, TIME ON;
GO
-- your query here
SET STATISTICS IO, TIME OFF;
```

### What is a logical read?

SQL Server manages data in 8 KB **pages**. A logical read is reading one page from the **buffer pool** (in-memory cache). This is fast — sub-microsecond. A physical read is reading one page from disk — milliseconds.

- **Logical reads**: Total pages accessed, from cache. The primary I/O cost metric.
- **Physical reads**: Pages that were not in cache and had to be read from disk.
- **Read-ahead reads**: Pages the storage engine prefetched sequentially, before they were requested — a signal of scanning behavior.

Every physical read is also a logical read. Every read-ahead read eventually becomes a logical read.

### What is a scan count?

Scan count is how many times SQL Server initiated a scan or seek on a table or index. A scan count of 1 means the table was accessed once (normal for a simple query). A scan count of 10,000 means the table was accessed 10,000 times — typically because it is the inner side of a Nested Loops join that runs 10,000 iterations.

High scan count is one of the clearest indicators of a missing index on a frequently-joined table.

### Worktable and Workfile

`Worktable` and `Workfile` are internal SQL Server work structures created in `tempdb`:
- **Worktable**: Created for sorts, hash joins, hash aggregates, or eager spools that exceeded their memory grant
- **Workfile**: Created for hash operations that spilled to disk

Seeing these in STATISTICS IO output means SQL Server ran out of memory mid-operation and wrote to disk. This is called a **spill** and dramatically slows query execution.

### LOB reads

**LOB** (Large Object) data — `text`, `ntext`, `image`, `varchar(max)`, `nvarchar(max)`, `xml`, `varbinary(max)` — is stored on separate pages from the main row. LOB logical reads count accesses to these overflow pages. High LOB reads relative to standard logical reads means the query is reading large text or binary data extensively.

### Segment reads and segment skipped

These appear only for **columnstore indexes**. A columnstore index stores data in compressed column segments of ~1 million rows each. SQL Server can skip entire segments using min/max metadata if the query predicate doesn't overlap the segment's value range.

- **Segment reads**: Segments that had to be decompressed and scanned
- **Segment skipped**: Segments eliminated without reading (free performance)

A high skip rate is good. A low skip rate means the predicate isn't filtering at the segment level.

### CPU time vs elapsed time

SQL Server reports two time dimensions:
- **CPU time**: Total processor time consumed (sum across all threads for parallel queries)
- **Elapsed time**: Wall-clock time from start to finish

If `CPU > Elapsed`: The query ran in parallel — CPU time is the sum across threads.
If `CPU << Elapsed`: The query spent most of its time waiting — for I/O, locks, or network.
If `CPU ≈ Elapsed`: Single-threaded execution, fully CPU-bound.

---

## IO Checks (I1–I18)

---

### I1 — High Logical Read Count

**What it means**
The query performed a large number of page reads from the buffer pool within a single statement. Each logical read is one 8 KB page. 1,000,000 logical reads = approximately 8 GB of data accessed.

**Why it matters**
Even though logical reads come from RAM (fast), they are not free: they consume CPU cycles for buffer pool locking, add pressure on the buffer pool (evicting other useful pages), and indicate more data was scanned than necessary. High logical reads slow the entire server, not just this query.

**How to spot it**
```
Table 'Orders'. Scan count 1, logical reads 1047520, physical reads 0, read-ahead reads 1042310, ...
Table 'Customers'. Scan count 1, logical reads 48230, physical reads 0, read-ahead reads 0, ...
```
Statement total: 1,095,750 logical reads → triggers I1 (Warning, ≥ 1,000,000)

**Example — problem**
```sql
-- Missing index causes a full scan on a 10M-row table
SELECT * FROM dbo.Orders WHERE Status = 'Pending' AND Region = 'EMEA';
-- Output: Table 'Orders'. Scan count 1, logical reads 1,204,180, ...
```

**Example — fix**
```sql
-- Add a covering index
CREATE NONCLUSTERED INDEX IX_Orders_Status_Region
ON dbo.Orders (Status, Region)
INCLUDE (OrderId, CustomerId, OrderDate, Total);

-- After: Table 'Orders'. Scan count 1, logical reads 312, ...
```

**Fix options (ranked by impact)**
1. Add a covering index on the highest-read table — use `/sqlplan-index-advisor` for the DDL.
2. Add predicates to the query to filter earlier (reduce rows scanned).
3. Move computation to a pre-aggregated summary table or indexed view.

**Related checks:** I2 (scan count), I4 (read-ahead), I5 (single table dominance), W4 (long elapsed)

---

### I2 — Excessive Scan Count

**What it means**
A table was accessed thousands of times within one statement. This is the I/O fingerprint of the inner side of a Nested Loops join: SQL Server seeks or scans the inner table once for every row from the outer input.

**Why it matters**
If scan count is 50,000 and each access reads 3 pages, that's 150,000 logical reads that could be eliminated by adding an index, reducing the 50,000 seeks to 1 (or a few range seeks). This is one of the most impactful fixes in SQL Server tuning.

**How to spot it**
```
Table 'OrderLines'. Scan count 48291, logical reads 144873, ...
```
Scan count 48,291 means the table was accessed 48,291 times — once per row from the outer input (likely `Orders`).

**Example — problem**
```sql
-- No index on OrderLines.OrderId; Nested Loops does a scan per outer row
SELECT o.OrderId, SUM(ol.LineTotal) AS Total
FROM dbo.Orders o
JOIN dbo.OrderLines ol ON ol.OrderId = o.OrderId
WHERE o.Status = 'Open'
GROUP BY o.OrderId;
-- Output: Table 'OrderLines'. Scan count 12845, logical reads 2,568,900
```

**Example — fix**
```sql
-- Add index on the FK column; Nested Loops now seeks instead of scans
CREATE NONCLUSTERED INDEX IX_OrderLines_OrderId
ON dbo.OrderLines (OrderId)
INCLUDE (LineTotal);

-- After: Table 'OrderLines'. Scan count 12845, logical reads 25,690 (99% reduction)
```

**Fix options**
1. Add an index on the join/seek column of the high-scan-count table (most impactful).
2. If the nested loops approach is suboptimal, restructure the query to encourage a Hash or Merge join (add statistics, or hint the join type) — but first try the index.
3. Reduce the outer input row count to reduce inner scan iterations.

**Related checks:** I1 (total logical reads), I5 (single table dominance), W4 (long elapsed)

---

### I3 — High Physical Read Ratio

**What it means**
A significant portion of logical reads required a disk read because the pages were not in the buffer pool (RAM cache). Physical reads are 100–1,000× slower than logical reads.

**Why it matters**
On a production system with a warm buffer pool, physical reads should be near zero for frequently-accessed tables. Persistent physical reads indicate the buffer pool is too small for the working set, or the table is rarely accessed.

**How to spot it**
```
Table 'ArchiveOrders'. Scan count 1, logical reads 812, physical reads 194, ...
```
physical / logical = 194 / 812 = 23.9% → triggers I3 (≥ 10%)

**Example — problem scenario**
- First execution after DBCC DROPCLEANBUFFERS or SQL Server restart: always physical reads (expected, benign)
- Repeated physical reads on a core transactional table: buffer pool too small

**Fix options**
1. **Reduce logical reads first** (I1, I2) — fewer pages needed = fewer physical reads = lower RAM requirement.
2. **Add RAM** to the SQL Server instance to expand the buffer pool.
3. **Check buffer pool allocation** with `sys.dm_os_buffer_descriptors` — identify which databases/objects consume the most buffer pool.
4. If the table is archival/rarely accessed, physical reads may be acceptable — document this.

**Related checks:** I1 (total logical reads), I4 (read-ahead pattern), W1 (I/O wait)

---

### I4 — Read-Ahead Dominant Pattern (Full Scan Signal)

**What it means**
Read-ahead reads are pages the SQL Server storage engine prefetched **sequentially** before they were requested — a mechanism optimized for full scans. When read-ahead reads approach the total logical read count, it means almost all pages were fetched as a sequential scan rather than a seek.

**Why it matters**
Read-ahead is efficient for scans but is a signal that a scan happened instead of a seek. An index seek would not trigger significant read-ahead because it only reads specific pages, not sequential pages.

**How to spot it**
```
Table 'Products'. Scan count 1, logical reads 24,150, physical reads 0, read-ahead reads 23,816, ...
```
read-ahead / logical = 23,816 / 24,150 = 98.6% → triggers I4

**Example — problem**
```sql
-- Full scan because predicate uses function on indexed column
SELECT ProductId FROM dbo.Products WHERE YEAR(CreatedDate) = 2024;
-- read-ahead: 23,816 of 24,150 logical reads (scanned the entire table)
```

**Example — fix**
```sql
-- Range predicate enables index seek; no read-ahead
SELECT ProductId FROM dbo.Products
WHERE CreatedDate >= '2024-01-01' AND CreatedDate < '2025-01-01';
-- After: logical reads: 18, read-ahead: 0
```

**Fix options**
1. Rewrite the predicate to be sargable (see `/tsql-review` T4, T6).
2. If a full scan is unavoidable (no selective predicate), the read-ahead is helping — note it as expected behavior.

**Related checks:** I2 (scan count), I1 (total reads), T4 (non-sargable predicate in `/tsql-review`)

---

### I5 — Single Table Dominates Logical Reads

**What it means**
One table is responsible for 80% or more of the total logical reads in the statement. All other tables combined contribute less than 20%.

**Why it matters**
This focuses the tuning effort. There is no value optimizing a table that contributes 2% of reads. The dominant table is the highest-leverage target for index additions or query rewrites.

**How to spot it**
```
Table 'OrderLines'. Scan count 1, logical reads 950,240, ... → 92% of statement reads
Table 'Orders'. Scan count 1, logical reads 84,210, ...     → 8%
```

**Fix options**
1. Use `/sqlplan-review` and `/sqlplan-index-advisor` targeting the dominant table.
2. Check I2 (scan count) and I4 (read-ahead) for the dominant table — the type of reads gives direction.
3. If the dominant table is `Worktable` or `Workfile`, see I6.

**Related checks:** I1 (total reads), I2 (scan count), I6 (worktable)

---

### I6 — Worktable or Workfile Detected

**What it means**
SQL Server created a temporary work structure in `tempdb` — a Worktable for sorts, hash joins, hash aggregates, or eager spools; a Workfile for hash operations that spilled to disk. This means the operator exceeded its allocated memory grant and overflowed to disk.

**Why it matters**
tempdb I/O is physical disk I/O — orders of magnitude slower than in-memory operations. A spill that adds 50,000 Worktable logical reads means SQL Server read 50,000 × 8 KB = 400 MB of data from tempdb during the query.

This corresponds to checks N41–N43 in `sqlplan-review` (Confirmed Spill).

**How to spot it**
```
Table 'Worktable'. Scan count 4, logical reads 182,140, ...
```

**Example — fix strategies**
1. **Update statistics** — stale statistics cause bad row estimates → wrong memory grants → spills.
2. **Add an index** to reduce input rows entering the sort/hash (reduces grant needed).
3. **Use `OPTION (MIN_GRANT_PERCENT = n)`** to request a larger memory grant.
4. **Switch algorithm**: if a hash join is spilling, an indexed merge join might not need to materialize at all.

**Related checks:** I1 (total reads), W4 (long elapsed), sqlplan-review N41 (confirmed spill)

---

### I7 — Temporary Table in IO Output

**What it means**
An explicit local (`#table`) or global (`##table`) temp table appears in the IO output. This is usually expected when temp tables are deliberately used as intermediate steps.

**Why it matters**
Temp tables are frequently misused: table variables (`@table`) have no statistics (see `/tsql-review` T46), while explicit temp tables have statistics but require careful index management. Seeing a temp table in IO output is a prompt to verify its statistics and indexes are adequate.

**How to spot it**
```
Table '#WorkingSet'. Scan count 3, logical reads 8,420, ...
```

**Fix options**
1. Ensure an index exists on the temp table's join column: `CREATE INDEX IX_#WorkingSet_CustomerId ON #WorkingSet(CustomerId)`.
2. Verify statistics are up to date by inserting before creating indexes, or using `UPDATE STATISTICS #WorkingSet`.
3. If the temp table reads are high, consider materializing with less data (filter before INSERT).

**Related checks:** `/tsql-review` T45 (no explicit column definition), T46 (table variable for large data)

---

### I8 — LOB Reads Present

**What it means**
`lob logical reads > 0` means the query accessed Large Object storage pages — separate overflow pages used by `varchar(max)`, `nvarchar(max)`, `xml`, `text`, `ntext`, `image`, `varbinary(max)`, or JSON stored in `nvarchar(max)`.

**Why it matters**
LOB pages are not stored inline with the row (for values > 8,000 bytes in varchar/nvarchar, or always for deprecated text/ntext/image types). Each LOB column access may require multiple additional page reads beyond the main row page.

**How to spot it**
```
Table 'Documents'. Scan count 1, logical reads 4,210, lob logical reads 48,190, ...
```

**Fix options**
1. Replace `SELECT *` with an explicit column list that excludes unneeded LOB columns (`/tsql-review` T1).
2. Store frequently-filtered metadata (titles, dates, flags) in regular columns; keep LOB columns for content-only retrieval.
3. Consider `FILESTREAM` or `FileTable` for binary data; consider `COMPRESS()` for compressible text.

**Related checks:** I9 (LOB reads dominant), T1 (SELECT * in `/tsql-review`)

---

### I9 — LOB Reads Dominant

**What it means**
LOB logical reads exceed 50% of total logical reads for a table. Most of the I/O for this table is large-object data access, not row data.

**Why it matters**
When LOB I/O dominates, the entire I/O profile of the query is driven by the size and number of LOB values accessed. Standard indexing on non-LOB columns does not reduce LOB page access.

**How to spot it**
```
Table 'Articles'. Scan count 1, logical reads 2,100, lob logical reads 9,840, ...
```
lob / logical = 9,840 / (2,100 + 9,840) = 82.4% → triggers I9

**Fix options**
1. Restructure the query to not fetch LOB content unless needed (separate the retrieval into two queries: one for metadata, one for content).
2. Consider XML indexes for frequently-queried XML columns.
3. For JSON: store commonly-queried JSON fields in regular computed persisted columns and index them.

**Related checks:** I8 (LOB reads present), I1 (total reads)

---

### I10 — Columnstore Segment Skip Rate Low

**What it means**
For a columnstore-indexed table, segment elimination — the process of skipping entire row-group segments using min/max metadata — is less than 50% effective. More than half of all segments had to be scanned.

**Why it matters**
Columnstore indexes achieve their performance through: (1) column-only access, (2) compression, and (3) segment elimination. When segment elimination fails, the columnstore index still reads far more data than necessary, losing its primary analytical performance advantage.

**How to spot it**
```
Table 'SalesFact'. Scan count 1, logical reads 4,812, segment reads 320, segment skipped 140, ...
```
Skip rate = 140 / (320 + 140) = 30.4% → triggers I10

**Common causes**
- Data was loaded in an order unrelated to the filter column (e.g., filtered by `Region` but data is loaded in `OrderDate` order)
- High cardinality within segments (many distinct values → poor min/max pruning)

**Fix options**
1. **Rebuild the columnstore index** after bulk-loading data in an order related to the primary filter column (cluster data by date or region before loading).
2. **Add a clustered rowstore index** on the filter column, then rebuild the columnstore — this pre-orders rows by the filter column.
3. **Use partition elimination** — partition the table by the filter column (e.g., by year) and use partition pruning.

**Related checks:** I11 (high skip rate — good pattern), I1 (total logical reads)

---

### I11 — Columnstore Segment Skip Rate High (Good Pattern)

**What it means**
90%+ of columnstore segments were eliminated without reading — the query predicate is highly effective at pruning columnstore data at the segment level.

**Why it matters**
This is a well-tuned columnstore query. Document this as confirmation that the columnstore index is correctly structured for this workload.

**How to spot it**
```
Table 'SalesFact'. Scan count 1, logical reads 240, segment reads 3, segment skipped 58, ...
```
Skip rate = 58 / (3 + 58) = 95.1% → triggers I11

**No fix required.** Note this as a positive pattern in the report.

**Related checks:** I10 (low skip rate), I1 (total logical reads)

---

### I12 — Same Table Appears Multiple Times in Statement

**What it means**
The same table name appears more than once in the IO output for a single statement. SQL Server accessed the table through multiple separate scans or seeks within the same query.

**Why it matters**
Multiple accesses to the same table in one query often indicate: a CTE referenced more than once (which re-executes the CTE — see `/tsql-review` T24), multiple explicit joins to the same table, or a self-join. Each occurrence adds independent I/O cost.

**How to spot it**
```
Table 'Customers'. Scan count 1, logical reads 8,410, ...
Table 'Orders'. Scan count 1, logical reads 42,190, ...
Table 'Customers'. Scan count 1, logical reads 8,410, ...   ← same table, second access
```

**Fix options**
1. Check for CTEs referenced multiple times — materialize into a temp table (`/tsql-review` T24).
2. Use `/sqlplan-review` to confirm the operator topology and determine why two separate accesses were generated.
3. Restructure the query to access the table once using JOINs.

**Related checks:** `/tsql-review` T24 (CTE referenced more than once)

---

### I13 — Zero Rows Affected With High Reads

**What it means**
The statement completed with 0 rows affected or 0 rows returned, but performed substantial I/O (≥ 10,000 logical reads). The query read many pages but found nothing.

**Why it matters**
The query scanned data looking for rows that either don't exist or don't match the predicate — all that I/O was wasted. This often signals a non-sargable predicate preventing an index seek, causing a full scan with no matching rows.

**How to spot it**
```
Table 'Orders'. Scan count 1, logical reads 980,410, ...
(0 rows affected)
```

**Example — problem**
```sql
-- Looks up by customer email with wrong type; full scan, zero matches
SELECT * FROM dbo.Orders WHERE CustomerId = N'missing-guid';
-- Result: 0 rows, but 980,410 logical reads
```

**Fix options**
1. Add `TOP 1` to stop early when looking for existence.
2. Verify the predicate uses the correct column and data type (see `/tsql-review` T5, T16).
3. If looking for non-existence, use `IF NOT EXISTS(SELECT 1 FROM ...)` pattern.

**Related checks:** I4 (read-ahead scan), `/tsql-review` T4, T5, T16

---

### I14 — Physical Reads Non-Zero on Warm System

**What it means**
Pages had to be read from disk during execution. On a system with a warm buffer pool, most frequently-accessed pages should be cached in RAM.

**Why it matters**
Physical reads are 100–1,000× slower than logical reads. Even a small number of physical reads can add meaningful latency. On a warm production system, physical reads on core tables suggest the buffer pool is under pressure.

**How to spot it**
```
Table 'Products'. Scan count 1, logical reads 4,210, physical reads 18, ...
```

**Fix options**
1. Assess whether physical reads are consistent across repeated executions or only occur on cold runs.
2. If consistent on a warm system: reduce logical reads (I1) to reduce the buffer pool footprint.
3. Monitor `sys.dm_os_buffer_descriptors` for buffer pool pressure.

**Related checks:** I3 (high physical read ratio), W1 (I/O wait signal)

---

### I15 — Azure SQL Page Server Reads Detected

**What it means**
`page server reads > 0` indicates the query is running on **Azure SQL Hyperscale** and pages were fetched from the remote page server (Azure Storage) rather than the local compute node buffer pool.

**Why it matters**
Page server reads in Hyperscale are similar in impact to physical reads in on-premises SQL Server — they are network + storage fetches rather than local RAM reads. They indicate pages not cached on the local compute node.

**How to spot it**
```
Table 'SalesData'. Scan count 1, logical reads 8,200, page server reads 1,840, ...
```

**Fix options**
1. Reduce total logical reads via indexing (I1) — fewer total pages needed = better local cache hit rate.
2. For recurring queries with consistent page access patterns, pre-warming is less effective than indexing.
3. Consider scaling up the compute replica's local buffer pool (higher vCore tier = more local RAM).

**Related checks:** I1 (total logical reads), I3 (physical reads ratio)

---

### I16 — Columnstore Batch Mode I/O Absent Despite CS Index (SQL 2012+)

**What it means**
A columnstore index is being scanned in row mode instead of batch mode. Batch mode processes ~900 rows per CPU cycle using vectorized instructions; row mode processes one row at a time. The I/O volume may look reasonable but the CPU cost per row is far higher than a properly batch-mode query.

**How to spot it**
`segment reads` appears in the IO output (confirming a columnstore index is being accessed), but the companion `/sqlplan-review` output shows execution mode as row-mode (no batch-mode operators). The query does not receive the expected columnstore throughput speedup.

**Common causes**
- Database compatibility level below 130 (SQL Server 2016) — batch mode requires compat level ≥ 130
- A scalar UDF in the SELECT list or WHERE clause forces the entire plan into row mode
- OUTER JOIN patterns that the optimizer cannot batch-mode-ize in older compat levels
- Row-mode-only operators in the plan path (e.g., certain XML, CLR, or cursor operations)

**Fix options**
1. Raise database compatibility level to 130 or higher: `ALTER DATABASE [db] SET COMPATIBILITY_LEVEL = 150`.
2. Remove or replace scalar UDFs with inline table-valued functions (iTVFs) or inline expressions.
3. On SQL Server 2019+, enable scalar UDF inlining: `ALTER DATABASE SCOPED CONFIGURATION SET TSQL_SCALAR_UDF_INLINING = ON`.
4. Run `/sqlplan-review` to confirm check N7 (Row Mode Columnstore Scan) and identify the operator forcing row mode.

**Related checks:** I10 (columnstore segment skip rate), W5 (high CPU time), sqlplan-review N7

---

### I17 — Azure SQL Hyperscale: Remote Page Server Reads Dominant (Hyperscale only)

**What it means**
More than 30% of I/O is coming from remote page server reads rather than the local compute node buffer pool. Page server reads traverse the network to Azure Storage, making them significantly more latency-sensitive than local buffer pool hits.

**How to spot it**
```
Table 'SalesData'. Scan count 1, logical reads 6,800, page server reads 2,400, ...
```
page server reads / (logical reads + page server reads) = 2,400 / (6,800 + 2,400) = 26.1% — approaching the 30% threshold. At or above 30% triggers I17.

**Common causes**
- The local compute node buffer pool is too small to hold the working set for this query
- The query accesses a large, infrequently-used range of data (e.g., historical range scans)
- The table has grown beyond what the current compute tier can cache locally
- For read-only workloads routed to a secondary replica: the secondary may have a smaller buffer pool than the primary

**Fix options**
1. Reduce total logical reads via indexing (see I1, I2) — fewer pages needed means a higher local cache hit rate.
2. Verify the compute replica tier has enough memory for the working set; scale up to a higher vCore tier to increase the local buffer pool.
3. For read-only reporting workloads, consider a **named replica** with a tier sized for the analytical workload.
4. Use partition pruning or filtered indexes to limit the page range accessed.

**Related checks:** I3 (physical read ratio), I15 (page server reads present), I1 (total logical reads)

---

### I18 — High Temp Object Write Amplification (All versions)

**What it means**
A temp table (`#table`) or `Worktable` is re-read many more times than the underlying base tables, indicating it is functioning as the inner side of a Nested Loops join. Without an index on the temp object, each outer row triggers a full scan of the temp table.

**How to spot it**
```
Table '#StagingData'. Scan count 12,400, logical reads 620,000, ...
Table 'Orders'. Scan count 1, logical reads 84,210, ...
```
Temp table logical reads (620,000) ≥ 5× base table reads (84,210 × 5 = 421,050) → triggers I18.

**Common causes**
- A temp table is inserted into, then immediately joined without creating an index on the join column
- The optimizer cannot create a Hash or Merge join plan because of a cursor loop or RBAR pattern iterating over the temp table
- A CTE or derived table was materialized into a Worktable internally, and that Worktable becomes the inner input of a Nested Loops join

**Fix options**
1. Add a covering index to the temp table immediately after the INSERT:
   ```sql
   INSERT INTO #StagingData (OrderId, CustomerId, Total) SELECT ...;
   CREATE NONCLUSTERED INDEX IX_Staging_CustomerId ON #StagingData (CustomerId);
   -- now the Nested Loops join can seek instead of scan
   ```
2. Restructure the query to use a CTE or subquery the optimizer can inline — avoiding explicit temp table materialization.
3. If the Worktable is created by an Eager Spool, run `/sqlplan-review` to check N44 (Eager Spool) — adding an index on the source table may eliminate the spool.

**Related checks:** I6 (worktable spill), I2 (excessive scan count), I7 (temp table in IO output)

---

## Time Checks (W1–W9)

---

### W1 — I/O or Lock Wait Dominant (CPU << Elapsed)

**What it means**
The query used less than 10% of its elapsed time doing actual computation (CPU). The rest was spent waiting — for I/O, locks, latches, or network. The query is not CPU-bound; it is **wait-bound**.

**Why it matters**
Optimizing CPU (adding indexes, rewriting joins) will not help a wait-bound query. The root cause must be identified and addressed separately.

**How to spot it**
```
SQL Server Execution Times:
   CPU time = 312 ms, elapsed time = 18,430 ms.
```
CPU = 312 ms = 1.7% of elapsed 18,430 ms → triggers W1

**Common wait causes**
| CPU/Elapsed ratio | Likely cause |
|---|---|
| CPU < 5% | Physical I/O wait (`PAGEIOLATCH_*`), lock blocking (`LCK_M_*`), network |
| CPU 5–30% | Moderate I/O or latch waits |
| CPU 30–100% | Mostly CPU-bound; moderate waits |
| CPU > 100% | Parallel execution (normal) |

**Fix options**
1. **Check physical reads (I3, I14)** — if non-zero, I/O is the likely bottleneck.
2. **Check for blocking** using `sys.dm_exec_requests` or Extended Events during execution.
3. **Check latch waits** with `sys.dm_os_wait_stats` filtered to `PAGEIOLATCH_*` or `LCK_M_*`.
4. **Network wait**: if the query returns large result sets, the client may be consuming rows slowly.

**Related checks:** I3 (physical reads), I6 (worktable/tempdb spill), W4 (long elapsed)

---

### W2 — Parallel Execution Detected (CPU >> Elapsed)

**What it means**
CPU time exceeds elapsed time — the query executed on multiple threads simultaneously. CPU time = sum of all thread CPU time; elapsed time = wall-clock time for the slowest thread. When CPU / elapsed > 1.5, parallel execution is confirmed.

**Why it matters**
Parallel execution is generally good for large analytical queries. This check flags it as informational so you can confirm it was intentional and check for thread imbalance.

**How to spot it**
```
SQL Server Execution Times:
   CPU time = 36,800 ms, elapsed time = 5,200 ms.
```
CPU / elapsed = 7.1 → 7-thread parallelism approximately → triggers W2

**Fix options**
1. No fix typically required. Use `/sqlplan-review` to check N30 (Parallel Thread Skew) — if some threads did 10× more work than others, the data isn't evenly distributed.
2. If parallelism is unintended (transactional query forced parallel), check `MAXDOP` settings and query cost thresholds.

**Related checks:** sqlplan-review S1 (serial plan), N30 (thread skew)

---

### W3 — High Compile Time Relative to Execution

**What it means**
Query compilation (parsing, optimization, plan generation) consumed more than 20% of the total CPU time AND took over 200 ms. The optimization phase is a significant overhead for this query.

**Why it matters**
Compilation happens once per plan cache miss. For frequently-executed short queries, high compile time means every cache eviction causes a noticeable slowdown. For complex queries, high compile time may indicate a query the optimizer struggles with.

**How to spot it**
```
SQL Server parse and compile time:
   CPU time = 312 ms, elapsed time = 318 ms.

SQL Server Execution Times:
   CPU time = 840 ms, elapsed time = 904 ms.
```
Compile CPU (312) / Execution CPU (840) = 37.1% → triggers W3

**Fix options**
1. **Use stored procedures** — plan is cached and reused across executions.
2. **Simplify the query** — deep CTEs (T25), many joins, and complex subqueries increase optimization time.
3. **Ensure statistics are current** — `UPDATE STATISTICS dbo.TableName` — stale statistics force longer optimization search.
4. **For ad-hoc workloads**: enable "optimize for ad hoc workloads" server setting to store only a plan stub on first execution.

**Related checks:** `/tsql-review` T25 (CTE chain depth), T28 (OPTION RECOMPILE), sqlplan-review S5 (compile timeout)

---

### W4 — Long Elapsed Time

**What it means**
The query took more than 30 seconds (wall-clock time) to execute. At 5 minutes (300,000 ms), it is critical.

**Why it matters**
Long-running queries consume resources for extended periods: they hold locks (blocking other sessions), consume buffer pool pages (displacing other queries' cache), and may indicate runaway workloads that should be killed.

**How to spot it**
```
SQL Server Execution Times:
   CPU time = 28,430 ms, elapsed time = 142,800 ms.
```
elapsed 142,800 ms = 2m 22s → triggers W4 (Warning, ≥ 30 s)

**Fix options**
1. Identify the highest-read table (I1, I5) and add an index.
2. If CPU << elapsed (W1): investigate waits, not compute.
3. Run `/sqlplan-review` on the captured plan to find the dominant operator.
4. If query cannot be optimized, consider query timeouts and cancellation to protect the system.

**Related checks:** I1 (total reads), W1 (wait-bound), W5 (high CPU)

---

### W5 — High CPU Time

**What it means**
The query consumed more than 60 seconds of CPU time. CPU time is the sum across all parallel threads. On a 4-core server, 60 seconds CPU in 15 seconds elapsed time is a single query monopolizing all cores.

**Why it matters**
High CPU queries reduce throughput for all concurrent sessions. They are typically caused by large scans, hash joins on large inputs, complex aggregations, or sorts — all reducible with better indexes.

**How to spot it**
```
SQL Server Execution Times:
   CPU time = 84,200 ms, elapsed time = 12,100 ms.
```
CPU 84,200 ms = 84.2 seconds → triggers W5

**Fix options**
1. Add indexes to eliminate scans driving the CPU-intensive operations (I1, I2).
2. Use `/sqlplan-review` to identify which operator consumes the most CPU (N4 Scan, N18 Hash Match, N20 Sort).
3. Reduce DOP if parallelism is causing CPU monopolization: `OPTION (MAXDOP 2)`.
4. Batch large aggregations into smaller time windows.

**Related checks:** W2 (parallel execution), W4 (long elapsed), I1 (total reads)

---

### W6 — Multi-Batch: Highly Variable Elapsed Times

**What it means**
When the input contains output from multiple queries (multiple `SQL Server Execution Times` blocks), one or more statements take more than 10× longer than the shortest non-trivial statement.

**Why it matters**
In a batch or stored procedure with many statements, one slow statement can be hidden among many fast ones. The grand total time hides the outlier. This check identifies which statement to focus tuning on.

**How to spot it**
```
Statement 1: CPU 48 ms, elapsed 52 ms
Statement 2: CPU 28 ms, elapsed 30 ms
Statement 3: CPU 18,430 ms, elapsed 84,200 ms   ← 1,600× slower than statement 2
Statement 4: CPU 62 ms, elapsed 68 ms
```
Statement 3 elapsed (84,200) / Statement 2 elapsed (30) = 2,806× → triggers W6

**Fix options**
1. Focus all analysis on the identified slow statement (its IO group + plan).
2. Run `/sqlplan-review` targeted at that statement's execution plan.

**Related checks:** I5 (single table dominance), W4 (long elapsed), W5 (high CPU)

---

### W7 — High Rows Affected With Low Elapsed

**What it means**
The query modified or returned more than 1 million rows very quickly. While fast execution is desirable, high-volume DML operations have secondary costs that elapsed time alone doesn't capture.

**Why it matters**
Large-volume DML:
- **Transaction log**: writes every change, potentially filling the log or delaying log backups
- **Locking**: holds locks on modified rows/pages for the duration of the transaction, blocking concurrent readers/writers
- **Replication**: all changes must be replicated to subscribers, creating downstream latency
- **Rollback cost**: if the transaction fails or is cancelled, rollback is as expensive as the forward operation

**How to spot it**
```
(3,847,291 row(s) affected)
SQL Server Execution Times: CPU time = 4,200 ms, elapsed time = 3,800 ms.
```
3,847,291 rows in 3.8 seconds → triggers W7

**Fix options**
1. Batch large DML: `DELETE TOP (10000) FROM ... WHERE ...; WHILE @@ROWCOUNT > 0 ...`
2. Verify the intent: confirm this is expected volume (migration scripts) vs unexpected full-table modification.
3. Run during off-peak hours if the workload is unavoidable.

**Related checks:** `/tsql-review` T2 (missing WHERE on DELETE/UPDATE), W4 (long elapsed)

---

### W8 — Compile Time Dominates Total Elapsed Time (All versions)

**What it means**
Compilation overhead consumes more than 30% of the total elapsed time for the statement — each execution is paying a fresh compile cost rather than reusing a cached plan. For queries that run frequently, this compile tax accumulates into significant throughput loss.

**How to spot it**
```
SQL Server parse and compile time:
   CPU time = 280 ms, elapsed time = 520 ms.

SQL Server Execution Times:
   CPU time = 480 ms, elapsed time = 840 ms.
```
compile_elapsed (520) / (compile_elapsed + execution_elapsed) = 520 / 1,360 = 38.2% → triggers W8 (and execution_elapsed 840 ms ≥ 500 ms threshold).

**Common causes**
- Ad-hoc SQL with literal values instead of parameters — each unique literal produces a distinct cache entry
- Complex query structure (deep CTEs, many joins, correlated subqueries) that takes longer for the optimizer to compile
- Missing or stale statistics forcing the optimizer to explore more plan alternatives
- Plan cache pressure evicting plans frequently, causing recompiles

**Fix options**
1. **Parameterize** ad-hoc SQL using `sp_executesql` with typed parameters — the same plan is reused across executions.
2. **Use stored procedures** — the plan is compiled once and reused, with recompile only on schema change or statistics update.
3. **Update statistics** (`UPDATE STATISTICS dbo.TableName`) — current statistics reduce optimizer search time.
4. Enable "optimize for ad hoc workloads" at the server level to cache only a plan stub on first execution for ad-hoc queries.

**Related checks:** W3 (high compile time relative to execution CPU), sqlplan-review S5 (compile timeout)

---

### W9 — Negative Elapsed Time (Clock Skew Artifact) (All versions)

**What it means**
A statement shows a negative elapsed time or negative compile time. This is a measurement artifact caused by NUMA node clock skew — the query started on one NUMA node's scheduler and ended on another node with a slightly different clock reading, producing an apparent negative duration.

**How to spot it**
```
SQL Server Execution Times:
   CPU time = 48 ms, elapsed time = -3 ms.
```
execution_elapsed < 0 → triggers W9. Similarly, `compile_elapsed < 0` for the parse/compile block.

**Common causes**
- Query execution migrated across NUMA nodes mid-flight, and the destination node's high-resolution timer reads lower than the source node's timer
- The `QueryProcessingTime` counter wrapped or was sampled at an inconsistent point under heavy NUMA load
- This is a data quality issue, not a query performance issue — the query likely ran in a few milliseconds

**Fix options**
1. **Rerun in isolation** for a clean measurement: run the query alone on a quiet system to get accurate timing.
2. **Check NUMA topology**: `SELECT node_id, node_state_desc FROM sys.dm_os_nodes` — if there are multiple NUMA nodes, cross-node scheduling is possible.
3. **No query tuning required** — this is a measurement artifact. Discard the negative value and use repeated executions to get a representative elapsed time.
4. If negative elapsed times appear frequently, check for NUMA imbalance with `sys.dm_os_schedulers`.

**Related checks:** W4 (long elapsed time for genuine slow queries)

---

## Quick Reference: Checks by Severity (I1–I18, W1–W9)

### Critical (fix before other issues)
| Check | Issue |
|-------|-------|
| I1 | Logical reads ≥ 10 M (statement) |
| I2 | Scan count ≥ 10,000 (table) |
| W4 | Elapsed ≥ 5 minutes |

### Warning (should fix)
| Check | Issue |
|-------|-------|
| I1 | Logical reads ≥ 1 M (statement) |
| I2 | Scan count ≥ 1,000 (table) |
| I3 | Physical read ratio ≥ 10% |
| I5 | Single table ≥ 80% of reads |
| I6 | Worktable or Workfile in output |
| I9 | LOB reads ≥ 50% of logical reads |
| I10 | Columnstore segment skip rate < 50% |
| W1 | CPU < 10% of elapsed (wait-bound) |
| W3 | Compile time > 20% of execution time |
| W4 | Elapsed ≥ 30 seconds |
| W5 | CPU ≥ 60 seconds |

### Info (investigate and document)
| Check | Issue |
|-------|-------|
| I4 | Read-ahead dominant (full scan signal) |
| I5 | Single table ≥ 95% of reads |
| I7 | Temp table in IO output |
| I8 | LOB reads present |
| I11 | Columnstore segment skip ≥ 90% (good) |
| I12 | Same table accessed multiple times |
| I13 | Zero rows with high reads |
| I14 | Physical reads non-zero |
| I15 | Azure page server reads detected |
| I16 | Columnstore Batch Mode I/O Absent Despite CS Index |
| I17 | Azure SQL Hyperscale: Remote Page Server Reads Dominant |
| I18 | High Temp Object Write Amplification |
| W2 | Parallel execution detected |
| W6 | Multi-batch high elapsed variance |
| W7 | High rows affected, low elapsed |
| W8 | Compile Time Dominates Total Elapsed Time |
| W9 | Negative Elapsed Time (Clock Skew Artifact) |

---

## Example Input and Expected Output

### Input
```
SQL Server parse and compile time:
   CPU time = 0 ms, elapsed time = 1 ms.

(48291 row(s) affected)
Table 'OrderLines'. Scan count 48291, logical reads 2568900, physical reads 0, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.
Table 'Orders'. Scan count 1, logical reads 84210, physical reads 0, read-ahead reads 82150, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.

SQL Server Execution Times:
   CPU time = 18420 ms,  elapsed time = 18912 ms.
```

### Expected Report Structure
```
## Statistics IO/Time Analysis

### Input Summary
- 1 statement parsed
- Total logical reads: 2,653,110
- Total execution elapsed: 00:00:18.912

---

### Statement 1

**Compile Time:** CPU 0 ms | Elapsed 1 ms

**Rows Affected:** 48,291 rows affected

**IO Statistics**

| Table | Scan Count | Logical Reads | Physical Reads | Read-Ahead | % of Reads |
|-------|-----------|---------------|----------------|------------|------------|
| OrderLines | 48,291 | 2,568,900 | 0 | 0 | 96.826% |
| Orders | 1 | 84,210 | 0 | 82,150 | 3.174% |
| **Total** | **48,292** | **2,653,110** | **0** | **82,150** | |

**Execution Time:** CPU 18,420 ms (00:00:18.420) | Elapsed 18,912 ms (00:00:18.912)

---

### Grand Totals (All Statements)

[Same as Statement 1 since only one statement]

---

### Performance Findings

#### Critical Issues
**[C1] Excessive Scan Count** (I2)
- Observed: OrderLines — scan count 48,291
- Impact: Table accessed 48,291 times — inner side of a Nested Loops join. 2.5M logical reads result.
- Fix: Add NONCLUSTERED INDEX IX_OrderLines_OrderId ON dbo.OrderLines (OrderId) INCLUDE (LineTotal, ...)

#### Warnings
**[W1] High Total Logical Reads** (I1)
- Observed: Statement total 2,653,110 logical reads (≥ 1,000,000 threshold)
- Impact: Sustained high read pressure on buffer pool
- Fix: Resolved by adding index on OrderLines.OrderId (see C1)

**[W2] Read-Ahead Dominant on Orders** (I4)
- Observed: Orders — read-ahead 82,150 / logical 84,210 = 97.5% (scan signal)
- Impact: Orders table is being fully scanned
- Fix: Add predicate index on dbo.Orders(Status) if filtered by Status

#### Passed Checks
I3 ✓, I5 ✓, I6 ✓, I7 ✓, I8 ✓, I9 ✓, I10 ✓, I13 ✓, I14 ✓, I15 ✓, W1 ✓, W2 ✓, W3 ✓, W5 ✓, W6 ✓, W7 ✓
```
