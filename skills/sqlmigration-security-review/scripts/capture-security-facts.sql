-- capture-security-facts.sql
-- Run on the SOURCE instance to collect facts needed by /sqlmigration-security-review (J1-J15).
-- Native T-SQL only -- no third-party tooling required.

-- Query 1: Server-level logins and their SIDs
-- is_policy_checked / is_expiration_checked exist only on sys.sql_logins,
-- so LEFT JOIN it; they return NULL for Windows logins (type U/G), which is correct.
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name, sp.sid,
       sl.is_policy_checked, sl.is_expiration_checked
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
WHERE sp.type IN ('S','U','G') AND sp.name NOT LIKE '##%';

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
-- class = 1 (OBJECT_OR_COLUMN) restricts to object permissions; without it, schema-level
-- permissions (class = 3) join to sys.objects as NULL and look like missing objects.
SELECT pr.name AS grantee, pe.permission_name, pe.state_desc, o.name AS object_name
FROM sys.database_permissions pe
JOIN sys.database_principals pr ON pe.grantee_principal_id = pr.principal_id
LEFT JOIN sys.objects o ON pe.major_id = o.object_id
WHERE pe.class = 1 AND pe.major_id > 0;

-- Query 6: Credentials
SELECT name, credential_identity FROM sys.credentials;

-- Query 7: SQL Agent proxies and their credential mapping
SELECT p.name AS proxy_name, c.name AS credential_name
FROM msdb.dbo.sysproxies p
JOIN sys.credentials c ON p.credential_id = c.credential_id;

-- Query 8: Linked server stored logins
-- local_principal_id + remote_name are required to reconstruct sp_addlinkedsrvlogin
-- mappings; local_principal_id = 0 means the wildcard/public (all-logins) mapping.
SELECT s.name AS linked_server, ll.uses_self_credential,
       ll.local_principal_id, lp.name AS local_login, ll.remote_name
FROM sys.linked_logins ll
JOIN sys.servers s ON ll.server_id = s.server_id
LEFT JOIN sys.server_principals lp ON ll.local_principal_id = lp.principal_id;

-- Query 9: Non-TDE certificates -- run per database
-- TDE encryptor certificates carry is_active_for_begin_dialog = 0, so that flag does
-- NOT exclude them. Anti-join to sys.dm_database_encryption_keys on the thumbprint to
-- drop the certificate currently protecting the DEK.
SELECT c.name, c.expiry_date, c.pvt_key_encryption_type_desc
FROM sys.certificates c
WHERE NOT EXISTS (
    SELECT 1 FROM sys.dm_database_encryption_keys dek
    WHERE dek.encryptor_thumbprint = c.thumbprint
);

-- Query 10: Database master key presence -- run per database
SELECT name FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##';

-- Query 11: Cross-database dependencies (J9 ownership-chain candidates) -- run per database
-- referenced_database_name is populated only for 3-/4-part references; NULL = same-database.
-- referenced_server_name IS NULL keeps cross-database (not cross-server) references.
SELECT OBJECT_SCHEMA_NAME(d.referencing_id) AS referencing_schema,
       OBJECT_NAME(d.referencing_id)        AS referencing_object,
       d.referenced_database_name,
       d.referenced_schema_name,
       d.referenced_entity_name
FROM sys.sql_expression_dependencies d
WHERE d.referenced_database_name IS NOT NULL
  AND d.referenced_database_name <> DB_NAME()
  AND d.referenced_server_name IS NULL;
