/*
================================================================================
  04_report_queries.sql
  Procedure Stats Collection Framework — Reporting Queries
================================================================================
  Run any of these queries after at least ONE collection has completed
  (two collections are needed for meaningful delta values).

  Paste the result grid into Claude and run:  /procstats-review

  Queries:
    Q1  Top CPU Consumers         (feeds R1, R6, R8, R9, R14)
    Q2  Top Read Consumers        (feeds R2, R5, R7, R15)
    Q3  Top Execution Callers     (feeds R4, R11, R12)
    Q4  Per-Execution Averages    (feeds R6, R7, R8, R9, R10)
    Q5  Trend — Time Series       (feeds R16, R17, R18, R19, R20; needs >= 3 snapshots)

  All queries filter to the MOST RECENT completed snapshot only (collection_time = max).
  For trend analysis (Q5), all snapshots for the object are returned.

  Column notes:
    avg_worker_time_ms  — average CPU time per execution (milliseconds)
    avg_elapsed_time_ms — average wall-clock time per execution (ms); > avg_worker = blocking/IO
    avg_logical_reads   — average 8-KB page reads per execution
    worker_time_per_sec — CPU milliseconds consumed per second during the sample window
    reads_per_sec       — logical reads per second during the sample window
    max_worker_time_ms  — single worst execution CPU time (ms); >> avg = parameter sniffing
    cache_age_minutes   — how long the current plan has been in cache
================================================================================
*/

USE [$(Database)];  /* <-- Change to your target database */
GO
SET NOCOUNT ON;
GO

/* ============================================================================
   Q1  — Top CPU Consumers (most recent snapshot)
   Paste this output into /procstats-review for checks R1, R6, R8, R9, R14.
   ============================================================================ */

DECLARE @latest_collection datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.proc_stats
     WHERE  execution_count_delta IS NOT NULL);

SELECT TOP 20
    collection_time,
    object_type,
    database_name,
    schema_name,
    object_name,
    execution_count_delta                                           AS execs_in_interval,
    CAST(worker_time_per_sec         AS decimal(18, 2))            AS cpu_ms_per_sec,
    CAST(avg_worker_time_ms          AS decimal(18, 2))            AS avg_cpu_ms,
    CAST(avg_elapsed_time_ms         AS decimal(18, 2))            AS avg_elapsed_ms,
    CAST(max_worker_time / 1000.     AS decimal(18, 2))            AS max_cpu_ms,
    CAST(avg_logical_reads           AS bigint)                    AS avg_logical_reads,
    CAST(reads_per_sec               AS decimal(18, 2))            AS reads_per_sec,
    CAST(avg_spills                  AS decimal(18, 4))            AS avg_spills,
    total_physical_reads_delta                                     AS physical_reads_delta,
    sample_seconds,
    DATEDIFF(MINUTE, cached_time, collection_time)                 AS cache_age_minutes
FROM collect.proc_stats
WHERE collection_time     = @latest_collection
  AND execution_count_delta IS NOT NULL
ORDER BY total_worker_time_delta DESC;
GO

/* ============================================================================
   Q2  — Top Read Consumers (most recent snapshot)
   Paste this output into /procstats-review for checks R2, R5, R7, R15.
   ============================================================================ */

DECLARE @latest_collection datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.proc_stats
     WHERE  execution_count_delta IS NOT NULL);

SELECT TOP 20
    collection_time,
    object_type,
    database_name,
    schema_name,
    object_name,
    execution_count_delta                                           AS execs_in_interval,
    CAST(reads_per_sec               AS decimal(18, 2))            AS reads_per_sec,
    CAST(avg_logical_reads           AS bigint)                    AS avg_logical_reads,
    total_logical_reads_delta                                      AS logical_reads_delta,
    total_physical_reads_delta                                     AS physical_reads_delta,
    CAST(
        100.0 * total_physical_reads_delta
        / NULLIF(total_logical_reads_delta, 0)
        AS decimal(6, 2))                                          AS physical_pct,  /* cache miss rate */
    CAST(avg_worker_time_ms          AS decimal(18, 2))            AS avg_cpu_ms,
    CAST(avg_elapsed_time_ms         AS decimal(18, 2))            AS avg_elapsed_ms,
    sample_seconds,
    DATEDIFF(MINUTE, cached_time, collection_time)                 AS cache_age_minutes
FROM collect.proc_stats
WHERE collection_time     = @latest_collection
  AND execution_count_delta IS NOT NULL
ORDER BY total_logical_reads_delta DESC;
GO

/* ============================================================================
   Q3  — Top Execution Frequency (most recent snapshot)
   Paste this output into /procstats-review for checks R4, R11, R12.
   ============================================================================ */

DECLARE @latest_collection datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.proc_stats
     WHERE  execution_count_delta IS NOT NULL);

SELECT TOP 20
    collection_time,
    object_type,
    database_name,
    schema_name,
    object_name,
    execution_count_delta                                           AS execs_in_interval,
    CAST(
        1.0 * execution_count_delta
        / NULLIF(sample_seconds, 0)
        AS decimal(10, 2))                                         AS execs_per_sec,
    CAST(avg_worker_time_ms          AS decimal(18, 2))            AS avg_cpu_ms,
    CAST(avg_elapsed_time_ms         AS decimal(18, 2))            AS avg_elapsed_ms,
    CAST(avg_logical_reads           AS bigint)                    AS avg_logical_reads,
    CAST(worker_time_per_sec         AS decimal(18, 2))            AS cpu_ms_per_sec,
    sample_seconds,
    DATEDIFF(MINUTE, cached_time, collection_time)                 AS cache_age_minutes
FROM collect.proc_stats
WHERE collection_time     = @latest_collection
  AND execution_count_delta IS NOT NULL
ORDER BY execution_count_delta DESC;
GO

/* ============================================================================
   Q4  — Per-Execution Averages (most recent snapshot)
   Paste this output into /procstats-review for checks R6, R7, R8, R9, R10.
   Min execution filter (>= 5) prevents noise from one-off executions.
   ============================================================================ */

DECLARE @latest_collection datetime2(7) =
    (SELECT MAX(collection_time) FROM collect.proc_stats
     WHERE  execution_count_delta IS NOT NULL);

SELECT TOP 20
    collection_time,
    object_type,
    database_name,
    schema_name,
    object_name,
    execution_count_delta                                           AS execs_in_interval,
    CAST(avg_worker_time_ms          AS decimal(18, 2))            AS avg_cpu_ms,
    CAST(avg_elapsed_time_ms         AS decimal(18, 2))            AS avg_elapsed_ms,
    CAST(max_worker_time / 1000.     AS decimal(18, 2))            AS max_cpu_ms,
    CAST(
        CASE WHEN avg_worker_time_ms > 0
             THEN max_worker_time / 1000. / avg_worker_time_ms
             ELSE NULL END
        AS decimal(10, 1))                                         AS max_to_avg_cpu_ratio,
    CAST(avg_logical_reads           AS bigint)                    AS avg_logical_reads,
    CAST(avg_physical_reads          AS bigint)                    AS avg_physical_reads,
    CAST(avg_spills                  AS decimal(18, 4))            AS avg_spills,
    CAST(
        CASE WHEN avg_elapsed_time_ms > 0
             THEN avg_worker_time_ms / avg_elapsed_time_ms
             ELSE NULL END
        AS decimal(6, 2))                                          AS cpu_to_elapsed_ratio, /* < 1 = blocking/IO wait; > 1.5 = parallel */
    sample_seconds,
    DATEDIFF(MINUTE, cached_time, collection_time)                 AS cache_age_minutes
FROM collect.proc_stats
WHERE collection_time       = @latest_collection
  AND execution_count_delta >= 5   /* skip one-off executions */
ORDER BY avg_worker_time_ms DESC;
GO

/* ============================================================================
   Q5  — Trend / Time Series (all snapshots for top objects by CPU)
   Paste this output into /procstats-review for checks R16, R17, R18, R19, R20.
   Requires >= 3 completed snapshots. Shows the last 24 hours by default.
   ============================================================================ */

WITH top_objects AS
(
    /* Identify top 5 CPU consumers in the most recent snapshot */
    SELECT TOP 5
        database_name, object_id
    FROM collect.proc_stats
    WHERE collection_time = (
              SELECT MAX(collection_time) FROM collect.proc_stats
              WHERE  execution_count_delta IS NOT NULL)
      AND execution_count_delta IS NOT NULL
    ORDER BY total_worker_time_delta DESC
)
SELECT
    p.collection_time,
    p.object_type,
    p.database_name,
    p.schema_name,
    p.object_name,
    p.execution_count_delta                                         AS execs_in_interval,
    CAST(p.worker_time_per_sec       AS decimal(18, 2))            AS cpu_ms_per_sec,
    CAST(p.avg_worker_time_ms        AS decimal(18, 2))            AS avg_cpu_ms,
    CAST(p.avg_elapsed_time_ms       AS decimal(18, 2))            AS avg_elapsed_ms,
    CAST(p.avg_logical_reads         AS bigint)                    AS avg_logical_reads,
    CAST(p.reads_per_sec             AS decimal(18, 2))            AS reads_per_sec,
    p.sample_seconds,
    p.plan_handle,
    DATEDIFF(MINUTE, p.cached_time, p.collection_time)             AS cache_age_minutes
FROM collect.proc_stats p
JOIN top_objects t
  ON  t.database_name = p.database_name
  AND t.object_id     = p.object_id
WHERE p.collection_time >= DATEADD(HOUR, -24, SYSDATETIME())
  AND p.execution_count_delta IS NOT NULL
ORDER BY
    p.database_name, p.object_name, p.collection_time;
GO

PRINT 'Report queries ready. Copy any result set and paste into /procstats-review.';
GO
