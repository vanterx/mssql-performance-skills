# Procedure Stats Analysis

> **Input:** `skills/procstats-review/examples/proc_stats_output.txt` — Q1 (Top CPU Consumers)
> Run with: `/procstats-review skills/procstats-review/examples/proc_stats_output.txt`

### Input Summary
- Source: collect.proc_stats — Q1 (Top CPU Consumers) output
- Sample window: 5 minutes (sample_seconds = 300)
- Collection time: 2025-05-04 09:15:00
- Objects in result: 10 (PROCEDURE: 9, TRIGGER: 1, FUNCTION: 0)
- Trend snapshots: N/A — single snapshot (R16–R20 cannot be evaluated)

---

### Top Resource Consumers

| Rank | Object | Type | DB | Execs | CPU ms/s | Avg CPU ms | Avg Reads | Reads/s |
|------|--------|------|----|-------|----------|------------|-----------|---------|
| 1 | `dbo.usp_GetSalesReport` | PROC | SalesDB | 18 | 842.5 | 14,042 | 412,000 | 1,242 |
| 2 | `dbo.usp_SyncInventory` | PROC | SalesDB | 4,210 | 31.2 | 2,220 | 8,400 | 1,168 |
| 3 | `dbo.usp_SearchCustomers` | PROC | SalesDB | 92,840 | 18.4 | 59 | 12 | 3,713 |
| 4 | `dbo.usp_ProcessPayment` | PROC | SalesDB | 1,240 | 8.2 | 1,984 | 2,100 | 865 |
| 5 | `dbo.usp_GetOrderHistory` | PROC | SalesDB | 8,420 | 6.1 | 217 | 18,400 | 5,140 |
| 6 | `dbo.usp_GeneratePDF` | PROC | SalesDB | 3 | 0.8 | 80,000 | 24,000 | 0.2 |
| 7 | `dbo.usp_CleanupSessions` | PROC | SalesDB | 1 | 0.1 | 30,000 | 920,000 | 0.1 |
| 8 | `dbo.usp_MonthlyRevenue` | PROC | ReportDB | 4 | 0.0 | 0 | 320,000 | 0.4 |

**Total CPU delta across all objects:** ~922 ms/s
`dbo.usp_GetSalesReport` = 842.5 / 922 = **91.4% of total CPU** — extreme concentration (R14: Critical).

---

## Critical Issues

### [C1 — R1] CPU Hotspot — dbo.usp_GetSalesReport (842.5 ms/s, 91.4% of total)
- **Observed:** `cpu_ms_per_sec = 842.5`, `execs_in_interval = 18`, `avg_cpu_ms = 14,042`. This single procedure consumed 91.4% of all CPU across 10 monitored objects during the 5-minute window.
- **Impact:** Effective monopolisation of one CPU core per execution. At 18 executions in 5 minutes (one every 17 seconds), any increase in call frequency or data volume will saturate available CPU. All other workloads compete for the remaining 8.6%.
- **Fix:** Capture the actual execution plan immediately — this plan has been in cache for only 22 minutes, so it is fresh. Run `/sqlplan-review` on it. With `avg_logical_reads = 412,000` (see C2) the dominant cost is almost certainly a full scan. Run `/sqlplan-index-advisor` to generate covering index DDL.

### [C2 — R6] High Average CPU per Execution — dbo.usp_GetSalesReport (14,042 ms avg, 288,400 ms max)
- **Observed:** `avg_cpu_ms = 14,042` (14 seconds average), `max_cpu_ms = 288,400` (4.8 minutes worst case).
- **Impact:** Each call burns 14 seconds of CPU on average. The 288-second worst case (`max_to_avg_cpu_ratio = 288,400 / 14,042 = 20.5`) signals parameter sniffing — see C3. At 14 s/call × 18 calls = 252 seconds of CPU consumed in a 300-second interval.
- **Fix:** (1) Capture the current plan and run `/sqlplan-review`. (2) Address the parameter sniffing (C3). (3) After fixing sniffing, the average cost may drop dramatically.

### [C3 — R9] Parameter Sniffing Signal — dbo.usp_GetSalesReport (max_to_avg ratio: 20.5×)
- **Observed:** `max_cpu_ms = 288,400`, `avg_cpu_ms = 14,042`, ratio = **20.5×**. The worst single execution used 20× the average CPU.
- **Impact:** The plan was compiled for a parameter set that returns a small result (fast plan). Some executions receive parameters returning far more data, turning a nested loops join into an N+1 catastrophe. The 288-second execution likely caused timeouts or user-visible slowness.
- **Fix:**
  ```sql
  -- Option 1: Recompile per execution (if < a few times/sec)
  ALTER PROCEDURE dbo.usp_GetSalesReport WITH RECOMPILE;

  -- Option 2: Optimize for the typical (large) parameter value
  -- (add to the problem statement inside the procedure)
  OPTION (OPTIMIZE FOR (@StartDate = '2025-01-01'));

  -- Option 3: Local variable to break sniffing
  DECLARE @LocalStart date = @StartDate;
  SELECT ... WHERE ReportDate >= @LocalStart;
  ```

---

## Warnings

### [W1 — R3] Duration Hotspot — dbo.usp_ProcessPayment (avg 39,820 ms elapsed)
- **Observed:** `avg_elapsed_ms = 39,820`, `avg_cpu_ms = 1,984`. cpu-to-elapsed ratio = 1,984 / 39,820 = **0.050** — 95% of time is spent waiting, not computing.
- **Impact:** Payment procedure takes ~40 seconds per call but only 2 seconds of CPU. This is a blocking signal (R8). With 1,240 executions in 5 minutes (4/sec), long-running payments are holding locks that block other payment attempts, creating a queue of blocked sessions.
- **Fix:** Run `/sqlwait-review` to confirm `LCK_M_X` or `LCK_M_U` waits. Investigate the locking pattern — the payment procedure likely holds a row lock on the Orders/Payments table while performing network I/O (e.g., calling an external payment gateway). Move the external call outside the transaction boundary.

### [W2 — R8] CPU-Elapsed Skew — dbo.usp_ProcessPayment (ratio 0.050 — blocking signal)
- **Observed:** `avg_cpu_ms = 1,984`, `avg_elapsed_ms = 39,820`, ratio = 0.050 (threshold < 0.2).
- **Impact:** Confirms W1. The procedure is blocked for 95% of its execution time. See W1 for root cause and fix.
- **Fix:** See W1.

### [W3 — R7] High Average Reads — dbo.usp_GetSalesReport (412,000 reads/execution)
- **Observed:** `avg_logical_reads = 412,000`. At 8 KB/page, each execution reads ~3.2 GB of buffer pool.
- **Impact:** 18 executions × 412,000 reads = 7.4 million logical reads in 5 minutes from this one procedure. This evicts pages used by other queries and causes physical reads (see W4).
- **Fix:** Run `/sqlplan-index-advisor` to generate covering indexes. With `physical_reads_delta = 84,000` over 18 executions = 4,667 physical reads/execution, approximately 1.1% cache miss rate — acceptable, but the volume means even 1% = significant disk I/O.

### [W4 — R5] Physical I/O — dbo.usp_GetSalesReport (84,000 physical reads in interval)
- **Observed:** `physical_reads_delta = 84,000`, `avg_logical_reads = 412,000`. Physical % = 84,000 / (18 × 412,000) = 1.1% — below Warning threshold, but worth noting given the absolute volume.
- **Impact:** 84,000 physical reads in 5 minutes = 280/sec to disk. Given SSD storage, this is manageable but indicates the working set does not fully fit in buffer pool.
- **Fix:** Address R7 first — reduce logical reads per execution with covering indexes. Physical reads will drop proportionally.

### [W5 — R10] High Spills — dbo.usp_GetSalesReport (avg 12.4 spills/execution)
- **Observed:** `avg_spills = 12.4`. Every execution spills to TempDb an average of 12 times.
- **Impact:** TempDb spills are caused by underestimated memory grants. Combined with C3 (parameter sniffing causing wrong row estimates), the optimizer is allocating memory for a small result set then encountering 10× more rows at runtime. 12 spill events per execution × 18 executions = 216 TempDb write operations in 5 minutes from this one procedure.
- **Fix:** Fix parameter sniffing (C3) first — correct row estimates will lead to correct memory grants and eliminate spills. Then run `/sqlplan-review` to check N6 (sort spill risk) and N7 (hash spill risk).

### [W6 — R12] Chatty Procedure — dbo.usp_SearchCustomers (309 executions/sec)
- **Observed:** `execs_in_interval = 92,840`, `sample_seconds = 300`, `execs_per_sec = 92,840 / 300 = 309/sec`.
- **Impact:** 309 calls/second is extremely high. Even at 0 ms avg CPU and 12 avg reads, this is 309 plan cache lookups, 309 permission checks, and 309 lock acquisitions per second. The aggregate reads alone: 309/sec × 12 reads = 3,708 reads/sec. Combined `reads_per_sec` in the data confirms: 3,713.
- **Fix:** Investigate the calling pattern — 309/sec is almost certainly an N+1 loop. Check R11.

### [W7 — R14] Workload Concentration — Top 1 proc: 91.4% of CPU
- **Observed:** `dbo.usp_GetSalesReport` accounts for 91.4% of total CPU delta in the result (842.5 of 922 ms/s). Top 3 procedures = 99.1%.
- **Impact:** The entire server's CPU workload depends on one procedure. Any degradation (see C3, parameter sniffing) immediately saturates the server. There is no capacity headroom.
- **Fix:** Prioritization signal — fix C1/C2/C3 on `dbo.usp_GetSalesReport` first. All other work is secondary.

### [W8 — R4] Execution Frequency — dbo.usp_SearchCustomers (92,840 in interval)
- **Observed:** `execs_in_interval = 92,840` — the highest call count in the result.
- **Impact:** 92,840 executions in 5 minutes drives 3,713 reads/sec despite tiny per-call cost. Combined with W6 (chatty), this is the classic N+1 signature. See I2.
- **Fix:** See W6, I2.

---

## Info

### [I1 — R15] Infrequent but Expensive — dbo.usp_CleanupSessions (1 exec, 920,000 reads)
- **Observed:** `execs_in_interval = 1`, `avg_logical_reads = 920,000`, `avg_elapsed_ms = 284,000` (4.7 minutes), `physical_reads_delta = 420,000` (physical % = 45.7% — near critical threshold).
- **Impact:** This procedure ran once in the 5-minute window and was not a top CPU consumer — but each execution reads 920,000 pages (~7.2 GB) and has a 45.7% physical read rate. When it runs during peak hours it will monopolise the buffer pool and disk for nearly 5 minutes.
- **Fix:** Run `/sqlplan-review` on its plan — 920,000 logical reads strongly suggests a clustered index scan on a large table. Add a covering index on the cleanup predicate (likely `WHERE CreatedDate < @cutoff`). Schedule during off-peak with Resource Governor to cap its I/O impact.

### [I2 — R11] N+1 Caller Pattern — dbo.usp_SearchCustomers (92,840 execs, 12 reads/call, 0 CPU)
- **Observed:** `execs_in_interval = 92,840`, `avg_logical_reads = 12`, `avg_cpu_ms = 59` (actually below R11's < 10 ms threshold, but the execution pattern is characteristic).
- **Impact:** Application code is calling this procedure per-customer in a loop. 12 reads/call at 309 calls/sec = 3,700 reads/sec aggregate with zero benefit that could not be achieved in one set-based call.
- **Fix:** Rewrite to accept a TVP of customer IDs and return all results in one call:
  ```sql
  CREATE TYPE dbo.IdList AS TABLE (Id int NOT NULL PRIMARY KEY);

  ALTER PROCEDURE dbo.usp_SearchCustomers
      @CustomerIds dbo.IdList READONLY  -- replace @SingleId
  AS
      SELECT c.* FROM dbo.Customers c
      JOIN @CustomerIds i ON c.CustomerId = i.Id;
  ```

### [I3 — R13] Plan Instability — dbo.usp_GeneratePDF (cache_age_minutes = 8)
- **Observed:** `cache_age_minutes = 8` — the plan for this procedure has been in cache only 8 minutes, much shorter than its peers. Combined with 3 executions and `avg_cpu_ms = 80,000`, this may indicate a recompile after a statistics update or schema change.
- **Impact:** Frequent recompilation means this expensive procedure may receive a different (possibly worse) plan on each cache eviction. At 80 seconds avg CPU per call, a bad recompile is immediately visible.
- **Fix:** Monitor `plan_handle` across the next 3–4 collection intervals. If it changes, run Extended Events to capture the recompile reason. Consider `OPTION (OPTIMIZE FOR UNKNOWN)` or Query Store plan forcing if recompile produces unstable plans.

> **Note:** R16–R20 (trend checks) cannot be evaluated — Q5 trend data was not provided. Run Q5 from `04_report_queries.sql` and re-run `/procstats-review` with that output to assess worsening trends.

---

## Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Add `WITH RECOMPILE` or `OPTION (OPTIMIZE FOR)` to `dbo.usp_GetSalesReport` | C3, C2, W5 | 15 min |
| 2 — Today | Run `/sqlplan-review` on `dbo.usp_GetSalesReport` plan + generate index DDL | C1, C2, W3 | 1 hr |
| 3 — Today | Investigate blocking in `dbo.usp_ProcessPayment` — move external call outside transaction | W1, W2 | 2 hrs |
| 4 — This sprint | Rewrite `dbo.usp_SearchCustomers` caller to use TVP batch pattern | W6, W8, I2 | 4 hrs |
| 5 — This sprint | Add covering index on `dbo.usp_CleanupSessions` cleanup predicate | I1 | 1 hr |
| 6 — Monitor | Track `plan_handle` for `dbo.usp_GeneratePDF` across next 3 intervals | I3 | 30 min |

---

## Passed Checks

| Check | Result |
|-------|--------|
| R2 — Read Hotspot (per-object) | PASS — no single object > 50% of total reads delta (dbo.usp_GetOrderHistory leads at 34%) |
| R4 — Execution Frequency Hotspot | PASS — dbo.usp_SearchCustomers at 92,840 is flagged under W8; absolute threshold ≥ 10,000 also fires W8 |
| R5 — Physical I/O Hotspot | PASS — physical_pct for top objects: dbo.usp_GetSalesReport 1.1%, dbo.usp_CleanupSessions 45.7% (below Critical 50%) |
| R13 — Plan Instability (multi-handle same interval) | PASS — each object shows a single plan_handle in this snapshot; I3 flags short cache_age as a signal |
| R15 — Infrequent but Expensive | PASS — dbo.usp_CleanupSessions flagged as Info (I1); no additional objects with execs ≤ 5 AND reads ≥ 100K |
| R16–R20 — Trend checks | CANNOT EVALUATE — Q5 trend data not provided |
| S/N checks (sqlplan-review) | NOT APPLICABLE — plan XML not in input; run /sqlplan-review separately |
