/*
================================================================================
  sql/deadlock/02_create_dedicated_xe_session.sql
  Dedicated Deadlock + Blocking Capture Session (Optional)
================================================================================
  Use this when:
    - system_health ring buffer is being overwritten too quickly (> 10 deadlocks/hour)
    - You also want to capture blocked process reports (blocking chains)
    - You want deadlocks persisted to a file for long-term analysis

  The session captures:
    - xml_deadlock_report    → deadlock graphs for /sqlplan-deadlock
    - blocked_process_report → blocking chains (requires blocked process threshold > 0)

  Read the output with 03_read_dedicated_session.sql.
================================================================================
*/

USE [master];
GO
SET NOCOUNT ON;
GO

/* ── Ensure blocked process threshold is set (required for blocking reports) */
EXEC sys.sp_configure 'blocked process threshold (s)', 5;  /* alert if blocked > 5 seconds */
RECONFIGURE;
GO

/* ── Drop existing session if present ─────────────────────────────────────── */

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DeadlockAndBlocking')
BEGIN
    DROP EVENT SESSION [DeadlockAndBlocking] ON SERVER;
    PRINT 'Existing DeadlockAndBlocking session dropped.';
END;
GO

/* ── Create session ────────────────────────────────────────────────────────── */

CREATE EVENT SESSION [DeadlockAndBlocking] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
    (ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name
    )),
ADD EVENT sqlserver.blocked_process_report
    (ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.sql_text
    ))
ADD TARGET package0.ring_buffer
    (SET max_memory = 51200),          /* 50 MB ring buffer */
ADD TARGET package0.event_file
    (SET filename = N'DeadlockAndBlocking',   /* SQL Server appends path + .xel */
         max_file_size = 100,                 /* MB per file */
         max_rollover_files = 10)
WITH
(
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = ON           /* restart automatically with SQL Server */
);
GO

ALTER EVENT SESSION [DeadlockAndBlocking] ON SERVER STATE = START;
GO

PRINT 'DeadlockAndBlocking XE session created and started.';
PRINT '';
PRINT 'Read results with: sql/deadlock/03_read_dedicated_session.sql';
GO
