/*
================================================================================
  10_usp_collect_perf_counters.sql
  Collection Framework — Performance Counter Collector
================================================================================
  Creates: collect.perf_counter_stats (table)
           collect.usp_CollectPerfCounters (stored procedure)

  Source DMV:  sys.dm_os_performance_counters
  Natural key: object_name + counter_name + instance_name
  Delta type:  Cumulative for PERF_LARGE_RAW_BASE counters;
               direct (no delta) for LARGE_RAWCOUNT (rate counters like Batch Req/sec)

  Counter types in sys.dm_os_performance_counters:
    65792  PERF_COUNTER_LARGE_RAWCOUNT  — raw count, rate counters (Batch Requests/sec)
    537003264 PERF_LARGE_RAW_BASE       — denominator for ratio counters (Buffer cache hit ratio base)
    1073939712 PERF_COUNTER_BULK_COUNT  — cumulative (Page reads/sec)

  Key counters captured:
    Batch Requests/sec             — workload rate
    SQL Compilations/sec           — recompile pressure
    SQL Re-Compilations/sec        — recompile pressure
    Page life expectancy           — buffer pool health (< 300 = Warning on older SQL; < 1000 more common now)
    Buffer cache hit ratio         — cache efficiency (< 99% = Warning)
    Lazy writes/sec                — memory pressure signal
    Lock Waits/sec                 — locking pressure
    Lock Wait Time (ms)            — locking duration
    User Connections               — connection count
    Processes blocked              — blocking
    Page reads/sec                 — I/O pressure
    Page writes/sec                — I/O pressure
    Checkpoint pages/sec           — checkpoint I/O
    Log Bytes Flushed/sec          — log I/O rate
    Target Server Memory (KB)      — SQL Server's target memory
    Total Server Memory (KB)       — SQL Server's committed memory
    Free Pages                     — internal free list
    Stolen Server Memory (KB)      — memory stolen from buffer pool
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ── Table ──────────────────────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.perf_counter_stats', N'U') IS NULL
BEGIN
    CREATE TABLE collect.perf_counter_stats
    (
        collection_id    bigint        NOT NULL IDENTITY,
        collection_time  datetime2(7)  NOT NULL DEFAULT SYSDATETIME(),
        server_start_time datetime2(7) NOT NULL,
        /* Counter identity */
        object_name      nvarchar(128) NOT NULL,
        counter_name     nvarchar(128) NOT NULL,
        instance_name    nvarchar(128) NULL,
        cntr_type        int           NOT NULL,
        /* Raw value */
        cntr_value       bigint        NOT NULL,
        /* Delta / rate (NULL for point-in-time counters) */
        cntr_value_delta bigint        NULL,
        value_per_second decimal(18,2) NULL,
        sample_seconds   int           NULL,
        CONSTRAINT PK_perf_counter_stats
            PRIMARY KEY CLUSTERED (collection_time, collection_id)
            WITH (DATA_COMPRESSION = PAGE)
    );

    CREATE NONCLUSTERED INDEX IX_perf_counter_stats_natural_key
    ON collect.perf_counter_stats
        (object_name, counter_name, instance_name, collection_time)
    INCLUDE (cntr_value, cntr_value_delta, server_start_time)
    WITH (DATA_COMPRESSION = PAGE);

    PRINT 'collect.perf_counter_stats created.';
END
ELSE
    PRINT 'collect.perf_counter_stats already exists — skipping DDL.';
GO

/* ── Collector ──────────────────────────────────────────────────────────── */

CREATE OR ALTER PROCEDURE collect.usp_CollectPerfCounters
    @debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @start_time   datetime2(7) = SYSDATETIME(),
        @server_start datetime2(7) = (SELECT CAST(sqlserver_start_time AS datetime2(7))
                                      FROM sys.dm_os_sys_info),
        @rows_inserted int = 0;

    BEGIN TRY

        /* ── Step 1: Insert selected counters ───────────────────────────── */

        INSERT collect.perf_counter_stats
            (server_start_time, object_name, counter_name, instance_name, cntr_type, cntr_value)
        SELECT
            @server_start,
            RTRIM(pc.object_name),
            RTRIM(pc.counter_name),
            NULLIF(RTRIM(pc.instance_name), ''),
            pc.cntr_type,
            pc.cntr_value
        FROM sys.dm_os_performance_counters pc
        WHERE pc.counter_name IN (
            /* Workload */
            'Batch Requests/sec',
            'SQL Compilations/sec',
            'SQL Re-Compilations/sec',
            /* Memory */
            'Page life expectancy',
            'Buffer cache hit ratio',
            'Buffer cache hit ratio base',
            'Lazy writes/sec',
            'Target Server Memory (KB)',
            'Total Server Memory (KB)',
            'Stolen Server Memory (KB)',
            'Free Pages',
            /* Locking */
            'Lock Waits/sec',
            'Lock Wait Time (ms)',
            'Number of Deadlocks/sec',
            'Processes blocked',
            /* I/O */
            'Page reads/sec',
            'Page writes/sec',
            'Checkpoint pages/sec',
            'Log Bytes Flushed/sec',
            'Log Flushes/sec',
            /* Connections */
            'User Connections',
            /* Transactions */
            'Transactions/sec',
            'Write Transactions/sec'
        )
        AND pc.instance_name IN ('', '_Total', 'SQLServer')
           OR pc.instance_name IS NULL
        OPTION (RECOMPILE);

        SET @rows_inserted = ROWCOUNT_BIG();

        /* ── Step 2: Calculate deltas ───────────────────────────────────── */
        /*
          PERF_LARGE_RAW_BASE (537003264): ratio denominator — no meaningful delta
          LARGE_RAWCOUNT (65792):          raw count/rate — delta shows change per interval
          Bulk count (1073939712):         cumulative — delta = change per interval

          For point-in-time counters (Page life expectancy, User Connections, Processes blocked):
          value_per_second is NULL (they show the current state, not a rate)
        */

        WITH cur AS (
            SELECT *, ROW_NUMBER() OVER
                (PARTITION BY object_name, counter_name, instance_name ORDER BY collection_time DESC) rn
            FROM collect.perf_counter_stats WHERE cntr_value_delta IS NULL
        ),
        prv AS (
            SELECT collection_id, object_name, counter_name, instance_name,
                   collection_time, server_start_time, cntr_value,
                   ROW_NUMBER() OVER
                   (PARTITION BY object_name, counter_name, instance_name ORDER BY collection_time DESC) rn
            FROM collect.perf_counter_stats WHERE cntr_value_delta IS NOT NULL
        )
        UPDATE c SET
            sample_seconds =
                CASE WHEN p.collection_id IS NULL
                     THEN NULL
                     ELSE DATEDIFF(SECOND, p.collection_time, c.collection_time) END,
            cntr_value_delta =
                CASE
                    /* Point-in-time — no delta makes sense */
                    WHEN c.counter_name IN ('Page life expectancy', 'User Connections',
                                            'Processes blocked', 'Target Server Memory (KB)',
                                            'Total Server Memory (KB)', 'Stolen Server Memory (KB)',
                                            'Free Pages', 'Lock Wait Time (ms)',
                                            'Buffer cache hit ratio', 'Buffer cache hit ratio base')
                    THEN NULL
                    WHEN p.collection_id IS NULL                      THEN c.cntr_value
                    WHEN c.server_start_time >= p.collection_time     THEN c.cntr_value
                    WHEN c.cntr_value >= p.cntr_value                 THEN c.cntr_value - p.cntr_value
                    ELSE c.cntr_value
                END,
            value_per_second =
                CASE
                    WHEN c.counter_name IN ('Page life expectancy', 'User Connections',
                                            'Processes blocked', 'Target Server Memory (KB)',
                                            'Total Server Memory (KB)', 'Stolen Server Memory (KB)',
                                            'Free Pages', 'Lock Wait Time (ms)',
                                            'Buffer cache hit ratio', 'Buffer cache hit ratio base')
                    THEN NULL
                    WHEN p.collection_id IS NULL OR DATEDIFF(SECOND, p.collection_time, c.collection_time) = 0
                    THEN NULL
                    WHEN c.server_start_time >= p.collection_time THEN NULL
                    WHEN c.cntr_value >= p.cntr_value
                    THEN CAST((c.cntr_value - p.cntr_value) AS decimal(18,2))
                         / DATEDIFF(SECOND, p.collection_time, c.collection_time)
                    ELSE NULL
                END
        FROM cur c
        LEFT JOIN prv p
          ON  p.object_name   = c.object_name
          AND p.counter_name  = c.counter_name
          AND (p.instance_name = c.instance_name OR (p.instance_name IS NULL AND c.instance_name IS NULL))
          AND p.rn = 1
        WHERE c.rn = 1
        OPTION (RECOMPILE);

        /* ── Step 3: Purge ──────────────────────────────────────────────── */

        DECLARE @retention int = (SELECT CAST(setting_value AS int)
                                  FROM collect.config WHERE setting_name = 'retention_days');
        DELETE collect.perf_counter_stats
        WHERE collection_time < DATEADD(DAY, -@retention, SYSDATETIME());

        IF @debug = 1
            PRINT CONCAT('Perf counter rows inserted: ', @rows_inserted);

        INSERT collect.collection_log (collector_name, status, rows_inserted, duration_ms)
        VALUES ('usp_CollectPerfCounters', 'SUCCESS', @rows_inserted,
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log (collector_name, status, error_message, duration_ms)
        VALUES ('usp_CollectPerfCounters', 'ERROR',
                CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));
        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CollectPerfCounters created.';
GO
