# SQL Server Performance Tuning Guide

A decision guide for choosing the right skill — or combination of skills — for any SQL Server performance scenario.

---

## Skills at a Glance

| Skill | Trigger | Input | What it does |
|-------|---------|-------|-------------|
| [`mssql-performance-review`](#mssql-performance-review) | `/mssql-performance-review` / `/sql-triage` | Mixed artifacts or a symptom description | Agentic offline orchestrator — routes mixed inputs to the right specialised skills, runs an adversarial root-cause check, emits a consolidated report with evidence chain, risk-rated fixes, and rollback. Dispatcher, no checks of its own. |
| [`tsql-review`](#tsql-review) | `/tsql-review` | T-SQL source code | Static analysis of source code — 78 checks for anti-patterns, security, logic bugs |
| [`sqlstats-review`](#sqlstats-review) | `/sqlstats-review` | SSMS Messages tab output | Parses `SET STATISTICS IO, TIME ON` output — 22 checks for I/O and wait patterns |
| [`sqltrace-review`](#sqltrace-review) | `/sqltrace-review` | Profiler `.trc` / XE `.xel` / `fn_trace_gettable()` results | Workload analysis — 20 checks for N+1, sniffing, recompiles, spills, top consumers |
| [`sqlwait-review`](#sqlwait-review) | `/sqlwait-review` | `sys.dm_os_wait_stats` or `sys.dm_exec_requests` output | Wait statistics — 40 checks (V1–V40): I/O, locks, parallelism, memory, CPU, latch, log I/O, network, poison/throttle waits, backup I/O, insert hotspots, cumulative skew, multi-snapshot trend analysis, In-Memory OLTP, Columnstore, Query Store, Transaction/DTC, Service Broker, Full Text Search, Parallel Redo, memory grants, file I/O latency |
| [`sqlplan-review`](#sqlplan-review) | `/sqlplan-review` | `.sqlplan` XML or description | Deep execution plan analysis — 99 checks across operators, memory, parallelism, row widths, elapsed timing |
| [`sqlplan-index-advisor`](#sqlplan-index-advisor) | `/sqlplan-index-advisor` | `.sqlplan` XML | Ranked `CREATE INDEX` script from plan operators + optimizer suggestions |
| [`sqlplan-compare`](#sqlplan-compare) | `/sqlplan-compare` | Two `.sqlplan` files | Diffs two plans to explain a regression |
| [`sqlplan-deadlock`](#sqlplan-deadlock) | `/sqlplan-deadlock` | Deadlock XML / `.xdl` file | Root-cause analysis and fix plan for a deadlock graph |
| [`sqlplan-batch`](#sqlplan-batch) | `/sqlplan-batch` | Folder of `.sqlplan` files | Bulk review of many plans — dashboard, top offenders, consolidated indexes |
| [`query-store-review`](#query-store-review) | `/query-store-review` | `sys.query_store_*` DMV output | Query Store workload analysis — 25 checks for regressed queries, plan instability, resource hotspots, query-level waits, and configuration health |
| [`procstats-review`](#procstats-review) | `/procstats-review` | Output from `sql/procstats/04_report_queries.sql` pasted from `collect.proc_stats` | Procedure/trigger/function runtime stats — 20 checks (R1–R20): top consumers, per-execution efficiency, N+1 patterns, parameter sniffing, trend analysis |
| [`clusterlog-review`](#clusterlog-review) | `/clusterlog-review` | `CLUSTER.LOG` file or inline paste | WSFC cluster log analysis — 25 checks (L1–L25): lease timeouts, health check failures, quorum loss, node eviction, network partition, RHS crashes, AG resource transitions |
| [`errorlog-review`](#errorlog-review) | `/errorlog-review` | SQL Server ERRORLOG file or inline paste | ERRORLOG operational analysis — 28 checks (E1–E28): AG failover events, lease expiry, memory pressure, I/O slow, corruption warnings, login failure bursts, startup/shutdown, and configuration signals |
| [`hadr-health-review`](#hadr-health-review) | `/hadr-health-review` | `sys.dm_hadr_*` DMV output | Always On AG health analysis — 22 checks (H1–H22): replica connectivity, data loss risk, recovery time, throughput, and configuration |
| [`spn-review`](#spn-review) | `/spn-review` | `setspn` output and/or `Get-ADUser`/`Get-ADComputer` AD attribute output | SPN and Kerberos delegation analysis — 30 checks (K1–K30): MSSQLSvc SPN presence, service account binding, AG listener and alias, permissions, Kerberos delegation, AD account sensitivity |

---

## Choose by Scenario

### "I have a pile of mixed artifacts and don't know where to start"

**Use: `/mssql-performance-review`**

The orchestrator classifies every input (`.sqlplan`, `.sql`, stats output, wait stats, trace, Query Store, procstats, deadlock XML, ERRORLOG, CLUSTER.LOG, setspn output, hadr DMVs), forms 2-3 ranked hypotheses, dispatches the relevant specialised skills, runs an adversarial root-cause check, and emits one consolidated report. Strictly offline — never contacts SQL Server.

```
/mssql-performance-review ./incident-20260517/
```

Also accepts a symptom description ("CPU is high on prod since 09:00") and tells you which captures to run.

```
/sql-triage CPU pegged at 95% on PROD-SQL01 since 09:00, no recent deploy
```

---

### "I'm writing a new query or stored procedure"

**Use: `/tsql-review`**

Run it on the source before the query ever executes. Catches things the execution plan cannot — SQL injection via dynamic SQL, non-sargable predicates, cursor patterns, NULL comparison bugs, deprecated syntax.

```
/tsql-review

CREATE PROCEDURE dbo.GetCustomerOrders @customerId INT
AS
    SELECT * FROM dbo.Orders WHERE CustomerId = @customerId
```

---

### "A query is slow and I want to understand why"

**Use: `/sqlplan-review`**

Capture the actual execution plan in SSMS (`Ctrl+M`, then run), save as `.sqlplan`, and review. The execution plan is the most diagnostic artifact SQL Server produces — it shows join choices, row estimate accuracy, memory grants, spills, and operator costs.

```
/sqlplan-review path/to/slow-query.sqlplan
```

If you don't have the plan yet, run with STATISTICS first:

```
/sqlstats-review   ← paste the Messages tab output to get I/O and timing first
```

Then capture the plan and continue with `/sqlplan-review`.

---

### "I have SSMS statistics output (Messages tab) but no execution plan"

**Use: `/sqlstats-review`**

Paste the raw output from the Messages tab after running with `SET STATISTICS IO, TIME ON`. The skill parses per-table read counts, computes % logical read share, and flags high scan counts, worktable spills, LOB access, and wait patterns — without needing a `.sqlplan` file.

```sql
-- In SSMS, before your query:
SET STATISTICS IO, TIME ON;
GO
-- your query
SET STATISTICS IO, TIME OFF;
```

Then paste the Messages output:

```
/sqlstats-review

Table 'Orders'. Scan count 48291, logical reads 2568900, ...
SQL Server Execution Times: CPU time = 18420 ms, elapsed time = 18912 ms.
```

---

### "I need to know which indexes to create"

**Use: `/sqlplan-index-advisor`**

Takes one or more `.sqlplan` files and produces a single ranked, deployment-ready `CREATE INDEX` script from two independent sources: operator-derived recommendations (D1–D8: Key Lookups, expensive scans, Sort operators, Eager Index Spools, Nested Loops inner-side scans, heap tables, backward scans) and the optimizer's own `MissingIndexGroup` suggestions. Both sources are merged and deduplicated per table — the output is one index per table group, not one per source.

```
/sqlplan-index-advisor path/to/query.sqlplan
```

For multiple plans in one pass (consolidated script across all):
```
/sqlplan-index-advisor plans/proc1.sqlplan plans/proc2.sqlplan plans/proc3.sqlplan
```

**When to use this vs just following sqlplan-review findings:**
- `/sqlplan-review` tells you *what* the problem is (e.g., "Key Lookup executing 48,000 times")
- `/sqlplan-index-advisor` tells you *exactly which index DDL to run* — it handles column order, INCLUDE columns, and merging overlapping suggestions that sqlplan-review does not generate
- Run both on the same plan for the most complete picture: review for full analysis, advisor for the actionable DDL

---

### "A query was fast, then it got slow after a deployment / stats update / schema change"

**Use: `/sqlplan-compare`**

Capture two plans: one from before the regression (baseline) and one from after. The skill diffs join strategies, memory grants, DOP, Key Lookups, operator topology, and missing index hints to explain exactly what changed and why it's slower.

```
/sqlplan-compare baseline.sqlplan regression.sqlplan
```

Or paste both XML blocks labeled "Baseline" and "New".

---

### "Kerberos authentication fails — linked server falls back to NTLM or anonymous login — AG listener connections fail"

**Use: `/spn-review`**

Collect `setspn` output and AD delegation attributes, then paste them for analysis. The skill applies 30 checks to identify missing SPNs, duplicate SPNs, unconstrained delegation, misconfigured KCD/RBCD, and AD account sensitivity flags that block delegation.

```powershell
setspn -Q MSSQLSvc/*
setspn -L DOMAIN\sqlsvc
setspn -X
Get-ADUser DOMAIN\sqlsvc -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo
Get-ADComputer SQLNODE1 -Properties TrustedForDelegation, msDS-AllowedToActOnBehalfOfOtherIdentity
```

```
/spn-review

[paste output above]
```

Common root causes found by `/spn-review`:
- K8 (duplicate SPN) — previous service account not cleaned up during account rotation
- K19/K29 (unconstrained delegation) — legacy configuration that must be replaced with KCD
- K21/K22 (KCD not configured or target SPN missing) — linked server double-hop fails
- K27/K30 (Protected Users group) — service account or connecting user blocks all delegation

---

### "Users are getting error 1205 (deadlock victim)"

**Use: `/sqlplan-deadlock`**

Capture the deadlock XML from the `system_health` Extended Events session in SSMS, or save the deadlock graph as XML. The skill identifies the victim and winner processes, the lock resources involved, matches against 8 known deadlock patterns (P1–P8), and produces a prioritized fix plan.

```
/sqlplan-deadlock path/to/deadlock.xdl
```

Or paste the raw `<deadlock>` XML directly.

---

### "The server is slow but I don't know why — queries, blocking, or resource pressure?"

**Use: `/sqlwait-review`**

Run the wait statistics capture query and paste the results. The skill applies 36 checks (V1–V36) based on the Paul Randal Waits and Queues methodology and the Brent Ozar First Responder Kit. V1–V18 and V27–V29 identify the dominant bottleneck in a single snapshot; V19–V26 perform trend analysis when 3+ time windows are provided; V30–V36 cover modern feature wait types (In-Memory OLTP, Columnstore, Query Store, Transaction/DTC, Service Broker, Full Text Search, Parallel Redo).

**Step 1 — Capture wait statistics (choose one)**

**Option A — Cumulative since last restart (quick, single query)**

```sql
SELECT TOP 20
    wait_type, waiting_tasks_count, wait_time_ms,
    max_wait_time_ms, signal_wait_time_ms,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS DECIMAL(5,2)) AS pct_total
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP','BROKER_TO_FLUSH',
    'BROKER_TRANSMITTER','CHECKPOINT_QUEUE','CLR_AUTO_EVENT','CLR_MANUAL_EVENT',
    'DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_WORK_QUEUE',
    'LAZYWRITER_SLEEP','LOGMGR_QUEUE','ONDEMAND_TASK_QUEUE',
    'PARALLEL_REDO_DRAIN_WORKER','PARALLEL_REDO_LOG_CACHE','PARALLEL_REDO_TRAN_LIST',
    'PARALLEL_REDO_WORKER_SYNC','PARALLEL_REDO_WORKER_WAIT_WORK',
    'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE',
    'REDO_THREAD_PENDING_WORK','REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK','SLEEP_DBSTARTUP','SLEEP_DBTASK','SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP',
    'SLEEP_SYSTEMTASK','SLEEP_TASK','SLEEP_TEMPDBSTARTUP',
    'SNI_HTTP_ACCEPT','SOS_WORK_DISPATCHER','SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'UCS_SESSION_REGISTRATION','VDI_CLIENT_OTHER','WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
    'WAITFOR','XE_DISPATCHER_WAIT','XE_LIVE_TARGET_TVF','XE_TIMER_EVENT'
)
ORDER BY wait_time_ms DESC;
```

> **Azure SQL Database:** Replace `sys.dm_os_wait_stats` with `sys.dm_db_wait_stats` — Azure SQL only exposes database-scoped wait statistics.

**Option B — 30-minute differential (recommended for active troubleshooting)**

```sql
-- Run at T=0, wait 30 minutes, run again — shows only activity during the window
SELECT * INTO #w FROM sys.dm_os_wait_stats WHERE wait_type NOT IN ('SLEEP_TASK','WAITFOR','LAZYWRITER_SLEEP','CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_DISPATCHER_WAIT');
WAITFOR DELAY '00:30:00';
SELECT a.wait_type,
       b.wait_time_ms - a.wait_time_ms AS wait_time_ms_delta,
       b.signal_wait_time_ms - a.signal_wait_time_ms AS signal_ms_delta,
       b.waiting_tasks_count - a.waiting_tasks_count AS tasks_delta,
       CAST(100.0 * (b.wait_time_ms - a.wait_time_ms) / NULLIF(SUM(b.wait_time_ms - a.wait_time_ms) OVER(), 0) AS DECIMAL(5,2)) AS pct
FROM #w a JOIN sys.dm_os_wait_stats b ON b.wait_type = a.wait_type
WHERE b.wait_time_ms > a.wait_time_ms
ORDER BY wait_time_ms_delta DESC;
DROP TABLE #w;
```

**Step 2 — Capture server configuration alongside wait stats (recommended)**

Several wait types are interpreted differently depending on server settings. Paste this result alongside your wait statistics so the skill can produce configuration-aware advice — e.g., CXPACKET advice changes based on MAXDOP and CTPfP; LCK_M_* advice changes based on RCSI state; PAGELATCH fix depends on TempDB file count.

```sql
-- sp_configure values
SELECT name AS config_name, CAST(value_in_use AS INT) AS current_value
FROM sys.configurations
WHERE name IN (
    'max degree of parallelism',
    'cost threshold for parallelism',
    'max server memory (MB)',
    'optimize for ad hoc workloads',
    'max worker threads'
);

-- Per-database settings
SELECT name, is_read_committed_snapshot_on, recovery_model_desc, delayed_durability_desc
FROM sys.databases WHERE database_id = DB_ID();

-- TempDB file count
SELECT COUNT(*) AS tempdb_data_file_count
FROM sys.master_files WHERE database_id = 2 AND type = 0;

-- Always On commit mode (if configured)
SELECT ag.name AS ag_name, ar.availability_mode_desc AS commit_mode, ars.role_desc
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ars.is_local = 1;
```

```
/sqlwait-review

[paste results from Step 1 (Option A or B)]
[paste results from Step 2 — configuration]
```

**What the output includes:**
- **In context** — converts raw ms into "N concurrent sessions blocked on average" so you know at a glance how loaded the server was
- **Server Configuration Context table** — interprets each config value against the wait types present (e.g., "RCSI = OFF → enabling it is the highest-leverage LCK_M fix")
- **Category column** in the top-wait table (I/O, Locks, Memory, Parallelism, Log, HA, etc.) for quick orientation
- **User impact** in each finding — what users actually experienced (timeouts, slow queries, write failures)

---

### "I don't know which query is slow — I need to find it"

**Use: `/sqltrace-review`**

Capture a Profiler or Extended Events trace across the workload (minutes to hours), then analyze it. The skill identifies the top CPU consumers, top read consumers, N+1 patterns (same query called thousands of times), parameter sniffing signals (same query with wildly inconsistent durations), and warning events (sort spills, hash spills, lock timeouts). Once the worst query is identified, pivot to `/sqlplan-review` on that specific query.

```
/sqltrace-review

[paste sys.fn_trace_gettable() output or XE session results]
```

---

### "I want to review a whole workload, not just one query"

**Use: `/sqlplan-batch`**

Capture a folder of `.sqlplan` files (from SQL Server's Query Store, Extended Events, or manual saves) and run them all at once. Applies the full 87-check ruleset from `/sqlplan-review` to every plan and aggregates findings into a single dashboard.

```
/sqlplan-batch path/to/plans/folder/
```

**Output includes:**
- **Top 10 most expensive plans** — ranked by statement cost
- **Top 10 plans by critical issue count** — worst offenders for prioritization
- **Check violation frequency** — which checks fire most often across the workload (systemic vs one-off problems)
- **Consolidated missing index script** — merged and ranked `CREATE INDEX` DDL across all plans (same merge rules as `/sqlplan-index-advisor`)
- **Spill report** — all plans with confirmed TempDb spills
- **Per-plan summary table** — one row per file with key metrics

**How to export plans from Query Store:**
```sql
-- Export top 50 worst plans from Query Store
SELECT qp.query_plan
FROM sys.query_store_query_text qt
JOIN sys.query_store_query q ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan qp ON qp.query_id = q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = qp.plan_id
ORDER BY rs.avg_cpu_time DESC
OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY;
-- Save each query_plan XML as a .sqlplan file
```

Follow up with `/sqlplan-review` on the worst 3–5 plans and `/sqlplan-index-advisor` for the consolidated index script.

---

### "I want to find my worst queries without running any captures — I have Query Store enabled"

**Use: `/query-store-review`**

If your database has Query Store enabled (SQL Server 2016+, on by default in many configurations), you already have weeks or months of query performance history. Run one capture query and the skill applies 25 checks to identify regressed queries, plan instability, resource hotspots, N+1 patterns, and configuration issues — all from data already collected.

```
/query-store-review

[paste output from the capture query in the skill or README]
```

The output tells you which queries to focus on and which companion skill to use next — `/sqlplan-review` for deep-dive plan analysis, `/sqlplan-index-advisor` for index DDL, `/tsql-review` for source code anti-patterns.

---

### "I want to find my worst stored procedures, triggers, or functions — I have sys.dm_exec_procedure_stats data"

**Use: `/procstats-review`**

Collect procedure/trigger/function runtime stats from the DMV and paste the output. No execution plan needed — the skill applies 20 checks to identify top CPU and I/O consumers, per-execution efficiency (cost per call), N+1 callers (a procedure called thousands of times per minute), parameter sniffing signals (execution time variance), and trend analysis when multiple snapshots are provided.

```sql
-- Quick capture: top 20 procedures by total CPU
SELECT TOP 20
    OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id) AS schema_name,
    OBJECT_NAME(ps.object_id, ps.database_id) AS proc_name,
    ps.execution_count,
    ps.total_worker_time / 1000 AS total_cpu_ms,
    ps.total_worker_time / ps.execution_count / 1000 AS avg_cpu_ms,
    ps.total_logical_reads,
    ps.total_logical_reads / ps.execution_count AS avg_logical_reads,
    ps.cached_time, ps.last_execution_time
FROM sys.dm_exec_procedure_stats ps
WHERE ps.database_id = DB_ID()
ORDER BY ps.total_worker_time DESC;
```

```
/procstats-review

[paste query output]
```

Once the worst procedure is identified, pivot to `/tsql-review` on its source, `/sqlstats-review` while running it, and `/sqlplan-review` on its execution plan.

---

### "I have a mix of different artifact types"

## The Standard Tuning Workflow

For a query you know is slow, work through these steps in order. Each step adds more diagnostic information.

```
Step 1 — Review the source code (no execution needed)
   /tsql-review
   → Fix: injection risks, non-sargable predicates, cursors, deprecated syntax

Step 2 — Run with STATISTICS to measure I/O and timing
   SET STATISTICS IO, TIME ON → /sqlstats-review
   → Fix: identify highest-read table, worktable spills, wait patterns

Step 3 — Capture and analyze the execution plan
   /sqlplan-review
   → Fix: join strategy, row estimate errors, memory grant, parallelism

Step 4 — Get the index recommendations
   /sqlplan-index-advisor
   → Fix: deploy the CREATE INDEX script, verify improvement

Step 5 — If the query regressed after a change
   /sqlplan-compare baseline.sqlplan new.sqlplan
   → Fix: revert the statistics / schema change, or rewrite the query

Step 6 — If the query causes deadlocks
   /sqlplan-deadlock deadlock.xdl
   → Fix: add missing index, change lock order, switch isolation level
```

---

## Choose by Artifact You Have

| What you have | Skill to use |
|--------------|-------------|
| T-SQL source code (.sql file, stored proc body) | `/tsql-review` |
| SSMS Messages tab output (STATISTICS IO, TIME) | `/sqlstats-review` |
| Profiler `.trc`, XE `.xel`, or `fn_trace_gettable()` results | `/sqltrace-review` |
| `sys.dm_os_wait_stats` or `sys.dm_exec_requests` output | `/sqlwait-review` |
| One `.sqlplan` file | `/sqlplan-review` then `/sqlplan-index-advisor` |
| Two `.sqlplan` files (before and after) | `/sqlplan-compare` |
| Deadlock XML / `.xdl` file | `/sqlplan-deadlock` |
| Folder of `.sqlplan` files | `/sqlplan-batch` |
| `sys.query_store_*` DMV output | `/query-store-review` |
| `collect.proc_stats` report query output (Q1–Q5 from `04_report_queries.sql`) | `/procstats-review` |
| No artifacts — just a slow query description | `/sqlplan-review` (describe operators) or `/tsql-review` (describe the code) |
| `setspn` output and/or `Get-ADUser`/`Get-ADComputer` AD attribute data | `/spn-review` |

---

## Choose by Symptom

### Server-wide slowdown — need to find the bottleneck category first

Users are reporting the application is slow, but you don't know if it's I/O, locking, CPU, or something else.

1. **`/sqlwait-review`** — run the wait statistics query and paste results. V17 (top-5 table) orients the analysis; specific checks identify the dominant wait type and give a prioritized fix. This is always the first step for server-wide performance problems.
2. If dominant wait is `PAGEIOLATCH` → I/O bound → proceed to `/sqlstats-review` on the heaviest queries, then `/sqlplan-index-advisor`.
3. If dominant wait is `LCK_M_*` → blocking → proceed to blocking chain analysis with `sys.dm_exec_requests`.
4. If dominant wait is `CXPACKET` → parallelism overhead → check Cost Threshold for Parallelism and data skew; `/sqlplan-review` for N30.
5. If dominant wait is `RESOURCE_SEMAPHORE` → memory grant queue → update statistics; `/sqlplan-review` S2–S4.
6. If poison waits present (`IO_RETRY`, `LOG_RATE_GOVERNOR`, `SE_REPL_*`) → emergency; see V18 fix table.

### High CPU usage

The query consumes excessive CPU on the server.

1. **`/sqlwait-review`** — check signal wait ratio (V10). High signal wait = CPU saturation (threads ready but no CPU). Check `CXPACKET` (V3) and `SOS_SCHEDULER_YIELD` (V7).
2. **`/sqlstats-review`** — check W5 (CPU ≥ 60s). If CPU ≈ elapsed: CPU-bound (scans, sorts). If CPU >> elapsed: parallel execution — check thread skew.
3. **`/sqlplan-review`** — check N4 (expensive scan), N18 (hash match), N20 (sort), S1 (serial plan vs expected parallelism).
4. **`/sqlplan-index-advisor`** — add indexes to eliminate scans driving the CPU cost.

### High I/O / disk pressure

Disk or buffer pool pressure, slow disk response.

1. **`/sqlwait-review`** — check `PAGEIOLATCH_SH` (V1). If ≥ 40% of waits, I/O is the dominant bottleneck. Note: the root cause is almost always inefficient queries reading too many pages — investigate queries before blaming storage.
2. **`/sqlstats-review`** — check I1 (total logical reads), I2 (scan count), I3 (physical reads ratio), I6 (worktable spill).
3. **`/sqlplan-review`** — check N4 (expensive scan), N5 (key lookup), N41–N43 (confirmed spill), S2/S3 (memory grant).
4. **`/sqlplan-index-advisor`** — covering indexes to eliminate key lookups and reduce scans.

### Long elapsed time but low CPU

Query is slow but not using much CPU — it is waiting.

1. **`/sqlwait-review`** — check signal wait ratio (V10 < 15% = not CPU). Check which wait type dominates: `PAGEIOLATCH` (I/O wait), `LCK_M_*` (blocking), `ASYNC_NETWORK_IO` (client-side — not SQL Server). `WRITELOG` (log I/O).
2. **`/sqlstats-review`** — check W1 (CPU < 10% of elapsed = wait-bound), I3/I14 (physical reads).
3. **`/sqlplan-deadlock`** if blocking or deadlocks are suspected.

### Query was fast, now it's slow

A regression after a deployment, index change, or statistics update.

1. **`/sqlplan-compare`** — diff the before and after plans. Most regressions are: seek→scan, DOP drop, new Key Lookup, memory grant change, or stale statistics.
2. **`/sqlstats-review`** on the slow execution — compare logical read counts to baseline.
3. Fix: update statistics, revert schema change, add OPTION (RECOMPILE), or pin the good plan via Query Store.

### Parameter sniffing

The query is fast for one parameter value, slow for another.

1. **`/sqlstats-review`** — compare logical reads between a fast and a slow execution.
2. **`/sqlplan-review`** — check S9 (forced plan from Query Store), N21 (bad row estimate), S2 (excessive memory grant).
3. Fix: OPTION (RECOMPILE), OPTION (OPTIMIZE FOR), or separate procedures for high/low cardinality paths.

### Deadlocks (error 1205)

Users intermittently get killed as a deadlock victim.

1. **`/sqlplan-deadlock`** — analyze the deadlock XML. The skill identifies which of the 8 canonical patterns applies (P1–P8) and gives a prioritized fix.
2. Common fixes: add a missing index (P4, P5), switch to READ_COMMITTED_SNAPSHOT isolation (P2), index the FK column in the child table (P7), enforce consistent lock order (P1).

### "This stored proc is slow but I don't know where to start"

No artifacts yet.

1. **`/tsql-review`** — paste the proc body. Catches cursor patterns, non-sargable predicates, SELECT * without column lists, dynamic SQL risks.
2. Run the proc with `SET STATISTICS IO, TIME ON` → **`/sqlstats-review`** — identify which statement and which table is the bottleneck.
3. Capture the plan for that statement → **`/sqlplan-review`**.

### Large number of queries to tune (workload-level)

After a version upgrade, migration, or workload capture.

1. **`/sqlplan-batch`** — point it at the folder of captured plans. Get the top offenders by cost, the most common check violations, and a consolidated missing index script.
2. Drill into the worst 5–10 plans with **`/sqlplan-review`**.
3. Generate targeted index DDL for each with **`/sqlplan-index-advisor`**.

### "I want to find my worst stored procedures / functions by resource usage — no specific query yet"

You have Query Store disabled or don't want to capture a trace. You have `sys.dm_exec_procedure_stats` available.

1. **`/procstats-review`** — collect DMV data (see capture query above) and paste. R1–R5 rank procedures by CPU, reads, and duration. R11/R12 flag workload concentration — if one procedure accounts for 80%+ of CPU, it's the target.
2. Run `/tsql-review` on the worst procedure's body — catch source-level anti-patterns before capturing a plan.
3. Run the procedure with `SET STATISTICS IO, TIME ON` → **`/sqlstats-review`** — identify which statement is the bottleneck.
4. Capture the plan for that statement → **`/sqlplan-review`** → **`/sqlplan-index-advisor`**.

---

## Skill Scope Comparison

Each skill sees a different slice of query behavior. Together they give a complete picture.

```
Source Code               │  T-SQL source (.sql)
──────────────────────────┼─────────────────────────────────────────
/tsql-review              │  Static: can I spot problems before running?
                          │  78 checks: injection, predicates, cursors,
                          │  deprecated syntax, correctness, security

Execution (no plan)       │  SSMS Messages tab
──────────────────────────┼─────────────────────────────────────────
/sqlstats-review          │  I/O: how many pages were read per table?
                          │  Time: CPU vs elapsed — compute vs wait?
                          │  22 checks: scan count, spills, LOB, waits

Trace / XE                │  Profiler .trc / XE .xel / fn_trace_gettable()
──────────────────────────┼─────────────────────────────────────────
/sqltrace-review          │  Workload: which queries are worst?
                          │  N+1 patterns, parameter sniffing signals,
                          │  recompiles, spill events, top consumers
                          │  20 checks: X1–X12 event, X13–X20 aggregate

Wait Statistics           │  sys.dm_os_wait_stats / sys.dm_exec_requests
──────────────────────────┼─────────────────────────────────────────
/sqlwait-review           │  Server bottleneck: why is the server slow?
                          │  40 checks V1–V40: I/O (PAGEIOLATCH), locks (LCK_M),
                          │  parallelism (CXPACKET/HT*), memory grants (RESOURCE_SEMAPHORE),
                          │  log I/O (WRITELOG/LOGBUFFER), CPU (SOS_SCHEDULER_YIELD),
                          │  TempDB (PAGELATCH), latch contention (LATCH_EX),
                          │  log space (LOGMGR_RESERVE_APPEND),
                          │  poison waits (IO_RETRY, LOG_RATE_GOVERNOR, SE_REPL_*)
                          │  V19–V26 Trend Analysis (3+ snapshots): direction, spikes,
                          │  peak period, velocity, emerging waits, correlated spikes,
                          │  transient events, pattern classification
                          │  V30–V36 Modern features: In-Memory OLTP (XTP*), Columnstore,
                          │  Query Store (QDS*), Transaction/DTC, Service Broker,
                          │  Full Text Search, Parallel Redo (Always On secondary)
                          │  V37–V40 Memory/I/O detail: forced grants, grant timeouts,
                          │  stolen memory, file-level I/O latency
                          │  Configuration-aware: MAXDOP, CTPfP, RCSI, TempDB files,
                          │  recovery model, delayed durability, Always On commit mode

Execution Plan            │  .sqlplan XML
──────────────────────────┼─────────────────────────────────────────
/sqlplan-review           │  Operators: what did the optimizer choose?
                          │  99 checks: join strategy, row estimates,
                          │  memory grants, parallelism, spills

/sqlplan-index-advisor    │  Indexes: what should I create?
                          │  D1–D8 derived rules + MissingIndexGroup
                          │  → ranked CREATE INDEX script

/sqlplan-compare          │  Regression: what changed between two plans?
                          │  C1–C10: seek→scan, DOP, Key Lookup,
                          │  memory grant, cardinality model

Deadlock                  │  deadlock XML / .xdl
──────────────────────────┼─────────────────────────────────────────
/sqlplan-deadlock         │  Deadlock: why are two sessions blocked?
                          │  P1–P8 patterns: lock order, isolation,
                          │  missing index, FK, SERIALIZABLE phantom

Workload                  │  Folder of .sqlplan files
──────────────────────────┼─────────────────────────────────────────
/query-store-review       │  Query Store: which queries in a workload
                           │  need attention? 25 checks: regressions,
                           │  plan instability, resource hotspots,
                           │  waits per query, operational health
                           │
/sqlplan-batch            │  Aggregate: which queries in a workload
                           │  need attention? Dashboard + top offenders
                           │  + consolidated index script
```

---

## How to Capture Each Input

### Wait statistics output (sys.dm_os_wait_stats)

**Standard capture (cumulative since restart)**
```sql
SELECT TOP 20
    wait_type, waiting_tasks_count, wait_time_ms,
    max_wait_time_ms, signal_wait_time_ms,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS DECIMAL(5,2)) AS pct_total
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP','BROKER_TO_FLUSH',
    'CHECKPOINT_QUEUE','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','DIRTY_PAGE_POLL',
    'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_WORK_QUEUE',
    'LAZYWRITER_SLEEP','LOGMGR_QUEUE','ONDEMAND_TASK_QUEUE',
    'PARALLEL_REDO_DRAIN_WORKER','PARALLEL_REDO_LOG_CACHE','PARALLEL_REDO_TRAN_LIST',
    'PARALLEL_REDO_WORKER_SYNC','PARALLEL_REDO_WORKER_WAIT_WORK',
    'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE',
    'REDO_THREAD_PENDING_WORK','REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK','SLEEP_DBSTARTUP','SLEEP_DBTASK','SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP',
    'SLEEP_SYSTEMTASK','SLEEP_TASK','SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT',
    'SOS_WORK_DISPATCHER','SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','UCS_SESSION_REGISTRATION',
    'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAITFOR',
    'XE_DISPATCHER_WAIT','XE_LIVE_TARGET_TVF','XE_TIMER_EVENT'
)
ORDER BY wait_time_ms DESC;
```

**Azure SQL Database** — use `sys.dm_db_wait_stats` (database-scoped):
```sql
SELECT TOP 20 wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER(), 0) AS DECIMAL(5,2)) AS pct_total
FROM sys.dm_db_wait_stats
WHERE wait_type NOT IN ('SLEEP_TASK','WAITFOR','LAZYWRITER_SLEEP','CHECKPOINT_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH','XE_DISPATCHER_WAIT','XE_TIMER_EVENT')
ORDER BY wait_time_ms DESC;
```

**30-minute differential** (filters out old background noise — recommended for active incidents):
```sql
SELECT * INTO #w FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ('SLEEP_TASK','WAITFOR','LAZYWRITER_SLEEP','CHECKPOINT_QUEUE','XE_DISPATCHER_WAIT');
WAITFOR DELAY '00:30:00';
SELECT a.wait_type,
       b.wait_time_ms - a.wait_time_ms               AS delta_ms,
       b.signal_wait_time_ms - a.signal_wait_time_ms AS signal_delta_ms,
       b.waiting_tasks_count - a.waiting_tasks_count  AS tasks_delta,
       CAST(100.0*(b.wait_time_ms-a.wait_time_ms)/NULLIF(SUM(b.wait_time_ms-a.wait_time_ms) OVER(),0) AS DECIMAL(5,2)) AS pct
FROM #w a JOIN sys.dm_os_wait_stats b ON b.wait_type = a.wait_type
WHERE b.wait_time_ms > a.wait_time_ms ORDER BY delta_ms DESC;
DROP TABLE #w;
```

Copy the result grid from SSMS → paste into Claude with `/sqlwait-review`.

**Server configuration capture (paste alongside wait stats)**

The skill produces configuration-aware interpretations when you include these values. Run once per server alongside the wait statistics query:

```sql
SELECT name AS config_name, CAST(value_in_use AS INT) AS current_value
FROM sys.configurations
WHERE name IN (
    'max degree of parallelism', 'cost threshold for parallelism',
    'max server memory (MB)', 'optimize for ad hoc workloads', 'max worker threads'
);

SELECT name, is_read_committed_snapshot_on, recovery_model_desc, delayed_durability_desc
FROM sys.databases WHERE database_id = DB_ID();

SELECT COUNT(*) AS tempdb_data_file_count
FROM sys.master_files WHERE database_id = 2 AND type = 0;
```

### Profiler trace / Extended Events output

**Option A — Query an existing .trc file with sys.fn_trace_gettable()**
```sql
SELECT EventClass, TextData, CPU, Reads, Writes, Duration,
       StartTime, SPID, ApplicationName, DatabaseName
FROM sys.fn_trace_gettable('C:\Traces\workload.trc', DEFAULT)
WHERE EventClass IN (10,12,16,37,50,54,65,69,79,80,92,93,146)
ORDER BY StartTime;
```
Export as CSV and paste into Claude.

**Option B — Query a saved Extended Events .xel file**
```sql
SELECT
    event_data.value('(event/@name)[1]',  'NVARCHAR(100)')  AS event_name,
    event_data.value('(event/data[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
    event_data.value('(event/data[@name="duration"]/value)[1]',     'BIGINT') AS duration_us,
    event_data.value('(event/data[@name="cpu_time"]/value)[1]',     'BIGINT') AS cpu_time_us,
    event_data.value('(event/data[@name="logical_reads"]/value)[1]','BIGINT') AS logical_reads,
    event_data.value('(event/@timestamp)[1]', 'DATETIME2') AS event_time
FROM sys.fn_xe_file_target_read_file('C:\XE\workload*.xel', NULL, NULL, NULL)
CROSS APPLY (SELECT CAST(event_data AS XML)) AS ed(event_data)
ORDER BY event_time;
```

**Option C — SQL Server Profiler GUI**
1. Tools → SQL Server Profiler → File → New Trace
2. Use the **TSQL_Duration** template; add: `Attention`, `SP:Recompile`, `Hash Warning`, `Sort Warnings`
3. Filter: `Duration >= 1000000` (≥ 1 second) to reduce noise
4. Save as `.trc` → re-read with Method A above

> **Production note:** Profiler with Showplan XML capture adds 10–30% overhead. Use Extended Events with server-side duration filters on production systems.

### T-SQL source code
- From SSMS: **Object Explorer → right-click stored proc → Script As → CREATE To → New Query Window**
- From a `.sql` file: paste inline or provide the file path

### SET STATISTICS IO, TIME output
```sql
SET STATISTICS IO, TIME ON;
GO
-- your query here
SET STATISTICS IO, TIME OFF;
```
After running: **SSMS Messages tab** → Select All → Copy → paste into Claude

### Execution plan (.sqlplan)
In SSMS:
- **Actual plan (recommended):** `Ctrl+M` → run the query → plan appears in Execution Plan tab → right-click → **Save Execution Plan As** → `.sqlplan`
- **Estimated plan:** `Ctrl+L` → right-click → **Save Execution Plan As** → `.sqlplan`

> **Actual plan is strongly preferred** for `/sqlplan-review`. Many checks (confirmed spills, bad row estimates, actual vs estimated rows) require actual execution statistics.

### Deadlock XML
**Method 1 — SSMS deadlock graph:**
- SSMS → Management → Extended Events → Sessions → system_health → double-click **deadlock** event → **Save Deadlock File As** → `.xdl`

**Method 2 — system_health session query:**
```sql
SELECT
    xdr.value('@timestamp', 'datetime2') AS deadlock_time,
    xdr.query('.') AS deadlock_graph
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets t
    JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
    WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(xdr)
ORDER BY deadlock_time DESC;
```
Copy the XML from the `deadlock_graph` column.

### Batch of execution plans
- Use **SQL Server Query Store**: SSMS → Databases → your database → **Query Store** → Top Resource Consuming Queries → for each query, right-click plan → **Save Execution Plan As**
- Use **Extended Events**: create an XE session capturing `query_post_execution_showplan` and batch-export all captured plans

---

## Check ID Reference

Each check has an ID you can use when discussing findings or searching the `references/check-explanations.md` files inside each skill directory.

| Prefix | Skill | Scope | Count |
|--------|-------|-------|-------|
| `T1–T78` | `tsql-review` | T-SQL source: structural, security, correctness, deprecated syntax, performance | 78 |
| `I1–I15` | `sqlstats-review` | I/O metrics: logical reads, scan count, physical reads, spills, LOB, columnstore | 15 |
| `W1–W7` | `sqlstats-review` | Time metrics: CPU vs elapsed ratio, compile overhead, long execution | 7 |
| `X1–X12` | `sqltrace-review` | Event-level: long duration, high CPU/reads, attention, lock timeout, recompile, spill warnings | 12 |
| `X13–X20` | `sqltrace-review` | Workload aggregate: N+1 frequency, sniffing variance, ad-hoc ratio, recompile rate, auto-grow | 8 |
| `V1–V18` | `sqlwait-review` | Wait types: I/O, locks, parallelism (CXPACKET/HT*), memory grants, log I/O, CPU, TempDB, latch, log space, poison/throttle waits | 18 |
| `V19–V26` | `sqlwait-review` | Trend analysis (3+ snapshots): direction, spikes, peak period, velocity, emerging waits, correlated spikes, transient events, pattern | 8 |
| `V27–V29` | `sqlwait-review` | Operational checks: PAGELATCH on user DBs (insert hotspots), BACKUPIO/BACKUPBUFFER (backup I/O), cumulative skew detection (outlier dominance) | 3 |
| `V30–V36` | `sqlwait-review` | Modern feature wait types: In-Memory OLTP (XTP*), Columnstore, Query Store (QDS*), Transaction/DTC, Service Broker, Full Text Search, Parallel Redo | 7 |
| `V37–V40` | `sqlwait-review` | Memory and I/O detail: forced memory grants, grant timeouts, stolen memory, file-level I/O latency (requires optional capture queries) | 4 |
| `S1–S33` | `sqlplan-review` | Statement-level: memory grants, parallelism, compile, statistics, hints, plan cache, row width | 33 |
| `N1–N66` | `sqlplan-review` | Node-level: per-operator scans, joins, spills, row estimates, index usage, elapsed timing, thread starvation | 66 |
| `C1–C10` | `sqlplan-compare` | Regression: what changed between two plans | 10 |
| `D1–D8` | `sqlplan-index-advisor` | Derived index rules: Key Lookup, scan, sort, spool, loops, heap | 8 |
| `P1–P8` | `sqlplan-deadlock` | Deadlock patterns: lock order, reader/writer, FK, SERIALIZABLE, self | 8 |
| `Q1–Q25` | `query-store-review` | Query Store: regressed queries, plan instability, resource hotspots, query-level waits, operational health | 25 |
| `R1–R20` | `procstats-review` | Procedure/trigger/function stats: top consumers, per-execution efficiency, N+1 patterns, parameter sniffing signals, trend analysis | 20 |
| `L1–L25` | `clusterlog-review` | WSFC cluster log: lease timeouts, health check failures, RHS crashes, quorum loss, node eviction, network partition, AG resource transitions, configuration signals | 25 |
| `H1–H22` | `hadr-health-review` | AG health: replica connectivity, data loss risk, recovery time, throughput, and configuration | 22 |
| `E1–E28` | `errorlog-review` | ERRORLOG: AG failover, lease expiry, memory pressure, I/O slow, corruption, login failure bursts, startup/shutdown, configuration signals | 28 |
| `K1–K30` | `spn-review` | SPN and Kerberos delegation: MSSQLSvc SPN presence, service account binding, AG listener and alias, permissions, KCD/RBCD delegation config, AD account sensitivity | 30 |

**Total: 435 checks across all skills.**

---

## Frequently Asked Questions

**Q: Should I always run all skills on every query?**

No. Start with the symptom and use the minimum skill that gives you the answer:
- Code review time → `/tsql-review` only
- "Is this query slow?" → `/sqlstats-review` first (fast), then `/sqlplan-review` if you need operator detail
- Already know it's slow → `/sqlplan-review` directly

**Q: When should I use `/sqlwait-review` vs `/sqlstats-review`?**

`/sqlwait-review` operates at the **server level** — it answers "why is the entire server slow?" by analyzing `sys.dm_os_wait_stats` across all sessions. `/sqlstats-review` operates at the **query level** — it answers "why did this specific query read so much data?" using `SET STATISTICS IO, TIME ON` output for one query. Start with `/sqlwait-review` when users report the server is slow and you don't know which query or bottleneck type is causing it. Start with `/sqlstats-review` when you already have a specific slow query to investigate.

**Q: CXPACKET is 40% of my wait stats. Should I reduce MAXDOP?**

Not immediately — and probably not at all. CXPACKET records the control thread waiting for parallel worker threads to finish and is **expected** for parallel queries. The skill's V3 check now interprets CXPACKET in context of your server's configuration:

- **If MAXDOP = 0 and Cost Threshold for Parallelism = 5** (both server defaults): almost any query costing > 5 units goes parallel — including many medium-cost queries that gain nothing from it. Raising CTPfP to 25–50 is the correct first action; it reduces unnecessary parallelism without touching MAXDOP. Include the config capture query with your wait stats and the skill will call this out explicitly.
- **If CTPfP is already tuned (≥ 25) and MAXDOP is set**: the CXPACKET is from queries that genuinely use parallelism. Investigate data skew (update statistics), then consider per-query MAXDOP hints before a server-wide MAXDOP change.
- **Reducing MAXDOP should be the last resort**, not the first response.

**Q: ASYNC_NETWORK_IO is my top wait. How do I fix it?**

You don't fix it in SQL Server — ASYNC_NETWORK_IO is almost never a SQL Server problem. It means SQL Server has results ready but the client is slow to consume them (row-by-row processing, buffering the entire result set, slow network). Investigate the application: use streaming data readers instead of buffering, add `SET NOCOUNT ON`, add pagination, and check network latency between app server and SQL Server.

**Q: I see LOG_RATE_GOVERNOR in my wait stats. What is it?**

This is a SQL Server 2019+ / Azure SQL wait that fires when SQL Server is actively throttling your transaction log generation rate. On Azure SQL it happens when your service tier's log I/O limit is hit (e.g., 25 MB/s on General Purpose). On-premises it can indicate Always On secondary replicas can't keep up. Reduce DML volume, batch writes more aggressively, or upgrade the service tier.

**Q: What's the difference between `/sqlstats-review` and `/sqlplan-review`?**

`/sqlstats-review` tells you *what happened at the I/O layer*: which tables were read, how many pages, how long it took. `/sqlplan-review` tells you *why*: which operators were chosen, what join strategy, what row estimates were made. Use STATISTICS to measure severity; use the plan to understand root cause.

**Q: `/sqlplan-review` found a Key Lookup. Should I also run `/sqlplan-index-advisor`?**

Yes — `/sqlplan-index-advisor` is the natural next step after `/sqlplan-review` finds issues. It takes the same plan, extracts every index opportunity (not just Key Lookups), merges them with the optimizer's own suggestions, and produces ready-to-run DDL.

**Q: When should I use `/sqlplan-batch` vs `/sqlplan-review`?**

Use `/sqlplan-batch` when you don't know which queries to focus on — it identifies the worst offenders. Use `/sqlplan-review` when you already know which query is slow and want deep analysis of that specific plan.

**Q: Can I run multiple skills in one conversation?**

Yes. A typical session: paste a slow proc body → `/tsql-review` → paste STATISTICS output → `/sqlstats-review` → paste the `.sqlplan` → `/sqlplan-review` → `/sqlplan-index-advisor`. Each skill builds on what the previous one found.

**Q: My query involves a deadlock AND it's slow. Where do I start?**

Start with the deadlock: `/sqlplan-deadlock`. A missing index (P4, P5) is the most common deadlock cause and will also fix the performance problem. If adding the index doesn't eliminate the deadlock, investigate isolation level changes (P2, P6) with `/sqlplan-review` for the overall plan.

**Q: The execution plan is estimated (no actual rows). Does `/sqlplan-review` still work?**

Yes, but with limitations. Checks that require actual execution statistics — confirmed spills (N41–N43), bad row estimates (N21), actual CPU/elapsed — cannot fire. The skill notes these explicitly in the output. Capture an actual plan (`Ctrl+M`) for full analysis.

---

## Installing All Skills

```bash
# Install all skills globally
cp -r skills/tsql-review           ~/.claude/skills/tsql-review
cp -r skills/sqlstats-review       ~/.claude/skills/sqlstats-review
cp -r skills/sqltrace-review       ~/.claude/skills/sqltrace-review
cp -r skills/sqlwait-review        ~/.claude/skills/sqlwait-review
cp -r skills/sqlplan-review        ~/.claude/skills/sqlplan-review
cp -r skills/sqlplan-index-advisor ~/.claude/skills/sqlplan-index-advisor
cp -r skills/sqlplan-compare       ~/.claude/skills/sqlplan-compare
cp -r skills/sqlplan-deadlock      ~/.claude/skills/sqlplan-deadlock
cp -r skills/sqlplan-batch         ~/.claude/skills/sqlplan-batch

# Or install all at once
cp -r skills/* ~/.claude/skills/
```

For project-scoped installation (only active in a specific project):
```bash
cp -r skills/* .claude/skills/
```
