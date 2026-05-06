# Procedure Stats Analysis — Trend

> **Input:** `example/procstats-review/proc_stats_trend.txt` — Q5 (Trend / Time Series)
> Run with: `/procstats-review example/procstats-review/proc_stats_trend.txt`

### Input Summary
- Source: collect.proc_stats — Q5 (Trend / Time Series) output
- Sample window: 5 minutes per snapshot (sample_seconds = 300)
- Collection times: 08:00–08:15 (4 snapshots, 15-minute window)
- Objects in result: 2 (PROCEDURE: 2)
- Trend snapshots: 4 per object — R16–R20 fully evaluable

---

### Top Resource Consumers (latest snapshot — 08:15)

| Rank | Object | Type | DB | Execs | CPU ms/s | Avg CPU ms | Avg Reads | Reads/s |
|------|--------|------|----|-------|----------|------------|-----------|---------|
| 1 | `dbo.usp_GetSalesReport` | PROC | SalesDB | 19 | 981.0 | 15,484 | 428,000 | 2,712 |
| 2 | `dbo.usp_SyncInventory` | PROC | SalesDB | 4,350 | 31.8 | 2,192 | 8,520 | 1,240 |

---

## Critical Issues

### [C1 — R1] CPU Hotspot — dbo.usp_GetSalesReport (981 ms/s, worsening)
- **Observed:** `cpu_ms_per_sec` reached 981.0 in the 08:15 snapshot, up from 312.4 at 08:00. Represents > 95% of total CPU delta across both objects.
- **Impact:** CPU consumption tripled in 15 minutes with only a 36% increase in execution count (14 → 19 execs/interval). The work per call is getting more expensive, not just the volume.
- **Fix:** This is a worsening trend requiring immediate capture of the current execution plan. Run `/sqlplan-review` on the cached plan now — the plan handle is stable (same across all 4 snapshots), meaning no recompile has occurred. The issue is the plan itself against growing data.

### [C2 — R6] High Average CPU — dbo.usp_GetSalesReport (15,484 ms at 08:15, up from 6,694 ms)
- **Observed:** `avg_cpu_ms` increased from 6,694 ms at 08:00 to 15,484 ms at 08:15 — 2.3× worse in 15 minutes.
- **Impact:** Each execution now takes ~15 seconds of CPU. At 19 executions/interval, that is 294 seconds of CPU consumed in a 300-second window — the server is at capacity.
- **Fix:** Same root cause as C1. The plan has not changed (stable plan_handle) but the cost per execution is rising. Likely cause: data growth making a scan touch more rows, stale statistics causing a wrong row estimate, or a parameter value shift driving a suboptimal plan path. Update statistics immediately: `UPDATE STATISTICS SalesDB.dbo.[target-table] WITH FULLSCAN;`

---

## Warnings

### [W1 — R16] Worsening CPU Trend — dbo.usp_GetSalesReport (monotonic, 4 snapshots)
- **Observed:**

  | collection_time | avg_cpu_ms | cpu_ms_per_sec | execs |
  |-----------------|-----------|----------------|-------|
  | 08:00 | 6,694 | 312.4 | 14 |
  | 08:05 | 7,847 | 418.2 | 16 |
  | 08:10 | 14,042 | 842.5 | 18 |
  | 08:15 | 15,484 | 981.0 | 19 |

  CPU per execution doubled between 08:05 and 08:10 — the inflection point. Execution count rose only modestly (+13%) but avg CPU rose 79%. Something changed at or before 08:10.

- **Impact:** If the trend continues, 08:20 will exceed 1,000+ ms/s and the server will be fully saturated. This is not a gradual drift — it has acceleration.
- **Fix:** Check what happened around 08:05–08:10: statistics job, index maintenance, parameter distribution change, or data load. Compare `avg_logical_reads` — it also increased (289K → 428K), suggesting the plan is reading more pages per call, consistent with data growth hitting a tipping point in a sort/hash operator.

### [W2 — R18] Read Regression — dbo.usp_GetSalesReport (+48% in 15 minutes)
- **Observed:** `avg_logical_reads` increased from 289,000 at 08:00 to 428,000 at 08:15 — a 48% increase.
- **Impact:** 48% more pages read per execution despite the same plan handle. This is characteristic of data growth crossing a threshold that changes how many rows a scan/hash operation touches, rather than a plan change.
- **Fix:** Verify table row counts on the tables this procedure reads. If row count grew significantly since the plan was compiled, update statistics to let the optimizer resize memory grants and join strategies. The stable plan_handle (R20 PASS) rules out a plan change as the cause.

### [W3 — R3] Duration Hotspot — dbo.usp_GetSalesReport (avg 52,800 ms elapsed at 08:15)
- **Observed:** `avg_elapsed_ms` = 52,800 ms (52 seconds), up from 6,820 ms at 08:00. cpu_to_elapsed_ratio = 15,484 / 52,800 = **0.29** — elapsed is 3.4× CPU.
- **Impact:** Wall-clock time grew 7.7× while CPU only grew 2.3×. The gap between CPU and elapsed widened sharply — at 08:10 the procedure started waiting substantially. This could be memory grant queuing (RESOURCE_SEMAPHORE) caused by the larger grant now requested due to more rows being processed.
- **Fix:** Run `/sqlwait-review` to check for RESOURCE_SEMAPHORE waits. The growing read count is inflating the optimizer's memory grant request — run `OPTION (RECOMPILE)` to get a fresh grant per execution, or `OPTION (OPTIMIZE FOR UNKNOWN)` to use average density instead of the potentially skewed sniffed parameter.

---

## Info

### [I1 — R14] Workload Concentration — dbo.usp_GetSalesReport dominates CPU
- **Observed:** At 08:15, dbo.usp_GetSalesReport accounts for 981/(981+31.8) = **96.8%** of total CPU across both monitored objects.
- **Impact:** The entire server's CPU health depends on this single procedure. With the worsening trend (W1), any further increase will saturate available capacity.
- **Fix:** Prioritization signal — all remediation effort should focus on dbo.usp_GetSalesReport.

> **Note:** R17 (execution rate spike), R19 (new entry), R20 (plan instability) all PASS — see Passed Checks below.

---

## Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Capture current plan: `sql/sqlplan/01_capture_from_cache.sql` → run `/sqlplan-review` | C1, C2 | 15 min |
| 2 — Immediately | `UPDATE STATISTICS SalesDB.dbo.[tables] WITH FULLSCAN` | W1, W2, W3 | 10 min |
| 3 — Today | Add `OPTION (RECOMPILE)` to dbo.usp_GetSalesReport as interim mitigation | W3 | 5 min |
| 4 — Today | Run `/sqlplan-index-advisor` on captured plan | W2 | 30 min |
| 5 — Monitor | Collect next 3 snapshots after stats update — confirm avg_cpu_ms declining | W1 | ongoing |

---

## Passed Checks

| Check | Result |
|-------|--------|
| R17 — Execution Rate Spike | PASS — execution count rose gradually (14→19 over 15 min), not a sudden spike (< 2× mean) |
| R19 — New High-Cost Entry | PASS — dbo.usp_GetSalesReport present in all 4 snapshots; not a new entrant |
| R20 — Plan Instability | PASS — plan_handle identical across all 4 snapshots; no plan change occurred |
| R11 — N+1 Pattern | PASS — dbo.usp_GetSalesReport has avg_logical_reads 289K-428K (far above the < 100 reads threshold) |
| R13 — Frequent Recompile | PASS — single plan_handle per object, cache_age_minutes increasing normally |
| R4 — Execution Frequency | PASS — 14-19 execs/interval (below 10,000 threshold) |
| R5 — Physical I/O | CANNOT EVALUATE — physical_reads_delta not present in Q5 output; run Q2 for physical read analysis |
| R8 — CPU-Elapsed Skew | PARTIAL — at 08:15 ratio = 0.29 (blocking/IO signal) flagged as W3; earlier snapshots within normal range |
