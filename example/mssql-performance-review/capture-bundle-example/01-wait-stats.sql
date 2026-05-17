-- 01-wait-stats.sql
-- Source: skills/sqlwait-review/scripts/01_capture_wait_stats.sql
-- Purpose: Confirm bottleneck class (CPU vs I/O vs lock vs memory vs compilation)
-- Read-only. SELECT against sys.dm_os_wait_stats only.

SET NOCOUNT ON;

SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS DECIMAL(5,2)) AS pct_total
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP',
    'BROKER_TO_FLUSH','BROKER_TRANSMITTER',
    'CHECKPOINT_QUEUE','CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE',
    'DBMIRROR_DBM_EVENT','DBMIRROR_DBM_MUTEX','DBMIRROR_EVENTS_QUEUE',
    'DBMIRROR_WORKER_QUEUE','DBMIRRORING_CMD',
    'HADR_CLUSAPI_CALL','HADR_FABRIC_CALLBACK','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'HADR_LOGCAPTURE_WAIT','HADR_NOTIFICATION_DEQUEUE','HADR_TIMER_TASK',
    'HADR_WORK_QUEUE',
    'DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE',
    'EXECSYNC','FSAGENT',
    'FT_IFTS_SCHEDULER_IDLE_WAIT','FT_IFTSHC_MUTEX',
    'KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE',
    'MEMORY_ALLOCATION_EXT',
    'ONDEMAND_TASK_QUEUE',
    'PREEMPTIVE_HADR_LEASE_MECHANISM','PREEMPTIVE_OS_FLUSHFILEBUFFERS',
    'PREEMPTIVE_SP_SERVER_DIAGNOSTICS','PREEMPTIVE_XE_GETTARGETSTATE',
    'PWAIT_ALL_COMPONENTS_INITIALIZED','PWAIT_DIRECTLOGCONSUMER_GETNEXT',
    'PWAIT_EXTENSIBILITY_CLEANUP_TASK',
    'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE',
    'REDO_THREAD_PENDING_WORK',
    'REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK','SLEEP_BPOOL_FLUSH',
    'SLEEP_DBSTARTUP','SLEEP_DBTASK','SLEEP_DCOMSTARTUP',
    'SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY','SLEEP_MASTERUPGRADED',
    'SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TASK','SLEEP_TEMPDBSTARTUP',
    'SNI_HTTP_ACCEPT','SOS_WORK_DISPATCHER',
    'SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'UCS_SESSION_REGISTRATION','VDI_CLIENT_OTHER',
    'WAIT_FOR_RESULTS','WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
    'WAITFOR','WAITFOR_TASKSHUTDOWN',
    'XE_DISPATCHER_WAIT','XE_LIVE_TARGET_TVF','XE_TIMER_EVENT'
)
ORDER BY wait_time_ms DESC;

-- Optional: current active session waits for point-in-time picture
-- (uncomment to also capture this if the cumulative window is too long)
/*
SELECT
    r.session_id,
    r.wait_type,
    r.wait_time / 1000.0 AS wait_sec,
    r.blocking_session_id,
    r.status,
    DB_NAME(r.database_id) AS database_name,
    SUBSTRING(t.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1) AS current_statement
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
ORDER BY r.wait_time DESC;
*/
