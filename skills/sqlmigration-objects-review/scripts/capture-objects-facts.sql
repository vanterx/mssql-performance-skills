-- capture-objects-facts.sql
-- Run on the SOURCE instance to collect facts needed by /sqlmigration-objects-review (M1-M16).
-- Native T-SQL only -- no third-party tooling required.

-- Query 1: Agent jobs, owners, and category
SELECT j.name, j.enabled, c.name AS category_name, j.owner_sid
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id;

-- Query 2: Job steps -- database context and proxy usage
SELECT j.name AS job_name, js.step_name, js.database_name, p.name AS proxy_name
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
LEFT JOIN msdb.dbo.sysproxies p ON js.proxy_id = p.proxy_id;

-- Query 3: Job owner login resolution
SELECT j.name, sp.name AS owner_login
FROM msdb.dbo.sysjobs j
LEFT JOIN sys.server_principals sp ON j.owner_sid = sp.sid;

-- Query 4: Job schedules
SELECT s.name AS schedule_name, s.active_start_time, s.freq_type, s.freq_interval
FROM msdb.dbo.sysschedules s;

-- Query 5: Operators
SELECT name, email_address, pager_address FROM msdb.dbo.sysoperators;

-- Query 6: Alerts
SELECT name, message_id, severity FROM msdb.dbo.sysalerts;

-- Query 7: Linked servers
SELECT name, product, provider, data_source, is_linked, is_collation_compatible
FROM sys.servers WHERE is_linked = 1;

-- Query 8: Database Mail profile and account
SELECT name, description FROM msdb.dbo.sysmail_profile;
SELECT name, email_address FROM msdb.dbo.sysmail_account;

-- Query 9: Backup devices
SELECT name, physical_name FROM sys.backup_devices;

-- Query 10: Custom error messages
SELECT message_id, language_id, severity, text FROM sys.messages
WHERE message_id >= 50000;

-- Query 11: Server-level triggers
SELECT name, type_desc, is_disabled, OBJECT_DEFINITION(object_id) AS definition
FROM sys.server_triggers;

-- Query 12: Extended Events sessions (user-defined, excluding system sessions)
SELECT name FROM sys.server_event_sessions
WHERE name NOT IN ('system_health', 'AlwaysOn_health', 'telemetry_xevents');

-- Query 13: Non-AG, user-defined endpoints
-- endpoint_id > 65535 excludes the built-in system endpoints (TSQL Default TCP/Named Pipes/VIA,
-- Dedicated Admin Connection) so only endpoints an admin actually created are reported.
SELECT name, type_desc, state_desc FROM sys.endpoints
WHERE type_desc NOT IN ('DATABASE_MIRRORING') AND endpoint_id > 65535;
