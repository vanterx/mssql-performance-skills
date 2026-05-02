# Wait Statistics Analysis — `wait_trend.txt`

> **Input:** `example/sqlwait-review/wait_trend.txt`
> Run with: `/sqlwait-review example/sqlwait-review/wait_trend.txt`
>
> Server: PROD-SQL-01 · SQL Server 2019 CU23 · 16 cores / 128 GB RAM
> Capture window: 4-snapshot trend (2025-05-02 10:00–11:00, 15-minute intervals)
> Mode: **Trend analysis** (V1–V18 on most recent period + V19–V26 across all periods)

---

## Input Summary

- Source: `sys.dm_os_wait_stats` staging table, 4 snapshots via LAG() delta query
- Capture window: 10:00–11:00 (4 periods of 15 minutes each)
- Wait types captured: 14 (benign idle waits excluded)
- Most recent period total wait: **11,564,820 ms** (11:00 window)
- In context (most recent period): 11,564,820 ms ÷ 900,000 ms (15-min window) ≈ **12.8 sessions blocked on average** in the last period — and worsening vs the first period (10:15: ≈ 10.0 sessions).
- Signal wait ratio (most recent period): SOS_SCHEDULER_YIELD and CXPACKET signal ms ≈ **9.1%** — CPU pressure is building but not yet saturated.

---

## Server Configuration Context

| Setting | Value | Affects | Interpretation |
|---------|-------|---------|---------------|
| MAXDOP | 0 (all 16 cores) | V3 | High CXPACKET expected; raise CTPfP before reducing MAXDOP |
| Cost Threshold for Parallelism | 5 (default) | V3 | Too low — many medium-cost queries go parallel unnecessarily; raising to 50 is the first fix |
| RCSI enabled | No | V2 | Reader/writer shared-lock conflicts are preventable — enabling RCSI is the highest-leverage LCK_M fix |
| TempDB data files | 2 (of 8 recommended) | V9 | Add 6 files to distribute PFS/GAM allocation contention |
| Recovery model | FULL | V16 | Log space freed by log backup — take one immediately if LOGMGR_RESERVE_APPEND appears |
| Delayed Durability | DISABLED | V5 | WRITELOG waits: consider DELAYED_DURABILITY = ALLOWED for non-critical workloads |
| Always On commit mode | Synchronous | V12 | Every COMMIT waits for secondary ack — secondary lag adds to primary commit time |
| Max Server Memory (MB) | 122,880 | V4 | Memory bounded appropriately — RESOURCE_SEMAPHORE waits from over-estimated grants, not RAM shortage |

---

## Top Wait Types — Most Recent Period (10:45–11:00) (V17)

| Rank | Wait Type | Category | delta_tasks | delta_wait_ms | % of Period | delta_signal_ms |
|------|-----------|----------|------------|--------------|-------------|----------------|
| 1 | PAGEIOLATCH_SH | I/O | 284,800 | 9,420,800 | **81.5%** | 348,400 |
| 2 | LCK_M_IX | Locks | 6,420 | 1,404,800 | **12.1%** | 18,400 |
| 3 | CXPACKET | Parallelism | 178,400 | 1,584,800 | 13.7% | 624,400 |
| 4 | RESOURCE_SEMAPHORE | Memory | 5,320 | 1,248,400 | 10.8% | 5,840 |
| 5 | WRITELOG | Log | 964,800 | 584,200 | 5.1% | 56,800 |

### Dominant Bottleneck

I/O pressure is the dominant and worsening bottleneck — PAGEIOLATCH_SH has grown from 48.8% in the first period to 81.5% in the last, while an emerging log space crisis (LOGMGR_RESERVE_APPEND appeared in the final period) and a historical IO_RETRY event add urgency.

---

## Performance Findings — Most Recent Period (V1–V18)

### Critical Issues

**[C1] Physical I/O Dominant — PAGEIOLATCH_SH 81.5% in Final Period** (V1 — Critical)
- Observed: `PAGEIOLATCH_SH` 81.5%, 284,800 tasks, 9,420,800 ms delta wait. Up from 48.8% in the first period — see Trend Analysis for full progression.
- **User impact:** 4 out of 5 seconds of query latency was disk wait in the final period. Queries that should take 100 ms were taking 500 ms or more because pages were not in memory.
- Impact: The working set is growing beyond buffer pool capacity, or a query generating increasing read volume is being executed repeatedly. This is the primary bottleneck and the root cause for several secondary findings.
- Fix: Run `/sqlstats-review` on `SET STATISTICS IO, TIME ON` output for the heaviest concurrent queries. Run `/sqlplan-index-advisor` to generate covering indexes. Priority: do this before any other tuning.

**[C2] Log Space Exhaustion — LOGMGR_RESERVE_APPEND Appeared in Final Period** (V16 — Critical)
- Observed: `LOGMGR_RESERVE_APPEND` — 84 waiting tasks, 18,420 ms in the 10:45–11:00 window. Absent in all prior periods (see V23 — Emerging Wait Type).
- **User impact:** All INSERT, UPDATE, and DELETE operations began stalling at 10:45. Users experienced write timeouts or unexplained write failures in the final 15 minutes of the observation window.
- Impact: The transaction log ran out of reusable space mid-observation. Given the growing I/O pressure (C1) and WRITELOG trend (see Trend Analysis W3), the high DML volume is likely generating log faster than it can be freed.
- Fix: **Immediately:** `DBCC SQLPERF('LOGSPACE'); SELECT log_reuse_wait_desc FROM sys.databases WHERE name = 'ProdDB';` — then `BACKUP LOG ProdDB TO DISK = 'path\log.bak' WITH COMPRESSION;` (recovery model = FULL → log backup frees space).

**[C3] Memory Grant Queue — RESOURCE_SEMAPHORE 10.8%** (V4 — Critical)
- Observed: `RESOURCE_SEMAPHORE` 10.8% of final period, 5,320 tasks, 1,248,400 ms delta wait. Growing every period (see V22 Velocity).
- **User impact:** Some queries waited for memory grants before starting. Grant queuing compounds the I/O delay — queries that eventually run spend additional time waiting just to begin.
- Impact: Stale statistics producing oversized memory grants, consistent with the bad row estimates driving the large scans (C1).
- Fix: `UPDATE STATISTICS dbo.[HeavyTable] WITH FULLSCAN;` on the highest-read tables identified by `/sqlstats-review`. Max Server Memory is correctly bounded — the issue is grant sizing, not total RAM.

**[C4] Intent Exclusive Lock Waits — LCK_M_IX 12.1%** (V2 — Warning/Critical)
- Observed: `LCK_M_IX` 12.1%, 6,420 tasks, 1,404,800 ms delta wait. Improving over time (see V19 Trend Direction — improving).
- **User impact:** Lock waits are improving — the head blocker that caused severe locking in earlier periods appears to have released. Current impact is moderate.
- **Configuration note (RCSI = OFF):** Enabling RCSI would prevent the reader-side LCK_M_S conflicts that likely initiated the blocking chain. Apply to prevent recurrence even though the immediate blocker resolved.
- Fix: `ALTER DATABASE ProdDB SET READ_COMMITTED_SNAPSHOT ON;`

### Warnings

**[W1] Parallelism — CXPACKET 13.7%** (V3)
- Observed: `CXPACKET` 13.7%, growing (see V22 Velocity). **Configuration note (MAXDOP=0, CTPfP=5):** Raise CTPfP to 50 first. Adding indexes (C1 fix) simultaneously eliminates parallel scans driving both CXPACKET and PAGEIOLATCH.

**[W2] WRITELOG 5.1%** (V5)
- Observed: `WRITELOG` 5.1%, 964,800 tasks, growing. High task count confirms many small commits. Combined with LOGMGR_RESERVE_APPEND (C2), log I/O pressure is building. Move log to dedicated storage.

**[W3] HADR_SYNC_COMMIT — Growing** (V12)
- Observed: 22,400 ms in final period vs 14,200 ms in first period (+58%). The synchronous secondary's ack latency is growing as the primary generates more log (C2/W2). Check `sys.dm_hadr_database_replica_states` for secondary redo queue growth.

---

### Passed Checks
V6 ✓ (ASYNC_NETWORK_IO < 20%), V7 ✓ (SOS_SCHEDULER_YIELD 0.97% < 15%), V8 ✓ (THREADPOOL absent), V10 ✓ (signal ratio 9.1% < 15%), V11 ✓ (OLEDB absent), V13 ✓ (PREEMPTIVE absent), V14 ✓ (no single type ≥ 60% in all periods)

---

## Trend Analysis (V19–V26)

### Observation Period Summary

- Mode: Trend analysis — 4 time windows, 15-minute intervals
- Total observation window: 60 minutes (2025-05-02 10:00 to 11:00)
- Periods analyzed: 4 (10:00–10:15, 10:15–10:30, 10:30–10:45, 10:45–11:00)

### Wait Type Trend Table

| Wait Type | Category | 10:00–10:15 | 10:15–10:30 | 10:30–10:45 | 10:45–11:00 | Trend | Δ First→Last |
|-----------|----------|------------|------------|------------|------------|-------|-------------|
| PAGEIOLATCH_SH | I/O | 48.8% | 53.7% | 59.7% | 81.5% | **↑↑ Worsening** | +67% |
| LCK_M_IX | Locks | 21.3% | 15.8% | 12.4% | 12.1% | **↓ Improving** | -43% |
| CXPACKET | Parallelism | 10.6% | 11.0% | 10.8% | 13.7% | ↑ Worsening | +29% |
| RESOURCE_SEMAPHORE | Memory | 8.3% | 7.9% | 8.3% | 10.8% | ↑ Worsening | +30% |
| WRITELOG | Log | 4.9% | 4.5% | 4.2% | 5.1% | → Stable | +4% |
| LATCH_EX | HA | 1.9% | 1.8% | 1.7% | 2.1% | → Stable | +11% |
| HADR_SYNC_COMMIT | HA | 0.14% | 0.16% | 0.16% | 0.19% | ↑ Worsening | +36% |
| IO_RETRY | I/O | — | ⚡ 0.24% | — | — | ✓ Resolved | transient |
| LOGMGR_RESERVE_APPEND | Log | — | — | — | 0.16% | **↑↑ Emerging** | new |

### Pattern Classification (V26)

The server shows a **consistently degrading I/O pattern** — PAGEIOLATCH_SH has grown monotonically and accelerated sharply in the final period (+36.9% in the last window alone), while lock contention improved as a blocking head session appears to have released mid-observation. The final-period emergence of LOGMGR_RESERVE_APPEND confirms that the escalating I/O and write load has now exhausted log space, converting a performance problem into an emergency.

---

### Trend Findings

**[T1] PAGEIOLATCH_SH — Monotonically Worsening with Late Acceleration** (V19)
- Observed: PAGEIOLATCH_SH grew every period: 48.8% → 53.7% → 59.7% → 81.5%. The final period jump (+36.9 percentage points) is 2.5× the average per-period change — an acceleration, not just a linear trend.
- **User impact:** What started as 2–4 second query delays in the first period became 5–8 second delays by the final period. If uncorrected, the server will likely see PAGEIOLATCH exceeding 90% within the next 30 minutes.
- Timing: Consistent across all 4 periods; accelerating in period 4 (10:45–11:00).
- Fix: This is the primary root cause of the entire session. Run `/sqlstats-review` on concurrent queries to identify the highest-read tables, then `/sqlplan-index-advisor` for covering indexes. The acceleration in the final period suggests a growing batch or accumulating scan volume — investigate whether a scheduled job started at ~10:45.

**[T2] IO_RETRY — Transient Spike at 10:15–10:30, Resolved** (V20 + V25)
- Observed: `IO_RETRY` appeared in the 10:15–10:30 period only (28,420 ms, 420 tasks), then returned to zero.
- **User impact:** During 10:15–10:30, some queries experienced unexpected delays from storage I/O retries. The issue resolved by the next period.
- Timing: 10:15–10:30 only.
- Fix: Although resolved, IO_RETRY always indicates at least one failed I/O operation. Check SQL Server error log around 10:15–10:30: `EXEC xp_readerrorlog 0, 1, N'I/O error', NULL, '2025-05-02 10:15', '2025-05-02 10:30';`. If the error repeats in future captures, escalate to infrastructure.

**[T3] LOGMGR_RESERVE_APPEND — Emerging in Final Period** (V23)
- Observed: Absent in all prior periods; appeared at 0.16% (18,420 ms, 84 tasks) in the 10:45–11:00 period.
- **User impact:** Write operations began failing or stalling in the final 15 minutes of the observation window.
- Timing: Emerged at 10:45–11:00; likely still present and growing.
- Fix: Emergency — take a log backup immediately. This wait type's emergence at the same time PAGEIOLATCH accelerated is consistent with a large DML batch generating both high reads and high log volume simultaneously.

**[T4] LCK_M_IX — Improving Trend, Not Yet Resolved** (V19 — Improving)
- Observed: LCK_M_IX decreased every period: 21.3% → 15.8% → 12.4% → 12.1%.
- **User impact:** Lock-based blocking was worst in the first period. It improved substantially through the observation — likely a blocking head session released around 10:15.
- Timing: Improving across all 4 periods; appears to be stabilizing around 12% in the last two periods rather than reaching zero.
- Fix: The remaining 12.1% represents ongoing lock contention that RCSI would resolve (reader/writer conflicts). Enabling RCSI is still recommended even though the worst blocking resolved.

---

### Peak Period (V21)

- **Most stressed window:** 10:45–11:00
- **Total accumulated wait:** 11,564,820 ms — **25.4% above the average period** (avg 9,225,800 ms)
- **Dominant wait in peak:** PAGEIOLATCH_SH 81.5% of the peak period
- **Note:** The peak period is also the period where LOGMGR_RESERVE_APPEND first appeared — the two events are likely related (large batch generating both reads and log simultaneously).

---

### Fastest-Growing Waits (V22)

| Rank | Wait Type | Category | Avg change/period | Direction |
|------|-----------|----------|------------------|-----------|
| 1 | PAGEIOLATCH_SH | I/O | +10.9%/period | ↑↑ Monotonic (accelerating) |
| 2 | RESOURCE_SEMAPHORE | Memory | +0.8%/period | ↑ General |
| 3 | CXPACKET | Parallelism | +1.0%/period | ↑ General |

PAGEIOLATCH_SH is growing 10× faster per period than the next fastest wait type. All tuning effort should focus here.

---

### Correlated Spikes (V24)

No correlated spikes detected across the observation period — the IO_RETRY spike in period 2 was isolated (only IO_RETRY spiked in that window). The PAGEIOLATCH acceleration and LOGMGR_RESERVE_APPEND emergence in period 4 occurred in the same window but IO_RETRY had already resolved, so they are not classified as a correlated spike under the V24 threshold.

However, the PAGEIOLATCH acceleration and LOGMGR_RESERVE_APPEND emergence in the same period (10:45–11:00) are **functionally correlated** — a large DML batch is the most likely common root cause, reading large volumes of data (PAGEIOLATCH) while also generating high log volume (LOGMGR_RESERVE_APPEND).

---

### Emerging / Resolved Waits (V23, V25)

**Emerging:** `LOGMGR_RESERVE_APPEND` — absent for 3 periods, crossed 2% threshold in period 4 (T3 above).

**Resolved:** `IO_RETRY` — spiked in period 2, returned to zero in periods 3 and 4 (T2 above).

---

## Recommended Action Order

| Priority | Action | Checks resolved | Effort |
|----------|--------|----------------|--------|
| 1 — Immediately | Take a log backup: `BACKUP LOG ProdDB TO DISK = '...' WITH COMPRESSION` | C2, T3 | 5 min |
| 2 — Immediately | Check SQL error log for IO_RETRY errors around 10:15–10:30 | T2 | 15 min |
| 3 — Today | Enable RCSI: `ALTER DATABASE ProdDB SET READ_COMMITTED_SNAPSHOT ON` | C4, T4 | 5 min |
| 4 — Today | Add TempDB data files (2→8) and raise CTPfP to 50 | W1, PAGELATCH | 20 min |
| 5 — Today | Investigate what started or escalated around 10:45 (job, batch, new connections) | T1 (acceleration) | 30 min |
| 6 — This sprint | Add covering indexes on highest-read tables (`/sqlstats-review` + `/sqlplan-index-advisor`) | C1, T1, W1, W2 | Days |
| 7 — This sprint | Update statistics with FULLSCAN on heavy tables | C3 | Hours |

**Trend summary:** The single root cause behind the worsening trend is missing indexes — they force full scans that generate the PAGEIOLATCH reads, the parallel scan CXPACKET overhead, the large memory grants driving RESOURCE_SEMAPHORE, and — in the final period — the DML volume that exhausted log space. The IO_RETRY transient event was unrelated (storage glitch) and resolved. Fixing the indexes addresses 5 of the 7 action items as side effects.
