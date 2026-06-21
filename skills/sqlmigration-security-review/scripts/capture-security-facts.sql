-- capture-security-facts.sql
-- Run on the SOURCE instance to collect facts needed by /sqlmigration-security-review (J1-J15).
-- Native T-SQL only -- no third-party tooling required.

-- Query 1: Server-level logins and their SIDs
SELECT name, type_desc, is_disabled, default_database_name,
       is_policy_checked, is_expiration_checked
FROM sys.server_principals
WHERE type IN ('S','U','G') AND name NOT LIKE '##%';

-- Query 2: Database users mapped (or unmapped) to logins -- run per database
SELECT dp.name AS user_name, dp.type_desc, sp.name AS login_name
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G') AND dp.principal_id > 4;

-- Query 3: Server-level role membership
SELECT sp.name AS login_name, r.name AS role_name
FROM sys.server_role_members rm
JOIN sys.server_principals sp ON rm.member_principal_id = sp.principal_id
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id;

-- Query 4: Database role membership -- run per database
SELECT dp.name AS user_name, r.name AS role_name
FROM sys.database_role_members rm
JOIN sys.database_principals dp ON rm.member_principal_id = dp.principal_id
JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id;

-- Query 5: Explicit object-level GRANT/DENY -- run per database
SELECT pr.name AS grantee, pe.permission_name, pe.state_desc, o.name AS object_name
FROM sys.database_permissions pe
JOIN sys.database_principals pr ON pe.grantee_principal_id = pr.principal_id
LEFT JOIN sys.objects o ON pe.major_id = o.object_id
WHERE pe.major_id > 0;

-- Query 6: Credentials
SELECT name, credential_identity FROM sys.credentials;

-- Query 7: SQL Agent proxies and their credential mapping
SELECT p.name AS proxy_name, c.name AS credential_name
FROM msdb.dbo.sysproxies p
JOIN sys.credentials c ON p.credential_id = c.credential_id;

-- Query 8: Linked server stored logins
SELECT ll.uses_self_credential, s.name AS linked_server
FROM sys.linked_logins ll
JOIN sys.servers s ON ll.server_id = s.server_id;

-- Query 9: Non-TDE certificates
SELECT name, expiry_date, pvt_key_encryption_type_desc
FROM sys.certificates
WHERE is_active_for_begin_dialog = 0;

-- Query 10: Database master key presence -- run per database
SELECT name FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##';
