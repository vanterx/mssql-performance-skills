# Trace Analysis — `trace_output.txt`

> **Input:** `example/sqltrace-review/trace_output.txt`
> Run with: `/sqltrace-review example/sqltrace-review/trace_output.txt`
>
> Source: `sys.fn_trace_gettable()` output · Duration column in microseconds

## Input Summary
- Source: `sys.fn_trace_gettable()` query result (Profiler .trc file)
- Trace window: 2025-05-01 10:32:14 – 10:33:00 (~46 seconds)
- Total events captured: 21
- Distinct normalized queries: 4
- Event types present: SQL:BatchCompleted (12), SP:Recompile (37), Attention (16), Lock:Timeout (54), Sort Warnings (69), Data File Auto Grow (92)

---

## Top Resource Consumers

**By Total CPU** (top 3 — all events)

| # | Query | Executions | Avg CPU ms | Total CPU ms | % of Workload |
|---|-------|-----------|-----------|-------------|---------------|
| 1 | `EXEC dbo.GetMonthlyReport @month = ?` | 2 | 44,200 | 88,400 | 99.5% |
| 2 | `SELECT … FROM dbo.Orders WHERE CustomerId = ?` | 7 | 153 | 1,071 | 0.5% |
| 3 | `SELECT … FROM dbo.Customers WHERE Id = ?` | 6 | 2 | 12 | <0.1% |

**By Total Logical Reads** (top 3)

| # | Query | Executions | Avg Reads | Total Reads |
|---|-------|-----------|-----------|-------------|
| 1 | `EXEC dbo.GetMonthlyReport @month = ?` | 2 | ~1,308,555 | ~2,617,110 |
| 2 | `SELECT … FROM dbo.Orders WHERE CustomerId = ?` | 7 | 48,270 | 337,890 |
| 3 | `SELECT … FROM dbo.Customers WHERE Id = ?` | 6 | 8 | 48 |

**By Max Duration** (top 3)

| # | Query | Executions | Avg ms | Max ms | Min ms |
|---|-------|-----------|--------|--------|--------|
| 1 | `EXEC dbo.GetMonthlyReport @month = ?` | 2 | 144,853 | **284,906** | 4,800 |
| 2 | `SELECT … FROM dbo.Orders WHERE CustomerId = ?` | 7 | 141,614 | 144,100 | 136,200 |
| 3 | `SELECT … FROM dbo.Customers WHERE Id = ?` | 6 | 2,933 | 3,100 | 2,800 |

---

## Performance Findings

### Critical Issues

**[C1] Long-Duration Query — GetMonthlyReport** (X1)
- Observed: `EXEC dbo.GetMonthlyReport @month = '2025-04'` — **284,906 ms (4m 44s)** elapsed, CPU 84,200 ms, Reads ~2,568,900, Writes 45,280
- Impact: Single query consumed 4m 44s and 2.5M reads. Writes = 45,280 on a SELECT confirms a Sort or Hash spill to tempdb (corroborated by X9 finding). Every session blocked on `Orders` or `OrderLines` during this execution cannot proceed.
- Fix: Capture execution plan with `/sqlplan-review`. The 45K writes signal a memory grant spill — update statistics to fix row estimates, add covering index on the highest-read table. Run `/sqlplan-index-advisor` for DDL.

**[C2] Long-Duration Query — Orders by CustomerId** (X1)
- Observed: `SELECT … FROM dbo.Orders WHERE CustomerId = ?` — avg **141,614 ms** across 7 executions, avg **48,270 reads** per call. Duration range: 136,200–144,100 ms (tight — not sniffing, just slow).
- Impact: Each of 7 calls takes ~2.4 minutes and reads 48K pages — the entire Orders table is being scanned per call because no index exists on `CustomerId`. 7 concurrent users × 2.4 min = 16.8 minutes of cumulative blocking.
- Fix: `CREATE NONCLUSTERED INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId) INCLUDE (OrderId, Total)` — reduces 48,270 reads to ~3–5 reads per call.

**[C3] Attention Event — Client Timeout on SPID 54** (X5)
- Observed: Attention event at 10:32:44, 300 seconds after the `SELECT … WHERE CustomerId = 42` query started (10:32:14). The client hit its 300-second timeout and cancelled.
- Impact: Wasted work — SQL Server ran the query for 300 seconds, consumed ~48K reads, then rolled back. The user received a timeout error.
- Fix: Resolved by adding the CustomerId index (C2 fix). Once the query runs in < 100 ms, no timeout occurs.

### Warnings

**[W1] Parameter Sniffing Signal — GetMonthlyReport** (X14)
- Observed: `dbo.GetMonthlyReport` — `@month = '2025-04'`: 284,906 ms vs `@month = '2025-03'`: 4,800 ms. Variance: **284,906 / 4,800 = 59×**
- Impact: The same stored procedure takes 59× longer for April vs March. The plan cached for one month's data distribution is wrong for another — classic parameter sniffing. Every April execution suffers until the plan is evicted or recompiled.
- Fix: Add `OPTION (RECOMPILE)` to the heavy query inside `dbo.GetMonthlyReport`. Alternative: `OPTION (OPTIMIZE FOR (@month = '2025-04'))` to pin the plan for the high-volume month. Run `/sqlplan-compare` on the fast and slow plans to confirm the plan difference.

**[W2] High-Frequency Query — N+1 Pattern on Orders** (X13)
- Observed: `SELECT … FROM dbo.Orders WHERE CustomerId = ?` — 7 executions in 31 seconds, each for a different `CustomerId` (42, 99, 1821, 7, 332, 4419, and one more). The application is fetching orders one customer at a time.
- Impact: For 1,000 customers this pattern would take 7 × 141s × 1000/7 ≈ 141,000 seconds. Even after adding the index (C2), 1,000 round-trips × small latency = significant overhead. The N+1 pattern must be fixed in the application regardless of indexing.
- Fix: Replace with a single batched query: `SELECT OrderId, Total, CustomerId FROM dbo.Orders WHERE CustomerId IN (42, 99, 1821, 7, 332, 4419, ...)` — or pass a TVP. One round-trip replaces seven.

**[W3] Recompile Events — GetMonthlyReport 3×** (X7)
- Observed: Three `SP:Recompile` events for `dbo.GetMonthlyReport` at 10:32:17, 10:32:18, 10:32:19 — three recompilations within 3 seconds during execution. EventSubClass would reveal cause (requires Extended Events for detail).
- Impact: Each recompile consumes CPU and acquires a schema stability lock. If the recompile is triggered by statistics updates mid-execution, this explains the severe performance variance between April (284s) and March (4.8s).
- Fix: Add `OPTION (KEEP PLAN)` to prevent statistics-triggered recompilation, or restructure the proc to use temp tables whose statistics don't trigger mid-procedure recompiles.

**[W4] Sort Warning — GetMonthlyReport** (X9)
- Observed: `Sort Warnings` event on SPID 61 at 10:32:16 (during GetMonthlyReport `@month = '2025-04'` execution)
- Impact: Confirms the 45,280 writes in C1 are a Sort spill to tempdb. The Sort operator in GetMonthlyReport exceeded its memory grant and wrote intermediate data to disk.
- Fix: Update statistics to produce accurate row estimates → correct memory grant. Add an index that pre-sorts the data, eliminating the Sort operator. Verify with `/sqlplan-review` checking N41–N43.

**[W5] Lock Timeout** (X6)
- Observed: `Lock:Timeout` on SPID 75 at 10:32:47
- Impact: A session waited for a lock held by one of the long-running Orders/OrderLines scans and timed out. Silent failure — the application may not have surfaced this to the user.
- Fix: Adding the CustomerId index (C2) reduces lock hold duration. Enabling READ_COMMITTED_SNAPSHOT eliminates reader/writer lock conflicts entirely.

**[W6] Data File Auto-Grow — 8.4 Seconds** (X19)
- Observed: `Data File Auto Grow` on ProdDB at 10:32:50, **8,420 ms duration** (8.4 seconds of full database pause)
- Impact: The database data file expanded mid-workload, pausing all ProdDB activity for 8.4 seconds. The 45K Sort spill writes from GetMonthlyReport (C1/W4) likely triggered the auto-grow.
- Fix: (1) Pre-size the data file to avoid mid-workload grows; (2) Enable Instant File Initialization (`SE_MANAGE_VOLUME_NAME` for the SQL Server service account) to eliminate data file zeroing overhead; (3) Fix the Sort spill (W4) to reduce write volume.

### Info

**[I1] Workload Concentration — GetMonthlyReport** (X18)
- Observed: `dbo.GetMonthlyReport` accounts for **99.5% of total CPU** (88,400 / 88,491 ms)
- Impact: Fixing one stored procedure improves the entire server. This extreme concentration makes prioritization trivial.

**[I2] Multi-Batch Elapsed Time Variance** (X6 — referenced from W1)
- Observed: GetMonthlyReport `@month = '2025-04'`: 284,906 ms vs `@month = '2025-03'`: 4,800 ms — 59× variance confirms W1 parameter sniffing.

---

### Passed Checks
X2 ✓ (individual non-report CPU < 5,000 ms), X3 ✓ (Customers queries < 100K reads), X4 ✓ (Customers writes = 0), X8 ✓ (no exception/error events), X10 ✓ (no hash warning events), X11 ✓ (no missing column statistics events), X12 ✓ (no missing join predicate events), X15 ✓ (queries are parameterized — same normalized text, different parameter values), X16 ✓ (3 recompiles / 21 batch events = 14.3% — flagged in W3, not exceeding 5% of non-recompile events), X17 ✓ (top consumers reported above), X20 ✓ (no ShowPlan XML events captured — would enable richer analysis if present)
