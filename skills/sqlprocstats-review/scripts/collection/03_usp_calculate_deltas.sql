/*
================================================================================
  03_usp_calculate_deltas.sql
  Procedure Stats Collection Framework — Delta Calculator
================================================================================
  Creates: collect.usp_CalculateProcStatsDeltas

  Called automatically by usp_CollectProcStats immediately after each INSERT.
  Can also be run manually to reprocess any rows where delta columns are NULL.

  Delta calculation logic (per-metric CASE expression):

    Case 1 — First collection (prev IS NULL):
      Delta = raw cumulative value.
      Rationale: no baseline exists; treat the entire history-to-now as the delta.

    Case 2 — Server restarted since previous collection
             (server_start_time >= previous collection_time):
      Delta = raw cumulative value.
      Rationale: all DMV counters reset to zero on restart; the new value IS the delta.

    Case 3 — Counter decreased (plan evicted and re-cached, or counter wrapped):
      Delta = raw cumulative value (conservative estimate).
      Rationale: we cannot know the true delta; use current value to avoid negative deltas.

    Case 4 — Normal:
      Delta = current - previous.

  Natural key:  (database_name, object_id, plan_handle)
  Matches a compiled plan for a specific object in a specific database.
  A new plan_handle appears on recompile or cache eviction.

  sample_seconds:
    If prev exists → DATEDIFF(SECOND, prev.collection_time, current.collection_time)
    If no prev     → DATEDIFF(SECOND, cached_time, last_execution_time)
    Used to calculate per-second rates (worker_time_per_sec, reads_per_sec).
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE collect.usp_CalculateProcStatsDeltas
    @debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @start_time    datetime2(7) = SYSDATETIME(),
        @rows_updated  int          = 0;

    BEGIN TRY

        /* ── Update only rows where delta columns are still NULL ────────── */
        /* Those are the rows just inserted by usp_CollectProcStats.         */
        /* Rows with existing deltas are already processed — skip them.      */

        WITH current_snap AS
        (
            SELECT
                collection_id,
                collection_time,
                server_start_time,
                database_name,
                object_id,
                plan_handle,
                cached_time,
                last_execution_time,
                execution_count,
                total_worker_time,
                total_elapsed_time,
                total_logical_reads,
                total_physical_reads,
                total_logical_writes,
                ROW_NUMBER() OVER
                (
                    PARTITION BY database_name, object_id, plan_handle
                    ORDER BY     collection_time DESC
                ) AS rn
            FROM collect.proc_stats
            WHERE execution_count_delta IS NULL   /* unprocessed */
        ),
        prev_snap AS
        (
            SELECT
                collection_id,
                collection_time,
                server_start_time,
                database_name,
                object_id,
                plan_handle,
                execution_count,
                total_worker_time,
                total_elapsed_time,
                total_logical_reads,
                total_physical_reads,
                total_logical_writes,
                ROW_NUMBER() OVER
                (
                    PARTITION BY database_name, object_id, plan_handle
                    ORDER BY     collection_time DESC
                ) AS rn
            FROM collect.proc_stats
            WHERE execution_count_delta IS NOT NULL  /* already processed */
        )
        UPDATE c
        SET
            /* ── sample_seconds ─────────────────────────────────────────── */
            sample_seconds =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN DATEDIFF(SECOND, c.cached_time, c.last_execution_time)
                    ELSE DATEDIFF(SECOND, p.collection_time, c.collection_time)
                END,

            /* ── execution_count_delta ──────────────────────────────────── */
            execution_count_delta =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN c.execution_count
                    WHEN c.server_start_time >= p.collection_time
                    THEN c.execution_count
                    WHEN c.execution_count >= p.execution_count
                    THEN c.execution_count - p.execution_count
                    ELSE c.execution_count
                END,

            /* ── total_worker_time_delta ─────────────────────────────────── */
            total_worker_time_delta =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN c.total_worker_time
                    WHEN c.server_start_time >= p.collection_time
                    THEN c.total_worker_time
                    WHEN c.total_worker_time >= p.total_worker_time
                    THEN c.total_worker_time - p.total_worker_time
                    ELSE c.total_worker_time
                END,

            /* ── total_elapsed_time_delta ─────────────────────────────────── */
            total_elapsed_time_delta =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN c.total_elapsed_time
                    WHEN c.server_start_time >= p.collection_time
                    THEN c.total_elapsed_time
                    WHEN c.total_elapsed_time >= p.total_elapsed_time
                    THEN c.total_elapsed_time - p.total_elapsed_time
                    ELSE c.total_elapsed_time
                END,

            /* ── total_logical_reads_delta ────────────────────────────────── */
            total_logical_reads_delta =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN c.total_logical_reads
                    WHEN c.server_start_time >= p.collection_time
                    THEN c.total_logical_reads
                    WHEN c.total_logical_reads >= p.total_logical_reads
                    THEN c.total_logical_reads - p.total_logical_reads
                    ELSE c.total_logical_reads
                END,

            /* ── total_physical_reads_delta ──────────────────────────────── */
            total_physical_reads_delta =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN c.total_physical_reads
                    WHEN c.server_start_time >= p.collection_time
                    THEN c.total_physical_reads
                    WHEN c.total_physical_reads >= p.total_physical_reads
                    THEN c.total_physical_reads - p.total_physical_reads
                    ELSE c.total_physical_reads
                END,

            /* ── total_logical_writes_delta ──────────────────────────────── */
            total_logical_writes_delta =
                CASE
                    WHEN p.collection_id IS NULL
                    THEN c.total_logical_writes
                    WHEN c.server_start_time >= p.collection_time
                    THEN c.total_logical_writes
                    WHEN c.total_logical_writes >= p.total_logical_writes
                    THEN c.total_logical_writes - p.total_logical_writes
                    ELSE c.total_logical_writes
                END

        FROM current_snap c
        LEFT JOIN prev_snap p
          ON  p.database_name = c.database_name
          AND p.object_id     = c.object_id
          AND p.plan_handle   = c.plan_handle
          AND p.rn            = 1   /* most recent processed row for this key */
        WHERE c.rn = 1              /* most recent unprocessed row for this key */
        OPTION (RECOMPILE, HASH JOIN, HASH GROUP);

        SET @rows_updated = ROWCOUNT_BIG();

        IF @debug = 1
            PRINT CONCAT('Delta rows updated: ', @rows_updated,
                         '  (', DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()), ' ms)');

        INSERT collect.collection_log
            (collector_name, status, rows_inserted, duration_ms)
        VALUES
            (N'usp_CalculateProcStatsDeltas', N'SUCCESS', @rows_updated,
             DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

    END TRY
    BEGIN CATCH
        INSERT collect.collection_log
            (collector_name, status, error_message, duration_ms)
        VALUES
            (N'usp_CalculateProcStatsDeltas', N'ERROR',
             CONCAT(ERROR_MESSAGE(), ' (Line ', ERROR_LINE(), ')'),
             DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()));

        THROW;
    END CATCH;
END;
GO

PRINT 'collect.usp_CalculateProcStatsDeltas created. Run 04_report_queries.sql next.';
GO
