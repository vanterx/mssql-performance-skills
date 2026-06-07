# SQL Server Encryption — Error Reference

Troubleshooting guide for common SQL Server encryption errors. Each entry covers the error message text, root cause, and step-by-step resolution. For algorithm and key-hierarchy background, see `concepts.md`.

---

## Msg 33111 — Cannot Find Server Certificate with Thumbprint

**Message:**
```
Msg 33111, Level 16, State 1
Cannot find server certificate with thumbprint '<thumbprint>'.
```

**Cause:** The certificate specified in the SQL Server Configuration Manager (Protocols → Properties → Certificate tab) was removed from the Windows certificate store, or the certificate was imported to the wrong store location (e.g., Current User instead of Local Machine).

**Resolution:**
1. Identify the expected thumbprint in the SQL Server error log:
   ```sql
   -- Check ERRORLOG for the thumbprint SQL Server tried to load
   exec xp_readerrorlog 0, 1, 'thumbprint';
   ```
2. Verify the certificate exists in the correct store:
   ```powershell
   Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object Thumbprint -eq '<thumbprint>'
   ```
3. If missing, re-import from backup (.pfx) and ensure the SQL Server service account has read permission on the private key.
4. Restart the SQL Server service.

---

## Msg 33104 — Cannot Decrypt Database Encryption Key

**Message:**
```
Msg 33104, Level 16, State 1
Cannot decrypt the database encryption key.
```

**Cause:** The TDE certificate or asymmetric key used to encrypt the Database Encryption Key (DEK) is unavailable. Common scenarios: the certificate was accidentally dropped, the `master` database was restored from a different server without restoring the certificate, or the certificate was created with a different name/thumbprint than the one protecting the DEK.

**Resolution:**
1. If you have a backup of the certificate and private key:
   ```sql
   -- Restore the certificate from backup
   CREATE CERTIFICATE TDECert FROM FILE = 'C:\Backups\TDECert.cer'
   WITH PRIVATE KEY (FILE = 'C:\Backups\TDECert.pvk',
        DECRYPTION BY PASSWORD = '<private_key_password>');
   ```
2. Confirm the DEK can now be decrypted by opening the database (`alter database ... set online`).
3. If the certificate backup is lost, the database is unrecoverable — this is why check A3 (TDE certificate backup) is Critical.
4. Always export the certificate immediately after enabling TDE:
   ```sql
   BACKUP CERTIFICATE TDECert TO FILE = 'C:\Backups\TDECert.cer'
   WITH PRIVATE KEY (FILE = 'C:\Backups\TDECert.pvk',
        ENCRYPTION BY PASSWORD = '<strong_password>');
   ```

---

## Msg 15581 — Cannot Find Certificate

**Message:**
```
Msg 15581, Level 16, State 1
Cannot find the certificate, because it does not exist or you do not have permission.
```

**Cause:** A certificate referenced by a `CREATE/ALTER CERTIFICATE` or `ENCRYPTBYCERT` operation does not exist in the database, or the caller lacks `VIEW DEFINITION` permission. Frequently seen during backup restore or certificate rotation scripts when the name does not match.

**Resolution:**
1. Check whether the certificate exists:
   ```sql
   SELECT name, certificate_id, pvt_key_encryption_type_desc
   FROM sys.certificates WHERE name = '<cert_name>';
   ```
2. Grant permission if missing:
   ```sql
   GRANT VIEW DEFINITION ON CERTIFICATE :: <cert_name> TO <login>;
   ```
3. If the certificate was lost with the database restore, restore it from backup as shown under Msg 33104.

---

## Msg 33081 — Cannot Find Cryptographic Provider

**Message:**
```
Msg 33081, Level 16, State 1
Cannot find the cryptographic provider '<provider_name>'.
```

**Cause:** An EKM (Extensible Key Management) provider DLL is not registered, or the provider was removed from `sys.cryptographic_providers`. Can also occur after a SQL Server upgrade if the provider DLL does not support the new version.

**Resolution:**
1. List registered providers:
   ```sql
   SELECT provider_id, name, guid, version
   FROM sys.cryptographic_providers;
   ```
2. Re-register the provider if missing:
   ```sql
   CREATE CRYPTOGRAPHIC PROVIDER <provider_name>
   FROM FILE = '<path_to_dll>';
   ```
3. For Azure Key Vault, check the AKV connector is installed. For third-party HSM providers (Thales, Entrust, Utimaco), verify the DLL path is correct and accessible to the SQL Server service account.
4. After an upgrade, reinstall the EKM provider DLL matching the new SQL Server major version.

---

## Msg 15318 — Operand Type Clash (Always Encrypted)

**Message:**
```
Msg 15318, Level 16, State 1
Operand type clash: <type1> is incompatible with <type2>.
```

**Cause (Always Encrypted context):** The application passes a value whose SQL Server type does not match the column's encryption type. The client driver encrypts the value and sends a ciphertext blob; the server rejects it because the underlying type is incompatible. Common with deterministic vs. randomized mismatch, or when the driver sends `varbinary` to a `varchar(encrypted)` column.

**Resolution:**
1. Verify the column encryption type matches the parameter:
   ```sql
   SELECT name, encryption_type_desc
   FROM sys.columns c
   JOIN sys.column_encryption_keys k ON c.column_encryption_key_id = k.column_encryption_key_id
   WHERE c.encryption_type IS NOT NULL;
   ```
2. In the application connection string, ensure `Column Encryption Setting=enabled` is present.
3. Use the correct SqlParameter type in .NET (e.g., `SqlDbType.VarChar` for string columns, not `SqlDbType.VarBinary`).
4. For deterministic encryption columns, ensure the input collation (`... COLLATE Latin1_General_BIN2`) matches the column definition.

---

## Self-Generated TLS Certificate Warning

**Message:**
```
INFO: A self-generated certificate was successfully loaded for encryption.
```

**Cause:** SQL Server could not find a configured certificate in Configuration Manager, so it auto-generated a self-signed certificate. This is not an error, but it means TLS connections will require `TrustServerCertificate=True` in the connection string, and clients cannot validate the server's identity.

**Resolution:**
1. Provision a proper certificate with the server's FQDN in the Subject or SAN field. Use an internal CA (AD CS) or a public CA.
2. Import it to `Cert:\LocalMachine\My` and grant the SQL Server service account read permission on the private key.
3. In SQL Server Configuration Manager, open Protocols → Properties → Certificate tab and select the new certificate.
4. Restart the SQL Server service.
5. Verify with:
   ```powershell
   Test-NetConnection -ComputerName <server> -Port 1433
   ```

---

## SQL Server Audit Fails to Start

**Message:**
```
Msg 33217, Level 16, State 1
SQL Server Audit '<audit_name>' could not start. Check the SQL Server error log.
```

**Cause (encryption-related):** When the audit destination is a file and permission on the file path is insufficient, or when the audit is configured with an audit filter that references an encrypted column. Also occurs if the audit log file destination directory does not exist or the service account lacks write permission.

**Resolution:**
1. Check the ERRORLOG for the specific failure reason:
   ```sql
   exec xp_readerrorlog 0, 1, 'audit';
   ```
2. Verify folder permissions — the SQL Server service account must have `Write` and `Modify` on the audit destination folder.
3. Ensure the destination folder is on a local drive (not a mapped network drive).
4. If using an audit filter on Always Encrypted columns, move the filter to the application layer; encrypted-column values are not available server-side for filtering.
5. Restart the audit:
   ```sql
   ALTER SERVER AUDIT <audit_name> WITH (STATE = ON);
   ```

---

## EKM Provider Errors

**Message:**
```
Msg 33184, Level 16, State 1
The EKM provider key is not found.
```

**Cause:** The EKM provider (Azure Key Vault, HSM, or third-party) does not have the expected key or the key was deleted/rotated outside of SQL Server. Often occurs after manually deleting a key in the Azure portal without updating SQL Server references.

**Resolution:**
1. Verify the key path and credential are correct:
   ```sql
   SELECT c.name AS credential_name, k.name AS key_name, k.key_path
   FROM sys.credentials c
   JOIN sys.asymmetric_keys k ON c.credential_id = CAST(k.sid AS uniqueidentifier);
   ```
2. For Azure Key Vault, verify the key exists in the vault and the SQL Server credential matches the latest version. Rotate the credential if the key was replaced:
   ```sql
   ALTER CRYPTOGRAPHIC PROVIDER <provider_name> DISABLE;
   ALTER CRYPTOGRAPHIC PROVIDER <provider_name> ENABLE;
   ```
3. Check network connectivity to the EKM provider endpoint (AKV URL, HSM appliance IP).
4. For on-premises HSM, verify the HSM management agent is running and reachable from the SQL Server host.

---

## Enclave Attestation Errors

**Message (varies):**
```
Msg 33173, Level 16, State 1
The enclave attestation URL '<url>' is unreachable or returned an error.
```

**Cause:** The Host Guardian Service (HGS) attestation endpoint is unreachable from the SQL Server host, the attestation protocol is misconfigured, or the attestation certificate has expired. This prevents Always Encrypted enclave operations (rich computations, in-place encryption).

**Resolution:**
1. Test connectivity to the attestation URL from the SQL Server host:
   ```powershell
   Invoke-WebRequest -Uri "http://<hgs_server>/attestation/protocolversion" -UseBasicParsing
   ```
   The response should be `<ProtocolVersion>1.0</ProtocolVersion>`.
2. Check the HGS attestation certificate expiry date on the HGS server:
   ```powershell
   Get-HgsAttestationHttpsEndpoint
   ```
3. Verify the SQL Server host is registered with HGS as a guarded host.
4. Re-register if needed:
   ```powershell
   Set-HgsClientConfiguration -AttestationServerUrl 'http://<hgs_server>/attestation'
   ```
5. Restart the SQL Server service after fixing connectivity.

---

## TLS Handshake Errors

**Message (client-side):**
```
A connection was successfully established with the server, but then an error occurred during the pre-login handshake.
```

**Cause:** Mismatch between client and server TLS versions or cipher suites. Common when the server enforces TLS 1.2+ but the client uses an older driver or OS version that negotiates TLS 1.0. Also occurs when the server certificate is self-signed and the client does not have `TrustServerCertificate=True`.

**Resolution:**
1. Verify the server's TLS configuration in the Windows registry:
   ```
   HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols
   ```
   Check that at least one TLS 1.2 server subkey has `Enabled=1` and `DisabledByDefault=0`, and TLS 1.0/1.1 are disabled.
2. Update the client driver or OS patch level to support TLS 1.2+. Minimum versions:
   - SQL Server Native Client 11.0.7462.6+
   - Microsoft ODBC Driver 17+
   - .NET Framework 4.6.2+
3. If using `TrustServerCertificate=True`, replace with a proper CA-issued certificate as soon as possible.
4. Use `nmap` to verify the server's TLS offering:
   ```
   nmap --script ssl-enum-ciphers -p 1433 <server>
   ```
5. For pre-login handshake failures before TLS negotiation is attempted, check that the SQL Browser service is running (if using named instances) and that Windows Firewall allows port 1433 (or the instance-specific port).

---

## Quick Reference

| Error | Cause | First Step |
|-------|-------|------------|
| Msg 33111 | Certificate missing from store | Check `Cert:\LocalMachine\My` for thumbprint |
| Msg 33104 | TDE DEK cannot be decrypted | Restore certificate from backup |
| Msg 15581 | Certificate not found or no permission | Query `sys.certificates` |
| Msg 33081 | EKM provider not registered | Check `sys.cryptographic_providers` |
| Msg 15318 | AE type mismatch | Verify column `encryption_type_desc` |
| Self-generated TLS cert | No configured server certificate | Import proper CA cert, select in Config Manager |
| Audit fails to start | Path permissions or AE filter | Check ERRORLOG, verify folder write permissions |
| EKM provider key not found | Key deleted or rotated externally | Check `sys.credentials` + provider connectivity |
| Enclave attestation unreachable | HGS network or cert issue | Test `Invoke-WebRequest` to attestation URL |
| TLS handshake failure | Version/cipher mismatch | Verify SCHANNEL registry, update client driver |
