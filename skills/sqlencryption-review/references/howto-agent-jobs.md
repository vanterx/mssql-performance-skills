# HOW-TO: Secure SQL Agent Job Patterns for Encryption Operations

SQL Agent job steps are a common source of credential and key password exposure. This guide covers safe patterns for jobs that work with encryption keys, certificates, and credentials.

---

## The Core Problem

SQL Agent job step T-SQL is stored in `msdb.dbo.sysjobsteps.command` in near-plaintext. Any principal with sysadmin or SQLAgentOperatorRole can see all job step source code via SSMS or T-SQL. Passwords embedded in job steps:

- Appear verbatim in SSMS (SQL Agent → Jobs → Job → Properties → Steps → Edit)
- Are logged in full on step failure in the SQL Agent error log
- Are visible to monitoring tools, APM agents, and 3rd-party DBA tools with sysadmin access
- Remain in MSDB backup files if MSDB is backed up

**Safe rule:** Never embed `DECRYPTION BY PASSWORD`, `ENCRYPTION BY PASSWORD`, or `OPEN MASTER KEY DECRYPTION BY PASSWORD` literal values in a SQL Agent job step.

---

## Pattern 1: Certificate-Based Symmetric Key (Recommended)

Replace password-protected symmetric key opens with certificate-based ones. The cert's private key is protected by the DMK, which auto-opens via the SMK — no password in job code.

**Before (unsafe):**
```sql
-- DO NOT do this in a job step
OPEN SYMMETRIC KEY CRMDataKey
    DECRYPTION BY PASSWORD = 'SuperSecret123!';

UPDATE dbo.CustomerPII
SET EncryptedSSN = ENCRYPTBYKEY(KEY_GUID('CRMDataKey'), SSN);

CLOSE SYMMETRIC KEY CRMDataKey;
```

**After (safe — certificate-based):**
```sql
-- Ensure the symmetric key uses certificate protection first:
-- ALTER SYMMETRIC KEY CRMDataKey ADD ENCRYPTION BY CERTIFICATE CRMEncryptCert;
-- ALTER SYMMETRIC KEY CRMDataKey DROP ENCRYPTION BY PASSWORD = 'SuperSecret123!';

OPEN SYMMETRIC KEY CRMDataKey
    DECRYPTION BY CERTIFICATE CRMEncryptCert;
-- (No password needed — cert private key is DMK-protected, DMK auto-opens via SMK)

BEGIN TRY
    UPDATE dbo.CustomerPII
    SET EncryptedSSN = ENCRYPTBYKEY(KEY_GUID('CRMDataKey'), SSN);
    CLOSE SYMMETRIC KEY CRMDataKey;
END TRY
BEGIN CATCH
    CLOSE ALL SYMMETRIC KEYS;  -- Safety net
    THROW;
END CATCH;
```

**Certificate protection setup (run once):**
```sql
-- 1. Add cert protection to existing password-only key
ALTER SYMMETRIC KEY CRMDataKey
    ADD ENCRYPTION BY CERTIFICATE CRMEncryptCert;

-- 2. Remove password protection
ALTER SYMMETRIC KEY CRMDataKey
    DROP ENCRYPTION BY PASSWORD = 'SuperSecret123!';

-- 3. Verify: key should now have CERTIFICATE protection only
SELECT crypt_type_desc FROM sys.key_encryptions WHERE key_id = KEY_ID('CRMDataKey');
-- Should show ENCRYPTION_BY_CERT, not ENCRYPTION_BY_PASSWORD
```

---

## Pattern 2: Proxy Account for External Operations

SQL Agent proxy accounts run job steps under a Windows account with specific permissions. Credential secrets (passwords) for proxies are stored in `sys.credentials`, encrypted by the SMK — more secure than embedding in job step T-SQL.

```sql
-- Create a credential for external access (backup to Azure, linked server, etc.)
CREATE CREDENTIAL [AzureBackupCredential]
    WITH IDENTITY = N'myazurestorageaccount',
    SECRET = N'StorageAccessKey';

-- Create proxy using the credential
USE msdb;
EXEC sp_add_proxy
    @proxy_name = N'AzureBackupProxy',
    @credential_name = N'AzureBackupCredential',
    @enabled = 1;

-- Grant proxy to specific job subsystem
EXEC sp_grant_proxy_to_subsystem
    @proxy_name = N'AzureBackupProxy',
    @subsystem_id = 3;  -- 3 = CmdExec; 12 = PowerShell

-- Use proxy in job step (avoids embedding credentials)
-- Set in SSMS: Job Step Properties → General → Run as: AzureBackupProxy
```

**Rotate proxy credentials without touching job steps:**
```sql
ALTER CREDENTIAL [AzureBackupCredential]
    WITH IDENTITY = N'myazurestorageaccount',
    SECRET = N'NewStorageAccessKey';
-- No job step changes needed — proxy automatically uses the updated credential
```

---

## Pattern 3: TRY/CATCH with CLOSE ALL SYMMETRIC KEYS

Always close symmetric keys on error to prevent open-key leaks across connection pool reuse.

```sql
BEGIN TRY
    OPEN SYMMETRIC KEY PaymentKey DECRYPTION BY CERTIFICATE PaymentCert;

    -- Encryption/decryption work here
    SELECT DECRYPTBYKEY(EncryptedCardNumber) FROM dbo.PaymentData;

    CLOSE SYMMETRIC KEY PaymentKey;
END TRY
BEGIN CATCH
    -- Always close keys on any error path
    IF EXISTS (SELECT 1 FROM sys.openkeys WHERE key_name = 'PaymentKey')
        CLOSE SYMMETRIC KEY PaymentKey;
    CLOSE ALL SYMMETRIC KEYS;  -- Belt-and-suspenders safety net

    DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE();
    RAISERROR(@msg, 16, 1);
END CATCH;
```

---

## Pattern 4: Check for Open Keys at Session Cleanup

For long-running or agent-invoked sessions, audit and clean up open keys:

```sql
-- View keys open in current session
SELECT key_name, algorithm_desc, modify_date
FROM sys.openkeys;

-- Emergency close all keys in current session
CLOSE ALL SYMMETRIC KEYS;

-- For monitoring: alert if keys are left open across idle sessions
SELECT s.session_id, s.login_name, s.status,
       ok.key_name, s.last_request_end_time
FROM sys.dm_exec_sessions s
CROSS JOIN sys.openkeys ok
WHERE s.is_user_process = 1
  AND s.status = 'sleeping'
  AND s.last_request_end_time < DATEADD(MINUTE, -15, GETDATE());
```

---

## Pattern 5: SQL Agent Alerts for Encryption Failures

Configure SQL Agent alerts for common encryption error numbers:

```sql
-- Alert on "Cannot find the server certificate" (EKM/TDE provider failure)
EXEC msdb.dbo.sp_add_alert
    @name = N'Encryption - Cannot find server certificate',
    @message_id = 33111,
    @severity = 0,
    @enabled = 1,
    @notification_message = N'Check EKM provider, TDE certificate, and sp_control_dbmasterkey_password registrations.';

-- Alert on DMK not found / cannot open master key
EXEC msdb.dbo.sp_add_alert
    @name = N'Encryption - Cannot open master key',
    @message_id = 15581,
    @severity = 0,
    @enabled = 1,
    @notification_message = N'Check sp_control_dbmasterkey_password registration. Run sqlencryption-review A81-A84.';

-- Alert on certificate expired
EXEC msdb.dbo.sp_add_alert
    @name = N'Encryption - Certificate error',
    @message_id = 15466,
    @severity = 0,
    @enabled = 1;

-- Add operator notification to each alert
EXEC msdb.dbo.sp_add_notification
    @alert_name = N'Encryption - Cannot find server certificate',
    @operator_name = N'DBATeam',
    @notification_method = 1;  -- email
```

---

## Pattern 6: Audit Job Steps for Exposed Secrets

Run this query periodically to find job steps with embedded passwords:

```sql
-- Scan all job steps for password patterns
SELECT j.name AS job_name, s.step_id, s.step_name,
       CASE
         WHEN s.command LIKE '%DECRYPTION BY PASSWORD%' THEN 'KEY PASSWORD'
         WHEN s.command LIKE '%ENCRYPTION BY PASSWORD%' THEN 'KEY PASSWORD'
         WHEN s.command LIKE '%OPEN MASTER KEY%PASSWORD%' THEN 'DMK PASSWORD'
         WHEN s.command LIKE '%CREATE SYMMETRIC KEY%PASSWORD%' THEN 'KEY SOURCE PASSWORD'
         WHEN s.command LIKE '%ENCRYPTBYPASSPHRASE%' THEN 'PASSPHRASE'
         ELSE 'Other pattern'
       END AS exposure_type
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.command LIKE '%DECRYPTION BY PASSWORD%'
   OR s.command LIKE '%ENCRYPTION BY PASSWORD%'
   OR s.command LIKE '%OPEN MASTER KEY%PASSWORD%'
   OR s.command LIKE '%ENCRYPTBYPASSPHRASE%'
ORDER BY j.name, s.step_id;
```

Add this to a weekly monitoring job with results emailed to the DBA team.

---

## Pattern 7: Naming Convention for Key Maintenance Jobs

Use consistent naming to make key lifecycle jobs discoverable:

| Job name prefix | Purpose |
|-----------------|---------|
| `DBA - Annual TDE Cert Rotation` | Rotate TDE certificate |
| `DBA - Annual Backup Cert Rotation` | Rotate backup encryption certificate |
| `DBA - Annual CLE Key Rotation` | Rotate cell-level symmetric keys |
| `DBA - Annual SMK Backup Verification` | Verify SMK backup exists and is testable |
| `DBA - Annual DMK Backup` | Refresh DMK backups |
| `DBA - Monthly Cert Expiry Check` | Alert on certs expiring within 90 days |
| `DBA - Monthly Encryption Posture Review` | Run sqlencryption-review capture queries |

Document each job's responsible custodian in the job description field (Job Properties → General → Description).

---

## Pattern 8: Backup Certificate in a Job (Safe Template)

```sql
-- Certificate backup job step template (no embedded passwords)
-- Passwords come from a pre-created credential or are passed as parameters from a calling mechanism

DECLARE @BackupPath NVARCHAR(500) = N'\\backup-server\certs\TDECert_' + CONVERT(NVARCHAR(8), GETDATE(), 112) + '.cer';
DECLARE @KeyPath    NVARCHAR(500) = N'\\backup-server\certs\TDECert_' + CONVERT(NVARCHAR(8), GETDATE(), 112) + '.pvk';
-- NOTE: The password below should be retrieved from a secrets manager, not hardcoded
-- In practice, pass it as an agent token or use Windows CNG / DPAPI to store the password
DECLARE @Pwd NVARCHAR(128) = N'$(CertBackupPassword)';  -- SQLCMD token if using sqlcmd mode

BACKUP CERTIFICATE TDECert_Production
TO FILE = @BackupPath
WITH PRIVATE KEY (
    FILE = @KeyPath,
    ENCRYPTION BY PASSWORD = @Pwd
);

-- Log the backup
INSERT INTO dba.CertificateBackupLog (CertName, BackupFile, KeyFile, BackupDate)
VALUES (N'TDECert_Production', @BackupPath, @KeyPath, GETDATE());
```
