/*
================================================================================
  06_usp_collect_wait_stats.sql
  Collection Framework — Wait Statistics Collector
================================================================================
  Creates: collect.wait_stats (table)
           collect.usp_CollectWaitStats (stored procedure)

  Source DMV:  sys.dm_os_wait_stats
  Natural key: wait_type
  Delta type:  Cumulative — deltas calculated immediately after insert

  Captures cumulative wait stats and computes interval deltas.
  Excludes benign background waits (same exclusion list as sqlwait-review skill).
  Feed report output into: /sqlwait-review

  Capture for analysis:
    SELECT wait_type, wait_time_ms_delta, waiting_tasks_count_delta,
           wait_time_ms_per_second, signal_wait_time_ms_delta, sample_seconds
    FROM collect.wait_stats
    WHERE collection_time = (SELECT MAX(collection_time) FROM collect.wait_stats
                              WHERE sample_seconds IS NOT NULL)
    ORDER BY wait_time_ms_delta DESC;
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ── Table ──────────────────────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.wait_stats', N'U') IS NULL
BEGIN
    CREATE TABLE collect.wait_stats
    (
        collection_id            bigint        NOT NULL IDENTITY,
        collection_time          datetime2(7)  NOT NULL DEFAULT SYSDATETIME(),
        server_start_time        datetime2(7)  NOT NULL,
        wait_type                nvarchar(60)  NOT NULL,
        /* Cumulative raw values */
        waiting_tasks_count      bigint        NOT NULL,
        wait_time_ms             bigint        NOT NULL,
        max_wait_time_ms         bigint        NOT NULL,
        signal_wait_time_ms      bigint        NOT NULL,
        /* Delta columns (NULL until SP runs) */
        waiting_tasks_count_delta bigint       NULL,
        wait_time_ms_delta        bigint       NULL,
        signal_wait_time_ms_delta bigint       NULL,
        sample_seconds            int          NULL,
        /* Computed helpers */
        wait_time_ms_per_second   AS (wait_time_ms_delta   / NULLIF(sample_seconds, 0)),
        signal_wait_ms_per_second AS (signal_wait_time_ms_delta / NULLIF(sample_seconds, 0)),
        CONSTRAINT PK_wait_stats
            PRIMARY KEY CLUSTERED (collection_time, collection_id)
            WITH (DATA_COMPRESSION = PAGE)
    );

    CREATE NONCLUSTERED INDEX IX_wait_stats_natural_key
    ON collect.wait_stats (wait_type, collection_time)
    INCLUDE (waiting_tasks_count, wait_time_ms, signal_wait_time_ms,
             server_start_time, waiting_tasks_count_delta)
    WITH (DATA_COMPRESSION = PAGE);

    PRINT 'collect.wait_stats created.';
END
ELSE
    PRINT 'collect.wait_stats already exists — skipping DDL.';
GO

/* ── Benign wait exclusion table (if not already seeded) ───────────────── */

IF OBJECT_ID(N'collect.ignored_wait_types', N'U') IS NULL
BEGIN
    CREATE TABLE collect.ignored_wait_types
    (
        wait_type   nvarchar(60) NOT NULL CONSTRAINT PK_ignored_wait_types PRIMARY KEY,
        reason      nvarchar(200) NULL
    );

    /* Community benign exclusion list */
    INSERT collect.ignored_wait_types (wait_type, reason) VALUES
        ('BROKER_EVENTHANDLER',         'Service Broker idle'),
        ('BROKER_RECEIVE_WAITFOR',      'Service Broker idle'),
        ('BROKER_TASK_STOP',            'Service Broker idle'),
        ('BROKER_TO_FLUSH',             'Service Broker idle'),
        ('BROKER_TRANSMITTER',          'Service Broker idle'),
        ('CHECKPOINT_QUEUE',            'Checkpoint idle'),
        ('CHKPT',                       'Checkpoint idle'),
        ('CLR_AUTO_EVENT',              'CLR idle'),
        ('CLR_MANUAL_EVENT',            'CLR idle'),
        ('CLR_SEMAPHORE',               'CLR idle'),
        ('DBMIRROR_DBM_EVENT',          'Mirroring idle'),
        ('DBMIRROR_DBM_MUTEX',          'Mirroring idle'),
        ('DBMIRROR_EVENTS_QUEUE',       'Mirroring idle'),
        ('DBMIRROR_WORKER_QUEUE',       'Mirroring idle'),
        ('DBMIRRORING_CMD',             'Mirroring idle'),
        ('DIRTY_PAGE_POLL',             'Background idle'),
        ('DISPATCHER_QUEUE_SEMAPHORE',  'Background idle'),
        ('EXECSYNC',                    'Background idle'),
        ('FSAGENT',                     'Background idle'),
        ('FT_IFTS_SCHEDULER_IDLE_WAIT', 'Full-text idle'),
        ('FT_IFTSHC_MUTEX',             'Full-text idle'),
        ('HADR_CLUSAPI_CALL',           'HADR idle'),
        ('HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR idle'),
        ('HADR_LOGCAPTURE_WAIT',        'HADR idle'),
        ('HADR_NOTIFICATION_DEQUEUE',   'HADR idle'),
        ('HADR_TIMER_TASK',             'HADR idle'),
        ('HADR_WORK_QUEUE',             'HADR idle'),
        ('KSOURCE_WAKEUP',              'Background idle'),
        ('LAZYWRITER_SLEEP',            'Lazy writer idle'),
        ('LOGMGR_QUEUE',                'Log manager idle'),
        ('MEMORY_ALLOCATION_EXT',       'Background idle'),
        ('ONDEMAND_TASK_QUEUE',         'Background idle'),
        ('PARALLEL_REDO_DRAIN_WORKER',  'Parallel redo idle'),
        ('PARALLEL_REDO_LOG_CACHE',     'Parallel redo idle'),
        ('PARALLEL_REDO_TRAN_LIST',     'Parallel redo idle'),
        ('PARALLEL_REDO_WORKER_SYNC',   'Parallel redo idle'),
        ('PARALLEL_REDO_WORKER_WAIT_WORK', 'Parallel redo idle'),
        ('PREEMPTIVE_OS_FLUSHFILEBUFFERS', 'OS idle'),
        ('PREEMPTIVE_SP_SERVER_DIAGNOSTICS', 'Diagnostics idle'),
        ('PREEMPTIVE_XE_GETTARGETSTATE', 'XE idle'),
        ('PVS_PREALLOCATE',             'Background idle'),
        ('PWAIT_ALL_COMPONENTS_INITIALIZED', 'Startup idle'),
        ('PWAIT_DIRECTLOGCONSUMER_GETNEXT', 'Background idle'),
        ('QDS_ASYNC_QUEUE',             'Query Store idle'),
        ('QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', 'Query Store idle'),
        ('QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'Query Store idle'),
        ('QDS_SHUTDOWN_QUEUE',          'Query Store idle'),
        ('REDO_THREAD_PENDING_WORK',    'Redo idle'),
        ('REQUEST_FOR_DEADLOCK_SEARCH', 'Deadlock monitor idle'),
        ('RESOURCE_QUEUE',              'Background idle'),
        ('SERVER_IDLE_CHECK',           'Server idle'),
        ('SLEEP_BPOOL_FLUSH',           'Background idle'),
        ('SLEEP_DBSTARTUP',             'Startup idle'),
        ('SLEEP_DBTASK',                'Background idle'),
        ('SLEEP_DCOMSTARTUP',           'Startup idle'),
        ('SLEEP_MASTERDBREADY',         'Startup idle'),
        ('SLEEP_MASTERMDREADY',         'Startup idle'),
        ('SLEEP_MASTERUPGRADED',        'Startup idle'),
        ('SLEEP_MSDBSTARTUP',           'Startup idle'),
        ('SLEEP_SYSTEMTASK',            'Background idle'),
        ('SLEEP_TASK',                  'Background idle'),
        ('SLEEP_TEMPDBSTARTUP',         'Startup idle'),
        ('SNI_HTTP_ACCEPT',             'Network idle'),
        ('SOS_WORK_DISPATCHER',         'Background idle'),
        ('SP_SERVER_DIAGNOSTICS_SLEEP', 'Diagnostics idle'),
        ('SQLTRACE_BUFFER_FLUSH',       'Trace idle'),
        ('SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'Trace idle'),
        ('WAITFOR',                     'Application WAITFOR'),
        ('WAITFOR_PF_FLUSH_COMPLETE',   'Background idle'),
        ('WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 'In-Memory OLTP idle'),
        ('XE_DISPATCHER_WAIT',          'XE idle'),
        ('XE_TIMER_EVENT',              'XE idle'),
        ('XE_DISPATCHER_JOIN',          'XE idle'),
        ('SQLTRACE_WAIT_ENTRIES',       'Trace idle');

    PRINT 'collect.ignored_wait_types created and seeded.';
END
GO

/* ── Collector ──────────────────────────────────────────────────────────── */

CREATE OR ALTER PROCEDURE collect.usp_CollectWaitStats
    @debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @start_time    datetime2(7) = SYSDATETIME(),
        @server_start  datetime2(7) = (SELECT CAST(sqlserver_start_time AS datetime2(7))
                                       FROM   sys.dm_os_sys_info),
        @rows_inserted int = 0;

    BEGIN TRY

        /* ── Step 1: Insert current snapshot ───────────────────────────── */

        INSERT collect.wait_stats
            (server_start_time, wait_type,
             waiting_tasks_count, wait_time_ms, max_wait_time_ms, signal_wait_time_ms)
        SELECT
            @server_start,
            ws.wait_type,
            ws.waiting_tasks_count,
            ws.wait_time_ms,
            ws.max_wait_time_ms,
            ws.signal_wait_time_ms
        FROM sys.dm_os_wait_stats ws
        WHERE ws.wait_time_ms > 0
          AND NOT EXISTS (
              SELECT 1 FROM collect.ignored_wait_types iwt
              WHERE iwt.wait_type = ws.wait_type)
        OPTION (RECOMPILE);

        SET @rows_inserted = ROWCOUNT_BIG();

        /* ── Step 2: Calculate deltas ───────────────────────────────────── */

        WITH current_snap AS
        (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY wait_type ORDER BY collection_time DESC) AS rn
            FROM collect.wait_stats
            WHERE waiting_tasks_count_delta IS NULL
        ),
        prev_snap AS
        (
            SELECT collection_id, wait_type, collection_time, server_start_time,
                   waiting_tasks_count, wait_time_ms, signal_wait_time_ms,
                   ROW_NUMBER() OVER (PARTITION BY wait_type ORDER BY collection_time DESC) AS rn
            FROM collect.wait_stats
            WHERE waiting_tasks_count_delta IS NOT NULL
        )
        UPDATE c
        SET
            sample_seconds =
                CASE WHEN p.collection_id IS NULL
                     THEN NULL
                     ELSE DATEDIFF(SECOND, p.collection_time, c.collection_time)
                END,
            waiting_tasks_count_delta =
                CASE WHEN p.collection_id IS NULL             THEN c.waiting_tasks_count
                     WHEN c.server_start_time >= p.collection_time THEN c.waiting_tasks_count
                     WHEN c.waiting_tasks_count >= p.waiting_tasks_count
                     THEN c.waiting_tasks_count - p.waiting_tasks_count
                     ELSE c.waiting_tasks_count
                END,
            wait_time_ms_delta =
                CASE WHEN p.collection_id IS NULL             THEN c.wait_time_ms
                     WHEN c.server_start_time >= p.collection_time THEN c.wait_time_ms
                     WHEN c.wait_time_ms >= p.wait_time_ms    THEN c.wait_time_ms - p.wait_time_ms
                     ELSE c.wait_time_ms
                END,
            signal_wait_time_ms_delta =
                CASE WHEN p.collection_id IS NULL             THEN c.signal_wait_time_ms
                     WHEN c.server_start_time >= p.collection_time THEN c.signal_wait_time_ms
                     WHEN c.signal_wait_time_ms >= p.signal_wait_time_ms
                     THEN c.signal_wait_time_ms - p.signal_wait_time_ms
                     ELSE c.signal_wait_time_ms
                END
        FROM current_snap c
        LEFT JOIN prev_snap p
          ON  p.wait_type = c.wait_type
          AND p.rn        = 1
        WHERE c.rn = 1
        OPTION (RECOMPILE);

        IF @debug = 1
            PRINT CONCAT('Wait stats inserted: ', @rows_inserted);

        /* ── Step 3: Purge ──────────────────────────────────────────────── */

        DECLARE @retention int = (SELECT CAST(setting_value AS int)
                                  FROM collect.config WHERE setting_name = 'retention_days');
        DELETE collect.wait_stats
        WHERE collection_time < DATEADD(DAY, -@retention, SYSDATETIME());

        INSERT collect.collection_log (collector_name, status, rows_inserted, duration_ms)
        VALUES ('usp_CollectWaitStats', 'SUCCESS', @rows_inserted,
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log (collector_name, status, error_message, duration_ms)
        VALUES ('usp_CollectWaitStats', 'ERROR',
                CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));
        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CollectWaitStats created.';
GO
