/*
================================================================================
  01_create_tables.sql
  Procedure Stats Collection Framework — Schema, Tables, and Indexes
================================================================================
  Run this script once against the target DBA / monitoring database.
  Compatible with SQL Server 2016+ (PAGE compression, COMPRESS function).

  Prerequisites: run 00_bootstrap.sql first (creates schema, config, collection_log).

  Tables created:
    collect.proc_stats            — main snapshot table (procedure / trigger / function)
    collect.proc_stats_latest_hash — deduplication tracker (one row per natural key)

  After running this script, execute in order:
    02_usp_collect_procstats.sql  — procedure/trigger/function stats collector
    03_usp_calculate_deltas.sql   — delta calculator (called by 02)
    04_report_queries.sql         — reporting queries to paste into /procstats-review
    05_create_agent_job.sql       — SQL Agent job (calls usp_CollectAll)
    06_usp_collect_wait_stats.sql — sys.dm_os_wait_stats collector
    07_usp_collect_query_stats.sql — sys.dm_exec_query_stats collector
    08_usp_collect_file_io.sql    — sys.dm_io_virtual_file_stats collector
    09_usp_collect_memory.sql     — memory clerks + process memory collector
    10_usp_collect_perf_counters.sql — sys.dm_os_performance_counters collector
    11_usp_collect_all.sql        — master collector (calls all of the above)
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ── collect.proc_stats ─────────────────────────────────────────────────── */
/*
  Natural key for delta matching: (database_name, object_id, plan_handle)
  Identifies a specific compiled plan for a specific object in a specific database.
  A new plan_handle appears when a plan is recompiled or evicted and re-cached.

  Cumulative counters are stored as-is from the DMV.
  Delta columns (_delta suffix) are populated by usp_CalculateProcStatsDeltas
  immediately after each insert — they remain NULL until that SP runs.

  Computed columns provide ready-to-use per-execution averages and per-second
  rates without requiring the reporting query to repeat the arithmetic.
*/

IF OBJECT_ID(N'collect.proc_stats', N'U') IS NULL
BEGIN
    CREATE TABLE collect.proc_stats
    (
        /* ── Identity / timestamp ───────────────────────────────────────── */
        collection_id        bigint        NOT NULL IDENTITY,
        collection_time      datetime2(7)  NOT NULL DEFAULT SYSDATETIME(),
        server_start_time    datetime2(7)  NOT NULL,  /* from sys.dm_os_sys_info — restart detection */

        /* ── Object identity ────────────────────────────────────────────── */
        object_type          nvarchar(20)  NOT NULL,  /* PROCEDURE | TRIGGER | FUNCTION */
        database_name        sysname       NOT NULL,
        schema_name          sysname       NULL,
        object_name          sysname       NULL,
        object_id            int           NOT NULL,
        sql_handle           varbinary(64) NOT NULL,
        plan_handle          varbinary(64) NOT NULL,
        cached_time          datetime2(7)  NOT NULL,  /* when this plan entered cache */
        last_execution_time  datetime2(7)  NOT NULL,

        /* ── Cumulative raw values from DMV ─────────────────────────────── */
        execution_count      bigint NOT NULL,
        total_worker_time    bigint NOT NULL,  /* microseconds */
        min_worker_time      bigint NOT NULL,
        max_worker_time      bigint NOT NULL,
        total_elapsed_time   bigint NOT NULL,  /* microseconds */
        min_elapsed_time     bigint NOT NULL,
        max_elapsed_time     bigint NOT NULL,
        total_logical_reads  bigint NOT NULL,  /* 8 KB pages */
        min_logical_reads    bigint NOT NULL,
        max_logical_reads    bigint NOT NULL,
        total_physical_reads bigint NOT NULL,
        total_logical_writes bigint NOT NULL,
        total_spills         bigint NULL,      /* SQL Server 2017+; NULL on 2016 */
        min_spills           bigint NULL,
        max_spills           bigint NULL,

        /* ── Delta columns (NULL until usp_CalculateProcStatsDeltas runs) ─ */
        execution_count_delta       bigint NULL,
        total_worker_time_delta     bigint NULL,
        total_elapsed_time_delta    bigint NULL,
        total_logical_reads_delta   bigint NULL,
        total_physical_reads_delta  bigint NULL,
        total_logical_writes_delta  bigint NULL,
        sample_seconds              int    NULL,  /* DATEDIFF(SECOND, prev_collection_time, collection_time) */

        /* ── Computed analysis helpers (not stored) ──────────────────────── */
        avg_worker_time_ms   AS (total_worker_time  / NULLIF(execution_count, 0) / 1000.),
        avg_elapsed_time_ms  AS (total_elapsed_time / NULLIF(execution_count, 0) / 1000.),
        avg_logical_reads    AS (total_logical_reads / NULLIF(execution_count, 0)),
        avg_physical_reads   AS (total_physical_reads / NULLIF(execution_count, 0)),
        worker_time_per_sec  AS (total_worker_time_delta  / NULLIF(sample_seconds, 0) / 1000.),
        reads_per_sec        AS (total_logical_reads_delta / NULLIF(sample_seconds, 0)),
        avg_spills           AS (total_spills / NULLIF(execution_count, 0)),

        /* ── Deduplication hash ──────────────────────────────────────────── */
        /* SHA2_256 of key cumulative counters; row skipped if hash matches   */
        /* previous hash for the same natural key (object did not execute).   */
        row_hash             binary(32) NULL,

        /* ── Optional compressed plan XML ───────────────────────────────── */
        query_plan_compressed varbinary(max) NULL,  /* COMPRESS(CAST(query_plan AS nvarchar(max))) */

        CONSTRAINT PK_proc_stats
            PRIMARY KEY CLUSTERED (collection_time, collection_id)
            WITH (DATA_COMPRESSION = PAGE)
    );

    /* Delta lookup index — joins current row to its predecessor by natural key */
    CREATE NONCLUSTERED INDEX IX_proc_stats_natural_key
    ON collect.proc_stats
        (database_name, object_id, plan_handle, collection_time)
    INCLUDE
        (execution_count, total_worker_time, total_elapsed_time,
         total_logical_reads, total_physical_reads, total_logical_writes,
         server_start_time, row_hash)
    WITH (DATA_COMPRESSION = PAGE);

    PRINT 'collect.proc_stats created.';
END
ELSE
    PRINT 'collect.proc_stats already exists — skipping.';
GO

/* ── collect.proc_stats_latest_hash ────────────────────────────────────── */
/*
  One row per natural key. Tracks the SHA2_256 hash of the last-seen cumulative
  counters. The collector skips inserting a new snapshot row when the hash matches,
  saving ~50-70% storage churn for idle objects.
*/

IF OBJECT_ID(N'collect.proc_stats_latest_hash', N'U') IS NULL
BEGIN
    CREATE TABLE collect.proc_stats_latest_hash
    (
        database_name  sysname        NOT NULL,
        object_id      int            NOT NULL,
        plan_handle    varbinary(64)  NOT NULL,
        row_hash       binary(32)     NOT NULL,
        last_seen      datetime2(7)   NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT PK_proc_stats_latest_hash
            PRIMARY KEY CLUSTERED (database_name, object_id, plan_handle)
    );

    PRINT 'collect.proc_stats_latest_hash created.';
END
ELSE
    PRINT 'collect.proc_stats_latest_hash already exists — skipping.';
GO

PRINT '';
PRINT 'Schema setup complete. Run 02_usp_collect_procstats.sql next.';
GO
