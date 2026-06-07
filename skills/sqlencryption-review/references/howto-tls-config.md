# How to Configure TLS for SQL Server

Step-by-step guide for enforcing TLS 1.2/1.3 encryption on SQL Server, from certificate procurement through client-side verification.

## Prerequisites

- SQL Server 2016+ (TLS 1.2); SQL Server 2022+ (TLS 1.3)
- Windows Server 2016+ or Windows 10+ with latest updates
- A domain-joined machine with access to an AD CS enterprise CA, or the ability to purchase from a public CA
- Local administrator rights on the SQL Server host
- `sysadmin` fixed server role on the SQL Server instance

## Step 1: Obtain a CA-Signed Certificate

### Option A: Request from Active Directory Certificate Services

1. Open the Certificates MMC snap-in for the computer account:

   ```cmd
   certlm.msc
   ```

2. Expand **Personal**, right-click **Certificates**, select **All Tasks > Request New Certificate**.
3. In the Certificate Enrollment wizard, choose the **Computer** template (or a custom template with Server Authentication EKU).
4. Set the common name (CN) to the fully qualified domain name clients use to connect, e.g. `sql01.contoso.com`.
5. Under the **Subject** tab, add the FQDN as a `dns` SAN entry. If the server uses an alias or Availability Group listener, add those as additional SAN entries.
6. Complete the enrollment. The certificate appears under **Personal > Certificates** with a private key.

### Option B: Purchase from a Public CA

1. Generate a certificate signing request (CSR):

   ```powershell
   $csr = New-SelfSignedCertificate -DnsName "sql01.contoso.com" `
       -CertStoreLocation "Cert:\LocalMachine\My" `
       -KeyExportPolicy Exportable -KeySpec KeyExchange
   ```

2. Right-click the generated certificate, select **All Tasks > Export**, and export without the private key as a base-64 encoded CSR file.
3. Submit the CSR to your public CA (DigiCert, Let's Encrypt, etc.).
4. Import the issued certificate via `certlm.msc` into **Personal > Certificates**. The private key must be on the server — if the CSR was generated elsewhere, import the private key separately.

## Step 2: Install the Certificate on the SQL Server

If the certificate was obtained via AD CS (Option A), it is already installed. For a public CA certificate received as a `.pfx` or `.p12`:

```cmd
certlm.msc
```

Right-click **Personal > Certificates**, select **All Tasks > Import**, and follow the wizard. Mark the key as exportable if you need to move it later.

Verify the certificate has a private key:

```powershell
Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.HasPrivateKey } | Format-List Subject, Thumbprint, NotAfter
```

## Step 3: Bind the Certificate in SQL Server Configuration Manager

1. Open **SQL Server Configuration Manager**.
2. Expand **SQL Server Network Configuration**, right-click **Protocols for `<instance>`**, and select **Properties**.
3. Select the **Certificate** tab. In the dropdown, choose the certificate by FQDN.
4. If the dropdown is empty, verify:
   - The certificate is in `Cert:\LocalMachine\My`.
   - The SQL Server service account has `Read` permission on the private key.
   - The certificate has the **Server Authentication (1.3.6.1.5.5.7.3.1)** enhanced key usage.
5. Click **OK**, then restart the SQL Server service:

   ```powershell
   Restart-Service -Name "MSSQLSERVER" -Force
   ```

## Step 4: Enable Force Encryption

Navigate to the **Flags** tab in SQL Server Network Configuration > Protocols for `<instance>` > Properties. Set **Force Encryption** to **Yes**.

Alternatively, for a named instance or headless configuration, add the registry value:

```powershell
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\<InstanceId>\MSSQLServer\SuperSocketNetLib" `
    -Name "ForceEncryption" -Value 1 -Type DWord
```

Restart SQL Server. After restart, all connections are encrypted. Unencrypted clients are rejected.

## Step 5: Disable Legacy TLS Versions

Disable TLS 1.0 and TLS 1.1 via the registry to prevent downgrade attacks:

```powershell
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
foreach ($version in @("TLS 1.0", "TLS 1.1")) {
    foreach ($role in @("Client", "Server")) {
        $keyPath = "$regPath\$version\$role"
        New-Item -Path $keyPath -Force | Out-Null
        Set-ItemProperty -Path $keyPath -Name "Enabled" -Value 0 -Type DWord
        Set-ItemProperty -Path $keyPath -Name "DisabledByDefault" -Value 1 -Type DWord
    }
}
```

Enable TLS 1.2:

```powershell
$keyPath = "$regPath\TLS 1.2\Server"
New-Item -Path $keyPath -Force | Out-Null
Set-ItemProperty -Path $keyPath -Name "Enabled" -Value 1 -Type DWord
Set-ItemProperty -Path $keyPath -Name "DisabledByDefault" -Value 0 -Type DWord
```

Reboot the server for registry changes to take effect.

## Step 6: Configure Strong Cipher Suites

Limit the cipher suite list to strong, forward-secret suites:

```powershell
$cipherOrder = @(
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256"
)
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002" `
    -Name "Functions" -PropertyType String -Value ($cipherOrder -join ",") -Force
```

The order matters — the first cipher the client supports is negotiated. Reboot after setting.

## Step 7: Enable TLS 1.3 (SQL Server 2022+)

SQL Server 2022 (16.x) on Windows Server 2022 supports TLS 1.3. Enable it:

```powershell
$keyPath = "$regPath\TLS 1.3\Server"
New-Item -Path $keyPath -Force | Out-Null
Set-ItemProperty -Path $keyPath -Name "Enabled" -Value 1 -Type DWord
Set-ItemProperty -Path $keyPath -Name "DisabledByDefault" -Value 0 -Type DWord
```

TLS 1.3 uses its own cipher suites independent of Step 6. The OS manages them automatically. Reboot after enabling.

## Step 8: Test the TLS Configuration

### From a remote client with OpenSSL

```cmd
openssl s_client -connect sql01.contoso.com:1433 -tls1_2
```

Or for TLS 1.3:

```cmd
openssl s_client -connect sql01.contoso.com:1433 -tls1_3
```

Verify the output shows `Verify return code: 0 (ok)` and the negotiated version.

### From a remote client with nmap

```cmd
nmap --script ssl-enum-ciphers -p 1433 sql01.contoso.com
```

Confirm only TLS 1.2/1.3 are listed and cipher suites match the configured set.

### Confirm SQL Server loaded the certificate

```sql
SELECT local_net_address, local_tcp_port, encrypt_option
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
```

Check the SQL Server error log for a startup message confirming the certificate thumbprint:

```powershell
Get-Content "C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\ERRORLOG" | Select-String "certificate"
```

### Verify TLS inside SQL Server

```sql
SELECT session_id, encrypt_option
FROM sys.dm_exec_connections;
```

`encrypt_option = TRUE` means the connection is encrypted.

## Step 9: Update Application Connection Strings

Add or update the encryption parameters in connection strings:

**ODBC / OLE DB / SqlClient (.NET):**

```
Server=sql01.contoso.com;Database=MyDB;Encrypt=Yes;TrustServerCertificate=No;
```

**JDBC:**

```
jdbc:sqlserver://sql01.contoso.com:1433;database=MyDB;encrypt=true;trustServerCertificate=false;
```

Key settings:

| Parameter | Value | Purpose |
|---|---|---|
| `Encrypt` / `encrypt` | `Yes` / `true` | Require TLS from the client side |
| `TrustServerCertificate` / `trustServerCertificate` | `No` / `false` | Validate the certificate chain against trusted CAs |

If the SQL Server certificate is signed by an internal CA, ensure the CA root certificate is installed in the client's **Trusted Root Certification Authorities** store.

## Common Errors

| Error | Likely Cause |
|---|---|
| Certificate dropdown empty in Config Manager | Missing Server Authentication EKU, or service account lacks private key read permission |
| `SSL Provider: The certificate chain was issued by an authority that is not trusted` | Client does not trust the CA that issued the certificate |
| `SSL Provider: The target principal name is incorrect` | Connection string server name does not match certificate CN or SAN |
| `The server was not found or was not accessible` with Force Encryption enabled | Client is not sending encrypted handshake; check `Encrypt=Yes` |
| TLS 1.3 not negotiated (SQL 2022) | Windows Server 2022 required for TLS 1.3 on the host; verify registry keys in Step 7 |

## Checklist

- [ ] CA-signed certificate with Server Authentication EKU in `Cert:\LocalMachine\My`
- [ ] Certificate CN/SAN matches the FQDN clients use (include AG listener names if applicable)
- [ ] SQL Server service account has `Read` permission on the certificate private key
- [ ] Certificate selected in SQL Server Configuration Manager, Certificate tab
- [ ] Force Encryption set to Yes
- [ ] TLS 1.0 and 1.1 disabled via registry on server and clients
- [ ] Strong cipher suites configured (ECDHE + AES-GCM preferred)
- [ ] TLS 1.3 enabled for SQL Server 2022+ on Windows Server 2022
- [ ] Server rebooted after registry changes
- [ ] OpenSSL and nmap tests pass: only TLS 1.2/1.3, expected cipher suites
- [ ] `sys.dm_exec_connections` confirms `encrypt_option = TRUE`
- [ ] All connection strings updated with `Encrypt=Yes;TrustServerCertificate=No;`
- [ ] Internal CA root certificate deployed to client trust stores
