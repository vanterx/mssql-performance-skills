/*
================================================================================
  skills/sqlworkload-compare/scripts/capture-workload-windows.sql
  Two-window workload comparison input for /sqlworkload-compare
================================================================================
  Run in the database being compared. Read-only: SELECT statements only.

  Part 1 aggregates Query Store runtime statistics by query_hash for a baseline
  window and a current window, side by side, one row per query_hash that ran in
  either window (a full outer match by construction - nothing is dropped
  because it ranked low on one side). Weighted averages, per-minute rates and
  totals are all returned so the skill can normalise windows of different
  length.

  Part 2 snapshots the configuration the comparison checks read (WC11-WC13):
  server properties, cpu_count and memory, sys.configurations, the database's
  options and its database-scoped configurations. Query Store keeps history;
  these views do not. For a before-and-after change on one instance, run
  Part 2 before the change as well, and paste both.

  Part 3 snapshots sys.dm_os_wait_stats with a timestamp (WC14). Wait totals
  are cumulative since startup, so run it at the start and the end of each
  window you are capturing live; it cannot reconstruct a past window.

  Set the four window variables below. Align them to the Query Store interval
  (sys.database_query_store_options.interval_length_minutes, 60 by default):
  an interval that only partly overlaps a window is excluded.

  Requires: VIEW DATABASE STATE in the target database (SQL Server 2019 and
  earlier) or VIEW DATABASE PERFORMANCE STATE (SQL Server 2022 and later) for
  Query Store and the database-scoped configurations; VIEW SERVER STATE or
  VIEW SERVER PERFORMANCE STATE (2022 and later) for sys.dm_os_sys_info and
  sys.dm_os_wait_stats. SQL Server 2016 or later with Query Store on for Part 1.
================================================================================
*/

SET NOCOUNT ON;

DECLARE @baseline_start datetimeoffset = '2026-10-05T09:00:00+13:00';
DECLARE @baseline_end   datetimeoffset = '2026-10-05T10:00:00+13:00';
DECLARE @current_start  datetimeoffset = '2026-10-06T09:00:00+13:00';
DECLARE @current_end    datetimeoffset = '2026-10-06T10:00:00+13:00';

/* ── Part 1: per-query_hash statistics for both windows ───────────────────── */

PRINT '-- Part 1: Query Store, baseline vs current, by query_hash';

WITH runtime AS
(
    SELECT
        q.query_hash,
        CASE
            WHEN i.start_time >= @baseline_start AND i.end_time <= @baseline_end THEN 'baseline'
            WHEN i.start_time >= @current_start  AND i.end_time <= @current_end  THEN 'current'
        END                                         AS side,
        rs.execution_type,
        rs.count_executions,
        rs.avg_duration,
        rs.max_duration,
        rs.avg_cpu_time,
        rs.avg_logical_io_reads
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i
        ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query AS q
        ON q.query_id = p.query_id
),
by_hash AS
(
    SELECT
        query_hash,
        /* regular executions only (execution_type 0) for cost; aborted (3) counted separately */
        SUM(CASE WHEN side = 'baseline' AND execution_type = 0 THEN count_executions END)                        AS b_execs,
        SUM(CASE WHEN side = 'baseline' AND execution_type = 0 THEN avg_duration * count_executions END)         AS b_duration_us,
        MAX(CASE WHEN side = 'baseline' AND execution_type = 0 THEN max_duration END)                            AS b_max_duration_us,
        SUM(CASE WHEN side = 'baseline' AND execution_type = 0 THEN avg_cpu_time * count_executions END)         AS b_cpu_us,
        SUM(CASE WHEN side = 'baseline' AND execution_type = 0 THEN avg_logical_io_reads * count_executions END) AS b_reads,
        SUM(CASE WHEN side = 'baseline' AND execution_type = 3 THEN count_executions END)                        AS b_aborted,
        SUM(CASE WHEN side = 'current'  AND execution_type = 0 THEN count_executions END)                        AS c_execs,
        SUM(CASE WHEN side = 'current'  AND execution_type = 0 THEN avg_duration * count_executions END)         AS c_duration_us,
        MAX(CASE WHEN side = 'current'  AND execution_type = 0 THEN max_duration END)                            AS c_max_duration_us,
        SUM(CASE WHEN side = 'current'  AND execution_type = 0 THEN avg_cpu_time * count_executions END)         AS c_cpu_us,
        SUM(CASE WHEN side = 'current'  AND execution_type = 0 THEN avg_logical_io_reads * count_executions END) AS c_reads,
        SUM(CASE WHEN side = 'current'  AND execution_type = 3 THEN count_executions END)                        AS c_aborted
    FROM runtime
    WHERE side IS NOT NULL
    GROUP BY query_hash
)
SELECT
    h.query_hash,
    CASE
        WHEN h.b_execs > 0 AND h.c_execs > 0 THEN 'both'
        WHEN h.b_execs > 0                   THEN 'baseline only'
        ELSE                                      'current only'
    END                                                                      AS presence,
    h.b_execs                                                                AS baseline_execs,
    h.c_execs                                                                AS current_execs,
    CAST(h.b_duration_us / NULLIF(h.b_execs, 0) / 1000.0 AS decimal(18,2))   AS baseline_avg_duration_ms,
    CAST(h.c_duration_us / NULLIF(h.c_execs, 0) / 1000.0 AS decimal(18,2))   AS current_avg_duration_ms,
    CAST(h.b_max_duration_us / 1000.0 AS decimal(18,2))                      AS baseline_max_duration_ms,
    CAST(h.c_max_duration_us / 1000.0 AS decimal(18,2))                      AS current_max_duration_ms,
    CAST(h.b_cpu_us / NULLIF(h.b_execs, 0) / 1000.0 AS decimal(18,2))        AS baseline_avg_cpu_ms,
    CAST(h.c_cpu_us / NULLIF(h.c_execs, 0) / 1000.0 AS decimal(18,2))        AS current_avg_cpu_ms,
    CAST(h.b_reads / NULLIF(h.b_execs, 0) AS decimal(18,1))                  AS baseline_avg_reads,
    CAST(h.c_reads / NULLIF(h.c_execs, 0) AS decimal(18,1))                  AS current_avg_reads,
    CAST(h.b_duration_us / 1000.0 AS decimal(18,0))                          AS baseline_total_duration_ms,
    CAST(h.c_duration_us / 1000.0 AS decimal(18,0))                          AS current_total_duration_ms,
    CAST(h.b_execs * 1.0 / NULLIF(DATEDIFF(MINUTE, @baseline_start, @baseline_end), 0) AS decimal(18,2)) AS baseline_execs_per_min,
    CAST(h.c_execs * 1.0 / NULLIF(DATEDIFF(MINUTE, @current_start,  @current_end),  0) AS decimal(18,2)) AS current_execs_per_min,
    h.b_aborted                                                              AS baseline_aborted,
    h.c_aborted                                                              AS current_aborted,
    LEFT(t.query_sql_text, 200)                                              AS sample_text
FROM by_hash AS h
OUTER APPLY
(
    SELECT TOP (1) qt.query_sql_text
    FROM sys.query_store_query AS q
    JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q.query_text_id
    WHERE q.query_hash = h.query_hash
    ORDER BY q.query_id DESC
) AS t
WHERE COALESCE(h.b_execs, 0) + COALESCE(h.c_execs, 0) > 0
ORDER BY COALESCE(h.c_duration_us, 0) + COALESCE(h.b_duration_us, 0) DESC;

PRINT '-- Window lengths in minutes (baseline, current)';
SELECT
    DATEDIFF(MINUTE, @baseline_start, @baseline_end) AS baseline_minutes,
    DATEDIFF(MINUTE, @current_start,  @current_end)  AS current_minutes;

PRINT '-- Query Store state (capture mode AUTO can skip queries on one side - WC1/WC5)';
SELECT actual_state_desc, query_capture_mode_desc, interval_length_minutes
FROM sys.database_query_store_options;

/* ── Part 2: configuration snapshot (WC11-WC13) ───────────────────────────── */

PRINT '';
PRINT '-- Part 2a: server properties and capacity (WC12)';
SELECT
    SYSDATETIMEOFFSET()                      AS captured_at,
    SERVERPROPERTY('ProductVersion')         AS product_version,
    SERVERPROPERTY('ProductLevel')           AS product_level,
    SERVERPROPERTY('ProductUpdateLevel')     AS product_update_level,
    SERVERPROPERTY('Edition')                AS edition,
    si.cpu_count,
    si.physical_memory_kb
FROM sys.dm_os_sys_info AS si;

PRINT '-- Part 2b: sys.configurations value_in_use (WC11)';
SELECT name, value_in_use
FROM sys.configurations
ORDER BY name;

PRINT '-- Part 2c: database options for the current database (WC13)';
SELECT
    name,
    compatibility_level,
    is_read_committed_snapshot_on,
    snapshot_isolation_state_desc,
    is_auto_create_stats_on,
    is_auto_update_stats_on,
    is_auto_update_stats_async_on,
    is_parameterization_forced,
    page_verify_option_desc
FROM sys.databases
WHERE database_id = DB_ID();

PRINT '-- Part 2d: database-scoped configurations for the current database (WC13)';
SELECT name, value, value_for_secondary
FROM sys.database_scoped_configurations
ORDER BY name;

/* ── Part 3: wait statistics snapshot (WC14) ──────────────────────────────── */

PRINT '';
PRINT '-- Part 3: wait statistics snapshot - run at the start and end of a live window';
SELECT
    SYSDATETIMEOFFSET() AS captured_at,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_time_ms > 0
ORDER BY wait_time_ms DESC;
