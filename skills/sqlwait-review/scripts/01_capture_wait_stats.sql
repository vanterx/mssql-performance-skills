/*
================================================================================
  skills/sqlwait-review/scripts/01_capture_wait_stats.sql
  Ad-Hoc Wait Statistics Capture for /sqlwait-review
================================================================================
  Run this script, then paste the result grids into Claude and run:
    /sqlwait-review

  This script produces three result sets:
    1. Top wait types (main input — required)
    2. Server configuration context (recommended — helps /sqlwait-review
       identify MAXDOP, memory, RCSI settings that explain wait patterns)
    3. Optional memory / resource semaphore / file I/O detail
       (uncomment the relevant sections for V37–V40 checks)

  For differential analysis (measures waits over a specific time window):
    Run Section A (before snapshot) → wait the desired interval → run Section B.
    The diff shows only what accumulated during that window, ignoring history.
================================================================================
*/

/* ============================================================================
   SECTION 1 — Cumulative Wait Statistics (since last SQL Server restart)
   Paste this output into /sqlwait-review
   ============================================================================ */

SELECT TOP 30
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms,
    CAST(100.0 * wait_time_ms
         / NULLIF(SUM(wait_time_ms) OVER (), 0) AS decimal(5,2))   AS pct_total,
    CAST(100.0 * signal_wait_time_ms
         / NULLIF(wait_time_ms, 0) AS decimal(5,2))                AS pct_signal  /* CPU queue pressure */
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    /* Benign background / idle waits — community exclusion list */
    'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP',
    'BROKER_TO_FLUSH','BROKER_TRANSMITTER',
    'CHECKPOINT_QUEUE','CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE',
    'DBMIRROR_DBM_EVENT','DBMIRROR_DBM_MUTEX','DBMIRROR_EVENTS_QUEUE',
    'DBMIRROR_WORKER_QUEUE','DBMIRRORING_CMD',
    'DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE','EXECSYNC','FSAGENT',
    'FT_IFTS_SCHEDULER_IDLE_WAIT','FT_IFTSHC_MUTEX',
    'HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'HADR_LOGCAPTURE_WAIT','HADR_NOTIFICATION_DEQUEUE','HADR_TIMER_TASK',
    'HADR_WORK_QUEUE','KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE',
    'MEMORY_ALLOCATION_EXT','ONDEMAND_TASK_QUEUE',
    'PARALLEL_REDO_DRAIN_WORKER','PARALLEL_REDO_LOG_CACHE',
    'PARALLEL_REDO_TRAN_LIST','PARALLEL_REDO_WORKER_SYNC',
    'PARALLEL_REDO_WORKER_WAIT_WORK',
    'PREEMPTIVE_OS_FLUSHFILEBUFFERS','PREEMPTIVE_SP_SERVER_DIAGNOSTICS',
    'PREEMPTIVE_XE_GETTARGETSTATE','PVS_PREALLOCATE',
    'PWAIT_ALL_COMPONENTS_INITIALIZED','PWAIT_DIRECTLOGCONSUMER_GETNEXT',
    'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_SHUTDOWN_QUEUE',
    'REDO_THREAD_PENDING_WORK','REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK','SLEEP_BPOOL_FLUSH','SLEEP_DBSTARTUP','SLEEP_DBTASK',
    'SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TASK',
    'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SOS_WORK_DISPATCHER',
    'SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_BUFFER_FLUSH',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP','SQLTRACE_WAIT_ENTRIES',
    'WAITFOR','WAITFOR_PF_FLUSH_COMPLETE','WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
    'XE_DISPATCHER_JOIN','XE_DISPATCHER_WAIT','XE_TIMER_EVENT'
)
  AND wait_time_ms > 0
ORDER BY wait_time_ms DESC;

/* ============================================================================
   SECTION 2 — Server Configuration Context
   Paste with Section 1 to enable V-checks that reference server settings
   ============================================================================ */

SELECT
    configuration_name         = name,
    value_in_use               = CAST(value_in_use AS int),
    description
FROM sys.configurations
WHERE name IN (
    'max degree of parallelism',
    'cost threshold for parallelism',
    'max server memory (MB)',
    'min server memory (MB)',
    'optimize for ad hoc workloads',
    'max worker threads',
    'xp_cmdshell',
    'clr enabled',
    'lightweight pooling',
    'blocked process threshold (s)',
    'query governor cost limit',
    'priority boost',
    'remote access',
    'Ole Automation Procedures',
    'Database Mail XPs'
)
ORDER BY name;

/* Also include TempDB file count and RCSI status */
SELECT
    tempdb_file_count = (SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type = 0),
    logical_cpu_count = (SELECT cpu_count FROM sys.dm_os_sys_info),
    sql_server_start  = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
    hours_since_start = DATEDIFF(HOUR,
                            (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
                            SYSDATETIME());

SELECT
    database_name     = name,
    is_rcsi_on        = is_read_committed_snapshot_on,
    recovery_model    = recovery_model_desc,
    delayed_durability = delayed_durability_desc,
    state             = state_desc
FROM sys.databases
WHERE database_id > 4   /* user databases only */
ORDER BY name;


/* ============================================================================
   SECTION 3A — Optional: Resource Semaphore (memory grant pressure)
   Uncomment to feed V37 (forced memory grants) and V38 (grant timeouts)
   ============================================================================ */
/*
SELECT
    resource_semaphore_id,
    target_memory_kb,
    max_target_memory_kb,
    total_memory_kb,
    available_memory_kb,
    granted_memory_kb,
    used_memory_kb,
    grantee_count,
    waiter_count,
    forced_grant_count,        -- > 0 signals memory pressure forcing grants
    timeout_error_count
FROM sys.dm_exec_query_resource_semaphores
ORDER BY resource_semaphore_id;
*/

/* ============================================================================
   SECTION 3B — Optional: Memory Clerks by category
   Uncomment to feed V39 (stolen memory) and V40 (memory clerk detail)
   ============================================================================ */
/*
SELECT
    clerk_type      = type,
    clerk_name      = name,
    pages_kb        = SUM(pages_kb),
    virtual_memory_reserved_kb  = SUM(virtual_memory_reserved_kb),
    virtual_memory_committed_kb = SUM(virtual_memory_committed_kb)
FROM sys.dm_os_memory_clerks
WHERE pages_kb > 0
GROUP BY type, name
ORDER BY pages_kb DESC;
*/

/* ============================================================================
   SECTION 3C — Optional: File I/O Latency
   Uncomment to feed V40 (file I/O latency checks)
   ============================================================================ */
/*
SELECT
    database_name      = DB_NAME(fs.database_id),
    file_name          = mf.name,
    file_type          = mf.type_desc,
    physical_name      = mf.physical_name,
    num_of_reads       = fs.num_of_reads,
    num_of_writes      = fs.num_of_writes,
    io_stall_read_ms   = fs.io_stall_read_ms,
    io_stall_write_ms  = fs.io_stall_write_ms,
    avg_read_latency_ms  = CASE WHEN fs.num_of_reads  = 0 THEN 0
                                ELSE fs.io_stall_read_ms  / fs.num_of_reads  END,
    avg_write_latency_ms = CASE WHEN fs.num_of_writes = 0 THEN 0
                                ELSE fs.io_stall_write_ms / fs.num_of_writes END,
    size_on_disk_gb    = CAST(fs.size_on_disk_bytes / 1073741824. AS decimal(10,2))
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS fs
LEFT JOIN sys.master_files mf
  ON  mf.database_id = fs.database_id
  AND mf.file_id     = fs.file_id
ORDER BY (fs.io_stall_read_ms + fs.io_stall_write_ms) DESC;
*/


/* ============================================================================
   DIFFERENTIAL CAPTURE — measures waits over a specific time window
   Use this instead of Section 1 when you want "last 60 seconds" rather than
   "since SQL Server started". Useful for reproducing a specific problem.

   Instructions:
     Step 1: Run the BEFORE block below
     Step 2: Reproduce the issue or wait the desired interval
     Step 3: Run the AFTER block below
     Step 4: Paste the AFTER output into /sqlwait-review
   ============================================================================ */

/* STEP 1 — run this first */
/*
IF OBJECT_ID('tempdb..#waits_before') IS NOT NULL DROP TABLE #waits_before;

SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
INTO #waits_before
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ( ... same exclusion list as Section 1 ... )
  AND wait_time_ms > 0;

PRINT 'Before snapshot taken. Reproduce the issue, then run Step 2.';
*/

/* STEP 2 — run after the observation window */
/*
SELECT TOP 30
    a.wait_type,
    waiting_tasks_count_delta  = b.waiting_tasks_count - a.waiting_tasks_count,
    wait_time_ms_delta         = b.wait_time_ms        - a.wait_time_ms,
    signal_wait_time_ms_delta  = b.signal_wait_time_ms - a.signal_wait_time_ms,
    pct_of_period = CAST(100.0 * (b.wait_time_ms - a.wait_time_ms)
                    / NULLIF(SUM(b.wait_time_ms - a.wait_time_ms) OVER (), 0)
                    AS decimal(5,2)),
    pct_signal    = CAST(100.0 * (b.signal_wait_time_ms - a.signal_wait_time_ms)
                    / NULLIF(b.wait_time_ms - a.wait_time_ms, 0)
                    AS decimal(5,2))
FROM #waits_before a
JOIN sys.dm_os_wait_stats b ON b.wait_type = a.wait_type
WHERE b.wait_time_ms > a.wait_time_ms
ORDER BY wait_time_ms_delta DESC;
*/
