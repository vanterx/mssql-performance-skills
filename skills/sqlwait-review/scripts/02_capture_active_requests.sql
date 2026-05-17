/*
================================================================================
  skills/sqlwait-review/scripts/02_capture_active_requests.sql
  Current Active Session Wait Capture for /sqlwait-review
================================================================================
  Captures what sessions are CURRENTLY waiting for — a live snapshot of
  active waits rather than cumulative history.

  This feeds the /sqlwait-review "current sessions" input mode.
  Paste the result into Claude with: /sqlwait-review

  Best used when:
    - A user reports "it's slow right now"
    - You want to identify blocking chains in real time
    - You want to confirm a wait type without waiting for a full interval
================================================================================
*/

/* ============================================================================
   QUERY A — All active waiting sessions right now
   ============================================================================ */

SELECT
    session_id        = r.session_id,
    status            = r.status,
    wait_type         = r.wait_type,
    wait_time_sec     = CAST(r.wait_time / 1000.0 AS decimal(10, 2)),
    wait_resource     = r.wait_resource,
    blocking_spid     = NULLIF(r.blocking_session_id, 0),
    database_name     = DB_NAME(r.database_id),
    cpu_time_ms       = r.cpu_time,
    logical_reads     = r.logical_reads,
    elapsed_sec       = CAST(r.total_elapsed_time / 1000.0 AS decimal(10, 2)),
    open_transactions = s.open_transaction_count,
    login_name        = s.login_name,
    host_name         = s.host_name,
    program_name      = s.program_name,
    command           = r.command,
    sql_text          = LEFT(st.text, 500)
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
ORDER BY r.wait_time DESC, r.total_elapsed_time DESC;

/* ============================================================================
   QUERY B — Blocking chain summary
   Shows who is blocking whom and the head of the blocking chain.
   ============================================================================ */

WITH blocking_chain AS (
    SELECT
        session_id       = s.session_id,
        blocking_id      = s.blocking_session_id,
        wait_type        = r.wait_type,
        wait_time_sec    = CAST(r.wait_time / 1000.0 AS decimal(10, 2)),
        wait_resource    = r.wait_resource,
        status           = r.status,
        sql_text         = LEFT(st.text, 300),
        open_transactions = s.open_transaction_count,
        login_name       = s.login_name,
        program_name     = s.program_name
    FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
    WHERE s.session_id > 50
      AND (r.blocking_session_id > 0 OR EXISTS (
              SELECT 1 FROM sys.dm_exec_requests r2
              WHERE r2.blocking_session_id = s.session_id))
)
SELECT
    chain_head       = CASE WHEN blocking_id = 0 OR blocking_id IS NULL
                            THEN '*** HEAD ***' ELSE '' END,
    session_id,
    blocking_id,
    wait_type,
    wait_time_sec,
    wait_resource,
    status,
    open_transactions,
    login_name,
    program_name,
    sql_text
FROM blocking_chain
ORDER BY blocking_id NULLS LAST, session_id;

/* ============================================================================
   QUERY C — Wait type aggregation from active requests (summary view)
   Useful when many sessions share the same wait type.
   ============================================================================ */

SELECT
    wait_type         = ISNULL(r.wait_type, 'RUNNING'),
    session_count     = COUNT(*),
    total_wait_sec    = CAST(SUM(r.wait_time) / 1000.0 AS decimal(10, 2)),
    max_wait_sec      = CAST(MAX(r.wait_time) / 1000.0 AS decimal(10, 2)),
    avg_wait_sec      = CAST(AVG(r.wait_time) / 1000.0 AS decimal(10, 2)),
    total_cpu_ms      = SUM(r.cpu_time),
    total_reads       = SUM(r.logical_reads)
FROM sys.dm_exec_requests r
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
GROUP BY r.wait_type
ORDER BY total_wait_sec DESC;
