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
    WHERE (c.wait_type COLLATE Latin1_General_BIN NOT IN ('EXCHANGE', 'CXPACKET')
           OR c.wait_type IS NULL)
      /* Depth cap: a self-pair guard alone does not stop a longer cycle
         (A blocks B blocks A), which would otherwise hit the 100-level
         recursion limit and fail the whole batch with error 530. No real
         chain is 32 deep; if output reaches level 31, suspect a cycle. */
      AND c.[level] < 32
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
WHERE request_session_id <> @@SPID   -- exclude this capture session
GROUP BY request_session_id, resource_database_id, resource_type, resource_subtype,
         request_mode, request_status
HAVING COUNT(*) > 0
ORDER BY lock_count DESC;

/* ------------------------------------------------------------------
   4b. How much of the current lock wait RCSI would remove (BL29)
   ------------------------------------------------------------------ */
PRINT '--- 4b. RCSI-addressable share of current lock waits ---';
/* RCSI removes reader-blocked-by-writer contention and nothing else, so the
   decision needs the reader share of lock wait, not just "readers are
   blocked". Writer-on-writer waits survive RCSI (BL24 shortens them
   instead); schema, bulk-update and mixed intent modes belong to neither
   side and are excluded from the ratio rather than counted against it.
   Mode classification follows /sqlblocking-review BL29. */
WITH waiting_locks AS (
    SELECT  wt.session_id,
            wt.wait_duration_ms,
            tm.request_mode,
            lock_class =
                CASE
                    WHEN tm.request_mode IN ('Sch-S', 'Sch-M', 'BU', 'IU', 'SIU', 'SIX')
                        THEN 'EXCLUDED'
                    WHEN tm.request_mode IN ('S', 'IS')
                      OR tm.request_mode LIKE 'RangeS%'
                        THEN 'READER'
                    WHEN tm.request_mode IN ('X', 'IX', 'U', 'UIX')
                      OR tm.request_mode LIKE 'RangeX%'
                      OR tm.request_mode LIKE 'RangeI%'
                        THEN 'WRITER'
                    ELSE 'EXCLUDED'
                END
    FROM sys.dm_tran_locks       AS tm
    JOIN sys.dm_os_waiting_tasks AS wt
      ON tm.lock_owner_address = wt.resource_address
    WHERE tm.request_status = 'WAIT'
)
SELECT  lock_class,
        request_mode,
        waiters = COUNT(*),
        wait_ms = SUM(wait_duration_ms),
        /* Same value on every row: the share of reader+writer lock wait that
           row versioning would remove. EXCLUDED modes are in neither term. */
        rcsi_addressable_pct = CONVERT(decimal(5,2),
            100.0 * SUM(SUM(CASE WHEN lock_class = 'READER'
                                 THEN wait_duration_ms ELSE 0 END)) OVER ()
            / NULLIF(SUM(SUM(CASE WHEN lock_class IN ('READER', 'WRITER')
                                  THEN wait_duration_ms ELSE 0 END)) OVER (), 0))
FROM waiting_locks
GROUP BY lock_class, request_mode
ORDER BY wait_ms DESC;

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
        -- NULL where optimized locking is not available (before SQL Server 2025)
        is_optimized_locking_on = DATABASEPROPERTYEX(name, 'IsOptimizedLockingOn'),
        recovery_model_desc
FROM sys.databases
WHERE database_id > 4;

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

/* ------------------------------------------------------------------
   6. Historical evidence — works after the blocking has cleared
      (BL37-BL42). Run sections 6a and 6b in the affected database.
   ------------------------------------------------------------------ */
PRINT '--- 6a. Lock wait hot spots per index ---';
SELECT  table_name = OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id),
        index_name = ISNULL(i.name, '(heap)'),
        i.index_id,
        os.partition_number,
        os.row_lock_wait_count,
        os.row_lock_wait_in_ms,
        os.page_lock_wait_count,
        os.page_lock_wait_in_ms,
        total_lock_wait_ms   = os.row_lock_wait_in_ms + os.page_lock_wait_in_ms,
        avg_row_lock_wait_ms = os.row_lock_wait_in_ms  / NULLIF(os.row_lock_wait_count, 0),
        avg_page_lock_wait_ms= os.page_lock_wait_in_ms / NULLIF(os.page_lock_wait_count, 0),
        os.index_lock_promotion_attempt_count,
        os.index_lock_promotion_count
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i
  ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE os.row_lock_wait_in_ms + os.page_lock_wait_in_ms > 0
   OR os.index_lock_promotion_attempt_count > 0   -- escalations block at OBJECT level, not row/page
ORDER BY total_lock_wait_ms DESC, os.index_lock_promotion_attempt_count DESC;

/* Counters are cumulative since the index's metadata entered the cache and
   reset when it is evicted or the object is rebuilt. Only row and page lock
   waits are counted — OBJECT, METADATA and APPLICATION lock waits are not,
   so a table that escalated appears through its promotion counts (BL39)
   even when its wait columns are zero. A wait is recorded when it ends:
   during a live incident the blocked waits are not yet in these columns. */

PRINT '--- 6b. Query Store lock wait history (SQL Server 2017+, Azure SQL) ---';
/* Capture mode first: under AUTO (the default from SQL Server 2019) a query
   is stored only after 30 executions, 1 s of compile CPU, or 100 ms of
   execution CPU. A blocked query waits without using CPU, so occasional
   blocking victims are often never captured — an empty result below is not
   proof that no lock waits happened. */
SELECT  query_capture_mode_desc, wait_stats_capture_mode_desc, actual_state_desc
FROM sys.database_query_store_options;

/* Both views can hold several rows per plan, interval, and execution type
   (flushed plus in-memory), so aggregate each on that key before joining. */
WITH lock_waits AS (
    SELECT  plan_id, runtime_stats_interval_id, execution_type,
            lock_wait_ms = SUM(total_query_wait_time_ms)
    FROM sys.query_store_wait_stats
    WHERE wait_category_desc = 'Lock'
    GROUP BY plan_id, runtime_stats_interval_id, execution_type
),
runs AS (
    SELECT  plan_id, runtime_stats_interval_id, execution_type,
            executions = SUM(count_executions)
    FROM sys.query_store_runtime_stats
    GROUP BY plan_id, runtime_stats_interval_id, execution_type
)
SELECT TOP (25)
        qsq.query_id,
        qsp.plan_id,
        total_lock_wait_ms = SUM(lw.lock_wait_ms),
        executions         = SUM(r.executions),
        avg_lock_wait_ms   = SUM(lw.lock_wait_ms) * 1.0 / NULLIF(SUM(r.executions), 0),
        query_sql_text     = MIN(qst.query_sql_text)
FROM lock_waits AS lw
LEFT JOIN runs AS r
       ON r.plan_id                   = lw.plan_id
      AND r.runtime_stats_interval_id = lw.runtime_stats_interval_id
      AND r.execution_type            = lw.execution_type
JOIN sys.query_store_plan       AS qsp ON qsp.plan_id       = lw.plan_id
JOIN sys.query_store_query      AS qsq ON qsq.query_id      = qsp.query_id
JOIN sys.query_store_query_text AS qst ON qst.query_text_id = qsq.query_text_id
GROUP BY qsq.query_id, qsp.plan_id
ORDER BY total_lock_wait_ms DESC;

PRINT '--- 6c. Blocking performance counters (sample twice for a rate) ---';
SELECT  object_name   = RTRIM(object_name),
        counter_name  = RTRIM(counter_name),
        instance_name = RTRIM(instance_name),
        cntr_value, cntr_type
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE '%General Statistics%' AND counter_name = 'Processes blocked')
   OR (object_name LIKE '%Locks%' AND counter_name IN
        ('Lock Waits/sec', 'Lock Wait Time (ms)', 'Lock Timeouts/sec',
         'Number of Deadlocks/sec', 'Average Wait Time (ms)'));

PRINT '--- 6d. Instance-wide lock wait share (BL37) ---';
/* The share is only meaningful once idle and background waits are removed:
   left in, waits such as SOS_WORK_DISPATCHER and LOGMGR_QUEUE dominate the
   denominator and push a real lock problem down into the Info band. The
   list below matches /sqlwait-review's capture script. Microsoft Learn
   documents many of these only as "Internal use only" —
   PWAIT_EXTENSIBILITY_CLEANUP_TASK is not documented at all, and is excluded
   because it accrues with uptime on an idle instance (observed on SQL Server
   2025, where it reached over 90% of non-idle wait time).
   RESOURCE_SEMAPHORE_MUTEX and WAIT_FOR_RESULTS are commonly excluded
   elsewhere and are deliberately kept in scope: the first sits next to
   memory-grant pressure, the second can be a real client-side stall. */
SELECT TOP (15)
        wait_type,
        wait_time_ms,
        waiting_tasks_count,
        pct_of_total = CONVERT(decimal(5,2),
            100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0)),
        lck_m_share_pct = CONVERT(decimal(5,2),
            100.0 * SUM(CASE WHEN wait_type LIKE 'LCK[_]M[_]%' THEN wait_time_ms ELSE 0 END) OVER ()
                  / NULLIF(SUM(wait_time_ms) OVER (), 0))   -- BL37 compares this column
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0
  AND wait_type NOT IN (
    'AZURE_IMDS_VERSIONS', 'BMPALLOCATION', 'BMPBUILD', 'BMPREPARTITION',
    'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP',
    'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER', 'BUFFERPOOL_SCAN',
    'CHECKPOINT_QUEUE', 'CHKPT', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT',
    'CLR_SEMAPHORE', 'COLUMNSTORE_BUILD_THROTTLE', 'DAC_INIT',
    'DBMIRRORING_CMD', 'DBMIRROR_DBM_EVENT', 'DBMIRROR_DBM_MUTEX',
    'DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_WORKER_QUEUE', 'DIRTY_PAGE_POLL',
    'DIRTY_PAGE_TABLE_LOCK', 'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC',
    'FSAGENT', 'FT_IFTSHC_MUTEX', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_CLUSAPI_CALL', 'HADR_FABRIC_CALLBACK',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR_LOGCAPTURE_WAIT',
    'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE',
    'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE',
    'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE',
    'PARALLEL_REDO_DRAIN_WORKER', 'PARALLEL_REDO_FLOW_CONTROL',
    'PARALLEL_REDO_LOG_CACHE', 'PARALLEL_REDO_TRAN_LIST',
    'PARALLEL_REDO_TRAN_TURN', 'PARALLEL_REDO_WORKER_SYNC',
    'PARALLEL_REDO_WORKER_WAIT_WORK', 'PERFORMANCE_COUNTERS_RWLOCK',
    'POPULATE_LOCK_ORDINALS', 'PREEMPTIVE_HADR_LEASE_MECHANISM',
    'PREEMPTIVE_OS_FLUSHFILEBUFFERS', 'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',
    'PREEMPTIVE_XE_CALLBACKEXECUTE', 'PREEMPTIVE_XE_DISPATCHER',
    'PREEMPTIVE_XE_GETTARGETSTATE', 'PREEMPTIVE_XE_SESSIONCOMMIT',
    'PREEMPTIVE_XE_TARGETFINALIZE', 'PREEMPTIVE_XE_TARGETINIT',
    'PRINT_ROLLBACK_PROGRESS', 'PURVIEW_POLICY_SDK_PREEMPTIVE_SCHEDULING',
    'PVS_PREALLOCATE', 'PWAIT_ALL_COMPONENTS_INITIALIZED',
    'PWAIT_DIRECTLOGCONSUMER_GETNEXT', 'PWAIT_EXTENSIBILITY_CLEANUP_TASK',
    'PWAIT_HADRSIM', 'PWAIT_HADR_ACTION_COMPLETED',
    'PWAIT_HADR_CHANGE_NOTIFIER_TERMINATION_SYNC',
    'PWAIT_HADR_CLUSTER_INTEGRATION', 'PWAIT_HADR_FAILOVER_COMPLETED',
    'PWAIT_HADR_JOIN', 'PWAIT_HADR_OFFLINE_COMPLETED',
    'PWAIT_HADR_ONLINE_COMPLETED', 'PWAIT_HADR_POST_ONLINE_COMPLETED',
    'PWAIT_HADR_SERVER_READY_CONNECTIONS', 'PWAIT_HADR_WORKITEM_COMPLETED',
    'PWAIT_MASTERDBREADY', 'QDS_ASYNC_QUEUE',
    'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_SHUTDOWN_QUEUE',
    'QUERY_EXECUTION_INDEX_SORT_EVENT_OPEN', 'QUERY_TASK_ENQUEUE_MUTEX',
    'REDO_THREAD_PENDING_WORK', 'REQUEST_FOR_DEADLOCK_SEARCH',
    'RESOURCE_QUEUE', 'SECURITY_CNG_PROVIDER_MUTEX', 'SERVER_IDLE_CHECK',
    'SLEEP_BPOOL_FLUSH', 'SLEEP_BUFFERPOOL_HELPLW', 'SLEEP_DBSTARTUP',
    'SLEEP_DBTASK', 'SLEEP_DCOMSTARTUP', 'SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP',
    'SLEEP_PHYSMASTERDBREADY', 'SLEEP_SYSTEMTASK', 'SLEEP_TASK',
    'SLEEP_TEMPDBSTARTUP', 'SNI_CRITICAL_SECTION', 'SNI_HTTP_ACCEPT',
    'SOS_PROCESS_AFFINITY_MUTEX', 'SOS_WORK_DISPATCHER',
    'SP_SERVER_DIAGNOSTICS_SLEEP', 'SQLTRACE_BUFFER_FLUSH',
    'SQLTRACE_FILE_BUFFER', 'SQLTRACE_FILE_READ_IO_COMPLETION',
    'SQLTRACE_FILE_WRITE_IO_COMPLETION', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'SQLTRACE_WAIT_ENTRIES', 'UCS_SESSION_REGISTRATION', 'VDI_CLIENT_OTHER',
    'WAITFOR', 'WAITFOR_PF_FLUSH_COMPLETE', 'WAITFOR_TASKSHUTDOWN',
    'WAIT_XTP_CKPT_CLOSE', 'WAIT_XTP_HOST_WAIT',
    'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 'WAIT_XTP_RECOVERY',
    'WINDOW_AGGREGATES_MULTIPASS', 'XE_BUFFERMGR_ALLPROCESSED_EVENT',
    'XE_DISPATCHER_JOIN', 'XE_DISPATCHER_WAIT', 'XE_FILE_TARGET_TVF',
    'XE_LIVE_TARGET_TVF', 'XE_TIMER_EVENT')
ORDER BY wait_time_ms DESC;
