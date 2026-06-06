# Encryption Audit Input — Sample DMV Output

This sample represents output collected from a production SQL Server 2019 instance hosting three user databases: `SalesDB`, `HRPayroll`, and `ArchiveDB`. The collection queries match the recommended captures in `SKILL.md`.

---

## 1. sys.databases — Encryption State

```
database_id  name         is_encrypted  collation_name
-----------  -----------  ------------  ----------------------
1            master       0             SQL_Latin1_General_CP1_CI_AS
2            tempdb       1             SQL_Latin1_General_CP1_CI_AS
3            model        0             SQL_Latin1_General_CP1_CI_AS
4            msdb         0             SQL_Latin1_General_CP1_CI_AS
5            SalesDB      1             SQL_Latin1_General_CP1_CI_AS
6            HRPayroll    0             SQL_Latin1_General_CP1_CI_AS
7            ArchiveDB    0             SQL_Latin1_General_CP1_CI_AS
```

---

## 2. sys.dm_database_encryption_keys

```
database_id  db_name     encryption_state  encryption_state_desc  percent_complete  encryptor_type  key_algorithm  key_length  encryptor_thumbprint                      set_date
-----------  ----------  ----------------  ---------------------  ----------------  --------------  -------------  ----------  ----------------------------------------  -----------------------
2            tempdb      3                 ENCRYPTED              100               CERTIFICATE     AES_256        256         0x3A7B...                                  2024-11-10 08:22:14
5            SalesDB     3                 ENCRYPTED              100               CERTIFICATE     AES_256        256         0x3A7B...                                  2024-11-10 08:22:14
```

---

## 3. master.sys.certificates

```
name                        certificate_id  principal_id  pvt_key_encryption_type_desc  issuer_name                 subject                     expiry_date             thumbprint   start_date
--------------------------  --------------  ------------  ----------------------------  --------------------------  --------------------------  ----------------------  -----------  ----------------------
TDECert_SalesDB             1               1             ENCRYPTED_BY_MASTER_KEY       CN=TDECert_SalesDB          CN=TDECert_SalesDB          2025-03-15 00:00:00     0x3A7B...    2022-03-15 00:00:00
BackupEncryptCert           2               1             ENCRYPTED_BY_MASTER_KEY       CN=BackupEncryptCert        CN=BackupEncryptCert        2025-08-01 00:00:00     0xF9C2...    2023-08-01 00:00:00
ServiceBrokerCert           3               1             ENCRYPTED_BY_MASTER_KEY       CN=ServiceBrokerCert        CN=ServiceBrokerCert        2023-01-01 00:00:00     0xAB44...    2021-01-01 00:00:00
AGEndpointCert              4               1             ENCRYPTED_BY_PASSWORD         CN=AGEndpointCert           CN=AGEndpointCert           2027-06-01 00:00:00     0xDE88...    2025-06-01 00:00:00
##MS_AgentSigningCertificate#  5            1             ENCRYPTED_BY_MASTER_KEY       CN=##MS_Agent...            CN=##MS_Agent...            2099-01-01 00:00:00     0x1122...    2019-01-01 00:00:00
```

*Note: Today's date is 2026-06-06. TDECert_SalesDB expired 2025-03-15 (15 months ago). BackupEncryptCert expires 2025-08-01 (already expired 10 months ago). ServiceBrokerCert expired 2023-01-01 (3.5 years ago).*

---

## 4. sys.symmetric_keys (user databases)

### SalesDB

```
name                            symmetric_key_id  algorithm_desc    key_length  create_date             modify_date             is_open
------------------------------  ----------------  ----------------  ----------  ----------------------  ----------------------  -------
##MS_DatabaseMasterKey##        101               AES_256           256         2022-03-10 10:00:00     2022-03-10 10:00:00     0
CreditCardKey                   102               TRIPLE_DES_3KEY   192         2019-06-12 14:30:00     2019-06-12 14:30:00     0
SessionTokenKey                 103               RC4_128           128         2018-01-05 09:00:00     2018-01-05 09:00:00     0
```

### HRPayroll

```
name                            symmetric_key_id  algorithm_desc    key_length  create_date             modify_date             is_open
------------------------------  ----------------  ----------------  ----------  ----------------------  ----------------------  -------
##MS_DatabaseMasterKey##        201               AES_256           256         2021-05-20 08:00:00     2021-05-20 08:00:00     0
SalaryKey                       202               AES_256           256         2021-05-20 08:15:00     2021-05-20 08:15:00     0
```

---

## 5. sys.key_encryptions (HRPayroll.SalaryKey)

```
key_id  crypt_type  crypt_type_desc             thumbprint
------  ----------  --------------------------  ----------
202     ESKP        ENCRYPTION_BY_PASSWORD      NULL
```

*SalaryKey is protected by password only — no certificate or asymmetric key in the hierarchy.*

---

## 6. sys.columns — Always Encrypted (SalesDB)

```
object_id  object_name     column_id  name                    column_encryption_key_id  encryption_type  encryption_type_desc
---------  --------------  ---------  ----------------------  ------------------------  ---------------  --------------------
(no rows returned — no Always Encrypted columns configured in SalesDB)
```

---

## 7. sys.columns — Sensitive-pattern names (all user databases)

```
database_name  schema_name  table_name        column_name           column_encryption_key_id  user_type_name
-------------  -----------  ----------------  --------------------  ------------------------  ---------------
SalesDB        dbo          CustomerPayment   CreditCardNumber      NULL                      nvarchar
SalesDB        dbo          CustomerPayment   CVV                   NULL                      char
SalesDB        dbo          CustomerPayment   CardExpiryDate        NULL                      date
SalesDB        dbo          CustomerProfile   SSN                   NULL                      varchar
HRPayroll      dbo          Employee          Salary                NULL                      decimal
HRPayroll      dbo          Employee          DateOfBirth           NULL                      date
HRPayroll      dbo          Employee          TaxID                 NULL                      varchar
HRPayroll      dbo          Employee          BankAccountNumber     NULL                      varchar
```

*None of these sensitive columns have Always Encrypted configured (`column_encryption_key_id IS NULL`).*

---

## 8. sys.sensitivity_classifications

```
(0 rows returned — no sensitivity classifications have been applied to any database)
```

---

## 9. msdb.dbo.backupset — Recent 30 days

```
database_name  backup_start_date        backup_type  key_algorithm  encryptor_thumbprint
-------------  -----------------------  -----------  -------------  --------------------
SalesDB        2026-06-05 02:00:00      D            AES_256        0xF9C2...
SalesDB        2026-06-04 02:00:00      D            AES_256        0xF9C2...
SalesDB        2026-06-03 02:00:00      L            AES_256        0xF9C2...
HRPayroll      2026-06-05 02:15:00      D            NULL           NULL
HRPayroll      2026-06-04 02:15:00      D            NULL           NULL
HRPayroll      2026-06-03 02:15:00      L            NULL           NULL
ArchiveDB      2026-06-05 02:30:00      D            NULL           NULL
ArchiveDB      2026-06-01 02:30:00      D            NULL           NULL
```

*HRPayroll and ArchiveDB backups are unencrypted (`key_algorithm IS NULL`).*
*SalesDB backups use certificate `BackupEncryptCert` (0xF9C2...) — which has already expired (2025-08-01).*

---

## 10. sys.dm_exec_connections — Remote connections

```
session_id  client_net_address    encrypt_option  auth_scheme  protocol_type
----------  --------------------  --------------  -----------  -------------
51          192.168.1.101         FALSE           SQL          TCP
52          192.168.1.205         TRUE            WINDOWS      TCP
53          10.10.5.33            FALSE           SQL          TCP
54          <local machine>       FALSE           SQL          Shared Memory
55          192.168.1.101         FALSE           SQL          TCP
```

*Sessions 51, 53, 55 are remote connections with `encrypt_option = FALSE` — data travels unencrypted.*

---

## 11. sys.configurations — Server settings

```
name                                    value   value_in_use  description
--------------------------------------  ------  ------------  -------------------------------------------
column encryption enclave type         0       0             Type of enclave used for Always Encrypted
EKM provider enabled                   0       0             Enable EKM provider for server
```

---

## 12. sys.databases — DMK auto-decryption

```
name        is_master_key_encrypted_by_server
----------  ---------------------------------
SalesDB     1
HRPayroll   0
ArchiveDB   0
```

*HRPayroll and ArchiveDB DMKs are NOT encrypted by the Service Master Key — they require explicit `OPEN MASTER KEY` on every restart.*

---

## 13. sys.asymmetric_keys (all user databases)

```
(0 rows — no user-created asymmetric keys exist)
```

---

## 14. sys.column_master_keys / sys.column_encryption_keys

```
(0 rows in both views — Always Encrypted not deployed)
```

---

## 15. SQL Server ERRORLOG excerpt (startup)

```
2026-06-01 06:14:22.310  spid5s   SQL Server is starting at normal priority base (=7). This is an informational message only.
2026-06-01 06:14:24.820  spid5s   A self-generated certificate was successfully loaded for encryption.
2026-06-01 06:14:25.110  spid15s  Server is listening on [ 'any' <ipv4> 1433].
```

*Self-signed certificate in use for TLS — clients must use `TrustServerCertificate=True`.*

---

## 16. SQL Agent job history — Backup/maintenance evidence

```
job_name                            last_run_date   last_run_outcome  last_run_message
----------------------------------  --------------  ----------------  ---------------------------
DBA - Weekly Full Backup            2026-06-01      Succeeded         Backups completed for all user databases
DBA - Daily Differential Backup     2026-06-05      Succeeded         Differentials completed
DBA - Certificate Backup            (no such job)   -                 -
DBA - Master Key Backup             (no such job)   -                 -
```

*No SQL Agent jobs exist for backing up certificates or master keys.*

---

## 17. sys.server_audits / sys.database_audit_specifications

```
(0 rows in sys.server_audits — no SQL Server Audit configured on this instance)
```
