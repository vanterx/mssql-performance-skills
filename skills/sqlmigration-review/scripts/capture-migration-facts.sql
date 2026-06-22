-- capture-migration-facts.sql
-- Run on the SOURCE instance to collect facts needed by /sqlmigration-review (Y1-Y14).
-- Native T-SQL only -- no third-party tooling required.

-- Query 1: Instance version, edition, engine edition
SELECT SERVERPROPERTY('ProductVersion') AS product_version,
       SERVERPROPERTY('Edition') AS edition,
       SERVERPROPERTY('EngineEdition') AS engine_edition,
       SERVERPROPERTY('Collation') AS server_collation,
       SERVERPROPERTY('IsHadrEnabled') AS hadr_enabled;

-- Query 2: Per-database compatibility level, recovery model, collation
SELECT name, compatibility_level, recovery_model_desc, collation_name,
       is_read_committed_snapshot_on
FROM sys.databases
WHERE database_id > 4;

-- Query 3: Edition-gated / persisted SKU features in use
SELECT DISTINCT feature_name
FROM sys.dm_db_persisted_sku_features;

-- Query 4: Memory-optimized tables and filegroups
SELECT t.name AS table_name, t.is_memory_optimized
FROM sys.tables t
WHERE t.is_memory_optimized = 1;

-- Query 5: Backup chain -- full/differential/log, most recent 14 days
SELECT database_name, type_desc, backup_start_date, backup_finish_date,
       differential_base_lsn, first_lsn, last_lsn,
       is_password_protected, key_algorithm, encryptor_type
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -14, GETDATE())
ORDER BY backup_start_date DESC;

-- Query 6: Active SQL Server Agent jobs (relevant when target is Azure SQL Database)
SELECT name, enabled
FROM msdb.dbo.sysjobs
WHERE enabled = 1;

-- Query 7: Windows-authenticated logins (relevant when target is Azure SQL Database)
SELECT name, type_desc, is_disabled
FROM sys.server_principals
WHERE type_desc IN ('WINDOWS_LOGIN', 'WINDOWS_GROUP');

-- Query 8: Linked servers (relevant when target is Azure SQL Database, not Managed Instance)
-- For the full linked-server portability detail (provider, is_collation_compatible), run
-- /sqlmigration-objects-review's capture-objects-facts.sql Query 7 instead of duplicating here.
SELECT name, product, data_source, is_linked
FROM sys.servers
WHERE is_linked = 1;
