# How to Rotate SQL Server Encryption Keys

Step-by-step rotation procedures for every key and certificate in the SQL Server key hierarchy. Pre-checks, commands, and post-verification included for each type.

## TDE Certificate Rotation

Zero-downtime: the database stays online. The DEK is re-encrypted under the new certificate asynchronously.

```sql
use master;
-- Back up the current TDE certificate before rotating
backup certificate TDE_Cert_Old
to file = '\\backup\share\TDE_Cert_Old.cer'
with private key (file = '\\backup\share\TDE_Cert_Old.pvk',
    encryption by password = 'OldCertBackupP@ssw0rd!');

-- Create replacement and bind it to the DEK
create certificate TDE_Cert_New
with subject = 'TDE Certificate v2', expiry_date = '20270101';

alter database encryption key encryption by server certificate TDE_Cert_New;

-- Monitor re-encryption (encryption_state = 5 means complete)
select db.name, d.encryption_state, d.percent_complete
from sys.dm_database_encryption_keys d
join sys.databases db on db.database_id = d.database_id;

-- Back up the new certificate immediately
backup certificate TDE_Cert_New
to file = '\\backup\share\TDE_Cert_New.cer'
with private key (file = '\\backup\share\TDE_Cert_New.pvk',
    encryption by password = 'NewCertBackupP@ssw0rd!');
```

Preserve the old certificate backup — required if you restore a pre-rotation backup.

## Backup Encryption Certificate Rotation

Only future backups are affected. Existing backup files remain decryptable with their original certificate.

```sql
use master;
create certificate BackupCert_v2
with subject = 'Backup Encryption v2', expiry_date = '20270101';

backup database [MyDatabase]
to disk = '\\backup\share\MyDatabase_v2.bak'
with encryption (algorithm = aes_256, server certificate = BackupCert_v2);

backup certificate BackupCert_v2
to file = '\\backup\share\BackupCert_v2.cer'
with private key (file = '\\backup\share\BackupCert_v2.pvk',
    encryption by password = 'CertBackupP@ssw0rd!');
```

Test a restore of the new backup to a scratch server to confirm the certificate chain works.

## Service Broker Endpoint Certificate Rotation

Requires stopping the endpoint briefly. Co-ordinate public-key exchange between both servers.

```sql
-- On primary: create new cert, reconfigure endpoint
create certificate SB_Cert_v2
with subject = 'SB Primary v2', expiry_date = '20270101';

alter endpoint ServiceBrokerEndpoint state = stopped;
alter endpoint ServiceBrokerEndpoint for service_broker
    (authentication = certificate SB_Cert_v2);
alter endpoint ServiceBrokerEndpoint state = started;

backup certificate SB_Cert_v2 to file = '\\backup\share\SB_Cert_v2.cer';
```

On the secondary, import the primary's new public key (`create certificate ... from file =`). Repeat the process on the secondary. Schedule a short maintenance window — the `state = stopped` is unavoidable.

## AG Endpoint Certificate Rotation

Rotate one replica at a time to avoid failover.

```sql
-- On each replica
create certificate AG_Cert_v2
with subject = 'AG Mirroring v2', expiry_date = '20270101';

alter endpoint Hadr_endpoint state = stopped;
alter endpoint Hadr_endpoint for database_mirroring
    (authentication = certificate AG_Cert_v2);
alter endpoint Hadr_endpoint state = started;

backup certificate AG_Cert_v2 to file = '\\backup\share\AG_Cert_v2.cer';
```

Import each replica's exported certificate on every other replica (`create certificate ... from file =`). Verify data movement resumes via `sys.dm_hadr_database_replica_states`.

## Cell-Level Encryption Symmetric Key Rotation

Create a new key, re-encrypt data in batched transactions, drop the old key.

```sql
use MyDatabase;
open master key decryption by password = 'DMK_P@ssw0rd!';
open symmetric key CLE_OldKey decryption by certificate CLE_Cert;

create symmetric key CLE_NewKey
with algorithm = aes_256 encryption by certificate CLE_Cert;

open symmetric key CLE_NewKey decryption by certificate CLE_Cert;

-- Re-encrypt columns (batch for large tables)
update dbo.Patients
set SSN_Encrypted = EncryptByKey(Key_GUID('CLE_NewKey'),
    DecryptByKey(SSN_Encrypted));

-- Verify a roundtrip sample before dropping the old key
close symmetric key CLE_OldKey;
drop symmetric key CLE_OldKey;
close symmetric key CLE_NewKey;
close master key;
```

For large tables, use `update top(n) ... where condition` loops with committed batches to control log growth.

## Always Encrypted Column Master Key Rotation

The CMK lives outside SQL Server. Rotate by provisioning a new key in the external store, registering it in each database, and adding CEK values for it.

```powershell
# Azure Key Vault — create a new key version
Add-AzKeyVaultKey -VaultName 'MyVault' -Name 'AE_CMK' -Destination 'Software'
```

```sql
-- Register the new CMK (pointing to new AKV key version)
create column master key AE_CMK_v2
from provider = AZURE_KEY_VAULT
with provider_key_name = 'https://myvault.vault.azure.net/keys/AE_CMK/4a3b...',
     key_store_provider_name = 'AZURE_KEY_VAULT';

-- Add CEK values encrypted by the new CMK (encrypted_value generated client-side)
alter column encryption key CEK_SSN
add value with (
    column_master_key = AE_CMK_v2,
    algorithm = 'RSA_OAEP',
    encrypted_value = <client_provided_value>
);
```

After all CEKs reference the new CMK, update application connection strings to use the new CMK provider. Remove the old CMK registration when safe.

## Always Encrypted Column Encryption Key Rotation

Rotates the key that encrypts column data (the CMK stays the same).

```sql
-- 1. Create a new CEK under the existing CMK (encrypted_value from client)
create column encryption key CEK_SSN_v2
with values (
    column_master_key = AE_CMK,
    algorithm = 'RSA_OAEP',
    encrypted_value = <client_provided_value>
);

-- 2. Rotate online (SQL 2022+)
exec sp_rotate_encryption_key
    @column_encryption_key_name = 'CEK_SSN_v2',
    @column_master_key_name = 'AE_CMK',
    @database_name = 'MyDatabase',
    @use_online_approach = 1;
```

For SQL 2016–2019, use the Always Encrypted Wizard in SSMS, or export/import data through an AE-enabled application writing with the new CEK.

## Database Master Key Regeneration

Creates a new DMK and re-encrypts all keys and certificates protected by the old one.

```sql
use MyDatabase;
-- Back up current DMK first
backup master key to file = '\\backup\share\DMK_old.key'
encryption by password = 'DMKBackupP@ssw0rd!';

-- Regenerate — re-encrypts all dependent keys and certs
alter master key regenerate with encryption by password = 'NewDMKP@ssw0rd!';

-- Back up the new DMK
backup master key to file = '\\backup\share\DMK_new.key'
encryption by password = 'NewDMKBackupP@ssw0rd!';

-- Verify dependent symmetric keys still work
open master key decryption by password = 'NewDMKP@ssw0rd!';
open symmetric key CLE_NewKey decryption by certificate CLE_Cert;
close symmetric key CLE_NewKey;
close master key;
```

## Service Master Key Regeneration

The SMK is the instance root. Regenerating it affects every database. Schedule an outage window.

```sql
-- Back up current SMK (critical — no recovery possible without this)
backup service master key to file = '\\backup\share\SMK_old.key'
encryption by password = 'SMKBackupStr0ngP@ssw0rd!';

alter service master key regenerate;

-- Re-encrypt every database's DMK with the new SMK
use MyDatabase1;  alter master key add encryption by service master key;
use MyDatabase2;  alter master key add encryption by service master key;
-- ... repeat for every user database

-- Back up the new SMK
backup service master key to file = '\\backup\share\SMK_new.key'
encryption by password = 'SMKBackupStr0ngP@ssw0rd!';
```

Immediately after regeneration, test connectivity to every database.

## Checklist

Before any rotation:

- [ ] Full database backups completed and verified
- [ ] Current certificate and key backups confirmed on secured storage
- [ ] Maintenance window scheduled (for endpoint stop/start rotations)
- [ ] Rollback plan documented: old key backups ready for re-import

Per key/cert type:

- [ ] **TDE certificate** — old cert backed up, `alter database encryption key` executed, `percent_complete = 0`
- [ ] **Backup encryption cert** — new cert created, fresh encrypted backup taken, restore tested on scratch server
- [ ] **SB endpoint cert** — endpoints reconfigured, public keys exchanged, message delivery verified
- [ ] **AG endpoint cert** — certs exchanged across replicas, endpoint restarted per replica, data movement resumed
- [ ] **CLE symmetric key** — new key created, data re-encrypted in batches, sample verified, old key dropped
- [ ] **CMK** — new AKV key provisioned, CMK registered in DB, CEK values added, applications updated
- [ ] **CEK** — new CEK created, `sp_rotate_encryption_key` completed, client applications using new CEK
- [ ] **DMK** — old DMK backed up, `regenerate` completed, dependent keys re-verified, new DMK backed up
- [ ] **SMK** — old SMK backed up, `regenerate` completed, every database DMK re-encrypted, all databases accessible
