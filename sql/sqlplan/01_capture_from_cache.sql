/*
================================================================================
  sql/sqlplan/01_capture_from_cache.sql
  Capture Execution Plans from Plan Cache for /sqlplan-review
================================================================================
  Retrieves .sqlplan XML from sys.dm_exec_cached_plans without needing SSMS.
  Three capture methods:

    A — By stored procedure / object name  → best for procstats-review findings
    B — By query text fragment             → best for ad-hoc SQL
    C — By query_hash                      → best for tracking a specific query

  After running, copy the query_plan XML column value and either:
    a) Paste directly into Claude: /sqlplan-review [paste XML]
    b) Save as a .sqlplan file and reference by path: /sqlplan-review path/to/file.sqlplan

  To save as file from SSMS: right-click the XML hyperlink → Save As → .sqlplan
================================================================================
*/

/* ============================================================================
   METHOD A — Capture plan by object (stored procedure / trigger / function) name
   ============================================================================ */

DECLARE
    @schema_name  sysname = N'dbo',
    @object_name  sysname = N'usp_GetOrders';  /* change to target procedure */

SELECT
    cached_plan_type   = cp.objtype,
    plan_creation_time = cp.creation_time,
    last_execution     = qs.last_execution_time,
    execution_count    = qs.execution_count,
    avg_cpu_ms         = qs.total_worker_time   / NULLIF(qs.execution_count, 0) / 1000.,
    avg_logical_reads  = qs.total_logical_reads / NULLIF(qs.execution_count, 0),
    sql_text           = SUBSTRING(st.text,
                             qs.statement_start_offset / 2 + 1,
                             CASE WHEN qs.statement_end_offset = -1
                                  THEN LEN(st.text)
                                  ELSE (qs.statement_end_offset - qs.statement_start_offset) / 2 + 1
                             END),
    query_plan         = qp.query_plan   /* copy this XML into /sqlplan-review */
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
JOIN sys.dm_exec_query_stats AS qs
  ON qs.plan_handle = cp.plan_handle
WHERE st.objectid = OBJECT_ID(QUOTENAME(@schema_name) + '.' + QUOTENAME(@object_name))
ORDER BY qs.total_worker_time DESC;

/* ============================================================================
   METHOD B — Capture plan by query text fragment
   ============================================================================ */
/*
SELECT TOP 10
    cached_plan_type   = cp.objtype,
    plan_creation_time = cp.creation_time,
    last_execution     = qs.last_execution_time,
    execution_count    = qs.execution_count,
    avg_cpu_ms         = qs.total_worker_time   / NULLIF(qs.execution_count, 0) / 1000.,
    avg_logical_reads  = qs.total_logical_reads / NULLIF(qs.execution_count, 0),
    sql_text           = LEFT(st.text, 300),
    query_plan         = qp.query_plan
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
JOIN sys.dm_exec_query_stats AS qs ON qs.plan_handle = cp.plan_handle
WHERE st.text LIKE N'%GetOrders%'    /* change to your search term */
  AND st.text NOT LIKE N'%sys.dm%'   /* exclude DMV queries */
ORDER BY qs.total_worker_time DESC;
*/

/* ============================================================================
   METHOD C — Capture plan by query_hash (from procstats or query_stats report)
   ============================================================================ */
/*
DECLARE @query_hash binary(8) = 0xABCD1234ABCD1234;  /* from procstats Q1 or query_stats */

SELECT TOP 5
    cached_plan_type   = cp.objtype,
    plan_creation_time = cp.creation_time,
    last_execution     = qs.last_execution_time,
    execution_count    = qs.execution_count,
    avg_cpu_ms         = qs.total_worker_time   / NULLIF(qs.execution_count, 0) / 1000.,
    avg_logical_reads  = qs.total_logical_reads / NULLIF(qs.execution_count, 0),
    sql_text           = LEFT(st.text, 300),
    query_plan         = qp.query_plan
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
JOIN sys.dm_exec_query_stats AS qs ON qs.plan_handle = cp.plan_handle
WHERE qs.query_hash = @query_hash
ORDER BY qs.total_worker_time DESC;
*/
