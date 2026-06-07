/*
================================================================================
  skills/sqltrace-review/scripts/01_create_xe_session.sql
  Extended Events Workload Capture Session for /sqltrace-review
================================================================================
  Creates an XE session that captures SQL statements, RPC calls, and batch
  completions — equivalent to a SQL Profiler trace with Duration, CPU, Reads
  filtered above a minimum threshold.

  Two target options:
    A) Ring buffer — for short captures (< 30 minutes); read with 02_read_ring_buffer.sql
    B) File target — for sustained captures; read with 03_read_file_target.sql

  Filter: duration > 100,000 microseconds (100 ms) by default.
  Lower to 10000 (10 ms) to capture more; raise to 1000000 (1 second) for
  only slow queries.

  After capture, paste the output of 02_read_ring_buffer.sql or
  03_read_file_target.sql into Claude and run: /sqltrace-review
================================================================================
*/

USE [master];
GO
SET NOCOUNT ON;
GO

DECLARE @duration_filter bigint = 100000;   /* microseconds — change as needed */

/* ── Drop existing session if present ─────────────────────────────────────── */

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'WorkloadCapture')
BEGIN
    DROP EVENT SESSION [WorkloadCapture] ON SERVER;
    PRINT 'Existing WorkloadCapture session dropped.';
END;
GO

/* ── Option A: Ring buffer target (ad-hoc, short captures) ─────────────────── */

CREATE EVENT SESSION [WorkloadCapture] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
    (
        WHERE (duration > 100000)   /* change threshold here */
        ACTION
        (
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.sql_text,
            sqlserver.plan_handle,
            sqlserver.query_hash
        )
    ),
ADD EVENT sqlserver.rpc_completed
    (
        WHERE (duration > 100000)
        ACTION
        (
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.sql_text,
            sqlserver.plan_handle,
            sqlserver.query_hash
        )
    ),
ADD EVENT sqlserver.sql_batch_completed
    (
        WHERE (duration > 100000)
        ACTION
        (
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.database_name,
            sqlserver.server_principal_name,
            sqlserver.sql_text
        )
    )
ADD TARGET package0.ring_buffer
    (SET max_memory = 4096,      /* 4 MB — keep ≤ 4096 KB; larger values can pin significant memory */
         max_events_limit = 1000)
WITH
(
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF   /* ad-hoc — does not restart with SQL Server */
);
GO

ALTER EVENT SESSION [WorkloadCapture] ON SERVER STATE = START;
GO

PRINT 'WorkloadCapture session started (ring buffer target).';
PRINT 'Capture your workload now, then run 02_read_ring_buffer.sql.';
PRINT 'To stop: ALTER EVENT SESSION [WorkloadCapture] ON SERVER STATE = STOP;';
GO

/* ============================================================================
   Option B — File target (replace ring_buffer above with this block
   for sustained captures lasting more than 30 minutes)
   ============================================================================ */
/*
ADD TARGET package0.event_file
    (SET filename = N'WorkloadCapture',   -- SQL Server appends path + .xel
         max_file_size = 500,             -- MB per file
         max_rollover_files = 5)
*/
