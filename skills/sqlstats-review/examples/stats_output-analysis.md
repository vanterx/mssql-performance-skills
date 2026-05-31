# Statistics IO/Time Analysis — `stats_output.txt`

> **Input:** `skills/sqlstats-review/examples/stats_output.txt`
> Run with: `/sqlstats-review skills/sqlstats-review/examples/stats_output.txt`

## Input Summary
- Source: SSMS Messages tab (SET STATISTICS IO, TIME ON)
- Statements parsed: **2**
- Total logical reads (all statements): **2,840,078**
- Total execution elapsed: Statement 1 — 00:02:22.800 | Statement 2 — 00:00:00.001

---

## Statement 1

**Compile Time:** CPU 0 ms | Elapsed 2 ms

**Rows Affected:** 48,291

**IO Statistics**

| Table | Scan Count | Logical Reads | Physical Reads | Read-Ahead | % of Reads |
|-------|-----------|---------------|----------------|------------|------------|
| OrderLines | 48,291 | 2,568,900 | 0 | 0 | 90.453% |
| Worktable | 4 | 182,140 | 0 | 0 | 6.413% |
| Orders | 1 | 84,210 | 12 | 82,150 | 2.965% |
| Customers | 1 | 4,820 | 0 | 0 | 0.170% |
| **Total** | **48,298** | **2,840,070** | **12** | **82,150** | |

**Execution Time:** CPU 18,420 ms (00:00:18.420) | Elapsed 142,800 ms (00:02:22.800)

---

## Statement 2

**Rows Affected:** 1

**IO Statistics**

| Table | Scan Count | Logical Reads | Physical Reads | Read-Ahead | % of Reads |
|-------|-----------|---------------|----------------|------------|------------|
| Orders | 1 | 8 | 0 | 0 | 100.000% |
| **Total** | **1** | **8** | **0** | **0** | |

**Execution Time:** CPU 0 ms | Elapsed 1 ms

---

## Grand Totals (All Statements)

| Table | Scan Count | Logical Reads | Physical Reads | Read-Ahead | % of All Reads |
|-------|-----------|---------------|----------------|------------|----------------|
| Customers | 1 | 4,820 | 0 | 0 | 0.2% |
| OrderLines | 48,291 | 2,568,900 | 0 | 0 | 90.4% |
| Orders | 2 | 84,218 | 12 | 82,150 | 3.0% |
| Worktable | 4 | 182,140 | 0 | 0 | 6.4% |
| **Grand Total** | **48,299** | **2,840,078** | **12** | **82,150** | |

**Time Totals**

| Phase | CPU | Elapsed |
|-------|-----|---------|
| Compile (Statement 1) | 0 ms | 2 ms |
| Execution (Statement 1) | 18,420 ms | 142,800 ms |
| Execution (Statement 2) | 0 ms | 1 ms |
| **Grand Total** | **18,420 ms** | **142,803 ms** |

---

## Performance Findings

### Critical Issues

**[C1] Excessive Scan Count on OrderLines** (I2)
- Observed: `OrderLines` — scan count **48,291**, logical reads 2,568,900 (90.5% of all reads). The table was accessed 48,291 times — once per row from the outer input.
- Impact: This is the inner side of a Nested Loops join iterating once per order. At ~53 logical reads per iteration × 48,291 iterations = 2.5M reads. This single pattern accounts for 90% of all I/O in the batch.
- Fix: `CREATE NONCLUSTERED INDEX IX_OrderLines_OrderId ON dbo.OrderLines (OrderId) INCLUDE (LineTotal, ProductId, Quantity)` — converts each inner-side scan to a seek. Expected reduction: 2,568,900 reads → ~97,000 reads (97% reduction). Run `/sqlplan-index-advisor` on the execution plan for the full DDL.

**[C2] Worktable Present — TempDb Spill** (I6)
- Observed: `Worktable` — scan count 4, logical reads 182,140. SQL Server created a temporary work structure in tempdb for a sort or hash join that exceeded its memory grant.
- Impact: The worktable adds 182K reads (6.4% of total) on top of the already-high OrderLines reads. Sort spills are synchronous; this is likely the cause of the 142-second elapsed time.
- Fix: Update statistics on `OrderLines` and `Orders` — stale statistics produce wrong row estimates → wrong memory grants → spills. After adding the IX_OrderLines_OrderId index (C1 fix), the reduced row count feeding the sort/hash may eliminate the spill entirely.

**[C3] Long Elapsed Time — 142.8 Seconds** (W4)
- Observed: Statement 1 elapsed 142,800 ms (2m 22s) — exceeds the 30-second Warning threshold and the 5-minute Critical threshold is not hit, but this is a production query taking over 2 minutes.
- Impact: Any concurrent session attempting to read or modify `OrderLines` rows is blocked for the duration of this scan. With scan count 48,291 holding shared locks, blocking chains are likely.
- Fix: Resolves as a secondary effect of C1 (index addition). Also capture the execution plan and run `/sqlplan-review` to confirm operator choices.

### Warnings

**[W1] I/O Wait Dominant — CPU 12.9% of Elapsed** (W1)
- Observed: Statement 1 — CPU 18,420 ms vs Elapsed 142,800 ms. CPU = 12.9% of elapsed time. The query spent 87% of its time waiting, not computing.
- Impact: The high elapsed-to-CPU ratio indicates lock waits or I/O waits. With scan count 48,291 and 12 physical reads on Orders, this is consistent with I/O stalls on the Orders read-ahead and lock waits from concurrent sessions.
- Fix: After adding the index (C1), elapsed time will drop to near CPU time. If I/O waits persist, run `/sqlwait-review` on `sys.dm_os_wait_stats` to identify the dominant wait type.

**[W2] Read-Ahead Dominant on Orders — Full Scan Signal** (I4)
- Observed: `Orders` — read-ahead 82,150 / logical 84,210 = **97.6%** read-ahead ratio. The storage engine prefetched almost every Orders page sequentially — a strong indicator of a full index scan, not a seek.
- Impact: The Orders scan reads all 84,210 pages (672 MB) to apply the date filter. An index on the filter column would reduce this to a range seek touching only the matching rows.
- Fix: Add an index on the Orders filter column (`CreatedDate`, `Status`, or whichever column the WHERE clause uses). Run `/sqlplan-review` on the execution plan to confirm the scan operator and its predicate.

**[W3] Physical Reads on Orders — Cold Pages** (I14)
- Observed: `Orders` — 12 physical reads (pages not in buffer pool cache)
- Impact: Minor at 12 pages, but indicates some Orders pages were evicted from cache. If this number is consistently non-zero across repeated executions on a warm system, the buffer pool is under pressure from the 2.5M logical reads in C1.
- Fix: Resolves as a secondary effect of C1 — fewer logical reads = smaller buffer pool footprint = better cache hit rate.

### Info

**[I1] Statement 2 Is Clean** (I3 — informational)
- Observed: Statement 2 — 1 row affected, 8 logical reads, 1 ms elapsed. An efficient point lookup (clustered index seek on Orders by primary key).
- No action required.

---

### Passed Checks
I1 ✓ (Statement 1 total reads 2.8M — yes Critical, flagged as C3), I3 ✓ (no intentional full-table scan without comment), I5 ✓ (no explicit temp tables), I7 ✓ (no temp tables in output), I8 ✓ (no LOB reads), I9 ✓ (LOB reads not dominant), I10 ✓ (no columnstore segments), I12 ✓ (OrderLines appears once per statement group — the 48K scan count is iterations, not re-appearances in the same batch group), I13 ✓ (48,291 rows affected with high reads — reads are proportional to output), I15 ✓ (no Azure page server reads), W2 ✓ (CPU > elapsed not the case — not parallel), W5 ✓ (CPU 18s < 60s), W6 ✓ (only 2 statements, no variance check applicable), W7 ✓ (48,291 rows affected in 142s — not "high rows with low elapsed" pattern)
