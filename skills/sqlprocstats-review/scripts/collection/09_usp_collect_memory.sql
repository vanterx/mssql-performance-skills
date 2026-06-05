/*
================================================================================
  09_usp_collect_memory.sql
  Collection Framework — Memory Statistics Collector
================================================================================
  Creates: collect.memory_stats (table)
           collect.usp_CollectMemory (stored procedure)

  Source DMVs:
    sys.dm_os_memory_clerks    — buffer pool, plan cache, other clerks
    sys.dm_os_process_memory   — SQL Server process memory usage
    sys.dm_os_sys_memory       — total system memory, available memory
    sys.dm_os_sys_info         — committed_target_kb, physical_memory_kb

  Collection type: POINT-IN-TIME (no deltas — values are instantaneous)

  Key indicators:
    buffer_pool_mb              — data pages in memory (should be as large as possible)
    plan_cache_mb               — compiled plans in memory
    stolen_mb                   — memory taken from buffer pool by other clerks
    available_physical_mb       — free RAM on OS (should be > 1 GB; < 200 MB = critical)
    page_fault_count_delta      — OS page faults since last collection (non-zero = memory pressure)
    memory_utilization_pct      — SQL Server memory as % of committed target

  Pressure signals:
    buffer_pool_pressure_warning = 1 → buffer pool dropped > 10% since last snapshot
    plan_cache_pressure_warning  = 1 → plan cache dropped > 10% since last snapshot
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ── Table ──────────────────────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.memory_stats', N'U') IS NULL
BEGIN
    CREATE TABLE collect.memory_stats
    (
        collection_id          bigint         NOT NULL IDENTITY,
        collection_time        datetime2(7)   NOT NULL DEFAULT SYSDATETIME(),
        /* Memory clerks (aggregated) */
        buffer_pool_mb         decimal(19, 2) NOT NULL,
        plan_cache_mb          decimal(19, 2) NOT NULL,
        stolen_mb              decimal(19, 2) NOT NULL,   /* other clerks from buffer pool */
        other_memory_mb        decimal(19, 2) NOT NULL,   /* non-stolen non-buffer clerks */
        total_clerk_mb         decimal(19, 2) NOT NULL,
        /* Process memory */
        physical_memory_in_use_mb   decimal(19, 2) NOT NULL,
        page_fault_count            bigint        NOT NULL,
        memory_utilization_pct      int           NOT NULL,  /* 0-100 from dm_os_process_memory */
        /* System memory */
        total_physical_memory_mb    decimal(19, 2) NULL,
        available_physical_mb       decimal(19, 2) NULL,
        system_memory_state         nvarchar(256)  NULL,   /* Available, Low, etc. */
        /* Server memory targets */
        committed_target_mb         decimal(19, 2) NULL,
        max_server_memory_mb        decimal(19, 2) NULL,
        /* Pressure flags (set by comparing to previous snapshot) */
        buffer_pool_pressure_warning bit           NOT NULL DEFAULT 0,
        plan_cache_pressure_warning  bit           NOT NULL DEFAULT 0,
        /* Computed */
        buffer_pool_pct        AS (buffer_pool_mb * 100. / NULLIF(total_clerk_mb, 0)),
        plan_cache_pct         AS (plan_cache_mb  * 100. / NULLIF(total_clerk_mb, 0)),
        CONSTRAINT PK_memory_stats
            PRIMARY KEY CLUSTERED (collection_time, collection_id)
            WITH (DATA_COMPRESSION = PAGE)
    );

    PRINT 'collect.memory_stats created.';
END
ELSE
    PRINT 'collect.memory_stats already exists — skipping DDL.';
GO

/* ── Collector ──────────────────────────────────────────────────────────── */

CREATE OR ALTER PROCEDURE collect.usp_CollectMemory
    @debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @start_time           datetime2(7)   = SYSDATETIME(),
        @buffer_pool_mb       decimal(19, 2),
        @plan_cache_mb        decimal(19, 2),
        @stolen_mb            decimal(19, 2),
        @other_memory_mb      decimal(19, 2),
        @total_clerk_mb       decimal(19, 2),
        @phys_in_use_mb       decimal(19, 2),
        @page_fault_count     bigint,
        @mem_util_pct         int,
        @total_phys_mb        decimal(19, 2),
        @avail_phys_mb        decimal(19, 2),
        @sys_mem_state        nvarchar(256),
        @committed_target_mb  decimal(19, 2),
        @max_server_mb        decimal(19, 2),
        @prev_buffer_pool_mb  decimal(19, 2),
        @prev_plan_cache_mb   decimal(19, 2),
        @buffer_pressure      bit = 0,
        @plan_pressure        bit = 0;

    BEGIN TRY

        /* ── Memory clerks ──────────────────────────────────────────────── */

        SELECT
            @buffer_pool_mb  = SUM(CASE WHEN type = 'MEMORYCLERK_SQLBUFFERPOOL'
                                        THEN pages_kb / 1024. ELSE 0. END),
            @plan_cache_mb   = SUM(CASE WHEN type IN ('CACHESTORE_SQLCP', 'CACHESTORE_OBJCP')
                                        THEN pages_kb / 1024. ELSE 0. END),
            @stolen_mb       = SUM(CASE WHEN type != 'MEMORYCLERK_SQLBUFFERPOOL'
                                          AND is_buffer_pool_page = 1
                                        THEN pages_kb / 1024. ELSE 0. END),
            @other_memory_mb = SUM(CASE WHEN type NOT IN ('MEMORYCLERK_SQLBUFFERPOOL',
                                                           'CACHESTORE_SQLCP',
                                                           'CACHESTORE_OBJCP')
                                          AND (is_buffer_pool_page = 0 OR is_buffer_pool_page IS NULL)
                                        THEN pages_kb / 1024. ELSE 0. END),
            @total_clerk_mb  = SUM(pages_kb / 1024.)
        FROM sys.dm_os_memory_clerks
        OPTION (RECOMPILE);

        /* ── Process memory ─────────────────────────────────────────────── */

        SELECT
            @phys_in_use_mb  = physical_memory_in_use_kb / 1024.,
            @page_fault_count = page_fault_count,
            @mem_util_pct    = memory_utilization_percentage
        FROM sys.dm_os_process_memory
        OPTION (RECOMPILE);

        /* ── System memory ──────────────────────────────────────────────── */

        SELECT
            @total_phys_mb  = total_physical_memory_kb / 1024.,
            @avail_phys_mb  = available_physical_memory_kb / 1024.,
            @sys_mem_state  = system_memory_state_desc
        FROM sys.dm_os_sys_memory
        OPTION (RECOMPILE);

        /* ── Server memory targets ──────────────────────────────────────── */

        SELECT
            @committed_target_mb = committed_target_kb / 1024.,
            @max_server_mb       = physical_memory_kb  / 1024.  /* approximation */
        FROM sys.dm_os_sys_info
        OPTION (RECOMPILE);

        /* ── Pressure detection: compare to previous snapshot ──────────── */

        SELECT TOP 1
            @prev_buffer_pool_mb = buffer_pool_mb,
            @prev_plan_cache_mb  = plan_cache_mb
        FROM collect.memory_stats
        ORDER BY collection_time DESC;

        IF @prev_buffer_pool_mb IS NOT NULL
        BEGIN
            IF @buffer_pool_mb < @prev_buffer_pool_mb * 0.9    /* dropped > 10% */
                SET @buffer_pressure = 1;
            IF @plan_cache_mb < @prev_plan_cache_mb * 0.9
                SET @plan_pressure = 1;
        END;

        /* ── Insert ─────────────────────────────────────────────────────── */

        INSERT collect.memory_stats
        (
            buffer_pool_mb, plan_cache_mb, stolen_mb, other_memory_mb, total_clerk_mb,
            physical_memory_in_use_mb, page_fault_count, memory_utilization_pct,
            total_physical_memory_mb, available_physical_mb, system_memory_state,
            committed_target_mb, max_server_memory_mb,
            buffer_pool_pressure_warning, plan_cache_pressure_warning
        )
        VALUES
        (
            ISNULL(@buffer_pool_mb,  0),
            ISNULL(@plan_cache_mb,   0),
            ISNULL(@stolen_mb,       0),
            ISNULL(@other_memory_mb, 0),
            ISNULL(@total_clerk_mb,  0),
            ISNULL(@phys_in_use_mb,  0),
            ISNULL(@page_fault_count, 0),
            ISNULL(@mem_util_pct,     0),
            @total_phys_mb, @avail_phys_mb, @sys_mem_state,
            @committed_target_mb, @max_server_mb,
            @buffer_pressure, @plan_pressure
        );

        /* ── Purge ──────────────────────────────────────────────────────── */

        DECLARE @retention int = (SELECT CAST(setting_value AS int)
                                  FROM collect.config WHERE setting_name = 'retention_days');
        DELETE collect.memory_stats
        WHERE collection_time < DATEADD(DAY, -@retention, SYSDATETIME());

        IF @debug = 1
            PRINT CONCAT('Memory: buffer_pool=', @buffer_pool_mb, ' MB  ',
                         'plan_cache=', @plan_cache_mb, ' MB  ',
                         'avail_phys=', @avail_phys_mb, ' MB  ',
                         'pressure=', @buffer_pressure);

        INSERT collect.collection_log (collector_name, status, rows_inserted, duration_ms)
        VALUES ('usp_CollectMemory', 'SUCCESS', 1,
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log (collector_name, status, error_message, duration_ms)
        VALUES ('usp_CollectMemory', 'ERROR',
                CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));
        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CollectMemory created.';
GO
