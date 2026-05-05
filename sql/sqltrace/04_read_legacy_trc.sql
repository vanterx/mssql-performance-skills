/*
================================================================================
  sql/sqltrace/04_read_legacy_trc.sql
  Read Legacy Profiler .trc File for /sqltrace-review
================================================================================
  For Profiler trace files (.trc) captured before Extended Events were available,
  or captured using SQL Profiler in SSMS.

  Adjust @trc_file to your trace file path.
  Column mapping to sqltrace-review expected format:
    Duration   — microseconds  (divide by 1000 for ms)
    CPU        — milliseconds
    Reads      — logical reads
    Writes     — logical writes

  After running, paste the result set into /sqltrace-review.
================================================================================
*/

DECLARE @trc_file nvarchar(260) =
    N'C:\Traces\workload_capture.trc';   /* change to your .trc file path */

SELECT TOP 5000
    event_name      = te.name,
    start_time      = CAST(t.StartTime AS datetime2(3)),
    database_name   = t.DatabaseName,
    object_name     = t.ObjectName,
    sql_text        = LEFT(t.TextData, 500),
    duration_us     = t.Duration,              /* microseconds */
    cpu_ms          = t.CPU,                   /* milliseconds */
    logical_reads   = t.Reads,
    writes          = t.Writes,
    row_count       = t.RowCounts,
    spid            = t.SPID,
    app_name        = t.ApplicationName,
    host_name       = t.HostName,
    login_name      = t.LoginName,
    error_number    = t.Error
FROM sys.fn_trace_gettable(@trc_file, DEFAULT) t
JOIN sys.trace_events te ON te.trace_event_id = t.EventClass
WHERE te.name IN (
    'SQL:StmtCompleted',
    'SQL:BatchCompleted',
    'RPC:Completed',
    'SP:Completed'
)
  AND t.Duration IS NOT NULL
  AND t.Duration > 0
ORDER BY t.Duration DESC;

/* ============================================================================
   AGGREGATED VIEW — top queries by total CPU, total reads, execution count
   Paste this alongside the row-level output for /sqltrace-review workload checks
   ============================================================================ */
/*
SELECT TOP 20
    event_name        = te.name,
    database_name     = t.DatabaseName,
    object_name       = t.ObjectName,
    sql_preview       = LEFT(MAX(t.TextData), 200),
    execution_count   = COUNT(*),
    total_duration_ms = SUM(t.Duration) / 1000,
    avg_duration_ms   = AVG(t.Duration) / 1000,
    max_duration_ms   = MAX(t.Duration) / 1000,
    total_cpu_ms      = SUM(t.CPU),
    avg_cpu_ms        = AVG(t.CPU),
    total_reads       = SUM(t.Reads),
    avg_reads         = AVG(t.Reads),
    total_writes      = SUM(t.Writes)
FROM sys.fn_trace_gettable(@trc_file, DEFAULT) t
JOIN sys.trace_events te ON te.trace_event_id = t.EventClass
WHERE te.name IN ('SQL:StmtCompleted', 'SQL:BatchCompleted', 'RPC:Completed', 'SP:Completed')
  AND t.Duration IS NOT NULL
GROUP BY te.name, t.DatabaseName, t.ObjectName
ORDER BY total_cpu_ms DESC;
*/
