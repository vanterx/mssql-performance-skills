/*
================================================================================
  11_usp_collect_all.sql
  Collection Framework — Master Collector
================================================================================
  Creates: collect.usp_CollectAll

  Calls every individual collector in isolation (TRY/CATCH per collector).
  One collector failure does not abort the others.
  All results logged to collect.collection_log.

  This is the procedure called by the SQL Agent job (05_create_agent_job.sql).
  To run manually:
    EXECUTE collect.usp_CollectAll;
    EXECUTE collect.usp_CollectAll @debug = 1;

  Execution order and frequency:
    Every run:    wait_stats, file_io, memory, perf_counters, proc_stats, query_stats
    The Agent job controls the schedule (default 5 minutes via collect.config).
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE collect.usp_CollectAll
    @debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @start_time datetime2(7) = SYSDATETIME(),
        @collectors TABLE (name sysname, seq int);

    INSERT @collectors (name, seq) VALUES
        ('usp_CollectWaitStats',    1),
        ('usp_CollectFileIo',       2),
        ('usp_CollectMemory',       3),
        ('usp_CollectPerfCounters', 4),
        ('usp_CollectProcStats',    5),
        ('usp_CollectQueryStats',   6);

    DECLARE
        @name sysname,
        @sql  nvarchar(256);

    DECLARE collector_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM @collectors ORDER BY seq;

    OPEN collector_cursor;
    FETCH NEXT FROM collector_cursor INTO @name;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = CONCAT(N'EXECUTE collect.', @name,
                              CASE WHEN @debug = 1 THEN N' @debug = 1' ELSE N'' END);
            EXECUTE sys.sp_executesql @sql;

            IF @debug = 1
                PRINT CONCAT(@name, ' completed OK');
        END TRY
        BEGIN CATCH
            /* Log the failure — already done inside each collector — and continue */
            IF @debug = 1
                PRINT CONCAT(@name, ' FAILED: ', ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM collector_cursor INTO @name;
    END;

    CLOSE collector_cursor;
    DEALLOCATE collector_cursor;

    IF @debug = 1
        PRINT CONCAT('usp_CollectAll finished in ',
                     DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()), ' ms');
END;
GO

/* Update the Agent job step to call usp_CollectAll instead of usp_CollectProcStats */
/* (Re-run 05_create_agent_job.sql or update the step manually in SSMS)            */

PRINT 'collect.usp_CollectAll created.';
PRINT '';
PRINT 'Update your Agent job step command to:';
PRINT '  EXECUTE collect.usp_CollectAll;';
GO
