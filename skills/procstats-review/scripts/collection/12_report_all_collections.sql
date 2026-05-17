/*
================================================================================
  12_report_all_collections.sql
  Report Queries for All Persistent Collection Tables
================================================================================
  After collect.usp_CollectAll has run at least twice, use these queries to
  produce output for each skill:

    Section 1  — collect.wait_stats      → paste into /sqlwait-review
    Section 2  — collect.query_stats     → paste into /procstats-review
    Section 3  — collect.file_io_stats   → paste into /sqlwait-review (V40)
    Section 4  — collect.memory_stats    → context for /sqlwait-review
    Section 5  — collect.perf_counter_stats → context for /sqlwait-review / /procstats-review
    Section 6  — collect.collection_log  → health check (confirm collection is working)
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;

DECLARE @latest datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.wait_stats
     WHERE  waiting_tasks_count_delta IS NOT NULL);

/* ============================================================================
   SECTION 1 — Wait Statistics Report  (paste into /sqlwait-review)
   Shows the dominant waits during the most recent collection interval.
   ============================================================================ */

SELECT TOP 30
    collection_time,
    wait_type,
    waiting_tasks_count_delta,
    wait_time_ms_delta,
    signal_wait_time_ms_delta,
    sample_seconds,
    wait_time_ms_per_second,
    pct_of_interval = CAST(
        100.0 * wait_time_ms_delta
        / NULLIF(SUM(wait_time_ms_delta) OVER (), 0)
        AS decimal(5,2))
FROM collect.wait_stats
WHERE collection_time = @latest
  AND waiting_tasks_count_delta IS NOT NULL
  AND wait_time_ms_delta > 0
ORDER BY wait_time_ms_delta DESC;

/* ============================================================================
   SECTION 2 — Query Stats Top CPU Report  (paste into /procstats-review)
   Shows top statement-level CPU consumers in the most recent interval.
   ============================================================================ */

DECLARE @latest_qs datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.query_stats
     WHERE  execution_count_delta IS NOT NULL);

SELECT TOP 20
    collection_time,
    database_name,
    object_name        = ISNULL(object_name, '(ad-hoc)'),
    sql_preview        = LEFT(
                            CAST(DECOMPRESS(query_text_compressed) AS nvarchar(max)),
                            200),
    execs_in_interval  = execution_count_delta,
    cpu_ms_per_sec     = CAST(worker_time_per_sec   AS decimal(18,2)),
    avg_cpu_ms         = CAST(avg_worker_time_ms    AS decimal(18,2)),
    avg_elapsed_ms     = CAST(avg_elapsed_time_ms   AS decimal(18,2)),
    avg_logical_reads  = CAST(avg_logical_reads      AS bigint),
    reads_per_sec      = CAST(reads_per_sec          AS decimal(18,2)),
    sample_seconds
FROM collect.query_stats
WHERE collection_time        = @latest_qs
  AND execution_count_delta IS NOT NULL
ORDER BY total_worker_time_delta DESC;

/* ============================================================================
   SECTION 3 — File I/O Report  (paste into /sqlwait-review for V40 checks)
   Shows I/O stall by file for the most recent interval.
   ============================================================================ */

DECLARE @latest_fio datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.file_io_stats
     WHERE  num_of_reads_delta IS NOT NULL);

SELECT
    collection_time,
    database_name,
    file_name,
    file_type_desc,
    physical_name,
    num_of_reads_delta,
    num_of_writes_delta,
    io_stall_read_ms_delta,
    io_stall_write_ms_delta,
    avg_read_stall_ms   = CAST(avg_read_stall_ms  AS decimal(10,2)),
    avg_write_stall_ms  = CAST(avg_write_stall_ms AS decimal(10,2)),
    mb_read_per_sec     = CAST(mb_read_per_sec    AS decimal(10,2)),
    mb_written_per_sec  = CAST(mb_written_per_sec AS decimal(10,2)),
    sample_seconds
FROM collect.file_io_stats
WHERE collection_time = @latest_fio
  AND num_of_reads_delta IS NOT NULL
  AND (num_of_reads_delta > 0 OR num_of_writes_delta > 0)
ORDER BY (io_stall_read_ms_delta + io_stall_write_ms_delta) DESC;

/* ============================================================================
   SECTION 4 — Memory Snapshot  (context for /sqlwait-review RESOURCE_SEMAPHORE)
   ============================================================================ */

SELECT TOP 5
    collection_time,
    buffer_pool_mb,
    plan_cache_mb,
    stolen_mb,
    total_clerk_mb,
    physical_memory_in_use_mb,
    available_physical_mb,
    system_memory_state,
    committed_target_mb,
    memory_utilization_pct,
    buffer_pool_pressure_warning,
    plan_cache_pressure_warning
FROM collect.memory_stats
ORDER BY collection_time DESC;

/* ============================================================================
   SECTION 5 — Performance Counter Snapshot
   Key counters for workload and health context.
   ============================================================================ */

DECLARE @latest_pc datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.perf_counter_stats);

SELECT
    collection_time,
    counter_name     = RTRIM(counter_name),
    instance_name,
    current_value    = cntr_value,
    per_second       = CAST(value_per_second AS decimal(18,2))
FROM collect.perf_counter_stats
WHERE collection_time = @latest_pc
  AND counter_name IN (
      'Batch Requests/sec',
      'SQL Compilations/sec',
      'SQL Re-Compilations/sec',
      'Page life expectancy',
      'Buffer cache hit ratio',
      'Lazy writes/sec',
      'Lock Waits/sec',
      'Number of Deadlocks/sec',
      'Processes blocked',
      'User Connections',
      'Page reads/sec',
      'Page writes/sec',
      'Target Server Memory (KB)',
      'Total Server Memory (KB)'
  )
ORDER BY counter_name;

/* ============================================================================
   SECTION 6 — Collection Health Log
   Confirms collectors are running and succeeding.
   ============================================================================ */

SELECT TOP 30
    collection_time,
    collector_name,
    status,
    rows_inserted,
    duration_ms,
    error_message
FROM collect.collection_log
ORDER BY log_id DESC;

/* Summary: are all collectors succeeding? */
SELECT
    collector_name,
    last_run       = MAX(collection_time),
    success_count  = SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END),
    error_count    = SUM(CASE WHEN status = 'ERROR'   THEN 1 ELSE 0 END),
    avg_duration_ms = AVG(duration_ms),
    last_status    = MAX(status)
FROM collect.collection_log
WHERE collection_time >= DATEADD(HOUR, -24, SYSDATETIME())
GROUP BY collector_name
ORDER BY collector_name;
GO
