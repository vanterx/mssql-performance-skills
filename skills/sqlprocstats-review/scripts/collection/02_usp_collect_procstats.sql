/*
================================================================================
  02_usp_collect_procstats.sql
  Procedure Stats Collection Framework — Snapshot Collector
================================================================================
  Creates: collect.usp_CollectProcStats

  Collects one snapshot from:
    sys.dm_exec_procedure_stats   (stored procedures)
    sys.dm_exec_trigger_stats     (triggers)
    sys.dm_exec_function_stats    (scalar functions — SQL Server 2016+)

  Collection flow:
    1. Read DMVs into #staged temp table
    2. Compute SHA2_256 deduplication hash per row
    3. Skip rows whose hash matches the previous snapshot (object did not execute)
    4. Insert new/changed rows into collect.proc_stats
    5. Upsert hash tracker (collect.proc_stats_latest_hash)
    6. Call usp_CalculateProcStatsDeltas to fill delta columns
    7. Purge rows older than retention_days
    8. Log result to collect.collection_log

  Execute manually:
    EXECUTE collect.usp_CollectProcStats;
    EXECUTE collect.usp_CollectProcStats @debug = 1;   -- prints row counts

  Schedule via SQL Agent (see 05_create_agent_job.sql).
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE collect.usp_CollectProcStats
    @debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @start_time      datetime2(7) = SYSDATETIME(),
        @server_start    datetime2(7) = (
                             SELECT CAST(sqlserver_start_time AS datetime2(7))
                             FROM   sys.dm_os_sys_info),
        @min_execs       int = (
                             SELECT CAST(setting_value AS int)
                             FROM   collect.config
                             WHERE  setting_name = N'min_executions'),
        @collect_plans   bit = (
                             SELECT CAST(setting_value AS bit)
                             FROM   collect.config
                             WHERE  setting_name = N'collect_query_plans'),
        @retention_days  int = (
                             SELECT CAST(setting_value AS int)
                             FROM   collect.config
                             WHERE  setting_name = N'retention_days'),
        @exclude_sys     bit = (
                             SELECT CAST(setting_value AS bit)
                             FROM   collect.config
                             WHERE  setting_name = N'exclude_system_databases'),
        @rows_inserted   int = 0,
        @rows_skipped    int = 0;

    BEGIN TRY

        /* ── Step 1: Collect DMV data into temp staging table ──────────── */

        IF OBJECT_ID(N'tempdb..#staged') IS NOT NULL
            DROP TABLE #staged;

        CREATE TABLE #staged
        (
            object_type         nvarchar(20)  NOT NULL,
            database_name       sysname       NOT NULL,
            schema_name         sysname       NULL,
            object_name         sysname       NULL,
            object_id           int           NOT NULL,
            sql_handle          varbinary(64) NOT NULL,
            plan_handle         varbinary(64) NOT NULL,
            cached_time         datetime2(7)  NOT NULL,
            last_execution_time datetime2(7)  NOT NULL,
            execution_count     bigint        NOT NULL,
            total_worker_time   bigint        NOT NULL,
            min_worker_time     bigint        NOT NULL,
            max_worker_time     bigint        NOT NULL,
            total_elapsed_time  bigint        NOT NULL,
            min_elapsed_time    bigint        NOT NULL,
            max_elapsed_time    bigint        NOT NULL,
            total_logical_reads  bigint       NOT NULL,
            min_logical_reads    bigint       NOT NULL,
            max_logical_reads    bigint       NOT NULL,
            total_physical_reads bigint       NOT NULL,
            total_logical_writes bigint       NOT NULL,
            total_spills        bigint        NULL,
            min_spills          bigint        NULL,
            max_spills          bigint        NULL,
            row_hash            binary(32)    NULL
        );

        /* Procedures */
        INSERT #staged
        SELECT
            object_type         = N'PROCEDURE',
            database_name       = DB_NAME(ps.database_id),
            schema_name         = OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id),
            object_name         = OBJECT_NAME(ps.object_id, ps.database_id),
            object_id           = ps.object_id,
            sql_handle          = ps.sql_handle,
            plan_handle         = ps.plan_handle,
            cached_time         = CAST(ps.cached_time AS datetime2(7)),
            last_execution_time = CAST(ps.last_execution_time AS datetime2(7)),
            execution_count     = ps.execution_count,
            total_worker_time   = ps.total_worker_time,
            min_worker_time     = ps.min_worker_time,
            max_worker_time     = ps.max_worker_time,
            total_elapsed_time  = ps.total_elapsed_time,
            min_elapsed_time    = ps.min_elapsed_time,
            max_elapsed_time    = ps.max_elapsed_time,
            total_logical_reads  = ps.total_logical_reads,
            min_logical_reads    = ps.min_logical_reads,
            max_logical_reads    = ps.max_logical_reads,
            total_physical_reads = ps.total_physical_reads,
            total_logical_writes = ps.total_logical_writes,
            total_spills        = NULL,   /* populated below for 2017+ */
            min_spills          = NULL,
            max_spills          = NULL,
            row_hash            = NULL    /* computed below */
        FROM sys.dm_exec_procedure_stats AS ps
        WHERE ps.execution_count >= @min_execs
          AND (  @exclude_sys = 0
              OR ps.database_id NOT IN (1, 2, 3, 4))  /* skip master/model/msdb/tempdb */
        OPTION (RECOMPILE);

        /* Triggers */
        INSERT #staged
        SELECT
            N'TRIGGER',
            DB_NAME(ts.database_id),
            OBJECT_SCHEMA_NAME(ts.object_id, ts.database_id),
            OBJECT_NAME(ts.object_id, ts.database_id),
            ts.object_id, ts.sql_handle, ts.plan_handle,
            CAST(ts.cached_time AS datetime2(7)),
            CAST(ts.last_execution_time AS datetime2(7)),
            ts.execution_count,
            ts.total_worker_time, ts.min_worker_time, ts.max_worker_time,
            ts.total_elapsed_time, ts.min_elapsed_time, ts.max_elapsed_time,
            ts.total_logical_reads, ts.min_logical_reads, ts.max_logical_reads,
            ts.total_physical_reads, ts.total_logical_writes,
            NULL, NULL, NULL, NULL
        FROM sys.dm_exec_trigger_stats AS ts
        WHERE ts.execution_count >= @min_execs
          AND (  @exclude_sys = 0
              OR ts.database_id NOT IN (1, 2, 3, 4))
        OPTION (RECOMPILE);

        /* Scalar functions (SQL Server 2016+) */
        BEGIN TRY
            INSERT #staged
            SELECT
                N'FUNCTION',
                DB_NAME(fs.database_id),
                OBJECT_SCHEMA_NAME(fs.object_id, fs.database_id),
                OBJECT_NAME(fs.object_id, fs.database_id),
                fs.object_id, fs.sql_handle, fs.plan_handle,
                CAST(fs.cached_time AS datetime2(7)),
                CAST(fs.last_execution_time AS datetime2(7)),
                fs.execution_count,
                fs.total_worker_time, fs.min_worker_time, fs.max_worker_time,
                fs.total_elapsed_time, fs.min_elapsed_time, fs.max_elapsed_time,
                fs.total_logical_reads, fs.min_logical_reads, fs.max_logical_reads,
                fs.total_physical_reads, fs.total_logical_writes,
                NULL, NULL, NULL, NULL
            FROM sys.dm_exec_function_stats AS fs
            WHERE fs.execution_count >= @min_execs
              AND (  @exclude_sys = 0
                  OR fs.database_id NOT IN (1, 2, 3, 4))
            OPTION (RECOMPILE);
        END TRY
        BEGIN CATCH
            /* dm_exec_function_stats absent on SQL Server < 2016 — silently skip */
            IF @debug = 1
                PRINT 'Note: sys.dm_exec_function_stats not available on this version.';
        END CATCH;

        /* Backfill spills columns for SQL Server 2017+ */
        BEGIN TRY
            UPDATE s
            SET
                total_spills = ps.total_spills,
                min_spills   = ps.min_spills,
                max_spills   = ps.max_spills
            FROM #staged s
            JOIN sys.dm_exec_procedure_stats ps
              ON  ps.plan_handle = s.plan_handle
              AND s.object_type  = N'PROCEDURE';

            UPDATE s
            SET
                total_spills = ts.total_spills,
                min_spills   = ts.min_spills,
                max_spills   = ts.max_spills
            FROM #staged s
            JOIN sys.dm_exec_trigger_stats ts
              ON  ts.plan_handle = s.plan_handle
              AND s.object_type  = N'TRIGGER';
        END TRY
        BEGIN CATCH
            /* total_spills column absent on SQL Server 2016 — silently skip */
            IF @debug = 1
                PRINT 'Note: total_spills not available on this version.';
        END CATCH;

        /* ── Step 2: Compute deduplication hash ────────────────────────── */
        /* Hash covers only the counters that change when the object executes. */
        /* If this hash matches the stored hash, the object did not run since  */
        /* the last collection, and we can skip the insert.                    */

        UPDATE #staged
        SET row_hash = HASHBYTES(
            'SHA2_256',
            CAST(execution_count     AS binary(8)) +
            CAST(total_worker_time   AS binary(8)) +
            CAST(total_elapsed_time  AS binary(8)) +
            CAST(total_logical_reads AS binary(8)) +
            CAST(total_physical_reads AS binary(8)) +
            CAST(total_logical_writes AS binary(8)) +
            ISNULL(CAST(total_spills AS binary(8)), 0x0000000000000000));

        IF @debug = 1
        BEGIN
            SET @rows_skipped = (
                SELECT COUNT(*)
                FROM #staged s
                JOIN collect.proc_stats_latest_hash h
                  ON  h.database_name = s.database_name
                  AND h.object_id     = s.object_id
                  AND h.plan_handle   = s.plan_handle
                  AND h.row_hash      = s.row_hash);
            PRINT CONCAT('Staged rows: ', (SELECT COUNT(*) FROM #staged),
                         '  |  Unchanged (skip): ', @rows_skipped);
        END;

        /* ── Step 3: Insert new / changed rows ─────────────────────────── */

        INSERT collect.proc_stats
        (
            server_start_time, object_type, database_name, schema_name, object_name,
            object_id, sql_handle, plan_handle, cached_time, last_execution_time,
            execution_count,
            total_worker_time, min_worker_time, max_worker_time,
            total_elapsed_time, min_elapsed_time, max_elapsed_time,
            total_logical_reads, min_logical_reads, max_logical_reads,
            total_physical_reads, total_logical_writes,
            total_spills, min_spills, max_spills,
            row_hash, query_plan_compressed
        )
        SELECT
            @server_start,
            s.object_type, s.database_name, s.schema_name, s.object_name,
            s.object_id, s.sql_handle, s.plan_handle, s.cached_time, s.last_execution_time,
            s.execution_count,
            s.total_worker_time, s.min_worker_time, s.max_worker_time,
            s.total_elapsed_time, s.min_elapsed_time, s.max_elapsed_time,
            s.total_logical_reads, s.min_logical_reads, s.max_logical_reads,
            s.total_physical_reads, s.total_logical_writes,
            s.total_spills, s.min_spills, s.max_spills,
            s.row_hash,
            /* Capture plan XML only when collect_query_plans = 1 */
            CASE WHEN @collect_plans = 1
                 THEN COMPRESS(CAST(qp.query_plan AS nvarchar(max)))
                 ELSE NULL
            END
        FROM #staged s
        OUTER APPLY (
            SELECT query_plan
            FROM   sys.dm_exec_query_plan(s.plan_handle)
            WHERE  @collect_plans = 1
        ) qp
        /* Skip rows whose hash matches the last-seen hash (not executed) */
        WHERE NOT EXISTS (
            SELECT 1
            FROM   collect.proc_stats_latest_hash h
            WHERE  h.database_name = s.database_name
              AND  h.object_id     = s.object_id
              AND  h.plan_handle   = s.plan_handle
              AND  h.row_hash      = s.row_hash)
        OPTION (RECOMPILE);

        SET @rows_inserted = ROWCOUNT_BIG();

        IF @debug = 1
            PRINT CONCAT('Rows inserted: ', @rows_inserted);

        /* ── Step 4: Upsert hash tracker ───────────────────────────────── */

        MERGE collect.proc_stats_latest_hash AS t
        USING (
            SELECT database_name, object_id, plan_handle, row_hash
            FROM   #staged
        ) AS s
        ON  t.database_name = s.database_name
        AND t.object_id     = s.object_id
        AND t.plan_handle   = s.plan_handle
        WHEN MATCHED THEN
            UPDATE SET row_hash = s.row_hash, last_seen = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (database_name, object_id, plan_handle, row_hash, last_seen)
            VALUES (s.database_name, s.object_id, s.plan_handle, s.row_hash, SYSDATETIME());

        /* ── Step 5: Calculate deltas ───────────────────────────────────── */

        EXECUTE collect.usp_CalculateProcStatsDeltas @debug = @debug;

        /* ── Step 6: Purge old rows ─────────────────────────────────────── */

        DELETE collect.proc_stats
        WHERE collection_time < DATEADD(DAY, -@retention_days, SYSDATETIME());

        IF @debug = 1
            PRINT CONCAT('Purged rows older than ', @retention_days, ' days.');

        /* ── Step 7: Log success ────────────────────────────────────────── */

        INSERT collect.collection_log
            (collector_name, status, rows_inserted, duration_ms)
        VALUES
            (N'usp_CollectProcStats', N'SUCCESS', @rows_inserted,
             DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log
            (collector_name, status, error_message, duration_ms)
        VALUES
            (N'usp_CollectProcStats', N'ERROR',
             CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
             DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CollectProcStats created. Run 03_usp_calculate_deltas.sql next.';
GO
