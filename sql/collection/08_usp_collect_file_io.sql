/*
================================================================================
  08_usp_collect_file_io.sql
  Collection Framework — File I/O Statistics Collector
================================================================================
  Creates: collect.file_io_stats (table)
           collect.usp_CollectFileIo (stored procedure)

  Source DMV:  sys.dm_io_virtual_file_stats(NULL, NULL)
               joined to sys.databases + sys.master_files
  Natural key: database_id + file_id
  Delta type:  Cumulative — deltas calculated inline

  Captures per-file read/write counts, bytes, and I/O stall times.
  Use to identify which database files are under I/O pressure and whether
  stall time is read-side or write-side.

  Key analysis columns:
    io_stall_read_ms_delta  / num_of_reads_delta  = avg ms per read
    io_stall_write_ms_delta / num_of_writes_delta = avg ms per write
    io_stall_ms_per_second  = total I/O stall ms per second of sample

  Thresholds (general guidance):
    avg read stall  > 20 ms  → Warning (HDD: > 30 ms; SSD: > 5 ms)
    avg write stall > 20 ms  → Warning
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ── Table ──────────────────────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.file_io_stats', N'U') IS NULL
BEGIN
    CREATE TABLE collect.file_io_stats
    (
        collection_id          bigint        NOT NULL IDENTITY,
        collection_time        datetime2(7)  NOT NULL DEFAULT SYSDATETIME(),
        server_start_time      datetime2(7)  NOT NULL,
        /* Identity */
        database_id            int           NOT NULL,
        database_name          sysname       NULL,
        file_id                int           NOT NULL,
        file_name              sysname       NULL,
        file_type_desc         nvarchar(60)  NULL,   /* ROWS | LOG | FILESTREAM | FULLTEXT */
        physical_name          nvarchar(260) NULL,
        size_on_disk_bytes     bigint        NULL,
        /* Cumulative raw values */
        num_of_reads           bigint        NOT NULL,
        num_of_bytes_read      bigint        NOT NULL,
        io_stall_read_ms       bigint        NOT NULL,
        num_of_writes          bigint        NOT NULL,
        num_of_bytes_written   bigint        NOT NULL,
        io_stall_write_ms      bigint        NOT NULL,
        io_stall_ms            bigint        NOT NULL,
        io_stall_queued_read_ms  bigint      NULL,   /* SQL 2014+ */
        io_stall_queued_write_ms bigint      NULL,
        sample_ms              bigint        NOT NULL,  /* DMV's own sample window */
        /* Delta columns */
        num_of_reads_delta         bigint    NULL,
        num_of_bytes_read_delta    bigint    NULL,
        io_stall_read_ms_delta     bigint    NULL,
        num_of_writes_delta        bigint    NULL,
        num_of_bytes_written_delta bigint    NULL,
        io_stall_write_ms_delta    bigint    NULL,
        io_stall_ms_delta          bigint    NULL,
        sample_seconds             int       NULL,
        /* Computed helpers */
        avg_read_stall_ms   AS (io_stall_read_ms_delta  / NULLIF(num_of_reads_delta, 0)),
        avg_write_stall_ms  AS (io_stall_write_ms_delta / NULLIF(num_of_writes_delta, 0)),
        mb_read_per_sec     AS (num_of_bytes_read_delta  / NULLIF(sample_seconds, 0) / 1048576.),
        mb_written_per_sec  AS (num_of_bytes_written_delta / NULLIF(sample_seconds, 0) / 1048576.),
        io_stall_ms_per_second AS (io_stall_ms_delta / NULLIF(sample_seconds, 0)),
        CONSTRAINT PK_file_io_stats
            PRIMARY KEY CLUSTERED (collection_time, collection_id)
            WITH (DATA_COMPRESSION = PAGE)
    );

    CREATE NONCLUSTERED INDEX IX_file_io_stats_natural_key
    ON collect.file_io_stats (database_id, file_id, collection_time)
    INCLUDE (num_of_reads, num_of_bytes_read, io_stall_read_ms,
             num_of_writes, num_of_bytes_written, io_stall_write_ms,
             io_stall_ms, server_start_time, num_of_reads_delta)
    WITH (DATA_COMPRESSION = PAGE);

    PRINT 'collect.file_io_stats created.';
END
ELSE
    PRINT 'collect.file_io_stats already exists — skipping DDL.';
GO

/* ── Collector ──────────────────────────────────────────────────────────── */

CREATE OR ALTER PROCEDURE collect.usp_CollectFileIo
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

        /* ── Step 1: Insert snapshot ────────────────────────────────────── */

        INSERT collect.file_io_stats
        (
            server_start_time, database_id, database_name, file_id,
            file_name, file_type_desc, physical_name, size_on_disk_bytes,
            num_of_reads, num_of_bytes_read, io_stall_read_ms,
            num_of_writes, num_of_bytes_written, io_stall_write_ms,
            io_stall_ms, io_stall_queued_read_ms, io_stall_queued_write_ms, sample_ms
        )
        SELECT
            @server_start,
            fs.database_id,
            DB_NAME(fs.database_id),
            fs.file_id,
            mf.name,
            mf.type_desc,
            mf.physical_name,
            fs.size_on_disk_bytes,
            fs.num_of_reads,
            fs.num_of_bytes_read,
            fs.io_stall_read_ms,
            fs.num_of_writes,
            fs.num_of_bytes_written,
            fs.io_stall_write_ms,
            fs.io_stall,
            TRY_CAST(fs.io_stall_queued_read_ms  AS bigint),   /* NULL on SQL 2012 */
            TRY_CAST(fs.io_stall_queued_write_ms AS bigint),
            fs.sample_ms
        FROM sys.dm_io_virtual_file_stats(NULL, NULL) fs
        LEFT JOIN sys.master_files mf
          ON  mf.database_id = fs.database_id
          AND mf.file_id     = fs.file_id
        WHERE (fs.num_of_reads > 0 OR fs.num_of_writes > 0)
          AND fs.database_id NOT IN (2, 3)    /* model, msdb — usually uninteresting */
        OPTION (RECOMPILE);

        SET @rows_inserted = ROWCOUNT_BIG();

        /* ── Step 2: Calculate deltas ───────────────────────────────────── */

        WITH cur AS (
            SELECT *, ROW_NUMBER() OVER
                (PARTITION BY database_id, file_id ORDER BY collection_time DESC) rn
            FROM collect.file_io_stats WHERE num_of_reads_delta IS NULL
        ),
        prv AS (
            SELECT collection_id, database_id, file_id, collection_time, server_start_time,
                   num_of_reads, num_of_bytes_read, io_stall_read_ms,
                   num_of_writes, num_of_bytes_written, io_stall_write_ms, io_stall_ms,
                   ROW_NUMBER() OVER
                   (PARTITION BY database_id, file_id ORDER BY collection_time DESC) rn
            FROM collect.file_io_stats WHERE num_of_reads_delta IS NOT NULL
        )
        UPDATE c SET
            sample_seconds =
                CASE WHEN p.collection_id IS NULL THEN NULL
                     ELSE DATEDIFF(SECOND, p.collection_time, c.collection_time) END,
            num_of_reads_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.num_of_reads
                     WHEN c.server_start_time >= p.collection_time       THEN c.num_of_reads
                     WHEN c.num_of_reads >= p.num_of_reads               THEN c.num_of_reads - p.num_of_reads
                     ELSE c.num_of_reads END,
            num_of_bytes_read_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.num_of_bytes_read
                     WHEN c.server_start_time >= p.collection_time       THEN c.num_of_bytes_read
                     WHEN c.num_of_bytes_read >= p.num_of_bytes_read     THEN c.num_of_bytes_read - p.num_of_bytes_read
                     ELSE c.num_of_bytes_read END,
            io_stall_read_ms_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.io_stall_read_ms
                     WHEN c.server_start_time >= p.collection_time       THEN c.io_stall_read_ms
                     WHEN c.io_stall_read_ms >= p.io_stall_read_ms       THEN c.io_stall_read_ms - p.io_stall_read_ms
                     ELSE c.io_stall_read_ms END,
            num_of_writes_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.num_of_writes
                     WHEN c.server_start_time >= p.collection_time       THEN c.num_of_writes
                     WHEN c.num_of_writes >= p.num_of_writes             THEN c.num_of_writes - p.num_of_writes
                     ELSE c.num_of_writes END,
            num_of_bytes_written_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.num_of_bytes_written
                     WHEN c.server_start_time >= p.collection_time       THEN c.num_of_bytes_written
                     WHEN c.num_of_bytes_written >= p.num_of_bytes_written THEN c.num_of_bytes_written - p.num_of_bytes_written
                     ELSE c.num_of_bytes_written END,
            io_stall_write_ms_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.io_stall_write_ms
                     WHEN c.server_start_time >= p.collection_time       THEN c.io_stall_write_ms
                     WHEN c.io_stall_write_ms >= p.io_stall_write_ms     THEN c.io_stall_write_ms - p.io_stall_write_ms
                     ELSE c.io_stall_write_ms END,
            io_stall_ms_delta =
                CASE WHEN p.collection_id IS NULL                        THEN c.io_stall_ms
                     WHEN c.server_start_time >= p.collection_time       THEN c.io_stall_ms
                     WHEN c.io_stall_ms >= p.io_stall_ms                 THEN c.io_stall_ms - p.io_stall_ms
                     ELSE c.io_stall_ms END
        FROM cur c
        LEFT JOIN prv p
          ON  p.database_id = c.database_id
          AND p.file_id     = c.file_id
          AND p.rn = 1
        WHERE c.rn = 1
        OPTION (RECOMPILE);

        /* ── Step 3: Purge ──────────────────────────────────────────────── */

        DECLARE @retention int = (SELECT CAST(setting_value AS int)
                                  FROM collect.config WHERE setting_name = 'retention_days');
        DELETE collect.file_io_stats
        WHERE collection_time < DATEADD(DAY, -@retention, SYSDATETIME());

        IF @debug = 1
            PRINT CONCAT('File I/O rows inserted: ', @rows_inserted);

        INSERT collect.collection_log (collector_name, status, rows_inserted, duration_ms)
        VALUES ('usp_CollectFileIo', 'SUCCESS', @rows_inserted,
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log (collector_name, status, error_message, duration_ms)
        VALUES ('usp_CollectFileIo', 'ERROR',
                CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
                DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));
        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CollectFileIo created.';
GO
