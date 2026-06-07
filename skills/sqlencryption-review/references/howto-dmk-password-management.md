# HOW-TO: DMK Password Management with sp_control_dbmasterkey_password

Step-by-step guide for managing Database Master Key passwords using `sp_control_dbmasterkey_password` — covering SSISDB, cross-server restores, AG replicas, and SMK migration.

---

## Background: Two DMK Protection Models

SQL Server offers two ways to automatically open a Database Master Key at startup:

**Model 1: SMK protection (default, recommended for most databases)**
```sql
USE [YourDatabase];
ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;
-- Verify:
SELECT is_master_key_encrypted_by_server FROM sys.databases WHERE name = 'YourDatabase';
-- Returns 1 = auto-open on restart; no further action needed
```

**Model 2: Password registration via sp_control_dbmasterkey_password**

Used when the DMK deliberately lacks SMK protection. SQL Server creates a credential (`##DBMKEY_<family_guid>_<random_guid>##`) in `sys.credentials`, encrypted by the SMK, and records it in `sys.master_key_passwords`. At startup, SQL Server looks up the database's `family_guid`, retrieves the credential, and uses the password to open the DMK.

Key facts:
- `sys.master_key_passwords` columns: `credential_id` (FK to `sys.credentials`) + `family_guid` (stable database ID — persists across restore, attach, rename, and `ALTER MASTER KEY REGENERATE`)
- Cannot be used on system databases (master, model, msdb, tempdb)
- Does NOT verify the password is correct (by design — validation is skipped for backward compatibility)
- Parameters do NOT appear in SQL Server traces (passwords are protected)
- `ALTER SERVICE MASTER KEY REGENERATE` on the same instance re-encrypts all credentials automatically — registrations remain valid
- `RESTORE SERVICE MASTER KEY FROM FILE` from a DIFFERENT instance invalidates existing registrations

---

## Scenario 1: SSISDB — Register at Installation

SSISDB creates its DMK without SMK protection by design (security isolation). After every SQL Server instance restart, SSIS catalog operations fail with Msg 15581 unless the password is registered.

```sql
-- Step 1: Verify SSISDB needs registration
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT d.name, drs.family_guid, d.is_master_key_encrypted_by_server,
       CASE WHEN mkp.credential_id IS NULL THEN 'NOT REGISTERED — fix required'
            ELSE 'Registered — OK' END AS registration_status
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
LEFT JOIN master.sys.master_key_passwords mkp ON mkp.family_guid = drs.family_guid
WHERE d.name = 'SSISDB';

-- Step 2: Register (run in master database context)
USE master;
EXEC sp_control_dbmasterkey_password
    @db_name = N'SSISDB',
    @password = N'[password_entered_at_catalog_creation]',
    @action = N'add';

-- Step 3: Verify
SELECT mkp.family_guid, c.name AS credential_name, c.create_date
FROM master.sys.master_key_passwords mkp
JOIN master.sys.credentials c ON mkp.credential_id = c.credential_id;
-- Should show a row for SSISDB's family_guid
```

If the SSISDB catalog creation password is lost, the catalog must be recreated:
```sql
-- DESTRUCTIVE — all packages will be lost unless backed up first
USE master;
EXEC SSISDB.catalog.drop_catalog;
-- Then recreate via SSMS: Integration Services Catalogs → right-click → Create Catalog
```

---

## Scenario 2: Any Database with Deliberate SMK Isolation

Some security architectures keep a database's DMK separate from the SMK so a compromised SA account cannot automatically decrypt encrypted data.

```sql
-- Verify current protection state
SELECT name, is_master_key_encrypted_by_server FROM sys.databases WHERE database_id > 4;

-- Check which databases have a DMK at all
SELECT DB_NAME() AS db_name, name, create_date
FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##';
-- (run in each database context)

-- Register password for a deliberately isolated DMK
USE master;
EXEC sp_control_dbmasterkey_password
    @db_name = N'[IsolatedDatabase]',
    @password = N'[strong_dmk_password]',
    @action = N'add';
```

---

## Scenario 3: Cross-Server Database Restore

When restoring a database with `is_master_key_encrypted_by_server = 0` to a new SQL Server instance, the `family_guid` is preserved but the target instance has no password registration.

```sql
-- On TARGET instance: identify restored databases needing registration
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT d.name, drs.family_guid, d.is_master_key_encrypted_by_server,
       r.restore_date
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
LEFT JOIN msdb.dbo.restorehistory r ON r.destination_database_name = d.name
LEFT JOIN master.sys.master_key_passwords mkp ON mkp.family_guid = drs.family_guid
WHERE d.database_id > 4
  AND d.is_master_key_encrypted_by_server = 0
  AND mkp.credential_id IS NULL
ORDER BY r.restore_date DESC;

-- Register on target instance
USE master;
EXEC sp_control_dbmasterkey_password
    @db_name = N'[RestoredDatabase]',
    @password = N'[original_dmk_password]',
    @action = N'add';

-- If original password is unknown, restore from DMK backup:
USE [RestoredDatabase];
RESTORE MASTER KEY
    FROM FILE = 'D:\Keys\RestoredDatabase_dmk.mk'
    DECRYPTION BY PASSWORD = 'VaultStoredBackupPassword'
    ENCRYPTION BY PASSWORD = 'NewPasswordForThisInstance';
-- Then register the new password
```

**Restore runbook checklist:**
1. Restore the database
2. Check `is_master_key_encrypted_by_server`
3. If 0: register password via `sp_control_dbmasterkey_password`
4. Test by restarting SQL Server Agent (without restarting SQL Server) and verifying jobs that access encrypted objects complete

---

## Scenario 4: Availability Groups

Each AG replica needs independent password registration. Seeding does NOT propagate `sys.master_key_passwords`.

```sql
-- Check all AG databases on each replica
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT d.name, drs.family_guid, d.is_master_key_encrypted_by_server,
       CASE WHEN mkp.credential_id IS NULL THEN 'NOT REGISTERED' ELSE 'OK' END AS status
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
JOIN sys.dm_hadr_database_replica_states rs ON rs.database_id = d.database_id
LEFT JOIN master.sys.master_key_passwords mkp ON mkp.family_guid = drs.family_guid
WHERE d.database_id > 4 AND d.is_master_key_encrypted_by_server = 0;

-- Register on EACH replica (primary and all secondaries)
USE master;
EXEC sp_control_dbmasterkey_password
    @db_name = N'[AGDatabase]',
    @password = N'[dmk_password]',
    @action = N'add';
```

---

## Scenario 5: After RESTORE SERVICE MASTER KEY from Another Instance

Restoring the SMK from a DIFFERENT server instance invalidates all existing credential registrations (the credentials were encrypted by the source instance's SMK). Note: `ALTER SERVICE MASTER KEY REGENERATE` does NOT invalidate registrations.

```sql
-- Identify all registered databases before proceeding
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT mkp.family_guid, d.name AS database_name, c.name AS credential_name
FROM master.sys.master_key_passwords mkp
JOIN master.sys.credentials c ON mkp.credential_id = c.credential_id
LEFT JOIN sys.database_recovery_status drs ON drs.family_guid = mkp.family_guid
LEFT JOIN sys.databases d ON d.database_id = drs.database_id;

-- After restoring foreign SMK: drop then re-add each registration
-- (The @password parameter is ignored for 'drop' action)
EXEC sp_control_dbmasterkey_password @db_name = N'SSISDB', @password = N'unused', @action = N'drop';
EXEC sp_control_dbmasterkey_password @db_name = N'SSISDB', @password = N'[catalog_password]', @action = N'add';

EXEC sp_control_dbmasterkey_password @db_name = N'[DB2]', @password = N'unused', @action = N'drop';
EXEC sp_control_dbmasterkey_password @db_name = N'[DB2]', @password = N'[db2_dmk_password]', @action = N'add';
```

---

## sys.master_key_passwords Reference

| Column | Type | Description |
|--------|------|-------------|
| `family_guid` | uniqueidentifier | Stable database identity — set at database creation; persists across RESTORE, ATTACH, RENAME, and `ALTER MASTER KEY REGENERATE` |
| `credential_id` | int | FK to `sys.credentials.credential_id` — the credential storing the DMK password |

```sql
-- Full registration view with database names and credential details
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT
    d.name                      AS database_name,
    d.is_master_key_encrypted_by_server,
    drs.family_guid,
    mkp.credential_id,
    c.name                      AS credential_name,  -- ##DBMKEY_<guid>_<guid>##
    c.create_date               AS registered_on,
    c.modify_date               AS last_modified
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
LEFT JOIN master.sys.master_key_passwords mkp ON mkp.family_guid = drs.family_guid
LEFT JOIN master.sys.credentials c ON mkp.credential_id = c.credential_id
WHERE d.database_id > 4
ORDER BY d.name;
```

---

## sp_control_dbmasterkey_password Quick Reference

| Parameter | Type | Description |
|-----------|------|-------------|
| `@db_name` | nvarchar | Database name (cannot be a system database) |
| `@password` | nvarchar | DMK password (ignored for `@action = 'drop'`) |
| `@action` | nvarchar | `'add'` — register; `'drop'` — remove |

**Permissions required:** sysadmin fixed server role.
**Limitation:** Does NOT verify the password actually opens the DMK (by design; validation will change in a future version).

---

## Monitoring for Unregistered DMKs

Add to SQL Agent monitoring job (weekly):

```sql
-- Alert if non-SMK DMKs lack registration
-- family_guid is in sys.database_recovery_status, not sys.databases
IF EXISTS (
    SELECT 1 FROM sys.databases d
    JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
    WHERE d.database_id > 4
      AND d.is_master_key_encrypted_by_server = 0
      AND NOT EXISTS (
        SELECT 1 FROM master.sys.master_key_passwords mkp
        WHERE mkp.family_guid = drs.family_guid
      )
)
BEGIN
    RAISERROR('WARNING: Non-SMK DMK databases without password registration detected. Run sqlencryption-review A81/A82 checks.', 16, 1);
END
```
