# How to Set Up Always Encrypted

Step-by-step operational guide for deploying Always Encrypted on a SQL Server database. Covers both the basic setup (SQL 2016+) and secure enclave configuration (SQL 2019+), plus migration from cell-level encryption.

For conceptual background on the key hierarchy, deterministic vs randomized encryption, and AE architecture, read `concepts.md`. For audit checks on an existing AE deployment, see checks A9–A16 and A63–A67 in `SKILL.md`.

---

## Prerequisites

- **SQL Server 2016 (13.x) or later** for basic Always Encrypted. Secure enclaves require SQL Server 2019 (15.x)+ with Windows Server 2019+ for VBS enclaves.
- **Driver versions** that support `Column Encryption Setting=Enabled`:
  - .NET Framework 4.6.1+ with `Microsoft.Data.SqlClient` 1.1+
  - .NET 6+ with `Microsoft.Data.SqlClient` 2.1+
  - ODBC Driver 13.1+ for SQL Server
  - JDBC Driver 6.2+ (Microsoft JDBC Driver for SQL Server)
  - Enclave-enabled operations require: .NET `Microsoft.Data.SqlClient` 2.1+ with enclave provider package, ODBC Driver 17.4+, JDBC 8.2+
- **Azure subscription** if using Azure Key Vault as the CMK store.
- **sysadmin or ALTER ANY COLUMN MASTER KEY + ALTER ANY COLUMN ENCRYPTION KEY** permissions.
- SSMS 18.0+ or `SqlServer` PowerShell module 21.0+.

---

## Step 1: Create the Column Master Key

The Column Master Key (CMK) protects the Column Encryption Keys (CEKs). The CMK never enters SQL Server — it lives in a client-side key store.

### Option A: Azure Key Vault (Recommended for Production)

1. Create an Azure Key Vault and generate a new RSA key (2048-bit minimum):
   ```powershell
   az keyvault create --name my-keyvault --resource-group my-rg --location eastus
   az keyvault key create --vault-name my-keyvault --name CMK-ProdDB-2026 --protection software `
       --kty RSA --size 2048
   ```

2. Register the Azure Key Vault provider in SQL Server:
   ```sql
   CREATE COLUMN MASTER KEY [CMK_AKV]
   WITH (
       KEY_STORE_PROVIDER_NAME = N'AZURE_KEY_VAULT',
       KEY_PATH = N'https://my-keyvault.vault.azure.net/keys/CMK-ProdDB-2026/<key-version>'
   );
   ```

3. Grant your application's Azure AD identity `get`, `unwrapKey`, and `wrapKey` permissions on the Key Vault key.

### Option B: Windows Certificate Store (Development / Test Only)

```powershell
# Create a self-signed certificate in Current User → Personal store
New-SelfSignedCertificate -Subject "CN=AlwaysEncryptedCMK" -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy NonExportable -KeyLength 2048 -KeyAlgorithm RSA
```

```sql
CREATE COLUMN MASTER KEY [CMK_WinCert]
WITH (
    KEY_STORE_PROVIDER_NAME = N'MSSQL_CERTIFICATE_STORE',
    KEY_PATH = N'CurrentUser/My/03EAEFE42D8411C60D5AB5A2B832C8AB5A67E1B4'
);
```

> **Warning:** Windows Certificate Store CMKs are machine-exportable by design. For production, prefer Azure Key Vault or a FIPS 140-2 Level 3 HSM. A13 fires on Windows-store CMKs in production.

---

## Step 2: Create the Column Encryption Key

The CEK is the symmetric key that encrypts the column data. It is stored inside SQL Server, protected (wrapped) by the CMK.

```sql
CREATE COLUMN ENCRYPTION KEY [CEK_Data]
WITH VALUES (
    COLUMN_MASTER_KEY = [CMK_AKV],
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x...  -- omitted; SSMS/PowerShell fills this in automatically
);
```

If you omit `ENCRYPTED_VALUE`, use SSMS or PowerShell to complete the CMK-to-CEK binding:

```powershell
# PowerShell: generate and set the CEK encrypted value against the CMK
$server = New-Object Microsoft.SqlServer.Management.Smo.Server "localhost"
$db = $server.Databases["MyDatabase"]
$cmk = $db.ColumnMasterKeys["CMK_AKV"]
$cek = New-Object Microsoft.SqlServer.Management.Smo.ColumnEncryptionKey $db, "CEK_Data"
$cek.Create($cmk)
```

---

## Step 3: Encrypt Columns

Choose the encryption type per column:

| Requirement | Use |
|---|---|
| Equality comparisons (`WHERE`, `JOIN`, `GROUP BY`) | **Deterministic** |
| No lookups; maximum privacy | **Randomized** |
| Range queries (`BETWEEN`, `<`, `>`) or `LIKE` | **Randomized + Secure Enclave** (SQL 2019+) |

### Via SSMS (Recommended for Initial Setup)

1. Right-click the database → Tasks → Encrypt Columns
2. Select the CEK and columns
3. For each column, choose `Deterministic` or `Randomized`
4. The wizard generates a PowerShell script; review and execute it

### Via T-SQL (No Data Migration Needed for New Columns)

For greenfield tables:

```sql
CREATE TABLE dbo.Customers (
    CustomerId  INT IDENTITY PRIMARY KEY,
    LastName    NVARCHAR(50) COLLATE Latin1_General_BIN2
        ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [CEK_Data],
                        ENCRYPTION_TYPE = RANDOMIZED,
                        ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256') NOT NULL,
    SSN         CHAR(11) COLLATE Latin1_General_BIN2
        ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [CEK_Data],
                        ENCRYPTION_TYPE = DETERMINISTIC,
                        ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256') NOT NULL
);
```

### Via PowerShell (Bulk Migration of Existing Data)

```powershell
Import-Module SqlServer

$server = New-Object Microsoft.SqlServer.Management.Smo.Server "localhost"
$db = $server.Databases["MyDatabase"]
$cek = $db.ColumnEncryptionKeys["CEK_Data"]

$settings = @()
$settings += New-SqlColumnEncryptionSettings -ColumnName "dbo.Customers.LastName" `
    -EncryptionType Randomized -EncryptionKey $cek
$settings += New-SqlColumnEncryptionSettings -ColumnName "dbo.Customers.SSN" `
    -EncryptionType Deterministic -EncryptionKey $cek

Set-SqlColumnEncryption -InputObject $db -ColumnEncryptionSettings $settings `
    -MaxBatchSize 10000
```

> **Important:** Encrypting an existing column triggers a full-table rewrite. Plan for log growth and I/O impact. The `MaxBatchSize` parameter controls how many rows are migrated per transaction.

### Collation Requirement

Encrypted string columns **must** use a BIN2 collation. If the column is not already `Latin1_General_BIN2`, alter it first:

```sql
ALTER TABLE dbo.Customers ALTER COLUMN SSN CHAR(11) COLLATE Latin1_General_BIN2 NOT NULL;
```

---

## Step 4: Update Application Connection Strings

All application connections that read or write encrypted columns must include:

```
Column Encryption Setting=Enabled
```

### Per Driver

**.NET (Microsoft.Data.SqlClient):**
```
Server=myserver;Database=MyDatabase;Authentication=Active Directory Default;
Column Encryption Setting=Enabled
```

**ODBC:**
```
Driver={ODBC Driver 18 for SQL Server};Server=myserver;Database=MyDatabase;
Authentication=ActiveDirectoryDefault;ColumnEncryption=Enabled
```

**JDBC:**
```
jdbc:sqlserver://myserver;databaseName=MyDatabase;authentication=ActiveDirectoryDefault;
columnEncryptionSetting=Enabled
```

### Key Store Provider Registration

Applications must register the CMK key store provider before opening connections:

**.NET:**
```csharp
SqlColumnEncryptionAzureKeyVaultProvider akvProvider =
    new SqlColumnEncryptionAzureKeyVaultProvider(new DefaultAzureCredential());
SqlConnection.RegisterColumnEncryptionKeyStoreProviders(
    new Dictionary<string, SqlColumnEncryptionKeyStoreProvider>
    {
        { SqlColumnEncryptionAzureKeyVaultProvider.ProviderName, akvProvider }
    });
```

**Java (JDBC):** Configure the `keyStoreAuthentication` and `keyStorePrincipalId` connection properties with the AKV client ID and secret. See Microsoft JDBC driver documentation for your version.

**ODBC:** Run the AKV provider registration command before the connection:
```powershell
# One-time machine-wide registration
az extension add --name sqlvm
Register-SqlVmAkvCredential -CredentialName "MyAKVCred"
```

---

## Step 5: Test Encrypted Queries

### From SSMS (with Column Encryption Setting)

Add `Column Encryption Setting=Enabled` to the SSMS connection dialog → Additional Connection Parameters tab, or use a dedicated registered server with the parameter pre-filled.

Then run:

```sql
-- Insert (parameters must be passed via parameterized query or SSMS variables)
DECLARE @ssn CHAR(11) = '123-45-6789';
INSERT INTO dbo.Customers (LastName, SSN)
VALUES ('Smith', @ssn);

-- Deterministic lookup (equality works)
DECLARE @ssn CHAR(11) = '123-45-6789';
SELECT * FROM dbo.Customers WHERE SSN = @ssn;
-- Returns the row

-- Randomized lookup (will fail without enclave)
DECLARE @name NVARCHAR(50) = N'Smith';
SELECT * FROM dbo.Customers WHERE LastName = @name;
-- Msg 206, Level 16: Operand type clash:
-- encrypted nvarchar(50) is incompatible with nvarchar(50)
```

### Verify Encryption Metadata

```sql
SELECT
    SCHEMA_NAME(t.schema_id) AS sch, t.name AS tbl, c.name AS col,
    c.encryption_type_desc, c.encryption_algorithm_name,
    cek.name AS cek_name, cmk.name AS cmk_name,
    cmk.key_store_provider_name
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.column_encryption_keys cek ON c.column_encryption_key_id = cek.column_encryption_key_id
JOIN sys.column_master_keys cmk ON cek.column_master_key_id = cmk.column_master_key_id
WHERE c.column_encryption_key_id IS NOT NULL;
```

---

## Step 6: Configure Secure Enclave (SQL 2019+)

Secure enclaves enable rich computations (range scans, pattern matching, in-place encryption) on randomized-encrypted columns.

### 6a. Enable the Enclave on the Server

```sql
EXEC sp_configure 'column encryption enclave type', 1;  -- 1 = VBS
RECONFIGURE;
-- Restart SQL Server service required
```

Verify after restart:

```sql
SELECT name, value_in_use FROM sys.configurations
WHERE name = 'column encryption enclave type';
-- Should return 1
```

### 6b. Configure Attestation

Choose one attestation provider:

**Azure Attestation (Recommended):**
1. Create an Azure Attestation provider in the Azure portal
2. Note the attestation URL: `https://myattest.eus.attest.azure.net`
3. Add to connection string: `Attestation Protocol=HGS;Enclave Attestation Url=https://myattest.eus.attest.azure.net/attest/SgxEnclave`

**Host Guardian Service (On-Premises):**
1. Deploy HGS on Windows Server 2019+
2. Register the SQL Server host with HGS
3. Configure the attestation URL: `https://hgs.contoso.com/Attestation`

### 6c. Update Connection String for Enclave

```
Server=myserver;Database=MyDatabase;Authentication=Active Directory Default;
Column Encryption Setting=Enabled;
Enclave Attestation Url=https://myattest.eus.attest.azure.net/attest/SgxEnclave;
Attestation Protocol=HGS
```

### 6d. Test Enclave Operations

```sql
-- Range query (requires enclave and randomized encryption)
DECLARE @min CHAR(11) = '100-00-0000';
DECLARE @max CHAR(11) = '199-99-9999';
SELECT * FROM dbo.Customers
WHERE SSN >= @min AND SSN <= @max;
-- Works only with enclave enabled

-- LIKE queries (requires enclave and randomized encryption)
DECLARE @pattern NVARCHAR(50) = N'Smi%';
SELECT * FROM dbo.Customers WHERE LastName LIKE @pattern;
-- Works only with enclave enabled
```

### 6e. In-Place Encryption with Enclave

Enclaves enable encrypting or rotating columns without moving data outside SQL Server:

```sql
ALTER TABLE dbo.Customers
ALTER COLUMN SSN CHAR(11) COLLATE Latin1_General_BIN2
ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [CEK_Data],
                ENCRYPTION_TYPE = RANDOMIZED,
                ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256') NOT NULL;
-- With enclave, this runs server-side without data round-trips to the client
```

---

## Step 7: Rotate the Column Master Key

CMK rotation re-wraps all CEKs with a new CMK. This does **not** touch the column data.

### 7a. Create the New CMK

```sql
CREATE COLUMN MASTER KEY [CMK_AKV_2027]
WITH (
    KEY_STORE_PROVIDER_NAME = N'AZURE_KEY_VAULT',
    KEY_PATH = N'https://my-keyvault.vault.azure.net/keys/CMK-ProdDB-2027/<version>'
);
```

### 7b. Rotate via PowerShell

```powershell
$db = Get-SqlDatabase -ServerInstance "localhost" -Database "MyDatabase"
Invoke-SqlColumnMasterKeyRotation -InputObject $db `
    -SourceColumnMasterKeyName "CMK_AKV" `
    -TargetColumnMasterKeyName "CMK_AKV_2027"
```

### 7c. Distribute the New CMK

Before completing rotation, ensure all application servers and secondary replicas have access to the new CMK (AKV permissions or certificate deployment). After verifying all CEKs have been re-wrapped:

```sql
-- Verify the rotation: each CEK should show the new CMK
SELECT cek.name AS cek_name, cmk.name AS cmk_name, cekv.create_date
FROM sys.column_encryption_key_values cekv
JOIN sys.column_encryption_keys cek ON cekv.column_encryption_key_id = cek.column_encryption_key_id
JOIN sys.column_master_keys cmk ON cekv.column_master_key_id = cmk.column_master_key_id;

-- Drop old CMK only after confirming nothing depends on it
DROP COLUMN MASTER KEY [CMK_AKV];
```

---

## Step 8: Migrate from Cell-Level Encryption to Always Encrypted

If you are moving from `ENCRYPTBYKEY`/`DECRYPTBYKEY` (CLE) to Always Encrypted:

### 8a. Inventory CLE Columns

```sql
SELECT OBJECT_NAME(object_id) AS proc_name, definition
FROM sys.sql_modules
WHERE definition LIKE '%ENCRYPTBYKEY%'
   OR definition LIKE '%DECRYPTBYKEY%';
```

### 8b. Decrypt and Re-Encrypt

```sql
-- In a batch window, decrypt CLE values and stage them as plaintext
OPEN SYMMETRIC KEY MyCLEKey DECRYPTION BY CERTIFICATE MyCert;

SELECT CustomerId,
       CONVERT(CHAR(11), DECRYPTBYKEY(EncryptedSSN)) AS PlaintextSSN
INTO #Staging
FROM dbo.Customers
WHERE EncryptedSSN IS NOT NULL;

CLOSE SYMMETRIC KEY MyCLEKey;
```

### 8c. Apply Always Encrypted

Use SSMS Encrypt Columns wizard or PowerShell (Step 3) against the staging table or the source table directly. The PowerShell `Set-SqlColumnEncryption` cmdlet handles the full decrypt/re-encrypt cycle client-side if the source column is not encrypted.

### 8d. Remove CLE Artifacts

```sql
-- After verifying all data is AE-encrypted and applications work
CLOSE ALL SYMMETRIC KEYS;
DROP SYMMETRIC KEY MyCLEKey;
DROP CERTIFICATE MyCert;  -- only if no other CLE keys depend on it
```

### 8e. Update Application Code

Remove `DECRYPTBYKEY()` calls. Application code now reads the column directly — the driver performs decryption transparently. Remove `OPEN SYMMETRIC KEY` and `CLOSE SYMMETRIC KEY` calls from all stored procedures.

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| `Operand type clash: encrypted <type> is incompatible with <type>` | Querying a randomized-encrypted column without an enclave | Switch to Deterministic for equality-only queries, or enable enclave (Step 6) |
| `Failed to decrypt column encryption key. Invalid key store provider name` | Application did not register the key store provider | Register AKV provider or Windows cert store provider before opening connection (Step 4) |
| `The certificate with thumbprint ... was not found in the certificate store` | CMK certificate not available on the application server | Export CMK certificate from the machine where it was created and install on all app servers |
| `Attestation failed` or `Enclave attestation Url is invalid` | Enclave attestation URL misconfigured or attestation service is down | Verify the attestation URL in the connection string; confirm the SQL Server host is registered with HGS/ASA; check `sys.dm_hadr_*` for enclave status |
| `Msg 206: Operand type clash: encrypted nvarchar is incompatible with nvarchar` on WHERE clause | Application passing plaintext literals instead of parameterizing | Use `SqlParameter` objects with `SqlDbType` matching the column; never inline literals for encrypted columns |
| `Msg 33299: The encryption key ... cannot be found` | CEK dropped or never created; column references non-existent key | Verify with `SELECT * FROM sys.column_encryption_keys`; recreate CEK if missing |
| `Access denied to Azure Key Vault` or `Forbidden` | Application identity does not have `get`, `unwrapKey`, `wrapKey` on the AKV key | Grant Key Vault access policy or RBAC role to the application's managed identity or service principal |
| `Collation mismatch` or `Cannot use column encryption with collation Latin1_General_CI_AS` | String column does not use a BIN2 collation | Alter column collation to `Latin1_General_BIN2` before applying encryption |

---

## Checklist

- [ ] SQL Server version is 2016+ (2019+ for enclaves)
- [ ] Application driver versions are compatible (Step 1 — Prerequisites)
- [ ] Column Master Key created in Azure Key Vault (or validated HSM for production)
- [ ] Windows Certificate Store CMK replaced with AKV for production (A13)
- [ ] Column Encryption Key created and wrapped by CMK
- [ ] String columns using `Latin1_General_BIN2` collation
- [ ] Encryption type chosen correctly: Deterministic for searchable columns, Randomized for pure privacy
- [ ] `AEAD_AES_256_CBC_HMAC_SHA_256` algorithm selected for all columns (A11)
- [ ] Application connection strings updated with `Column Encryption Setting=Enabled`
- [ ] Key store provider registered in application code or ODBC config
- [ ] Encrypted queries tested with parameterized variables (not inline literals)
- [ ] Secure enclave configured if range/LIKE queries are needed (SQL 2019+)
- [ ] Enclave attestation URL verified and connection string updated
- [ ] CMK rotation schedule defined (at least every 2 years — A16)
- [ ] CEK rotation scheduled (at least annually — A15)
- [ ] CLE-to-AE migration completed: all `DECRYPTBYKEY`/`ENCRYPTBYKEY` calls removed
- [ ] CMK private key backed up (for Windows cert store) or Key Vault soft-delete enabled
- [ ] DR procedure documented: how to restore the CMK and CEK hierarchy on a new instance
- [ ] Sensitivity classifications applied to encrypted columns via `ADD SENSITIVITY CLASSIFICATION`
- [ ] Audit policy configured to log CMK/CEK creation and rotation events
