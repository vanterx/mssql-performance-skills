# How to Set Up Transparent Data Encryption (TDE)

TDE encrypts the entire database at rest: data files (.mdf/.ndf), transaction log (.ldf), and all full/differential/log backups. The encryption is transparent to applications — no code changes are required.

The DEK (a symmetric AES key, usually AES_256) encrypts every page before it is written to disk. The DEK itself is protected by a certificate stored in the `master` database. The certificate's private key is in turn protected by the master database's DMK, which is protected by the instance-level SMK (see `concepts.md` for the full key hierarchy).

## Prerequisites

- SQL Server 2008 or later (Standard Edition TDE is available from 2019+; earlier Standard editions do not support TDE)
- `sysadmin` or `CONTROL SERVER` permission on the instance
- `CONTROL` permission on the target database (or `db_owner` plus `CONTROL SERVER` for certificate access)
- A Database Master Key (DMK) must exist in the `master` database
- A file-system location with enough free space for the certificate backup file (the backup is small, typically ~2 KB)
- Knowledge of the target database's recovery model (simple or full); TDE works with either

Before starting, verify that a DMK exists in `master`. If it does not, create one:

```sql
USE master;
GO
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'StrongP@ssw0rd!';
GO
```

## Step 1: Create the TDE Certificate

The TDE certificate is a self-signed certificate created in `master`. Its private key is protected by the DMK. SQL Server will use this cert's asymmetric key to encrypt the DEK at database startup.

```sql
USE master;
GO
CREATE CERTIFICATE TDECert
    WITH SUBJECT = 'TDE certificate for encrypting database encryption keys';
GO
```

Best practices for naming and security:

- Use a descriptive name that includes the purpose (e.g., `TDECert_Production_2026` including a year tag for rotation tracking).
- Set an expiry date to force rotation: `EXPIRY_DATE = '2027-06-01'`. SQL Server does not enforce this for already-open databases, but it documents intent and catches attempts to use an expired cert at restore time.
- Do not specify `ENCRYPTION BY PASSWORD` for the certificate. The DMK protection path is sufficient and cleaner for operational workflows (no password prompt at restore).

Verify the certificate was created:

```sql
SELECT name, pvt_key_encryption_type_desc, expiry_date
FROM sys.certificates
WHERE name = 'TDECert';
```

`pvt_key_encryption_type_desc` should show `ENCRYPTED_BY_MASTER_KEY`.

## Step 2: Create the Database Encryption Key

The DEK is an AES symmetric key stored inside the target database. It is encrypted by the TDE certificate's public key. When SQL Server starts up, it uses the certificate's private key (via the DMK → SMK chain) to decrypt the DEK and hold it in memory.

```sql
USE [YourDatabase];
GO
CREATE DATABASE ENCRYPTION KEY
    WITH ALGORITHM = AES_256
    ENCRYPTION BY SERVER CERTIFICATE TDECert;
GO
```

Algorithm selection:

| Algorithm | Recommendation |
|-----------|---------------|
| `AES_128` | Acceptable for PCI-DSS v4 minimum; double the key size is preferred |
| `AES_192` | Valid but rarely chosen |
| `AES_256` | Recommended — strongest, required by many compliance frameworks, FIPS approved |

Do not use `TRIPLE_DES_3KEY` or `DES`. These are deprecated (NIST 2023) and fail FIPS-compliant-mode checks.

Verify the DEK:

```sql
USE [YourDatabase];
GO
SELECT db.name, db.is_encrypted, dek.encryption_state, dek.percent_complete,
       dek.key_algorithm, dek.key_length
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases db ON dek.database_id = db.database_id
WHERE db.name = DB_NAME();
GO
```

At this point `encryption_state` is `1` (unencrypted) and `is_encrypted` is `0`. That changes in the next step.

## Step 3: Enable TDE on the Database

TDE is turned on with a single `ALTER DATABASE` statement. This starts a background encryption scan that reads every page into the buffer pool, re-writes it encrypted, and flushes it to disk.

```sql
ALTER DATABASE [YourDatabase]
SET ENCRYPTION ON;
GO
```

The command returns immediately. The actual encryption scan runs asynchronously on a background worker thread. No transaction log growth occurs beyond the one initial checkpoint that flushes the encryption-state metadata.

## Step 4: Monitor the Encryption Scan

The scan progress is visible in `sys.dm_database_encryption_keys`:

```sql
SELECT db.name AS database_name,
       dek.encryption_state,
       dek.percent_complete,
       dek.key_algorithm,
       dek.key_length,
       dek.encryptor_type,
       dek.encryptor_thumbprint
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases db ON dek.database_id = db.database_id;
GO
```

`encryption_state` values:

| State | Meaning |
|-------|---------|
| 0 | No database encryption key present |
| 1 | Unencrypted (DEK exists, encryption not yet enabled) |
| 2 | Encryption in progress |
| 3 | Encrypted |
| 4 | Key change in progress (rotation) |
| 5 | Decryption in progress |
| 6 | Protection change in progress |

`percent_complete` increases from 0 to 100 as the scan processes pages. The scan performs at I/O subsystem speed; a large database may take hours. The database remains online and fully usable during the scan.

You can also check encryption state via the `is_encrypted` column in `sys.databases`, which flips to `1` once encryption is complete.

## Step 5: Back Up the TDE Certificate

**This is the most critical step.** Without a backup of the TDE certificate and its private key, encrypted databases cannot be restored to another server — ever. The backup file is small and should be stored in multiple secure locations, separate from the database backups.

```sql
USE master;
GO
BACKUP CERTIFICATE TDECert
TO FILE = 'E:\CertBackups\TDECert_TDE.cer'
WITH PRIVATE KEY (
    FILE = 'E:\CertBackups\TDECert_TDE.pvk',
    ENCRYPTION BY PASSWORD = 'StrongBackupP@ssw0rd!'
);
GO
```

Two files are produced:

| File | Extension | Contents | Sensitivity |
|------|-----------|----------|-------------|
| Certificate public key | `.cer` | The certificate's public key and metadata | Low |
| Certificate private key | `.pvk` | The private key, encrypted with the password | High — treat like a domain admin password |

Store these files:

- Off the SQL Server host entirely (different physical machine, secure network share, or Azure Key Vault)
- With the password stored in a separate secrets management system (not the same folder)
- Included in the disaster recovery runbook alongside the database backup procedure

## Step 6: Verify tempdb Encryption

When any user database on the instance has TDE enabled, SQL Server automatically encrypts `tempdb`. This is unavoidable and non-configurable. Any unencrypted database that uses `tempdb` (for spools, hash joins, temporary tables, sorts) would otherwise leak plaintext data through `tempdb` data files.

Verify that `tempdb` is encrypted:

```sql
SELECT name, is_encrypted
FROM sys.databases
WHERE name = 'tempdb';
GO
```

`is_encrypted` must be `1`. The encryption scan for `tempdb` also appears in `sys.dm_database_encryption_keys`. The performance impact on `tempdb` is generally negligible because AES-NI hardware acceleration handles encryption at memory-bandwidth speeds.

If you later remove TDE from all user databases, `tempdb` is automatically decrypted at the next SQL Server restart (the encryption state for `tempdb` persists until the instance recycles).

## Step 7: Test Disaster Recovery

A TDE backup is worthless unless you have tested that you can restore it. Run through the following on a separate (non-production) instance:

1. Copy the database backup file (a `.bak` file, now TDE-encrypted) to the test server.
2. Attempt a restore without importing the certificate first — it will fail. This is expected and proves that the backup file is indeed encrypted at rest.
3. Import the certificate from the backup files:

```sql
USE master;
GO
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'TestDMKPassword!';
GO
CREATE CERTIFICATE TDECert
FROM FILE = 'E:\CertBackups\TDECert_TDE.cer'
WITH PRIVATE KEY (
    FILE = 'E:\CertBackups\TDECert_TDE.pvk',
    DECRYPTION BY PASSWORD = 'StrongBackupP@ssw0rd!'
);
GO
```

Note: On the restore target, you need a DMK in `master` before you can import the certificate. The DMK password can be different from the source instance.

4. Restore the database:

```sql
RESTORE DATABASE [YourDatabase]
FROM DISK = 'E:\Backups\YourDatabase_Full.bak'
WITH MOVE 'YourDatabase' TO 'E:\Data\YourDatabase.mdf',
     MOVE 'YourDatabase_log' TO 'F:\Log\YourDatabase_log.ldf',
     RECOVERY;
GO
```

5. Verify the restored database is accessible and encrypted:

```sql
SELECT name, is_encrypted
FROM sys.databases
WHERE name = 'YourDatabase';
GO

USE [YourDatabase];
SELECT TOP 1 * FROM dbo.SomeTable;
GO
```

If the query succeeds, the DR procedure is validated.

## Common Errors

| Error | Message text | Cause and resolution |
|-------|-------------|---------------------|
| **Msg 15581** | "Cannot drop the database encryption key because it is currently in use." | TDE must be turned off first: `ALTER DATABASE [db] SET ENCRYPTION OFF;` then wait for decryption to complete (`encryption_state = 1`) before dropping the DEK. |
| **Msg 33111** | "Cannot find server certificate with thumbprint '0x...'." | The certificate was not imported to the restore target's `master` database, or the certificate thumbprint does not match the one used to encrypt the DEK. Import the correct certificate from your secure backup. |
| **Msg 33104** | "Cannot decrypt the database encryption key because the server certificate is …" | The certificate exists but its private key cannot be decrypted. The DMK in `master` does not exist or was restored with a different SMK. Open the DMK with `OPEN MASTER KEY DECRYPTION BY PASSWORD = '...';` then run `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;` to re-establish the SMK auto-decrypt chain. |
| **Msg 15578** | "The database encryption key is encrypted by a certificate which was created with a password." | The certificate was created with `ENCRYPTION BY PASSWORD`, which means the DMK chain is not sufficient. At restore time you must open the certificate with `OPEN MASTER KEY` and `OPEN CERTIFICATE ... WITH PASSWORD`. Avoid this pattern — create certificates without a password for TDE. |
| **Msg 33106** | "Cannot change database encryption state because no database encryption key is set." | You ran `ALTER DATABASE SET ENCRYPTION ON` but never ran `CREATE DATABASE ENCRYPTION KEY`. Create the DEK first. |

## Checklist

- [ ] DMK exists in `master` (`SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##'`)
- [ ] TDE certificate created in `master` with a descriptive name and expiry date
- [ ] DEK created in the target database with `AES_256`
- [ ] `ALTER DATABASE SET ENCRYPTION ON` executed
- [ ] Encryption scan completed (`percent_complete = 100`, `encryption_state = 3`)
- [ ] `tempdb` confirmed encrypted (`is_encrypted = 1`)
- [ ] Certificate backed up with private key to a secure off-server location
- [ ] Backup password stored in a separate secrets vault (not alongside the .pvk file)
- [ ] Full disaster-recovery restore tested on a non-production instance
- [ ] Certificate expiry date noted in calendar for rotation (recommended: 1 year)
- [ ] Database backups taken after encryption completes are encrypted and tested
- [ ] Encryption state documented in the operational runbook (cert name, instance, databases covered)
