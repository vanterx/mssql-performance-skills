---
name: sqlencryption-review
description: Analyze SQL Server encryption posture across all layers — TDE, Always Encrypted, cell-level encryption, backup encryption, transport/TLS, certificate lifecycle, asymmetric and symmetric key management, DMK/SMK key hierarchy, EKM/AKV integration, sensitivity-classification gaps, TLS and network hardening, Always Encrypted advanced (secure enclave attestation, driver compatibility), operational key lifecycle, SQL Server 2022 Ledger, Azure-specific encryption, and PCI-DSS/HIPAA/GDPR/SOX/ISO 27001 compliance. Applies 80 checks (A1–A80) across 15 categories. Use this skill when reviewing database security posture, preparing for a compliance audit, investigating a key exposure, or whenever output from sys.dm_database_encryption_keys, sys.certificates, sys.symmetric_keys, msdb.dbo.backupset, sys.dm_exec_connections, sys.ledger_*, or sys.sensitivity_classifications is pasted. Trigger for questions about TDE setup, Always Encrypted configuration, backup encryption, TLS enforcement, certificate rotation, key rotation, SQL Ledger verification, or crypto-shredding for GDPR.
triggers:
  - /sqlencryption-review
  - /encryption-review
  - /tde-review
  - /always-encrypted-review
  - /backup-encryption-review
  - /tls-review
  - /ledger-review
---

# SQL Server Encryption Review Skill

## Purpose

Audit the complete encryption posture of a SQL Server instance or database. Applies 80 checks (A1–A80) across 15 categories:

- **A1–A8** — Transparent Data Encryption (TDE): scan state, algorithm strength, certificate lifecycle, cross-database cert sharing risks
- **A9–A16** — Always Encrypted: encryption type selection, CEK algorithm, secure enclave availability, CMK store quality, sensitive-column coverage, key rotation
- **A17–A21** — Cell-Level Encryption (CLE): deprecated algorithms, open-key scope leaks, password-only key protection, rotation age, strategy conflicts
- **A22–A25** — Backup Encryption: unencrypted backups, certificate backup status, algorithm strength, certificate expiry
- **A26–A30** — Transport / Connection Encryption: ForceEncryption enforcement, unencrypted active sessions, self-signed TLS certificates, TrustServerCertificate bypass, TLS cert expiry
- **A31–A38** — Certificate Management: private key protection, Service Broker and AG endpoint certificates, certificate-based login permissions, signature hash algorithm, CA trust chain, backup strategy, duplicate subjects
- **A39–A43** — Asymmetric and Symmetric Key Management: RSA key length, over-permissioned keys, rotation age, orphaned keys, non-unique KEY_SOURCE
- **A44–A48** — Key Hierarchy (DMK / SMK): backup status, SMK protection layer, password-only risks, linked-server encryption
- **A49–A52** — EKM / Azure Key Vault: provider health, BYOK rotation policy, service-managed vs. customer-managed TDE, provider version
- **A53–A56** — Compliance and Coverage: sensitivity-classified columns without encryption, sensitive-pattern columns unprotected, non-FIPS algorithms, missing audit configuration
- **A57–A62** — TLS and Network Encryption Hardening: legacy TLS version audit, weak cipher detection, TLS 1.3 enforcement, IPsec as compensating control, Kerberos armoring, Named Pipes risk
- **A63–A67** — Always Encrypted Advanced: enclave attestation completeness, driver version compatibility, CEK caching configuration, enclave utilization, attestation protocol enforcement
- **A68–A72** — Operational Key Lifecycle: DMK/SMK password strength, certificate auto-enrollment, key archival/escrow procedures, TDE scan I/O baselining, log backup encryption
- **A73–A76** — SQL Server Ledger (SQL 2022+): database ledger enablement, digest storage configuration, hash algorithm strength, ledger verification scheduling
- **A77–A80** — Azure-Specific Encryption: TDE protector region placement, double encryption (infrastructure + TDE), enclave attestation provider isolation, audit log encryption at rest

For background on encryption concepts, algorithm comparisons, TLS versions, the SQL Server key hierarchy, and PCI-DSS / HIPAA / GDPR requirements, read `references/concepts.md`.

---

## Input

Accept any combination of the following. Apply all checks that are relevant to the data provided. When the user describes symptoms in natural language, apply checks based on the described state.

- Output from `sys.dm_database_encryption_keys` joined with `sys.databases` and `master.sys.certificates` — TDE checks
- Output from `sys.columns` joined with `sys.column_encryption_keys` and `sys.column_master_keys` — Always Encrypted checks
- Output from `sys.symmetric_keys`, `sys.asymmetric_keys`, `sys.certificates`, `sys.key_encryptions` — key management checks
- Output from `msdb.dbo.backupset` — backup encryption checks
- Output from `sys.dm_exec_connections` — transport encryption checks
- Output from `sys.sensitivity_classifications` — compliance coverage checks
- Output from `sys.cryptographic_providers` or `sys.dm_cryptographic_provider_properties` — EKM checks
- Output from `sys.endpoints` — Service Broker / AG endpoint checks
- Output from `sys.server_audits` and `sys.database_audit_specifications` — audit checks
- Output from `sys.ledger_*` DMVs — SQL Server 2022 Ledger checks (A73–A76)
- Output from `sys.dm_exec_connections` with connection attribute details — driver version checks (A64)
- Natural language description of encryption configuration or symptoms

### Recommended Capture Queries

```sql
-- 1. TDE status across all databases
SELECT
    d.name                          AS database_name,
    d.is_encrypted,
    dek.encryption_state,
    dek.encryption_state_desc,
    dek.percent_complete,
    dek.encryptor_type,
    dek.key_algorithm,
    dek.key_length,
    c.name                          AS certificate_name,
    c.expiry_date                   AS cert_expiry,
    c.pvt_key_encryption_type_desc
FROM sys.databases d
LEFT JOIN sys.dm_database_encryption_keys dek ON d.database_id = dek.database_id
LEFT JOIN master.sys.certificates c ON dek.encryptor_thumbprint = c.thumbprint
ORDER BY d.name;

-- 2. Always Encrypted column inventory
SELECT
    SCHEMA_NAME(t.schema_id)        AS schema_name,
    t.name                          AS table_name,
    c.name                          AS column_name,
    c.encryption_type,
    c.encryption_type_desc,
    c.encryption_algorithm_name,
    cek.name                        AS cek_name,
    cmk.name                        AS cmk_name,
    cmk.key_store_provider_name,
    cmk.key_path
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.column_encryption_keys cek ON c.column_encryption_key_id = cek.column_encryption_key_id
JOIN sys.column_master_keys cmk ON cek.column_master_key_id = cmk.column_master_key_id
WHERE c.column_encryption_key_id IS NOT NULL;

-- 3. CEK version history (rotation check)
SELECT
    cek.name                        AS cek_name,
    cek.create_date,
    cekv.column_master_key_id,
    cmk.name                        AS cmk_name,
    cekv.create_date                AS version_created
FROM sys.column_encryption_keys cek
JOIN sys.column_encryption_key_values cekv ON cek.column_encryption_key_id = cekv.column_encryption_key_id
JOIN sys.column_master_keys cmk ON cekv.column_master_key_id = cmk.column_master_key_id;

-- 4. Symmetric and asymmetric keys
SELECT
    name,
    symmetric_key_id                AS key_id,
    'SYMMETRIC'                     AS key_type,
    algorithm_desc,
    CAST(key_length AS VARCHAR(10)) AS key_length,
    create_date,
    modify_date,
    pvt_key_encryption_type_desc
FROM sys.symmetric_keys
WHERE name NOT LIKE '##%'
UNION ALL
SELECT
    name,
    asymmetric_key_id,
    'ASYMMETRIC',
    algorithm_desc,
    CAST(key_length AS VARCHAR(10)),
    create_date,
    modify_date,
    pvt_key_encryption_type_desc
FROM sys.asymmetric_keys
WHERE name NOT LIKE '##%';

-- 5. Certificates (all purposes)
SELECT
    name,
    certificate_id,
    pvt_key_encryption_type_desc,
    issuer_name,
    subject,
    start_date,
    expiry_date,
    DATEDIFF(DAY, GETDATE(), expiry_date) AS days_until_expiry,
    CERTPROPERTY(name, 'Algorithm')       AS sig_algorithm
FROM sys.certificates
WHERE name NOT LIKE '##%'
ORDER BY expiry_date;

-- 6. Backup encryption history (last 30 days)
SELECT TOP 30
    database_name,
    backup_start_date,
    backup_finish_date,
    type                            AS backup_type,
    key_algorithm,
    encryptor_type,
    encryptor_thumbprint
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -30, GETDATE())
ORDER BY backup_start_date DESC;

-- 7. Connection encryption status
SELECT
    encrypt_option,
    auth_scheme,
    COUNT(*)                        AS connection_count,
    SUM(CASE WHEN client_net_address NOT IN ('<local machine>', '127.0.0.1', '::1')
             THEN 1 ELSE 0 END)     AS remote_connections
FROM sys.dm_exec_connections
GROUP BY encrypt_option, auth_scheme;

-- 8. Key hierarchy: DMK protection status
SELECT
    d.name                          AS database_name,
    d.is_master_key_encrypted_by_server,
    sk.name                         AS dmk_name,
    sk.create_date,
    sk.modify_date
FROM sys.databases d
LEFT JOIN sys.symmetric_keys sk ON sk.name = N'##MS_DatabaseMasterKey##'
WHERE d.database_id = DB_ID();

-- 9. EKM providers
SELECT
    provider_id,
    name,
    dll_path,
    is_enabled,
    provider_version,
    sqlcrypt_version
FROM sys.cryptographic_providers;

-- 10. Sensitivity classifications
SELECT
    SCHEMA_NAME(t.schema_id)        AS schema_name,
    t.name                          AS table_name,
    c.name                          AS column_name,
    sc.information_type,
    sc.label,
    sc.rank_desc,
    c.column_encryption_key_id      AS ae_key_id
FROM sys.sensitivity_classifications sc
JOIN sys.objects t ON sc.major_id = t.object_id
JOIN sys.columns c ON sc.major_id = c.object_id AND sc.minor_id = c.column_id;

-- 11. Endpoints using certificate authentication
SELECT
    e.name                          AS endpoint_name,
    e.type_desc,
    e.connection_auth_desc,
    c.name                          AS certificate_name,
    c.expiry_date,
    DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_until_expiry
FROM sys.endpoints e
LEFT JOIN sys.certificates c ON e.certificate_id = c.certificate_id
WHERE e.connection_auth_desc LIKE '%CERTIFICATE%';
```

---

## How to Run

Walk A1–A80 in category order. Report every triggered finding — do not stop at the first match per category. For checks where the relevant DMV data is absent from the input, mark them as `NOT ASSESSED` rather than skipping silently. For checks where the data is partial (e.g., a description rather than DMV output), state your assumption explicitly before applying the check.

When multiple databases or instances are present in the input, run all applicable checks per database/instance and aggregate findings. Prioritize production databases for Critical and Warning findings.

For T-SQL source-level checks (A18, A19, A43), scan provided SQL modules in `sys.sql_modules` or pasted code; note any checks that could not be verified due to missing source code.

---

## Thresholds Reference

| Metric | Info | Warning | Critical |
|--------|------|---------|----------|
| Certificate / key days until expiry | — | < 90 days | Expired (≤ 0 days) |
| Key rotation age (symmetric / CEK) | — | > 365 days since last rotation | > 730 days |
| CMK rotation age | — | > 730 days | — |
| RSA asymmetric key length | — | RSA_1024 | RSA_512 |
| Unencrypted remote connections | 0 | > 0 | — |
| TDE DEK algorithm | AES_128 / AES_192 | — | TRIPLE_DES_3KEY / RC4 |
| Symmetric key algorithm (CLE) | AES_128 / AES_192 | DES / DESX / TRIPLE_DES | RC4 / RC2 |
| Backup encryption algorithm | AES_128 | TRIPLE_DES_3KEY | None (unencrypted) |
| Non-FIPS algorithm anywhere | — | SHA1 / DES / 3DES | RC4 / MD5 |

---

## Checks

## Transparent Data Encryption — A1–A8

### A1 — TDE not enabled on user database
- **Trigger:** `sys.databases` WHERE `is_encrypted = 0` AND `database_id > 4` (non-system database)
- **Severity:** Warning by default; Critical if database name contains any of: prod, finance, hr, payroll, customer, patient, medical, pii, gdpr, pci, hipaa
- **Fix:** In master DB, create a certificate and Database Encryption Key, then `ALTER DATABASE [db] SET ENCRYPTION ON`. Note: tempdb will encrypt automatically.

### A2 — TDE encryption scan in progress
- **Trigger:** `sys.dm_database_encryption_keys` WHERE `encryption_state IN (2, 4)` AND `percent_complete < 100`
- **Severity:** Info — the scan (encryption_state 2 = encrypting, 4 = decrypting) consumes additional I/O and CPU proportional to database size; on SQL 2019+ the scan can be suspended
- **Fix:** Monitor `percent_complete`; avoid heavy index rebuild or backup jobs during scan; on SQL 2019+, use `ALTER DATABASE [db] SET ENCRYPTION SUSPEND | RESUME` if I/O pressure is high

### A3 — TDE certificate not backed up
- **Trigger:** TDE-protector certificate present in `master.sys.certificates` but no evidence of a `BACKUP CERTIFICATE` operation (no corresponding file path documented, no SQL Agent job containing BACKUP CERTIFICATE)
- **Severity:** Critical — the TDE certificate is the only key capable of decrypting the Database Encryption Key; if it is lost with the instance, the database is permanently unrestorable even with an intact backup
- **Fix:** `BACKUP CERTIFICATE [tde_cert] TO FILE = 'path\tde_cert.cer' WITH PRIVATE KEY (FILE = 'path\tde_cert.pvk', ENCRYPTION BY PASSWORD = 'StrongPassword')` — store the .cer, .pvk, and password in separate secure, off-server locations

### A4 — TDE certificate expired or expiring within 90 days
- **Trigger:** `master.sys.certificates` WHERE cert thumbprint matches a `sys.dm_database_encryption_keys.encryptor_thumbprint` AND `DATEDIFF(DAY, GETDATE(), expiry_date) < 90`
- **Severity:** Critical if `expiry_date < GETDATE()`; Warning if within 90 days
- **Fix:** Create new certificate: `CREATE CERTIFICATE [tde_cert_new] WITH EXPIRY_DATE = '20270101'`; re-key DEK: `ALTER DATABASE [db] ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE [tde_cert_new]`; keep old cert until all backups protected by it have been superseded

### A5 — TDE DEK using non-AES_256 algorithm
- **Trigger:** `sys.dm_database_encryption_keys` WHERE `key_algorithm != 'AES_256'` — specifically TRIPLE_DES_3KEY or AES_128/AES_192
- **Severity:** Critical for TRIPLE_DES_3KEY (NIST SP 800-131A deprecated 3DES after 2023); Warning for AES_128 / AES_192 (acceptable but AES_256 is preferred for PCI-DSS and FIPS compliance)
- **Fix:** `ALTER DATABASE [db] ENCRYPTION KEY REGENERATE WITH ALGORITHM = AES_256` — triggers a re-encryption scan; plan for I/O impact

### A6 — Multiple databases sharing the same TDE certificate
- **Trigger:** `sys.dm_database_encryption_keys` GROUP BY `encryptor_thumbprint` HAVING COUNT(*) > 1
- **Severity:** Warning — a single certificate compromise or rotation event affects all databases simultaneously; a failed rotation leaves all covered databases in a degraded state
- **Fix:** Issue a dedicated TDE certificate per database or per environment tier (prod, staging); use a consistent naming convention: `TDE_[dbname]_[year]`

### A7 — TDE enabled on master, model, or msdb
- **Trigger:** `sys.dm_database_encryption_keys` WHERE `database_id IN (1, 2, 3)` (master, model, msdb — tempdb at database_id 2 is acceptable and expected)
- **Severity:** Info — explicitly encrypting master or model can complicate bare-metal restores, Dedicated Admin Connection (DAC) access, and AG seed operations; tempdb encryption is expected when any user DB is TDE-enabled
- **Fix:** Confirm intent; if inadvertent, `ALTER DATABASE master SET ENCRYPTION OFF`; verify that AG seeding, RESTORE DATABASE, and DAC connections still function after change

### A8 — tempdb encrypted but no user database is encrypted
- **Trigger:** `sys.databases` WHERE `name = 'tempdb'` AND `is_encrypted = 1` AND COUNT of user databases (`database_id > 4`) with `is_encrypted = 1` = 0
- **Severity:** Warning — tempdb encryption is a residual artifact of a TDE-enabled database that was since dropped or decrypted; it adds I/O overhead with no data-protection benefit
- **Fix:** Disable TDE on the last remaining user database (if that is the intended state); tempdb will automatically drop its encryption; verify `sys.databases` shows `is_encrypted = 0` for tempdb after restart

---

## Always Encrypted — A9–A16

### A9 — Deterministic encryption on non-searchable columns
- **Trigger:** `sys.columns` WHERE `encryption_type = 1` (DETERMINISTIC) AND column name does not suggest a join key or lookup field (no `_id`, `_key`, `_code`, `_number` suffix pattern)
- **Severity:** Info — deterministic encryption preserves equality-comparison semantics but leaks frequency distribution patterns; randomized encryption (type 2) is preferable for columns that are never queried with WHERE or JOIN
- **Fix:** Re-encrypt privacy-only columns (e.g., middle name, notes) with RANDOMIZED type using SSMS Always Encrypted wizard or PowerShell `Set-SqlColumnEncryption`

### A10 — Randomized encryption where equality queries are needed, no secure enclave configured
- **Trigger:** `sys.columns` WHERE `encryption_type = 2` (RANDOMIZED) AND `sys.configurations` WHERE `name = 'column encryption enclave type'` returns 0 (no enclave)
- **Severity:** Warning — applications attempting WHERE or JOIN on randomized-encrypted columns will receive "Operand type clash" errors at runtime; this is a functional defect, not merely a security concern
- **Fix:** Either (a) switch the column to DETERMINISTIC if only equality comparisons are needed, or (b) enable a secure enclave on SQL 2019+ (`sp_configure 'column encryption enclave type', 1`) and configure VBS enclave attestation on the client

### A11 — Column encryption algorithm is not AEAD_AES_256_CBC_HMAC_SHA_256
- **Trigger:** `sys.columns` WHERE `column_encryption_key_id IS NOT NULL` AND `encryption_algorithm_name != 'AEAD_AES_256_CBC_HMAC_SHA_256'`
- **Severity:** Warning — the standard AE algorithm provides authenticated encryption (prevents ciphertext manipulation); non-standard algorithms may lack authentication or use weaker primitives
- **Fix:** Re-encrypt the column specifying `ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'` in the column definition; coordinate with application teams for driver updates if needed

### A12 — Secure enclave not configured for range or pattern queries (SQL 2019+)
- **Trigger:** SQL Server 2019 or later AND `sys.configurations` WHERE `name = 'column encryption enclave type'` = 0 AND randomized-encrypted columns exist in the database
- **Severity:** Info — the server supports secure enclaves but they are not enabled; range comparisons (`BETWEEN`, `<`, `>`) and `LIKE` on AE columns are currently impossible
- **Fix:** `EXEC sp_configure 'column encryption enclave type', 1; RECONFIGURE` — requires Windows Server 2019+ with Virtualization Based Security or Intel SGX hardware; configure attestation service URL in client connection string

### A13 — Column Master Key stored in Windows Certificate Store (not HSM or AKV)
- **Trigger:** `sys.column_master_keys` WHERE `key_store_provider_name = 'MSSQL_CERTIFICATE_STORE'`
- **Severity:** Warning — Windows certificate store certificates are machine-exportable; without additional protections (CNG key storage providers, TPM-backed certificates) the private key can be extracted from the machine; no hardware tamper resistance
- **Fix:** Migrate CMK to Azure Key Vault (`key_store_provider_name = 'AZURE_KEY_VAULT'`) or a FIPS 140-2 Level 3 HSM; generate new CMK in the new store, re-encrypt CEKs under the new CMK, then drop the old CMK

### A14 — Sensitive-pattern column names without Always Encrypted protection
- **Trigger:** `sys.columns` WHERE name matches any of `%ssn%`, `%social_sec%`, `%credit_card%`, `%card_num%`, `%cvv%`, `%cvc%`, `%password%`, `%passwd%`, `%\bpin\b%`, `%dob%`, `%date_of_birth%`, `%salary%`, `%tax_id%`, `%passport%`, `%national_id%`, `%medical_record%`, `%diagnosis%`, `%account_number%` — AND `column_encryption_key_id IS NULL`
- **Severity:** Warning — strong indicator of PII/PCI/PHI columns without encryption; likely non-compliant with PCI-DSS Requirement 3.4, HIPAA 45 CFR §164.312, or GDPR Article 32
- **Fix:** Confirm column contents with data owner; apply Always Encrypted for columns requiring client-side key control, or CLE for simpler needs; add `sys.sensitivity_classifications` label after encrypting

### A15 — No CEK rotation ever performed
- **Trigger:** `sys.column_encryption_key_values` WHERE for a given `column_encryption_key_id` there is only one record (single CMK version, never rotated) AND `sys.column_encryption_keys.create_date < DATEADD(YEAR, -1, GETDATE())`
- **Severity:** Info — annual key rotation limits the exposure window if a CEK or its protecting CMK is ever compromised; a single-version CEK that is more than a year old has not been rotated
- **Fix:** `ALTER COLUMN ENCRYPTION KEY [cek] ADD VALUE (COLUMN_MASTER_KEY = [new_cmk], ALGORITHM = 'RSA_OAEP', ENCRYPTED_VALUE = 0x...)` — use SSMS wizard to automate CEK re-encryption; then `DROP VALUE` for the old CMK version

### A16 — Column Master Key not rotated in over 2 years
- **Trigger:** `sys.column_master_keys` WHERE `create_date < DATEADD(YEAR, -2, GETDATE())` AND no newer CMK with the same logical name pattern exists
- **Severity:** Warning — CMKs protect all CEKs for a database; a 2-year-old CMK is overdue for rotation by most security policy standards
- **Fix:** Use SSMS Always Encrypted wizard → Rotate Column Master Key, or PowerShell `Invoke-SqlColumnMasterKeyRotation -InputObject $db -SourceColumnMasterKeyName [old_cmk] -TargetColumnMasterKeyName [new_cmk]`; distribute new CMK to all application servers before completing rotation

---

## Cell-Level Encryption — A17–A21

### A17 — Symmetric key using deprecated or broken algorithm
- **Trigger:** `sys.symmetric_keys` WHERE `algorithm_desc IN ('DES', 'TRIPLE_DES', 'RC2', 'RC4', 'DESX', 'TRIPLE_DES_3KEY')` AND `name NOT LIKE '##%'`
- **Severity:** Critical for RC4 and RC2 (cryptographically broken; trivially decryptable); Warning for DES/DESX (56-bit key, brute-forceable); Warning for TRIPLE_DES / TRIPLE_DES_3KEY (deprecated post-2023 per NIST SP 800-131A)
- **Fix:** `CREATE SYMMETRIC KEY [key_new] WITH ALGORITHM = AES_256, KEY_SOURCE = '...', IDENTITY_VALUE = '...', ENCRYPTION BY CERTIFICATE [cert]`; re-encrypt all data with `ENCRYPTBYKEY(KEY_GUID('[key_new]'), plaintext)`; close and `DROP SYMMETRIC KEY [key_old]`

### A18 — OPEN SYMMETRIC KEY without matching CLOSE in the same scope
- **Trigger:** T-SQL source (stored procedures, functions) containing `OPEN SYMMETRIC KEY` with no `CLOSE SYMMETRIC KEY` or `CLOSE ALL SYMMETRIC KEYS` before the end of the batch; OR `sys.openkeys` showing keys open across long-running or idle sessions
- **Severity:** Warning — an open symmetric key persists for the lifetime of the session; any code running in that session can call `DECRYPTBYKEY()` without re-opening; connection pool reuse means keys may be open in unexpected contexts
- **Fix:** Add `CLOSE SYMMETRIC KEY [key_name]` after every use; add a CATCH block that also closes the key on error; add `CLOSE ALL SYMMETRIC KEYS` as a session cleanup safeguard in session-level error handlers

### A19 — Symmetric key protected by password only
- **Trigger:** `sys.key_encryptions` WHERE `crypt_type_desc = 'ENCRYPTION_BY_PASSWORD'` AND the same `key_id` does NOT also appear in a row with `crypt_type_desc IN ('ENCRYPTION_BY_CERT', 'ENCRYPTION_BY_ASYMMETRIC_KEY')`
- **Severity:** Warning — the password must be embedded in T-SQL scripts or agent jobs to open the key; passwords can appear in plan cache text, SQL Agent job step history, and memory dumps; certificate-based protection integrates cleanly with the key hierarchy and never requires a password at runtime
- **Fix:** `ALTER SYMMETRIC KEY [key] ADD ENCRYPTION BY CERTIFICATE [cert]` — then test the OPEN statement without the password parameter — then `ALTER SYMMETRIC KEY [key] DROP ENCRYPTION BY PASSWORD = 'old_password'`

### A20 — Symmetric key never rotated (age over 365 days)
- **Trigger:** `sys.symmetric_keys` WHERE `modify_date = create_date` AND `create_date < DATEADD(DAY, -365, GETDATE())` AND `name NOT LIKE '##%'`
- **Severity:** Info for 1–2 years; Warning for over 2 years — a static CLE key that has never been rotated maximizes the exposure window for any key material that might have leaked through logs, backups, or memory
- **Fix:** Create replacement key; re-encrypt data in batches; schedule rotation as a SQL Agent job; document the rotation interval in the key's naming convention (e.g., `CLE_CustomerSSN_2025`)

### A21 — Both CLE and Always Encrypted applied to the same table
- **Trigger:** Table contains columns with `column_encryption_key_id IS NOT NULL` (Always Encrypted) AND `sys.sql_modules.definition` contains `ENCRYPTBYKEY` or `DECRYPTBYKEY` calls referencing the same table
- **Severity:** Warning — double-encryption adds latency on every read and write; the application must handle two decryption code paths; CLE decryption happens server-side (defeating AE's client-side key control guarantee)
- **Fix:** Standardize on Always Encrypted for column-level encryption across the table; remove CLE functions from stored procedures; test the application layer after removing CLE

---

## Backup Encryption — A22–A25

### A22 — Recent backups not encrypted
- **Trigger:** `msdb.dbo.backupset` WHERE `backup_start_date > DATEADD(DAY, -30, GETDATE())` AND `key_algorithm IS NULL` (no encryption) — for database_name matching production databases
- **Severity:** Critical — an unencrypted full backup is a complete copy of the database accessible to anyone with access to the backup media or storage location; encryption at rest on storage is not a substitute for backup-level encryption
- **Fix:** Add `WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [backup_cert])` to all BACKUP DATABASE and BACKUP LOG statements; create the backup certificate in master DB first; update Ola Hallengren or native maintenance plan scripts

### A23 — Backup encryption certificate not separately backed up
- **Trigger:** Encrypted backups exist (`msdb.dbo.backupset.key_algorithm IS NOT NULL`) AND no `BACKUP CERTIFICATE` evidence for the referenced certificate
- **Severity:** Critical — if the SQL Server instance is lost (disk failure, OS corruption, ransomware) and the backup encryption certificate is not saved separately, all encrypted backup files become permanently irrecoverable regardless of how many copies exist
- **Fix:** `BACKUP CERTIFICATE [backup_cert] TO FILE = 'D:\CertBackups\backup_cert.cer' WITH PRIVATE KEY (FILE = 'D:\CertBackups\backup_cert.pvk', ENCRYPTION BY PASSWORD = 'VaultStoredPassword')` — keep the .cer, .pvk, and password in separate, geographically distributed secure storage

### A24 — Backup encryption using TRIPLE_DES_3KEY or AES_128
- **Trigger:** `msdb.dbo.backupset` WHERE `key_algorithm IN ('TRIPLE_DES_3KEY', 'AES_128')` AND `backup_start_date > DATEADD(DAY, -30, GETDATE())`
- **Severity:** Warning — TRIPLE_DES_3KEY is deprecated (NIST 800-131A); AES_128 is acceptable but AES_256 is required for PCI-DSS v4 and recommended for HIPAA/GDPR workloads
- **Fix:** Update backup scripts to `ALGORITHM = AES_256`; existing backups retain their original algorithm (still restorable); change affects only new backups going forward

### A25 — Backup encryption certificate expiring within 90 days
- **Trigger:** Certificate referenced by `msdb.dbo.backupset.encryptor_thumbprint` with `DATEDIFF(DAY, GETDATE(), expiry_date) < 90`
- **Severity:** Critical if already expired; Warning if < 90 days — note: an expired TDE certificate does NOT prevent restoring backups encrypted by that certificate; however the same certificate is often used for both TDE and backup encryption, so expired certs must be tracked
- **Fix:** Create new backup certificate; update backup scripts to use new cert; maintain old cert for restoring pre-rotation backups; document the cert-to-backup-date mapping

---

## Transport and Connection Encryption — A26–A30

### A26 — ForceEncryption not enabled at server level
- **Trigger:** `sys.dm_server_registry` WHERE `registry_key LIKE N'%SuperSocketNetLib%'` AND `value_name = N'Encrypt'` AND `value_data = 0`; or no TLS certificate configured in SQL Server Configuration Manager
- **Severity:** Warning — without ForceEncryption, any client that connects with `Encrypt=False` (which was the default in drivers before ODBC 18 / JDBC 12 / .NET 7) establishes a plaintext session; credentials and query results travel in clear text over the network
- **Fix:** SQL Server Configuration Manager → SQL Server Network Configuration → Protocols for [Instance] → Properties → Certificate tab (bind a CA-signed cert) → Flags tab → Force Encryption = Yes; restart the SQL Server service

### A27 — Active remote connections using no TLS encryption
- **Trigger:** `sys.dm_exec_connections` WHERE `encrypt_option = 'FALSE'` AND `client_net_address NOT IN ('<local machine>', '127.0.0.1', '::1', '<named pipe>')`
- **Severity:** Warning — live remote sessions expose authentication credentials and all result-set data to network packet capture; this is an active security defect, not a configuration recommendation
- **Fix:** Enable ForceEncryption (A26); audit application connection strings for `Encrypt=True`; for interim mitigation, use IPsec between application servers and the SQL Server host

### A28 — SQL Server TLS certificate is self-signed
- **Trigger:** SQL Server ERRORLOG at last startup contains "A self-generated certificate was successfully loaded for encryption"; or the certificate configured in SQL Server Configuration Manager has `issuer_name = subject`
- **Severity:** Info for development/test; Warning for production — self-signed certs cannot be chain-validated by clients; connecting clients must set `TrustServerCertificate=True`, which disables all certificate validation and opens a man-in-the-middle vector
- **Fix:** Obtain a certificate from an internal CA (ADCS) or public CA (DigiCert, Let's Encrypt enterprise); install in Local Machine → Personal store; bind in SQL Server Configuration Manager → Certificates; restart SQL Server

### A29 — TrustServerCertificate=TRUE detected in connection attributes
- **Trigger:** Extended Events session on `sql_batch_starting` or `rpc_starting` captures session attribute `trust_server_certificate = 1`; or connection string audit reveals `TrustServerCertificate=True` in application configuration files
- **Severity:** Warning — TrustServerCertificate=True instructs the driver to skip the entire certificate chain validation; a network attacker can intercept the TLS handshake and present any certificate without detection
- **Fix:** Deploy a valid CA-signed TLS certificate on the SQL Server (A28 fix); then remove `TrustServerCertificate=True` from all production connection strings; test each application after the change

### A30 — SQL Server TLS authentication certificate expiring within 90 days
- **Trigger:** The certificate bound to SQL Server for TLS (identified from ERRORLOG "The certificate [thumbprint] will expire" message or SQL Server Configuration Manager) expires within 90 days
- **Severity:** Critical if expired — SQL Server falls back to a self-generated certificate, which will cause connection failures for clients that do not have TrustServerCertificate=True; Warning if within 90 days
- **Fix:** Renew the certificate from the issuing CA; install renewed cert in Windows cert store; rebind in SQL Server Configuration Manager → Certificates tab; restart SQL Server; verify ERRORLOG confirms the new cert is loaded

---

## Certificate Management — A31–A38

### A31 — Certificate private key not protected by DMK
- **Trigger:** `sys.certificates` WHERE `pvt_key_encryption_type_desc = 'ENCRYPTED_BY_PASSWORD'` (password-only, DMK not used) OR `pvt_key_encryption_type_desc = 'NO_PRIVATE_KEY'` (key was stripped or never imported)
- **Severity:** Warning for password-only (password must appear in T-SQL code to use the cert at runtime); Critical for NO_PRIVATE_KEY (cert cannot sign or decrypt — effectively a public-key-only stub, useless for TDE/CLE/Service Broker)
- **Fix:** For password-only: `ALTER CERTIFICATE [cert] WITH PRIVATE KEY (DECRYPTION BY PASSWORD = 'old_pwd', ENCRYPTION BY DATABASE MASTER KEY)` — verify the DMK exists and is open; for missing private key, restore cert from BACKUP CERTIFICATE output

### A32 — Service Broker endpoint certificate not rotated in over 2 years
- **Trigger:** `sys.endpoints` WHERE `type_desc = 'SERVICE_BROKER'` AND `connection_auth_desc = 'CERTIFICATE'` joined to `sys.certificates` WHERE `create_date < DATEADD(YEAR, -2, GETDATE())`
- **Severity:** Info — Service Broker authentication certificates are long-lived but should be rotated to limit exposure; rotation requires coordination on both sides of each service binding
- **Fix:** Create new certificate; export and import it to the remote database; update `sys.remote_service_bindings` at the remote end; update the local endpoint: `ALTER ENDPOINT [sb_endpoint] FOR SERVICE_BROKER (AUTHENTICATION = CERTIFICATE [new_cert])`; test message flow before dropping old cert

### A33 — Always On AG endpoint certificate expiring within 90 days
- **Trigger:** `sys.endpoints` WHERE `type_desc = 'DATABASE_MIRRORING'` (used for AG) AND `connection_auth_desc LIKE '%CERTIFICATE%'` joined to `sys.certificates` WHERE `DATEDIFF(DAY, GETDATE(), expiry_date) < 90`
- **Severity:** Critical — when the AG endpoint certificate expires, replicas disconnect from the primary; data movement halts; if the primary then fails, failover to a synchronized secondary may not be possible
- **Fix:** Create new cert on primary; export to all secondary replicas via `CREATE CERTIFICATE … FROM FILE`; update endpoint on each replica: `ALTER ENDPOINT [hadr_endpoint] FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE [new_cert])`; verify replica states with `SELECT * FROM sys.dm_hadr_availability_replica_states`

### A34 — Certificate-based login mapped to sysadmin or elevated fixed role
- **Trigger:** `sys.server_principals` WHERE `type = 'C'` (certificate login) JOIN `sys.server_role_members` WHERE `role_principal_id IN (SELECT principal_id FROM sys.server_principals WHERE name IN ('sysadmin', 'securityadmin', 'processadmin', 'dbcreator'))`
- **Severity:** Critical — a certificate-mapped login with sysadmin means that any process that can sign a T-SQL batch with the certificate's private key has full server control; certificate-based logins are intended for code-signing, not elevated interactive access
- **Fix:** Remove the certificate login from elevated fixed server roles; grant only the specific permissions needed (e.g., `GRANT EXECUTE ON [schema].[proc] TO [cert_login]`); consider using `EXECUTE AS` within the signed procedure instead of elevating the cert login itself

### A35 — Certificate signed with MD5 or SHA1 signature hash
- **Trigger:** `CERTPROPERTY(name, 'Algorithm')` returns `'MD5'` or `'SHA1'` for any certificate in `sys.certificates WHERE name NOT LIKE '##%'`
- **Severity:** Critical for MD5 (collision attacks demonstrated in practice since 2004; do not use for any purpose); Warning for SHA1 (deprecated by NIST and Microsoft since 2016; CABrowser Forum banned SHA1 cert issuance)
- **Fix:** Re-issue all affected certificates using SHA256 or SHA384 signature algorithm; SQL Server's `CREATE CERTIFICATE` uses SHA1 by default on older instances — explicitly specify a stronger algorithm in newer versions or generate via OpenSSL/certreq with `SignatureAlgorithm = sha256RSA`

### A36 — Production certificate issued by self-signed or untrusted CA
- **Trigger:** `sys.certificates` WHERE `issuer_name = subject` (self-signed) AND the certificate is referenced by an endpoint, linked server, or backup job in a production context
- **Severity:** Warning — self-signed certificates provide encryption but not authentication; the communicating party cannot verify the identity of the certificate holder; MitM attacks are undetectable with self-signed certs
- **Fix:** Request a certificate from a trusted internal CA (Microsoft AD CS) or public CA; distribute the CA root certificate to all client machines' Trusted Root Certification Authorities store; remove reliance on TrustServerCertificate bypass after rotation

### A37 — No BACKUP CERTIFICATE evidence for certificates with private keys
- **Trigger:** `sys.certificates` WHERE `pvt_key_encryption_type_desc NOT IN ('NO_PRIVATE_KEY')` (certificate has a private key) AND no `BACKUP CERTIFICATE` operation documented in SQL Agent job history or maintenance scripts
- **Severity:** Critical — in the event of instance loss (OS corruption, disk failure, ransomware), all data encrypted or signed by these certificates becomes permanently inaccessible without the backed-up private key
- **Fix:** For each certificate: `BACKUP CERTIFICATE [cert] TO FILE = '…' WITH PRIVATE KEY (FILE = '…', ENCRYPTION BY PASSWORD = '…')`; store the .cer file, .pvk file, and password in separate physical locations; document the restore procedure and test it

### A38 — Multiple certificates sharing the same Subject/CN
- **Trigger:** `sys.certificates` GROUP BY `subject` HAVING COUNT(*) > 1 WHERE `name NOT LIKE '##%'`
- **Severity:** Warning — when two certificates share the same subject, T-SQL code referencing the certificate by subject (rather than by name) may select the wrong one; rotation procedures become error-prone; `CREATE CERTIFICATE … FROM FILE` during disaster recovery may create additional duplicates
- **Fix:** Retire or rename duplicates; adopt a naming standard that incorporates purpose, environment, and year (e.g., `TDE_ProductionDB_2025`); include the subject in the cert name to keep them unique

---

## Asymmetric and Symmetric Key Management — A39–A43

### A39 — Asymmetric key using RSA_512 or RSA_1024
- **Trigger:** `sys.asymmetric_keys` WHERE `key_length IN (512, 1024)` AND `name NOT LIKE '##%'`
- **Severity:** Critical for RSA_512 (factorable with modest computational resources as demonstrated by researchers); Warning for RSA_1024 (NIST SP 800-131A prohibited RSA_1024 after 2013 for government use; CAs stopped issuing 1024-bit certs in 2013)
- **Fix:** `CREATE ASYMMETRIC KEY [new_key] WITH ALGORITHM = RSA_2048`; re-encrypt any symmetric keys protected by the old asymmetric key: `ALTER SYMMETRIC KEY [sk] ADD ENCRYPTION BY ASYMMETRIC KEY [new_key]; ALTER SYMMETRIC KEY [sk] DROP ENCRYPTION BY ASYMMETRIC KEY [old_key]`; then `DROP ASYMMETRIC KEY [old_key]`

### A40 — CONTROL permission on an encryption key granted to a non-sysadmin principal
- **Trigger:** `sys.database_permissions` WHERE `class_desc IN ('SYMMETRIC_KEY', 'ASYMMETRIC_KEY')` AND `permission_name = 'CONTROL'` AND `grantee_principal_id NOT IN` (list of sysadmin-mapped users in the database)
- **Severity:** Warning — CONTROL on a symmetric key grants the ability to drop, alter, and (through key-open) access all data encrypted by that key; for asymmetric keys, CONTROL allows re-signing and potentially deriving key material
- **Fix:** Replace CONTROL with purpose-specific permissions: `REFERENCES` for Always Encrypted CMK metadata access; `ENCRYPT` + `DECRYPT` for CLE operations; `EXECUTE` for stored procedures that wrap the key operations; revoke CONTROL

### A41 — Symmetric key not rotated in over 2 years
- **Trigger:** `sys.symmetric_keys` WHERE `modify_date = create_date` AND `create_date < DATEADD(YEAR, -2, GETDATE())` AND `name NOT LIKE '##%'`
- **Severity:** Warning — a symmetric CLE key that has never been rotated since creation presents an extended exposure window; PCI-DSS Requirement 3.7.3 requires cryptographic key changes at least once per year for keys protecting cardholder data
- **Fix:** Create replacement key with updated name and AES_256; re-encrypt data in manageable batches during low-activity window; close and `DROP SYMMETRIC KEY [old_key]` after verifying all dependent data has been re-encrypted

### A42 — Orphaned encryption keys not referenced in any module
- **Trigger:** Key `name` from `sys.symmetric_keys` or `sys.asymmetric_keys` (excluding `##%` system keys) does not appear in any `sys.sql_modules.definition` or `sys.server_sql_modules.definition` — no ENCRYPTBYKEY, DECRYPTBYKEY, SIGNBYASYMKEY, or VERIFYBYASYMKEY calls referencing the key
- **Severity:** Info — orphaned keys are unused attack surface; they are common residue from retired applications, failed migrations, or test databases promoted to production
- **Fix:** Confirm with application owners that the key is truly unused across all environments and application versions; `DROP SYMMETRIC KEY [key]` or `DROP ASYMMETRIC KEY [key]` after verification; scan application source code in addition to SQL modules

### A43 — Non-unique or weak KEY_SOURCE in symmetric key definition
- **Trigger:** T-SQL source containing `KEY_SOURCE = 'password'`, `KEY_SOURCE = 'test'`, or any KEY_SOURCE that is identical across multiple environments (detected via code review, git history, or duplicate key GUIDs visible across database clones)
- **Severity:** Warning — the KEY_SOURCE parameter is incorporated into the key derivation function; a non-unique KEY_SOURCE means identical symmetric keys are generated in different databases/environments, allowing dev-encrypted data to be decrypted with the prod key
- **Fix:** Generate a unique random string per database per environment as KEY_SOURCE: `SELECT CONVERT(VARCHAR(36), NEWID()) AS unique_source`; never reuse KEY_SOURCE across environments; treat KEY_SOURCE as a secret equal in sensitivity to the key itself

---

## Key Hierarchy DMK and SMK — A44–A48

### A44 — Database Master Key not backed up
- **Trigger:** `sys.symmetric_keys` WHERE `name = '##MS_DatabaseMasterKey##'` exists (DMK is present) AND no `BACKUP MASTER KEY` evidence in SQL Agent job history or maintenance documentation
- **Severity:** Critical — the DMK is the root protector for all certificates, asymmetric keys, and symmetric keys in the database; losing the DMK without a backup means permanent loss of access to all dependent encrypted data across every table that uses CLE
- **Fix:** `BACKUP MASTER KEY TO FILE = 'D:\Keys\[dbname]_master_key.mk' ENCRYPTION BY PASSWORD = 'VaultStoredPassword'` — store the .mk file and password in separate secure locations; incorporate into disaster recovery runbook

### A45 — DMK not encrypted by the Service Master Key
- **Trigger:** `SELECT is_master_key_encrypted_by_server FROM sys.databases WHERE name = DB_NAME()` returns 0
- **Severity:** Warning — the SMK provides automatic DMK decryption at SQL Server service startup; without SMK encryption, every restart that needs the DMK requires a manual `OPEN MASTER KEY DECRYPTION BY PASSWORD = '...'` call before any encrypted objects are accessible; this causes application errors until the DBA intervenes
- **Fix:** `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY` — requires that the DMK is currently open or the password is provided; verify with `SELECT is_master_key_encrypted_by_server FROM sys.databases WHERE name = DB_NAME()` = 1

### A46 — DMK protected by password only (no automatic decryption)
- **Trigger:** Same as A45 — `is_master_key_encrypted_by_server = 0` AND no other protection method layered on the DMK
- **Severity:** Warning — a lost or forgotten DMK password with no SMK backup means the entire CLE key hierarchy for the database becomes permanently inaccessible; the password must be stored securely and documented in the recovery runbook
- **Fix:** Same as A45: `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY` to add automatic decryption; separately back up the DMK (A44) so the password provides a recovery path even after instance migration

### A47 — Service Master Key never explicitly backed up
- **Trigger:** No evidence of `BACKUP SERVICE MASTER KEY` in any SQL Agent job or maintenance script; the SMK is the root of the entire instance-level key hierarchy (protects all DMKs, linked-server passwords, and proxy account credentials)
- **Severity:** Critical — if the SQL Server instance is migrated to new hardware, rebuilt after OS failure, or the machine key is damaged (e.g., from Windows re-imaging without preserving DPAPI), all SMK-protected objects become inaccessible on the new instance without an SMK backup
- **Fix:** `BACKUP SERVICE MASTER KEY TO FILE = 'D:\Keys\smk_[hostname]_[date].smk' ENCRYPTION BY PASSWORD = 'VaultStoredPassword'` — run once after SQL Server installation and again after any SMK regeneration; store file and password in separate secure locations outside the SQL Server machine

### A48 — Linked server connections not using TLS encryption
- **Trigger:** `sys.servers` WHERE `is_linked = 1` AND server is on a different host (different from `@@SERVERNAME`) AND the provider string in `sys.linked_logins` or SSMS Linked Server properties does not include `Encrypt=yes` or `Use Encryption for Data=True`
- **Severity:** Warning — distributed queries, OPENQUERY, and four-part name queries over linked servers traverse the network as plaintext if the connection is not encrypted; linked server credentials are also visible during session setup
- **Fix:** Drop and re-create the linked server with encryption in the provider string: `EXEC sp_addlinkedserver @server = N'RemoteSrv', @srvproduct = N'SQL Server', @provider = N'SQLNCLI11', @provstr = N'Encrypt=yes;TrustServerCertificate=no'` — ensure the remote SQL Server has a valid CA-signed TLS cert

---

## EKM and Azure Key Vault Integration — A49–A52

### A49 — EKM provider installed but inactive or in error state
- **Trigger:** `sys.cryptographic_providers` WHERE `is_enabled = 0`; OR `sys.dm_cryptographic_provider_properties` WHERE the provider is in an error, not_connected, or degraded state
- **Severity:** Critical if TDE or any symmetric key uses this EKM provider — an inactive provider causes "Cannot find server certificate" or "The EKM provider key is not found" errors that prevent database startup or decryption
- **Fix:** Verify provider DLL path is accessible: `sys.cryptographic_providers.dll_path`; ensure `EKM provider enabled = 1` in `sys.configurations`; restart the EKM provider service; consult vendor documentation for the specific error code; test with `OPEN SYMMETRIC KEY` using the EKM key

### A50 — Azure Key Vault BYOK TDE without automatic key rotation configured
- **Trigger:** TDE configured with AKV asymmetric key (`sys.dm_database_encryption_keys.encryptor_type = 'ASYMMETRIC_KEY'`) AND no Azure Automation runbook, AKV rotation policy, or SQL Agent job configured to detect key version changes and update the TDE protector
- **Severity:** Warning — BYOK TDE provides customer control over the encryption key but requires active management; a key that is not rotated for years undermines compliance posture and increases the impact of a key store compromise
- **Fix:** Set an expiry date and rotation policy on the AKV key via `az keyvault key set-attributes --name [key] --vault-name [vault] --expires [date]`; configure Azure Monitor alerts on key expiry; use `Set-AzSqlServerTransparentDataEncryptionProtector` to re-point TDE to the new key version

### A51 — TDE using service-managed key in a compliance-regulated Azure SQL environment
- **Trigger:** Azure SQL Database WHERE the TDE protector type is service-managed (Azure default) AND the database resource tags or naming convention suggest PCI, HIPAA, FedRAMP, ISO 27001, or SOC 2 workloads
- **Severity:** Info — service-managed TDE is cryptographically sound (AES-256); however several compliance frameworks (PCI-DSS Requirement 3.6, HIPAA addressable safeguard for key management, FedRAMP HIGH) require customer-managed keys to demonstrate key lifecycle control and data sovereignty
- **Fix:** Switch to BYOK: create or import an RSA 2048/3072/4096 key into AKV; grant the SQL Server managed identity access to the vault; `Set-AzSqlServerTransparentDataEncryptionProtector -ServerName [server] -ResourceGroupName [rg] -Type AzureKeyVault -KeyId [akv_key_uri]`

### A52 — EKM provider version is outdated
- **Trigger:** `sys.cryptographic_providers.provider_version` does not match the latest version published by the EKM vendor (compare against vendor release notes; common EKM providers: nCipher, Thales Luna, Azure Key Vault EKM connector)
- **Severity:** Warning — outdated EKM provider DLLs may have known vulnerabilities (e.g., key derivation weaknesses, authentication bypass); also risk of incompatibility with SQL Server cumulative updates
- **Fix:** Download the latest provider DLL from the vendor portal; test on a non-production SQL Server instance; update via `ALTER CRYPTOGRAPHIC PROVIDER [provider] FROM FILE = 'path\new_provider.dll'`; follow vendor's upgrade guide; verify with `SELECT * FROM sys.cryptographic_providers` after update

---

## Compliance and Coverage — A53–A56

### A53 — Sensitivity-classified columns without any encryption layer
- **Trigger:** `sys.sensitivity_classifications` WHERE `information_type IN ('Financial', 'Health', 'Credentials', 'Banking', 'National ID', 'Government', 'Payment')` AND the classified column has `column_encryption_key_id IS NULL` (no AE) AND the column name does not appear in any `ENCRYPTBYKEY` call in `sys.sql_modules`
- **Severity:** Warning — data classification is the first step in a data protection program, not the complete program; a column labeled "Financial" or "Credentials" with no encryption is still readable by any user with SELECT permission
- **Fix:** Apply Always Encrypted (preferred for Credentials and PII) or CLE (acceptable for less-sensitive Financial aggregates); confirm with the data owner whether masking (`sys.masked_columns`) is sufficient for some read-paths as a complementary control

### A54 — Sensitive-pattern column names without any encryption or classification
- **Trigger:** `sys.columns` WHERE `name` matches any of: `ssn`, `social_security`, `credit_card`, `card_number`, `cvv`, `cvc`, `pin`, `password`, `passwd`, `pw`, `dob`, `date_of_birth`, `birth_date`, `salary`, `wage`, `compensation`, `tax_id`, `ein`, `tin`, `passport`, `national_id`, `nhs`, `medical_record`, `mrn`, `diagnosis`, `prescription`, `account_number`, `routing_number`, `iban`, `swift` — AND `column_encryption_key_id IS NULL` AND `column_id` not in `sys.sensitivity_classifications`
- **Severity:** Warning — column names are strong indicators of regulated data content; unencrypted and unclassified sensitive columns are a likely compliance violation under PCI-DSS, HIPAA, or GDPR
- **Fix:** Classify columns with `ADD SENSITIVITY CLASSIFICATION TO [schema].[table].[column] WITH (LABEL = '…', INFORMATION_TYPE = '…', RANK = HIGH)`; apply encryption (A14 fix paths); run a data discovery scan (SQL Data Discovery & Classification in SSMS) to confirm column contents

### A55 — Non-FIPS compliant algorithm detected anywhere in the encryption hierarchy
- **Trigger:** Any of: `sys.dm_database_encryption_keys.key_algorithm` = TRIPLE_DES_3KEY; `sys.symmetric_keys.algorithm_desc` IN (DES, RC4, DESX, RC2, TRIPLE_DES); `CERTPROPERTY(name, 'Algorithm')` returns MD5 or SHA1; `msdb.dbo.backupset.key_algorithm` = TRIPLE_DES_3KEY; `sys.asymmetric_keys.key_length` ≤ 1024
- **Severity:** Critical for RC4, RC2, and MD5 (cryptographically broken; not fixable with configuration; all data protected by these must be considered potentially exposed); Warning for SHA1, DES, DESX, TRIPLE_DES, RSA_1024 (deprecated; not immediately broken but must be replaced for compliance)
- **Fix:** Each algorithm type requires its corresponding fix: TDE DEK (A5), CLE symmetric keys (A17), certificate hash (A35), backup encryption (A24), asymmetric keys (A39); treat this check as an umbrella finding that points to the individual fixes

### A56 — No SQL Server Audit configured for cryptographic key access events
- **Trigger:** `sys.server_audits` and `sys.database_audit_specifications` — no `DATABASE_OBJECT_ACCESS_GROUP`, `SCHEMA_OBJECT_ACCESS_GROUP`, or `DATABASE_PRINCIPAL_CHANGE_GROUP` action group is configured to target symmetric key, asymmetric key, or certificate objects
- **Severity:** Info — without an audit trail for key access and modification events, it is impossible to detect unauthorized decryption attempts, key exfiltration, certificate deletion, or key rotation that should have occurred; PCI-DSS Requirement 10.2.2 requires auditing of all access to audit logs and cryptographic key management operations
- **Fix:** Create a database audit specification: `ALTER DATABASE AUDIT SPECIFICATION [enc_audit] FOR SERVER AUDIT [instance_audit] ADD (SCHEMA_OBJECT_ACCESS_GROUP)`; enable the audit: `ALTER SERVER AUDIT [instance_audit] WITH (STATE = ON)`; for finer granularity, add an audit action on `sys.symmetric_keys`, `sys.asymmetric_keys`, and `sys.certificates` object classes

---

## TLS and Network Encryption Hardening — A57–A62

### A57 — TLS 1.0 or 1.1 enabled at operating system level
- **Trigger:** SChannel registry key `HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server\Enabled = 1` OR `TLS 1.1\Server\Enabled = 1`; OR `xp_regread` output showing either protocol enabled; OR ERRORLOG does not contain "TLS 1.0 is disabled" (SQL 2016+)
- **Severity:** Warning — TLS 1.0 is prohibited by PCI-DSS v4.0 (effective 2018 for CDE); TLS 1.1 is deprecated with known weaknesses; both expose connections to downgrade attacks (POODLE, BEAST, CRIME). Even if ForceEncryption is enabled, legacy TLS versions weaken the protection.
- **Fix:** Set `Enabled = 0` and `DisabledByDefault = 1` for TLS 1.0 and TLS 1.1 under the SChannel registry path; restart SQL Server; verify with `nmap --script ssl-enum-ciphers -p 1433 <host>` or `openssl s_client -tls1_0 -connect <host>:1433`

### A58 — Weak TLS cipher suites enabled
- **Trigger:** SChannel registry `HKLM\...\SCHANNEL\Ciphers` OR TLS cipher order in Group Policy contains RC4, 3DES, DES, NULL, EXPORT ciphers; OR `nmap` cipher scan reveals weak ciphers offered on port 1433
- **Severity:** Warning — RC4 and 3DES cipher suites are deprecated (NIST SP 800-131A); NULL ciphers offer zero encryption; EXPORT ciphers are trivially broken (FREAK attack); enabling them downgrades the effective TLS strength regardless of certificate or TLS version
- **Fix:** Use Group Policy → Computer Configuration → Administrative Templates → Network → SSL Configuration Settings → SSL Cipher Suite Order — specify a list containing only AES-GCM and AES-CBC ciphers with ECDHE key exchange; disable all RC4, 3DES, DES, NULL, MD5, and EXPORT suites; restart SQL Server

### A59 — TLS 1.3 not enforced on SQL Server 2022+
- **Trigger:** SQL Server 2022 or later AND ERRORLOG shows "TLS 1.2" as the highest negotiated protocol (TLS 1.3 not listed) AND the OS is Windows Server 2022+ (capable of TLS 1.3) AND the SChannel registry does not show TLS 1.3 disabled
- **Severity:** Info — TLS 1.3 provides improved handshake performance (1-RTT vs 2-RTT), mandatory forward secrecy (all ciphers use ECDHE), and removes legacy algorithms entirely; SQL Server 2022 on Windows Server 2022+ supports TLS 1.3 but may not negotiate it if not enabled or if clients do not support it
- **Fix:** Verify TLS 1.3 is enabled in SChannel registry: `HKLM\...\SCHANNEL\Protocols\TLS 1.3\Server\Enabled = 1`; ensure Windows Server 2022 or later; update SQL Server drivers to versions supporting TLS 1.3 (ODBC 18+, JDBC 12.4+, .NET 8+); verify with `openssl s_client -tls1_3 -connect <host>:1433`

### A60 — IPsec not configured as compensating control for unencrypted SQL traffic
- **Trigger:** `sys.dm_exec_connections` shows `encrypt_option = 'FALSE'` AND no evidence of IPsec policy securing TCP port 1433 between application servers and SQL Server (no Windows Firewall Connection Security Rule, no `netsh ipsec static show policy` output, no Group Policy IPsec rule)
- **Severity:** Info — IPsec provides network-layer encryption and authentication that protects SQL traffic even when TLS is not configured; it is an acceptable compensating control for PCI-DSS Requirement 4 where application-level TLS changes are not immediately feasible; IPsec on port 1433 with ESP/AES encryption can protect credentials and data in transit
- **Fix:** Create Windows Firewall Connection Security Rule: `New-NetIPsecRule -DisplayName "SQL Encryption" -LocalPort 1433 -Protocol TCP -RequireEncryption -Authentication RequireAuthDomain` OR configure via Group Policy → Windows Firewall with Advanced Security → Connection Security Rules; test with `netsh ipsec dynamic show mmsas`

### A61 — Kerberos armoring (FAST) not enforced in Active Directory environment
- **Trigger:** Active Directory-joined SQL Server AND Kerberos armoring (Flexible Authentication Secure Tunneling) not enforced via Group Policy (`Computer Configuration → Windows Settings → Security Settings → Local Policies → Security Options → Network security: Restrict NTLM — Kerberos armoring not configured`) AND `sys.dm_exec_connections.auth_scheme = 'KERBEROS'` for domain accounts
- **Severity:** Info — Kerberos armoring (FAST / RFC 6113) protects Kerberos AS-REQ and TGS-REQ exchanges from offline brute-force attacks on the encrypted timestamp; without armoring, a captured Kerberos pre-authentication packet can be subjected to password cracking; this weakens the authentication layer that TLS depends on
- **Fix:** Configure Group Policy: `Computer Configuration → Administrative Templates → System → Kerberos → Support for Kerberos armoring (FAST) = Enabled and require armoring`; requires domain functional level Windows Server 2012+; verify with `klist get krbtgt` showing `Armor: yes`

### A62 — Named Pipes protocol enabled on production SQL Server
- **Trigger:** SQL Server Configuration Manager shows Named Pipes protocol enabled for the instance; OR `sys.dm_server_registry` shows `SuperSocketNetLib\Np` present and Enabled; Named Pipes traffic is unencrypted by default (SMB encryption is separate)
- **Severity:** Warning — Named Pipes transport is not encrypted by TLS (TLS applies only to TCP/IP); data traverses SMB which may or may not be encrypted depending on SMB encryption configuration; Named Pipes exposes SQL traffic to any host on the same network segment with SMB access
- **Fix:** Disable Named Pipes in SQL Server Configuration Manager → SQL Server Network Configuration → Protocols for [Instance] → Named Pipes = Disabled; ensure all applications connect via TCP/IP; if Named Pipes is required for legacy local applications, restrict to local connections only and enable SMB Encryption via `Set-SmbServerConfiguration -EncryptData $true`

---

## Always Encrypted Advanced — A63–A67

### A63 — Enclave attestation service URL not configured for enclave-enabled queries
- **Trigger:** `sys.configurations` WHERE `name = 'column encryption enclave type'` AND `value_in_use > 0` (enclave enabled) AND the client connection string or application configuration does not include `Enclave Attestation Url` parameter — OR the attestation URL is missing, unreachable, or using HGS/ICM in an unsupported configuration for the SQL Server version
- **Severity:** Warning — without a configured and reachable attestation URL, the client driver cannot verify the enclave's identity before sending sensitive plaintext data for in-enclave computation; this defeats the purpose of enclave attestation and allows a compromised host to impersonate the enclave
- **Fix:** Deploy Microsoft Azure Attestation (MAA) or Host Guardian Service (HGS); configure attestation URL in the client connection string: `Enclave Attestation Url = https://<attest-server>/attest/SgxEnclave`; verify attestation works with a simple query like `SELECT GETDATE()` with enclave-enabled connection; monitor attestation failures in SQL Server ERRORLOG

### A64 — Always Encrypted driver version incompatible with secure enclave or modern features
- **Trigger:** Extended Events or `sys.dm_exec_sessions.program_name` reveals outdated driver versions: ODBC < 17.10, JDBC < 12.2, .NET < 7.0, or OLEDB < 19; AND Always Encrypted columns exist in the database — outdated drivers may lack enclave support, AEAD support, or CEK caching
- **Severity:** Warning — outdated drivers cannot leverage secure enclave capabilities, may use weaker key exchange algorithms, and may lack CEK caching (causing excessive AKV/HSM round-trips per query); this creates performance degradation and security gaps
- **Fix:** Update drivers: ODBC Driver 18+ for SQL Server, JDBC Driver 12.4+, Microsoft.Data.SqlClient 5.2+, OLE DB Driver 19+; verify `Column Encryption Setting=Enabled` in the updated connection string; test all AE queries after the driver update

### A65 — Column Encryption Key caching disabled or misconfigured
- **Trigger:** Always Encrypted columns exist AND application performance logs show high latency on first query after connection (indicating CEK decryption per session, not cached) AND the driver supports CEK caching (ODBC 17.6+, JDBC 12.2+, .NET Core 3.1+) but the application does not configure a CEK cache TTL
- **Severity:** Info — without CEK caching, the driver must contact the AKV or HSM to decrypt the CEK on every new database connection; this adds 50–200 ms of latency per connection open and increases AKV API call costs; CEK caching with a 2-hour TTL dramatically reduces this overhead
- **Fix:** Set CEK cache TTL in the client driver: ODBC — `Column Encryption Key Cache Time-To-Live = 7200` (seconds); JDBC — `columnEncryptionKeyCacheTtl = 7200`; .NET — `SqlConnection.ColumnEncryptionKeyCacheTtl = TimeSpan.FromHours(2)`; monitor AKV API call volume after enabling to confirm reduction

### A66 — Secure enclave configured but no columns using enclave-enabled computations
- **Trigger:** `sys.configurations` WHERE `name = 'column encryption enclave type'` AND `value_in_use > 0` (enclave enabled, consuming VBS memory and attestation infrastructure) AND no columns use `ENCRYPTION_TYPE = RANDOMIZED` with enclave-enabled queries OR no `LIKE`, `BETWEEN`, or range queries on encrypted columns are observed
- **Severity:** Info — enabling a secure enclave consumes system resources (VBS reserves memory, attestation service runs); if no workloads leverage the enclave, this overhead is wasted and represents a misconfigured investment; the enclave was likely enabled for proof-of-concept but never operationalized
- **Fix:** Audit the Always Encrypted column inventory for columns that would benefit from enclave computations (randomized encrypted columns queried with `LIKE`, `BETWEEN`, range, or JOIN); if no such workload exists, consider disabling the enclave: `EXEC sp_configure 'column encryption enclave type', 0; RECONFIGURE` — then monitor for functional impact on AE queries

### A67 — Enclave attestation protocol set to allow relaxed attestation
- **Trigger:** The SQL Server enclave configuration allows "relaxed" attestation (no HGS attestation URL configured, or HGS attestation mode set to `None`) in a production environment; the client can connect to the enclave without verifying its identity
- **Severity:** Warning — relaxed attestation means the client accepts any process claiming to be the enclave without cryptographic proof; in a compromised host scenario, a malicious process can intercept enclave computations and read plaintext; relaxed attestation is acceptable for development only
- **Fix:** Configure HGS or MAA attestation on the SQL Server host: `Initialize-HgsServer -HgsServerName <hgs> -HgsDomainName <domain>`; register the SQL Server with the HGS; configure the enclave to require attestation; update all client connection strings with the correct attestation URL; test attestation with `SELECT GETDATE()` before disabling relaxed attestation

---

## Operational Key Lifecycle — A68–A72

### A68 — DMK or SMK backup password does not meet complexity requirements
- **Trigger:** No evidence of DMK/SMK password complexity enforcement (length < 14 characters, no special characters, no mixed case, no digits) — inferred from documented backup procedures, SQL Agent job step text, or password vault entries
- **Severity:** Warning — a weak DMK/SMK backup password is the single point of failure for the entire database or instance encryption hierarchy; a brute-forced backup password gives an attacker full access to all encrypted data in the database or instance
- **Fix:** Regenerate the backup with a strong password: `BACKUP MASTER KEY TO FILE = '...' ENCRYPTION BY PASSWORD = 'UseAVaultWith32+CharRandomString'`; store the password in a secrets management vault (Azure Key Vault, HashiCorp Vault, CyberArk); enforce password complexity via organizational policy; use a password generator with ≥ 20 characters, mixed case, digits, and special characters

### A69 — TLS certificate not configured for automatic enrollment via AD CS
- **Trigger:** SQL Server TLS certificate is manually managed (no auto-enrollment template configured in AD CS Group Policy) AND the certificate has expired or will expire within 90 days AND the SQL Server is domain-joined
- **Severity:** Info — Active Directory Certificate Services auto-enrollment ensures TLS certificates are renewed before expiry without manual intervention; manual certificate management is the primary cause of production outages from expired TLS certificates (A30)
- **Fix:** Configure AD CS certificate template for SQL Server TLS with auto-enrollment permission; apply via Group Policy: `Computer Configuration → Windows Settings → Security Settings → Public Key Policies → Certificate Services Client - Auto-Enrollment → Enabled`; set template validity period to 1–2 years; test renewal by running `certutil -pulse` and verifying the new certificate in the machine Personal store

### A70 — No documented key archival or escrow procedure
- **Trigger:** No evidence of a documented key escrow procedure (physical or digital) — no key archival runbook, no escrow log, no documented split-knowledge procedure for key material recovery; AND certificates or master keys exist in the encryption hierarchy
- **Severity:** Warning — key escrow ensures that encryption keys can be recovered even if the primary custodians are unavailable (emergency, departure, disaster); without a documented escrow procedure, the organization has no guaranteed recovery path for encrypted data; PCI-DSS Requirement 3.7.6 mandates split-knowledge and dual-control procedures for manual clear-text key operations
- **Fix:** Document and test a key escrow procedure: define primary and secondary key custodians; establish a secure physical or digital escrow location (safe, vault, offline HSM); require dual authorization for escrow access; conduct annual escrow audits and recovery tests; integrate into the disaster recovery runbook

### A71 — TDE encryption scan I/O impact never baselined or monitored
- **Trigger:** TDE is enabled or was recently enabled AND no performance baseline was captured before the encryption scan (no `sys.dm_io_virtual_file_stats` snapshot from before the scan, no PerfMon `Physical Disk: Avg. Disk sec/Read` and `Avg. Disk sec/Write` pre-scan baseline) AND the database is larger than 50 GB
- **Severity:** Info — a TDE encryption scan reads every page of every data file and writes it back encrypted; on large databases (hundreds of GB to TB), this can cause days of elevated I/O; without a pre-scan baseline, it is impossible to quantify the impact or distinguish scan overhead from normal workload I/O
- **Fix:** Before enabling TDE, capture baseline I/O metrics: `SELECT * FROM sys.dm_io_virtual_file_stats(DB_ID('SalesDB'), NULL)`; start PerfMon with Physical Disk and SQL Server Buffer Manager counters; enable TDE during a maintenance window; monitor `percent_complete` in `sys.dm_database_encryption_keys`; on SQL 2019+, use `ALTER DATABASE [db] SET ENCRYPTION SUSPEND` during peak hours

### A72 — Database in full recovery model without log backup encryption
- **Trigger:** `sys.databases` WHERE `recovery_model = 1` (FULL recovery) AND log backups are taken (verified via `msdb.dbo.backupset` WHERE `type = 'L'`) AND `key_algorithm IS NULL` for those log backups AND TDE is enabled on the database
- **Severity:** Info — TDE encrypts the transaction log on disk, but log backup files (`.trn`) are written without encryption unless backup encryption is explicitly configured; an unencrypted transaction log backup contains all transactions that occurred during the backup interval, including DML operations on sensitive tables — anyone with access to the `.trn` file can restore and read the data
- **Fix:** Add `WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [backup_cert])` to all `BACKUP LOG` statements; update maintenance plan scripts; verify with `SELECT key_algorithm FROM msdb.dbo.backupset WHERE type = 'L' AND backup_start_date > DATEADD(DAY, -7, GETDATE())`

---

## SQL Server Ledger — A73–A76

### A73 — Ledger not enabled on database with immutability or audit requirements
- **Trigger:** Database naming convention or metadata suggests regulatory or audit requirements (names containing: audit, compliance, financial, legal, regulatory, tax) AND `sys.databases` WHERE `is_ledger_on = 0` AND SQL Server version is 2022+
- **Severity:** Info — SQL Server Ledger provides cryptographic verification that data has not been tampered with; ledger tables maintain a SHA-256 hash chain and generate periodically published database digests that can be verified by external auditors; without Ledger, database integrity relies entirely on access controls and audit logs, which can be bypassed by a sysadmin
- **Fix:** Enable Ledger on the database: `CREATE DATABASE [FinanceLedger] WITH LEDGER = ON`; migrate existing tables to ledger tables: `CREATE TABLE [dbo].[Transactions] (...) WITH (LEDGER = ON (APPEND_ONLY = ON))`; verify with `SELECT is_ledger_on FROM sys.databases WHERE name = DB_NAME()`

### A74 — Ledger database digest not configured for automatic storage
- **Trigger:** `sys.databases` WHERE `is_ledger_on = 1` AND no Azure Storage account, Azure Confidential Ledger, or file share is configured for automatic digest upload — the digest is only generated locally (no external verification possible)
- **Severity:** Warning — database digests are the cryptographic proof that data has not been tampered with; storing them only on the same server defeats the purpose — a compromised sysadmin can delete or modify the digest history; external digest storage provides tamper-evident verification that auditors can use independently
- **Fix:** Configure automatic digest storage: `EXEC sp_generate_database_ledger_digest` to an Azure Storage account (`@digest_storage_endpoint = 'https://<account>.blob.core.windows.net/<container>'`) or an Azure Confidential Ledger ACL instance; configure a SQL Agent job to run `sp_generate_database_ledger_digest` on a schedule (e.g., daily); test verification: `EXEC sp_verify_database_ledger FROM 'https://account.blob.core.windows.net/container/digest.json'`

### A75 — Ledger table hash algorithm not SHA-256
- **Trigger:** Ledger database exists AND the ledger hash algorithm is not SHA-256 (check via `sys.database_ledger_configurations` or the `CREATE DATABASE ... LEDGER = ON` documentation confirming the default) — only SHA-256 is available in SQL Server 2022, so this check serves as a future-proofing and documentation check
- **Severity:** Info — SHA-256 is the minimum acceptable hash algorithm for cryptographic ledger integrity; if a future SQL Server version allows weaker algorithms, they must be avoided; SHA-384 provides a higher security margin for long-lived financial data
- **Fix:** Verify the ledger hash algorithm: `SELECT hash_algorithm_desc FROM sys.database_ledger_configurations WHERE database_id = DB_ID()`; SHA-256 is the only supported algorithm in SQL Server 2022 — accept this for now; document the hash algorithm used for audit evidence; plan migration to SHA-384 when available for 10+ year retention workloads

### A76 — Ledger verification not scheduled on a recurring basis
- **Trigger:** Ledger database exists AND no SQL Agent job or Azure Automation runbook is configured to run `sp_verify_database_ledger` on a recurring schedule (at least monthly)
- **Severity:** Warning — ledger verification is the only way to detect tampering; if verification is never run, tampered data may go undetected for months or years, by which time the evidence trail may be cold; the ledger's security model depends on regular verification by an external party (auditor, compliance team)
- **Fix:** Create a SQL Agent job: `EXEC sp_verify_database_ledger FROM '<digest_storage_endpoint/digest_file>'` and schedule it weekly or monthly; configure SQL Agent alerts on verification failure (use SQL Agent operators for email notification); document the verification schedule in the audit runbook; periodically have an external auditor run verification independently

---

## Azure-Specific Encryption — A77–A80

### A77 — Azure SQL TDE protector key vault in different Azure region
- **Trigger:** Azure SQL Database or Managed Instance WHERE the TDE protector is customer-managed (BYOK) AND the Azure Key Vault is in a different Azure region from the SQL Server resource; OR the Key Vault is in a different subscription or tenant without proper cross-tenant authorization
- **Severity:** Warning — a cross-region Key Vault adds network latency to every DEK decryption operation (at database startup and after failover events), increases the risk of transient Key Vault unavailability due to region-specific Azure outages, and complicates the network security boundary (VNet service endpoints may not span regions)
- **Fix:** Provision an Azure Key Vault in the same region as the SQL Database or Managed Instance; migrate the TDE protector key to the regional vault using `az keyvault key import` or key rotation; update the TDE protector: `Set-AzSqlServerTransparentDataEncryptionProtector -ServerName <srv> -ResourceGroupName <rg> -Type AzureKeyVault -KeyId <new_key_uri>`; verify region affinity in Azure Portal

### A78 — Double encryption (Infrastructure + TDE) not enabled on Azure SQL for high-compliance workloads
- **Trigger:** Azure SQL Database tagged with compliance designations (PCI, HIPAA, FedRAMP, ISO 27001) AND the database does not have infrastructure encryption enabled (check Azure Portal → SQL Database → Transparent Data Encryption → "Infrastructure encryption" toggle is off) AND the service tier supports it (Premium, Business Critical, Hyperscale)
- **Severity:** Info — Azure SQL's infrastructure encryption provides an additional layer of AES-256 encryption at the storage infrastructure level, beneath TDE; this protects against physical media theft at the Azure data center level; combined with customer-managed TDE, it provides defense-in-depth against cloud-provider-level threats
- **Fix:** In Azure Portal → SQL Database → Transparent Data Encryption → enable "Infrastructure encryption" toggle; this can only be enabled at database creation or during a service tier change — it cannot be enabled on an existing database; for existing databases, create a new database with infrastructure encryption enabled and migrate data using `CREATE DATABASE ... AS COPY OF` or Azure DMS

### A79 — Always Encrypted enclave attestation shared across multiple tenants or applications
- **Trigger:** Azure SQL Database or Managed Instance with secure enclave enabled AND the attestation provider (MAA or HGS) is shared across multiple applications, tenants, or SQL Server instances without tenant isolation
- **Severity:** Warning — a shared attestation provider means that any client trusting that attestation provider can attest any enclave on any SQL Server registered with it; in a multi-tenant scenario, this allows a compromised application to impersonate the enclave of another tenant's database; dedicated attestation providers provide security isolation
- **Fix:** Deploy a dedicated MAA or HGS instance per security boundary (per tenant, per application tier, or per compliance domain); register only SQL Server instances within that boundary with the dedicated attestation provider; update client connection strings to use the dedicated attestation URL; verify isolation by testing cross-boundary attestation failure

### A80 — Azure SQL Database audit logs not encrypted at rest
- **Trigger:** SQL Server Audit is configured on Azure SQL Database (`sys.server_audits` or `sys.database_audit_specifications` exist) AND the audit log destination is Azure Blob Storage AND the storage account does not have Storage Service Encryption (SSE) enabled OR uses a storage account without customer-managed keys for compliance workloads
- **Severity:** Info — audit logs contain sensitive operational data including query text, parameter values, and user identities; unencrypted audit logs expose this data to anyone with access to the storage account; PCI-DSS Requirement 10 requires protection of audit trail data from unauthorized modification
- **Fix:** Enable Azure Storage Service Encryption on the audit log storage account (enabled by default for new accounts — verify it is on); for PCI/HIPAA workloads, configure customer-managed keys for the storage account: `az storage account update --name <account> --encryption-key-source Microsoft.KeyVault --encryption-key-vault <vault_uri> --encryption-key-name <key_name>`; verify with `az storage account show --name <account> --query encryption`

---

## Output Format

### Result Conventions

Apply one of four results to every check:

- **PASS** — attribute present, threshold not met (no issue)
- **FIRE → Critical / Warning / Info** — threshold met; use bold to distinguish from passes in the Check Evaluation Log
- **NOT ASSESSED** — required attribute absent from input (version-gated feature, missing DMV, or the construct is not applicable)
- **SKIPPED** — check triggered but insufficient data to evaluate (e.g., folder-based check when no directory provided)

### Report Structure

Structure all output in this order:

1. **Encryption Coverage Summary** — one-paragraph narrative covering which encryption layers are active, which are absent, and the overall risk posture
2. **Findings Table**

   | ID | Severity | Title | Evidence |
   |----|----------|-------|----------|
   | [A3] | CRITICAL | TDE certificate not backed up | No BACKUP CERTIFICATE in Agent history |

3. **Root-Cause Analysis** — for each Critical or Warning finding, explain the risk in business terms (data exposure scenario, compliance implication, recovery impact)
4. **Prioritised Fix Plan** — ordered by: Critical → Warning → Info; within each tier, order by fix complexity (quick wins first); include T-SQL snippets for each fix
5. **Compliance Gap Summary** — separate paragraph mapping findings to PCI-DSS, HIPAA, GDPR requirements that are likely unmet (only if relevant context indicates regulated workloads)
6. **Next Steps** — 3–5 bullet points for the DBA team

Severity labels: `CRITICAL`, `WARNING`, `INFO`
Output labels: `[A1]` through `[A80]`

### File Output

Save two files to the current working directory:

  output/sqlencryption-review/<YYYY-MM-DD-HHmmss>-<input-prefix>/analysis.md  → full report
  output/sqlencryption-review/<YYYY-MM-DD-HHmmss>-<input-prefix>/trace.md     → Check Evaluation Log

Derive `<input-prefix>` from the filename stem if a file path was provided, or from the first meaningful identifier in the artifact (database name, server name, etc.). Fallback: `run`. Sanitize: alphanumeric + hyphens/underscores only, max 32 chars.

File headers:
  analysis.md → `# Analysis — sqlencryption-review / # Input: <first 80 chars> / # Generated: <UTC timestamp>`
  trace.md    → `# Check Evaluation Log — sqlencryption-review / # Input: <first 80 chars> / # Generated: <UTC timestamp>`

Create directories as needed. When `--verbose` is not present, write nothing to disk.

> Analyzed by: `sqlencryption-review` (A1–A80)

---

## Limitations

- When DMV data is absent (user provided natural language description only), mark version-gated and data-dependent checks as `NOT ASSESSED` and note what data would be needed for a complete assessment.
- Certificate backup history is not tracked by any DMV — A3, A23, A37, A44, A47 rely on SQL Agent job history or maintenance script evidence; if that evidence is not provided, state the assumption that no backup exists.
- Registry-based checks (A26 ForceEncryption via `sys.dm_server_registry`, TLS cipher suite checks A57–A58) require the SQL Server service account to have registry read permissions or the checks must be verified manually in SQL Server Configuration Manager.
- T-SQL source-level checks (A18, A19, A43) can only be evaluated when source code is provided or extractable from `sys.sql_modules`; source-only checks not applicable to DMV-only inputs.
- Azure-specific checks (A50, A51, A77–A80) are applicable only to Azure SQL Database or SQL Server on Azure VM; mark as `NOT ASSESSED` for on-premises instances.
- SQL Server 2022+ checks (A59 TLS 1.3, A73–A76 Ledger) self-skip on older versions where the features are absent.

---

## Reference Files

Load `references/check-explanations.md` when:
- A check fires and the user asks "what does this mean?" or needs ranked fix options beyond the primary fix above
- You need DMV query examples or T-SQL code samples to verify a finding
- The user asks "explain check A5" or "how do I fix X"

The file is 1,500+ lines. Navigate with the Quick Reference Table at the top:
- **A1–A8** — Transparent Data Encryption (TDE)
- **A9–A16** — Always Encrypted
- **A17–A21** — Cell-Level Encryption (CLE)
- **A22–A25** — Backup Encryption
- **A26–A30** — Transport and Connection Encryption
- **A31–A38** — Certificate Management
- **A39–A43** — Asymmetric and Symmetric Key Management
- **A44–A48** — Key Hierarchy DMK and SMK
- **A49–A52** — EKM and Azure Key Vault
- **A53–A56** — Compliance and Coverage
- **A57–A62** — TLS and Network Encryption Hardening
- **A63–A67** — Always Encrypted Advanced
- **A68–A72** — Operational Key Lifecycle
- **A73–A76** — SQL Server Ledger
- **A77–A80** — Azure-Specific Encryption

Load `references/concepts.md` when:
- The user asks background questions: "what is TDE?", "explain symmetric vs asymmetric encryption", "what TLS version should I use?"
- A finding needs regulatory context: "what does PCI-DSS require for SQL Server encryption?", "does GDPR mandate key rotation?"
- The user needs encryption type comparison: "should I use TDE or Always Encrypted for this column?"

Load `references/howto-*.md` guides when the user asks for step-by-step operational procedures:
- `howto-tde-setup.md` — end-to-end TDE deployment
- `howto-always-encrypted.md` — Always Encrypted setup and migration
- `howto-tls-config.md` — TLS 1.2/1.3 configuration and testing
- `howto-key-rotation.md` — certificate and key rotation procedures
- `howto-crypto-shredding.md` — cryptographic erasure for GDPR right-to-erasure
- `howto-disaster-recovery.md` — encrypted database restore across servers
- `error-reference.md` — common encryption error messages and resolution

---

## Companion Skills

- `/tsql-review` — if T-SQL source code is provided, run alongside to catch `OPEN SYMMETRIC KEY` scope issues (A18), password-embedded key opens (A19), and CLE function usage patterns (A20, A21)
- `/sqlplan-review` — if execution plans are provided along with encryption artifacts, check for parameter sniffing on AE columns and implicit conversions caused by encrypted column type mismatches
- `/sqlerrorlog-review` — if ERRORLOG is available, check for TDE certificate errors, "Cannot find the server certificate" messages (A49), AG endpoint disconnection events related to cert expiry (A33), and TLS startup messages (A28, A59)
- `/sqlhadr-review` — if AG DMV data is provided, check for AG endpoint authentication failures that may be certificate-related (A33)
- `/sqlspn-review` — if Kerberos issues are suspected, check for SPN misconfiguration that may force NTLM fallback, weakening the encryption posture around transport authentication (complements A61)
- `/mssql-performance-review` — for mixed artifact bundles; routes encryption artifacts here automatically

---

## Version Compatibility

Checks are self-skipping when the feature they test is absent from the artifact:
- **A1–A8 (TDE):** SQL Server 2008 and later; `sys.dm_database_encryption_keys` not present on SQL 2005 → checks not assessed
- **A9–A16 (Always Encrypted):** SQL Server 2016 and later; A12 (secure enclave) requires SQL 2019+
- **A17–A21 (CLE):** SQL Server 2005 and later
- **A22–A25 (Backup encryption):** SQL Server 2014 and later; backup set will have no `key_algorithm` column on older versions
- **A26–A30 (Transport):** SQL Server 2008 and later
- **A31–A38 (Certificates):** SQL Server 2005 and later
- **A39–A43 (Key management):** SQL Server 2005 and later
- **A44–A48 (DMK/SMK):** SQL Server 2005 and later; A48 requires linked server configuration
- **A49–A52 (EKM/AKV):** SQL Server 2008 and later for EKM; A50–A51 require Azure SQL or SQL Server on Azure VM
- **A53–A56 (Compliance):** A53 requires SQL Server 2019+ (`sys.sensitivity_classifications`); A54–A55 all versions; A56 requires SQL Server 2012+ (SQL Server Audit GA)
- **A57–A62 (TLS/Network hardening):** A57–A58 require registry access (all Windows versions); A59 requires SQL Server 2022+ (TLS 1.3); A60 all versions; A61 requires Kerberos (Active Directory environment); A62 all versions
- **A63–A67 (Always Encrypted advanced):** A63–A65 require SQL Server 2019+ with secure enclave; A66 requires SQL Server 2019+; A67 requires SQL Server 2019+
- **A68–A72 (Operational key lifecycle):** A68–A70 all versions; A71 requires SQL Server 2008+ (TDE); A72 requires SQL Server 2014+ (backup encryption)
- **A73–A76 (SQL Ledger):** All require SQL Server 2022+; Azure SQL Database ledger available in limited regions
- **A77–A80 (Azure-specific):** All require Azure SQL Database or SQL Server on Azure VM

| Version | TDE | AE | CLE | Backup Enc | TLS | Certs | Keys | DMK/SMK | EKM | Compliance | TLS Hardening | AE Adv | Key Ops | Ledger | Azure |
|---------|-----|----|----|-----------|-----|-------|------|---------|-----|-----------|--------------|--------|---------|--------|-------|
| SQL 2005 | — | — | ✓ | — | ✓ | ✓ | ✓ | ✓ | — | A54–A55 | — | — | A68–A70 | — | — |
| SQL 2008 | ✓ | — | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | A54–A55 | A57–A58, A60, A62 | — | A68–A70 | — | — |
| SQL 2012 | ✓ | — | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | A54–A56 | A57–A58, A60, A62 | — | A68–A70 | — | — |
| SQL 2014 | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | A54–A56 | A57–A58, A60, A62 | — | A68–A72 | — | — |
| SQL 2016 | ✓ | ✓ (A9–A16) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | A54–A56 | A57–A58, A60, A62 | — | A68–A72 | — | — |
| SQL 2019 | ✓ | ✓ + A12 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | A53–A56 | A57–A58, A60, A62 | A63–A67 | A68–A72 | — | — |
| SQL 2022 | ✓ | ✓ + A12 | ✓ | ✓ | ✓ (TLS 1.3) | ✓ | ✓ | ✓ | ✓ | A53–A56 | A57–A62 | A63–A67 | A68–A72 | A73–A76 | — |
| Azure SQL | ✓ | ✓ + A12 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | A50–A51 | A53–A56 | A57–A58, A60, A62 | A63–A67 | A68–A72 | A73–A76 | A77–A80 |
