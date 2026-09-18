---
name: sqlblocking-review
description: Analyze SQL Server lock blocking from sys.dm_exec_requests, sys.dm_exec_sessions, sys.dm_os_waiting_tasks, sys.dm_tran_locks, open-transaction DMVs, and blocked process reports. Applies 36 checks (BL1–BL36) covering blocking chain topology and head-blocker identification, head-blocker state classification against the six documented blocking scenarios, lock-level evidence such as escalation and Sch-M and key-range locks, transaction and isolation-level design faults, and blocking observability configuration. Use this skill whenever sessions are blocked, applications report lock timeouts, LCK_M waits dominate, or a DBA pastes blocking chain output and asks who is blocking whom. Trigger when blocked_session_id, blocking_session_id, blocked process report XML, or sp_who2 BlkBy output is present.
triggers:
  - /sqlblocking-review
  - /blocking-review
  - /head-blocker
  - /sqlblocking
---

# SQL Server Blocking Review Skill

## Purpose

Identify the head of a blocking chain, explain why it holds its locks, and give a ranked remediation path. Applies 36 checks (BL1–BL36) across five categories:

- **BL1–BL7** — Blocking chain topology: head blocker identification, block duration, chain depth, fan-out, cross-database chains, concurrency exhaustion, and chronic recurrence across captures
- **BL8–BL15** — Head-blocker state classification: maps the head blocker to the documented blocking scenarios (long-running query, sleeping session with an open transaction, orphaned transaction, rollback, client not fetching results, client/server distributed deadlock), plus non-lock waits and maintenance work at the head
- **BL16–BL23** — Lock-level evidence: lock escalation to table locks, schema modification locks, hot resource contention, key-range locks, lock conversion waits, application locks, and lock footprint size
- **BL24–BL30** — Transaction and isolation design: long-running open transactions, elevated isolation levels, implicit transactions, transactions held across client round-trips, blocking lock hints, reader-writer blocking curable by row versioning, and row-versioning side effects
- **BL31–BL36** — Observability and platform configuration: blocked process threshold, blocked process report capture, lock escalation overrides, scan-driven lock footprints, accelerated database recovery, and optimized locking

This skill analyzes captured artifacts only — it never opens a connection to SQL Server. The user runs the capture queries below and pastes the output.

Blocking is normal and self-clearing in a lock-based engine; the question this skill answers is which blocking is *persistent*, *what holds the locks*, and *whether it will resolve on its own*.

## Input

Accept any of:

- **DMV output** from the blocking-chain capture queries below — `sys.dm_exec_requests`, `sys.dm_exec_sessions`, `sys.dm_os_waiting_tasks`, `sys.dm_tran_locks`, `sys.dm_tran_active_transactions`, `sys.dm_exec_input_buffer`, `sys.dm_exec_sql_text` (preferred; two or more captures minutes apart give the strongest evidence)
- **A blocked process report** — the XML payload of the `blocked_process_report` Extended Event, or the equivalent Profiler event, containing `<blocked-process>` and `<blocking-process>` elements
- **`sp_who2` / Activity Monitor output** — the `BlkBy` column, SSMS "Activity - All Blocking Transactions" report text, or a screenshot transcription
- **Wait statistics** showing `LCK_M_*` waits when the user asks "what is blocking?" — analyze what is available and name the extra capture needed
- **A natural language description** of symptoms ("every morning at 09:05 all order inserts stall for two minutes, then clear on their own")

Partial input is workable: state which checks could not be evaluated and which capture closes the gap, rather than guessing.

### Recommended capture queries

```sql
-- 1. Blocking chain with head blocker, statement text, and session state
--    Run this first. Level 0 rows are head blockers.
WITH cteHead AS (
    SELECT  sess.session_id,
            req.request_id,
            req.blocking_session_id,
            wait_type       = LEFT(ISNULL(req.wait_type, ''), 50),
            wait_resource   = LEFT(ISNULL(req.wait_resource, ''), 60),
            last_wait_type  = LEFT(ISNULL(req.last_wait_type, ''), 50),
            req.wait_time,
            request_status  = LEFT(ISNULL(req.status, ''), 15),
            session_status  = LEFT(sess.status, 15),
            req.command,
            req.open_transaction_count,
            session_open_tran = sess.open_transaction_count,
            sess.transaction_isolation_level,
            sess.is_user_process,
            sess.host_name,
            sess.program_name,
            sess.login_name,
            sess.last_request_start_time,
            sess.last_request_end_time,
            req.cpu_time,
            req.logical_reads,
            req.percent_complete,
            req.[sql_handle],
            conn.most_recent_sql_handle
    FROM sys.dm_exec_sessions AS sess
    LEFT JOIN sys.dm_exec_requests    AS req  ON req.session_id  = sess.session_id
    LEFT JOIN sys.dm_exec_connections AS conn ON conn.session_id = sess.session_id
),
cteChain AS (
    SELECT  head_blocker_session_id = h.session_id, h.session_id, h.blocking_session_id,
            h.wait_type, h.wait_time, h.wait_resource, h.request_status, h.session_status,
            h.command, h.open_transaction_count, h.session_open_tran,
            h.transaction_isolation_level, h.host_name, h.program_name, h.login_name,
            h.last_request_start_time, h.last_request_end_time, h.percent_complete,
            h.[sql_handle], h.most_recent_sql_handle, [level] = 0
    FROM cteHead AS h
    WHERE (h.blocking_session_id IS NULL OR h.blocking_session_id = 0)
      AND h.session_id IN (SELECT DISTINCT blocking_session_id FROM cteHead WHERE blocking_session_id <> 0)
    UNION ALL
    SELECT  c.head_blocker_session_id, b.session_id, b.blocking_session_id,
            b.wait_type, b.wait_time, b.wait_resource, b.request_status, b.session_status,
            b.command, b.open_transaction_count, b.session_open_tran,
            b.transaction_isolation_level, b.host_name, b.program_name, b.login_name,
            b.last_request_start_time, b.last_request_end_time, b.percent_complete,
            b.[sql_handle], b.most_recent_sql_handle, c.[level] + 1
    FROM cteHead AS b
    INNER JOIN cteChain AS c
            ON c.session_id = b.blocking_session_id
           AND c.session_id <> b.session_id   -- avoid infinite recursion on latch-type blocking
    WHERE c.wait_type COLLATE Latin1_General_BIN NOT IN ('EXCHANGE', 'CXPACKET') OR c.wait_type IS NULL
)
SELECT  c.*,
        blocker_or_last_query = txt.text,
        input_buffer          = ib.event_info
FROM cteChain AS c
OUTER APPLY sys.dm_exec_sql_text (ISNULL(c.[sql_handle], c.most_recent_sql_handle)) AS txt
OUTER APPLY sys.dm_exec_input_buffer (c.session_id, NULL) AS ib
ORDER BY c.head_blocker_session_id, c.[level], c.session_id;

-- 2. Open transactions with age — finds sleeping sessions holding locks
SELECT  tst.session_id,
        database_name          = DB_NAME(s.database_id),
        tat.transaction_begin_time,
        transaction_duration_s = DATEDIFF(SECOND, tat.transaction_begin_time, SYSDATETIME()),
        transaction_type       = CASE tat.transaction_type
                                     WHEN 1 THEN 'Read/write' WHEN 2 THEN 'Read-only'
                                     WHEN 3 THEN 'System'     WHEN 4 THEN 'Distributed' END,
        transaction_state      = tat.transaction_state,
        session_open_tran      = tst.open_transaction_count,
        request_status         = r.status,
        s.status               AS session_status,
        s.host_name, s.program_name, s.login_name, s.is_user_process,
        s.last_request_start_time, s.last_request_end_time,
        s.transaction_isolation_level,
        input_buffer           = ib.event_info
FROM sys.dm_tran_active_transactions  AS tat
JOIN sys.dm_tran_session_transactions AS tst ON tst.transaction_id = tat.transaction_id
JOIN sys.dm_exec_sessions             AS s   ON s.session_id       = tst.session_id
LEFT JOIN sys.dm_exec_requests        AS r   ON r.session_id       = s.session_id
CROSS APPLY sys.dm_exec_input_buffer (s.session_id, NULL) AS ib
ORDER BY tat.transaction_begin_time;

-- 3. Waiting tasks joined to the locks they are waiting for
SELECT  wt.session_id, wt.wait_duration_ms, wt.wait_type, wt.blocking_session_id,
        wt.resource_description,
        tm.resource_type, tm.resource_subtype, tm.request_mode, tm.request_status,
        tm.resource_associated_entity_id,
        database_name = DB_NAME(tm.resource_database_id)
FROM sys.dm_tran_locks        AS tm
JOIN sys.dm_os_waiting_tasks  AS wt ON tm.lock_owner_address = wt.resource_address
ORDER BY wt.wait_duration_ms DESC;

-- 4. Lock footprint per session — escalation risk and what the head blocker holds
SELECT  request_session_id,
        database_name = DB_NAME(resource_database_id),
        resource_type, resource_subtype, request_mode, request_status,
        lock_count = COUNT(*),
        sample_resource = MIN(resource_description),
        sample_entity   = MIN(resource_associated_entity_id)
FROM sys.dm_tran_locks
GROUP BY request_session_id, resource_database_id, resource_type, resource_subtype,
         request_mode, request_status
ORDER BY lock_count DESC;

-- 5. Blocking observability and database-level concurrency settings
SELECT  name, value_in_use
FROM sys.configurations
WHERE name IN ('blocked process threshold (s)');

SELECT  name,
        snapshot_isolation_state_desc,
        is_read_committed_snapshot_on,
        is_accelerated_database_recovery_on,
        recovery_model_desc
FROM sys.databases
WHERE database_id > 4;

SELECT  session_name = s.name, s.startup_state, event_name = e.name
FROM sys.server_event_sessions AS s
JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
WHERE e.name IN ('blocked_process_report', 'lock_escalation', 'xml_deadlock_report', 'locking_stats');
```

> Optimized-locking instances also expose `is_optimized_locking_on` in `sys.databases` and `XACT` lock resources in `sys.dm_tran_locks`. See BL36.

---

## Analysis Order

1. **Find the head blocker** — the session whose `blocking_session_id` is 0 or NULL and that appears as another session's `blocking_session_id`. Everything else is a consequence of it (BL1).
2. **Classify the head blocker's state** — `status`, `wait_type`, and `open_transaction_count` decide whether the block resolves on its own or needs intervention (BL8–BL15).
3. **Read the lock evidence** — what resource, what mode, whose locks, how many (BL16–BL23).
4. **Explain the transaction design** — how long the transaction has been open, at what isolation level, with what hints (BL24–BL30).
5. **Check observability** — whether this will be captured automatically next time (BL31–BL36).

Report the head blocker's *identity, statement, and state* before any recommendation; a fix aimed at a victim session treats the symptom.

---

## Thresholds Reference

| Metric | Info | Warning | Critical |
|--------|------|---------|----------|
| Lock wait duration of any blocked session (`wait_time` / `wait_duration_ms`) | < 5 s | 5–29 s | ≥ 30 s |
| Blocking chain depth (levels below the head blocker) | 1 | 2 | ≥ 3 |
| Blocking fan-out (sessions blocked by one head blocker) | 1–2 | 3–9 | ≥ 10 |
| Blocked sessions as a share of active user requests | < 10% | 10–24% | ≥ 25% |
| Open transaction age on a session holding locks | < 60 s | 60–299 s | ≥ 300 s |
| Idle time of a sleeping session with an open transaction (`last_request_end_time` to capture time) | < 30 s | 30–299 s | ≥ 300 s |
| Locks held by a single session on one table or index | < 2,500 | 2,500–4,999 | ≥ 5,000 (escalation threshold) |
| `blocked process threshold (s)` setting | 5–30 | 31–86,400 | 0 (off) or 1–4 (ineffective) |
| Repeat appearances of the same head-blocker statement across captures | 1 | 2 | ≥ 3 |

> **Threshold provenance:** The 5,000-lock escalation threshold and the `blocked process threshold (s)` range (5 to 86,400, with a 5-second lock-monitor wake interval) are Microsoft-documented values. The wait-duration, chain-depth, fan-out, transaction-age, and recurrence cutoffs are operational heuristics for prioritisation — compare them against the workload's own baseline before calling a number a problem.

---

## Blocking Chain Topology Checks (BL1–BL7)

### BL1 — Head Blocker Identified
- **Trigger:** A session has `blocking_session_id` of 0 or NULL and appears as the `blocking_session_id` of at least one other session
- **Severity:** Info when the chain clears within the Info duration band; escalates with BL2–BL4
- **Fix:** Report the head blocker's `session_id`, `login_name`, `host_name`, `program_name`, current statement (`sys.dm_exec_sql_text`) or last statement (`sys.dm_exec_input_buffer`), `status`, `wait_type`, and `open_transaction_count`. Every subsequent finding attaches to this session. When several independent chains exist, report one head blocker per chain and rank the chains by total blocked session count and longest wait.

### BL2 — Long Lock Wait
- **Trigger:** Any blocked session shows a lock wait (`wait_type` starting `LCK_M_`) with `wait_time` or `wait_duration_ms` at or above the Warning band in the Thresholds Reference
- **Severity:** Warning in the 5–29 s band; Critical at 30 s or more
- **Fix:** Waits past the client's command timeout become application errors, so treat this as the user-visible severity of the incident. Record the longest wait, the resource it waits on, and the head blocker's state from BL8–BL15, which determines whether waiting is enough or the head blocker needs a `KILL`. Compare `wait_time` across two captures: a falling value means locks are being acquired and released (progress), a rising value on the same `wait_resource` means a stalled head blocker.

### BL3 — Deep Blocking Chain
- **Trigger:** The chain from the head blocker reaches the Warning depth or more, measured as levels of `blocking_session_id` indirection
- **Severity:** Warning at 2 levels; Critical at 3 or more
- **Fix:** Depth means blocked sessions are themselves holding locks other sessions want, so the queue drains serially after the head blocker releases. Resolve the head blocker; do not kill intermediate sessions, whose rollback adds work and can lengthen the outage. Deep chains on a single hot table usually point at BL19 (hot resource) or BL16 (escalation).

### BL4 — Wide Blocking Fan-Out
- **Trigger:** One head blocker directly blocks sessions at or above the Warning fan-out count
- **Severity:** Warning at 3–9 sessions; Critical at 10 or more
- **Fix:** Wide fan-out with a shallow chain is the signature of one coarse lock (table or page) against many short readers/writers — check BL16 (escalation), BL17 (object-level X), and BL18 (Sch-M). Quantify the impact as blocked sessions multiplied by the longest wait so the business cost is explicit in the report.

### BL5 — Blocking Chain Spans Multiple Databases
- **Trigger:** Sessions in one chain hold or wait for locks whose `resource_database_id` resolves to more than one database, or the head blocker's `database_name` differs from a victim's
- **Severity:** Info; Warning when a distributed transaction (`transaction_type` = Distributed) or a linked-server call is involved
- **Fix:** Cross-database chains usually come from a transaction that spans databases (including one enlisted through MS DTC or a linked server), which holds locks in the first database for the duration of remote work. Shorten the transaction so remote calls happen outside it, or stage the remote data first and modify locally. A `request_session_id` of `-2` in `sys.dm_tran_locks` marks an orphaned distributed transaction that has to be resolved through `KILL` with the transaction UOW value.

### BL6 — Concurrency Exhaustion Risk
- **Trigger:** Blocked sessions reach the Warning share of active user requests, or `THREADPOOL` waits appear alongside the lock waits
- **Severity:** Warning at 10–24% blocked; Critical at 25% or more, or on any `THREADPOOL` wait
- **Fix:** Each blocked request pins a worker thread. Once blocked requests approach the worker thread limit, new connections — including the DBA's — cannot be scheduled and the instance looks down. Connect through the dedicated administrator connection, kill the head blocker, and afterwards address the root cause. Raising `max worker threads` treats the symptom and delays recovery.

### BL7 — Chronic Head Blocker Across Captures
- **Trigger:** Two or more captures (or repeated blocked process reports) show the same statement, `query_hash`, procedure, or client program at the head of a chain
- **Severity:** Warning at 2 appearances; Critical at 3 or more
- **Fix:** Recurrence moves the problem from incident to design defect. Pin the recurring statement, then decide which structural fix applies: query or index tuning (BL35), transaction shortening (BL24), isolation change (BL26/BL29), or scheduling (BL15). Set up the blocked process report (BL31–BL33) so subsequent occurrences are captured without a DBA at the keyboard.

---

## Head-Blocker State Classification (BL8–BL15)

These map the head blocker to the documented blocking scenarios. `status`, `wait_type`, and `open_transaction_count` are the three columns that separate them.

### BL8 — Head Blocker Is a Long-Running Query
- **Trigger:** Head blocker has `status` of `running`, `runnable`, or `suspended`, a non-NULL `wait_type` that is not a lock wait, and growing `cpu_time`, `reads`, or `logical_reads` across captures
- **Severity:** Warning; Critical when its runtime exceeds the blocked sessions' command timeout
- **Fix:** This blocking resolves itself when the query finishes, so treat it as a query performance problem rather than a locking problem. Capture the statement and plan and route to `/sqlplan-review` and `/sqlindex-advisor`; a scan that touches far more rows than it returns both lengthens the transaction and widens the lock footprint (BL35). If the query cannot be tuned in place, move the workload to a read-only replica or a reporting copy rather than killing it repeatedly.

### BL9 — Sleeping Head Blocker with an Open Transaction
- **Trigger:** Head blocker has `status` of `sleeping`, `wait_type` NULL, and `open_transaction_count` greater than 0 in `sys.dm_exec_sessions`
- **Severity:** Critical
- **Fix:** The session is idle inside an open transaction and still holds every lock the transaction acquired; this does not resolve on its own. The usual cause is a client that hit a query timeout or issued a cancel without a matching `ROLLBACK` or `COMMIT` — SQL Server ends the batch but keeps the transaction. Short-term: `KILL <session_id>`. Durable fix: roll back in the client's error handler (`IF @@TRANCOUNT > 0 ROLLBACK TRAN`), or use `SET XACT_ABORT ON` in the connection or in procedures that open transactions, remembering that statements after an aborting error will not run. Confirm the age of the transaction with BL24.

### BL10 — Orphaned Transaction
- **Trigger:** Head blocker is sleeping with `open_transaction_count` greater than 0 **and** `last_request_end_time` is older than the Warning idle band, or the client host is known to have disconnected or restarted
- **Severity:** Critical
- **Fix:** A batch-aborting error, a client crash, or a workstation restart left the transaction open while the connection still appears alive to SQL Server, so the locks are held until the session is killed or the instance restarts. `KILL <session_id>` releases them, and the kill can take up to 30 seconds because of the interval between kill checks. Prevent recurrence with `Try-Catch-Finally` cleanup in application code and `SET XACT_ABORT ON`. If connection pooling is in play, note that the transaction survives until the pooled connection is reused or aged out.

### BL11 — Head Blocker Is Rolling Back
- **Trigger:** Head blocker shows `command` of `KILLED/ROLLBACK`, a `status` of `rollback`, or a populated `percent_complete` on a rollback
- **Severity:** Warning; Critical when `percent_complete` advances slowly or `estimated_completion_time` exceeds the outage tolerance
- **Fix:** The rollback has to finish — it cannot be killed again or chosen as a deadlock victim, and restarting the instance makes it worse by moving the same work into startup recovery with the database inaccessible. Report `percent_complete` and `estimated_completion_time` and wait. To avoid a repeat, break large write batches into smaller transactions and schedule them off-hours (BL15), and consider accelerated database recovery, which makes lengthy rollbacks rare (BL36).

### BL12 — Client Is Not Consuming Results
- **Trigger:** Head blocker has `wait_type` of `ASYNC_NETWORK_IO` while holding locks, typically with `status` of `runnable` or `suspended` and a client that fetches row by row
- **Severity:** Warning; Critical when the wait persists across captures with the same `wait_resource` on the victims
- **Fix:** The server has produced rows the client has not fetched, so the statement — and its locks — stay open at the pace of the client. Rewrite the client to fetch the result set to completion promptly (server-side paging with `OFFSET`/`FETCH` is fine), avoid per-row processing inside the result loop, and keep result sets small. Poorly behaved reporting clients that cannot be changed belong on a reporting copy rather than the OLTP database.

### BL13 — Client/Server Distributed Deadlock
- **Trigger:** The head blocker's `host_name` matches the `host_name` of a session it blocks, one side waits on `ASYNC_NETWORK_IO` and the other on a lock, and the situation does not clear
- **Severity:** Critical
- **Fix:** Only one side of this cycle is a SQL Server lock, so the lock monitor cannot detect or resolve it — the other side is the client's own thread or connection scheduling. A query timeout on the client breaks the cycle; set one. The durable fix is in the application: avoid holding one connection's result set open while a second connection on the same thread modifies the same table, and do not feed rows read on one connection into writes on another inside the same logical unit.

### BL14 — Head Blocker Waits on a Non-Lock Resource
- **Trigger:** Head blocker's `wait_type` is an I/O, memory, log, or parallelism wait — `PAGEIOLATCH_*`, `WRITELOG`, `RESOURCE_SEMAPHORE`, `IO_COMPLETION`, `CXPACKET`/`CXCONSUMER`, `THREADPOOL`, `SOS_SCHEDULER_YIELD`
- **Severity:** Warning
- **Fix:** The blocking here is downstream of a different bottleneck: the head blocker holds locks because something else makes it slow. Fixing locking will not help until that resource is fixed. Route by wait: `PAGEIOLATCH_*`/`WRITELOG` to `/sqldiskio-review` and `/sqlwait-review`, `RESOURCE_SEMAPHORE` to `/sqlmemory-review`, `CXPACKET`/`CXCONSUMER` and `SOS_SCHEDULER_YIELD` to `/sqlwait-review` and `/sqlplan-review`.

### BL15 — Head Blocker Is Maintenance or System Work
- **Trigger:** Head blocker's `command` is a maintenance operation (`BACKUP DATABASE`, `DBCC`, `ALTER INDEX`, `UPDATE STATISTICS`, bulk load) or `is_user_process` is 0
- **Severity:** Warning; Critical during business hours on an OLTP database
- **Fix:** Maintenance that blocks production is a scheduling and options problem, not a query problem. Move the job to a low-activity window; use `ALTER INDEX ... REBUILD WITH (ONLINE = ON)` where the edition supports it, with `WAIT_AT_LOW_PRIORITY` so the operation yields instead of queueing behind and in front of user work; chunk large deletes and updates; and keep statistics maintenance off peak. Backups do not block DML but do conflict with other backups and with some file and bulk operations — check `resource_subtype` values such as `DATABASE.BULKOP_BACKUP_DB`.

---

## Lock-Level Evidence Checks (BL16–BL23)

### BL16 — Lock Escalation to a Table Lock
- **Trigger:** `sys.dm_tran_locks` shows the head blocker holding an `OBJECT` lock with `request_mode` of `S` or `X` while its row or page locks have disappeared, or a `lock_escalation` Extended Event fired for the same object
- **Severity:** Critical when the escalated table lock is what victims wait for; Warning when escalation happened but is not the blocking lock
- **Fix:** Escalation converts many row or page locks into one table lock, which blocks every other user of the table. An `OBJECT` lock in an intent mode (`IS`, `IU`, `IX`) is not escalation and points elsewhere. Preferred fixes, in order: break the operation into smaller transactions (delete or update in batches of a few hundred to a few thousand rows); tune the statement and its indexes so fewer locks are taken (BL35); make predicates SARGable so a seek replaces a scan. Disabling escalation is a last resort — `ALTER TABLE ... SET (LOCK_ESCALATION = DISABLE)` on the one table, and the instance-wide trace flags 1211 and 1224 only to mitigate severe blocking while a real fix is prepared, because they can push lock memory to the point of error 1204.

### BL17 — Exclusive Object-Level Lock Held
- **Trigger:** Head blocker holds `resource_type` of `OBJECT` with `request_mode` of `X` and the escalation evidence in BL16 is absent
- **Severity:** Critical
- **Fix:** A whole-table exclusive lock usually comes from a `TABLOCKX` hint, a bulk load with `TABLOCK`, or DDL. Remove the hint unless the operation genuinely needs table-level exclusivity, and schedule bulk loads that require `TABLOCK` for a maintenance window. When the object is a staging table used by a nightly load, partition switching moves the data in with a brief metadata-only operation instead of a long table lock.

### BL18 — Schema Modification Lock Blocking
- **Trigger:** Any session holds or waits for `request_mode` of `Sch-M`, or waits for `Sch-S` behind a held `Sch-M`
- **Severity:** Critical
- **Fix:** A schema modification lock conflicts with every other lock mode, including the schema stability lock that ordinary queries and even `READUNCOMMITTED` readers take, so one DDL statement stalls all access to the object. Typical sources are offline `ALTER INDEX ... REBUILD`, `ALTER TABLE`, truncate, partition switch, and statistics or index metadata operations (`OBJECT.INDEX_OPERATION`, `OBJECT.UPDSTATS` subtypes). Run DDL in a maintenance window, use online index operations where available, and wrap DDL with `SET LOCK_TIMEOUT` plus `WAIT_AT_LOW_PRIORITY` so a failed attempt backs off instead of queueing the whole workload behind itself.

### BL19 — Hot Resource Contention
- **Trigger:** Multiple waiting sessions show the same `resource_description` or the same `resource_associated_entity_id` (a `KEY`, `PAGE`, or `RID` resource) in `sys.dm_os_waiting_tasks`
- **Severity:** Warning; Critical when the queue on one resource reaches the Critical fan-out threshold
- **Fix:** Contention is concentrated on one row, page, or key range rather than spread across the table. Identify the object with `sys.partitions` (join `hobt_id` to `resource_associated_entity_id`) and, for a `PAGE` resource, `sys.dm_db_page_info`. Common shapes: a counter or "next ID" row every transaction updates — replace with a sequence or identity; last-page insert contention on an ever-increasing clustered key — consider a different key, a hash-distributed key, or `OPTIMIZE_FOR_SEQUENTIAL_KEY` on supporting versions; a queue table polled by many workers — use `READPAST` with row locks.

### BL20 — Key-Range Locks Present
- **Trigger:** `request_mode` values beginning `Range` (`RangeS_S`, `RangeS_U`, `RangeI_N`, `RangeX_X`) appear on the head blocker or the victims
- **Severity:** Warning
- **Fix:** Key-range locks come from `SERIALIZABLE` — set explicitly, inherited from a `HOLDLOCK`/`SERIALIZABLE` hint, or supplied by a client library or distributed transaction default. They lock gaps as well as rows, so they block inserts into a range that has no rows yet. Confirm the isolation level (BL26) and lower it to the weakest level the correctness requirement allows; most code that reaches for `SERIALIZABLE` needs only a targeted `UPDLOCK, HOLDLOCK` on a single key to serialize one race.

### BL21 — Lock Conversion Wait
- **Trigger:** `sys.dm_tran_locks` shows `request_status` of `CONVERT` (or a low-priority variant) for a waiting request
- **Severity:** Warning; Critical when the converting session is itself the head of a chain
- **Fix:** The session already holds a lock on the resource and waits to upgrade it — typically shared to exclusive, in a read-then-write pattern inside one transaction. Two transactions doing this against the same row deadlock rather than block. Take the stronger lock up front with `UPDLOCK` at the read step, or restructure to a single statement (`UPDATE ... WHERE` with the predicate, or `MERGE` with `HOLDLOCK`) so no upgrade is needed.

### BL22 — Application Lock Contention
- **Trigger:** `resource_type` of `APPLICATION` appears among held or waited-for locks
- **Severity:** Warning
- **Fix:** These are explicit `sp_getapplock` mutexes taken by application code, not engine locks on data, and the wait usually means a critical section is held longer than intended or released on a path the code misses. Verify the lock owner (`Transaction` versus `Session`), that every acquire has a matching `sp_releaseapplock` — or that the owner is `Transaction` so commit or rollback releases it — and that `@LockTimeout` is set so a stuck holder produces a handled error instead of an indefinite wait. The `resource_description` carries the principal ID and the first 32 characters of the resource name, which identifies the critical section. Note that a deadlock involving an application lock does not roll back the transaction that requested it — a return code of -3 has to be handled with an explicit `ROLLBACK` in the calling code.

### BL23 — Large Lock Footprint
- **Trigger:** One session holds locks on a single table or index at or above the Warning count in the Thresholds Reference
- **Severity:** Warning at 2,500–4,999 locks; Critical at 5,000 or more (escalation is triggered when the count on one table or index exceeds 5,000, after the memory threshold is checked)
- **Fix:** A large footprint is the precursor to BL16 and, on its own, already blocks widely. Reduce rows touched per transaction by batching, and reduce locks per row by removing scans: a bookmark lookup with `PREFETCH` can raise part of a read-committed query to repeatable-read behaviour and take thousands of key locks, so a covering index removes both the lookup and the locks. Escalation also fires on memory pressure — lock memory is capped at 60 percent of the visible buffer pool and escalation is considered at 40 percent of that — so check `/sqlmemory-review` when footprints are large instance-wide.

---

## Transaction and Isolation Checks (BL24–BL30)

### BL24 — Long-Running Open Transaction
- **Trigger:** `sys.dm_tran_active_transactions` shows a read/write transaction whose age reaches the Warning band while the session holds locks
- **Severity:** Warning at 60–299 s; Critical at 300 s or more
- **Fix:** Lock duration equals transaction duration for write locks, so transaction length is the single biggest lever on blocking. Move everything that does not need to be transactional out of the transaction: validation reads, remote or linked-server calls, file or queue work, and user or service round-trips. Commit per batch in loops rather than wrapping the loop. Where a long read must stay, row versioning (BL29) removes its blocking effect without shortening it.

### BL25 — Transaction Held Across Client Round-Trips
- **Trigger:** A session alternates between `sleeping` with `open_transaction_count` greater than 0 and short bursts of activity across captures, or a blocked process report shows the blocker's `<inputbuf>` containing only `BEGIN TRAN` or a single statement of a larger unit
- **Severity:** Critical
- **Fix:** The transaction spans client-side work — a screen, a service call, or a loop that fetches and then decides. Every lock taken before the round-trip is held for the user's think time. Restructure so the transaction opens after all input is gathered and closes in the same batch or procedure, and use optimistic concurrency (a rowversion check on update) instead of holding read locks to guard against concurrent edits.

### BL26 — Elevated Transaction Isolation Level
- **Trigger:** `transaction_isolation_level` is 3 (`RepeatableRead`) or 4 (`Serializable`) on the head blocker or on a blocked session
- **Severity:** Warning; Critical when key-range locks (BL20) are the blocking resource
- **Fix:** Above read committed, shared locks are held to the end of the transaction instead of being released after each read, so readers block writers for the whole transaction. Confirm whether the level is intentional: some client libraries and distributed-transaction stacks set `SERIALIZABLE` by default, and a `SET TRANSACTION ISOLATION LEVEL` left in a procedure persists for the connection, which pooling then hands to unrelated work. Set the level explicitly per connection to the weakest level correctness allows, and use a targeted hint at the one statement that needs stronger guarantees.

### BL27 — Implicit Transactions Enabled
- **Trigger:** A blocking session is sleeping with an open transaction, no explicit `BEGIN TRAN` appears in its input buffer, and its `program_name` or driver indicates a client that sets `IMPLICIT_TRANSACTIONS ON`
- **Severity:** Critical
- **Fix:** With implicit transactions on, a bare `SELECT` or `UPDATE` opens a transaction that stays open until the client commits — which an autocommit-style application never does, so locks accumulate until the connection is reset. Turn the setting off at the driver or connection level (`SET IMPLICIT_TRANSACTIONS OFF`), or make the client commit explicitly after each unit of work. This is the most common cause of a sleeping session holding locks with an innocuous-looking last statement.

### BL28 — Blocking Lock Hints in the Blocker's Statement
- **Trigger:** The head blocker's statement or input buffer contains `HOLDLOCK`, `SERIALIZABLE`, `TABLOCK`, `TABLOCKX`, `XLOCK`, `UPDLOCK`, `PAGLOCK`, or `REPEATABLEREAD`
- **Severity:** Warning; Critical for `TABLOCKX`, or `XLOCK`/`HOLDLOCK` held for the length of a long transaction
- **Fix:** Hints override the engine's lock choice and are frequently copied forward long after the reason for them has gone. Keep only those a correctness requirement needs, scope them to the single statement and table that needs them rather than the whole query, and prefer `UPDLOCK` on a narrow seek over `TABLOCKX` on the table. Note the mirror-image risk: `NOLOCK`/`READUNCOMMITTED` is not a blocking fix — it permits dirty, missing, and duplicated rows, and still waits behind a `Sch-M` lock (BL18).

### BL29 — Reader-Writer Blocking Curable by Row Versioning
- **Trigger:** Victims wait in `LCK_M_S` or `LCK_M_IS` behind a writer holding `X` or `IX` locks, the victims' statements are read-only, and the database has `is_read_committed_snapshot_on` = 0
- **Severity:** Warning; Critical when read-only reporting sessions are the majority of the victims
- **Fix:** Under read committed snapshot isolation, readers take a row version instead of a shared lock, which removes this entire class of blocking without changing query text. Enable it with `ALTER DATABASE <db> SET READ_COMMITTED_SNAPSHOT ON` — while the statement runs, the connection issuing it has to be the only open connection to the database (single-user mode is not required), so run it in a maintenance window, with `WITH ROLLBACK IMMEDIATE` if disconnecting the other sessions is acceptable. Budget for the costs before enabling: version store space and I/O in TempDB, 14 bytes added per row as rows are updated, and different semantics for read-then-write patterns, which may need `UPDLOCK` to stay correct. Writers still block writers.

### BL30 — Row-Versioning Side Effects
- **Trigger:** The database has RCSI or snapshot isolation enabled and the capture shows long-running transactions, a growing version store (TempDB, or the in-database persistent version store when ADR is on), or update-conflict errors (3960) in the application logs
- **Severity:** Warning
- **Fix:** Row versioning trades lock waits for version-store growth: the oldest open transaction pins versions for everything newer, so one forgotten transaction grows the version store until its home fills. Check where that store lives — with ADR enabled the versions go to the in-database persistent version store, otherwise to TempDB. Keep BL24 under control, monitor `sys.dm_tran_version_store_space_usage`, and size the relevant store for the peak. Under `SNAPSHOT` isolation, concurrent updates raise error 3960 instead of blocking, so the application needs retry logic; if that is not viable, use RCSI, which does not produce update conflicts.

---

## Observability and Platform Configuration Checks (BL31–BL36)

### BL31 — Blocked Process Threshold Not Configured
- **Trigger:** `blocked process threshold (s)` has `value_in_use` of 0
- **Severity:** Warning
- **Fix:** With the default of 0, no blocked process reports are produced, so the next incident leaves no automatic record of who blocked whom and the DBA has to be present while it happens. Set a threshold in seconds — a value around 5 to 30 matches most command timeouts — with `sp_configure 'blocked process threshold', 20` followed by `RECONFIGURE`; the setting takes effect without a restart. Pair it with a capture target (BL33) or the report has nowhere to land.

### BL32 — Blocked Process Threshold Set Ineffectively
- **Trigger:** `blocked process threshold (s)` is between 1 and 4, or is set so high that real incidents never reach it
- **Severity:** Warning
- **Fix:** The lock monitor wakes every 5 seconds, so a threshold below 5 cannot detect anything sooner and only adds work; the supported range is 5 to 86,400 seconds. Reports are generated once per reporting interval per blocked task and are best-effort, not real-time. Set the value just under the application's command timeout so a report exists for every block the users actually see.

### BL33 — No Capture Target for Blocking Events
- **Trigger:** No Extended Events session with the `blocked_process_report` event is defined or started; optionally also no `lock_escalation` or `xml_deadlock_report` event
- **Severity:** Warning
- **Fix:** Create a lightweight session with `blocked_process_report` (plus `lock_escalation` when escalation is suspected, and `attention` to catch the client timeouts that create orphaned transactions) writing to an `event_file` target, and set it to start with the server. For ad-hoc capture during an incident, `sql_batch_completed`/`rpc_completed` alongside the blocked process report shows what the blocker ran earlier in its transaction — the last statement alone often is not the one holding the locks. Deadlock graphs are captured by default in the `system_health` session; blocked process reports are not.

### BL34 — Lock Escalation Overrides in Effect
- **Trigger:** Trace flag 1211 or 1224 is enabled instance-wide, or tables in the chain have `LOCK_ESCALATION` set to `DISABLE` or (on partitioned tables) left at `TABLE` when `AUTO` is wanted
- **Severity:** Warning; Critical when 1211 is on, since it disables escalation unconditionally including under memory pressure
- **Fix:** Escalation exists to cap lock memory, which is finite — with it disabled, a large transaction can exhaust lock memory and produce error 1204, which aborts the statement and rolls back the transaction. Prefer per-table `LOCK_ESCALATION = DISABLE` over the trace flags, treat either as a temporary mitigation while the query and transaction are fixed, and on partitioned tables consider `LOCK_ESCALATION = AUTO` so escalation stops at the partition instead of the table.

### BL35 — Scan-Driven Lock Footprint
- **Trigger:** The head blocker's statement shows a table or index scan, a bookmark lookup over many rows, or a non-SARGable predicate (a function or conversion applied to a column), and its lock count or duration is in the Warning band
- **Severity:** Warning
- **Fix:** A query that reads more rows than it needs locks more rows than it needs and holds them longer, so index and query tuning is a locking fix as well as a performance fix. Route the statement to `/sqlplan-review` and `/sqlindex-advisor` for a covering index or a seek-enabling rewrite; make predicates SARGable by moving functions and conversions off the column side; and check implicit conversions, which turn a seek into a scan and are a common hidden cause.

### BL36 — Row-Versioning and Locking Platform Features Not Evaluated
- **Trigger:** Repeated or long blocking is present and the instance-level mitigations are unused — `is_accelerated_database_recovery_on` = 0 where long rollbacks occur (BL11), or, on platforms that offer it, `is_optimized_locking_on` = 0
- **Severity:** Info; Warning when BL11 or BL16 fires repeatedly
- **Fix:** Accelerated database recovery (SQL Server 2019 and later) makes lengthy rollbacks rare, which directly shortens the BL11 outage class, and it is a prerequisite for optimized locking. Optimized locking (SQL Server 2025 and Azure SQL Database / Managed Instance, where it is always on) replaces many row and key locks with a single transaction-ID lock and avoids most escalation; its lock-after-qualification component needs RCSI enabled to take effect. Under optimized locking the diagnostic shape changes — expect `XACT` resources in `sys.dm_tran_locks` and `LCK_M_S_XACT*` wait types — so read blocking chains with that in mind. Enable with `ALTER DATABASE <db> SET OPTIMIZED_LOCKING = ON` after ADR is on, and validate the workload first: lock hints reduce the benefit, and code that relies on strict execution ordering under RCSI can see different results.

---

## Output Format

Present findings in this order:

```
## Blocking Analysis

### Blocking Summary
- Head blocker: session <id> (<login> / <host> / <program>)
- State: <status> / wait_type <type> / open_transaction_count <n> — <resolves on its own | needs intervention>
- Impact: <n> sessions blocked, deepest chain <n> levels, longest wait <duration>
- X Critical, Y Warnings, Z Info

### Blocking Chain Map
session 71 (head)  UPDATE dbo.Orders ...  sleeping, open_tran 1, idle 6m
  └─ 84  LCK_M_U  42s  KEY 7:72057594045267968  SELECT ... FROM dbo.Orders
       └─ 92  LCK_M_S  38s  KEY 7:72057594045267968  SELECT ...

### Critical Issues   (labeled [C1], [C2], ...)
### Warnings          (labeled [W1], [W2], ...)
### Info              (labeled [I1], [I2], ...)

### Lock Evidence
| Session | Role | Resource | Mode | Status | Count | Object |

### Remediation Priority
| # | Action | Addresses | Effect | Risk | Rollback |

### Passed Checks
BL5, BL13, BL20, ... (explicitly verified clean)
```

Each finding states **Observed** (the value in the input) → **Impact** (what it costs) → **Fix** (what to do), with the check ID in parentheses after the issue name, for example `[C1] Sleeping session holding locks (BL9)`.

Separate immediate relief from durable fixes in the Remediation Priority table: name the one action that ends the current incident first (usually `KILL` of the head blocker, or waiting when BL11 applies), then the design changes that stop recurrence. For any `KILL` recommendation, state the rollback cost — a kill on a large write transaction starts a rollback that can take as long as the original work.

When the input does not cover a check, list it under a short "Not evaluated" note with the capture query that would cover it, rather than reporting it as passed.

> Analyzed by: `sqlblocking-review` (BL1–BL36)

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*

---

## Companion Skills

- `/sqlwait-review` — instance-wide `LCK_M_*` wait totals (V-checks) show how much of the workload's wait time is blocking; this skill explains a specific chain, that one sizes the problem
- `/sqldeadlock-review` — a deadlock is blocking that closed into a cycle; the same lock evidence (modes, resources, hints, isolation) drives both, so run it when the chain resolves itself by an error 1205 rather than a wait
- `/sqlplan-review` and `/sqlindex-advisor` — BL35 and BL8 route here: scans and lookups in the blocker's plan are what make the lock footprint large and the transaction long
- `/sqltrace-review` — shows the earlier statements in the blocker's transaction, which the last-statement view of the DMVs hides
- `/sqlquerystore-review` — confirms whether a chronic head blocker (BL7) regressed recently and provides its plan history and lock wait category totals
- `/sqldbconfig-review` — database-level concurrency settings behind BL29/BL30/BL36 (RCSI, snapshot isolation, ADR) are audited there
- `/sqlmemory-review` — lock memory pressure is an escalation trigger (BL23) and `RESOURCE_SEMAPHORE` at the head blocker (BL14) is a memory problem
- `/sqldiskio-review` — `PAGEIOLATCH_*`/`WRITELOG` at the head blocker (BL14) means slow storage is lengthening the lock hold
- `/tsql-review` — catches the source-level causes before deployment: missing `SET XACT_ABORT ON`, transactions around round-trips, stray isolation-level and lock hints

---

## VERSION_COMPATIBILITY

See [skills/VERSION_COMPATIBILITY.md](../VERSION_COMPATIBILITY.md) for the full compatibility matrix.

| Check | 2008 R2 | 2012 | 2014 | 2016 | 2017 | 2019 | 2022 | Azure SQL |
|-------|---------|------|------|------|------|------|------|-----------|
| BL1 Head blocker | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL2 Long lock wait | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL3 Chain depth | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL4 Fan-out | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL5 Cross-database chain | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Partial |
| BL6 Concurrency exhaustion | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL7 Chronic head blocker | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL8 Long-running query | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL9 Sleeping with open tran | Partial | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL10 Orphaned transaction | Partial | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL11 Rollback state | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL12 Client not fetching | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL13 Distributed deadlock | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL14 Non-lock wait at head | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL15 Maintenance at head | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Partial |
| BL16 Lock escalation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL17 Object X lock | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL18 Sch-M blocking | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL19 Hot resource | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL20 Key-range locks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL21 Conversion wait | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL22 Application lock | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL23 Lock footprint | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL24 Long open transaction | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL25 Transaction across round-trips | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL26 Elevated isolation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL27 Implicit transactions | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL28 Lock hints | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL29 RCSI candidate | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | On by default |
| BL30 Version store effects | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL31 BPR threshold off | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A |
| BL32 BPR threshold ineffective | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A |
| BL33 No capture target | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Partial |
| BL34 Escalation overrides | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Partial |
| BL35 Scan-driven footprint | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| BL36 ADR / optimized locking | — | — | — | — | — | ADR | ADR | ✓ |
