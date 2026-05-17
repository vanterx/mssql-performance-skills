/*
================================================================================
  skills/sqltrace-review/scripts/03_read_file_target.sql
  Read WorkloadCapture File Target for /sqltrace-review
================================================================================
  Use this when the WorkloadCapture session was configured with a file target
  (sustained capture > 30 minutes). Adjust the file path below.

  After running, paste the result set into Claude and run: /sqltrace-review
================================================================================
*/

/* ── Adjust this path to match your SQL Server instance ─────────────────── */
DECLARE @xe_file_path nvarchar(260) =
    N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\WorkloadCapture*.xel';
/* ─────────────────────────────────────────────────────────────────────────── */

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
    SELECT CAST(event_data AS xml) AS xdr_raw
    FROM sys.fn_xe_file_target_read_file(@xe_file_path, NULL, NULL, NULL)
    WHERE object_name IN ('sql_statement_completed', 'rpc_completed', 'sql_batch_completed')
) AS raw_data
CROSS APPLY raw_data.xdr_raw.nodes('event') AS XEventData(xdr)
ORDER BY start_time DESC;
