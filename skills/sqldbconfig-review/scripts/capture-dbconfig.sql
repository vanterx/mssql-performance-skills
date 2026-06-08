-- sqldbconfig-review capture script
-- Run on the target SQL Server instance and paste the output into /sqldbconfig-review
-- Requires VIEW SERVER STATE and VIEW DATABASE STATE permissions
-- Compatible with SQL Server 2012+ (some columns require 2016 SP2+ -- see notes inline)

PRINT '-- 1. Instance configuration (sp_configure)';
EXEC sp_configure;

PRINT '';
PRINT '-- 2. Database settings';
SELECT
    name,
    compatibility_level,
    is_auto_shrink_on,
    is_auto_close_on,
    is_read_committed_snapshot_on,
    page_verify_option_desc,
    is_auto_create_stats_on,
    is_auto_update_stats_on,
    is_trustworthy_on,
    is_db_chaining_on,
    recovery_model_desc,
    state_desc
FROM sys.databases
ORDER BY database_id;

PRINT '';
PRINT '-- 3. File growth configuration';
SELECT
    DB_NAME(database_id)    AS database_name,
    name                    AS logical_name,
    type_desc,
    size * 8 / 1024         AS size_mb,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS varchar(10)) + '%'
        ELSE CAST(growth * 8 / 1024 AS varchar(10)) + ' MB'
    END                     AS growth_setting,
    is_percent_growth,
    growth,
    max_size
FROM sys.master_files
ORDER BY database_id, type;

PRINT '';
PRINT '-- 4. CPU and NUMA topology';
SELECT
    cpu_count,
    scheduler_count,
    -- numa_node_count, socket_count, cores_per_socket: SQL Server 2016 SP2+ only
    -- sql_memory_model_desc: SQL Server 2012 SP4 / 2016 SP1+ only
    -- Comment out columns that do not exist on older instances
    numa_node_count,
    socket_count,
    cores_per_socket,
    sql_memory_model_desc
FROM sys.dm_os_sys_info;

PRINT '';
PRINT '-- 5. VLF count per database (SQL Server 2016 SP2+)';
PRINT '-- For older instances use: DBCC LOGINFO in each database and count rows';
SELECT
    DB_NAME(s.database_id)  AS database_name,
    COUNT(l.database_id)    AS vlf_count
FROM sys.databases AS s
CROSS APPLY sys.dm_db_log_info(s.database_id) AS l
WHERE s.state_desc = 'ONLINE'
GROUP BY s.database_id
ORDER BY vlf_count DESC;

PRINT '';
PRINT '-- 6. Instant File Initialization status';
SELECT
    servicename,
    instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%'
   OR servicename LIKE 'SQL Server Agent%';

PRINT '';
PRINT '-- 7. TempDB file count';
SELECT
    type_desc,
    COUNT(*) AS file_count,
    SUM(size * 8 / 1024) AS total_size_mb
FROM sys.master_files
WHERE database_id = 2
GROUP BY type_desc;
