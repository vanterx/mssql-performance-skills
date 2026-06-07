# How to Recover Encrypted Databases in Disaster Recovery

A step-by-step operational guide for restoring encrypted SQL Server databases to new servers after hardware failure, site loss, or OS migration. Covers TDE, backup encryption, Always Encrypted, and availability group failover.

The key principle: encryption keys are portable iff you backed them up before the disaster. If the only copy of a TDE certificate's private key was on the failed server, the encrypted data is unrecoverable.

See `concepts.md` for the SQL Server key hierarchy and `howto-tde-setup.md` for initial TDE deployment.

## Prerequisites — What to Back Up Before Disaster

| Artifact | How to back up | Storage requirements |
|----------|---------------|---------------------|
| **Service Master Key (SMK)** | `backup service master key to file = 'E:\Keys\smk.key' encryption by password = '…'` | Separate from server; needed after OS reinstall or bare-metal restore |
| **Database Master Key (DMK) in master** | `backup master key to file = 'E:\Keys\master_dmk.key' encryption by password = '…'` | Separate secure location; needed when restoring master to a new server |
| **TDE certificate (public + private key)** | `backup certificate TDECert to file = 'E:\Keys\TDECert.cer' with private key (file = 'E:\Keys\TDECert.pvk', encryption by password = '…')` | Off-server vault **and** DR site; the .pvk file is high-sensitivity |
| **Backup encryption certificate** | Same as TDE certificate backup | Same requirements if the cert is separate from the TDE cert |
| **Always Encrypted column master key** | Export from AKV (managed HSM) or from Windows certificate store (`Export-PfxCertificate`) | Secure offline storage or secondary-region AKV with RBAC |
| **All database DMKs** (user databases using CLE) | `backup master key to file = 'E:\Keys\[db]_dmk.key' encryption by password = '…'` | Needed for CLE-encrypted data recovery; without it all CLE data is lost |

All passwords must be stored in a separate secrets management system — never in the same folder or share as the key files.

## Scenario 1: Restore TDE-Encrypted Database to New Server

This is the most common DR scenario. You have the database backup (.bak) file and the TDE certificate backup (.cer + .pvk). The target server has no prior knowledge of the source instance's keys.

```sql
-- 1. Create a DMK in master on the target server (use a new password — it does not need to match the source)
use master;
go
create master key encryption by password = 'TargetServerDMK!';
go

-- 2. Import the TDE certificate from the backup files
create certificate TDECert
from file = 'E:\Keys\TDECert.cer'
with private key (
    file = 'E:\Keys\TDECert.pvk',
    decryption by password = 'StrongBackupP@ssw0rd!'
);
go

-- 3. Verify the certificate imported correctly
select name, pvt_key_encryption_type_desc, thumbprint
from sys.certificates
where name = 'TDECert';
go

-- 4. Restore the database
restore database [YourDatabase]
from disk = 'E:\Backups\YourDatabase_Full.bak'
with move 'YourDatabase' to 'E:\Data\YourDatabase.mdf',
     move 'YourDatabase_log' to 'F:\Log\YourDatabase_log.ldf',
     recovery;
go

-- 5. Verify the database is online and accessible
select name, is_encrypted from sys.databases where name = 'YourDatabase';
go
```

If step 4 fails with "cannot find server certificate", double-check that the certificate thumbprint in `sys.certificates` on the target matches the thumbprint stored in the DEK. In rare cases the wrong certificate backup was provided or the certificate was rotated post-backup.

## Scenario 2: Restore Encrypted Backups to New Server

If the database backup itself was encrypted with a certificate (separate from the TDE cert), you need both certificates on the target.

```sql
-- 1. Import the backup encryption certificate first
create certificate BackupEncryptCert
from file = 'E:\Keys\BackupEncryptCert.cer'
with private key (
    file = 'E:\Keys\BackupEncryptCert.pvk',
    decryption by password = 'BackupKeyP@ssw0rd!'
);
go

-- 2. Import the TDE certificate (if the database itself is TDE-encrypted)
create certificate TDECert
from file = 'E:\Keys\TDECert.cer'
with private key (
    file = 'E:\Keys\TDECert.pvk',
    decryption by password = 'TdeKeyP@ssw0rd!'
);
go

-- 3. Restore — SQL Server decrypts the backup file using BackupEncryptCert,
--    then decrypts the DEK using TDECert
restore database [YourDatabase]
from disk = 'E:\Backups\YourDatabase_Encrypted.bak'
with move 'YourDatabase' to 'E:\Data\YourDatabase.mdf',
     move 'YourDatabase_log' to 'F:\Log\YourDatabase_log.ldf',
     recovery;
go
```

If the same certificate was used for both TDE and backup encryption, only one import is needed.

## Scenario 3: Cross-Version Restore

Restoring a TDE-encrypted database from a lower SQL Server version to a higher version (e.g., 2016 → 2022) is supported and follows the same procedure as Scenario 1. The certificate import format is forward-compatible.

Restoring from a higher version to a lower version is **not supported**, regardless of encryption. SQL Server never supports downgrade restores.

If the source instance used Azure Key Vault-backed TDE (EKM), the target server must have the same EKM provider installed and the same AKV credential created before the certificate import. This applies to both TDE and Always Encrypted.

## Scenario 4: AG Failover with Encryption

In an availability group, encryption is instance-level — every replica must have the same TDE certificate and any backup encryption certificates present in `master`.

Pre-failover checklist:

- [ ] The same TDE certificate (identical thumbprint) exists in `master` on every replica
- [ ] The DMK in `master` exists on every replica and is openable (SMK chain intact)
- [ ] Any backup encryption certificates are also present on every replica
- [ ] `tempdb` on each replica is encrypted and fully scanned (happens automatically at startup once any TDE database starts)

Seeding an encrypted database to a new replica:

```sql
-- On the new replica, import the TDE certificate before joining the AG
-- Then add the replica to the AG and seed normally
alter availability group [AG_Name] add database [YourDatabase];
```

If the certificate is missing on a secondary, the database enters a not-synchronizing state. Add the certificate, then resume data movement. No restart is required.

## Scenario 5: Migrate Always Encrypted CMK to New Server

Always Encrypted column master keys (CMKs) are stored outside SQL Server — in Azure Key Vault, Windows Certificate Store, or an HSM. SQL Server never sees the plaintext CMK.

**For Azure Key Vault CMKs:**

No migration is needed. Grant the target server's application identity (managed identity or service principal) the `get`, `unwrapKey`, and `verify` permissions on the same key vault key. The application will connect and decrypt column encryption keys transparently.

**For Windows Certificate Store CMKs:**

```powershell
# On the source server: export the certificate with its private key
$cert = Get-ChildItem -Cert:\CurrentUser\My | Where-Object { $_.Subject -like "*AlwaysEncrypted*" }
$password = ConvertTo-SecureString -String "ExportP@ssw0rd!" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath "E:\Keys\AECMK.pfx" -Password $password

# On the target server: import the certificate
Import-PfxCertificate -FilePath "E:\Keys\AECMK.pfx" `
    -CertStoreLocation Cert:\CurrentUser\My `
    -Password $password
```

After import, the application connection string must reference the same key store provider and key path. Test column decryption with a `select` that returns an encrypted column value.

## Scenario 6: Regenerate SMK After OS Migration

When SQL Server is installed on a new OS (bare-metal restore, VM migration with fresh OS), the Windows DPAPI context changes. The new instance's SMK cannot decrypt the restored master database's DMK, which breaks the entire key hierarchy.

Procedure:

```sql
-- 1. Restore master to the new server (single-user mode, startup parameter -m)
--    SQL Server will start but the DMK cannot auto-open

-- 2. Open the DMK manually using the backup password
open master key decryption by password = 'DMKBackupPassword!';
go

-- 3. Re-establish the SMK protection chain
alter master key add encryption by service master key;
go

-- 4. Close and test
close master key;
go
-- Restart SQL Server normally — the DMK should now auto-open via the new SMK
```

If you did not back up the DMK, you can recover it from a backup of the original `master` database if you know the DMK password. If you have neither, all certificates and keys in master are permanently inaccessible.

## DR Runbook Checklist

### Before disaster (must be done now)

- [ ] TDE certificate backed up with private key (.cer + .pvk) and stored off-server
- [ ] Backup encryption certificate backed up (if separate from TDE cert)
- [ ] SMK backed up (`backup service master key`)
- [ ] DMK in `master` backed up
- [ ] All user database DMKs (for CLE) backed up
- [ ] All backup passwords stored in a separate secrets vault
- [ ] Always Encrypted CMK export tested and stored off-server (if Windows cert store)
- [ ] Certificate thumbprints documented in the runbook (for verification during restore)
- [ ] AG replicas verified to have matching certificates (all nodes)
- [ ] Full DR restore tested on a non-production server within the last 6 months

### During disaster recovery

- [ ] Locate the certificate backup files and passwords
- [ ] Create DMK in `master` on the target server
- [ ] Import TDE certificate — verify thumbprint matches runbook
- [ ] Import backup encryption certificate (if applicable)
- [ ] Restore database with `recovery`
- [ ] Verify `is_encrypted = 1` in `sys.databases`
- [ ] Run `dbcc checkdb` to confirm data integrity
- [ ] Test application connectivity and query encrypted columns (if Always Encrypted)
- [ ] Restore the SMK backup if the OS was rebuilt (Scenario 6)

### Post-restore verification

- [ ] `sys.dm_database_encryption_keys.encryption_state = 3` for the restored database
- [ ] `tempdb` is encrypted (`is_encrypted = 1`)
- [ ] No `Msg 33111` or `Msg 33104` errors in the SQL Server ERRORLOG
- [ ] AG databases are synchronized on all replicas (if applicable)
- [ ] Backup jobs reconfigured and tested
- [ ] New certificate backups taken on the target server (the imported cert now lives here)

## Common Errors

| Error | Meaning | Resolution |
|-------|---------|------------|
| **Msg 33111** — "Cannot find server certificate with thumbprint '0x…'" | The TDE certificate was not imported on the target, or the wrong certificate file was used | Import the correct certificate .cer/.pvk pair; verify the thumbprint in `sys.certificates` matches the source runbook |
| **Msg 33104** — "Cannot decrypt the database encryption key" | The certificate exists but its private key is inaccessible — typically because the DMK in master does not exist or is not open | Run `open master key decryption by password = '…'` then `alter master key add encryption by service master key` |
| **Msg 15507** — "The key is not encrypted using the specified decryptor" | The certificate was created with a password and the DMK auto-open chain is insufficient | Run `open master key decryption by password = '…'` then `open certificate TDECert decryption by password = '…'` |
| **Msg 33101** — "Cannot use the special principal 'sa'" | The restore is attempting to create or modify an SA-owned object; typically a key creation conflict | Use a service account with `sysadmin` or `control server` instead of sa |
| **Msg 15578** — "The database encryption key is encrypted by a certificate which was created with a password" | The DEK-protecting certificate has `encryption by password` set; the DMK chain alone is insufficient | Open the certificate explicitly: `open certificate TDECert decryption by password = '…'` before the restore |
| **Msg 33096** — "A generic failure occurred in cryptographic services" | The .pvk file is corrupted, the password is wrong, or the file was modified | Re-obtain the private key backup from a verified source; if no copy exists, the data is not recoverable |
