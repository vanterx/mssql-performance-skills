/*
================================================================================
  skills/sqlplan-review/scripts/02_capture_running_query.sql
  Capture Plan for an Actively Running Query for /sqlplan-review
================================================================================
  Use this when a query is currently slow and you want its plan immediately
  without waiting for it to complete.

  The plan captured here is the *estimated* plan (the compiled plan) since
  the query hasn't finished — actual row counts are not yet available.
  Note this limitation when running /sqlplan-review.

  Two approaches:
    A — Find slow queries by current wait type / duration (triage first)
    B — Capture plan for a specific SPID
================================================================================
*/

/* ============================================================================
   METHOD A — Identify slow/blocked queries right now
   Paste the wait_type column into /sqlwait-review context,
   then use Method B to get the plan for the worst offender.
   ============================================================================ */

SELECT
    spid              = r.session_id,
    status            = r.status,
    wait_type         = r.wait_type,
    wait_time_sec     = r.wait_time / 1000.,
    cpu_time_ms       = r.cpu_time,
    logical_reads     = r.logical_reads,
    elapsed_sec       = r.total_elapsed_time / 1000.,
    blocking_spid     = r.blocking_session_id,
    database_name     = DB_NAME(r.database_id),
    command           = r.command,
    sql_text          = LEFT(st.text, 300),
    login_name        = s.login_name,
    host_name         = s.host_name,
    program_name      = s.program_name,
    open_transactions = s.open_transaction_count
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.session_id > 50                   /* exclude system SPIDs */
  AND r.session_id <> @@SPID              /* exclude this query */
ORDER BY r.total_elapsed_time DESC;

/* ============================================================================
   METHOD B — Capture the actual execution plan for a specific SPID
   Replace @target_spid with the spid from Method A.
   Paste the query_plan column into /sqlplan-review.
   ============================================================================ */

DECLARE @target_spid int = 75;   /* change to target SPID from Method A */

SELECT
    session_id   = r.session_id,
    status       = r.status,
    wait_type    = r.wait_type,
    elapsed_sec  = r.total_elapsed_time / 1000.,
    sql_text     = LEFT(st.text, 500),
    query_plan   = qp.query_plan   /* copy this XML into /sqlplan-review — note: estimated only */
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.session_id = @target_spid;

/* ============================================================================
   METHOD C — Capture plans for ALL active requests sorted by CPU / reads
   Useful for a quick cross-section of what's running.
   ============================================================================ */
/*
SELECT TOP 20
    r.session_id,
    r.status,
    r.wait_type,
    cpu_time_ms    = r.cpu_time,
    logical_reads  = r.logical_reads,
    elapsed_sec    = r.total_elapsed_time / 1000.,
    sql_text       = LEFT(st.text, 200),
    query_plan     = qp.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
  AND qp.query_plan IS NOT NULL
ORDER BY r.cpu_time DESC;
*/
