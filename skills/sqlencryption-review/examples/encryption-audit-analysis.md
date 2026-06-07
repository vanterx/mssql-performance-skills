# Encryption Audit Analysis — Expected Output

This is the expected `/sqlencryption-review` analysis of the input in `encryption-audit-input.md`.

---

## Coverage Summary

| Layer | Status | Detail |
|-------|--------|--------|
| TDE (at-rest DB) | Partial | SalesDB encrypted; HRPayroll and ArchiveDB unencrypted |
| TDE Certificate | Critical | TDECert_SalesDB expired 15 months ago; BackupEncryptCert expired 10 months ago |
| Always Encrypted | Not deployed | 8 sensitive-pattern columns (card numbers, SSN, salary, DOB, tax ID) unprotected |
| Cell-Level Encryption | Broken | TRIPLE_DES_3KEY on CreditCardKey; RC4_128 on SessionTokenKey (cryptographically broken) |
| Backup Encryption | Partial | SalesDB backups encrypted but with expired cert; HRPayroll and ArchiveDB unencrypted |
| Transport (TLS) | Warning | Remote sessions 51/53/55 in plaintext; self-signed TLS certificate on server |
| Certificates | Critical | ServiceBrokerCert expired 3.5 years ago; AGEndpointCert private key protected by password only |
| Key Hierarchy (DMK) | Warning | HRPayroll and ArchiveDB DMKs not encrypted by SMK; no certificate/master key backup job |
| EKM / AKV | N/A | No EKM providers configured |
| Compliance | Critical | No sensitivity classifications; no SQL Server Audit; FIPS violations (RC4, 3DES) |

**Total findings: 18 checks triggered** (3 Critical, 9 Warning, 6 Info)

---

## Findings

| ID | Severity | Category | Finding |
|----|----------|----------|---------|
| A1 | Warning | TDE | HRPayroll (HR/payroll data) and ArchiveDB not encrypted at rest |
| A3 | Critical | TDE | No SQL Agent job for certificate backup — TDECert_SalesDB and BackupEncryptCert have no documented backup |
| A4 | Critical | TDE | TDECert_SalesDB expired 2025-03-15 (15 months overdue) — SalesDB restores from old backups at risk |
| A8 | Warning | TDE | tempdb encrypted but HRPayroll/ArchiveDB lack TDE — residual overhead without full protection |
| A14 | Warning | Always Encrypted | 8 sensitive-pattern columns (CreditCardNumber, CVV, SSN, Salary, DOB, TaxID, BankAccountNumber) have no Always Encrypted |
| A17 | Critical | CLE | SalesDB: CreditCardKey uses TRIPLE_DES_3KEY (deprecated); SessionTokenKey uses RC4_128 (cryptographically broken — remove immediately) |
| A18 | Warning | CLE | RC4 key SessionTokenKey is likely left open — no CLOSE evidence; any session can decrypt data |
| A22 | Critical | Backup | HRPayroll and ArchiveDB backups unencrypted — stolen backup = full data exposure |
| A23 | Critical | Backup | SalesDB backup cert (BackupEncryptCert) not backed up; cert expired 2025-08-01 — future restores may fail |
| A25 | Critical | Backup | BackupEncryptCert expired 2025-08-01 — 10 months ago; new backups may silently fall back to unencrypted depending on backup job configuration |
| A26 | Warning | Transport | ForceEncryption not enabled — sessions 51, 53, 55 connecting without TLS from remote IPs |
| A27 | Warning | Transport | 3 active remote sessions (51, 53, 55) using `encrypt_option = FALSE` — credentials and query data in cleartext on the wire |
| A28 | Info | Transport | Self-signed TLS certificate in use — clients must trust it explicitly; MITM vector in production |
| A31 | Warning | Certificates | AGEndpointCert private key protected by password only (ENCRYPTED_BY_PASSWORD) — not integrated into DMK hierarchy |
| A32 | Warning | Certificates | ServiceBrokerCert expired 2023-01-01 — 3.5 years ago; Service Broker connections will fail or use no authentication |
| A37 | Critical | Certificates | No BACKUP CERTIFICATE job exists — TDECert_SalesDB, BackupEncryptCert, ServiceBrokerCert, AGEndpointCert all lack documented backups |
| A44 | Critical | Key Hierarchy | No BACKUP MASTER KEY job — DMK loss for any database = permanent encrypted data loss |
| A45 | Warning | Key Hierarchy | HRPayroll and ArchiveDB: `is_master_key_encrypted_by_server = 0` — DMK not auto-decrypted; `OPEN MASTER KEY` required after every restart or application outage |
| A47 | Critical | Key Hierarchy | No BACKUP SERVICE MASTER KEY job — SMK loss during OS migration = permanent loss of all server-level secrets |
| A53 | Warning | Compliance | No sensitivity classifications applied — data classification is absent; no data governance baseline |
| A54 | Warning | Compliance | 8 sensitive-pattern columns identified without any encryption layer or classification |
| A55 | Critical | Compliance | FIPS violations: RC4_128 (broken) on SessionTokenKey; TRIPLE_DES_3KEY (deprecated) on CreditCardKey; TDECert_SalesDB using SHA1 signature |
| A56 | Info | Compliance | No SQL Server Audit configured — key access, cert operations, and decryption events are unlogged |

---

## Root-Cause Analysis

### Root Cause 1: Stale Key Lifecycle Management

The instance has accumulated 7+ years of encryption artifacts with no documented rotation or expiry management. TDECert_SalesDB (3-year-old cert, expired 15 months ago), BackupEncryptCert (expired 10 months ago), and ServiceBrokerCert (expired 3.5 years ago) all indicate that certificate expiry monitoring was never implemented. The absence of SQL Agent jobs for `BACKUP CERTIFICATE` and `BACKUP MASTER KEY` means this state could persist indefinitely without detection. The CLE keys (TRIPLE_DES_3KEY from 2019, RC4_128 from 2018) were created when these algorithms were already known to be weak — they were never rotated.

**Evidence chain:** master.sys.certificates (expired certs) → msdb.dbo.backupset (encrypted SalesDB backups using expired cert) → sys.dm_database_encryption_keys (TDE DEK bound to expired cert) → SQL Agent history (no backup jobs for keys/certs)

### Root Cause 2: Incomplete Encryption Coverage of High-Value Databases

HRPayroll is the most sensitive database (contains salary, SSN, tax ID, bank account data) but has no TDE, its backups are unencrypted, its SalaryKey is protected by password only, and its DMK requires manual opening. The encryption work was applied to SalesDB (likely the first database to handle card data) but never extended to HRPayroll. ArchiveDB similarly has no TDE.

**Evidence chain:** sys.databases (HRPayroll is_encrypted = 0) → sys.columns (salary, DOB, TaxID, BankAccountNumber — all NULL column_encryption_key_id) → msdb.dbo.backupset (HRPayroll backups: key_algorithm NULL) → sys.key_encryptions (SalaryKey protected by password only)

### Root Cause 3: Broken Transport Encryption Configuration

ForceEncryption is disabled and the server is using a self-signed TLS certificate (confirmed by ERRORLOG startup message: "A self-generated certificate was successfully loaded for encryption"). As a result, 3 of 4 remote sessions are connecting without TLS, including SQL authentication sessions that transmit credentials in plaintext over the network. This is a systemic misconfiguration, not an isolated incident.

**Evidence chain:** ERRORLOG ("self-generated certificate") → sys.dm_exec_connections (encrypt_option = FALSE on remote sessions 51, 53, 55)

---

## Fix Plan

### Immediate Priority (Critical — do today)

**1. Rotate TDECert_SalesDB (A4)**
```sql
-- On master database
CREATE CERTIFICATE TDECert_SalesDB_2026
WITH SUBJECT = 'TDE Certificate for SalesDB — 2026',
EXPIRY_DATE = '20280606';

USE SalesDB;
ALTER DATABASE ENCRYPTION KEY
ENCRYPTION BY SERVER CERTIFICATE TDECert_SalesDB_2026;

-- Verify new cert is active
SELECT db_name(database_id), encryptor_thumbprint
FROM sys.dm_database_encryption_keys;

-- Keep old cert to restore backups taken before the rotation
-- BACKUP CERTIFICATE TDECert_SalesDB_2026 TO FILE = '\\backup-server\certs\TDECert_SalesDB_2026.cer'
-- WITH PRIVATE KEY (FILE = '\\backup-server\certs\TDECert_SalesDB_2026.pvk',
--                  ENCRYPTION BY PASSWORD = 'STRONG_PASSPHRASE_HERE');
```

**2. Remove RC4 key immediately (A17, A55)**
```sql
USE SalesDB;
-- Audit what uses this key first
SELECT OBJECT_NAME(object_id), definition
FROM sys.sql_modules
WHERE definition LIKE '%SessionTokenKey%';

-- After confirming no active usage, drop it
DROP SYMMETRIC KEY SessionTokenKey;
```

**3. Rotate CreditCardKey from TRIPLE_DES_3KEY to AES_256 (A17)**
```sql
USE SalesDB;
-- 1. Create replacement key
CREATE SYMMETRIC KEY CreditCardKey_2026
WITH ALGORITHM = AES_256
ENCRYPTION BY CERTIFICATE TDECert_SalesDB_2026;

-- 2. Re-encrypt existing data (in a transaction with batching)
-- OPEN SYMMETRIC KEY CreditCardKey WITH CERTIFICATE TDECert_SalesDB; 
-- OPEN SYMMETRIC KEY CreditCardKey_2026 WITH CERTIFICATE TDECert_SalesDB_2026;
-- UPDATE dbo.CustomerPayment SET EncryptedCCN = 
--   ENCRYPTBYKEY(KEY_GUID('CreditCardKey_2026'), DECRYPTBYKEY(EncryptedCCN));
-- CLOSE ALL SYMMETRIC KEYS;

-- 3. After re-encryption is confirmed, drop old key
-- DROP SYMMETRIC KEY CreditCardKey;
```

**4. Enable backup encryption for HRPayroll and ArchiveDB (A22)**
```sql
-- Update maintenance plan or backup job scripts:
BACKUP DATABASE [HRPayroll]
TO DISK = N'\\backup-server\HRPayroll\HRPayroll_Full.bak'
WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = BackupEncryptCert),
COMPRESSION, STATS = 10;
-- Note: Must create new BackupEncryptCert first (current one expired)
```

**5. Back up all certificates and master keys (A3, A37, A44, A47)**
```sql
-- SERVICE MASTER KEY (run on master)
BACKUP SERVICE MASTER KEY
TO FILE = '\\backup-server\keys\SMK_20260606.key'
ENCRYPTION BY PASSWORD = 'STRONG_PASSPHRASE';

-- DATABASE MASTER KEY for each database
USE SalesDB;
BACKUP MASTER KEY
TO FILE = '\\backup-server\keys\SalesDB_DMK_20260606.key'
ENCRYPTION BY PASSWORD = 'STRONG_PASSPHRASE';

-- Each certificate with private key
BACKUP CERTIFICATE TDECert_SalesDB_2026
TO FILE = '\\backup-server\certs\TDECert_SalesDB_2026.cer'
WITH PRIVATE KEY (
  FILE = '\\backup-server\certs\TDECert_SalesDB_2026.pvk',
  ENCRYPTION BY PASSWORD = 'STRONG_PASSPHRASE'
);
```

### High Priority (Warning — this week)

**6. Enable TDE on HRPayroll (A1)**
```sql
USE master;
CREATE CERTIFICATE TDECert_HRPayroll
WITH SUBJECT = 'TDE Certificate for HRPayroll — 2026',
EXPIRY_DATE = '20280606';

USE HRPayroll;
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE TDECert_HRPayroll;

ALTER DATABASE HRPayroll SET ENCRYPTION ON;
-- Monitor: SELECT * FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('HRPayroll')
```

**7. Fix HRPayroll DMK auto-decryption (A45)**
```sql
USE HRPayroll;
ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;

-- Verify
SELECT is_master_key_encrypted_by_server FROM sys.databases WHERE name = 'HRPayroll';
-- Should return 1
```

**8. Protect SalaryKey by certificate instead of password (A19)**
```sql
USE HRPayroll;
-- First create a certificate in HRPayroll
CREATE CERTIFICATE HRPayroll_KeyProtectCert
WITH SUBJECT = 'Key protection certificate for HRPayroll symmetric keys',
EXPIRY_DATE = '20280606';

-- Add cert-based protection
ALTER SYMMETRIC KEY SalaryKey
ADD ENCRYPTION BY CERTIFICATE HRPayroll_KeyProtectCert;

-- Remove password-based protection (after confirming cert protection works)
-- ALTER SYMMETRIC KEY SalaryKey
-- DROP ENCRYPTION BY PASSWORD = 'current_password_here';
```

**9. Fix AGEndpointCert private key encryption (A31)**
```sql
USE master;
ALTER CERTIFICATE AGEndpointCert
WITH PRIVATE KEY (
  DECRYPTION BY PASSWORD = 'current_password',
  ENCRYPTION BY DATABASE MASTER KEY
);
```

**10. Enable ForceEncryption (A26, A27)**

In SQL Server Configuration Manager:
- SQL Server Network Configuration → Protocols for [MSSQLSERVER] → Properties
- Certificate tab: Configure a CA-signed certificate (see A28 fix)
- Flags tab: Force Encryption = Yes
- Restart SQL Server service

### Medium Priority (Info — this month)

**11. Deploy Always Encrypted on high-risk columns (A14)**

Priority order based on regulatory exposure:
1. `SalesDB.dbo.CustomerPayment.CreditCardNumber` — PCI-DSS Requirement 3.4
2. `SalesDB.dbo.CustomerPayment.CVV` — PCI-DSS
3. `SalesDB.dbo.CustomerProfile.SSN` — GDPR/HIPAA
4. `HRPayroll.dbo.Employee.Salary` — GDPR Article 9
5. `HRPayroll.dbo.Employee.TaxID`, `BankAccountNumber` — PCI-DSS/GDPR

Use SSMS Encrypt Columns wizard or PowerShell:
```powershell
Import-Module SqlServer
# Example for CreditCardNumber with deterministic encryption (searchable)
$columnEncSettings = @(
    New-SqlColumnEncryptionSettings -ColumnName "dbo.CustomerPayment.CreditCardNumber" `
        -EncryptionType Deterministic `
        -EncryptionKey "CEK_CustomerPayment"
)
Set-SqlColumnEncryption -ColumnEncryptionSettings $columnEncSettings `
    -InputObject $database
```

**12. Apply sensitivity classifications (A53, A54)**
```sql
USE SalesDB;
ADD SENSITIVITY CLASSIFICATION TO dbo.CustomerPayment.CreditCardNumber
  WITH (LABEL = 'Highly Confidential', INFORMATION_TYPE = 'Banking', RANK = HIGH);
  
ADD SENSITIVITY CLASSIFICATION TO dbo.CustomerProfile.SSN
  WITH (LABEL = 'Highly Confidential', INFORMATION_TYPE = 'National ID', RANK = HIGH);
```

**13. Create SQL Server Audit for key access events (A56)**
```sql
CREATE SERVER AUDIT [EncryptionKeyAudit]
TO FILE (FILEPATH = N'C:\SQLAudit\EncryptionKeys\', MAXSIZE = 100 MB, MAX_ROLLOVER_FILES = 10)
WITH (ON_FAILURE = CONTINUE);

ALTER SERVER AUDIT [EncryptionKeyAudit] WITH (STATE = ON);

USE SalesDB;
CREATE DATABASE AUDIT SPECIFICATION [SalesDB_KeyAccessAudit]
FOR SERVER AUDIT [EncryptionKeyAudit]
ADD (SCHEMA_OBJECT_ACCESS_GROUP),
ADD (DATABASE_OBJECT_ACCESS_GROUP)
WITH (STATE = ON);
```

---

## Compliance Gap Analysis

| Framework | Requirement | Status | Gap |
|-----------|-------------|--------|-----|
| PCI DSS v4 Req 3.4 | PAN must be unreadable at rest | **FAIL** | CreditCardNumber, CVV stored in plaintext |
| PCI DSS v4 Req 3.5 | Key custodians documented, dual control | **FAIL** | No key backup procedures; no custodian documentation |
| PCI DSS v4 Req 4.2 | TLS 1.2+ for cardholder data in transit | **FAIL** | Remote sessions without encryption; self-signed cert |
| PCI DSS v4 | No RC4 or 3DES | **FAIL** | RC4_128 and TRIPLE_DES_3KEY active in SalesDB |
| HIPAA §164.312(a)(2)(iv) | Encryption of PHI at rest | **PARTIAL** | HRPayroll (PHI database) not encrypted |
| HIPAA §164.312(e)(2)(ii) | Transmission security | **FAIL** | Unencrypted remote sessions |
| HIPAA §164.312(b) | Audit controls | **FAIL** | No SQL Server Audit |
| GDPR Art. 32 | Encryption as appropriate technical measure | **FAIL** | HRPayroll (personal data) unencrypted; plaintext transport |
| GDPR Art. 25 | Data protection by design | **FAIL** | No sensitivity classification; no column encryption on PII |

---

## Next Steps

1. **Today:** Remove RC4 key (SessionTokenKey) immediately — no valid use case; any usage indicates broken design
2. **Today:** Rotate TDECert_SalesDB; create and back up new cert off-server
3. **Today:** Capture SMK and DMK backups for all databases; store off-server in secure location
4. **This week:** Enable TDE on HRPayroll; rotate BackupEncryptCert; update HRPayroll backup jobs to use encryption; fix HRPayroll DMK to use SMK encryption
5. **This week:** Configure ForceEncryption + CA-signed TLS certificate; coordinate app teams to remove `TrustServerCertificate=True` from connection strings
6. **This month:** Deploy Always Encrypted on PCI-scoped card number columns; engage application team for driver updates (`Column Encryption Setting=Enabled`)
7. **This month:** Apply sensitivity classifications; create SQL Server Audit for key access events
8. **Ongoing:** Run `/sqlencryption-review` after each key rotation or certificate renewal to verify the posture is maintained

**Companion reviews to run alongside this analysis:**
- `/sqlerrorlog-review` — look for additional encryption-related startup errors, certificate load failures
- `/sqlhadr-review` — verify AG endpoint cert rotation does not disconnect replicas  
- `/tsql-review` — audit all stored procedures for hardcoded passwords or unsafe OPEN SYMMETRIC KEY patterns
