/*
================================================================================
  sql/deadlock/03_read_dedicated_session.sql
  Read DeadlockAndBlocking Session for /sqlplan-deadlock
================================================================================
  Reads from the DeadlockAndBlocking session created by 02_create_dedicated_xe_session.sql.
  Paste the deadlock_xml column value into /sqlplan-deadlock.
================================================================================
*/

/* ── Read deadlocks from ring buffer ─────────────────────────────────────── */

SELECT
    event_name     = xdr.value('@name',      'nvarchar(50)'),
    event_time     = xdr.value('@timestamp', 'datetime2(3)'),
    deadlock_xml   = CAST(xdr.query('(data/value/deadlock)[1]') AS xml)
FROM (
    SELECT CAST(target_data AS xml) AS target_data
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t
      ON s.address = t.event_session_address
    WHERE s.name        = 'DeadlockAndBlocking'
      AND t.target_name = 'ring_buffer'
) AS raw_data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(xdr)
ORDER BY event_time DESC;

/* ── Read blocked process reports from ring buffer ───────────────────────── */

SELECT
    event_time         = xdr.value('@timestamp', 'datetime2(3)'),
    blocked_spid       = xdr.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@spid)[1]', 'int'),
    blocking_spid      = xdr.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@spid)[1]', 'int'),
    wait_time_ms       = xdr.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@waittime)[1]', 'bigint'),
    blocked_sql        = xdr.value('(data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(4000)'),
    blocking_sql       = xdr.value('(data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(4000)'),
    full_report_xml    = CAST(xdr.query('(data[@name="blocked_process"]/value)[1]') AS xml)
FROM (
    SELECT CAST(target_data AS xml) AS target_data
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t
      ON s.address = t.event_session_address
    WHERE s.name        = 'DeadlockAndBlocking'
      AND t.target_name = 'ring_buffer'
) AS raw_data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="blocked_process_report"]') AS XEventData(xdr)
ORDER BY event_time DESC;
