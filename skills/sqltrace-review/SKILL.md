---
name: sqltrace-review
description: Analyze SQL Server trace files and Extended Events output to identify workload-level performance patterns. Applies 20 checks (X1–X12 event-level, X13–X20 workload aggregate) covering long-running queries, high-frequency N+1 patterns, parameter sniffing signals, recompilations, lock timeouts, hash/sort warnings, and top resource consumers. Use when a user provides Profiler trace output, sys.fn_trace_gettable() results, or Extended Events session data.
triggers:
  - /sqltrace-review
  - /trace-review
---

# SQL Server Trace / Extended Events Review Skill

## Purpose

Analyze workload-level diagnostic data from SQL Server Profiler traces (`.trc`), Extended Events sessions (`.xel`), `sys.fn_trace_gettable()` output, or XE session query results. Produce a ranked summary of top resource consumers and a prioritized findings report covering 20 checks (X1–X20) across event patterns and cross-event workload aggregates.

Trace analysis reveals patterns that no single-query artifact can show: which queries run thousands of times per minute, which have wildly inconsistent durations (parameter sniffing), how many recompilations are happening globally, and whether spill or lock events correlate with slow periods.

## Input

Accept any of:
- `sys.fn_trace_gettable()` query results — paste the tabular output (tab-separated, CSV, or grid)
- Extended Events session query results — any column layout containing event name, SQL text, duration, CPU, reads
- SSMS Profiler trace grid — copy-paste from the trace window
- A `.trc` or `.xel` file path (describe what to extract if the file cannot be read directly)
- A natural-language description of trace contents ("the trace shows 48,000 executions of a stored proc in 60 seconds, each reading 3,200 pages")

**Duration units:** SQL Profiler `.trc` Duration column = **microseconds**. Extended Events `duration` = **microseconds**. CPU = **milliseconds** throughout. Normalize all duration values to milliseconds before applying thresholds and displaying results.

**Query normalization:** Group events by normalized query text — replace literal values and parameter values with placeholders to identify the same logical query across executions. Example: `SELECT * FROM Orders WHERE Id = 42` and `SELECT * FROM Orders WHERE Id = 99` normalize to the same pattern.

## How to Run

1. **Parse input**: identify which columns are present. Map to canonical fields: `event_class`, `sql_text`, `duration_us`, `cpu_ms`, `logical_reads`, `writes`, `spid`, `app_name`, `login_name`, `db_name`, `start_time`.
2. **Classify events**: use event class number or XE event name to categorize each row (see Event Class Reference below).
3. **Normalize queries**: group `SQL:BatchCompleted` and `RPC:Completed` events by normalized query pattern. Compute per-pattern: execution count, total/avg/min/max for duration, CPU, reads.
4. **Run X1–X12 (event-level checks)**: scan each event row for individual threshold violations.
5. **Run X13–X20 (workload-level checks)**: aggregate across all events and normalized patterns.
6. **Build top-consumer tables**: top 5 by CPU, by reads, by duration.
7. **Output**: produce the structured report defined in Output Format.

---

## Event Class Reference

| Profiler Class | XE Event Name | Category |
|---------------|---------------|----------|
| 10 | `rpc_completed` | Query |
| 12 | `sql_batch_completed` | Query |
| 13 | `sql_batch_starting` | Query |
| 16 | `attention` | Connection |
| 20 | `error_reported` (login fail) | Security |
| 37 | `sql_statement_recompile` | Recompile |
| 50 | `sql_statement_recompile` | Recompile |
| 54 | `lock_timeout` | Locking |
| 59 | `xml_deadlock_report` | Locking |
| 65 | `hash_warning` | Warning |
| 69 | `sort_warning` | Warning |
| 79 | `missing_column_statistics` | Statistics |
| 80 | `missing_join_predicate` | Warning |
| 92 | `data_file_auto_grow` | Storage |
| 93 | `log_file_auto_grow` | Storage |
| 146 | `query_post_execution_showplan` | Plan |

---

## Thresholds Reference

| Metric | Value |
|--------|-------|
| Long duration — warning | duration ≥ 5,000 ms |
| Long duration — critical | duration ≥ 30,000 ms |
| High CPU — warning | cpu ≥ 5,000 ms |
| High reads — warning | logical_reads ≥ 100,000 |
| High reads — critical | logical_reads ≥ 1,000,000 |
| High writes — warning | writes ≥ 10,000 pages |
| Error severity — critical | error severity ≥ 20 |
| Recompile threshold | ≥ 3 recompile events for the same object/query in trace window |
| High-frequency query | ≥ 1,000 executions of the same normalized query |
| Parameter sniffing signal | max duration > 10× min duration, same normalized query, ≥ 10 executions |
| Global recompile ratio | recompile events > 5% of (SQL:BatchCompleted + RPC:Completed) events |
| Workload concentration | top 3 normalized queries > 80% of total CPU |
| Ad-hoc ratio | distinct query texts / total query events > 80% |

---

## Event-Level Checks (X1–X12)

Evaluate per-event rows. A check fires if any single event meets its trigger condition.
### X1 — Long-Duration Query
- **Trigger:** Any `SQL:BatchCompleted`, `RPC:Completed`, or `sql_statement_completed` event where `duration ≥ 5,000 ms` (warning) or `≥ 30,000 ms` (critical). Duration column is in microseconds — divide by 1,000 before comparing.
- **Severity:** Warning (5 s – 29.9 s); Critical (≥ 30 s)
- **Fix:** Capture the execution plan for this query and run `/sqlplan-review`. Run `/sqlstats-review` on `SET STATISTICS IO, TIME ON` output. Identify whether the query is CPU-bound (X2) or wait-bound (high duration, low CPU).
### X2 — High CPU Query
- **Trigger:** Any completed query event where `cpu ≥ 5,000 ms`
- **Severity:** Warning
- **Fix:** High CPU indicates scans, large sorts, hash joins, or implicit conversions. Use `/sqlplan-review` to find the dominant operator. Use `/sqlplan-index-advisor` for covering index recommendations.
### X3 — High Logical Reads Query
- **Trigger:** Any completed query event where `logical_reads ≥ 100,000` (warning) or `≥ 1,000,000` (critical)
- **Severity:** Warning (≥ 100 K); Critical (≥ 1 M)
- **Fix:** Run `/sqlstats-review` on this query's STATISTICS IO output to identify the highest-read table. Run `/sqlplan-index-advisor` to get a covering index. Each 8 KB page read = ~8 MB of data accessed.
### X4 — High Write Count
- **Trigger:** Any completed query event where `writes ≥ 10,000 pages`
- **Severity:** Warning
- **Fix:** Large write counts indicate bulk DML, large sorts spilling to tempdb, or excessive worktable writes. If the query is a SELECT, writes indicate a tempdb spill — check X9 (Sort Warning) and X10 (Hash Warning). If DML, verify it was intentional and consider batching (see `/tsql-review` W7).
### X5 — Attention Event (Client Timeout or Cancel)
- **Trigger:** Any event with class 16 (`Attention`) or XE event `attention`
- **Severity:** Warning
- **Fix:** The client disconnected or cancelled the query — either a command timeout was hit or the user cancelled manually. The query was running long enough to trigger the client's timeout. Run `/sqlplan-review` on the query to understand why it runs long. Consider increasing timeout only after optimizing the query.
### X6 — Lock Timeout Event
- **Trigger:** Any event with class 54 (`Lock:Timeout`) or XE event `lock_timeout`
- **Severity:** Warning
- **Fix:** A session waited for a lock and timed out (LOCK_TIMEOUT setting > 0). The blocking session holds a lock this query needs. Investigate: add a missing index to reduce lock duration, switch to READ_COMMITTED_SNAPSHOT isolation, or use `/sqlplan-deadlock` if deadlock graphs are also present.
### X7 — Recompile Event
- **Trigger:** ≥ 3 recompile events (class 37 or 50, XE `sql_statement_recompile`) for the same stored procedure or normalized query within the trace window
- **Severity:** Warning
- **Fix:** Repeated recompilations are CPU-expensive and indicate plan instability. Common causes: schema changes to referenced objects mid-execution, SET option changes between calls, table variable row count changes after first reference, use of `OPTION(RECOMPILE)` in a hot path, or statistics updates. See `/tsql-review` T28 for OPTION(RECOMPILE) trade-offs.
### X8 — Exception / Error Event
- **Trigger:** Any event with class 33 (Exception) or XE `error_reported` where severity < 20 (warning) or ≥ 20 (critical)
- **Severity:** Warning (severity < 20 — informational/user errors); Critical (severity ≥ 20 — fatal/hardware errors)
- **Fix:** Log the error number and message. Severity ≥ 20 errors indicate server-level problems (out of memory, disk errors, corruption) — escalate immediately. Lower severity errors (deadlock victim 1205, constraint violation 547, duplicate key 2627) are application logic issues — review the calling code.
### X9 — Sort Warning Event
- **Trigger:** Any event with class 69 (`Sort Warnings`) or XE `sort_warning`
- **Severity:** Warning
- **Fix:** A sort operator ran out of its memory grant and spilled to tempdb. This is the same condition as `sqlplan-review` checks N41–N43. Fix: update statistics (stale stats → bad row estimate → wrong grant), add an index that pre-sorts the data (eliminating the Sort operator), or use `OPTION (MIN_GRANT_PERCENT = n)` to force a larger grant.
### X10 — Hash Warning Event (Bailout or Recursion)
- **Trigger:** Any event with class 65 (`Hash Warning`) or XE `hash_warning`
- **Severity:** Warning
- **Fix:** A hash join or hash aggregate ran out of memory and either bailed out to a less efficient strategy or recursively partitioned to disk. Same root cause as Sort Warning — stale statistics, missing index on a join column, or insufficient memory grant. Use `/sqlplan-review` to identify the spilling Hash Match operator (N41).
### X11 — Missing Column Statistics Event
- **Trigger:** Any event with class 79 (`Missing Column Statistics`) or XE `missing_column_statistics`
- **Severity:** Info
- **Fix:** The optimizer needed statistics on a column to estimate cardinality but found none. It used a guess instead. Create statistics: `CREATE STATISTICS stat_name ON dbo.TableName (ColumnName)`. For indexed columns, statistics are auto-created — check whether auto-create statistics is enabled at the database level.
### X12 — Missing Join Predicate Event
- **Trigger:** Any event with class 80 (`Missing Join Predicate`) or XE `missing_join_predicate`
- **Severity:** Warning
- **Fix:** SQL Server detected a Cartesian product — a JOIN with no ON condition, or a CROSS JOIN that may be accidental. This produces `rows_left × rows_right` output rows. See `/tsql-review` T10 (CROSS JOIN without comment). Confirm the join condition is correct in the source query.

---

## Workload-Level Checks (X13–X20)

Evaluate aggregated patterns across all events in the trace.
### X13 — High-Frequency Query (N+1 Signal)
- **Trigger:** Any normalized query pattern with ≥ 1,000 executions within the trace window
- **Severity:** Warning
- **Fix:** A query executing 1,000+ times in the trace window is a classic N+1 pattern — the application loops over a result set and issues one query per row. Rewrite as a single set-based query with a JOIN or use a table-valued parameter to batch the lookups. Even if each execution is fast, 10,000 round trips × 1 ms = 10 seconds of serial latency per batch.
### X14 — Parameter Sniffing Signal (High Duration Variance)
- **Trigger:** Same normalized query pattern with ≥ 10 executions where `max(duration) > 10 × min(duration)`
- **Severity:** Warning
- **Fix:** The cached plan was compiled for one parameter value but executes poorly for others. Fixes ranked by impact: (1) `OPTION(RECOMPILE)` on the query — per-execution plan, eliminates sniffing; (2) `OPTION(OPTIMIZE FOR (@param = typical_value))` — pins a representative plan; (3) separate stored procedures for high/low cardinality paths; (4) use Query Store to force the good plan. Use `/sqlplan-compare` to diff the fast and slow plans.
### X15 — Ad-Hoc / Unparameterized Workload
- **Trigger:** Distinct normalized query texts / total query events > 80%, OR large number of near-identical queries with embedded literals (e.g., `WHERE Id = 1`, `WHERE Id = 2`, ..., `WHERE Id = N`)
- **Severity:** Info
- **Fix:** The application is sending literal-embedded SQL rather than parameterized queries. Each distinct literal produces a unique plan cache entry — the plan cache fills with single-use plans, evicting useful plans. Fix: use `sp_executesql` with bound parameters, or ORM parameterization. Enable "optimize for ad hoc workloads" as a short-term mitigation (`sp_configure 'optimize for ad hoc workloads', 1`).
### X16 — Excessive Global Recompilations
- **Trigger:** Recompile events (class 37 or 50) > 5% of total completed query events (class 10 + 12)
- **Severity:** Warning
- **Fix:** Global recompile pressure degrades the entire server — every recompile consumes CPU and a schema lock. Investigate the most-recompiled objects. Common causes: DDL on referenced objects (schema stability), SET option differences across connections, deferred compilation on temp tables (use `OPTION(KEEP PLAN)`).
### X17 — Top Resource Consumers Summary
- **Trigger:** Always fires — this check always produces output
- **Severity:** Info
- **Fix:** No fix required for this check — it surfaces the top 5 queries by total CPU, total logical reads, and max duration. These are the highest-leverage targets for tuning. Run `/sqlplan-review` and `/sqlplan-index-advisor` on the top 1–3 entries.
### X18 — Workload Concentration (Few Queries Dominate)
- **Trigger:** Top 3 normalized query patterns account for > 80% of total CPU time across all events
- **Severity:** Info
- **Fix:** Highly concentrated workloads are good news for tuning — fixing 3 queries improves the whole system. Focus effort entirely on those 3 queries before addressing anything else.
### X19 — Auto-Grow Event Detected
- **Trigger:** Any event with class 92 (`Data File Auto Grow`) or 93 (`Log File Auto Grow`), or XE `database_file_size_change` with `is_auto_grow = 1`
- **Severity:** Warning (≥ 1 event in trace window, normal growth); Critical (≥ 5 events in trace window, frequent growth — file is sized too small for the workload)
- **Fix:** Auto-grow events pause all activity on the database while the file expands. Frequency matters more than individual duration: one 2-second auto-grow is less concerning than 50 auto-grows at 50 ms each — every grow pauses all database transactions. For data files: pre-size the file to avoid mid-workload grows; set instant file initialization (Windows privilege `SE_MANAGE_VOLUME_NAME`) to eliminate file zeroing on data file growth (not applicable to log files). For log files: either pre-size or investigate what is driving high log volume (large uncommitted transactions, bulk inserts without minimal logging, log backup frequency). If auto-grow duration exceeds 1,000 ms (slow auto-grow), the file system or storage subsystem cannot allocate space quickly enough — pre-size the file immediately. For any auto-grow that uses percent growth (the default on older SQL Server versions) rather than fixed-size growth, switch to fixed-size growth to avoid geometrically increasing growth amounts.
### X20 — ShowPlan XML Events Present in Trace
- **Trigger:** Any event with class 146 (`Showplan XML`) or XE `query_post_execution_showplan`
- **Severity:** Info
- **Fix:** The trace captured execution plan XML inline. Extract the plan XML for the slowest queries and run `/sqlplan-review` on them directly — this is a richer artifact than trace metrics alone. Note that capturing Showplan XML for every query significantly increases trace overhead; disable this event class on production traces after initial diagnosis.

---

## Output Format

Structure your report as follows:

```
## Trace Analysis

### Input Summary
- Source: [sys.fn_trace_gettable / XE session / Profiler grid / description]
- Trace window: [start_time] – [end_time]  ([N] minutes)
- Total events captured: N
- Distinct normalized queries: N
- Event types present: SQL:BatchCompleted, RPC:Completed, Attention, Sort Warnings, ...

---

### Top Resource Consumers

**By Total CPU** (top 5)
| # | Query (first 80 chars, for display only) | Executions | Avg CPU ms | Total CPU ms | % of Workload |
|---|------------------------|-----------|-----------|-------------|---------------|
| 1 | SELECT o.OrderId FROM dbo.Orders... | 12,841 | 18 | 231,138 | 42.1% |

**By Total Logical Reads** (top 5)
| # | Query | Executions | Avg Reads | Total Reads |
...

**By Max Duration** (top 5)
| # | Query | Executions | Avg ms | Max ms | Min ms |
...

---

### Performance Findings

#### Critical Issues
**[C1 — Row 47 (SPID 52, 14:23:01)] Issue Name** (X<N>)  ← event-level (X1–X12)
**[C1 — Pattern 3] Issue Name** (X<N>)                    ← workload aggregate (X13–X20)
- Observed: [query text snippet, metric value, SPID, timestamp or frequency]
- Impact: [why this matters]
- Fix: [concrete action]

#### Warnings
[same format]

#### Info
[same format]

### Passed Checks
X5 ✓ (brief reason), X6 ✓ (brief reason) [list every check verified clean with a reason in parens — e.g., X2 ✓ (individual non-report CPU < 5,000 ms)]

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*
```

---

## Notes

- For event-level findings (X1–X12), include the specific row in the bracket using RowNumber, SPID, and StartTime from the trace (e.g., `[C1 — Row 47 (SPID 52, 14:23:01)]`). For workload aggregate findings (X13–X20), include the normalized query pattern number or query hash (e.g., `[C1 — Pattern 3]`).
- Do not invent findings not triggered by the rules above.
- Duration in the input may be in microseconds (`.trc` / XE) or milliseconds (some XE configurations) — confirm the unit from column headers or context before applying thresholds.
- Query normalization: replace integer and string literals with `?`, replace multi-value IN lists with `IN (?,?,?)`, preserve object names and structure. Two queries that differ only in parameter values should be grouped as the same pattern.
- If the trace window is very short (< 1 minute), high-frequency thresholds may not be meaningful — note the window duration and adjust interpretation.
- If the trace contains only a few hundred events, workload-level aggregate checks (X13–X18) may not produce statistically meaningful results — note the sample size.
- If ShowPlan XML events are present (X20), prioritize extracting and reviewing those plans over relying solely on trace metrics.
- Deadlock events (class 59 / `xml_deadlock_report`) in the trace should be extracted and passed to `/sqlplan-deadlock` — do not attempt full deadlock analysis within this skill.

## Companion Skills

- **tsql-review** — Review the source code of the most problematic queries identified by the trace for static anti-patterns (non-sargable predicates, cursor loops, dynamic SQL injection risk).
- **sqlplan-review** — Analyze the execution plan of the top CPU or read consumers identified here. Capture with `Ctrl+M` in SSMS or from ShowPlan XML events in the trace itself (X20).
- **sqlplan-index-advisor** — Derive `CREATE INDEX` recommendations from execution plans of the top resource consumers.
- **sqlplan-compare** — If X14 (parameter sniffing signal) fires, capture the fast and slow plans and diff them to understand what changes between executions.
- **sqlstats-review** — Run `SET STATISTICS IO, TIME ON` on the top-CPU or top-reads query identified here for per-table I/O breakdown.
- **sqlplan-deadlock** — If deadlock events (class 59) appear in the trace, extract the deadlock XML and analyze with this companion skill.
- **sqlplan-batch** — If the trace contains ShowPlan XML for many queries (X20), export those plans to `.sqlplan` files and batch-analyze with this skill.
- **query-store-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.

- **mssql-performance-review** — Orchestrator that routes mixed artifacts to multiple specialised skills (this one included), runs an adversarial root-cause check, and produces a single consolidated report with evidence chain, risk-rated fixes, and rollback. Use when you have several artifact types together or describe a symptom without knowing which skill to run.
