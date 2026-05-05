/*
================================================================================
  05_create_agent_job.sql
  Procedure Stats Collection Framework — SQL Agent Job
================================================================================
  Creates a SQL Server Agent job that runs collect.usp_CollectProcStats
  every N minutes (default: 5, controlled by collect.config).

  Prerequisites:
    01_create_tables.sql, 02_usp_collect_procstats.sql,
    03_usp_calculate_deltas.sql must already be deployed.

  To change the schedule interval after deployment:
    UPDATE collect.config SET setting_value = '10' WHERE setting_name = 'collection_interval_minutes';
    Then update the Agent job schedule manually in SSMS or re-run this script.

  To verify collection is working:
    SELECT TOP 10 * FROM collect.collection_log ORDER BY log_id DESC;
    SELECT TOP 5  * FROM collect.proc_stats     ORDER BY collection_time DESC;
================================================================================
*/

USE [msdb];
GO
SET NOCOUNT ON;
GO

/* SQLCMD variables injected by Deploy-DmvCollection.ps1:
     $(Database)  — target database containing the collect schema
     $(JobName)   — Agent job display name
   When running manually in SSMS: set these via Query > SQLCMD Mode, or edit the values below. */

DECLARE
    @job_name       sysname      = N'$(JobName)',
    @target_db      sysname      = N'$(Database)',
    @interval_min   int          = 5,
    @job_id         uniqueidentifier,
    @schedule_id    int;

/* ── Drop existing job if present ──────────────────────────────────────── */

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
BEGIN
    EXECUTE msdb.dbo.sp_delete_job
        @job_name   = @job_name,
        @delete_history = 0;   /* keep history */
    PRINT CONCAT('Existing job "', @job_name, '" dropped.');
END;

/* ── Create job ─────────────────────────────────────────────────────────── */

EXECUTE msdb.dbo.sp_add_job
    @job_name             = @job_name,
    @enabled              = 1,
    @description          = N'DMV Collection Framework — captures sys.dm_exec_procedure_stats, dm_exec_trigger_stats, dm_exec_function_stats, dm_os_wait_stats, dm_exec_query_stats, dm_io_virtual_file_stats, dm_os_memory_clerks, and dm_os_performance_counters into the collect schema. Feed report output into /procstats-review or /sqlwait-review.',
    @category_name        = N'[Uncategorized (Local)]',
    @owner_login_name     = N'sa',
    @job_id               = @job_id OUTPUT;

/* ── Add collection step ────────────────────────────────────────────────── */

EXECUTE msdb.dbo.sp_add_jobstep
    @job_id         = @job_id,
    @step_name      = N'Collect Procedure Stats',
    @subsystem      = N'TSQL',
    @database_name  = @target_db,
    @command        = N'EXECUTE collect.usp_CollectAll;',
    @retry_attempts = 2,
    @retry_interval = 1,   /* minutes between retries */
    @on_success_action = 1,  /* 1 = quit with success */
    @on_fail_action    = 2;  /* 2 = quit with failure  */

/* ── Add schedule: every N minutes, 00:00–23:59, every day ─────────────── */

EXECUTE msdb.dbo.sp_add_schedule
    @schedule_name          = N'Every 5 Minutes',
    @enabled                = 1,
    @freq_type              = 4,        /* 4 = daily */
    @freq_interval          = 1,        /* every 1 day */
    @freq_subday_type       = 4,        /* 4 = minutes */
    @freq_subday_interval   = @interval_min,
    @active_start_time      = 0,        /* 00:00:00 */
    @active_end_time        = 235959,   /* 23:59:59 */
    @schedule_id            = @schedule_id OUTPUT;

EXECUTE msdb.dbo.sp_attach_schedule
    @job_id      = @job_id,
    @schedule_id = @schedule_id;

/* ── Target local server ────────────────────────────────────────────────── */

EXECUTE msdb.dbo.sp_add_jobserver
    @job_id      = @job_id,
    @server_name = N'(LOCAL)';

PRINT CONCAT('Job "', @job_name, '" created. Schedule: every ', @interval_min, ' minutes.');
PRINT '';
PRINT 'To verify:';
PRINT '  SELECT TOP 20 * FROM $(Database).collect.collection_log ORDER BY log_id DESC;';
PRINT '  SELECT TOP 5  * FROM $(Database).collect.proc_stats    ORDER BY collection_time DESC;';
PRINT '  SELECT TOP 5  * FROM $(Database).collect.wait_stats    ORDER BY collection_time DESC;';
PRINT '  SELECT TOP 1  * FROM $(Database).collect.memory_stats  ORDER BY collection_time DESC;';
GO
