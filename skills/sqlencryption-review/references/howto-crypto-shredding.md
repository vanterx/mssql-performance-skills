# How to Implement Cryptographic Erasure (GDPR Right-to-Erasure)

## GDPR Context

Article 17 of the GDPR grants data subjects the right to erasure ("right to be forgotten"). Deleting rows satisfies this superficially: backups, log archives, replication snapshots, and uncommitted disk pages can retain copies. Cryptographic erasure makes data permanently unreadable rather than removing it, covering every copy in every location.

## Crypto-Shredding Concept

Assign each data subject a unique symmetric key. Encrypt that subject's data with that key. On a deletion request, drop the key — every copy of the ciphertext (live database, backups, log files, replicas) becomes irrecoverable.

```
Customer A data → encrypted with Key_A (AES_256)
Customer B data → encrypted with Key_B (AES_256)
Customer C data → encrypted with Key_C (AES_256)

Erasure for Customer B: drop Key_B → all Customer B ciphertext is unrecoverable
```

Pre-shred backups are safe: the key resides only in the database key hierarchy, not in the backup file itself.

## Option 1: Cell-Level Encryption with Per-Customer Keys

Cell-Level Encryption (CLE) uses `EncryptByKey` / `DecryptByKey` with a per-customer symmetric key. Works on all SQL Server editions.

### Key Creation (per customer onboarded)

```sql
create master key encryption by password = '<strong_dmk_password>';
open master key decryption by password = '<strong_dmk_password>';

create certificate CustomerCert_123 with subject = 'Customer 123 Key Cert';
create symmetric key Key_Customer_123
with algorithm = aes_256
encryption by certificate CustomerCert_123;
```

### Encrypt on Write / Decrypt on Read

```sql
open symmetric key Key_Customer_123 decryption by certificate CustomerCert_123;

-- write
insert into CustomerPII (CustomerId, EncryptedEmail)
values (123, EncryptByKey(Key_GUID('Key_Customer_123'), 'alice@example.com'));

-- read
select CustomerId, convert(nvarchar(255), DecryptByKey(EncryptedEmail)) as Email
from CustomerPII where CustomerId = 123;

close symmetric key Key_Customer_123;
```

### Crypto-Shred Erasure

```sql
open master key decryption by password = '<strong_dmk_password>';
drop symmetric key Key_Customer_123;
drop certificate CustomerCert_123;
```

SQL Server handles thousands of symmetric keys without practical impact. Use `Key_Customer_{id}` naming.

## Option 2: Always Encrypted Approach

Always Encrypted (AE) encrypts client-side using Column Encryption Keys (CEKs) protected by Column Master Keys (CMKs). Create one CEK per customer for per-subject shredding.

```sql
-- CMK in Azure Key Vault (recommended)
create column master key CustomerCMK
with (
    key_store_provider_name = 'AZURE_KEY_VAULT',
    key_path = 'https://<vault>.vault.azure.net/keys/CustomerCMK/<version>'
);

-- per-customer CEK
create column encryption key CEK_Customer_123
with values (
    column_master_key_definition_name = 'CustomerCMK',
    algorithm = 'RSA_OAEP',
    encrypted_value = <encrypted_value_from_client_driver>
);
```

### Erasure

```sql
drop column encryption key CEK_Customer_123;
```

### CLE vs AE

| Factor | CLE | AE |
|--------|-----|----|
| Editions | All | All (enclave: Enterprise only) |
| Client changes | `DecryptByKey` in T-SQL | Client driver manages encryption |
| Index support | None on encrypted cols | Deterministic encryption allows equality lookups |
| Keys outside SQL | No | CMK in AKV/HSM |

## Verifying Erasure

```sql
-- key must be absent
select count(*) as remaining_keys from sys.symmetric_keys
where name = 'Key_Customer_123';  -- expected: 0

-- ciphertext must be unreadable
begin try
    open symmetric key Key_Customer_123 decryption by certificate CustomerCert_123;
    print 'erasure not complete';
end try
begin catch
    print 'erasure confirmed';
end catch;
```

Remove plaintext copies from application caches, materialised views, indexed views, and full-text indexes. If deterministic AE was used, equality indexes on encrypted columns are safe to leave — the values are now semantically meaningless.

## Audit Trail Requirements

GDPR Article 5(2) requires the controller to demonstrate compliance. Record for every erasure:

- Data subject identity and request timestamp; verification method
- Key name dropped, key creation date, timestamp of drop, operator who executed it
- Verification result (query confirming key absent per `sys.symmetric_keys` / `sys.column_encryption_keys`)

Store audit records in a separate, encrypted audit database so they survive key drops in the operational database. Retain for 3–6 years per your data protection policy.

## Limitations and Caveats

- **Plaintext copies**: if PII exists in plaintext in indexes, redundant columns, or materialised views, crypto-shredding does not erase those. Audit all column usages first.
- **No special handling for AG or log shipping**: ciphertext replicates normally; the key exists only in the primary's key hierarchy.
- **Restoring pre-shred backups**: ciphertext but no key — data is irrecoverable by design.
- **No undo**: dropping a key permanently destroys data. Verify the deletion request before execution.
- **Password-based keys**: passwords must never appear in source control, config files, or environment variables.
- **CPU cost**: batch `EncryptByKey` / `DecryptByKey` calls and open the key once per batch, not once per row.

## Checklist

- [ ] DMK created and backed up (DMK loss = all per-customer keys lost)
- [ ] Key naming convention established: `Key_Customer_{id}`
- [ ] Application code updated for key open/close or AE client driver
- [ ] Encryption columns sized correctly (`varbinary`: plaintext length × 2 + overhead for CLE)
- [ ] No plaintext PII in indexes, computed columns, or materialised views
- [ ] Audit table provisioned in a separate, encrypted database
- [ ] Key drop procedure tested in a non-production environment
- [ ] Erasure verification query confirmed working
- [ ] Backup-and-restore tested: pre-shred backup unrecoverable after key drop
- [ ] Operator access scoped: grant `alter any symmetric key` / `alter any column encryption key` only to authorised personnel
- [ ] Monitoring alert configured if a key drop fails
- [ ] DPO or compliance officer signed off on the procedure
