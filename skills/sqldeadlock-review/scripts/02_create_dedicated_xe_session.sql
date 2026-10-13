/*
================================================================================
  skills/sqldeadlock-review/scripts/02_create_dedicated_xe_session.sql
  Dedicated Deadlock + Blocking Capture Session (Optional)
================================================================================
  Use this when:
    - system_health ring buffer is being overwritten too quickly (> 10 deadlocks/hour)
    - You also want to capture blocked process reports (blocking chains)
    - You want deadlocks persisted to a file for long-term analysis

  The session captures:
    - xml_deadlock_report    → deadlock graphs for /sqldeadlock-review
    - blocked_process_report → blocking chains (requires blocked process threshold > 0)

  Read the output with 03_read_dedicated_session.sql.

  CHANGES SERVER STATE — this is a setup script, not a read-only capture:
    1. Sets the server option 'blocked process threshold (s)' to 5 (it stays
       set until changed back). 'show advanced options' is turned on only for
       the change and restored to its previous value in the same batch.
    2. Drops any existing [DeadlockAndBlocking] session, then creates and
       starts one with STARTUP_STATE = ON, so it also restarts with the
       instance until it is dropped.
    The previous threshold value is printed first. Run the Teardown section at
    the end of this file when the investigation is over.

  Requires: ALTER SETTINGS (sp_configure with a value, RECONFIGURE) and
    ALTER ANY EVENT SESSION; on SQL Server 2022 and later, CREATE ANY EVENT
    SESSION, DROP ANY EVENT SESSION and ALTER ANY EVENT SESSION cover the
    session statements. sysadmin and serveradmin hold ALTER SETTINGS.
================================================================================
*/

USE [master];
GO
SET NOCOUNT ON;
GO

/* ── Ensure blocked process threshold is set (required for blocking reports) */
/* blocked process threshold is an advanced option. Turn show advanced options
   on only for this change, then put it back the way it was: Microsoft
   recommends leaving it at 0 when the task that needed it is done. */
DECLARE @prior_show_advanced int =
    (SELECT CONVERT(int, value_in_use) FROM sys.configurations
     WHERE name = N'show advanced options');
DECLARE @prior_bpt int =
    (SELECT CONVERT(int, value_in_use) FROM sys.configurations
     WHERE name = N'blocked process threshold (s)');

PRINT 'Previous blocked process threshold (s): ' + CONVERT(varchar(10), @prior_bpt)
    + ' — use this value in the Teardown section.';

IF @prior_show_advanced = 0
BEGIN
    EXEC sys.sp_configure 'show advanced options', 1;
    RECONFIGURE;
END;

EXEC sys.sp_configure 'blocked process threshold (s)', 5;  /* alert if blocked > 5 seconds */
RECONFIGURE;

IF @prior_show_advanced = 0
BEGIN
    EXEC sys.sp_configure 'show advanced options', 0;
    RECONFIGURE;
END;
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
    (SET max_memory = 1024),           /* KB — Microsoft recommends ≤ 1024 KB to avoid truncated target XML; the file target keeps history */
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
PRINT 'Read results with: skills/sqldeadlock-review/scripts/03_read_dedicated_session.sql';
GO

/* ============================================================================
   Teardown — run when the investigation is over
   ============================================================================
   The session has STARTUP_STATE = ON and the threshold persists, so neither
   goes away on its own. Read anything you still need from the event file
   first (03_read_dedicated_session.sql); dropping the session does not delete
   the .xel files already written.

   Replace <previous value> with the number printed when this script ran
   (0 is the default, and disables blocked process reports).
*/
/*
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'DeadlockAndBlocking')
    ALTER EVENT SESSION [DeadlockAndBlocking] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DeadlockAndBlocking')
    DROP EVENT SESSION [DeadlockAndBlocking] ON SERVER;
GO

DECLARE @prior_show_advanced int =
    (SELECT CONVERT(int, value_in_use) FROM sys.configurations
     WHERE name = N'show advanced options');
IF @prior_show_advanced = 0
BEGIN
    EXEC sys.sp_configure 'show advanced options', 1;
    RECONFIGURE;
END;
EXEC sys.sp_configure 'blocked process threshold (s)', <previous value>;
RECONFIGURE;
IF @prior_show_advanced = 0
BEGIN
    EXEC sys.sp_configure 'show advanced options', 0;
    RECONFIGURE;
END;
GO
*/
