# sqlencryption-review — Check Explanations

Plain-English explanation of all 112 A-checks. Load this file when a user asks "explain check A-N", "why does A-N fire?", "how do I fix A-N?", or needs deeper context beyond the three-part summary in SKILL.md.

For foundational encryption concepts (symmetric/asymmetric, TLS versions, key hierarchy, PCI-DSS/HIPAA/GDPR), read `concepts.md`.
For step-by-step operational guides (TDE setup, TLS config, key rotation, crypto-shredding, disaster recovery), read the appropriate `howto-*.md` file in this directory.

---

## Contents

- [Quick Reference Table](#quick-reference-table)
- [TDE — A1–A8](#tde--a1a8)
- [Always Encrypted — A9–A16](#always-encrypted--a9a16)
- [Cell-Level Encryption — A17–A21](#cell-level-encryption--a17a21)
- [Backup Encryption — A22–A25](#backup-encryption--a22a25)
- [Transport and Connection Encryption — A26–A30](#transport-and-connection-encryption--a26a30)
- [Certificate Management — A31–A38](#certificate-management--a31a38)
- [Asymmetric and Symmetric Key Management — A39–A43](#asymmetric-and-symmetric-key-management--a39a43)
- [Key Hierarchy DMK and SMK — A44–A48](#key-hierarchy-dmk-and-smk--a44a48)
- [EKM and Azure Key Vault — A49–A52](#ekm-and-azure-key-vault--a49a52)
- [Compliance and Coverage — A53–A56](#compliance-and-coverage--a53a56)
- [TLS and Network Hardening — A57–A62](#tls-and-network-hardening--a57a62)
- [Always Encrypted Advanced — A63–A67](#always-encrypted-advanced--a63a67)
- [Operational Key Lifecycle — A68–A72](#operational-key-lifecycle--a68a72)
- [SQL Server Ledger — A73–A76](#sql-server-ledger--a73a76)
- [Azure-Specific Encryption — A77–A80](#azure-specific-encryption--a77a80)
- [DMK Password Auto-Open — A81–A86](#dmk-password-auto-open--a81a86)
- [Dynamic Data Masking and Permission Patterns — A87–A91](#dynamic-data-masking-and-permission-patterns--a87a91)
- [Compliance Explicit Checks — A92–A98](#compliance-explicit-checks--a92a98)
- [Operational Validation — A99–A104](#operational-validation--a99a104)
- [Advanced Cryptographic Patterns — A105–A112](#advanced-cryptographic-patterns--a105a112)

---

## Quick Reference Table

| ID | Category | Title | Severity |
|----|----------|-------|---------|
| A1 | TDE | TDE not enabled on user database | Warning / Critical |
| A2 | TDE | TDE encryption scan in progress | Info |
| A3 | TDE | TDE certificate not backed up | Critical |
| A4 | TDE | TDE certificate expired or expiring | Critical / Warning |
| A5 | TDE | DEK using non-AES_256 algorithm | Critical / Warning |
| A6 | TDE | Multiple databases sharing one TDE certificate | Warning |
| A7 | TDE | TDE on master / model / msdb | Info |
| A8 | TDE | tempdb encrypted but no user DB encrypted | Warning |
| A9 | Always Encrypted | Deterministic encryption on non-searchable columns | Info |
| A10 | Always Encrypted | Randomized encryption with no secure enclave | Warning |
| A11 | Always Encrypted | Column encryption algorithm not AEAD_AES_256_CBC_HMAC_SHA_256 | Warning |
| A12 | Always Encrypted | Secure enclave not configured (SQL 2019+) | Info |
| A13 | Always Encrypted | CMK in Windows Certificate Store | Warning |
| A14 | Always Encrypted | Sensitive-pattern columns without AE | Warning |
| A15 | Always Encrypted | No CEK rotation performed | Info |
| A16 | Always Encrypted | CMK not rotated in over 2 years | Warning |
| A17 | CLE | Symmetric key using deprecated algorithm | Critical / Warning |
| A18 | CLE | OPEN SYMMETRIC KEY without CLOSE | Warning |
| A19 | CLE | Symmetric key protected by password only | Warning |
| A20 | CLE | Symmetric key never rotated | Info / Warning |
| A21 | CLE | Both CLE and AE on same table | Warning |
| A22 | Backup | Recent backups not encrypted | Critical |
| A23 | Backup | Backup encryption certificate not backed up | Critical |
| A24 | Backup | Backup encryption using weak algorithm | Warning |
| A25 | Backup | Backup encryption certificate expiring | Critical / Warning |
| A26 | Transport | ForceEncryption not enabled | Warning |
| A27 | Transport | Active remote connections unencrypted | Warning |
| A28 | Transport | SQL Server using self-signed TLS cert | Info / Warning |
| A29 | Transport | TrustServerCertificate=TRUE in use | Warning |
| A30 | Transport | TLS certificate expiring | Critical / Warning |
| A31 | Certificates | Certificate private key unprotected | Warning / Critical |
| A32 | Certificates | Service Broker cert not rotated (>2 years) | Info |
| A33 | Certificates | AG endpoint cert expiring | Critical |
| A34 | Certificates | Cert-based login with elevated permissions | Critical |
| A35 | Certificates | Certificate signed with MD5 or SHA1 | Critical / Warning |
| A36 | Certificates | Cert from self-signed or untrusted CA | Warning |
| A37 | Certificates | No BACKUP CERTIFICATE evidence | Critical |
| A38 | Certificates | Multiple certs with same Subject/CN | Warning |
| A39 | Keys | Asymmetric key using RSA_512 or RSA_1024 | Critical / Warning |
| A40 | Keys | CONTROL permission on key to non-sysadmin | Warning |
| A41 | Keys | Symmetric key not rotated in 2+ years | Warning |
| A42 | Keys | Orphaned encryption keys | Info |
| A43 | Keys | Non-unique KEY_SOURCE | Warning |
| A44 | Hierarchy | DMK not backed up | Critical |
| A45 | Hierarchy | DMK not protected by SMK | Warning |
| A46 | Hierarchy | DMK password-only protection | Warning |
| A47 | Hierarchy | SMK never backed up | Critical |
| A48 | Hierarchy | Linked server encryption not enforced | Warning |
| A49 | EKM/AKV | EKM provider inactive or in error | Critical |
| A50 | EKM/AKV | AKV BYOK TDE without automatic rotation | Warning |
| A51 | EKM/AKV | Service-managed TDE in regulated environment | Info |
| A52 | EKM/AKV | EKM provider version outdated | Warning |
| A53 | Compliance | Sensitivity-classified columns without encryption | Warning |
| A54 | Compliance | Sensitive-pattern columns without encryption | Warning |
| A55 | Compliance | Non-FIPS algorithm in encryption hierarchy | Critical / Warning |
| A56 | Compliance | No audit for cryptographic key access | Info |
| A57 | TLS Hardening | TLS 1.0 or 1.1 enabled at OS level | Warning |
| A58 | TLS Hardening | Weak TLS cipher suites enabled | Warning |
| A59 | TLS Hardening | TLS 1.3 not enforced on SQL 2022+ | Info |
| A60 | TLS Hardening | IPsec not configured as compensating control | Info |
| A61 | TLS Hardening | Kerberos armoring (FAST) not enforced | Info |
| A62 | TLS Hardening | Named Pipes protocol enabled in production | Warning |
| A63 | AE Advanced | Enclave attestation URL not configured | Warning |
| A64 | AE Advanced | AE driver version incompatible with enclave | Warning |
| A65 | AE Advanced | CEK caching disabled or misconfigured | Info |
| A66 | AE Advanced | Enclave configured but no enclave-enabled queries | Info |
| A67 | AE Advanced | Relaxed enclave attestation in production | Warning |
| A68 | Key Lifecycle | DMK/SMK backup password lacks complexity | Warning |
| A69 | Key Lifecycle | TLS cert not configured for auto-enrollment | Info |
| A70 | Key Lifecycle | No key archival or escrow procedure | Warning |
| A71 | Key Lifecycle | TDE scan I/O impact never baselined | Info |
| A72 | Key Lifecycle | Full-recovery DB without log backup encryption | Info |
| A73 | Ledger | Ledger not enabled on compliance database | Info |
| A74 | Ledger | Ledger digest not configured for auto-storage | Warning |
| A75 | Ledger | Ledger hash algorithm not SHA-256 | Info |
| A76 | Ledger | Ledger verification not scheduled | Warning |
| A77 | Azure | TDE protector key vault in different region | Warning |
| A78 | Azure | Double encryption not enabled | Info |
| A79 | Azure | Enclave attestation shared across tenants | Warning |
| A80 | Azure | Audit logs not encrypted at rest | Info |
| A81 | DMK Password | Non-SMK DMK without registered password | Warning |
| A82 | DMK Password | SSISDB DMK not registered | Critical |
| A83 | DMK Password | SMK restored from foreign instance: registrations invalidated | Warning |
| A84 | DMK Password | Non-SMK DMK with no auto-open path | Warning |
| A85 | DMK Password | Restored DB non-SMK DMK not re-registered | Warning |
| A86 | DMK Password | AG secondary non-SMK DMK not registered | Warning |
| A87 | DDM/Permissions | Sensitive column masked but not encrypted | Warning |
| A88 | DDM/Permissions | UNMASK granted to broad role | Warning |
| A89 | DDM/Permissions | CONTROL on certificate to non-sysadmin | Warning |
| A90 | DDM/Permissions | RLS predicate on Always Encrypted column | Warning |
| A91 | DDM/Permissions | CLE column without masked fallback | Info |
| A92 | Compliance+ | PCI-DSS v4: PAN without column-level encryption | Critical |
| A93 | Compliance+ | PCI-DSS v4: no annual key rotation evidence | Warning |
| A94 | Compliance+ | GDPR Art. 17: PII in append-only ledger | Warning |
| A95 | Compliance+ | FIPS: Windows FIPS mode not enabled | Warning |
| A96 | Compliance+ | FIPS: software-only EKM provider | Warning |
| A97 | Compliance+ | No key custodian or management policy | Info |
| A98 | Compliance+ | HIPAA: PHI columns without encryption and audit | Warning |
| A99 | Ops Validation | SQL Agent job step with hardcoded key password | Critical |
| A100 | Ops Validation | Plan cache contains key password | Critical |
| A101 | Ops Validation | AKV soft-delete or purge protection disabled | Critical |
| A102 | Ops Validation | No annual backup restore test | Warning |
| A103 | Ops Validation | sys.credentials not rotated in 1+ year | Info |
| A104 | Ops Validation | AG listener TLS SAN mismatch | Warning |
| A105 | Crypto Patterns | TLS cipher suites: ECDHE not prioritised | Info |
| A106 | Crypto Patterns | Remote connections using NTLM | Info |
| A107 | Crypto Patterns | Service Broker remote cert not imported | Warning |
| A108 | Crypto Patterns | ENCRYPTBYPASSPHRASE with weak passphrase | Warning |
| A109 | Crypto Patterns | HASHBYTES with deprecated algorithm | Warning |
| A110 | Crypto Patterns | Database Mail SMTP without modern auth | Info |
| A111 | Crypto Patterns | ENCRYPTBYCERT without cert expiry monitoring | Warning |
| A112 | Crypto Patterns | Azure SQL MI managed identity missing AKV perms | Critical |

---

## A1–A8: Transparent Data Encryption (TDE)

### A1 — TDE not enabled on user database

**What it means**
Transparent Data Encryption encrypts the physical data files (.mdf, .ndf) and log file (.ldf) at rest. Without TDE, anyone who gains access to the files — backup tapes, decommissioned drives, cold storage — can read the data using any SQL Server installation, bypassing all SQL authentication. TDE is the foundation of "storage-level" data protection.

**How to spot it**
```sql
SELECT name, is_encrypted
FROM sys.databases
WHERE database_id > 4  -- exclude master, tempdb, model, msdb
  AND is_encrypted = 0;
```
Any row returned is a user database without TDE.

**Example**
```
name          is_encrypted
------------- ------------
SalesDB       0            -- Warning: production database without TDE
HRPortal      0            -- Critical: name contains 'HR', a sensitive pattern
```

**Fix options**
1. In master: `CREATE CERTIFICATE TDE_SalesDB WITH SUBJECT = 'TDE cert for SalesDB'`
2. In SalesDB: `CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE TDE_SalesDB`
3. `ALTER DATABASE SalesDB SET ENCRYPTION ON` — triggers the encryption scan
4. Monitor progress: `SELECT percent_complete FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('SalesDB')`

**Related checks:** A2 (scan in progress), A3 (cert backup), A4 (cert expiry), A5 (algorithm), A6 (shared cert)

---

### A2 — TDE encryption scan in progress

**What it means**
When TDE is first enabled (or re-keyed), SQL Server performs a background scan to encrypt every page in the database. `encryption_state = 2` means encryption is in progress; `encryption_state = 4` means decryption is in progress (TDE being removed). The scan is I/O-intensive and proportional to database size.

**How to spot it**
```sql
SELECT d.name, dek.encryption_state, dek.encryption_state_desc, dek.percent_complete
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases d ON dek.database_id = d.database_id
WHERE dek.encryption_state IN (2, 4);
```

**Example**
```
name     encryption_state  encryption_state_desc  percent_complete
-------- ----------------  ---------------------- ----------------
SalesDB  2                 ENCRYPTION_IN_PROGRESS 34.7
```

**Fix options**
1. **SQL 2016 and earlier**: wait; cannot pause or stop
2. **SQL 2019+**: `ALTER DATABASE SalesDB SET ENCRYPTION SUSPEND` to pause during peak hours; `ALTER DATABASE SalesDB SET ENCRYPTION RESUME` to continue during off-peak
3. Schedule encryption scans to start during off-peak; avoid large index rebuilds or DBCC CHECKDB during the scan window

**Related checks:** A1 (TDE setup), A5 (algorithm regeneration which also triggers scan)

---

### A3 — TDE certificate not backed up

**What it means**
The TDE certificate in master DB is the key that wraps the Database Encryption Key. Without a backup of this certificate and its private key, it is impossible to restore a TDE-encrypted database to any server other than the one that created it — not even the same server after an OS reinstall. This is the single most common TDE disaster scenario.

**How to spot it**
No DMV shows certificate backup history; look for a BACKUP CERTIFICATE statement in SQL Agent job history or maintenance scripts. If there's nothing, the cert is not backed up.

```sql
-- Identify TDE certs in master (requires connection to master)
SELECT name, certificate_id, expiry_date, pvt_key_encryption_type_desc
FROM master.sys.certificates
WHERE name NOT LIKE '##%';
```

**Example**
A new DBA restores a full backup to a DR server. SQL Server reports:
`Msg 33111, Level 16: Cannot find server certificate with thumbprint '0x...'`
The TDE certificate was never exported. The backup is unrestorable.

**Fix options**
1. Back up immediately: `BACKUP CERTIFICATE TDE_SalesDB TO FILE = 'C:\CertBackups\TDE_SalesDB.cer' WITH PRIVATE KEY (FILE = 'C:\CertBackups\TDE_SalesDB.pvk', ENCRYPTION BY PASSWORD = 'use-a-strong-vault-password')`
2. Store .cer, .pvk, and the password in **three separate** locations: off-server vault, DR site, and a secure password manager
3. Create a SQL Agent job to alert if no cert backup has been performed in the last 30 days
4. Document the restore procedure in the DR runbook and test it on a non-production server

**Related checks:** A4 (expiry), A6 (shared cert risk), A37 (all cert backups)

---

### A4 — TDE certificate expired or expiring within 90 days

**What it means**
Certificates have a `NotAfter` date. An expired TDE certificate does not prevent SQL Server from *running* — the DEK is loaded at startup and the cert is only checked then. However, restoring a backup to a new server requires importing the TDE certificate. An expired certificate can be imported in some versions but causes confusion and failures. More importantly, the same certificate is often used for backup encryption where expiry is operationally enforced.

**How to spot it**
```sql
SELECT c.name, c.expiry_date, DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_remaining
FROM master.sys.certificates c
WHERE c.name NOT LIKE '##%'
  AND c.thumbprint IN (
      SELECT encryptor_thumbprint FROM sys.dm_database_encryption_keys
  )
  AND c.expiry_date < DATEADD(DAY, 90, GETDATE());
```

**Example**
```
name             expiry_date    days_remaining
---------------- -------------- --------------
TDE_ProductionDB 2025-08-15     22              -- Critical: expires in 22 days
```

**Fix options**
1. Create replacement cert: `CREATE CERTIFICATE TDE_ProductionDB_2026 WITH SUBJECT = 'TDE ProductionDB replacement', EXPIRY_DATE = '2028-01-01'`
2. Re-key the database's DEK: `ALTER DATABASE ProductionDB ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE TDE_ProductionDB_2026`
3. Wait for the re-encryption scan to complete
4. Keep the old certificate for 90+ days after rotation (needed to restore backups taken before the switch)
5. Back up the new certificate (A3 fix)

**Related checks:** A3 (cert backup), A5 (algorithm)

---

### A5 — TDE DEK using non-AES_256 algorithm

**What it means**
The Database Encryption Key (DEK) can be created with AES_128, AES_192, AES_256, or TRIPLE_DES_3KEY. TRIPLE_DES_3KEY has been deprecated by NIST since 2023 and is prohibited by PCI-DSS v4. AES_128 and AES_192 are FIPS-approved but AES_256 is the standard recommendation for compliance frameworks.

**How to spot it**
```sql
SELECT d.name, dek.key_algorithm, dek.key_length
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases d ON dek.database_id = d.database_id;
```

**Example**
```
name       key_algorithm  key_length
---------- -------------  ----------
LegacyDB   TRIPLE_DES_3KEY  192      -- Critical: deprecated algorithm
OldPayroll AES_128         128      -- Warning: prefer AES_256 for PCI
```

**Fix options**
1. `ALTER DATABASE LegacyDB ENCRYPTION KEY REGENERATE WITH ALGORITHM = AES_256` — this triggers another full-database encryption scan; plan I/O impact
2. Monitor progress: `SELECT percent_complete FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('LegacyDB')`
3. Note: AES_256 adds negligible performance overhead on modern CPUs with AES-NI hardware acceleration

**Related checks:** A2 (scan impact), A55 (FIPS compliance)

---

### A6 — Multiple databases sharing the same TDE certificate

**What it means**
SQL Server allows multiple databases to be protected by the same TDE certificate. This simplifies initial setup but creates operational risk: rotating the certificate means re-keying all affected databases simultaneously; a certificate compromise affects all databases at once; a failed rotation leaves all covered databases in a degraded state.

**How to spot it**
```sql
SELECT c.name AS certificate_name, COUNT(*) AS database_count,
       STRING_AGG(d.name, ', ') AS databases
FROM sys.dm_database_encryption_keys dek
JOIN master.sys.certificates c ON dek.encryptor_thumbprint = c.thumbprint
JOIN sys.databases d ON dek.database_id = d.database_id
GROUP BY c.name
HAVING COUNT(*) > 1;
```

**Example**
```
certificate_name   database_count  databases
------------------ --------------- ---------------------------
TDE_AllDatabases   4               SalesDB, HRDB, FinanceDB, PayrollDB
```

**Fix options**
1. Issue a dedicated TDE certificate per database: `CREATE CERTIFICATE TDE_SalesDB WITH SUBJECT = 'TDE cert for SalesDB only'`
2. Re-key each database to its own cert: `ALTER DATABASE SalesDB ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE TDE_SalesDB`
3. Adopt naming convention: `TDE_[DatabaseName]_[Year]` for easy lifecycle tracking
4. Back up each new certificate individually

**Related checks:** A3 (backup each cert), A4 (track expiry per cert)

---

### A7 — TDE enabled on master, model, or msdb

**What it means**
SQL Server automatically encrypts tempdb when any user database uses TDE (this is expected and correct). However, explicitly encrypting master, model, or msdb is unusual and can cause complications: encrypted master can complicate restore operations, DAC (Dedicated Admin Connection) during emergencies, and AG seeding operations that touch system databases.

**How to spot it**
```sql
SELECT d.name, d.is_encrypted
FROM sys.databases d
WHERE d.database_id IN (1, 2, 3)  -- master=1, tempdb=2, model=3
  AND d.is_encrypted = 1
  AND d.name != 'tempdb';         -- tempdb is expected
```

**Example**
```
name    is_encrypted
------- ------------
master  1            -- Info: unusual; verify intent
```

**Fix options**
1. Confirm whether this was intentional (some CIS benchmarks do recommend it; some DR procedures do not)
2. If inadvertent: `ALTER DATABASE master SET ENCRYPTION OFF` — triggers a decryption scan
3. Verify DAC and emergency restore procedures work correctly after removing TDE from master

**Related checks:** A8 (tempdb artifact)

---

### A8 — tempdb encrypted but no user database is encrypted

**What it means**
tempdb is encrypted automatically as a side-effect of TDE on user databases. If all TDE-enabled user databases have since been decrypted or dropped, tempdb remains encrypted — it does not self-disable. This adds I/O and CPU overhead to all tempdb operations (sorts, hash joins, spills, temp tables) with no data-protection benefit.

**How to spot it**
```sql
SELECT d.name, d.is_encrypted
FROM sys.databases d
WHERE d.is_encrypted = 1;
-- If only 'tempdb' appears and no user databases, this check fires
```

**Fix options**
1. Determine whether TDE should be re-enabled on user databases (perhaps it was accidentally disabled)
2. If TDE is intentionally off: disable TDE on the last user database, wait for the decryption scan to complete, then restart SQL Server — tempdb will no longer be encrypted
3. Monitor with `sys.dm_database_encryption_keys` after restart

**Related checks:** A2 (scan progress), A7 (system DB encryption)

---

## A9–A16: Always Encrypted

### A9 — Deterministic encryption on non-searchable columns

**What it means**
Always Encrypted supports two encryption types: deterministic (encrypts the same plaintext to the same ciphertext every time — enables equality comparisons) and randomized (uses a fresh random IV each time — higher privacy, but equality comparisons fail without a secure enclave). Deterministic encryption reveals frequency distribution: an attacker who can observe ciphertext values can tell when two rows have the same plaintext even without decrypting either. For columns that are never searched, this leakage is unnecessary.

**How to spot it**
```sql
SELECT SCHEMA_NAME(t.schema_id) + '.' + t.name AS table_col,
       c.name, c.encryption_type_desc
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
WHERE c.encryption_type = 1  -- DETERMINISTIC
ORDER BY table_col;
```

Review the column names: if a column is `middle_name`, `notes`, `full_address`, or similar non-key/non-filter fields, randomized is more appropriate.

**Example**
```
table_col               name          encryption_type_desc
----------------------- ------------- --------------------
dbo.Customers.MiddleName DETERMINISTIC -- should be RANDOMIZED
dbo.Customers.SSN        DETERMINISTIC -- correct: used in WHERE clause
```

**Fix options**
1. Use SSMS → Always Encrypted wizard → select column → change to Randomized
2. Or PowerShell: `Set-SqlColumnEncryption -InputObject $db -ColumnEncryptionSettings @(New-SqlColumnEncryptionSettings -ColumnName 'dbo.Customers.MiddleName' -EncryptionType Randomized -EncryptionKey $cek)`
3. Coordinate with application team to verify no queries filter on this column

**Related checks:** A10 (randomized without enclave), A12 (secure enclave for range queries)

---

### A10 — Randomized encryption where equality queries are needed, no secure enclave

**What it means**
Randomized AE encryption provides better privacy but SQL Server cannot natively evaluate predicates on randomized-encrypted columns without a secure enclave. Applications that try to query `WHERE ssn = @ssn` on a randomized column will get "Operand type clash: encrypted nchar(11) is incompatible with nchar" errors. This is a functional defect that breaks the application.

**How to spot it**
```sql
-- Find randomized-encrypted columns
SELECT t.name AS table_name, c.name AS column_name, c.encryption_type_desc
FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
WHERE c.encryption_type = 2;  -- RANDOMIZED

-- Check if secure enclave is configured
SELECT name, value_in_use FROM sys.configurations
WHERE name = 'column encryption enclave type';
-- 0 = no enclave; 1 = VBS enclave
```

**Example**
An application reports: `SqlException: Operand type clash: encrypted nvarchar(20) is incompatible with nvarchar(20)` when querying by SSN. The SSN column uses RANDOMIZED encryption and there is no secure enclave.

**Fix options**
1. **Short-term**: Switch the column to DETERMINISTIC if only equality comparisons are needed and frequency leakage is acceptable
2. **Long-term**: Configure a secure enclave (SQL 2019+ with Windows Server 2019+):
   - `EXEC sp_configure 'column encryption enclave type', 1; RECONFIGURE`
   - Configure VBS attestation in Windows Server
   - Update client connection string: `Column Encryption Setting=Enabled;Enclave Attestation Url=https://[attest-server]/attest/SgxEnclave`
3. Coordinate with application team — application must use an enclave-enabled driver version

**Related checks:** A9 (deterministic), A12 (enclave setup)

---

### A11 — Column encryption algorithm not AEAD_AES_256_CBC_HMAC_SHA_256

**What it means**
The standard Always Encrypted column algorithm is `AEAD_AES_256_CBC_HMAC_SHA_256` — Authenticated Encryption with Associated Data using AES-256-CBC with HMAC-SHA-256 authentication. The authentication component (HMAC) prevents an attacker from manipulating ciphertext and having SQL Server accept it. A non-standard algorithm lacks this guarantee.

**How to spot it**
```sql
SELECT t.name AS table_name, c.name AS column_name, c.encryption_algorithm_name
FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
WHERE c.column_encryption_key_id IS NOT NULL
  AND c.encryption_algorithm_name != 'AEAD_AES_256_CBC_HMAC_SHA_256';
```

**Fix options**
1. Drop the column's AE definition; recreate with the standard algorithm
2. Or use `Set-SqlColumnEncryption` with `AlgorithmName = 'AEAD_AES_256_CBC_HMAC_SHA_256'`
3. Requires application downtime during migration

**Related checks:** A55 (FIPS compliance)

---

### A12 — Secure enclave not configured for range / LIKE queries (SQL 2019+)

**What it means**
Secure enclaves allow SQL Server 2019+ to perform confidential computations on encrypted data inside a hardware-protected memory region. Without enclaves, queries like `WHERE salary BETWEEN 50000 AND 100000` or `WHERE name LIKE N'Smi%'` are impossible on AE-encrypted columns. This is not a security vulnerability — it is a missing capability that limits Always Encrypted's usefulness.

**How to spot it**
```sql
SELECT name, value_in_use FROM sys.configurations
WHERE name = 'column encryption enclave type';
-- 0 = disabled; 1 = VBS (Virtualization Based Security)
```

**Fix options**
1. Verify Windows Server version: VBS enclaves require Windows Server 2019 or later
2. Enable: `EXEC sp_configure 'column encryption enclave type', 1; RECONFIGURE`
3. Configure attestation: deploy Microsoft Azure Attestation service or a local HGS (Host Guardian Service) for on-premises
4. Update SQL Server driver on application servers to support enclaves
5. Test with: `SELECT GETDATE()` with enclave-enabled connection to verify attestation works

**Related checks:** A9, A10

---

### A13 — CMK stored in Windows Certificate Store (not HSM or AKV)

**What it means**
The Column Master Key (CMK) is the top of the Always Encrypted key hierarchy — it protects all Column Encryption Keys (CEKs). The CMK never enters SQL Server; it lives in the client's key store. When the CMK is in the Windows Certificate Store, the private key is stored on the machine's disk (protected by DPAPI). If someone extracts the certificate (or accesses the machine), the CMK is compromised and all AE-encrypted data becomes readable.

**How to spot it**
```sql
SELECT name, key_store_provider_name, key_path
FROM sys.column_master_keys
WHERE key_store_provider_name = 'MSSQL_CERTIFICATE_STORE';
```

**Fix options**
1. Generate a new RSA_2048+ key in Azure Key Vault or a FIPS 140-2 Level 3 HSM
2. Create a new CMK in SQL Server: `CREATE COLUMN MASTER KEY [CMK_AKV] WITH (KEY_STORE_PROVIDER_NAME = 'AZURE_KEY_VAULT', KEY_PATH = 'https://[vault].vault.azure.net/keys/[key]/[version]')`
3. Rotate CEKs to the new CMK using SSMS wizard
4. Drop the old CMK after verifying all CEKs have been re-encrypted

**Related checks:** A16 (CMK rotation), A15 (CEK rotation)

---

### A14 — Sensitive-pattern column names without Always Encrypted protection

**What it means**
Column names like `ssn`, `credit_card`, `password`, `dob`, and `salary` are strong indicators of regulated data. Without encryption, these columns are readable by any user with SELECT permission on the table — including DBAs, developers, report writers, and anyone with SQL Server access. This is likely a compliance violation under PCI-DSS, HIPAA, or GDPR.

**How to spot it**
```sql
SELECT SCHEMA_NAME(t.schema_id) + '.' + t.name AS table_name,
       c.name AS column_name, c.system_type_id, c.max_length
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
WHERE c.column_encryption_key_id IS NULL
  AND (
      c.name LIKE '%ssn%' OR c.name LIKE '%credit_card%' OR c.name LIKE '%cvv%'
      OR c.name LIKE '%password%' OR c.name LIKE '%salary%' OR c.name LIKE '%tax_id%'
      OR c.name LIKE '%passport%' OR c.name LIKE '%dob%' OR c.name LIKE '%diagnosis%'
  );
```

**Fix options**
1. Confirm column data with the data owner — naming sometimes doesn't match content
2. Apply AE using SSMS Encrypt Columns wizard or `Set-SqlColumnEncryption`
3. For non-AE candidates (complex stored procedures, aggregations): apply CLE with AES_256
4. Add sensitivity classification: `ADD SENSITIVITY CLASSIFICATION TO [schema].[table].[column] WITH (LABEL = 'Confidential', INFORMATION_TYPE = 'Credentials', RANK = HIGH)`
5. Coordinate with the application team — AE requires driver changes (COLUMN_ENCRYPTION_SETTING=Enabled in connection string)

**Related checks:** A53 (sensitivity classifications), A54 (pattern columns), A17 (CLE fallback)

---

### A15 — No CEK rotation performed

**What it means**
Column Encryption Keys (CEKs) protect the actual column data. `sys.column_encryption_key_values` records the history of CMK versions used to protect each CEK — if a CEK has only one record with a single CMK version, the CEK has never been rotated. Annual rotation limits the exposure window if a CEK is ever compromised.

**How to spot it**
```sql
SELECT cek.name AS cek_name, cek.create_date,
       COUNT(cekv.column_master_key_id) AS cmk_version_count,
       DATEDIFF(DAY, cek.create_date, GETDATE()) AS age_days
FROM sys.column_encryption_keys cek
JOIN sys.column_encryption_key_values cekv ON cek.column_encryption_key_id = cekv.column_encryption_key_id
GROUP BY cek.name, cek.create_date
HAVING COUNT(cekv.column_master_key_id) = 1
   AND cek.create_date < DATEADD(YEAR, -1, GETDATE());
```

**Fix options**
1. Generate or identify a new CMK (rotate CMK first if needed per A16)
2. Add new CEK value: in SSMS → Always Encrypted → Rotate Column Encryption Key
3. Or PowerShell: uses `Get-SqlColumnEncryptionKey` → decrypt with old CMK → encrypt with new CMK → `Set-SqlColumnEncryptionKey`
4. After confirming all application instances use the new CMK, drop the old CMK reference

**Related checks:** A16 (CMK rotation), A13 (CMK store)

---

### A16 — Column Master Key not rotated in over 2 years

**What it means**
The CMK is the root of the Always Encrypted hierarchy. Unlike CEKs, the CMK does not directly encrypt data — it encrypts CEKs. CMK rotation involves re-wrapping all CEK values with the new CMK. If the Windows cert store or AKV key containing the CMK private key is ever compromised, all AE data becomes readable to the attacker. Regular rotation limits this exposure window.

**How to spot it**
```sql
SELECT name, key_store_provider_name, create_date,
       DATEDIFF(DAY, create_date, GETDATE()) AS age_days
FROM sys.column_master_keys
WHERE create_date < DATEADD(YEAR, -2, GETDATE());
```

**Fix options**
1. SSMS: Right-click column master key in Object Explorer → Rotate
2. PowerShell: `Invoke-SqlColumnMasterKeyRotation -InputObject $db -SourceColumnMasterKeyName [OldCMK] -TargetColumnMasterKeyName [NewCMK]`
3. Propagate new CMK to all application servers and secondary replicas before completing rotation
4. Set a calendar reminder or Key Vault expiry policy to alert 90 days before the next rotation is due

**Related checks:** A13 (CMK store), A15 (CEK rotation)

---

## A17–A21: Cell-Level Encryption (CLE)

### A17 — Symmetric key using deprecated or broken algorithm

**What it means**
Cell-Level Encryption uses symmetric keys to encrypt individual cell values via `ENCRYPTBYKEY()`. The algorithm chosen when the key was created determines its strength. RC4 and RC2 are cryptographically broken and must be replaced immediately. DES (56-bit) and DESX are brute-forceable with commodity hardware. TRIPLE_DES has been deprecated by NIST since 2023.

**How to spot it**
```sql
SELECT name, algorithm_desc, key_length, create_date
FROM sys.symmetric_keys
WHERE algorithm_desc IN ('DES', 'Triple_DES', 'RC2', 'RC4', 'DESX', 'TRIPLE_DES_3KEY')
  AND name NOT LIKE '##%';
```

**Example**
```
name           algorithm_desc  key_length
-------------- --------------- ----------
LegacyCustKey  RC4             128        -- Critical: RC4 is broken
OldPayrollKey  TRIPLE_DES      168        -- Warning: deprecated
```

**Fix options**
1. Create replacement: `CREATE SYMMETRIC KEY PayrollKey_2025 WITH ALGORITHM = AES_256, ENCRYPTION BY CERTIFICATE DataProtectionCert`
2. Re-encrypt in batches:
   ```sql
   OPEN SYMMETRIC KEY LegacyCustKey DECRYPTION BY CERTIFICATE DataProtectionCert
   OPEN SYMMETRIC KEY PayrollKey_2025 DECRYPTION BY CERTIFICATE DataProtectionCert
   UPDATE PayrollData
   SET EncryptedSalary = ENCRYPTBYKEY(KEY_GUID('PayrollKey_2025'),
                                       DECRYPTBYKEY(EncryptedSalary))
   WHERE EncryptedSalary IS NOT NULL
   CLOSE SYMMETRIC KEY LegacyCustKey
   CLOSE SYMMETRIC KEY PayrollKey_2025
   ```
3. After verifying all data re-encrypted: `DROP SYMMETRIC KEY LegacyCustKey`

**Related checks:** A18 (open key scope), A55 (FIPS), A20 (rotation)

---

### A18 — OPEN SYMMETRIC KEY without CLOSE in same scope

**What it means**
A symmetric key opened with `OPEN SYMMETRIC KEY` remains open for the entire session until explicitly closed or the session ends. In a connection-pooled application, sessions are reused, meaning a key opened in one request may still be open when the connection is reused by a different user or request. Any code running in that session can call `DECRYPTBYKEY()` without re-authenticating.

**How to spot it**
```sql
-- Check for currently open keys across sessions
SELECT s.session_id, s.login_name, ok.name AS open_key_name
FROM sys.openkeys ok
JOIN sys.dm_exec_sessions s ON ok.session_id = s.session_id;
```

In T-SQL source, look for OPEN SYMMETRIC KEY in stored procedures without a matching CLOSE.

**Example**
```sql
-- PROBLEMATIC: key remains open if an error occurs
CREATE PROCEDURE GetCustomerData @id INT AS
BEGIN
    OPEN SYMMETRIC KEY CustKey DECRYPTION BY CERTIFICATE DataCert
    SELECT DECRYPTBYKEY(ssn) FROM Customers WHERE customer_id = @id
    -- CLOSE SYMMETRIC KEY CustKey  <-- missing!
END
```

**Fix options**
```sql
CREATE PROCEDURE GetCustomerData @id INT AS
BEGIN
    BEGIN TRY
        OPEN SYMMETRIC KEY CustKey DECRYPTION BY CERTIFICATE DataCert
        SELECT CONVERT(NVARCHAR(20), DECRYPTBYKEY(ssn)) AS ssn
        FROM Customers WHERE customer_id = @id
        CLOSE SYMMETRIC KEY CustKey
    END TRY
    BEGIN CATCH
        CLOSE ALL SYMMETRIC KEYS  -- safety net
        THROW
    END CATCH
END
```

**Related checks:** A19 (password-protected key — must appear in OPEN statement)

---

### A19 — Symmetric key protected by password only

**What it means**
A symmetric key can be protected by a certificate, an asymmetric key, a password, or the DMK. When protected by password only, the password must appear in the `OPEN SYMMETRIC KEY` statement in T-SQL code — which means it appears in stored procedure definitions (visible in `sys.sql_modules`), SQL Agent job step text (visible in `msdb`), application configuration files, and potentially memory dumps. Certificate-based protection eliminates the password from T-SQL code entirely; the certificate is found automatically via the key hierarchy.

**How to spot it**
```sql
SELECT sk.name AS key_name, ke.crypt_type_desc
FROM sys.key_encryptions ke
JOIN sys.symmetric_keys sk ON ke.key_id = sk.symmetric_key_id
WHERE ke.crypt_type_desc = 'ENCRYPTION BY PASSWORD'
  AND sk.symmetric_key_id NOT IN (
      SELECT key_id FROM sys.key_encryptions WHERE crypt_type_desc IN ('ENCRYPTION BY CERTIFICATE', 'ENCRYPTION BY ASYMMETRIC KEY')
  )
  AND sk.name NOT LIKE '##%';
```

**Fix options**
1. Ensure a certificate exists and is protected by the DMK: verify `master_key_encrypted_by_server = 1` in `sys.databases`
2. Add certificate protection: `ALTER SYMMETRIC KEY [CustKey] ADD ENCRYPTION BY CERTIFICATE [DataCert]`
3. Test that the key opens without a password: `OPEN SYMMETRIC KEY CustKey DECRYPTION BY CERTIFICATE DataCert`
4. Remove password protection: `ALTER SYMMETRIC KEY [CustKey] DROP ENCRYPTION BY PASSWORD = 'old_password'`
5. Remove the password from all stored procedures, agent jobs, and config files

**Related checks:** A44 (DMK backup), A45 (DMK/SMK protection), A31 (cert protection)

---

### A20 — Symmetric key never rotated (age over 365 days)

**What it means**
CLE symmetric keys are often created once and forgotten. A key that has never been rotated since creation has been in use for its entire lifetime, maximizing the exposure window if the key material was ever leaked (through logs, memory dumps, insecure key transport, or insider access). PCI-DSS Requirement 3.7.3 mandates key replacement at the end of their cryptoperiod — annually for active keys.

**How to spot it**
```sql
SELECT name, algorithm_desc, create_date, modify_date,
       DATEDIFF(DAY, create_date, GETDATE()) AS age_days
FROM sys.symmetric_keys
WHERE modify_date = create_date  -- never modified = never rotated
  AND create_date < DATEADD(YEAR, -1, GETDATE())
  AND name NOT LIKE '##%';
```

**Fix options**
1. Create new key: `CREATE SYMMETRIC KEY [OldKey_Replacement] WITH ALGORITHM = AES_256, ENCRYPTION BY CERTIFICATE [cert]`
2. Re-encrypt data in batches during a low-activity window (see A17 fix for the batch re-encryption pattern)
3. Automate with a SQL Agent job: open both keys, re-encrypt new rows, close both keys, track progress
4. After verifying all data: `CLOSE ALL SYMMETRIC KEYS; DROP SYMMETRIC KEY [OldKey]`
5. Name keys with the year: `CustKey_2025` to make rotation age obvious

**Related checks:** A17 (algorithm), A42 (orphaned keys after rotation)

---

### A21 — Both CLE and Always Encrypted applied to the same table

**What it means**
When a table has some columns using Always Encrypted and other columns using CLE (`ENCRYPTBYKEY`), the security model becomes inconsistent. AE protects data from DBAs (key never in SQL Server); CLE does not (key is in the SQL Server key hierarchy accessible to sysadmin). Mixing them creates dual maintenance burden and confuses the security boundary.

**How to spot it**
```sql
-- Tables with AE columns
SELECT DISTINCT OBJECT_NAME(c.object_id) AS table_name
FROM sys.columns c WHERE c.column_encryption_key_id IS NOT NULL
INTERSECT
-- Tables referenced in CLE function calls
SELECT DISTINCT OBJECT_NAME(p.object_id) AS table_name
FROM sys.sql_modules m
JOIN sys.objects p ON m.object_id = p.object_id
WHERE m.definition LIKE '%ENCRYPTBYKEY%';
```

**Fix options**
1. Audit which columns use CLE vs. AE on the same table
2. Migrate CLE columns to Always Encrypted: use SSMS Encrypt Columns wizard; coordinate application changes
3. If AE is not feasible for all columns, at minimum document the dual strategy and the different security guarantees for each column type
4. Remove CLE from any column already covered by AE

**Related checks:** A9–A16 (Always Encrypted), A17–A20 (CLE)

---

## A22–A25: Backup Encryption

### A22 — Recent backups not encrypted

**What it means**
An unencrypted backup file is a complete copy of the database that anyone with file-system access can restore to their own SQL Server — bypassing all SQL Server authentication, permissions, and row-level security. This is one of the most common causes of large-scale data breaches: stolen backup tapes, unsecured cloud storage, decommissioned servers with backup files.

**How to spot it**
```sql
SELECT database_name, backup_start_date, type AS backup_type, key_algorithm, encryptor_type
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -30, GETDATE())
  AND key_algorithm IS NULL  -- unencrypted
ORDER BY backup_start_date DESC;
```

**Fix options**
1. Create a backup certificate: `CREATE CERTIFICATE BackupCert WITH SUBJECT = 'Backup Encryption Certificate'`
2. Add encryption to backup commands: `BACKUP DATABASE [SalesDB] TO DISK = '...' WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = BackupCert)`
3. For Ola Hallengren's maintenance solution: add `@EncryptionAlgorithm = 'AES_256', @ServerCertificate = 'BackupCert'` to `DatabaseBackup` parameters
4. For SSMS Maintenance Plans: check the "Encrypt backup" option in the Back Up Database Task
5. Back up the backup certificate immediately (A23)

**Related checks:** A23 (cert backup), A24 (algorithm), A25 (cert expiry)

---

### A23 — Backup encryption certificate not separately backed up

**What it means**
The backup encryption certificate is the only thing standing between encrypted backups and permanent data loss. If the SQL Server instance is destroyed — by hardware failure, ransomware, or accidental deletion — and the certificate is not saved separately, every encrypted backup file is permanently unrestorable, regardless of how many copies exist.

**How to spot it**
Look for a SQL Agent job with `BACKUP CERTIFICATE` in its step text. If none exists, the cert is not backed up.

```sql
-- Check if backup jobs exist
SELECT j.name, js.step_name, js.command
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE js.command LIKE '%BACKUP CERTIFICATE%';
```

**Fix options**
1. `BACKUP CERTIFICATE BackupCert TO FILE = 'D:\Offsite\backup_cert.cer' WITH PRIVATE KEY (FILE = 'D:\Offsite\backup_cert.pvk', ENCRYPTION BY PASSWORD = 'UseAVaultForThis')`
2. Copy both files to a geographically separate location (different data centre, offline vault)
3. Store the password in a password manager / secrets vault accessible to at least two people
4. Test restore: on a non-production server, `CREATE CERTIFICATE BackupCert FROM FILE = '...' WITH PRIVATE KEY (FILE = '...', DECRYPTION BY PASSWORD = '...')` then attempt to restore an encrypted backup

**Related checks:** A3 (TDE cert backup), A37 (all cert backups)

---

### A24 — Backup encryption using weak algorithm

**What it means**
SQL Server supports AES_128, AES_192, AES_256, and TRIPLE_DES_3KEY for backup encryption. TRIPLE_DES_3KEY is deprecated and will be non-compliant with PCI-DSS v4 and FIPS after 2023. AES_128 is acceptable but AES_256 is the current standard.

**How to spot it**
```sql
SELECT database_name, backup_start_date, key_algorithm
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -30, GETDATE())
  AND key_algorithm IN ('TRIPLE_DES_3KEY', 'AES_128');
```

**Fix options**
1. Update backup scripts to use `ALGORITHM = AES_256`
2. Existing backups retain their original algorithm — they are still restorable; only future backups change
3. Consider re-taking full backups with AES_256 so the most recent backup set is compliant

**Related checks:** A55 (FIPS compliance)

---

### A25 — Backup encryption certificate expiring within 90 days

**What it means**
The backup encryption certificate expiry does not prevent SQL Server from *running* or from *taking* new backups — but a SQL Server instance restore to new hardware requires importing the certificate first, and an expired certificate may cause import issues. More practically, if the same certificate is used for TDE and backup encryption, its expiry has broader impact.

**How to spot it**
```sql
SELECT c.name, c.expiry_date, DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_remaining
FROM master.sys.certificates c
WHERE c.thumbprint IN (SELECT encryptor_thumbprint FROM msdb.dbo.backupset WHERE encryptor_thumbprint IS NOT NULL)
  AND c.expiry_date < DATEADD(DAY, 90, GETDATE());
```

**Fix options**
1. Create new backup certificate with future expiry
2. Switch future backups to new cert: update backup scripts / maintenance plans to reference new cert name
3. Retain old cert for restoring historical backups (document which date range each cert covers)
4. Back up new certificate (A23)

**Related checks:** A23 (cert backup), A3 (TDE cert expiry)

---

## A26–A30: Transport / Connection Encryption

### A26 — ForceEncryption not enabled at server level

**What it means**
Without ForceEncryption = Yes, SQL Server is willing to accept unencrypted connections from clients that do not request encryption. Before ODBC 18, JDBC 12, and .NET 7, `Encrypt=False` was the default in most SQL Server drivers. This means legacy application connection strings — and any new application that did not explicitly set `Encrypt=True` — connect in plaintext. Login credentials and all query data traverse the network unencrypted.

**How to spot it**
In SQL Server Configuration Manager (cannot query via T-SQL directly), check: SQL Server Network Configuration → Protocols for [instance] → Properties → Flags tab → Force Encryption.

Or check the registry (read-only DBA):
```sql
SELECT value_name, value_data
FROM sys.dm_server_registry
WHERE registry_key LIKE N'%SuperSocketNetLib%'
  AND value_name = N'ForceEncryption';
-- 0 = not forced; 1 = forced
```

**Fix options**
1. Install a CA-signed TLS certificate first (if using self-signed, clients may break after ForceEncryption is enabled because they cannot validate the cert)
2. SQL Server Configuration Manager → Certificates tab → bind the CA-signed cert
3. Flags tab → Force Encryption = Yes
4. Restart SQL Server service
5. Test all applications; those with `TrustServerCertificate=False` (the new default) and no way to validate the server cert will fail — fix by installing the CA root cert or correcting the cert

**Related checks:** A27 (active unencrypted connections), A28 (self-signed cert), A29 (TrustServerCertificate)

---

### A27 — Active remote connections using no encryption

**What it means**
`sys.dm_exec_connections.encrypt_option = 'FALSE'` means the session's data is transmitted as plain text. For remote connections (non-loopback), this means credentials, query parameters, and result sets are visible on the network segment between the client and the SQL Server.

**How to spot it**
```sql
SELECT c.session_id, c.client_net_address, c.auth_scheme, c.encrypt_option,
       s.login_name, s.program_name
FROM sys.dm_exec_connections c
JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
WHERE c.encrypt_option = 'FALSE'
  AND c.client_net_address NOT IN ('<local machine>', '127.0.0.1', '::1', '<named pipe>');
```

**Fix options**
1. Enable ForceEncryption (A26 fix)
2. For applications that cannot immediately support TLS: implement IPsec or VLAN isolation as a temporary compensating control
3. Identify application owners from `s.program_name` and `s.login_name`; coordinate connection string updates
4. Rerun this query after enabling ForceEncryption to confirm all remote sessions show `encrypt_option = 'TRUE'`

**Related checks:** A26 (ForceEncryption)

---

### A28 — SQL Server TLS certificate is self-signed

**What it means**
SQL Server generates a self-signed certificate at startup if no certificate is configured. This certificate provides encryption (the channel is protected from passive eavesdropping) but not authentication (a MITM attacker can intercept and present their own self-signed cert instead). Clients connecting to a server with a self-signed cert must use `TrustServerCertificate=True`, which bypasses all certificate validation.

**How to spot it**
Check the SQL Server ERRORLOG for startup message:
```
A self-generated certificate was successfully loaded for encryption.
```
Or via SQL Server Configuration Manager: Certificates tab shows the bound certificate; check if issuer = subject in the cert properties.

**Fix options**
1. Request a certificate from internal CA (AD CS) with Subject = SQL Server FQDN
2. Install in Local Machine → Personal store
3. Grant SQL Server service account read access to the cert's private key in the cert store
4. Configure in SQL Server Configuration Manager → Certificates tab → select the new cert
5. Restart SQL Server; verify ERRORLOG shows the new thumbprint
6. Remove TrustServerCertificate=True from production connection strings

**Related checks:** A26 (ForceEncryption), A29 (TrustServerCertificate), A30 (cert expiry)

---

### A29 — TrustServerCertificate=TRUE in use

**What it means**
`TrustServerCertificate=True` in a connection string instructs the SQL Server driver to skip all certificate chain validation. Combined with `Encrypt=True`, the connection is encrypted, but the client accepts any certificate the server presents — including a certificate from an attacker performing a MITM attack. This is the main reason self-signed certificates are dangerous in production.

**How to spot it**
Extended Events session or application connection string audit. Query active session properties:
```sql
SELECT s.session_id, s.login_name, s.program_name, c.client_net_address, c.encrypt_option
FROM sys.dm_exec_sessions s
JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
WHERE c.encrypt_option = 'TRUE';
-- Cannot directly tell TrustServerCertificate from DMVs alone; requires app-level audit
```

**Fix options**
1. Deploy a CA-signed certificate (A28 fix)
2. Distribute the CA root certificate to client machines (via Group Policy for domain-joined clients)
3. Remove `TrustServerCertificate=True` from all production connection strings
4. If using .NET: `SqlConnectionStringBuilder.TrustServerCertificate = false`

**Related checks:** A28 (self-signed cert), A26 (ForceEncryption)

---

### A30 — SQL Server TLS authentication certificate expiring within 90 days

**What it means**
When the certificate bound to SQL Server for TLS expires, SQL Server falls back to a self-generated certificate on restart. Clients with `TrustServerCertificate=False` (default in modern drivers) will fail to connect. This is an outage scenario.

**How to spot it**
```sql
-- Check for expiry warning in ERRORLOG (recent boot)
-- Also check Windows cert store via SQL Server Configuration Manager
-- Or match the thumbprint:
SELECT value_data AS tls_cert_thumbprint
FROM sys.dm_server_registry
WHERE registry_key LIKE N'%SuperSocketNetLib%' AND value_name = N'Certificate';
-- Then: SELECT * FROM sys.certificates WHERE thumbprint = 0x[value above]
```

**Fix options**
1. Renew the certificate from the issuing CA before expiry
2. Install renewed cert in Windows cert store (same Personal store slot)
3. If the thumbprint changes: rebind in SQL Server Configuration Manager → Certificates tab
4. Restart SQL Server service; verify ERRORLOG confirms the new cert thumbprint
5. No client-side changes needed if the same CA is still trusted

**Related checks:** A28 (self-signed cert), A36 (CA trust)

---

## A31–A38: Certificate Management

### A31 — Certificate private key unprotected

**What it means**
SQL Server certificate private keys are stored encrypted within the database. `ENCRYPTED_BY_PASSWORD` means only the password can decrypt them — which requires the password to be in T-SQL code or application memory. `NO_PRIVATE_KEY` means the private key was either never imported or was stripped after creation — the certificate can only verify signatures, not create them, and cannot decrypt anything.

**How to spot it**
```sql
SELECT name, pvt_key_encryption_type_desc
FROM sys.certificates
WHERE name NOT LIKE '##%'
  AND pvt_key_encryption_type_desc IN ('ENCRYPTED_BY_PASSWORD', 'NO_PRIVATE_KEY');
```

**Fix options**
- For `ENCRYPTED_BY_PASSWORD`: `ALTER CERTIFICATE [cert] WITH PRIVATE KEY (DECRYPTION BY PASSWORD = 'pwd', ENCRYPTION BY DATABASE MASTER KEY)`
- For `NO_PRIVATE_KEY`: restore from BACKUP CERTIFICATE output; if no backup exists, the cert is permanently limited to public-key operations

**Related checks:** A44–A46 (DMK must exist), A37 (cert backup)

---

### A32 — Service Broker endpoint certificate overdue

**What it means**
Service Broker uses certificates for cross-instance authentication when Windows auth is not available (cross-domain, cross-forest, internet). These certificates authenticate the SQL Server instance to remote instances. Long-lived certs increase the exposure window for compromised certificate material.

**How to spot it**
```sql
SELECT e.name, c.name AS cert_name, c.create_date, c.expiry_date,
       DATEDIFF(YEAR, c.create_date, GETDATE()) AS age_years
FROM sys.endpoints e
JOIN sys.certificates c ON e.certificate_id = c.certificate_id
WHERE e.type_desc = 'SERVICE_BROKER' AND e.connection_auth_desc = 'CERTIFICATE'
  AND c.create_date < DATEADD(YEAR, -2, GETDATE());
```

**Fix options**
1. Create new cert; export to remote database(s); create login from cert on remote; update remote service binding
2. Update local endpoint: `ALTER ENDPOINT [sb] FOR SERVICE_BROKER (AUTHENTICATION = CERTIFICATE [new_cert])`
3. Test message delivery before retiring old cert

**Related checks:** A33 (AG endpoints), A37 (cert backup)

---

### A33 — Always On AG endpoint certificate expiring within 90 days

**What it means**
AG endpoints use certificates for authentication when Windows auth is not used (cross-domain, workgroup, cloud). An expired AG endpoint cert causes replicas to disconnect, data movement to halt, and failover capability to degrade. This is the SQL Server equivalent of an expired SSL cert taking down HTTPS — except the consequence is potential data loss.

**How to spot it**
```sql
SELECT e.name AS endpoint_name, c.name AS cert_name,
       c.expiry_date, DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_remaining
FROM sys.endpoints e
JOIN sys.certificates c ON e.certificate_id = c.certificate_id
WHERE e.type_desc = 'DATABASE_MIRRORING'
  AND e.connection_auth_desc LIKE '%CERTIFICATE%'
  AND c.expiry_date < DATEADD(DAY, 90, GETDATE());
```

**Fix options**
1. On primary: create new cert; export new cert
2. On each secondary: import cert; `CREATE LOGIN [PrimaryLogin] FROM CERTIFICATE [new_cert]`; `GRANT CONNECT ON ENDPOINT::[hadr_endpoint] TO [PrimaryLogin]`
3. On primary: `ALTER ENDPOINT [hadr_endpoint] FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE [new_cert])`
4. Verify with `SELECT replica_server_name, connected_state_desc FROM sys.dm_hadr_availability_replica_states`

**Related checks:** A4 (TDE cert), A25 (backup cert), A30 (TLS cert)

---

### A34 — Certificate-based login with elevated fixed server role

**What it means**
Certificate-based logins (`CREATE LOGIN FROM CERTIFICATE`) are primarily used to grant elevated permissions to signed stored procedures without giving those permissions to the execution user directly. If the cert login is added to sysadmin, then any batch that can be signed with the certificate's private key has full server control. This is a serious privilege escalation vector.

**How to spot it**
```sql
SELECT p.name AS login_name, p.type_desc, r.name AS role_name
FROM sys.server_principals p
JOIN sys.server_role_members rm ON p.principal_id = rm.member_principal_id
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
WHERE p.type = 'C'
  AND r.name IN ('sysadmin', 'securityadmin', 'processadmin', 'dbcreator', 'bulkadmin');
```

**Fix options**
1. Remove from elevated roles: `ALTER SERVER ROLE sysadmin DROP MEMBER [cert_login]`
2. Grant only the specific permissions the signed procedure needs: `GRANT AUTHENTICATE SERVER TO [cert_login]` or specific object permissions
3. Use `EXECUTE AS` within the signed procedure rather than elevating the cert login globally

**Related checks:** A40 (key permissions)

---

### A35 — Certificate signed with MD5 or SHA1

**What it means**
The certificate's signature hash algorithm determines how tamper-evident it is. MD5 hash collisions are computationally trivial (demonstrated by the Flame malware in 2012). SHA1 collisions have been demonstrated (SHAttered, 2017). Both are deprecated for certificate signing by all major CAs, browsers, and the NIST. SQL Server's `CREATE CERTIFICATE` uses SHA1 by default on older versions.

**How to spot it**
```sql
-- CERTPROPERTY() does not expose the 'Algorithm' property — always returns NULL for that argument.
-- Verify signature algorithm via certutil or PowerShell:
--   certutil -dump <cert.cer>  (shows "Signature Algorithm")
--   Get-ChildItem Cert:\ | Select-Object Subject, SignatureAlgorithm
-- For SQL Server-generated certs, newer versions (2022+) default to SHA256; older default to SHA1.
SELECT name, expiry_date, pvt_key_encryption_type_desc
FROM sys.certificates
WHERE name NOT LIKE '##%';
```

**Fix options**
1. Re-create the certificate using a tool that supports SHA256 (openssl, certreq, or a CA)
2. For SQL Server-generated certs via `CREATE CERTIFICATE`: newer versions (2022+) use SHA256 by default; on older versions, create from a pre-generated file
3. Replace in all dependent uses (TDE, Service Broker, AG endpoints, backup encryption)

**Related checks:** A55 (FIPS compliance)

---

### A36 — Certificate from self-signed or untrusted CA

**What it means**
A self-signed certificate or one from an internal CA that clients do not trust forces clients to use `TrustServerCertificate=True` for TLS or to manually add the issuer to their trust store. Without proper chain-of-trust, certificate revocation cannot be checked and MITM attacks are undetectable.

**How to spot it**
```sql
SELECT name, issuer_name, subject, expiry_date
FROM sys.certificates
WHERE name NOT LIKE '##%'
  AND issuer_name = subject;  -- self-signed
```

**Fix options**
1. For TLS (A28): replace with CA-signed cert from ADCS or public CA
2. For internal use only (TDE, Service Broker within a trusted network): self-signed may be acceptable with explicit risk acceptance
3. Distribute the issuing CA root to all client Trusted Root CA stores via Group Policy

**Related checks:** A28 (TLS cert), A29 (TrustServerCertificate), A36

---

### A37 — No BACKUP CERTIFICATE evidence

**What it means**
This is the generalised version of A3 (TDE cert) and A23 (backup cert) — it fires for any certificate with a private key that has not been backed up. Certificate private keys in SQL Server cannot be extracted via DMVs; they must be exported using `BACKUP CERTIFICATE … WITH PRIVATE KEY`. Without this, a server loss means permanent loss of all data protected by the certificate.

**How to spot it**
```sql
SELECT name, pvt_key_encryption_type_desc, create_date
FROM sys.certificates
WHERE pvt_key_encryption_type_desc != 'NO_PRIVATE_KEY'
  AND name NOT LIKE '##%';
-- For each: check whether BACKUP CERTIFICATE exists in SQL Agent jobs or maintenance scripts
```

**Fix options**
See A3 fix for procedure. Apply to every certificate in the list.

**Related checks:** A3, A23, A31, A32, A33

---

### A38 — Multiple certificates with same Subject/CN

**What it means**
SQL Server identifies certificates by name (in T-SQL) or by thumbprint (internally). When two certificates have the same Subject, T-SQL operations or imports may operate on the wrong certificate. During disaster recovery, `CREATE CERTIFICATE … FROM FILE` may create a duplicate-subject collision. Rotation procedures become error-prone.

**How to spot it**
```sql
SELECT subject, COUNT(*) AS count, STRING_AGG(name, ', ') AS cert_names
FROM sys.certificates
WHERE name NOT LIKE '##%'
GROUP BY subject
HAVING COUNT(*) > 1;
```

**Fix options**
1. Retire certificates that are no longer needed
2. Rename remaining ones to distinguish purpose: `TDE_SalesDB_2023_RETIRED`, `TDE_SalesDB_2025_ACTIVE`
3. Adopt a naming standard that includes the year and purpose in both the T-SQL name and the Subject/CN

**Related checks:** A4 (TDE cert rotation), A6 (shared cert)

---

## A39–A43: Asymmetric and Symmetric Key Management

### A39 — Asymmetric key using RSA_512 or RSA_1024

**What it means**
RSA key security depends on the difficulty of factoring the product of two large primes. RSA_512 can be factored in hours with consumer hardware. RSA_1024 was deprecated by NIST in 2010; academic factoring records are approaching 1024-bit numbers. NIST recommends RSA_2048 as the minimum through at least 2030, RSA_3072 through 2040.

**How to spot it**
```sql
SELECT name, algorithm_desc, key_length, create_date
FROM sys.asymmetric_keys
WHERE key_length <= 1024 AND name NOT LIKE '##%';
```

**Fix options**
1. Create: `CREATE ASYMMETRIC KEY [NewKey] WITH ALGORITHM = RSA_2048 ENCRYPTION BY PASSWORD = 'pwd'`
2. Re-wrap dependent symmetric keys: `ALTER SYMMETRIC KEY [SymKey] ADD ENCRYPTION BY ASYMMETRIC KEY [NewKey]`
3. Verify symmetric key opens with new asymmetric key
4. `ALTER SYMMETRIC KEY [SymKey] DROP ENCRYPTION BY ASYMMETRIC KEY [OldKey]`
5. `DROP ASYMMETRIC KEY [OldKey]`

**Related checks:** A55 (FIPS)

---

### A40 — CONTROL permission on an encryption key

**What it means**
CONTROL on a symmetric key grants the grantee the ability to: open the key (read all encrypted data), alter the key (change its protections), and drop the key (destroy access to encrypted data). For asymmetric keys, CONTROL allows signing, verification, and key management operations. These are equivalent to owning the key.

**How to spot it**
```sql
SELECT p.name AS principal_name, dp.permission_name, dp.class_desc,
       CASE dp.class
           WHEN 24 THEN OBJECT_NAME(dp.major_id, dp.minor_id)  -- symmetric key
           WHEN 26 THEN (SELECT name FROM sys.asymmetric_keys WHERE asymmetric_key_id = dp.major_id)
       END AS key_name
FROM sys.database_permissions dp
JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
WHERE dp.permission_name = 'CONTROL'
  AND dp.class IN (24, 26)  -- 24 = symmetric key, 26 = asymmetric key
  AND p.name != 'dbo';
```

**Fix options**
1. `REVOKE CONTROL ON SYMMETRIC KEY::[key] FROM [user]`
2. Grant purpose-specific permissions: `GRANT REFERENCES ON COLUMN MASTER KEY::[cmk] TO [app_user]` for AE; `GRANT DECRYPT ON SYMMETRIC KEY::[key] TO [app_user]` for CLE decryption
3. Use stored procedures that `EXECUTE AS` a key owner so end users never need direct key permissions

**Related checks:** A34 (cert login permissions)

---

### A41 — Symmetric key not rotated in over 2 years

**What it means**
Same concept as A20 but for keys that have been modified but not rotated to a new key version. `modify_date != create_date` means the key metadata was changed (e.g., adding a new encryption method), but a true key rotation (creating a new key with new key material and re-encrypting data) requires tracking manually.

**How to spot it**
```sql
SELECT name, algorithm_desc, create_date, modify_date,
       DATEDIFF(YEAR, create_date, GETDATE()) AS age_years
FROM sys.symmetric_keys
WHERE create_date < DATEADD(YEAR, -2, GETDATE()) AND name NOT LIKE '##%';
```

**Fix options**
See A20 fix. Prioritize keys protecting PCI/HIPAA/GDPR data (PCI-DSS Requirement 3.7.3).

---

### A42 — Orphaned encryption keys

**What it means**
Keys that exist in `sys.symmetric_keys` or `sys.asymmetric_keys` but are not referenced by any stored procedure, function, trigger, view, or module in `sys.sql_modules` are orphaned. They may be: leftover from a retired application, created during testing that was never cleaned up, or the application has moved to a different key without removing the old one.

**How to spot it**
```sql
SELECT sk.name, sk.algorithm_desc, sk.create_date
FROM sys.symmetric_keys sk
WHERE sk.name NOT LIKE '##%'
  AND sk.name NOT IN (
      SELECT DISTINCT
             SUBSTRING(m.definition,
                       CHARINDEX('SYMMETRIC KEY ', m.definition) + 14,
                       50) AS key_ref
      FROM sys.sql_modules m
      WHERE m.definition LIKE '%SYMMETRIC KEY%'
  );
```

This is approximate; a thorough analysis should also check application code outside of SQL Server.

**Fix options**
1. Confirm with application owners that the key is unused across all versions and environments
2. `DROP SYMMETRIC KEY [orphan_key]`
3. Document the drop in change management — in case an old application version surfaces later

---

### A43 — Non-unique KEY_SOURCE in symmetric key definition

**What it means**
The `KEY_SOURCE` parameter in `CREATE SYMMETRIC KEY` is an additional input to the key derivation function. Using the same KEY_SOURCE across dev, staging, and production means the same symmetric key material is generated — data encrypted in dev can be decrypted with the prod key. This is dangerous if dev databases contain real or semi-real data.

**How to spot it**
Only detectable from T-SQL source or git history for `CREATE SYMMETRIC KEY` statements. Look for `KEY_SOURCE = 'password'`, `KEY_SOURCE = 'test'`, or any hardcoded string repeated across environment deployment scripts.

**Fix options**
1. Generate unique per-environment KEY_SOURCE values: `SELECT CONVERT(VARCHAR(36), NEWID())` — use the output as the KEY_SOURCE; store it in the secrets vault, not in the deployment script
2. Re-create the key with the new KEY_SOURCE; re-encrypt all data (see A17/A20 re-encryption pattern)
3. Never copy deployment scripts with KEY_SOURCE values between environments; use environment-specific secrets management

---

## A44–A48: Key Hierarchy (DMK / SMK)

### A44 — Database Master Key not backed up

**What it means**
The DMK is the root protector for all certificates and asymmetric keys in the database. Losing it — through server failure, accidental `DROP MASTER KEY`, or corruption — makes every certificate, asymmetric key, and the symmetric keys protected by them permanently inaccessible. All CLE-encrypted data becomes unreadable. This is catastrophic and irreversible.

**How to spot it**
Look for `BACKUP MASTER KEY` in SQL Agent jobs or maintenance scripts. No DMV records backup history.

```sql
-- Verify DMK exists
SELECT name, create_date, modify_date FROM sys.symmetric_keys
WHERE name = '##MS_DatabaseMasterKey##';
```

**Fix options**
1. `BACKUP MASTER KEY TO FILE = 'C:\Backup\[dbname]_master_key.mk' ENCRYPTION BY PASSWORD = 'VaultPassword'`
2. Store in secure, off-server location
3. Test restore on a non-production database before a disaster occurs
4. Create a SQL Agent alert or job to remind the team if no backup has been performed in 90 days

**Related checks:** A45 (DMK/SMK protection), A47 (SMK backup)

---

### A45 — DMK not protected by Service Master Key

**What it means**
The DMK can be protected by the SMK (automatic) and/or by a user-supplied password. When protected by the SMK, SQL Server automatically decrypts the DMK at startup — all CLE operations work transparently without DBA intervention. When NOT protected by the SMK, every restart requires a DBA to manually run `OPEN MASTER KEY DECRYPTION BY PASSWORD = '...'` before any CLE operation can succeed. Missing this step causes application errors until a DBA intervenes.

**How to spot it**
```sql
SELECT d.name AS database_name, d.is_master_key_encrypted_by_server
FROM sys.databases d
WHERE d.database_id = DB_ID();
-- 0 = DMK not protected by SMK = manual OPEN required after every restart
```

**Fix options**
1. First, ensure the DMK is currently open or provide the password
2. `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY`
3. Verify: `SELECT is_master_key_encrypted_by_server FROM sys.databases WHERE database_id = DB_ID()` returns 1

**Related checks:** A46 (password-only DMK), A47 (SMK backup)

---

### A46 — DMK protected by password only

**What it means**
Same condition as A45 — A45 focuses on the operational impact (application errors after restart); A46 focuses on the key management risk: if the DMK password is lost, the DMK and all keys it protects are permanently gone. Unlike the SMK (backed by Windows DPAPI), a password-protected DMK has no OS-level recovery path.

**How to spot it**
Same query as A45: `is_master_key_encrypted_by_server = 0`.

**Fix options**
Same as A45: `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY`. Additionally:
1. Back up the DMK with the password as a recovery option (A44)
2. Store the password in a vault accessible to at least two people

**Related checks:** A44 (DMK backup), A45 (SMK protection)

---

### A47 — Service Master Key never explicitly backed up

**What it means**
The SMK is the root of the entire instance-level key hierarchy — it protects all DMKs across all databases, linked server passwords, SQL Agent proxy credentials, and database mail passwords. SQL Server generates the SMK automatically at install; many installations never back it up. If the instance is migrated to new hardware without an SMK backup, the new installation generates a new SMK, and all objects protected by the old SMK become permanently inaccessible.

**How to spot it**
No DMV records SMK backup history. Check SQL Agent jobs or maintenance scripts for `BACKUP SERVICE MASTER KEY`. If nothing found, it has not been backed up.

**Fix options**
1. `BACKUP SERVICE MASTER KEY TO FILE = 'D:\Keys\SMK_[hostname]_[date].smk' ENCRYPTION BY PASSWORD = 'VaultPassword'`
2. Store in secure, off-server, geographically separate location
3. Perform after SQL Server installation, after any SMK regeneration (`ALTER SERVICE MASTER KEY REGENERATE`), and after SQL Server major version upgrades

**Related checks:** A44 (DMK backup), A45 (SMK/DMK hierarchy)

---

### A48 — Linked server connection encryption not enforced

**What it means**
Linked server connections use the SQL Server OLE DB / ODBC provider to establish a connection to a remote server. Without encryption in the provider string, all four-part queries, OPENQUERY calls, and distributed transactions traverse the network in plaintext — including credentials and query data.

**How to spot it**
```sql
SELECT s.name AS linked_server_name, s.provider, s.data_source, ls.product_name
FROM sys.servers s
JOIN sys.linked_logins ls ON s.server_id = ls.server_id
WHERE s.is_linked = 1;
-- Check provider string in SSMS: Linked Servers → [server] → Properties → Provider Options
```

**Fix options**
1. Drop and re-create with encrypted provider string:
   ```sql
   EXEC sp_addlinkedserver
       @server = N'RemoteSrv',
       @srvproduct = N'SQL Server',
       @provider = N'MSOLEDBSQL',     -- SQLNCLI11 is deprecated and removed in SQL Server 2022
       @provstr = N'Encrypt=Mandatory;TrustServerCertificate=no'
   ```
2. Ensure the remote SQL Server has a valid CA-signed TLS cert installed (required for `TrustServerCertificate=no`)
3. Test linked server query after updating

---

## A49–A52: EKM / Azure Key Vault

### A49 — EKM provider inactive or in error state

**What it means**
Extensible Key Management (EKM) allows SQL Server to use external hardware (HSM) or cloud (AKV) for key storage. When an EKM provider is installed but inactive, any TDE or CLE keys managed by that provider become inaccessible. Databases that use EKM-backed TDE fail to open (mount) after a SQL Server restart, causing a full database outage.

**How to spot it**
```sql
SELECT provider_id, name, dll_path, is_enabled, provider_version
FROM sys.cryptographic_providers;
-- is_enabled = 0 means inactive
```

**Fix options**
1. Check the provider DLL path: `EXEC xp_fileexist 'dll_path'` (verify it resolves)
2. Verify configuration: `SELECT name, value_in_use FROM sys.configurations WHERE name = 'EKM provider enabled'` — must be 1
3. Check provider service status (vendor-specific: HSM client service, AKV proxy service)
4. Restart the provider service; then restart SQL Server if needed
5. Test with: `OPEN SYMMETRIC KEY [ekmKey] DECRYPTION BY EKM_AK_NAME = '[ekm_asym_key]'`

**Related checks:** A52 (provider version)

---

### A50 — AKV BYOK TDE without automatic rotation

**What it means**
BYOK TDE (Bring Your Own Key) via Azure Key Vault gives customers full control over the TDE encryption key — including the ability to revoke access. However, unlike service-managed TDE, BYOK requires manual action to rotate the TDE protector when the AKV key is rotated. If the AKV key is rotated without updating the SQL Server TDE protector, SQL Server loses access to the database.

**How to spot it**
Check `sys.dm_database_encryption_keys.encryptor_type = 'ASYMMETRIC_KEY'` (EKM-backed TDE). Check the AKV key's rotation policy via Azure Portal or `az keyvault key show`.

**Fix options**
1. Set a rotation policy on the AKV key: `az keyvault key rotation-policy update --vault-name [vault] --name [key] --value @policy.json`
2. After rotation: `Set-AzSqlServerTransparentDataEncryptionProtector -ServerName [srv] -ResourceGroupName [rg] -Type AzureKeyVault -KeyId [new_key_version_uri]`
3. Create an Azure Automation runbook or Logic App to detect key version changes and automatically update the TDE protector

---

### A51 — Service-managed TDE in regulated environment

**What it means**
Azure SQL Database enables TDE by default using a service-managed key — Azure manages the key lifecycle completely. This is cryptographically sound (AES-256) but some compliance frameworks require the customer to own the key (data sovereignty, right to revoke access, auditable key lifecycle). Service-managed TDE means the cloud provider can technically access the key.

**How to spot it**
Azure Portal: SQL Database → Transparent Data Encryption → TDE protector shows "Service-managed" vs. "Customer-managed".
T-SQL: `SELECT encryptor_type FROM sys.dm_database_encryption_keys` — service-managed shows `SERVICE_MANAGED`.

**Fix options**
1. Identify whether compliance requirements mandate BYOK (check PCI-DSS, HIPAA, FedRAMP, ISO 27001 control requirements)
2. If required: create AKV, add RSA key, grant SQL Server managed identity access to AKV
3. `Set-AzSqlServerTransparentDataEncryptionProtector -ServerName [srv] -ResourceGroupName [rg] -Type AzureKeyVault -KeyId [akv_key_uri]`
4. Verify TDE protector changed: `Get-AzSqlServerTransparentDataEncryptionProtector`

---

### A52 — EKM provider version outdated

**What it means**
EKM provider DLLs (HSM client libraries, AKV connector) are software components that may have security vulnerabilities, compatibility issues with SQL Server CUs, or feature limitations in old versions. Running outdated EKM provider software is a supply-chain risk: a vulnerability in the provider DLL may allow key material extraction or authentication bypass.

**How to spot it**
```sql
SELECT name, provider_version, sqlcrypt_version FROM sys.cryptographic_providers;
-- Compare provider_version against vendor's current release notes
```

**Fix options**
1. Download latest vendor DLL from vendor portal
2. Test upgrade on a non-production SQL Server (same SQL Server version) first
3. `ALTER CRYPTOGRAPHIC PROVIDER [provider_name] FROM FILE = 'path\new_provider.dll'`
4. Verify: `SELECT provider_version FROM sys.cryptographic_providers` shows new version
5. Follow vendor-specific upgrade guide; some EKM providers require a SQL Server restart after update

**Related checks:** A49 (provider health)

---

## A53–A56: Compliance and Coverage

### A53 — Sensitivity-classified columns without encryption

**What it means**
SQL Server 2019+ provides `sys.sensitivity_classifications` to tag columns with sensitivity labels (using SQL Data Discovery & Classification). These labels document that the data is sensitive. A column labeled "Credentials" or "Financial" with no encryption layer is still readable by any user with SELECT permission — the label provides compliance documentation but not protection.

**How to spot it**
```sql
SELECT sc.information_type, sc.label, SCHEMA_NAME(t.schema_id) + '.' + t.name + '.' + c.name AS column_path,
       CASE WHEN c.column_encryption_key_id IS NOT NULL THEN 'AE' ELSE 'No encryption' END AS encryption_status
FROM sys.sensitivity_classifications sc
JOIN sys.objects t ON sc.major_id = t.object_id
JOIN sys.columns c ON sc.major_id = c.object_id AND sc.minor_id = c.column_id
WHERE c.column_encryption_key_id IS NULL
  AND sc.information_type IN ('Financial', 'Health', 'Credentials', 'Banking', 'National ID', 'Payment', 'Government');
```

**Fix options**
1. Apply Always Encrypted for Credentials and high-sensitivity PII fields
2. Apply CLE for financial aggregate columns where AE's limitations are prohibitive
3. For read-path protection where full encryption is not feasible: apply Dynamic Data Masking as a supplemental control (not a substitute for encryption)
4. Document compensating controls in the compliance evidence for any classified column that intentionally remains unencrypted

**Related checks:** A14 (sensitive patterns), A54 (pattern columns without classification)

---

### A54 — Sensitive-pattern column names without encryption or classification

**What it means**
This is a discovery check for columns that appear to contain sensitive data (based on column names) but have neither AE protection nor a sensitivity classification label. It casts a wider net than A14 (which only checks for missing AE) by also flagging columns without even a sensitivity label.

**How to spot it**
```sql
SELECT SCHEMA_NAME(t.schema_id) + '.' + t.name AS table_name, c.name AS column_name
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
WHERE c.column_encryption_key_id IS NULL
  AND c.object_id NOT IN (SELECT major_id FROM sys.sensitivity_classifications)
  AND (c.name LIKE '%ssn%' OR c.name LIKE '%credit_card%' OR c.name LIKE '%salary%'
       OR c.name LIKE '%password%' OR c.name LIKE '%tax_id%' OR c.name LIKE '%dob%'
       OR c.name LIKE '%passport%' OR c.name LIKE '%diagnosis%' OR c.name LIKE '%account_number%');
```

**Fix options**
1. Run SSMS → Data Discovery & Classification → Scan database — reviews column names and data types; generates classification recommendations
2. Confirm with data owners whether the columns contain real sensitive data
3. Apply sensitivity classification first, then encryption (A14 fix paths)
4. False positives (e.g., `password_reset_url`) should still be classified as low sensitivity so they appear in the inventory

**Related checks:** A14 (AE), A53 (classified columns)

---

### A55 — Non-FIPS compliant algorithm in the encryption hierarchy

**What it means**
This is an umbrella finding that consolidates all algorithm-quality issues across every encryption layer. It fires when any check in the other categories (A5, A17, A24, A35, A39) would also fire for algorithm weakness. It provides a single summary for compliance auditors who need to confirm FIPS 140-2 compliance across the entire SQL Server instance.

**How to spot it**
```sql
-- TDE
SELECT 'TDE_DEK' AS source, d.name AS object_name, dek.key_algorithm AS algorithm
FROM sys.dm_database_encryption_keys dek JOIN sys.databases d ON dek.database_id = d.database_id
WHERE dek.key_algorithm IN ('TRIPLE_DES_3KEY', 'AES_128')
UNION ALL
-- CLE symmetric keys
SELECT 'SYM_KEY', name, algorithm_desc
FROM sys.symmetric_keys WHERE algorithm_desc NOT IN ('AES_128', 'AES_192', 'AES_256') AND name NOT LIKE '##%'
UNION ALL
-- Asymmetric keys
SELECT 'ASYM_KEY', name, algorithm_desc + '_' + CAST(key_length AS VARCHAR(10))
FROM sys.asymmetric_keys WHERE key_length <= 1024 AND name NOT LIKE '##%'
UNION ALL
-- Certificates with potentially weak hash (CERTPROPERTY does not expose 'Algorithm'; list all for out-of-band review)
SELECT 'CERT_HASH', name, NULL AS sig_algorithm  -- verify hash via certutil or PowerShell
FROM sys.certificates WHERE name NOT LIKE '##%'  -- review each cert's SignatureAlgorithm externally
UNION ALL
-- Backup encryption
SELECT 'BACKUP', database_name, key_algorithm
FROM msdb.dbo.backupset WHERE key_algorithm IN ('TRIPLE_DES_3KEY', 'AES_128') AND backup_start_date > DATEADD(DAY, -30, GETDATE());
```

**Fix options**
See individual checks: A5 (TDE), A17 (CLE), A24 (backup), A35 (cert hash), A39 (asymmetric key).

---

### A56 — No SQL Server Audit for cryptographic operations

**What it means**
Without an audit trail for key access and modification events, it is impossible to detect: key exfiltration (someone exported a cert), unauthorized decryption (a rogue proc calling DECRYPTBYKEY), certificate deletion, or failed key rotation attempts. PCI-DSS Requirement 10.2.2 requires logging all cryptographic key management operations. HIPAA 45 CFR §164.312(b) requires hardware/software/procedural mechanisms that record and examine activity.

**How to spot it**
```sql
SELECT a.name AS audit_name, aspec.name AS spec_name, ag.audit_action_name
FROM sys.database_audit_specification_details ag
JOIN sys.database_audit_specifications aspec ON ag.database_specification_id = aspec.database_specification_id
JOIN sys.server_audits a ON aspec.audit_guid = a.audit_guid
WHERE ag.audit_action_name IN ('SCHEMA_OBJECT_ACCESS_GROUP', 'DATABASE_OBJECT_ACCESS_GROUP');
-- If no rows: encryption key access is not being audited
```

**Fix options**
1. Ensure a server audit exists and is enabled:
   ```sql
   CREATE SERVER AUDIT [InstanceAudit] TO FILE (FILEPATH = 'D:\AuditLogs\')
   WITH (ON_FAILURE = CONTINUE);
   ALTER SERVER AUDIT [InstanceAudit] WITH (STATE = ON);
   ```
2. Create a database audit specification:
   ```sql
   CREATE DATABASE AUDIT SPECIFICATION [EncryptionAudit]
   FOR SERVER AUDIT [InstanceAudit]
   ADD (SCHEMA_OBJECT_ACCESS_GROUP),
   ADD (DATABASE_PRINCIPAL_CHANGE_GROUP)
   WITH (STATE = ON);
   ```
3. For even more targeted coverage, add explicit audit actions on specific objects:
   `ADD (SELECT, INSERT, UPDATE, DELETE ON OBJECT::[schema].[encrypted_table] BY [public])`
4. Verify audit is writing: `SELECT * FROM sys.fn_get_audit_file('D:\AuditLogs\*.sqlaudit', DEFAULT, DEFAULT)`

---

## A57–A62: TLS and Network Encryption Hardening

### A57 — TLS 1.0 / 1.1 enabled at OS level

**What it means**
SChannel (Windows Secure Channel) is the TLS implementation used by SQL Server. If TLS 1.0 or 1.1 is enabled at the Windows level, SQL Server will negotiate these protocols with clients that request them — even if ForceEncryption is enabled. TLS 1.0 has been prohibited by PCI-DSS since 2018 and is vulnerable to downgrade attacks (POODLE, BEAST). TLS 1.1 lacks protocol-level fixes for known weaknesses.

**How to spot it**
```sql
-- Check via xp_regread (requires sysadmin)
EXEC xp_regread N'HKEY_LOCAL_MACHINE',
    N'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server',
    N'Enabled';
-- 1 = enabled, NULL or 0 = disabled/not configured

-- Also check SQL Server ERRORLOG for TLS version messages
-- "The certificate [thumbprint] was successfully loaded for encryption" followed by TLS version
```

External verification: `nmap --script ssl-enum-ciphers -p 1433 <host>` — lists all TLS versions offered.

**Fix options**
1. Set registry keys via PowerShell: `Set-ItemProperty -Path 'HKLM:\SYSTEM\...\TLS 1.0\Server' -Name 'Enabled' -Value 0 -Type DWord`
2. Set `DisabledByDefault = 1` for TLS 1.0 and TLS 1.1
3. Restart SQL Server
4. Verify: `openssl s_client -tls1_0 -connect <host>:1433` should fail

**Related checks:** A26 (ForceEncryption), A28 (self-signed TLS cert), A59 (TLS 1.3)

---

### A58 — Weak TLS cipher suites enabled

**What it means**
Even with TLS 1.2 and a strong certificate, weak cipher suites (RC4, 3DES, NULL, EXPORT) can be negotiated if they are enabled in the SChannel cipher suite order. An attacker who can force a downgrade to a weak cipher can break the encryption. The cipher suite order is managed centrally via Group Policy or locally via registry.

**How to spot it**
External scan: `nmap --script ssl-enum-ciphers -p 1433 <host>` — look for RC4, 3DES, DES, NULL, EXPORT ciphers in the output.

GPO check: `gpresult /h gpo.html` → Computer Configuration → Administrative Templates → Network → SSL Configuration Settings → SSL Cipher Suite Order.

**Fix options**
1. Configure cipher suite order via GPO to include only strong ciphers: `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`, `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, `TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384`, etc.
2. Disable RC4 completely via registry: `HKLM\...\SCHANNEL\Ciphers\RC4 128/128\Enabled = 0`
3. Run `gpupdate /force` and restart SQL Server
4. Re-scan to confirm weak ciphers no longer offered

**Related checks:** A57 (TLS versions), A59 (TLS 1.3)

---

### A59 — TLS 1.3 not enforced on SQL 2022+

**What it means**
SQL Server 2022 on Windows Server 2022+ supports TLS 1.3, which provides improved handshake performance (1-RTT vs 2-RTT for TLS 1.2), mandatory forward secrecy, and removes all legacy algorithms. If TLS 1.3 is available but not enforced, the server negotiates TLS 1.2 or lower, missing out on these protections.

**How to spot it**
Check in SQL Server ERRORLOG for "TLS 1.2" as the highest negotiated protocol. Or external: `openssl s_client -tls1_3 -connect <host>:1433` — if it falls back to TLS 1.2, TLS 1.3 is not enforced.

**Fix options**
1. Verify Windows Server 2022+ and SQL Server 2022+
2. Ensure TLS 1.3 is enabled in SChannel: `HKLM\...\SCHANNEL\Protocols\TLS 1.3\Server\Enabled = 1`
3. Update all client drivers to versions supporting TLS 1.3 (ODBC 18+, JDBC 12.4+, .NET 8+)
4. Restart SQL Server and verify negotiation

**Related checks:** A57 (legacy TLS)

---

### A60 — IPsec not configured as compensating control

**What it means**
When TLS encryption cannot be immediately enforced (legacy applications, driver incompatibilities), IPsec provides network-layer encryption on TCP port 1433. IPsec encrypts all traffic between the application server and SQL Server regardless of TLS configuration. It is an acceptable compensating control for compliance audits.

**How to spot it**
Check Windows Firewall Connection Security Rules: `Get-NetIPsecRule | Where-Object {$_.LocalPort -eq 1433}`. If no rules exist, IPsec is not configured for SQL traffic.

**Fix options**
1. `New-NetIPsecRule -DisplayName "SQL TLS Fallback" -LocalPort 1433 -Protocol TCP -RequireEncryption -Authentication RequireAuthDomain`
2. Test: `netsh ipsec dynamic show mmsas`
3. Document as compensating control in compliance evidence

**Related checks:** A26 (ForceEncryption), A27 (unencrypted connections)

---

### A61 — Kerberos armoring (FAST) not enforced

**What it means**
Kerberos armoring (FAST / RFC 6113) protects the Kerberos pre-authentication exchange from offline brute-force attacks. Without FAST, an attacker who captures a Kerberos AS-REQ can attempt to crack the user's password from the encrypted timestamp. This weakens the authentication layer that TLS depends on.

**How to spot it**
Check Group Policy: `Computer Configuration → Administrative Templates → System → Kerberos → Support for Kerberos armoring (FAST)`. Verify with `klist get krbtgt` showing `Armor: yes`.

**Fix options**
1. Requires domain functional level Windows Server 2012+
2. Enable via GPO: `Support for Kerberos armoring = Enabled and require armoring`
3. `gpupdate /force` on all SQL Server and domain controllers

**Related checks:** `/sqlspn-review` (K1–K40 for SPN/Kerberos config)

---

### A62 — Named Pipes protocol enabled in production

**What it means**
Named Pipes transport is not protected by TLS (TLS applies only to TCP/IP). Data traverses SMB/CIFS, which may or may not be encrypted depending on SMB encryption configuration. Named Pipes can be accessed by any host on the same network segment with SMB access.

**How to spot it**
SQL Server Configuration Manager → SQL Server Network Configuration → Protocols for [Instance] → Named Pipes = Enabled. OR check registry: `sys.dm_server_registry` for `SuperSocketNetLib\Np`.

**Fix options**
1. Disable in SQL Server Configuration Manager → Named Pipes = Disabled
2. If required for legacy apps, restrict to local connections and enable SMB Encryption: `Set-SmbServerConfiguration -EncryptData $true`
3. Ensure all applications use TCP/IP

**Related checks:** A26, A27 (TLS enforcement)

---

## A63–A67: Always Encrypted Advanced

### A63 — Enclave attestation URL not configured

**What it means**
When a secure enclave is enabled, the client driver must verify the enclave's identity before sending plaintext data for in-enclave computation. Without a configured attestation URL, the client cannot perform this verification, defeating the purpose of enclave attestation.

**How to spot it**
Check client connection strings for `Enclave Attestation Url` parameter. Verify attestation endpoint is reachable: `Invoke-WebRequest https://<attest-server>/attest/SgxEnclave`.

**Fix options**
1. Deploy MAA (Azure) or HGS (on-premises)
2. Add to connection string: `Enclave Attestation Url=https://<attest-server>/attest/SgxEnclave`
3. Test: `SELECT GETDATE()` with enclave-enabled connection
4. Monitor ERRORLOG for attestation failures

**Related checks:** A12 (enclave setup), A67 (relaxed attestation)

---

### A64 — Always Encrypted driver version incompatible

**What it means**
Older SQL Server drivers lack support for secure enclaves, may use weaker key exchange, and lack CEK caching. They cause excessive AKV round-trips and prevent enclave computations.

**How to spot it**
```sql
SELECT session_id, program_name FROM sys.dm_exec_sessions
WHERE program_name LIKE '%ODBC%' OR program_name LIKE '%JDBC%' OR program_name LIKE '%SqlClient%';
```
Check driver versions: ODBC < 17.10, JDBC < 12.2, .NET SqlClient < 5.0 lack full enclave support.

**Fix options**
1. ODBC Driver 18+, JDBC 12.4+, Microsoft.Data.SqlClient 5.2+
2. Update connection strings with `Column Encryption Setting=Enabled`
3. Test all AE queries after update

**Related checks:** A10 (no enclave for randomized columns)

---

### A65 — CEK caching disabled or misconfigured

**What it means**
Without CEK caching, the driver contacts AKV/HSM to decrypt the CEK on every new connection — adding 50-200 ms latency per connection and AKV API costs. CEK caching with a 2-hour TTL stores the decrypted CEK in the driver's memory.

**How to spot it**
Check application connection settings for CEK cache TTL. Monitor AKV API call volume per SQL Server connection count.

**Fix options**
1. ODBC: `Column Encryption Key Cache Time-To-Live=7200`
2. JDBC: `columnEncryptionKeyCacheTtl=7200`
3. .NET: `SqlConnection.ColumnEncryptionKeyCacheTtl = TimeSpan.FromHours(2)`
4. Verify AKV call reduction after enabling

**Related checks:** A64 (driver version)

---

### A66 — Enclave configured but no enclave-enabled queries

**What it means**
Enabling a secure enclave reserves VBS memory and requires attestation infrastructure. If no workloads actually use enclave computations (LIKE, BETWEEN, range queries on randomized columns), this overhead provides no benefit.

**How to spot it**
```sql
SELECT value_in_use FROM sys.configurations WHERE name = 'column encryption enclave type';
-- 0 = off, 1 = VBS. If 1 but no AE columns use RANDOMIZED + enclave queries, the enclave is unused.
```

**Fix options**
1. Audit AE columns for candidates that would benefit from enclave queries
2. If none exist: `EXEC sp_configure 'column encryption enclave type', 0; RECONFIGURE`
3. Test AE queries after disabling

**Related checks:** A10 (randomized without enclave), A12 (enclave not configured)

---

### A67 — Relaxed enclave attestation in production

**What it means**
Relaxed attestation mode means the client accepts any process claiming to be the enclave without cryptographic verification. A compromised host can intercept enclave computations and read plaintext. Only appropriate for development.

**How to spot it**
Check HGS attestation mode: `Get-HgsAttestationPolicy`. `AttestationMode = None` means relaxed. Or check if MAA/attestation URL is missing from client connection strings.

**Fix options**
1. Deploy HGS with TPM or host key attestation
2. Register SQL Server with HGS: `Set-HgsServer -HgsServerName <hgs_fqdn>`
3. Update connection strings with proper attestation URL
4. Verify attestation works: `SELECT GETDATE()`

**Related checks:** A12 (enclave setup), A63 (attestation URL)

---

## A68–A72: Operational Key Lifecycle

### A68 — DMK/SMK backup password lacks complexity

**What it means**
The DMK/SMK backup password is the only protection for the backed-up key file. A weak password (< 14 chars, no special chars) can be brute-forced, giving an attacker full access to the key hierarchy.

**How to spot it**
Review documented backup procedures, SQL Agent job text, or password vault entries for password complexity. No DMV query can check this.

**Fix options**
1. Re-backup with strong password: `BACKUP MASTER KEY TO FILE = '...' ENCRYPTION BY PASSWORD = '<32+ char random string with mixed case, digits, special chars>'`
2. Store in enterprise password vault with access controls
3. Enforce password policy minimum: 20+ characters, all character classes

**Related checks:** A44 (DMK backup), A47 (SMK backup)

---

### A69 — TLS cert not configured for auto-enrollment

**What it means**
AD CS auto-enrollment automatically renews TLS certificates before expiry, preventing certificate-expiry outages. Manual certificate management is the primary cause of A30 findings.

**How to spot it**
Check Group Policy: `Computer Configuration → Windows Settings → Security Settings → Public Key Policies → Certificate Services Client - Auto-Enrollment` — verify Enabled. Check AD CS template configured for the SQL Server.

**Fix options**
1. Create AD CS template with auto-enrollment permission for SQL Server computer accounts
2. Enable auto-enrollment via GPO
3. `certutil -pulse` to trigger enrollment; verify new cert in `certlm.msc` → Personal store

**Related checks:** A30 (TLS cert expiry)

---

### A70 — No key archival or escrow procedure

**What it means**
Without a documented key escrow procedure, the organization cannot guarantee key recovery if primary custodians are unavailable. PCI-DSS 3.7.6 mandates split-knowledge and dual-control for manual key operations.

**How to spot it**
Review DR runbook and key management documentation. No DMV tracks this — it's a process audit.

**Fix options**
1. Designate primary and secondary key custodians
2. Establish secure escrow location (safe, offline HSM, or escrow service)
3. Document dual-authorization procedure
4. Test recovery annually

**Related checks:** A44 (DMK backup), A47 (SMK backup)

---

### A71 — TDE scan I/O impact never baselined

**What it means**
TDE encryption scans read and rewrite every page in the database. On large databases, this can cause days of elevated I/O. Without a pre-scan baseline, you cannot measure the impact or distinguish scan overhead from workload I/O.

**How to spot it**
Check if pre-TDE I/O baselines exist (PerfMon logs, `sys.dm_io_virtual_file_stats` snapshots). If TDE was enabled without a baseline, no retrospective quantification is possible.

**Fix options**
1. Before enabling TDE: capture `SELECT * FROM sys.dm_io_virtual_file_stats(DB_ID('<db>'), NULL)` and PerfMon Physical Disk counters
2. Enable during maintenance window
3. Monitor `percent_complete` in `sys.dm_database_encryption_keys`
4. SQL 2019+: `ALTER DATABASE [db] SET ENCRYPTION SUSPEND` during peak hours

**Related checks:** A2 (scan in progress)

---

### A72 — Full recovery model without log backup encryption

**What it means**
TDE encrypts the transaction log on disk, but transaction log backup files (`.trn`) are plaintext unless backup encryption is explicitly enabled. Anyone with access to the `.trn` files can restore them and read all transactions.

**How to spot it**
```sql
SELECT database_name, key_algorithm
FROM msdb.dbo.backupset
WHERE type = 'L' AND backup_start_date > DATEADD(DAY, -7, GETDATE())
  AND key_algorithm IS NULL;
```

**Fix options**
1. Add `WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [backup_cert])` to `BACKUP LOG` statements
2. Update maintenance plan scripts
3. Verify next log backup shows `key_algorithm = 'AES_256'`

**Related checks:** A22 (backup encryption), A24 (backup algorithm)

---

## A73–A76: SQL Server Ledger

### A73 — Ledger not enabled on compliance database

**What it means**
SQL Server Ledger (2022+) provides cryptographic data integrity verification using SHA-256 hash chains and database digests. Databases with compliance requirements (financial, legal, regulatory) benefit from ledger's tamper-evident guarantees.

**How to spot it**
```sql
SELECT name, is_ledger_on FROM sys.databases WHERE database_id > 4;
-- is_ledger_on = 0 for compliance-named databases
```

**Fix options**
1. Create new ledger database: `CREATE DATABASE [FinanceLedger] WITH LEDGER = ON`
2. Migrate tables: `CREATE TABLE [dbo].[T] (...) WITH (LEDGER = ON (APPEND_ONLY = ON))`
3. Ledger cannot be enabled on existing databases — new database creation required

**Related checks:** A74–A76

---

### A74 — Ledger digest not configured for auto-storage

**What it means**
Database digests prove data integrity to external auditors. Storing them only on the same server defeats the purpose — a compromised sysadmin can delete or modify digest history.

**How to spot it**
Check if `sp_generate_database_ledger_digest` is scheduled with `@digest_storage_endpoint` pointing to Azure Storage or ACL. No DMV tracks this — check SQL Agent jobs.

**Fix options**
1. Create Azure Storage container or ACL instance
2. Schedule: `EXEC sp_generate_database_ledger_digest @digest_storage_endpoint = 'https://<account>.blob.core.windows.net/<container>'`
3. Create SQL Agent job running daily
4. Test verification from external location

**Related checks:** A73 (ledger enablement), A76 (verification)

---

### A75 — Ledger hash algorithm not SHA-256

**What it means**
SHA-256 is the minimum acceptable hash for cryptographic ledger integrity. Currently only SHA-256 is available in SQL Server 2022 — this check is future-proofing for when weaker algorithms might become available.

**How to spot it**
```sql
SELECT hash_algorithm_desc FROM sys.database_ledger_configurations WHERE database_id = DB_ID();
```

**Fix options**
1. SHA-256 is the only algorithm in SQL 2022 — accept as compliant
2. Document for audit evidence
3. Plan for SHA-384 migration when available for 10+ year retention

**Related checks:** A55 (FIPS compliance)

---

### A76 — Ledger verification not scheduled

**What it means**
Ledger verification (`sp_verify_database_ledger`) is the only way to detect tampering. If never run, tampered data may go undetected indefinitely. Regular verification by external parties is essential to the ledger security model.

**How to spot it**
Check SQL Agent jobs for `sp_verify_database_ledger` calls. If none, verification is not scheduled.

**Fix options**
1. Create SQL Agent job: `EXEC sp_verify_database_ledger FROM '<digest_storage_endpoint>'`
2. Schedule weekly or monthly
3. Configure alerts on failure
4. Have external auditor run verification independently

**Related checks:** A74 (digest storage)

---

## A77–A80: Azure-Specific Encryption

### A77 — TDE protector key vault in different region

**What it means**
A cross-region Key Vault adds latency to DEK decryption, increases risk of Key Vault unavailability during Azure region outages, and complicates network security boundaries.

**How to spot it**
Azure Portal → SQL Server → Transparent Data Encryption → check Key Vault region vs SQL Server region. Or `Get-AzSqlServerTransparentDataEncryptionProtector -ServerName <srv> -ResourceGroupName <rg>`.

**Fix options**
1. Provision Key Vault in same region as SQL Server
2. Migrate TDE key: `az keyvault key import` or key rotation
3. Update TDE protector: `Set-AzSqlServerTransparentDataEncryptionProtector ... -KeyId <new_key_uri>`
4. Verify region affinity in Portal

**Related checks:** A50 (AKV rotation), A51 (service-managed TDE)

---

### A78 — Double encryption not enabled

**What it means**
Azure SQL's infrastructure encryption provides an additional AES-256 layer at the storage infrastructure level beneath TDE. Combined with customer-managed TDE, it provides defense-in-depth for compliance-sensitive workloads.

**How to spot it**
Azure Portal → SQL Database → Transparent Data Encryption → "Infrastructure encryption" toggle is off. Only available at database creation or service tier change.

**Fix options**
1. For new databases: enable during creation
2. For existing: create new database with infrastructure encryption + migrate via `CREATE DATABASE ... AS COPY OF`
3. Verify in Azure Portal

**Related checks:** A51 (service-managed vs BYOK)

---

### A79 — Enclave attestation shared across tenants

**What it means**
A shared MAA/HGS attestation provider allows any registered SQL Server to attest any enclave. In multi-tenant scenarios, a compromised application can impersonate another tenant's enclave.

**How to spot it**
Check how many SQL Servers/instances are registered with the same MAA/HGS instance. In Azure Portal → MAA → see registered providers.

**Fix options**
1. Deploy dedicated MAA/HGS per security boundary
2. Register only servers within that boundary
3. Update client connection strings with dedicated attestation URL
4. Test: cross-boundary attestation should fail

**Related checks:** A63 (attestation URL), A67 (relaxed attestation)

---

### A80 — Audit logs not encrypted at rest

**What it means**
SQL Server Audit logs contain query text, parameters, and user identities. Unencrypted audit logs expose this data to storage account administrators. PCI-DSS Requirement 10 requires audit trail protection.

**How to spot it**
Azure Portal → Storage Account (audit destination) → Encryption → check if "Microsoft-managed keys" or "Customer-managed keys" is active. `az storage account show --name <account> --query encryption`.

**Fix options**
1. Enable Storage Service Encryption (on by default for new accounts — verify)
2. For compliance workloads: configure CMK: `az storage account update --encryption-key-source Microsoft.KeyVault --encryption-key-vault <uri> --encryption-key-name <key>`
3. Verify: `az storage account show --name <account> --query encryption`

**Related checks:** A56 (audit configuration), A78 (double encryption)

---

## DMK Password Auto-Open — A81–A86

### A81 — Database has non-SMK DMK without registered password

**What it means**
A database has a Database Master Key whose `is_master_key_encrypted_by_server = 0` — meaning the DMK is not automatically decryptable by the Service Master Key at startup. SQL Server can auto-open such a DMK if the password is registered via `sp_control_dbmasterkey_password`, which stores the password as a credential in `master.sys.credentials` (encrypted by the SMK) and records a `(credential_id, family_guid)` row in `master.sys.master_key_passwords`. Without this registration, every restart leaves encrypted objects in that database inaccessible.

**How to spot it**
```sql
SELECT d.name, drs.family_guid, d.is_master_key_encrypted_by_server,
       mkp.credential_id
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
LEFT JOIN master.sys.master_key_passwords mkp
       ON mkp.family_guid = drs.family_guid
WHERE d.database_id > 4
  AND d.is_master_key_encrypted_by_server = 0;
-- Any row with NULL credential_id is unregistered
```

**Fix options**
1. Register the password: `EXEC sp_control_dbmasterkey_password @db_name = N'[db]', @password = N'[dmk_password]', @action = N'add'`
2. Add SMK protection (preferred if no isolation requirement): `USE [db]; ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY`
3. Create a SQL Agent startup job: `USE [db]; OPEN MASTER KEY DECRYPTION BY PASSWORD = N'[password]'` (last resort — password in job step)

**Related checks:** A44 (DMK backup), A45 (SMK protection), A82 (SSISDB), A84 (no auto-open path)

---

### A82 — SSISDB DMK password not registered

**What it means**
SSISDB (the SQL Server Integration Services catalog database) deliberately creates its DMK without SMK protection. This is by design — the SSIS catalog uses the DMK to encrypt package parameters, environment variables, and sensitive values. When the catalog is created via `SSISDB.catalog.create_catalog`, the user supplies a password that becomes the sole DMK protector. Unless this password is registered via `sp_control_dbmasterkey_password`, SSIS catalog operations fail after every SQL Server restart with error 15581.

**How to spot it**
```sql
-- Check if SSISDB needs registration
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT d.name, drs.family_guid, d.is_master_key_encrypted_by_server,
       CASE WHEN mkp.credential_id IS NULL THEN 'NOT REGISTERED — will fail on restart'
            ELSE 'Registered — OK' END AS status
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
LEFT JOIN master.sys.master_key_passwords mkp ON mkp.family_guid = drs.family_guid
WHERE d.name = 'SSISDB';

-- The family_guid is in sys.database_recovery_status (not sys.databases):
SELECT database_id, family_guid FROM sys.database_recovery_status WHERE database_id = DB_ID('SSISDB');
```

**Example symptom**
After SQL Server restart: SSIS package execution fails with `The Data Protection API (DPAPI) master key encryption for the SSISDB is not available. Error details: "Please create a master key in the database or open the master key in the session before performing this operation."` or Msg 15581.

**Fix options**
1. Register the catalog creation password: `EXEC sp_control_dbmasterkey_password @db_name = N'SSISDB', @password = N'[catalog_password]', @action = N'add'` (run in master database context)
2. Verify: `SELECT * FROM master.sys.master_key_passwords` — should show a row for SSISDB's family_guid
3. If the catalog creation password is lost: the SSISDB catalog must be dropped (`SSISDB.catalog.drop_catalog`) and recreated — all packages will be lost unless backed up

**Related checks:** A81 (non-SMK DMK), A83 (SMK restore invalidation), A84 (no auto-open path), A85 (restore), A86 (AG replicas)

---

### A83 — SMK restored from foreign instance: registered passwords invalidated

**What it means**
`master.sys.master_key_passwords` stores passwords as SQL Server credentials (`sys.credentials`), which are themselves encrypted by the Service Master Key (SMK). When you restore an SMK backup from a DIFFERENT server instance (`RESTORE SERVICE MASTER KEY FROM FILE`), the current instance's SMK is replaced with the foreign one. All previously registered credentials were encrypted with the OLD instance's SMK — the new (foreign) SMK cannot decrypt them. DMK auto-open via `sys.master_key_passwords` silently fails until passwords are re-registered. Note: `ALTER SERVICE MASTER KEY REGENERATE` on the SAME instance re-encrypts all credentials automatically and does NOT invalidate registrations.

**How to spot it**
```sql
-- Check ERRORLOG for SMK restore events
EXEC xp_readerrorlog 0, 1, N'RESTORE SERVICE MASTER KEY';

-- If evidence of foreign SMK restore, check registered entries
SELECT mkp.family_guid, c.name AS credential_name, c.modify_date
FROM master.sys.master_key_passwords mkp
JOIN master.sys.credentials c ON mkp.credential_id = c.credential_id;
-- If c.modify_date is older than the SMK restore date, entries may be stale
```

**Fix options**
1. After any `RESTORE SERVICE MASTER KEY FROM FILE`: for each database in `sys.master_key_passwords`, re-register: `EXEC sp_control_dbmasterkey_password @action = 'drop'` then `@action = 'add'`
2. Maintain a vault-stored inventory: which databases have registered passwords and what the current passwords are
3. Create a post-SMK-restore SQL Agent job that re-registers all known databases

**Related checks:** A47 (SMK backup), A81 (non-SMK DMK), A82 (SSISDB), A85 (cross-server restore)

---

### A84 — Non-SMK DMK with no auto-open path configured

**What it means**
A database has `is_master_key_encrypted_by_server = 0` (no SMK protection), no password registered in `sys.master_key_passwords`, and no SQL Agent startup job that manually opens the key. This means every SQL Server restart leaves the DMK unopenable until a DBA manually runs `OPEN MASTER KEY DECRYPTION BY PASSWORD`. Any automated jobs, services, or application connections that hit encrypted objects before the DBA intervenes will fail.

**How to spot it**
```sql
-- Find databases with non-SMK DMK and no registered password
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT d.name, drs.family_guid
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
WHERE d.database_id > 4
  AND d.is_master_key_encrypted_by_server = 0
  AND NOT EXISTS (
    SELECT 1 FROM master.sys.master_key_passwords mkp
    WHERE mkp.family_guid = drs.family_guid
  );

-- Also check SQL Agent jobs for OPEN MASTER KEY
SELECT j.name, s.command FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.command LIKE '%OPEN MASTER KEY%';
```

**Fix options**
1. Preferred: `USE [db]; ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY` — enables automatic decryption; verify with `SELECT is_master_key_encrypted_by_server FROM sys.databases WHERE name = '[db]'`
2. Alternative: `EXEC sp_control_dbmasterkey_password @db_name = N'[db]', @password = N'[password]', @action = N'add'`
3. Last resort: SQL Agent startup job with `OPEN MASTER KEY` — stores password in job step (see A99)

**Related checks:** A45 (SMK protection), A46 (password-only), A81 (registration), A82 (SSISDB), A99 (job step password)

---

### A85 — Restored database with non-SMK DMK not re-registered on target

**What it means**
`sys.master_key_passwords` is instance-local (stored in `master` database). When you restore a database with a password-protected DMK to a new SQL Server instance, the `family_guid` is preserved from the source (it's stable across restore/attach), but the target instance has no corresponding entry in its `sys.master_key_passwords`. The database DMK will not auto-open on the target until the password is re-registered.

**How to spot it**
```sql
-- Databases restored from another server with unregistered password-only DMK
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT r.destination_database_name, d.is_master_key_encrypted_by_server, drs.family_guid
FROM msdb.dbo.restorehistory r
JOIN sys.databases d ON d.name = r.destination_database_name
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
WHERE d.database_id > 4
  AND d.is_master_key_encrypted_by_server = 0
  AND NOT EXISTS (
    SELECT 1 FROM master.sys.master_key_passwords mkp
    WHERE mkp.family_guid = drs.family_guid
  )
ORDER BY r.restore_date DESC;
```

**Fix options**
1. Register on target: `EXEC sp_control_dbmasterkey_password @db_name = N'[db]', @password = N'[original_dmk_password]', @action = N'add'`
2. Add to restore runbook: after restoring any database with `is_master_key_encrypted_by_server = 0`, always check and register the password
3. If the original password is unknown: the DMK can be opened by restoring from a DMK backup: `RESTORE MASTER KEY FROM FILE = '...' DECRYPTION BY PASSWORD = '...' ENCRYPTION BY PASSWORD = '...'`

**Related checks:** A44 (DMK backup), A81 (registration), A83 (SMK restore), A85/A86 (AG)

---

### A86 — AG secondary with non-SMK DMK not registered on secondary replicas

**What it means**
When a database with a password-protected DMK is part of an Availability Group, each replica needs the DMK password registered in its own `sys.master_key_passwords`. AG seeding (automatic or manual) copies the database data but does NOT copy `master.sys.master_key_passwords` entries from the primary. On failover, the new primary inherits the database but not the auto-open path — SSIS, encrypted objects, and cert-protected keys all fail until the DBA registers the password on the new primary.

**How to spot it**
```sql
-- On each AG secondary, check for missing registrations
-- family_guid is in sys.database_recovery_status, not sys.databases
SELECT d.name, d.is_master_key_encrypted_by_server, drs.family_guid
FROM sys.databases d
JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
JOIN sys.dm_hadr_database_replica_states rs ON rs.database_id = d.database_id
WHERE d.database_id > 4
  AND d.is_master_key_encrypted_by_server = 0
  AND NOT EXISTS (
    SELECT 1 FROM master.sys.master_key_passwords mkp
    WHERE mkp.family_guid = drs.family_guid
  );
```

**Fix options**
1. Run on every replica: `EXEC sp_control_dbmasterkey_password @db_name = N'[db]', @password = N'[dmk_password]', @action = N'add'`
2. Add to AG deployment checklist: after adding a database to an AG, verify all replicas have DMK passwords registered
3. Add to failover runbook: after failover, verify new primary has all registrations intact; re-register any that are missing

**Related checks:** A81 (non-SMK DMK), A82 (SSISDB), A83 (SMK restore), A85 (restore), A33 (AG cert)

---

## Dynamic Data Masking and Permission Patterns — A87–A91

### A87 — Sensitive column masked but not encrypted

**What it means**
Dynamic Data Masking (DDM) presents masked values to unprivileged users at the query result layer. It is NOT encryption — it does not protect data at rest, does not protect against privileged SQL users (sysadmin, UNMASK grantees), does not prevent inference attacks (queries like `WHERE column BETWEEN x AND y` return accurate row counts without revealing values), and does not satisfy most compliance requirements for encryption at rest.

**How to spot it**
```sql
SELECT t.name AS table_name, c.name AS column_name,
       c.masking_function, c.column_encryption_key_id
FROM sys.masked_columns c
JOIN sys.tables t ON c.object_id = t.object_id
WHERE c.name LIKE '%ssn%' OR c.name LIKE '%card%' OR c.name LIKE '%password%'
   OR c.name LIKE '%salary%' OR c.name LIKE '%dob%' OR c.name LIKE '%diagnosis%'
   AND c.column_encryption_key_id IS NULL;
```

**Fix options**
1. Apply Always Encrypted for columns requiring true confidentiality (sysadmin cannot read plaintext)
2. Apply CLE for simpler server-side encryption (sysadmin can read; good for legacy apps)
3. Retain DDM as a complementary display layer alongside encryption; DDM + AE together means application users see masked values AND sysadmins see encrypted ciphertext (neither sees plaintext without the column master key)
4. See `howto-dynamic-data-masking.md` for the full decision tree

**Related checks:** A14 (sensitive columns without AE), A53 (sensitivity classification), A88 (UNMASK permission), A91 (CLE cipher text)

---

### A88 — UNMASK permission granted to a broad role

**What it means**
The `UNMASK` permission bypasses Dynamic Data Masking for a database principal — they see unmasked (real) values. Granting it to a role means every current and future member of that role receives unrestricted access to all masked columns. This effectively renders DDM useless as a control for anyone in that role.

**How to spot it**
```sql
SELECT dp.name AS grantee, dp.type_desc,
       (SELECT COUNT(*) FROM sys.database_role_members rm
        WHERE rm.role_principal_id = dp.principal_id) AS member_count
FROM sys.database_permissions p
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
WHERE p.permission_name = 'UNMASK'
  AND dp.type IN ('R', 'G', 'E');  -- role, group, external group
```

**Fix options**
1. `REVOKE UNMASK FROM [role_name]`
2. Grant UNMASK only to named individuals: `GRANT UNMASK TO [user_name]`
3. Audit who has UNMASK: `SELECT * FROM sys.database_permissions WHERE permission_name = 'UNMASK'`
4. Schedule regular UNMASK permission reviews via SQL Agent

**Related checks:** A87 (masking vs encryption), A89 (certificate CONTROL), A40 (key CONTROL)

---

### A89 — CONTROL permission on certificate granted to non-sysadmin

**What it means**
CONTROL on a database certificate grants all permissions: USE (for encryption/decryption), ALTER, DROP, TAKE OWNERSHIP. For certificates protecting TDE, Service Broker routes, backup encryption, or code-signing patterns, an over-privileged non-admin user could drop the certificate (destroying encrypted data recovery paths), alter it, or use it for unauthorized signing. This extends A40 which covers symmetric/asymmetric keys — certificates are a separate permission class.

**How to spot it**
```sql
SELECT dp.name AS grantee, c.name AS certificate_name
FROM sys.database_permissions p
JOIN sys.certificates c ON p.major_id = c.certificate_id
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
WHERE p.class_desc = 'CERTIFICATE_OBJECT'
  AND p.permission_name = 'CONTROL'
  AND dp.name NOT IN ('dbo', 'db_owner');
```

**Fix options**
1. `REVOKE CONTROL ON CERTIFICATE::[cert] FROM [principal]`
2. Grant purpose-specific permissions: `REFERENCES` for AE CMK, `EXECUTE` for signing procedures
3. For TDE/backup certs: no permission grant needed — sysadmin role provides implicit access; remove all explicit grants

**Related checks:** A40 (key CONTROL), A34 (cert-based login), A37 (cert backup)

---

### A90 — Row-Level Security predicate referencing an Always Encrypted column

**What it means**
Always Encrypted encrypts column values client-side before they reach SQL Server. The server-side SQL engine never sees plaintext — it receives encrypted byte strings. Row-Level Security filter predicates are evaluated server-side, so any predicate comparing an AE column to a plaintext literal always produces a mismatch. The result: filter predicates return zero rows (if a blocking predicate) or allow all rows through (if a permissive SELECT filter compares ciphertext to literal). Neither is correct.

**How to spot it**
```sql
SELECT sp.name AS policy_name, sp.type_desc,
       o.name AS table_name, c.name AS column_name,
       c.encryption_type_desc
FROM sys.security_policies sp
JOIN sys.security_predicates pred ON sp.object_id = pred.object_id
JOIN sys.columns c ON pred.target_column_id = c.column_id
    AND pred.target_object_id = c.object_id
JOIN sys.tables o ON c.object_id = o.object_id
WHERE c.column_encryption_key_id IS NOT NULL;
```

**Fix options**
1. Move row-filtering logic to the application layer (WHERE clause in application queries using AE-aware driver)
2. Use deterministic AE encryption for the filter column — still encrypted but equality-comparable by an AE-enabled driver
3. Remove the RLS policy on AE columns; document the known limitation

**Related checks:** A9 (deterministic vs randomized AE), A10 (AE + enclave), A87 (DDM limitations)

---

### A91 — CLE-encrypted column without masked fallback

**What it means**
When a column is encrypted with CLE (via `ENCRYPTBYKEY`), reporting users who do not have the symmetric key open receive raw `varbinary` cipher text in their query results. This cipher text: (1) confirms to the user that the column is encrypted, (2) reveals data-length patterns (longer cipher text = longer plaintext), (3) may cause application errors if the application expects a specific data type. Adding a DDM mask returns a neutral value instead of cipher text.

**How to spot it**
```sql
SELECT t.name AS table_name, c.name AS column_name
FROM sys.tables t
JOIN sys.columns c ON t.object_id = c.object_id
WHERE c.system_type_id = 165  -- varbinary (CLE result type)
  AND NOT EXISTS (
    SELECT 1 FROM sys.masked_columns mc
    WHERE mc.object_id = c.object_id AND mc.column_id = c.column_id
  )
  AND EXISTS (
    SELECT 1 FROM sys.database_permissions dp
    WHERE dp.major_id = t.object_id
      AND dp.permission_name = 'SELECT'
      AND dp.grantee_principal_id <> 1  -- exclude dbo
  );
```

**Fix options**
1. Add a default DDM mask: `ALTER TABLE [dbo].[t] ALTER COLUMN [col] ADD MASKED WITH (FUNCTION = 'default()')`
2. Grant UNMASK only to users who also have the symmetric key available
3. Ensure CLE-encrypted varbinary columns are typed consistently (not returned as nvarchar to application)

**Related checks:** A17 (CLE algorithms), A18 (open key scope), A87 (masking), A88 (UNMASK)

---

## Compliance Explicit Checks — A92–A98

### A92 — PCI-DSS v4: PAN stored without column-level encryption

**What it means**
PCI-DSS v4.0 Requirement 3.5.1 requires that the Primary Account Number (PAN) be rendered unreadable anywhere it is stored. TDE encrypts the database files but does NOT prevent a SQL user with SELECT permission from reading the plaintext PAN. Column-level encryption (Always Encrypted) encrypts the data before it reaches the server — even a sysadmin sees only ciphertext, satisfying the "unreadable" requirement for SQL-level access.

**How to spot it**
```sql
SELECT DB_NAME() AS db_name, SCHEMA_NAME(t.schema_id) AS schema_name,
       t.name AS table_name, c.name AS column_name
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
WHERE (c.name LIKE '%card_number%' OR c.name LIKE '%pan%'
    OR c.name LIKE '%primary_account%' OR c.name LIKE '%credit_card%')
  AND c.column_encryption_key_id IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM sys.sql_modules m WHERE m.definition LIKE '%ENCRYPTBYKEY%'
      AND m.definition LIKE '%' + t.name + '%'
  );
```

**Fix options**
1. Apply Always Encrypted with deterministic encryption (allows equality-based lookups): use SSMS Encrypt Columns wizard or `Set-SqlColumnEncryption` PowerShell
2. Truncate PANs where full value is not needed (store first 6 + last 4 only)
3. Replace with tokenisation (store a token, keep PAN in a separate token vault)
4. Document chosen approach in PCI-DSS evidence: attestation letters and QSA will require proof

**Related checks:** A1 (TDE), A9/A14 (AE column gaps), A53–A54 (sensitivity), A93 (key rotation)

---

### A93 — PCI-DSS v4: No evidence of annual key rotation

**What it means**
PCI-DSS v4.0 Requirement 3.7.3 mandates that cryptographic keys used to protect cardholder data are changed "at least once a year." Keys protecting PAN columns (CLE symmetric keys) or backup encryption certificates for PCI-scope databases must have evidence of rotation. The `modify_date = create_date` pattern in `sys.symmetric_keys` means the key was created and never subsequently altered — a strong indicator it was never rotated.

**How to spot it**
```sql
SELECT name, create_date, modify_date, algorithm_desc,
       DATEDIFF(DAY, create_date, GETDATE()) AS age_days
FROM sys.symmetric_keys
WHERE name NOT LIKE '##%'
  AND modify_date = create_date
  AND create_date < DATEADD(YEAR, -1, GETDATE());
```

**Fix options**
1. Create a replacement key, re-encrypt data, drop old key (see `howto-key-rotation.md`)
2. Adopt a naming convention that includes year: `CLE_PAN_Key_2026` — makes rotation history visible
3. Schedule annual rotation in SQL Agent; document in PCI key management policy
4. For backup certs: `CREATE CERTIFICATE [NewBackupCert2026] ...`; update backup scripts; retain old cert for restoring older backups

**Related checks:** A20 (CLE rotation), A41 (key rotation 2yr), A92 (PCI PAN), A4 (TDE cert expiry)

---

### A94 — GDPR Art. 17: PII in append-only ledger without crypto-shredding strategy

**What it means**
Append-only ledger tables (`ledger_type = 2`) are cryptographically immutable — rows can never be deleted, updated, or truncated; the hash chain would be broken. GDPR Article 17 grants data subjects the right to erasure ("right to be forgotten"). For PII in append-only ledger tables, the only technically sound erasure method is crypto-shredding: encrypting data with a per-subject key, then deleting that key. Without a per-subject key architecture, erasure is impossible.

**How to spot it**
```sql
-- SQL 2022+: find append-only ledger tables with PII-like columns
SELECT t.name AS table_name, c.name AS column_name
FROM sys.tables t
JOIN sys.columns c ON t.object_id = c.object_id
WHERE t.ledger_type = 2  -- append-only
  AND (c.name LIKE '%ssn%' OR c.name LIKE '%email%' OR c.name LIKE '%name%'
    OR c.name LIKE '%address%' OR c.name LIKE '%phone%' OR c.name LIKE '%dob%')
  AND NOT EXISTS (
    SELECT 1 FROM sys.columns ck WHERE ck.object_id = t.object_id
      AND (ck.name LIKE '%key_id%' OR ck.name LIKE '%subject_id%')
  );
```

**Fix options**
1. Switch to updatable ledger table: `CREATE TABLE ... WITH (LEDGER = ON)` (default is updatable); supports DELETE with history audit, compatible with GDPR erasure
2. Implement per-subject CLE keys: one symmetric key per data subject; delete the key when erasure is requested; see `howto-crypto-shredding.md`
3. Store only pseudonymous identifiers (hashed subject IDs) in append-only ledger; keep identifying PII in a separate updatable ledger table
4. Document the GDPR tension in the data privacy impact assessment (DPIA)

**Related checks:** A73 (ledger enablement), A76 (ledger verification), A53 (sensitivity)

---

### A95 — FIPS: Windows FIPS mode not enabled for regulated workloads

**What it means**
FedRAMP HIGH, CMMC Level 3, DoD IL4+, and several other US government frameworks require that all cryptographic operations use FIPS 140-2 validated modules. SQL Server inherits the OS FIPS setting — when Windows FIPS mode is enabled, SQL Server rejects non-FIPS algorithms (RC4, MD5, SHA-1, DES, 3DES for new operations). The ERRORLOG contains "FIPS compliance mode is enabled" when active.

**How to spot it**
```sql
-- Check ERRORLOG for FIPS mode status (most recent startup)
EXEC xp_readerrorlog 0, 1, N'FIPS';
-- Should return "FIPS compliance mode is enabled" if active
-- Absence = FIPS mode not enabled
```

**Fix options**
1. Enable via Group Policy: Computer Configuration → Windows Settings → Security Settings → Local Policies → Security Options → "System cryptography: Use FIPS compliant algorithms for encryption, hashing, and signing" = Enabled
2. Restart SQL Server; verify ERRORLOG shows "FIPS compliance mode is enabled"
3. Test all applications: some older ODBC/JDBC drivers and .NET Framework apps fail in FIPS mode (requires FIPS-compliant crypto providers in the application stack)
4. Remediate A55 (non-FIPS algorithms) before enabling FIPS mode

**Related checks:** A55 (non-FIPS algorithms), A96 (software EKM), A17 (CLE algorithms)

---

### A96 — FIPS environment using software-only EKM provider

**What it means**
FIPS 140-2 Level 2 requires that cryptographic modules provide physical tamper evidence and resistance. Software-only EKM providers (DLLs without HSM hardware backing) meet at most Level 1 (algorithmic correctness only). For FedRAMP HIGH, CMMC, and NSS use cases, key material must reside in a FIPS 140-2 Level 2+ validated hardware security module.

**How to spot it**
```sql
-- Identify EKM providers and assess if they are HSM-backed
SELECT provider_id, name, dll_path, is_enabled, provider_version
FROM sys.cryptographic_providers;
-- Manually cross-reference DLL name/path against NIST CMVP list:
-- https://csrc.nist.gov/projects/cryptographic-module-validation-program
```

**Fix options**
1. Replace with a validated HSM provider: nCipher nShield, Thales Luna/SafeNet, Entrust nShield, IBM 4769 CCID, AWS CloudHSM, Azure Dedicated HSM
2. Verify HSM FIPS 140-2 Level 2 certificate at csrc.nist.gov/projects/cryptographic-module-validation-program
3. Follow HSM vendor migration guide to move existing keys to HSM; update EKM provider DLL
4. For Azure: use Azure Dedicated HSM (HSM validated to FIPS 140-2 Level 3) instead of shared Azure Key Vault (Level 1)

**Related checks:** A49 (EKM provider health), A52 (EKM version), A95 (FIPS mode)

---

### A97 — No documented key custodian or key management policy

**What it means**
PCI-DSS v4.0 Requirement 3.7.6 requires that manual cleartext cryptographic keys use split-knowledge and dual-control procedures (two custodians each knowing half the key). NY DFS 23 NYCRR 500 §500.15 requires documented cryptographic controls. CMMC SC.3.191 requires a key management procedure. The absence of SQL Agent jobs named for key maintenance, an active SQL Server Audit, or any data classification suggests the organisation lacks documented cryptographic governance.

**How to spot it**
```sql
-- Check for key-related SQL Agent jobs
SELECT name FROM msdb.dbo.sysjobs
WHERE name LIKE '%key%' OR name LIKE '%cert%' OR name LIKE '%dmk%' OR name LIKE '%smk%';

-- Check for active SQL Server Audit
SELECT name, status_desc FROM sys.server_audits WHERE status_desc = 'STARTED';
```

**Fix options**
1. Create and document a key inventory: list all keys, certs, responsible custodians, rotation schedule
2. Create SQL Agent jobs with naming convention: `DBA - Annual TDE Cert Rotation`, `DBA - Annual SMK Backup Verification`
3. Configure SQL Server Audit for key access events (A56 fix)
4. For PCI: document split-knowledge procedure for manual key ceremonies; maintain key custodian acknowledgement records

**Related checks:** A56 (SQL Audit), A44/A47 (DMK/SMK backup), A93 (PCI rotation), A70 (key archival)

---

### A98 — HIPAA: PHI columns without encryption and no SELECT audit trail

**What it means**
HIPAA 45 CFR §164.312(a)(2)(iv) addresses encryption of ePHI as an addressable safeguard (must implement unless documented otherwise with an equivalent alternative). §164.312(b) requires audit controls to record and examine activity on systems containing ePHI. Unencrypted PHI columns without any SELECT audit fail both safeguards simultaneously — there is neither technical protection nor visibility into who accessed the data.

**How to spot it**
```sql
-- PHI-pattern columns without AE
SELECT SCHEMA_NAME(t.schema_id) AS schema_name, t.name AS table_name, c.name AS column_name
FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
WHERE (c.name LIKE '%ssn%' OR c.name LIKE '%diagnosis%' OR c.name LIKE '%medical_record%'
    OR c.name LIKE '%prescription%' OR c.name LIKE '%dob%' OR c.name LIKE '%patient%')
  AND c.column_encryption_key_id IS NULL;

-- Check audit specifications for PHI table coverage
SELECT a.name AS audit, das.name AS spec, dap.action_id, dap.object_name
FROM sys.server_audits a
JOIN sys.database_audit_specifications das ON a.audit_guid = das.audit_guid
JOIN sys.database_audit_specification_details dap ON das.database_specification_id = dap.database_specification_id
WHERE dap.action_id IN ('SL', 'UP', 'IN', 'DL');  -- SELECT, UPDATE, INSERT, DELETE
```

**Fix options**
1. Apply Always Encrypted to PHI columns (see `howto-always-encrypted.md`)
2. Create database audit specification: `ADD (SELECT ON OBJECT::[schema].[table] BY PUBLIC)` scoped to PHI tables
3. Ensure audit log retention ≥ 6 years (HIPAA §164.316(b)(2))
4. Document the decision in a HIPAA risk analysis; if PHI is not encrypted, document the equivalent alternative measure

**Related checks:** A14 (sensitive columns), A53–A54 (sensitivity classification), A56 (audit config), A92 (PCI PAN)

---

## Operational Validation — A99–A104

### A99 — SQL Agent job step with hardcoded OPEN SYMMETRIC KEY password

**What it means**
SQL Agent job steps store their T-SQL command text in `msdb.dbo.sysjobsteps.command`. This column is readable by any sysadmin via SSMS or T-SQL. Passwords embedded in `OPEN SYMMETRIC KEY [key] DECRYPTION BY PASSWORD = 'secret'` are stored in near-plaintext in MSDB, visible in SSMS Job Step UI, logged in SQL Server error log on step failure, and exposed to any monitoring tool, APM agent, or 3rd-party DBA tool with sysadmin access. It is equivalent to hardcoding a password in source code checked into a public repository.

**How to spot it**
```sql
SELECT j.name AS job_name, s.step_name, s.command
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.command LIKE '%OPEN SYMMETRIC KEY%DECRYPTION BY PASSWORD%';
```

**Fix options**
1. Replace with certificate-based protection: `OPEN SYMMETRIC KEY [key] DECRYPTION BY CERTIFICATE [cert]` — the cert's private key is protected by the DMK which auto-opens via SMK; no password in job code
2. If the symmetric key must stay password-protected, store the OPEN call in a signed stored procedure that the job calls via proxy; the procedure's source is still visible but the indirection reduces casual exposure
3. See `howto-agent-jobs.md` for secure SQL Agent job patterns

**Related checks:** A19 (password-protected keys), A100 (plan cache), A18 (open key scope), A84 (DMK auto-open)

---

### A100 — Plan cache contains OPEN SYMMETRIC KEY with visible password

**What it means**
SQL Server's plan cache stores the full text of recently executed SQL statements in `sys.dm_exec_sql_text`. Any user with `VIEW SERVER STATE` permission (granted to operator roles, monitoring tools, APM agents, 3rd-party DBA tools) can read the full query text including embedded passwords. Unlike `sp_control_dbmasterkey_password` (which deliberately does not appear in traces), ad-hoc T-SQL with hardcoded passwords appears verbatim in the plan cache.

**How to spot it**
```sql
SELECT qs.execution_count, SUBSTRING(qt.text, 1, 500) AS query_excerpt
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
WHERE qt.text LIKE '%OPEN SYMMETRIC KEY%DECRYPTION BY PASSWORD%'
   OR qt.text LIKE '%ENCRYPTBYPASSPHRASE%'
   OR qt.text LIKE '%OPEN MASTER KEY DECRYPTION BY PASSWORD%';
```

**Fix options**
1. Immediate: `DBCC FREEPROCCACHE` to evict exposed plans from cache
2. Permanent: migrate to certificate-based key protection (A99 fix); passwords disappear from T-SQL source
3. Audit VIEW SERVER STATE grants: `SELECT * FROM sys.server_permissions WHERE permission_name = 'VIEW SERVER STATE'`

**Related checks:** A99 (job step password), A19 (password-protected keys), A108 (ENCRYPTBYPASSPHRASE)

---

### A101 — AKV soft-delete or purge protection not enabled

**What it means**
Azure Key Vault's soft-delete and purge protection settings prevent permanent key deletion. Without soft-delete, a deleted key is immediately and permanently gone. Without purge protection, even a soft-deleted key can be purged (permanently deleted) before the retention period expires. If the TDE protector key or AE CMK is deleted — accidentally, by a malicious insider, or by a compromised service principal — all databases using that key become permanently and irrecoverably inaccessible within minutes.

**How to spot it**
```bash
# Azure CLI check
az keyvault show --name [vault-name] --query "properties.{softDelete:enableSoftDelete, purgeProtection:enablePurgeProtection}"
# Expected: { "softDelete": true, "purgeProtection": true }
```

**Fix options**
1. `az keyvault update --name [vault] --enable-soft-delete true --enable-purge-protection true`
2. Set minimum retention: `az keyvault update --retention-days 90` (90 days minimum for compliance)
3. Enable Azure Policy: "Azure Key Vault should have soft delete enabled" and "Azure Key Vault should have purge protection enabled" at subscription scope
4. Verify via Azure Portal: Key Vault → Properties → Soft-delete and Purge protection

**Related checks:** A50 (BYOK rotation), A79 (attestation), A101 pair with A51

---

### A102 — No annual encrypted backup restore test on record

**What it means**
An encrypted backup is only as good as the ability to restore it. Certificate rotation, SMK regeneration, infrastructure migration, or key vault access policy changes can silently break the restore chain. The organisation may not discover this until a disaster recovery event — at which point the encrypted backup is a collection of permanently inaccessible files. Annual restore tests to an isolated environment provide continuous confidence in the recovery chain.

**How to spot it**
```sql
-- Most recent restore for databases with encrypted backups
SELECT bs.database_name, MAX(rh.restore_date) AS last_restore,
       DATEDIFF(DAY, MAX(rh.restore_date), GETDATE()) AS days_since_restore
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.restorehistory rh ON rh.backup_set_id = bs.backup_set_id
WHERE bs.key_algorithm IS NOT NULL  -- encrypted backups only
GROUP BY bs.database_name
HAVING MAX(rh.restore_date) < DATEADD(YEAR, -1, GETDATE())
    OR MAX(rh.restore_date) IS NULL;
```

**Fix options**
1. Schedule annual `RESTORE DATABASE [db] WITH RECOVERY` to an isolated test server
2. Restore the certificate first: `RESTORE MASTER KEY FROM FILE = '...'` or `CREATE CERTIFICATE [cert] FROM FILE = '...' WITH PRIVATE KEY (FILE = '...', DECRYPTION BY PASSWORD = '...')`
3. Document the test result, certificate thumbprint used, and test environment in the DR runbook
4. For SSISDB: test restoring the SSISDB catalog and registering the DMK password on the test instance

**Related checks:** A3 (TDE cert backup), A23 (backup cert backup), A85 (cross-server restore), A44 (DMK backup)

---

### A103 — sys.credentials age exceeds 1 year without rotation

**What it means**
`sys.credentials` stores secrets for EKM providers, proxy accounts, and Database Mail. These are encrypted by the SMK. Long-lived secrets increase the exposure window — a stolen credential (from a memory dump, SMK compromise, or disgruntled employee who memorised it) remains valid until rotated. Unlike key material that has cryptographic age indicators, credential rotation is purely an administrative discipline.

**How to spot it**
```sql
SELECT name, credential_identity, create_date, modify_date,
       DATEDIFF(DAY, modify_date, GETDATE()) AS days_since_rotation
FROM sys.credentials
WHERE modify_date < DATEADD(YEAR, -1, GETDATE())
  AND credential_identity NOT LIKE '%DOMAIN\%'  -- exclude Windows accounts
  AND credential_identity NOT LIKE '%@%';  -- exclude Azure AD / email-style accounts
```

**Fix options**
1. Rotate EKM provider credentials: `ALTER CREDENTIAL [name] WITH IDENTITY = N'[identity]', SECRET = N'new_secret'`
2. Rotate proxy account credentials: update in MSDB, coordinate with target service
3. For Database Mail SMTP: update password in SSMS → Management → Database Mail → Configure → Account properties
4. Document rotation schedule in the key management policy

**Related checks:** A103 pair with A110 (Database Mail), A49/A52 (EKM provider), A47 (SMK backup)

---

### A104 — AG listener TLS certificate does not include listener DNS name in SAN

**What it means**
Availability Group listeners have their own DNS name (e.g., `aglistener.domain.com`) separate from the underlying SQL Server instance names. When clients connect via the listener, TLS certificate validation checks whether the listener DNS name matches the certificate CN or a Subject Alternative Name (SAN) entry. If the certificate only has the instance hostname, clients connecting to the listener receive a certificate name mismatch error or bypass validation by setting `TrustServerCertificate=True`.

**How to spot it**
```sql
-- Check AG listeners and their DNS names
SELECT a.name AS ag_name, l.dns_name, l.port, c.subject
FROM sys.availability_groups a
JOIN sys.availability_group_listeners l ON a.group_id = l.group_id
LEFT JOIN sys.certificates c ON c.pvt_key_encryption_type_desc != 'NO_PRIVATE_KEY'
    AND c.subject LIKE '%' + SUBSTRING(l.dns_name, 1, CHARINDEX('.', l.dns_name)-1) + '%';
-- If the JOIN returns NULL, the listener name may not be in any cert SAN
```

**Fix options**
1. Include all AG listener DNS names in the TLS certificate SAN when requesting from CA
2. If the current cert is missing the listener SAN: renew the cert with the listener name added; rebind in SQL Server Configuration Manager; restart
3. Test: `openssl s_client -connect aglistener.domain.com:1433 -starttls mssql 2>&1 | grep -E "subject|SAN|verify"`
4. Alternative: configure a dedicated listener certificate in SQL Server Configuration Manager (separate from the instance cert)

**Related checks:** A28 (self-signed cert), A30 (cert expiry), A33 (AG endpoint cert), A26 (ForceEncryption)

---

## Advanced Cryptographic Patterns — A105–A112

### A105 — TLS cipher suite ordering: ECDHE not prioritised

**What it means**
TLS cipher suite negotiation uses the CLIENT's preference order by default. If ECDHE (Elliptic Curve Diffie-Hellman Ephemeral) suites are not at the top of the server's list, negotiation may fall back to RSA key exchange, which lacks Perfect Forward Secrecy (PFS). With PFS, a compromised server private key cannot decrypt previously captured TLS sessions. Without it, a retroactive breach of the server's private key exposes all past session content.

**How to spot it**
```powershell
# Check cipher suite order via registry (PowerShell)
$path = 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002'
(Get-ItemProperty -Path $path -Name Functions -ErrorAction SilentlyContinue).Functions -split ','
# ECDHE suites should appear before RSA suites
```

**Fix options**
1. Use IIS Crypto (free tool from Nartac Software) to reorder: enable ECDHE suites first, disable RC4/DES/NULL
2. Via Group Policy: Computer Configuration → Administrative Templates → Network → SSL Configuration Settings → SSL Cipher Suite Order
3. Recommended order (top-to-bottom): `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`, `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, then RSA suites for compatibility
4. Restart SQL Server after registry changes; verify with Qualys SSL Labs or nmap `--script ssl-enum-ciphers`

**Related checks:** A57 (legacy TLS), A58 (weak ciphers), A26 (ForceEncryption)

---

### A106 — Remote connections authenticating via NTLM

**What it means**
NTLM (NT LAN Manager) authentication is vulnerable to relay attacks: a man-in-the-middle captures the NTLM challenge/response and relays it to authenticate against another server (NTLM relay attack). NTLM also does not provide mutual authentication — the client cannot cryptographically verify the server's identity. Kerberos with FAST armoring provides mutual authentication and is resistant to relay. NTLM on encrypted TLS is lower risk but still a weaker authentication layer.

**How to spot it**
```sql
SELECT client_net_address, auth_scheme, encrypt_option, COUNT(*) AS connections
FROM sys.dm_exec_connections
WHERE auth_scheme = 'NTLM'
  AND client_net_address NOT IN ('<local machine>', '127.0.0.1', '::1')
GROUP BY client_net_address, auth_scheme, encrypt_option;
```

**Fix options**
1. Register SPNs to enable Kerberos: `setspn -S MSSQLSvc/hostname.domain.com:1433 DOMAIN\sqlserviceaccount`
2. See `/sqlspn-review` for comprehensive SPN audit (K-checks)
3. Enable Extended Protection for Authentication in SQL Server Configuration Manager
4. Verify Kerberos is negotiated: `SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID` should return 'KERBEROS'

**Related checks:** A61 (Kerberos armoring), A26/A27 (TLS enforcement)

---

### A107 — Service Broker remote endpoint certificate not imported into target database

**What it means**
Service Broker uses certificates to authenticate inter-instance communication. The initiating service sends messages signed with its private key; the target verifies the signature using the sender's public certificate, which must be imported into the target database (as a certificate without a private key). Without this import, the target cannot verify the sender's identity and rejects all messages with authentication errors.

**How to spot it**
```sql
-- Find Service Broker endpoints using certificate auth
SELECT e.name, e.type_desc, e.connection_auth_desc, c.name AS cert_name,
       c.thumbprint, c.subject
FROM sys.endpoints e
JOIN sys.certificates c ON e.certificate_id = c.certificate_id
WHERE e.type_desc = 'SERVICE_BROKER'
  AND e.connection_auth_desc LIKE '%CERTIFICATE%';

-- Check if cert public key is imported in target databases
-- (Run this query in each target database that receives messages)
SELECT name, pvt_key_encryption_type_desc, subject
FROM sys.certificates
WHERE pvt_key_encryption_type_desc = 'NO_PRIVATE_KEY';
-- Public-key-only certs (imported from sender) should appear here
```

**Fix options**
1. Export sender cert (public key only): `BACKUP CERTIFICATE [sb_cert] TO FILE = 'C:\temp\sb_cert.cer'` (omit WITH PRIVATE KEY)
2. Copy to target server; import: `CREATE CERTIFICATE [sender_cert] AUTHORIZATION [broker_user] FROM FILE = 'C:\temp\sb_cert.cer'`
3. Create a remote service binding: `CREATE REMOTE SERVICE BINDING [binding] TO SERVICE 'TargetServiceName' WITH USER = [broker_user], ANONYMOUS = OFF`
4. Test by sending a test message and checking `sys.transmission_queue` for errors

**Related checks:** A32 (SB cert rotation), A35 (SHA1 cert), A37 (cert backup), A36 (self-signed)

---

### A108 — ENCRYPTBYPASSPHRASE with weak or visible passphrase

**What it means**
`ENCRYPTBYPASSPHRASE` uses PBKDF1 — Password-Based Key Derivation Function 1 — to derive an encryption key from the passphrase. PBKDF1 uses only 1 iteration of SHA-1 (no bcrypt-style cost factor), making it GPU-acceleratable for brute-force. A passphrase of 12 characters can be cracked in minutes with modern hardware. The passphrase also appears verbatim in T-SQL source code, plan cache, and SQL Agent job step history.

**How to spot it**
```sql
-- Find modules using ENCRYPTBYPASSPHRASE
SELECT OBJECT_NAME(object_id) AS module_name, definition
FROM sys.sql_modules
WHERE definition LIKE '%ENCRYPTBYPASSPHRASE%';
-- Review: is the passphrase parameterised or hardcoded?
-- Short literals (< 16 chars) or dictionary words are high risk
```

**Fix options**
1. Migrate to AES_256 symmetric key: `CREATE SYMMETRIC KEY [DataKey] WITH ALGORITHM = AES_256, ENCRYPTION BY CERTIFICATE [cert]`; use `ENCRYPTBYKEY(KEY_GUID('DataKey'), plaintext)` instead
2. If `ENCRYPTBYPASSPHRASE` must be retained: use a 32+ char random passphrase stored in a secrets vault, never in T-SQL source; pass as a parameter from the application, not hardcoded
3. Re-encrypt all existing ENCRYPTBYPASSPHRASE data with the new symmetric key before removing the old function
4. Load `howto-agent-jobs.md` for patterns to avoid passphrase exposure

**Related checks:** A19 (password-only keys), A99/A100 (plan cache exposure), A17 (deprecated CLE algorithms)

---

### A109 — HASHBYTES using deprecated algorithm in security-sensitive context

**What it means**
`HASHBYTES` can use MD2, MD4, MD5, SHA (SHA-1), SHA1, SHA2_256, or SHA2_512. MD2/MD4/MD5 are cryptographically broken — collision attacks are practical (Flame malware used MD5 collisions to forge certificates in 2012). SHA-1 is deprecated by NIST with a 2030 sunset and is already excluded from TLS. Using these for password hashing, HMAC construction, data fingerprinting, or digital signatures provides no meaningful security guarantee.

**How to spot it**
```sql
SELECT OBJECT_NAME(object_id) AS module_name,
       SUBSTRING(definition, CHARINDEX('HASHBYTES', definition), 30) AS excerpt
FROM sys.sql_modules
WHERE definition LIKE '%HASHBYTES(''MD2''%'
   OR definition LIKE '%HASHBYTES(''MD4''%'
   OR definition LIKE '%HASHBYTES(''MD5''%'
   OR definition LIKE '%HASHBYTES(''SHA''%'  -- SHA-1 shorthand
   OR definition LIKE '%HASHBYTES(''SHA1''%';
```

**Fix options**
1. Replace with: `HASHBYTES('SHA2_256', @input)` or `HASHBYTES('SHA2_512', @input)`
2. For password storage: do NOT use any HASHBYTES — use application-layer bcrypt/Argon2; SQL Server has no built-in slow password-hashing function; HASHBYTES is intentionally fast (bad for passwords)
3. For data integrity/fingerprinting: `SHA2_256` is appropriate for SQL Server use cases
4. Update all stored hashes: existing MD5/SHA1 hashes must be recomputed with the new algorithm (requires re-processing the original data)

**Related checks:** A35 (cert SHA1 signature), A55 (FIPS algorithm audit), A108 (PBKDF1 weakness)

---

### A110 — Database Mail SMTP without modern authentication

**What it means**
Database Mail uses SMTP to send email notifications. If configured with username/password authentication (not Windows authentication), the SMTP credentials are stored in `msdb.dbo.sysmail_account`, encrypted only by the instance SMK — visible to any sysadmin via `SELECT` on MSDB. Without TLS (`enable_ssl = 0`), SMTP credentials are also transmitted in cleartext over the network during authentication.

**How to spot it**
```sql
SELECT a.name AS account_name, a.email_address, s.servername,
       s.port, s.enable_ssl, s.use_default_credentials,
       CASE WHEN s.credential_id IS NOT NULL THEN 'Password-based auth'
            ELSE 'No auth' END AS auth_type
FROM msdb.dbo.sysmail_account a
JOIN msdb.dbo.sysmail_server s ON a.account_id = s.account_id
WHERE s.enable_ssl = 0 OR s.use_default_credentials = 0;
```

**Fix options**
1. Enable TLS: `EXEC msdb.dbo.sysmail_update_account_sp @account_name = 'DBMail', @enable_ssl = 1`
2. Use Windows Authentication for SMTP relay (`use_default_credentials = 1`): avoids stored passwords entirely
3. SQL Server 2022 CU14+: configure OAuth2/modern auth app token via Azure AD for Office 365 SMTP
4. If SMTP credentials cannot be avoided: ensure `enable_ssl = 1` and rotate the password regularly (A103)

**Related checks:** A103 (credential rotation), A47 (SMK backup), A19 (password-only protection pattern)

---

### A111 — ENCRYPTBYCERT or DECRYPTBYCERT without cert expiry monitoring

**What it means**
Unlike TLS certificates, SQL Server does NOT enforce certificate expiry for `ENCRYPTBYCERT` and `DECRYPTBYCERT` operations. An expired certificate works fine for CLE encryption/decryption. The risk is silent security degradation: operators assume TLS certificate monitoring covers all certificates, but CLE certificates are separate objects with separate expiry dates that may not be monitored. An expired CLE certificate is a sign that key rotation procedures are not followed.

**How to spot it**
```sql
-- Find CLE usage modules and their referenced certificates
SELECT OBJECT_NAME(m.object_id) AS module_name,
       c.name AS cert_name, c.expiry_date,
       DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_to_expiry
FROM sys.sql_modules m
JOIN sys.certificates c ON m.definition LIKE '%ENCRYPTBYCERT(CERT_ID(''' + c.name + ''')%'
   OR m.definition LIKE '%DECRYPTBYCERT(CERT_ID(''' + c.name + ''')%'
WHERE c.expiry_date < DATEADD(DAY, 90, GETDATE());
```

**Fix options**
1. Add CLE cert monitoring to SQL Agent maintenance job: `SELECT name, expiry_date FROM sys.certificates WHERE expiry_date < DATEADD(DAY, 90, GETDATE()) AND name NOT LIKE '##%'`
2. Configure SQL Agent alerts via Database Mail when certs approach expiry
3. Rotate CLE certificates before expiry (see `howto-key-rotation.md`)
4. Separate TLS cert monitoring from CLE cert monitoring — they are different object types with different management cycles

**Related checks:** A4 (TDE cert expiry), A30 (TLS cert expiry), A33 (AG cert expiry), A35 (SHA1 cert)

---

### A112 — Azure SQL Managed Instance: managed identity missing AKV permissions for CMK

**What it means**
Azure SQL Managed Instance can use BYOK TDE — the TDE protector is an asymmetric key in Azure Key Vault, and the managed instance's managed identity (system-assigned or user-assigned) must have `wrapKey`, `unwrapKey`, and `get` permissions on the key. If these permissions are absent or expired (e.g., after rotating the managed identity or modifying AKV access policies), the TDE protector becomes inaccessible — databases fail to start, and geo-replication failover groups cannot activate.

**How to spot it**
```sql
-- On the Managed Instance: check ERRORLOG for TDE protector access errors
EXEC xp_readerrorlog 0, 1, N'TDE Protector';
EXEC xp_readerrorlog 0, 1, N'33111';  -- "Cannot find server certificate with thumbprint"
-- Azure Portal: Managed Instance → Transparent Data Encryption → shows "Key not accessible" status
```

```bash
# Azure CLI: verify managed identity AKV access
az keyvault show-permissions --name [vault-name] --query "properties.accessPolicies"
# Look for the MI object-id with wrapKey, unwrapKey, get permissions
```

**Fix options**
1. Key Vault access policy model: `az keyvault set-policy --name [vault] --object-id [mi-object-id] --key-permissions wrapKey unwrapKey get list`
2. Azure RBAC model: `az role assignment create --assignee [mi-object-id] --role "Key Vault Crypto Service Encryption User" --scope /subscriptions/[sub]/resourceGroups/[rg]/providers/Microsoft.KeyVault/vaults/[vault]`
3. After granting: verify TDE status returns to "Enabled" in Azure Portal
4. Include in MI deployment checklist: verify managed identity permissions after any AKV access policy rotation or MI re-provisioning

**Related checks:** A50 (BYOK rotation), A77 (key vault region), A101 (AKV soft-delete), A49 (EKM provider)
