/*  capture-blocking.sql — companion capture script for /sqlblocking-review

    Collects everything the skill needs to identify a head blocker and explain
    why it holds its locks. Read-only: no configuration is changed and nothing
    is killed.

    Run it on the instance while the blocking is happening, save the output,
    and paste it (or the file) into /sqlblocking-review.

    Run it twice, 30-60 seconds apart, when you can. Two captures separate a
    chain that is making progress from one that is stuck, and they are what
    BL7 (chronic head blocker) compares.

    Permissions: VIEW SERVER STATE (SQL Server 2019 and earlier) or
    VIEW SERVER PERFORMANCE STATE (SQL Server 2022 and later). On Azure SQL
    Database, sections 1-4 work with VIEW DATABASE STATE; section 5's
    sys.configurations query does not apply.
*/

SET NOCOUNT ON;
SELECT capture_time = SYSDATETIME(), server_name = @@SERVERNAME;

/* ------------------------------------------------------------------
   1. Blocking chain — level 0 rows are head blockers (BL1-BL8, BL12-BL15)
   ------------------------------------------------------------------ */
PRINT '--- 1. Blocking chain ---';
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
            req.estimated_completion_time,
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
            h.last_request_start_time, h.last_request_end_time,
            h.percent_complete, h.estimated_completion_time,
            h.[sql_handle], h.most_recent_sql_handle, [level] = 0
    FROM cteHead AS h
    WHERE (h.blocking_session_id IS NULL OR h.blocking_session_id = 0)
      AND h.session_id IN (SELECT DISTINCT blocking_session_id FROM cteHead WHERE blocking_session_id <> 0)
    UNION ALL
    SELECT  c.head_blocker_session_id, b.session_id, b.blocking_session_id,
            b.wait_type, b.wait_time, b.wait_resource, b.request_status, b.session_status,
            b.command, b.open_transaction_count, b.session_open_tran,
            b.transaction_isolation_level, b.host_name, b.program_name, b.login_name,
            b.last_request_start_time, b.last_request_end_time,
            b.percent_complete, b.estimated_completion_time,
            b.[sql_handle], b.most_recent_sql_handle, c.[level] + 1
    FROM cteHead AS b
    INNER JOIN cteChain AS c
            ON c.session_id = b.blocking_session_id
           AND c.session_id <> b.session_id   -- avoid infinite recursion on latch-type blocking
    WHERE c.wait_type COLLATE Latin1_General_BIN NOT IN ('EXCHANGE', 'CXPACKET') OR c.wait_type IS NULL
)
SELECT  c.[level], c.head_blocker_session_id, c.session_id, c.blocking_session_id,
        c.wait_type, c.wait_time, c.wait_resource,
        c.request_status, c.session_status, c.command,
        c.open_transaction_count, c.session_open_tran, c.transaction_isolation_level,
        c.host_name, c.program_name, c.login_name,
        c.last_request_start_time, c.last_request_end_time,
        c.percent_complete, c.estimated_completion_time,
        blocker_or_last_query = txt.text,
        input_buffer          = ib.event_info
FROM cteChain AS c
OUTER APPLY sys.dm_exec_sql_text (ISNULL(c.[sql_handle], c.most_recent_sql_handle)) AS txt
OUTER APPLY sys.dm_exec_input_buffer (c.session_id, NULL) AS ib
ORDER BY c.head_blocker_session_id, c.[level], c.session_id;

/* ------------------------------------------------------------------
   2. Open transactions with age (BL9, BL10, BL24, BL25, BL27)
   ------------------------------------------------------------------ */
PRINT '--- 2. Open transactions ---';
SELECT  tst.session_id,
        database_name          = DB_NAME(s.database_id),
        tat.transaction_begin_time,
        transaction_duration_s = DATEDIFF(SECOND, tat.transaction_begin_time, SYSDATETIME()),
        transaction_type       = CASE tat.transaction_type
                                     WHEN 1 THEN 'Read/write' WHEN 2 THEN 'Read-only'
                                     WHEN 3 THEN 'System'     WHEN 4 THEN 'Distributed' END,
        transaction_state      = tat.transaction_state,
        session_open_tran      = tst.open_transaction_count,
        tst.is_user_transaction, tst.is_local,
        request_status         = r.status,
        session_status         = s.status,
        idle_seconds           = DATEDIFF(SECOND, s.last_request_end_time, SYSDATETIME()),
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

/* ------------------------------------------------------------------
   3. Waiting tasks joined to the lock each one waits for
      (BL2, BL18-BL22)
   ------------------------------------------------------------------ */
PRINT '--- 3. Waiting tasks and their locks ---';
SELECT  wt.session_id, wt.exec_context_id, wt.wait_duration_ms, wt.wait_type,
        wt.blocking_session_id, wt.resource_description,
        tm.resource_type, tm.resource_subtype, tm.request_mode, tm.request_status,
        tm.resource_associated_entity_id,
        database_name = DB_NAME(tm.resource_database_id)
FROM sys.dm_tran_locks        AS tm
JOIN sys.dm_os_waiting_tasks  AS wt ON tm.lock_owner_address = wt.resource_address
ORDER BY wt.wait_duration_ms DESC;

/* ------------------------------------------------------------------
   4. Lock footprint per session (BL16, BL17, BL22, BL23)
   ------------------------------------------------------------------ */
PRINT '--- 4. Lock footprint ---';
SELECT  request_session_id,
        database_name   = DB_NAME(resource_database_id),
        resource_type, resource_subtype, request_mode, request_status,
        lock_count      = COUNT(*),
        sample_resource = MIN(resource_description),
        sample_entity   = MIN(resource_associated_entity_id)
FROM sys.dm_tran_locks
GROUP BY request_session_id, resource_database_id, resource_type, resource_subtype,
         request_mode, request_status
HAVING COUNT(*) > 0
ORDER BY lock_count DESC;

/* Object names for the top lock resources — run in the affected database.
   Replace the hobt id with a resource_associated_entity_id from section 3 or 4.

   SELECT OBJECT_NAME(object_id) AS table_name, index_id
   FROM sys.partitions
   WHERE hobt_id = <resource_associated_entity_id>;
*/

/* ------------------------------------------------------------------
   5. Observability and concurrency configuration (BL29-BL34, BL36)
   ------------------------------------------------------------------ */
PRINT '--- 5a. Blocked process threshold ---';
SELECT name, value_in_use
FROM sys.configurations
WHERE name = 'blocked process threshold (s)';

PRINT '--- 5b. Database concurrency options ---';
SELECT  name,
        snapshot_isolation_state_desc,
        is_read_committed_snapshot_on,
        is_accelerated_database_recovery_on,
        recovery_model_desc
FROM sys.databases
WHERE database_id > 4;

/* On SQL Server 2025, Azure SQL Database, and Azure SQL Managed Instance,
   sys.databases also exposes is_optimized_locking_on:

   SELECT name, is_optimized_locking_on FROM sys.databases WHERE database_id > 4;
*/

PRINT '--- 5c. Extended Events sessions capturing blocking ---';
SELECT  session_name = s.name, s.startup_state, event_name = e.name
FROM sys.server_event_sessions AS s
JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
WHERE e.name IN ('blocked_process_report', 'lock_escalation', 'xml_deadlock_report',
                 'attention', 'locking_stats');

PRINT '--- 5d. Lock escalation overrides ---';
DBCC TRACESTATUS(1211, 1224, -1);

/* Per-table escalation setting — run in the affected database:

   SELECT OBJECT_NAME(object_id) AS table_name, lock_escalation_desc
   FROM sys.tables
   WHERE lock_escalation_desc <> 'TABLE';
*/
