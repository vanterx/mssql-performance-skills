/*
================================================================================
  00_bootstrap.sql
  DMV Collection Framework — Shared Prerequisites
================================================================================
  Creates the three objects every collector depends on:
    collect schema       — namespace for all collection tables and SPs
    collect.config       — key/value configuration
    collect.collection_log — one row per collector execution

  Completely idempotent — safe to run multiple times.
  Does NOT create any collector-specific tables.

  The Deploy-DmvCollection.ps1 script always runs this first, regardless of
  which collectors are being deployed. Run manually with:
    :setvar Database DBAMonitor
    :r 00_bootstrap.sql
  Or via PowerShell:
    Invoke-Sqlcmd -ServerInstance . -Database DBAMonitor -InputFile 00_bootstrap.sql
                  -Variable "Database=DBAMonitor"
================================================================================
*/

USE [$(Database)];
GO
SET NOCOUNT ON;
GO

/* ── Schema ─────────────────────────────────────────────────────────────── */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'collect')
    EXECUTE (N'CREATE SCHEMA collect AUTHORIZATION dbo;');
GO

/* ── collect.config ─────────────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.config', N'U') IS NULL
BEGIN
    CREATE TABLE collect.config
    (
        setting_name   sysname        NOT NULL
            CONSTRAINT PK_config PRIMARY KEY CLUSTERED,
        setting_value  nvarchar(256)  NOT NULL,
        description    nvarchar(512)  NULL
    );
    PRINT 'collect.config created.';
END;

/* Seed / update all settings (MERGE is idempotent) */
MERGE collect.config AS t
USING (VALUES
    (N'collection_interval_minutes', N'5',
     N'How often the Agent job calls usp_CollectAll'),
    (N'retention_days',              N'30',
     N'Rows older than N days are purged on each collection'),
    (N'min_executions',              N'1',
     N'Skip objects with execution_count below this threshold'),
    (N'collect_query_plans',         N'1',
     N'1 = capture plan XML (COMPRESS-ed); 0 = skip'),
    (N'exclude_system_databases',    N'1',
     N'1 = exclude master/model/msdb/tempdb (database_id IN (1,2,3,4))')
) AS s (setting_name, setting_value, description)
ON t.setting_name = s.setting_name
WHEN NOT MATCHED THEN
    INSERT (setting_name, setting_value, description)
    VALUES (s.setting_name, s.setting_value, s.description);
GO

/* ── collect.collection_log ─────────────────────────────────────────────── */

IF OBJECT_ID(N'collect.collection_log', N'U') IS NULL
BEGIN
    CREATE TABLE collect.collection_log
    (
        log_id           bigint         NOT NULL IDENTITY
            CONSTRAINT PK_collection_log PRIMARY KEY CLUSTERED,
        collection_time  datetime2(7)   NOT NULL DEFAULT SYSDATETIME(),
        collector_name   sysname        NOT NULL,
        status           nvarchar(20)   NOT NULL,   /* SUCCESS | ERROR */
        rows_inserted    int            NULL,
        duration_ms      int            NULL,
        error_message    nvarchar(2048) NULL
    );
    PRINT 'collect.collection_log created.';
END;
GO

PRINT 'Bootstrap complete — collect schema, config, and collection_log are ready.';
GO
