## SQL Server Workload Comparison

**Input:** `workload-windows.txt` — SalesDB, Query Store, baseline Mon 2026-10-05 09:00–10:00 +13:00, current Tue 2026-10-06 09:00–10:00 +13:00

### Summary

- **Verdict: systemic regression across the workload**, with three changes between the windows that explain it: compatibility level 140 → 160 (WC13), cumulative update CU12 → CU14 (WC12), and cost threshold for parallelism 50 → 5 (WC11). One new job (WC4) and one cache failure (WC10) add load on top.
- Total query duration in the window rose from 1,257,260 ms to 2,868,055 ms (2.28×) over two windows of equal length on the same 16-core instance.
- 3 Critical, 7 Warning, 6 Info. Highest-risk finding: `[C1]` — the Orders lookup regressed 3.3× on a 7.95× rise in reads, costing 554 seconds in one hour.

### Comparability (WC1)

| Aspect | Baseline | Current | Comparable |
|--------|----------|---------|------------|
| Window | 60 min | 60 min | Yes |
| `cpu_count` | 16 | 16 | Yes |
| Source and filter | Query Store, capture mode ALL | same Query Store | Yes |
| Business period | Monday 09:00 | Tuesday 09:00 | Yes (stated equivalent) |

WC1 passes: same database, same Query Store, same clock, same window length and core count. Every check below is assessable.

### Query Changes (WC2–WC10)

| # | Query (first 80 chars) | Presence | Baseline execs | Current execs | Baseline avg ms | Current avg ms | Ratio | Added time ms | Class | Check |
|---|------------------------|----------|----------------|---------------|-----------------|----------------|-------|---------------|-------|-------|
| 1 | SELECT o.OrderId, o.Total FROM dbo.Orders o WHERE o.CustomerId = @p1 AND o.S… | both | 12,400 | 12,950 | 18.4 | 61.2 | 3.33 | 554,260 | reads | WC2, WC8 |
| 2 | EXEC dbo.usp_SalesByRegion @Region = @p1, @From = @p2 | both | 880 | 910 | 210.0 | 690.0 | 3.29 | 436,800 | CPU | WC2, WC7 |
| 3 | EXEC dbo.usp_ReconcileLedger @BatchId = @p1 | current only | 0 | 140 | — | 2,100.0 | new | 294,000 | — | WC4 |
| 4 | UPDATE dbo.Inventory SET Qty = Qty - @p1 WHERE Sku = @p2 | both | 3,100 | 3,050 | 42.0 | 118.5 | 2.82 | 233,325 | wait | WC2, WC9 |
| 5 | SELECT c.CustomerId, SUM(l.Amount) FROM dbo.Ledger l JOIN dbo.Customers c ON … | both | 1,800 | 1,750 | 95.0 | 160.0 | 1.68 | 113,750 | reads | WC2, WC8 |
| 6 | SELECT p.Price FROM dbo.Prices p WHERE p.Sku = @p1 | both | 45,000 | 96,000 | 1.9 | 2.0 | 1.05 | 9,600 | volume | WC10 |
| 7 | SELECT s.ShipmentId FROM dbo.Shipments s WHERE s.TrackingNo = @p1 | both | 5,200 | 5,150 | 25.0 | 14.8 | 0.59 | −52,529 | — | WC3 |
| 8 | EXEC dbo.usp_ExportDailyOrders @Date = @p1 | baseline only | 60 | 0 | 1,500.0 | — | — | — | — | WC5 |

Ranked by added time. The two other matched queries (`dbo.Notifications`, `usp_GetCart`) moved by 1.03–1.05× and are unchanged.

### Configuration Differences (WC11–WC13)

| Scope | Setting | Baseline | Current | Severity | Check |
|-------|---------|----------|---------|----------|-------|
| Server | `ProductUpdateLevel` / `ProductVersion` | CU12 / 16.0.4125.3 | CU14 / 16.0.4135.4 | Warning | WC12 |
| Server | cost threshold for parallelism | 50 | 5 | Warning | WC11 |
| Database (SalesDB) | `compatibility_level` | 140 | 160 | Warning | WC13 |

Unchanged and verified: `max degree of parallelism` 8, `max server memory (MB)` 114688, RCSI off, auto update statistics on, forced parameterization off, database-scoped `LEGACY_CARDINALITY_ESTIMATION` 0 and `MAXDOP` 0, edition, `cpu_count` 16, physical memory 128 GB.

### Wait Profile (WC14)

Normalised to milliseconds per second per CPU (delta ÷ 3,600 s ÷ 16).

| Category | Wait types | Baseline | Current | Ratio |
|----------|-----------|----------|---------|-------|
| Buffer I/O | PAGEIOLATCH_SH | 2.1 | 6.8 | 3.2× |
| Lock | LCK_M_U | 0.9 | 4.6 | 5.1× |
| Parallelism | CXPACKET + CXCONSUMER | 1.2 | 3.9 | 3.3× |
| CPU/scheduler | SOS_SCHEDULER_YIELD | 0.8 | 2.0 | 2.5× |
| Log | WRITELOG | 0.5 | 0.6 | 1.2× |

### Critical Issues

**[C1] Orders lookup regressed 3.3× — reads-driven** (WC2, WC8)
- Observed: `0x1A2B3C4D5E6F7081`, 12,400 → 12,950 executions, average 18.4 → 61.2 ms, maximum 240 → 910 ms, logical reads 1,240 → 9,860 per execution (7.95×). 792,540 ms in the current window — 27.6% of it. Added time 554,260 ms.
- Impact: Every caller of the Orders lookup now waits three times as long; this one query is over a quarter of the window.
- Fix: Reads rose with the compatibility level change (W6): the level-160 cardinality estimator expects more rows and the plan reads eight times the data. Diff one plan from each side with `/sqlplan-compare`; force the Monday plan with Query Store as a stopgap (`/sqlquerystore-review`) while the estimate is fixed.

**[C2] Sales-by-region procedure regressed 3.3× — CPU-driven** (WC2, WC7)
- Observed: `0x3C4D5E6F70819203`, average 210 → 690 ms (+480), CPU 180 → 610 ms (+430), reads 22,000 → 24,300 (1.10×). 21.9% of the current window. Added time 436,800 ms.
- Impact: Same data, far more CPU per execution — the procedure is now one of the main CPU consumers on the host.
- Fix: Consistent with the cost threshold for parallelism dropping from 50 to 5 (W5): the procedure now qualifies for a parallel plan and pays parallel overhead on a moderate row count. Restore the threshold, then confirm with `/sqlplan-compare` that the serial plan returns.

**[C3] Inventory update regressed 2.8× — wait-driven** (WC2, WC9)
- Observed: `0x2B3C4D5E6F708192`, average 42.0 → 118.5 ms, CPU 38.0 → 41.2 ms (1.08×), reads 3,400 → 3,520 (1.04×), maximum 390 → 2,850 ms. 12.6% of the current window.
- Impact: Same work per execution; the extra 76 ms is waiting. Lock waits on the instance rose 5.1× (W7).
- Fix: Do not apply a plan fix. Capture the blocking chain in the current window with `/sqlblocking-review` — the regressed reads-driven queries hold locks longer and the new reconciliation job (W2) writes to the same tables.

### Warnings

**[W1] Regression is systemic** (WC6)
- Observed: 4 of 8 matched queries with ≥ 10 executions on both sides regressed (50%): two reads-driven (C1, W3), one CPU-driven (C2), one wait-driven (C3).
- Impact: Query-by-query tuning would treat symptoms of shared causes.
- Fix: Address the configuration and version changes first — compatibility level (W6), cost threshold (W5), cumulative update (W4) — then re-compare before tuning individual queries.

**[W2] New heavy query: ledger reconciliation** (WC4)
- Observed: `0x5E6F708192031425` (`usp_ReconcileLedger`), current only, 140 executions at 2,100 ms — 294,000 ms, 10.3% of the window's duration and 11.4% of its CPU.
- Impact: New load in the business window, and it writes to the ledger tables the inventory update waits on.
- Fix: Find the deployment or job that added it and move it out of 09:00–10:00 before tuning it.

**[W3] Ledger summary regressed 1.7× — reads-driven** (WC2, WC8)
- Observed: `0x92031425364F5A6B`, average 95 → 160 ms, reads 8,000 → 14,500 (1.81×). 9.8% of the window.
- Fix: Same estimator change as C1 (W6); include it in the same plan comparison.

**[W4] Cumulative update applied between the windows** (WC12)
- Observed: CU12 (16.0.4125.3) → CU14 (16.0.4135.4).
- Fix: Read the CU13 and CU14 fix lists for optimizer changes; the update happened the same night as the compatibility level change, so separate their effects by testing the old level on the new build.

**[W5] Cost threshold for parallelism lowered from 50 to 5** (WC11)
- Observed: `value_in_use` 50 → 5.
- Fix: Restore 50 unless the change was deliberate; it explains C2 and the 3.3× rise in parallelism waits. `/sqldbconfig-review` B2 covers the setting on its own merits.

**[W6] Compatibility level raised from 140 to 160** (WC13)
- Observed: SalesDB `compatibility_level` 140 → 160, `LEGACY_CARDINALITY_ESTIMATION` 0 on both sides.
- Fix: The cardinality estimator changed with the level. Force the earlier plans for C1 and W3 through Query Store, evaluate them under 160, and consider a per-query `USE HINT` rather than lowering the whole database back.

**[W7] Wait profile shifted** (WC14)
- Observed: lock waits 0.9 → 4.6 ms/s/CPU (5.1×), parallelism 1.2 → 3.9 (3.3×), buffer I/O 2.1 → 6.8 (3.2×); buffer I/O remains the dominant category.
- Fix: The shifts match the classes above — lock with C3, parallelism with C2 and W5, buffer I/O with C1 and W3. Hand the current side to `/sqlwait-review`.



### Info

**[I1] Price lookup volume doubled, cost flat** (WC10)
- Observed: `0x4D5E6F7081920314`, 750 → 1,600 executions per minute (2.13×) at 1.9 → 2.0 ms each. Not in the top three by duration.
- Fix: The query did not get slower — something calls it twice as often. Check the application's price cache.

**[I2] Shipment lookup improved 0.59×** (WC3)
- Observed: `0x708192031425364F`, 25.0 → 14.8 ms, reads 2,100 → 900. Saved 52,529 ms.
- Fix: None needed; it confirms the change window touched plan choice (the new estimator helped this one).

**[I3] Daily export absent from the current window** (WC5)
- Observed: `0x6F70819203142536` (`usp_ExportDailyOrders`), 60 executions at 1,500 ms on Monday — 7.2% of the baseline — none on Tuesday. Query Store capture mode is ALL, so it did not run.
- Fix: Confirm it was rescheduled rather than broken.

**[I4] CPU-driven class** (WC7) — C2.
**[I5] Reads-driven class** (WC8) — C1, W3.
**[I6] Wait-driven class** (WC9) — C3.

### Recommended Action Order

1. Restore cost threshold for parallelism to 50 (W5) — reversible in seconds, explains C2.
2. Force Monday's plans for the C1 and W3 queries through Query Store (W6) — stops the reads-driven regressions while the estimator change is evaluated (`/sqlquerystore-review`).
3. Move `usp_ReconcileLedger` out of the business window (W2).
4. Re-capture and re-compare; then take whatever remains of C3 to `/sqlblocking-review`.
5. Investigate the doubled price-lookup rate (I1) with the application team.

### Passed Checks

- WC1 — captures comparable (same database, Query Store, window length, `cpu_count`)
- WC11 — `max degree of parallelism`, `max server memory (MB)` unchanged
- WC12 — edition, `cpu_count`, physical memory unchanged
- WC13 — RCSI, auto-update statistics, forced parameterization, `LEGACY_CARDINALITY_ESTIMATION`, database-scoped `MAXDOP` unchanged
- Two matched queries within 1.05× (no change)

---
> Analyzed by: `sqlworkload-compare` (WC1–WC14)
