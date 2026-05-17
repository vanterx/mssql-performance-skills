/*
================================================================================
  skills/sqltrace-review/scripts/02_read_ring_buffer.sql
  Read WorkloadCapture Ring Buffer for /sqltrace-review
================================================================================
  Run this after your workload capture is complete.
  Paste the result set into Claude and run: /sqltrace-review

  All duration values are in microseconds (matches XE convention).
  The sqltrace-review skill handles both microsecond and millisecond inputs.
================================================================================
*/

/* Stop the session before reading to get a clean snapshot */
-- ALTER EVENT SESSION [WorkloadCapture] ON SERVER STATE = STOP;

SELECT TOP 5000
    event_name      = xdr.value('@name',                           'nvarchar(50)'),
    start_time      = xdr.value('@timestamp',                      'datetime2(3)'),
    database_name   = xdr.value('(action[@name="database_name"]/value)[1]',        'nvarchar(128)'),
    sql_text        = LEFT(
                        COALESCE(
                            xdr.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)'),
                            xdr.value('(data[@name="statement"]/value)[1]',  'nvarchar(max)')),
                        500),
    object_name     = xdr.value('(data[@name="object_name"]/value)[1]',     'nvarchar(128)'),
    duration_us     = xdr.value('(data[@name="duration"]/value)[1]',        'bigint'),
    cpu_ms          = xdr.value('(data[@name="cpu_time"]/value)[1]',        'bigint') / 1000,
    logical_reads   = xdr.value('(data[@name="logical_reads"]/value)[1]',   'bigint'),
    physical_reads  = xdr.value('(data[@name="physical_reads"]/value)[1]',  'bigint'),
    writes          = xdr.value('(data[@name="writes"]/value)[1]',          'bigint'),
    row_count       = xdr.value('(data[@name="row_count"]/value)[1]',       'bigint'),
    spid            = xdr.value('(action[@name="session_id"]/value)[1]',    'int'),
    app_name        = xdr.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(128)'),
    host_name       = xdr.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(128)'),
    login_name      = xdr.value('(action[@name="server_principal_name"]/value)[1]', 'nvarchar(128)'),
    query_hash      = xdr.value('(action[@name="query_hash"]/value)[1]',    'binary(8)')
FROM (
    SELECT CAST(target_data AS xml) AS target_data
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t
      ON s.address = t.event_session_address
    WHERE s.name        = 'WorkloadCapture'
      AND t.target_name = 'ring_buffer'
) AS raw_data
CROSS APPLY target_data.nodes('//RingBufferTarget/event') AS XEventData(xdr)
ORDER BY start_time DESC;

/* After reading, drop the session to free memory */
-- DROP EVENT SESSION [WorkloadCapture] ON SERVER;
