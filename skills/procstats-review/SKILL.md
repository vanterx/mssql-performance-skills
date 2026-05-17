---
name: procstats-review
description: Analyze SQL Server procedure/trigger/function runtime stats collected from sys.dm_exec_procedure_stats into collect.proc_stats. Applies 20 checks (R1–R20) across four categories — top consumers, per-execution efficiency, pattern detection, and trend analysis. Use when pasting output from the report queries in scripts/collection/04_report_queries.sql.
triggers:
  - /procstats-review
  - /proc-stats
---

# SQL Server Procedure Stats Review Skill

## Purpose

Analyze runtime statistics collected from `sys.dm_exec_procedure_stats`,
`sys.dm_exec_trigger_stats`, and `sys.dm_exec_function_stats` into the `collect.proc_stats`
table. Applies 20 checks (R1–R20) across four categories:

- **R1–R5** — Top resource consumers: identify which procedure, trigger, or function is
  burning the most CPU, reads, or elapsed time in the collection interval
- **R6–R10** — Per-execution efficiency: flag objects that are expensive per call regardless
  of how often they run — high average CPU, high reads, parameter sniffing signals, spills
- **R11–R15** — Pattern detection: N+1 callers, chatty high-frequency procs, plan instability,
  workload concentration, infrequent-but-heavy outliers
- **R16–R20** — Trend analysis: worsening CPU/reads across snapshots, execution spikes,
  plan changes, new high-cost entries (requires ≥ 3 snapshots from Q5)

## Input

Accept any of:

- **Q1 output** (Top CPU) — paste the result grid from `04_report_queries.sql` Query 1
- **Q2 output** (Top Reads) — paste Query 2 result grid
- **Q3 output** (Top Callers) — paste Query 3 result grid
- **Q4 output** (Per-Execution Averages) — paste Query 4 result grid
- **Q5 output** (Trend / Time Series) — paste Query 5 result grid (requires ≥ 3 snapshots)
- **Combined paste** — paste two or more query outputs together; apply all applicable checks
- **Natural language description** — describe the metrics you see ("usp_GetOrders uses 80% of CPU")
- **Statement-level stats** — paste output from `collect.query_stats` using the report query in
  `scripts/collection/12_report_all_collections.sql` Section 2; all R-checks apply equally to
  statement-level data — just note the object_name may be NULL for ad-hoc SQL

For trend checks (R16–R20), Q5 output with ≥ 3 rows per object is required. State
"Cannot evaluate R16–R20 — trend data not provided" if Q5 is absent.

### Column Reference

| Column | Source | Notes |
|--------|--------|-------|
| `execs_in_interval` | `execution_count_delta` | Executions since last snapshot |
| `cpu_ms_per_sec` | `worker_time_per_sec` | CPU ms consumed per second of sample |
| `avg_cpu_ms` | `avg_worker_time_ms` | Avg CPU per execution (ms) |
| `avg_elapsed_ms` | `avg_elapsed_time_ms` | Avg wall-clock per execution (ms) |
| `max_cpu_ms` | `max_worker_time / 1000` | Single worst execution CPU (ms) |
| `avg_logical_reads` | computed | Avg 8-KB page reads per execution |
| `reads_per_sec` | computed | Logical reads per second |
| `avg_spills` | computed | Avg TempDb spill pages per execution |
| `physical_reads_delta` | delta | Total physical reads in interval |
| `physical_pct` | computed | Physical reads as % of logical (cache miss rate) |
| `execs_per_sec` | computed | Execution rate per second |
| `max_to_avg_cpu_ratio` | computed | max_cpu_ms / avg_cpu_ms — parameter sniffing signal |
| `cpu_to_elapsed_ratio` | computed | avg_cpu / avg_elapsed — > 1.5 = parallel; < 0.2 = blocking/IO |
| `sample_seconds` | delta SP | Duration of the collection interval |
| `cache_age_minutes` | computed | How long the current plan has been in cache |

---

## Thresholds Reference

| Metric | Info | Warning | Critical |
|--------|------|---------|----------|
| `cpu_ms_per_sec` (single proc) | — | ≥ 50 ms/s | ≥ 500 ms/s |
| Single proc share of total CPU delta | — | > 50% | > 80% |
| `avg_cpu_ms` per execution | — | ≥ 1,000 ms | ≥ 10,000 ms |
| `avg_logical_reads` per execution | — | ≥ 50,000 | ≥ 500,000 |
| Physical reads as % of logical | — | > 10% | > 50% |
| `execs_in_interval` | — | ≥ 10,000 | — |
| `execs_per_sec` (chatty) | — | ≥ 10/s | ≥ 100/s |
| `avg_spills` per execution | — | ≥ 1 | ≥ 10 |
| `cpu_to_elapsed_ratio` (parallel waste) | — | > 1.5 | > 3.0 |
| `cpu_to_elapsed_ratio` (blocking/IO wait) | — | < 0.2 | < 0.05 |
| `max_to_avg_cpu_ratio` (sniffing signal) | ≥ 3 | ≥ 10 | ≥ 100 |
| Top 3 procs share of total CPU delta | ≥ 70% | ≥ 90% | — |
| `avg_elapsed_ms` per execution | — | ≥ 5,000 ms | ≥ 30,000 ms |
| Trend: execution rate spike | — | latest > 2× mean | > 5× mean |
| Trend: CPU worsening (monotonic) | 2 snapshots | 3+ snapshots | — |

---

## Statement-Level Checks (R1–R5): Top Resource Consumers

Run these first. They identify which objects dominate the workload in the collection interval.
### R1 — CPU Hotspot
- **Trigger:** `cpu_ms_per_sec` ≥ 50 for a single object, OR that object's `total_worker_time_delta` represents > 50% of the sum across all objects in the result set
- **Severity:** Warning if ≥ 50 ms/s or > 50%; Critical if ≥ 500 ms/s or > 80%
- **Fix:** Run `/sqlplan-review` on this procedure's cached plan to identify the expensive operator. Check for missing indexes, implicit conversions, or missing parallelism. Use `OPTION (RECOMPILE)` as immediate mitigation if parameter sniffing is suspected (see R9).
### R2 — Read Hotspot
- **Trigger:** `reads_per_sec` ≥ 5,000 for a single object, OR that object's `total_logical_reads_delta` represents > 50% of total reads in the result
- **Severity:** Warning if ≥ 5,000 reads/s or > 50%; Critical if ≥ 50,000 reads/s or > 80%
- **Fix:** The object reads disproportionately from the buffer pool. Run `/sqlplan-index-advisor` on its execution plan. High `avg_logical_reads` (see R7) indicates a per-execution index problem; high `reads_per_sec` with low `avg_logical_reads` indicates high frequency (see R4/R12).
### R3 — Duration Hotspot
- **Trigger:** `avg_elapsed_ms` ≥ 5,000 ms AND `execs_in_interval` > 0
- **Severity:** Warning if ≥ 5,000 ms; Critical if ≥ 30,000 ms
- **Fix:** Objects with high elapsed time are holding connections and blocking dependent code. If `avg_elapsed_ms` >> `avg_cpu_ms` (see R8 blocking signal), investigate locking with `/sqlwait-review` or `/sqlplan-deadlock`. If `avg_elapsed_ms` ≈ `avg_cpu_ms`, the work itself is expensive — run `/sqlplan-review`.
### R4 — Execution Frequency Hotspot
- **Trigger:** `execs_in_interval` ≥ 10,000 in a single collection window
- **Severity:** Warning
- **Fix:** A highly executed object deserves extra scrutiny even if per-execution cost is low. Total resource consumption is execution count × per-call cost. Pair with R11 (N+1) and R12 (chatty) checks to understand the caller pattern.
### R5 — Physical I/O Hotspot (Cache Miss)
- **Trigger:** `physical_reads_delta` > 0 AND `physical_pct` > 10% (more than 1 in 10 page reads goes to disk)
- **Severity:** Warning if `physical_pct` > 10%; Critical if > 50%
- **Fix:** Data is not in the buffer pool. Root causes: (1) insufficient memory — check `sys.dm_os_memory_clerks`; (2) scans reading cold data — add covering indexes; (3) first execution after cache flush — monitor over multiple windows to see if physical reads decline.

---

## Node-Level Checks (R6–R10): Per-Execution Efficiency

Apply these regardless of execution count — an infrequent but expensive proc matters.
### R6 — High Average CPU per Execution
- **Trigger:** `avg_cpu_ms` ≥ 1,000 ms
- **Severity:** Warning if ≥ 1,000 ms; Critical if ≥ 10,000 ms
- **Fix:** The object does significant work per call. Capture its actual execution plan (`SET STATISTICS TIME ON` or SSMS actual plan) and run `/sqlplan-review`. Focus on the highest-cost operator. Common causes: full table scans from missing indexes, sort spills, hash join spills, large row sets.
### R7 — High Average Reads per Execution
- **Trigger:** `avg_logical_reads` ≥ 50,000 per execution
- **Severity:** Warning if ≥ 50,000; Critical if ≥ 500,000
- **Fix:** The object reads many buffer pool pages per call. At 8 KB per page, 50,000 reads = 400 MB of data touched per execution. Run `/sqlplan-index-advisor` on its plan to generate covering index DDL. Check for table scans, key lookups, and missing WHERE clause indexes.
### R8 — CPU-Elapsed Skew (Parallelism Waste or Blocking Signal)
- **Trigger:**
  - `cpu_to_elapsed_ratio` > 1.5: CPU > elapsed → object uses parallelism, but threads may be poorly utilized (CXPACKET waits)
  - `cpu_to_elapsed_ratio` < 0.2: elapsed >> CPU → most time is waiting, not executing (blocking, lock waits, I/O)
- **Severity:** Warning if ratio > 1.5 or < 0.2; Critical if > 3.0 or < 0.05
- **Fix (parallel waste):** Run `/sqlplan-review` and check N27 (thread skew) and S8 (ineffective parallelism). Consider reducing MAXDOP.
- **Fix (blocking/IO):** Run `/sqlwait-review` to identify the dominant wait type. If `PAGEIOLATCH`, investigate missing indexes. If `LCK_M_*`, investigate blocking chains or isolation level.
### R9 — Max vs Average CPU Skew (Parameter Sniffing Signal)
- **Trigger:** `max_to_avg_cpu_ratio` ≥ 10 (worst single execution used 10× the average CPU)
- **Severity:** Info if ≥ 3; Warning if ≥ 10; Critical if ≥ 100
- **Fix:** The plan was compiled for one parameter set but executed with a very different set. The worst execution was dramatically more expensive than the average. Add `OPTION (RECOMPILE)` as immediate mitigation. Long term: use `OPTION (OPTIMIZE FOR)`, filtered statistics, or a plan guide. Run `/sqlplan-review` on the bad-parameter plan.
### R10 — High Spills per Execution
- **Trigger:** `avg_spills` ≥ 1 (the object spills to TempDb on average at least once per execution)
- **Severity:** Warning if ≥ 1; Critical if ≥ 10
- **Fix:** The sort or hash operators inside the procedure are spilling to TempDb on most executions. This is usually caused by underestimated row counts (stale statistics or parameter sniffing). Run `/sqlplan-review` and look for N6 (sort spill risk) or N7 (hash spill risk). Update statistics and fix cardinality errors.

---

## Pattern Checks (R11–R15): Behavioral Patterns
### R11 — N+1 Caller Pattern
- **Trigger:** `execs_in_interval` ≥ 1,000 AND `avg_logical_reads` < 100 AND `avg_cpu_ms` < 10
- **Severity:** Info
- **Fix:** A lightweight procedure called thousands of times per interval — a classic N+1 pattern. Each call is cheap but the aggregate load is high. Look for application-layer loops calling this procedure once per record. Rewrite to accept a table-valued parameter (TVP) or use `IN (...)` to batch the calls. Check `cpu_ms_per_sec` — even cheap procs at high frequency add up.
### R12 — Chatty High-Frequency Procedure
- **Trigger:** `execs_per_sec` ≥ 10 (10 or more executions every second)
- **Severity:** Warning if ≥ 10/s; Critical if ≥ 100/s
- **Fix:** The procedure is called extremely frequently. Even with low per-call cost, plan cache lookups, lock acquisitions, and connection overhead add up. Evaluate: (1) Can calls be batched (TVP or set-based)? (2) Can results be cached at the application layer? (3) Is there a missing index that makes each call look up one row when it could be a set?
### R13 — Plan Instability / Frequent Recompile Signal
- **Trigger:** Multiple rows in the result set share the same `database_name` + `object_name` but have different `plan_handle` values, AND `cache_age_minutes` for at least one row is < 60
- **Severity:** Warning
- **Fix:** The procedure's plan is being recompiled or evicted frequently. Common causes: `WITH RECOMPILE` on the procedure definition, `OPTION (RECOMPILE)` on inner statements, schema changes, statistics updates mid-execution, or SET option mismatches from different callers. Run `DBCC FREEPROCCACHE` monitoring or Extended Events to capture the recompile reason.
### R14 — Workload Concentration
- **Trigger:** The top object in the result accounts for > 50% of total `total_worker_time_delta` across all rows in the result set, OR the top 3 account for > 90%
- **Severity:** Info if top 3 > 70%; Warning if top 1 > 50%; Warning if top 3 > 90%
- **Fix:** The workload is concentrated on a small number of objects. This is common and not inherently a problem — but it means tuning R1/R2/R6/R7 on the top object will have outsized impact. It also means if that object fails or degrades, the entire server is affected. Consider read-scale, caching, or workload distribution.
### R15 — Infrequent but Expensive
- **Trigger:** `execs_in_interval` ≤ 5 AND `avg_logical_reads` ≥ 100,000
- **Severity:** Info
- **Fix:** The object runs rarely but is extremely expensive per call — likely a batch job, report, or maintenance procedure. Even at low frequency, a 500,000-read execution blocks the buffer pool for other queries. Optimize with covering indexes (see R7), or schedule during off-peak hours with Resource Governor to cap its memory and CPU impact.

---

## Trend Checks (R16–R20): Requires Q5 Time-Series Output

Skip these checks and state "Cannot evaluate R16–R20 — Q5 trend data not provided" if
the input does not contain multiple rows per object across different `collection_time` values.
### R16 — Worsening CPU Trend
- **Trigger:** `avg_cpu_ms` or `cpu_ms_per_sec` increases monotonically across ≥ 3 consecutive snapshots for the same object
- **Severity:** Info (2 snapshots worsening); Warning (≥ 3 consecutive)
- **Fix:** The procedure is getting slower over time. Causes: (1) data growth making plans suboptimal — rebuild indexes and update statistics; (2) plan regression from statistics update — use Query Store to identify and force the prior good plan; (3) application change increasing workload per call — instrument with `SET STATISTICS IO, TIME ON`.
### R17 — Execution Rate Spike
- **Trigger:** `execs_in_interval` for the most recent snapshot > 2× the mean of prior snapshots for the same object
- **Severity:** Warning if > 2× mean; Critical if > 5× mean
- **Fix:** Something caused a sudden surge in call frequency — a batch job, application retry loop, or viral traffic. Identify the caller from `sys.dm_exec_sessions` or Extended Events. Check for application loops triggered by errors (error → retry → error spiral). Reduce call frequency or add circuit-breaker logic.
### R18 — Read Regression
- **Trigger:** `avg_logical_reads` increases by > 50% between the oldest and newest snapshot for the same object
- **Severity:** Warning
- **Fix:** The procedure is reading more pages per execution than it used to. Common causes: (1) plan regression — capture before/after plans with `/sqlplan-compare`; (2) data growth making a seek read more rows; (3) index dropped or disabled. Compare `plan_handle` across snapshots (see R20 — if it changed, the plan regressed).
### R19 — New High-Cost Entry
- **Trigger:** An object appears in the result for the first time (no prior rows in the time window) AND `cpu_ms_per_sec` ≥ 50 OR `avg_logical_reads` ≥ 50,000
- **Severity:** Info
- **Fix:** A new or previously-idle procedure appeared with high resource usage. This may indicate: (1) a newly deployed stored procedure; (2) a batch job that started running; (3) a procedure that was previously executing cheaply but now has a bad plan. Capture its execution plan and run `/sqlplan-review`.
### R20 — Plan Instability Signal (Trend)
- **Trigger:** The same `database_name` + `object_name` shows different `plan_handle` values across consecutive snapshots in the trend output
- **Severity:** Warning
- **Fix:** The execution plan changed during the monitoring window — plan recompilation, cache eviction, or statistics update triggered a new plan. Check whether `avg_cpu_ms` or `avg_logical_reads` worsened after the plan change (correlate with R16/R18). If so, this is a plan regression — use Query Store to force the prior plan while investigating the root cause.

---

## Output Format

Structure your report as follows. Follow every formatting rule below exactly — the reference
output in `example/procstats-review/proc_stats_output-analysis.md` demonstrates the expected
quality level.

---

### Section: Input Summary

```
## Procedure Stats Analysis

### Input Summary
- Source: collect.proc_stats — [Q1 / Q2 / Q3 / Q4 / Q5] output
- Sample window: N minutes (sample_seconds = X)
- Collection time: [collection_time from data]
- Objects in result: N (PROCEDURE: N, TRIGGER: N, FUNCTION: N)
- Trend snapshots: N  [or "N/A — single snapshot"]
```

---

### Section: Top Resource Consumers Table

Always include this table, populated from whatever input was provided:

```
### Top Resource Consumers

| Rank | Object | Type | DB | Execs | CPU ms/s | Avg CPU ms | Avg Reads | Reads/s |
|------|--------|------|----|-------|----------|------------|-----------|---------|
| 1    | ...    | PROC | .. | ...   | ...      | ...        | ...       | ...     |
```

---

### Section: Findings (Critical → Warnings → Info)

Each finding **must** include the check ID that fired:

```
### [C1 — R6] High Average CPU — dbo.usp_GetOrderHistory (avg 12,400 ms)
- **Observed:** avg_cpu_ms = 12,400, execs_in_interval = 48, cpu_ms_per_sec = 99.2
- **Impact:** [why this matters at runtime]
- **Fix:** [concrete action]
```

- **Object names in finding headers and Observed lines must use `schema_name.object_name`
  format when `schema_name` is present in the input.** Use bare `object_name` only when
  `schema_name` is NULL (ad-hoc SQL with no associated object).
  Correct: `dbo.usp_GetSalesReport` — Wrong: `usp_GetSalesReport`
- Findings reference each other by ID where one explains another (e.g. "root cause of C1").
- Parameter sniffing findings (R9) go in Info unless `max_to_avg_cpu_ratio` ≥ 10 (Warning).

---

### Section: Prioritized Action Order

Always end the findings with this table:

```
### Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Run /sqlplan-review on dbo.usp_GetOrderHistory | C1, W2 | 15 min |
| 2 — Today        | Add covering index on Orders(CustomerId) | W2 | 30 min |
```

---

### Section: Passed Checks

Format as a two-column table. Include every check explicitly evaluated and not triggered.

```
### Passed Checks

| Check | Result |
|-------|--------|
| R1 — CPU Hotspot | PASS — no object > 50% of total CPU delta (top proc = 34%) |
| R5 — Physical I/O | PASS — physical_reads_delta = 0 across all objects |

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*
```

---

## Notes

- When only Q1 or Q2 output is provided, checks R11–R15 that require execution count + per-exec
  averages together may not be fully evaluable — state the limitation explicitly.
- When Q5 trend data is absent, state "Cannot evaluate R16–R20" rather than skipping silently.
- Do not invent findings not triggered by the rules above.
- `total_worker_time` is cumulative microseconds in the DMV; `avg_worker_time_ms` is already
  converted to milliseconds in the report queries — do not double-convert.
- `avg_spills` = NULL means the SQL Server version does not support `total_spills`
  (pre-2017) — skip R10 and note the version limitation.

## Companion Skills

- **sqlplan-review** — Capture and analyze the actual execution plan for any procedure flagged
  by R1/R2/R6/R7. The plan reveals which operator inside the procedure is expensive.
- **sqlplan-index-advisor** — Generate CREATE INDEX DDL for procedures with high R7 (reads per
  execution). Feed the procedure's cached plan XML to the advisor.
- **sqlwait-review** — When R8 shows elapsed >> CPU (blocking signal), run wait statistics
  analysis to identify whether the bottleneck is LCK_M_*, PAGEIOLATCH, or RESOURCE_SEMAPHORE.
- **sqltrace-review** — Cross-reference procedure-level stats with individual statement traces
  to identify which statement inside the procedure is the bottleneck.
- **query-store-review** — When R20 (plan instability) or R16 (worsening CPU trend) fires,
  use Query Store analysis to identify the regressed plan and its first-seen date.
- **sqlplan-compare** — When R18 (read regression) fires and you have pre- and post-regression
  plans, diff them to understand exactly what changed in the query plan.
- **tsql-review** — Review the T-SQL source of flagged procedures for static anti-patterns
  (implicit conversions, non-sargable predicates, cursor loops) before capturing a plan.

- **mssql-performance-review** — Orchestrator that routes mixed artifacts to multiple specialised skills (this one included), runs an adversarial root-cause check, and produces a single consolidated report with evidence chain, risk-rated fixes, and rollback. Use when you have several artifact types together or describe a symptom without knowing which skill to run.
