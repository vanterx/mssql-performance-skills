/*
================================================================================
  07_usp_collect_query_stats.sql
  Collection Framework — Query (Statement-Level) Stats Collector
================================================================================
  Creates: collect.query_stats (table)
           collect.query_stats_latest_hash (deduplication tracker)
           collect.usp_CollectQueryStats (stored procedure)

  Source DMV:  sys.dm_exec_query_stats
  Natural key: sql_handle + statement_start_offset + statement_end_offset + plan_handle
  Delta type:  Cumulative — deltas calculated inline, SHA2_256 deduplication

  This is the statement-level complement to proc_stats. Where proc_stats gives
  you cost per stored procedure call, query_stats gives you cost per individual
  SQL statement — useful for identifying expensive statements inside ad-hoc
  batches, ORMs, or dynamic SQL that is not wrapped in a procedure.

  Feed report output into: /procstats-review (R1–R15 checks apply equally)
  Or use the query_stats report query at the bottom of 04_report_queries.sql.
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ── Table ──────────────────────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.query_stats', N'U') IS NULL
BEGIN
    CREATE TABLE collect.query_stats
    (
        collection_id         bigint         NOT NULL IDENTITY,
        collection_time       datetime2(7)   NOT NULL DEFAULT SYSDATETIME(),
        server_start_time     datetime2(7)   NOT NULL,
        /* Natural key */
        sql_handle            varbinary(64)  NOT NULL,
        statement_start_offset int           NOT NULL,
        statement_end_offset   int           NOT NULL,
        plan_handle           varbinary(64)  NOT NULL,
        plan_generation_num   bigint         NOT NULL,
        /* Context */
        database_name         sysname        NULL,   /* from dm_exec_plan_attributes */
        creation_time         datetime2(7)   NOT NULL,
        last_execution_time   datetime2(7)   NOT NULL,
        /* Cumulative raw values */
        execution_count       bigint         NOT NULL,
        total_worker_time     bigint         NOT NULL,
        min_worker_time       bigint         NOT NULL,
        max_worker_time       bigint         NOT NULL,
        total_elapsed_time    bigint         NOT NULL,
        min_elapsed_time      bigint         NOT NULL,
        max_elapsed_time      bigint         NOT NULL,
        total_logical_reads   bigint         NOT NULL,
        min_logical_reads     bigint         NOT NULL,
        max_logical_reads     bigint         NOT NULL,
        total_physical_reads  bigint         NOT NULL,
        total_logical_writes  bigint         NOT NULL,
        total_rows            bigint         NOT NULL,
        total_spills          bigint         NULL,   /* SQL 2017+ */
        min_grant_kb          bigint         NULL,   /* SQL 2016+ */
        max_grant_kb          bigint         NULL,
        /* Delta columns */
        execution_count_delta      bigint    NULL,
        total_worker_time_delta    bigint    NULL,
        total_elapsed_time_delta   bigint    NULL,
        total_logical_reads_delta  bigint    NULL,
        total_physical_reads_delta bigint    NULL,
        total_logical_writes_delta bigint    NULL,
        sample_seconds             int       NULL,
        /* Computed helpers */
        avg_worker_time_ms    AS (total_worker_time  / NULLIF(execution_count, 0) / 1000.),
        avg_elapsed_time_ms   AS (total_elapsed_time / NULLIF(execution_count, 0) / 1000.),
        avg_logical_reads     AS (total_logical_reads / NULLIF(execution_count, 0)),
        avg_rows              AS (total_rows / NULLIF(execution_count, 0)),
        worker_time_per_sec   AS (total_worker_time_delta / NULLIF(sample_seconds, 0) / 1000.),
        reads_per_sec         AS (total_logical_reads_delta / NULLIF(sample_seconds, 0)),
        /* Deduplication */
        row_hash              binary(32)     NULL,
        /* Optional: compressed query text and plan */
        query_text_compressed  varbinary(max) NULL,
        query_plan_compressed  varbinary(max) NULL,
        CONSTRAINT PK_query_stats
            PRIMARY KEY CLUSTERED (collection_time, collection_id)
            WITH (DATA_COMPRESSION = PAGE)
    );

    CREATE NONCLUSTERED INDEX IX_query_stats_natural_key
    ON collect.query_stats
        (sql_handle, statement_start_offset, statement_end_offset, plan_handle, collection_time)
    INCLUDE (execution_count, total_worker_time, total_elapsed_time,
             total_logical_reads, total_physical_reads, total_logical_writes,
             server_start_time, row_hash)
    WITH (DATA_COMPRESSION = PAGE);

    CREATE TABLE collect.query_stats_latest_hash
    (
        sql_handle             varbinary(64) NOT NULL,
        statement_start_offset int           NOT NULL,
        statement_end_offset   int           NOT NULL,
        plan_handle            varbinary(64) NOT NULL,
        row_hash               binary(32)    NOT NULL,
        last_seen              datetime2(7)  NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT PK_query_stats_latest_hash
            PRIMARY KEY (sql_handle, statement_start_offset, statement_end_offset, plan_handle)
    );

    PRINT 'collect.query_stats + collect.query_stats_latest_hash created.';
END
ELSE
    PRINT 'collect.query_stats already exists — skipping DDL.';
GO

/* ── Collector ──────────────────────────────────────────────────────────── */

CREATE OR ALTER PROCEDURE collect.usp_CollectQueryStats
    @debug       bit = 0,
    @min_execs   int = 1,      /* skip statements below this execution count */
    @top_n       int = 2000    /* cap collection to top N by worker_time (reduces noise) */
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @start_time     datetime2(7) = SYSDATETIME(),
        @server_start   datetime2(7) = (SELECT CAST(sqlserver_start_time AS datetime2(7))
                                        FROM   sys.dm_os_sys_info),
        @collect_text   bit = (SELECT CAST(setting_value AS bit)
                                FROM collect.config WHERE setting_name = 'collect_query_plans'),
        @rows_inserted  int = 0;

    BEGIN TRY

        /* ── Step 1: Stage top-N rows from DMV ─────────────────────────── */

        SELECT TOP (@top_n)
            qs.sql_handle,
            qs.statement_start_offset,
            qs.statement_end_offset,
            qs.plan_handle,
            qs.plan_generation_num,
            database_name = DB_NAME(TRY_CAST(pa.value AS int)),
            creation_time         = CAST(qs.creation_time AS datetime2(7)),
            last_execution_time   = CAST(qs.last_execution_time AS datetime2(7)),
            qs.execution_count,
            qs.total_worker_time, qs.min_worker_time, qs.max_worker_time,
            qs.total_elapsed_time, qs.min_elapsed_time, qs.max_elapsed_time,
            qs.total_logical_reads, qs.min_logical_reads, qs.max_logical_reads,
            qs.total_physical_reads, qs.total_logical_writes,
            total_rows   = ISNULL(qs.total_rows, 0),
            total_spills = NULL,   /* backfilled below for 2017+ */
            min_grant_kb = NULL,
            max_grant_kb = NULL,
            row_hash = HASHBYTES(
                'SHA2_256',
                CAST(qs.execution_count     AS binary(8)) +
                CAST(qs.total_worker_time   AS binary(8)) +
                CAST(qs.total_elapsed_time  AS binary(8)) +
                CAST(qs.total_logical_reads AS binary(8)) +
                CAST(qs.total_physical_reads AS binary(8)) +
                CAST(qs.total_logical_writes AS binary(8)))
        INTO #staged
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
        WHERE pa.attribute = 'dbid'
          AND qs.execution_count >= @min_execs
          AND TRY_CAST(pa.value AS int) NOT IN (1, 2, 3, 4)   /* exclude system DBs */
        ORDER BY qs.total_worker_time DESC
        OPTION (RECOMPILE);

        /* Backfill 2017+ columns (total_spills, min/max_grant_kb) */
        BEGIN TRY
            UPDATE s
            SET total_spills = qs.total_spills,
                min_grant_kb = qs.min_grant_kb,
                max_grant_kb = qs.max_grant_kb
            FROM #staged s
            JOIN sys.dm_exec_query_stats qs
              ON  qs.sql_handle             = s.sql_handle
              AND qs.statement_start_offset = s.statement_start_offset
              AND qs.statement_end_offset   = s.statement_end_offset
              AND qs.plan_handle            = s.plan_handle;
        END TRY
        BEGIN CATCH  /* columns absent on SQL Server < 2017 */ END CATCH;

        /* ── Step 2: Insert new / changed rows only ─────────────────────── */

        INSERT collect.query_stats
        (
            server_start_time, sql_handle, statement_start_offset, statement_end_offset,
            plan_handle, plan_generation_num, database_name, creation_time, last_execution_time,
            execution_count,
            total_worker_time, min_worker_time, max_worker_time,
            total_elapsed_time, min_elapsed_time, max_elapsed_time,
            total_logical_reads, min_logical_reads, max_logical_reads,
            total_physical_reads, total_logical_writes, total_rows,
            total_spills, min_grant_kb, max_grant_kb,
            row_hash, query_text_compressed, query_plan_compressed
        )
        SELECT
            @server_start,
            s.sql_handle, s.statement_start_offset, s.statement_end_offset,
            s.plan_handle, s.plan_generation_num, s.database_name,
            s.creation_time, s.last_execution_time,
            s.execution_count,
            s.total_worker_time, s.min_worker_time, s.max_worker_time,
            s.total_elapsed_time, s.min_elapsed_time, s.max_elapsed_time,
            s.total_logical_reads, s.min_logical_reads, s.max_logical_reads,
            s.total_physical_reads, s.total_logical_writes, s.total_rows,
            s.total_spills, s.min_grant_kb, s.max_grant_kb,
            s.row_hash,
            CASE WHEN @collect_text = 1
                 THEN COMPRESS(SUBSTRING(st.text,
                      s.statement_start_offset / 2 + 1,
                      CASE WHEN s.statement_end_offset = -1
                           THEN LEN(st.text)
                           ELSE (s.statement_end_offset - s.statement_start_offset) / 2 + 1
                      END))
                 ELSE NULL END,
            CASE WHEN @collect_text = 1
                 THEN COMPRESS(CAST(qp.query_plan AS nvarchar(max)))
                 ELSE NULL END
        FROM #staged s
        OUTER APPLY sys.dm_exec_sql_text(s.sql_handle) st
        OUTER APPLY sys.dm_exec_query_plan(s.plan_handle) qp
        WHERE NOT EXISTS (
            SELECT 1 FROM collect.query_stats_latest_hash h
            WHERE  h.sql_handle             = s.sql_handle
              AND  h.statement_start_offset = s.statement_start_offset
              AND  h.statement_end_offset   = s.statement_end_offset
              AND  h.plan_handle            = s.plan_handle
              AND  h.row_hash               = s.row_hash)
        OPTION (RECOMPILE);

        SET @rows_inserted = ROWCOUNT_BIG();

        /* ── Step 3: Upsert hash tracker ───────────────────────────────── */

        MERGE collect.query_stats_latest_hash AS t
        USING (SELECT sql_handle, statement_start_offset, statement_end_offset,
                      plan_handle, row_hash FROM #staged) AS s
        ON  t.sql_handle             = s.sql_handle
        AND t.statement_start_offset = s.statement_start_offset
        AND t.statement_end_offset   = s.statement_end_offset
        AND t.plan_handle            = s.plan_handle
        WHEN MATCHED     THEN UPDATE SET row_hash = s.row_hash, last_seen = SYSDATETIME()
        WHEN NOT MATCHED THEN INSERT (sql_handle, statement_start_offset, statement_end_offset,
                                      plan_handle, row_hash, last_seen)
                              VALUES (s.sql_handle, s.statement_start_offset,
                                      s.statement_end_offset, s.plan_handle,
                                      s.row_hash, SYSDATETIME());

        /* ── Step 4: Calculate deltas ───────────────────────────────────── */

        WITH cur AS (
            SELECT *, ROW_NUMBER() OVER
                (PARTITION BY sql_handle, statement_start_offset, statement_end_offset, plan_handle
                 ORDER BY collection_time DESC) rn
            FROM collect.query_stats WHERE execution_count_delta IS NULL
        ),
        prv AS (
            SELECT collection_id, sql_handle, statement_start_offset, statement_end_offset,
                   plan_handle, collection_time, server_start_time,
                   execution_count, total_worker_time, total_elapsed_time,
                   total_logical_reads, total_physical_reads, total_logical_writes,
                   ROW_NUMBER() OVER
                   (PARTITION BY sql_handle, statement_start_offset, statement_end_offset, plan_handle
                    ORDER BY collection_time DESC) rn
            FROM collect.query_stats WHERE execution_count_delta IS NOT NULL
        )
        UPDATE c SET
            sample_seconds =
                CASE WHEN p.collection_id IS NULL
                     THEN DATEDIFF(SECOND, c.creation_time, c.last_execution_time)
                     ELSE DATEDIFF(SECOND, p.collection_time, c.collection_time) END,
            execution_count_delta =
                CASE WHEN p.collection_id IS NULL                              THEN c.execution_count
                     WHEN c.server_start_time >= p.collection_time             THEN c.execution_count
                     WHEN c.execution_count >= p.execution_count               THEN c.execution_count - p.execution_count
                     ELSE c.execution_count END,
            total_worker_time_delta =
                CASE WHEN p.collection_id IS NULL                              THEN c.total_worker_time
                     WHEN c.server_start_time >= p.collection_time             THEN c.total_worker_time
                     WHEN c.total_worker_time >= p.total_worker_time           THEN c.total_worker_time - p.total_worker_time
                     ELSE c.total_worker_time END,
            total_elapsed_time_delta =
                CASE WHEN p.collection_id IS NULL                              THEN c.total_elapsed_time
                     WHEN c.server_start_time >= p.collection_time             THEN c.total_elapsed_time
                     WHEN c.total_elapsed_time >= p.total_elapsed_time         THEN c.total_elapsed_time - p.total_elapsed_time
                     ELSE c.total_elapsed_time END,
            total_logical_reads_delta =
                CASE WHEN p.collection_id IS NULL                              THEN c.total_logical_reads
                     WHEN c.server_start_time >= p.collection_time             THEN c.total_logical_reads
                     WHEN c.total_logical_reads >= p.total_logical_reads       THEN c.total_logical_reads - p.total_logical_reads
                     ELSE c.total_logical_reads END,
            total_physical_reads_delta =
                CASE WHEN p.collection_id IS NULL                              THEN c.total_physical_reads
                     WHEN c.server_start_time >= p.collection_time             THEN c.total_physical_reads
                     WHEN c.total_physical_reads >= p.total_physical_reads     THEN c.total_physical_reads - p.total_physical_reads
                     ELSE c.total_physical_reads END,
            total_logical_writes_delta =
                CASE WHEN p.collection_id IS NULL                              THEN c.total_logical_writes
                     WHEN c.server_start_time >= p.collection_time             THEN c.total_logical_writes
                     WHEN c.total_logical_writes >= p.total_logical_writes     THEN c.total_logical_writes - p.total_logical_writes
                     ELSE c.total_logical_writes END
        FROM cur c
        LEFT JOIN prv p
          ON  p.sql_handle             = c.sql_handle
          AND p.statement_start_offset = c.statement_start_offset
          AND p.statement_end_offset   = c.statement_end_offset
          AND p.plan_handle            = c.plan_handle
          AND p.rn = 1
        WHERE c.rn = 1
        OPTION (RECOMPILE, HASH JOIN, HASH GROUP);

        /* ── Step 5: Purge ──────────────────────────────────────────────── */

        DECLARE @retention int = (SELECT CAST(setting_value AS int)
                                  FROM collect.config WHERE setting_name = 'retention_days');
        DELETE collect.query_stats WHERE collection_time < DATEADD(DAY, -@retention, SYSDATETIME());

        IF @debug = 1
            PRINT CONCAT('Query stats inserted: ', @rows_inserted);

        INSERT collect.collection_log (collector_name, status, rows_inserted, duration_ms)
        VALUES ('usp_CollectQueryStats', 'SUCCESS', @rows_inserted,
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log (collector_name, status, error_message, duration_ms)
        VALUES ('usp_CollectQueryStats', 'ERROR',
                CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));
        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CollectQueryStats created.';
GO
