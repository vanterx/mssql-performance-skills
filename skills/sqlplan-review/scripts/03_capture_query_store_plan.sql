/*
================================================================================
  skills/sqlplan-review/scripts/03_capture_query_store_plan.sql
  Extract Plan XML from Query Store for /sqlplan-review and /sqlplan-compare
================================================================================
  Query Store retains historical plans even after cache eviction.
  Use this to retrieve plans for queries that are no longer in the plan cache.

  Particularly useful for:
    /sqlplan-compare — pass two plan XMLs (baseline plan + regressed plan)
    /sqlplan-review  — analyze the specific plan that caused a performance incident

  Run inside the target user database.
================================================================================
*/

/* ── Change to target database first ──────────────────────────────────── */
/* USE [YourDatabase]; */
GO

/* ============================================================================
   A — Get plans for a specific query (by query_id from query-store review)
   ============================================================================ */

DECLARE @query_id bigint = 42;   /* from Query A / Query D output of 01_capture_queries.sql */

SELECT
    p.plan_id,
    p.plan_type_desc,
    p.is_forced_plan,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    p.compatibility_level,
    first_execution = rs.first_execution_time,
    last_execution  = rs.last_execution_time,
    total_executions = rs.count_executions,
    avg_duration_ms  = rs.avg_duration / 1000.0,
    avg_cpu_ms       = rs.avg_cpu_time / 1000.0,
    avg_logical_reads = rs.avg_logical_io_reads,
    query_plan       = TRY_CAST(p.query_plan AS xml)   /* paste into /sqlplan-review */
FROM sys.query_store_plan AS p
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE p.query_id = @query_id
ORDER BY rs.last_execution_time DESC;

/* ============================================================================
   B — Get baseline + regressed plan pair for /sqlplan-compare
   Run this after identifying a regression in query-store 01_capture_queries.sql Query D.
   Returns two rows: the best plan and the worst plan for the same query.
   ============================================================================ */
/*
DECLARE @query_id bigint = 42;

-- Best plan (lowest avg duration)
SELECT TOP 1
    'BASELINE'  AS plan_role,
    p.plan_id,
    p.is_forced_plan,
    avg_duration_ms = rs.avg_duration / 1000.0,
    avg_cpu_ms      = rs.avg_cpu_time / 1000.0,
    query_plan      = TRY_CAST(p.query_plan AS xml)  -- save as baseline.sqlplan
FROM sys.query_store_plan AS p
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE p.query_id = @query_id
ORDER BY rs.avg_duration ASC;

-- Worst plan (highest avg duration)
SELECT TOP 1
    'REGRESSION' AS plan_role,
    p.plan_id,
    p.is_forced_plan,
    avg_duration_ms = rs.avg_duration / 1000.0,
    avg_cpu_ms      = rs.avg_cpu_time / 1000.0,
    query_plan      = TRY_CAST(p.query_plan AS xml)  -- save as regression.sqlplan
FROM sys.query_store_plan AS p
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE p.query_id = @query_id
ORDER BY rs.avg_duration DESC;
*/

/* ============================================================================
   C — Force / unforce a plan (use after /sqlplan-compare identifies the good plan)
   ============================================================================ */
/*
-- Force a specific plan (replace bad plan with known-good plan):
EXEC sys.sp_query_store_force_plan
    @query_id = 42,
    @plan_id  = 18;   -- the plan_id of the baseline plan

-- Unforce when the root cause is fixed (statistics updated, index added):
EXEC sys.sp_query_store_unforce_plan
    @query_id = 42,
    @plan_id  = 18;
*/
