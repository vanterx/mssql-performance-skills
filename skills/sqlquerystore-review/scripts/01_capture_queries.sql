/*
================================================================================
  skills/query-store-review/scripts/01_capture_queries.sql
  Query Store Capture Queries for /query-store-review
================================================================================
  Run these queries INSIDE the user database (USE YourDatabase first).
  Paste any combination of result sets into Claude and run: /query-store-review

  Queries:
    Query A — Top resource consumers (required — feeds Q1–Q18 checks)
    Query B — Wait stats per query (SQL 2017+ — feeds Q19–Q22 checks)
    Query C — Query Store configuration health (required — feeds Q23–Q25 checks)
    Query D — Regressed queries (optional — feeds Q1–Q6 regression checks)

  How to use:
    1. Connect to the database you want to analyze
    2. Run Query A and optionally B/C/D
    3. Paste all result sets into one message to Claude
    4. Run /query-store-review

  Adjust @start_date / @end_date to your observation window.
  Default: last 7 days.
================================================================================
*/

/* ── Change to target database first ──────────────────────────────────── */
/* USE [YourDatabase]; */
GO

/* ============================================================================
   QUERY A — Top Resource Consumers
   Required. Feeds Q7–Q18 checks (plan instability, resource hotspots,
   high frequency, high reads, high duration, memory grants, exceptions).
   ============================================================================ */

DECLARE @start_date datetimeoffset = DATEADD(DAY, -7, GETUTCDATE());
DECLARE @end_date   datetimeoffset = GETUTCDATE();
DECLARE @top_n      int            = 20;

SELECT TOP (@top_n)
    database_name                  = DB_NAME(),
    query_sql_text                 = TRY_CAST(qt.query_sql_text AS nvarchar(200)),
    object_name                    = OBJECT_NAME(q.object_id),
    query_id                       = q.query_id,
    query_hash                     = q.query_hash,
    plan_count                     = COUNT(DISTINCT p.plan_id),
    total_executions               = SUM(rs.count_executions),
    avg_duration_ms                = SUM(rs.avg_duration)        / NULLIF(SUM(rs.count_executions), 0) / 1000.0,
    avg_cpu_ms                     = SUM(rs.avg_cpu_time)        / NULLIF(SUM(rs.count_executions), 0) / 1000.0,
    avg_logical_reads              = SUM(rs.avg_logical_io_reads) / NULLIF(SUM(rs.count_executions), 0),
    avg_physical_reads             = SUM(rs.avg_physical_io_reads) / NULLIF(SUM(rs.count_executions), 0),
    avg_logical_writes             = SUM(rs.avg_logical_io_writes) / NULLIF(SUM(rs.count_executions), 0),
    avg_memory_grant_mb            = SUM(rs.avg_query_max_used_memory) / NULLIF(SUM(rs.count_executions), 0) * 8.0 / 1024.0,
    max_duration_ms                = MAX(rs.max_duration) / 1000.0,
    min_duration_ms                = MIN(rs.min_duration) / 1000.0,
    max_cpu_ms                     = MAX(rs.max_cpu_time) / 1000.0,
    min_cpu_ms                     = MIN(rs.min_cpu_time) / 1000.0,
    last_execution_time            = MAX(rs.last_execution_time),
    is_forced_plan                 = MAX(CASE WHEN p.is_forced_plan = 1 THEN 1 ELSE 0 END),
    force_failure_count            = MAX(p.force_failure_count),
    last_force_failure_reason_desc = MAX(p.last_force_failure_reason_desc),
    aborted_count                  = SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END),
    exception_count                = SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END),
    avg_tempdb_mb                  = TRY_CAST(
                                         SUM(rs.avg_tempdb_space_used)
                                         / NULLIF(SUM(rs.count_executions), 0) * 8.0 / 1024.0
                                         AS decimal(18, 2))   /* NULL on SQL 2016 */
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt
  ON q.query_text_id    = qt.query_text_id
JOIN sys.query_store_plan AS p
  ON q.query_id         = p.query_id
JOIN sys.query_store_runtime_stats AS rs
  ON p.plan_id          = rs.plan_id
WHERE rs.last_execution_time >= @start_date
  AND rs.last_execution_time <  @end_date
  AND rs.execution_type IN (0, 3, 4)   /* 0=regular, 3=aborted (client-initiated), 4=exception */
GROUP BY qt.query_sql_text, q.query_id, q.query_hash, q.object_id
HAVING SUM(rs.count_executions) > 0
ORDER BY SUM(rs.avg_cpu_time * rs.count_executions) DESC;
GO

/* ============================================================================
   QUERY B — Wait Stats Per Query  (SQL Server 2017+)
   Optional. Feeds Q19–Q22 checks (dominant wait category per query).
   Skip on SQL 2016 — sys.query_store_wait_stats does not exist.
   ============================================================================ */

BEGIN TRY
    SELECT TOP 30
        database_name       = DB_NAME(),
        wait_category_desc  = ws.wait_category_desc,
        query_sql_text      = TRY_CAST(qt.query_sql_text AS nvarchar(200)),
        query_hash          = q.query_hash,
        total_wait_time_ms  = SUM(ws.total_query_wait_time_ms),
        avg_wait_time_ms    = AVG(ws.avg_query_wait_time_ms),
        total_executions    = SUM(rs.count_executions)
    FROM sys.query_store_wait_stats AS ws
    JOIN sys.query_store_plan AS p
      ON ws.plan_id        = p.plan_id
    JOIN sys.query_store_query AS q
      ON p.query_id        = q.query_id
    JOIN sys.query_store_query_text AS qt
      ON q.query_text_id   = qt.query_text_id
    JOIN sys.query_store_runtime_stats AS rs
      ON p.plan_id         = rs.plan_id
    WHERE ws.last_execution_time >= DATEADD(DAY, -7, GETUTCDATE())
    GROUP BY ws.wait_category_desc, qt.query_sql_text, q.query_hash
    ORDER BY total_wait_time_ms DESC;
END TRY
BEGIN CATCH
    SELECT 'Query B skipped — sys.query_store_wait_stats requires SQL Server 2017+' AS note;
END CATCH;
GO

/* ============================================================================
   QUERY C — Query Store Configuration Health
   Required. Feeds Q23–Q25 checks (storage near limit, capture mode,
   wait stats enabled, desired vs actual state).
   ============================================================================ */

SELECT
    database_name              = DB_NAME(),
    desired_state_desc,
    actual_state_desc,
    readonly_reason,
    current_storage_size_mb,
    max_storage_size_mb,
    storage_pct_used           = CAST(100.0 * current_storage_size_mb
                                      / NULLIF(max_storage_size_mb, 0) AS decimal(5,1)),
    flush_interval_seconds,
    interval_length_minutes,
    max_plans_per_query,
    stale_query_threshold_days,
    size_based_cleanup_mode_desc,
    query_capture_mode_desc,
    wait_stats_capture_mode_desc
FROM sys.database_query_store_options;
GO

/* ============================================================================
   QUERY D — Regressed Queries (two-period comparison)
   Optional. Feeds Q1–Q6 regression checks. Compares a baseline period
   to a current period and surfaces queries that got significantly slower.

   Adjust the date ranges:
     @baseline_start / @baseline_end = a known-good period
     @current_start  / @current_end  = the period under investigation
   ============================================================================ */

DECLARE
    @baseline_start datetimeoffset = DATEADD(DAY, -14, GETUTCDATE()),
    @baseline_end   datetimeoffset = DATEADD(DAY, -7,  GETUTCDATE()),
    @current_start  datetimeoffset = DATEADD(DAY, -7,  GETUTCDATE()),
    @current_end    datetimeoffset = GETUTCDATE();

WITH baseline AS (
    SELECT
        q.query_id,
        q.query_hash,
        object_name             = OBJECT_NAME(q.object_id),
        query_sql_text          = TRY_CAST(qt.query_sql_text AS nvarchar(200)),
        baseline_executions     = SUM(rs.count_executions),
        baseline_avg_duration   = SUM(rs.avg_duration * rs.count_executions)
                                  / NULLIF(SUM(rs.count_executions), 0),
        baseline_avg_cpu        = SUM(rs.avg_cpu_time * rs.count_executions)
                                  / NULLIF(SUM(rs.count_executions), 0),
        baseline_avg_reads      = SUM(rs.avg_logical_io_reads * rs.count_executions)
                                  / NULLIF(SUM(rs.count_executions), 0)
    FROM sys.query_store_query AS q
    JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
    JOIN sys.query_store_plan       AS p  ON q.query_id      = p.query_id
    JOIN sys.query_store_runtime_stats AS rs ON p.plan_id   = rs.plan_id
    WHERE rs.last_execution_time >= @baseline_start
      AND rs.last_execution_time <  @baseline_end
    GROUP BY q.query_id, q.query_hash, q.object_id, qt.query_sql_text
    HAVING SUM(rs.count_executions) >= 5
),
current_period AS (
    SELECT
        q.query_id,
        current_executions      = SUM(rs.count_executions),
        current_avg_duration    = SUM(rs.avg_duration * rs.count_executions)
                                  / NULLIF(SUM(rs.count_executions), 0),
        current_avg_cpu         = SUM(rs.avg_cpu_time * rs.count_executions)
                                  / NULLIF(SUM(rs.count_executions), 0),
        current_avg_reads       = SUM(rs.avg_logical_io_reads * rs.count_executions)
                                  / NULLIF(SUM(rs.count_executions), 0),
        plan_count_current      = COUNT(DISTINCT p.plan_id)
    FROM sys.query_store_query AS q
    JOIN sys.query_store_plan  AS p  ON q.query_id  = p.query_id
    JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
    WHERE rs.last_execution_time >= @current_start
      AND rs.last_execution_time <  @current_end
    GROUP BY q.query_id
    HAVING SUM(rs.count_executions) >= 5
)
SELECT TOP 20
    database_name        = DB_NAME(),
    b.query_id,
    b.query_hash,
    b.object_name,
    b.query_sql_text,
    b.baseline_executions,
    c.current_executions,
    baseline_avg_duration_ms  = b.baseline_avg_duration / 1000.0,
    current_avg_duration_ms   = c.current_avg_duration  / 1000.0,
    duration_ratio            = CAST(c.current_avg_duration / NULLIF(b.baseline_avg_duration, 0) AS decimal(8,2)),
    baseline_avg_cpu_ms       = b.baseline_avg_cpu / 1000.0,
    current_avg_cpu_ms        = c.current_avg_cpu  / 1000.0,
    cpu_ratio                 = CAST(c.current_avg_cpu / NULLIF(b.baseline_avg_cpu, 0) AS decimal(8,2)),
    baseline_avg_reads        = b.baseline_avg_reads,
    current_avg_reads         = c.current_avg_reads,
    reads_ratio               = CAST(c.current_avg_reads / NULLIF(b.baseline_avg_reads, 0) AS decimal(8,2)),
    plan_count_current        = c.plan_count_current
FROM baseline b
JOIN current_period c ON c.query_id = b.query_id
WHERE c.current_avg_duration > b.baseline_avg_duration * 2.0   /* 2× or worse */
   OR c.current_avg_cpu      > b.baseline_avg_cpu      * 2.0
   OR c.current_avg_reads    > b.baseline_avg_reads    * 2.0
ORDER BY duration_ratio DESC;
GO
