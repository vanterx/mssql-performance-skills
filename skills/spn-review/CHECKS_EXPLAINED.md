# SPN Review — Checks Explained

Plain-English explanations for all 30 K-checks (K1–K30) in `/spn-review`.

---

## Kerberos Ticket Flow and The Double-Hop Problem

### How Kerberos Authentication Works for SQL Server

When a client connects to SQL Server with Windows Authentication, the protocol proceeds in three steps:

1. **Client obtains a Ticket-Granting Ticket (TGT)** — The client contacts the Key Distribution Center (KDC, which runs on a Domain Controller) and proves its identity. The KDC issues a TGT encrypted with the KDC's own key.
2. **Client requests a service ticket** — The client presents its TGT to the KDC and asks for a service ticket for `MSSQLSvc/<host>:<port>`. The KDC looks up which AD account holds a matching `ServicePrincipalName` attribute. It encrypts the service ticket with that account's password hash.
3. **Client presents the service ticket to SQL Server** — SQL Server decrypts it using its service account's password hash. If decryption succeeds, SQL Server trusts the client's identity. No password ever crosses the network.

**Why the SPN must exist:** If the KDC cannot find any account with a matching `ServicePrincipalName`, it cannot issue a service ticket. The client falls back to NTLM (if allowed) or the connection fails with "The target principal name is incorrect."

### The Double-Hop Problem

```
Client → SQL Server A (hop 1, Kerberos OK)
              ↓
         SQL Server B (hop 2, FAILS)
```

When a client connects to SQL Server A using Kerberos, the KDC issues a service ticket for SQL A's SPN. That ticket proves the client's identity to SQL A — but it is not forwardable by default. When SQL A then tries to connect to SQL Server B on behalf of the client, it has no ticket to present. SQL B sees SQL A's machine identity, not the original client's identity.

This is the **double-hop problem** — Kerberos tickets cannot be forwarded without explicit delegation configuration.

**Why NTLM does not have this problem (but also cannot solve it):** NTLM uses a challenge/response mechanism — no tickets are involved, so there is no forwarding barrier. However, NTLM only passes the machine or service identity downstream, not the original client identity. If the downstream system needs to know *who the client is* (for row-level security, audit trails, or permission checks), NTLM is not a substitute for properly configured Kerberos delegation.

---

## AD Objects Involved in SPN and Delegation

| AD object | Attribute | Role |
|-----------|-----------|------|
| AD User account (service account) | `servicePrincipalName` | Holds the SPNs the KDC looks up to issue service tickets |
| AD User account (service account) | `TrustedForDelegation` | Unconstrained delegation — the service can forward credentials to any service |
| AD User account (service account) | `TrustedToAuthForDelegation` | Protocol transition (S4U2Self) — service can obtain forwardable tickets for users who authenticated via non-Kerberos means |
| AD User account (service account) | `msDS-AllowedToDelegateTo` | Constrained delegation (KCD) — lists specific target SPNs to which this account may delegate |
| AD User account (connecting user) | `AccountNotDelegated` | Marks this user's tickets as non-forwardable regardless of server delegation config |
| AD User account (connecting user) | `memberOf: Protected Users` | Disables delegation, RC4 encryption, and NTLM for this user unconditionally |
| AD Computer account | `servicePrincipalName` | Auto-registered SPNs when SQL Server runs as NETWORK SERVICE or LOCAL SYSTEM |
| AD Computer account | `TrustedForDelegation` | Unconstrained delegation for all services running on that host |
| AD Computer account (target) | `msDS-AllowedToActOnBehalfOfOtherIdentity` | RBCD — the target controls which accounts may impersonate callers toward it |

### Three Delegation Models

| Model | Where configured | AD attribute | Security posture | Use case |
|-------|-----------------|-------------|-----------------|---------|
| Unconstrained | Service account or computer | `TrustedForDelegation` | Low — can forward to any service | Legacy only; flag Critical always |
| Constrained (KCD) | Service account | `msDS-AllowedToDelegateTo` | Medium — specific target SPNs only | Linked servers, SSRS, middle-tier apps |
| Resource-based (RBCD) | Target computer | `msDS-AllowedToActOnBehalfOfOtherIdentity` | Best — target controls access | Modern environments (Windows Server 2012 R2+) |

---

## Kerberos Encryption Types

Kerberos tickets are encrypted. The client, KDC, and target service must share a supported encryption type or authentication fails before SQL Server ever sees the connection.

| Type | Strength | Notes |
|------|----------|-------|
| AES256-CTS-HMAC-SHA1-96 | Strongest | Default and preferred on Windows Server 2008 R2+ |
| AES128-CTS-HMAC-SHA1-96 | Strong | Fallback when AES256 is unavailable |
| RC4-HMAC | Weak | Legacy; disabled by default on Windows Server 2022+ and Windows 11 |
| DES-CBC-MD5 / DES-CBC-CRC | Obsolete | Disabled since Windows 7 / Server 2008 R2 |

**Negotiation:** The KDC and client negotiate the strongest type both support. If the type set on the target service account (`msDS-SupportedEncryptionTypes`) does not overlap with what the client or KDC allows, the ticket request fails.

**Protected Users group (K27, K30):** Members are restricted to AES128/AES256 only — RC4 is unconditionally disabled for them. If any component in the authentication chain (old OS, legacy GPO, service account configured for RC4-only) requires RC4, Protected Users members fail authentication entirely.

**Windows Server 2022 / Windows 11 change:** RC4 is disabled by default. Service accounts that were never explicitly configured with AES keys may fail on these platforms. Fix: `Set-ADUser <account> -KerberosEncryptionType AES256,AES128`.

**GPO control:** `Computer Configuration → Windows Settings → Security Settings → Local Policies → Security Options → Network security: Configure encryption types allowed for Kerberos`. Restrictive policies on domain controllers directly gate which types the KDC will use.

**Diagnostic:** `klist` shows the negotiated encryption type per cached ticket. If you see RC4 on a Windows Server 2022 domain controller, investigate the GPO and account encryption settings.

---

## Reading klist Output

`klist` (run on the client machine as the connecting user) is the primary tool to verify whether a Kerberos ticket was issued and whether it is forwardable.

```
klist

Current LogonId is 0:0x4a3f12

Cached Tickets: (2)

#0>     Client: jsmith @ CONTOSO.COM
        Server: krbtgt/CONTOSO.COM @ CONTOSO.COM
        KerbTicket Encryption Type: AES-256-CTS-HMAC-SHA1-96
        Ticket Flags 0x40e10000 -> forwardable forwarded renewable initial pre-authent
        Start Time: 5/13/2026 9:00:01 (local)
        End Time:   5/13/2026 19:00:01 (local)
        Renew Time: 5/20/2026 9:00:01 (local)

#1>     Client: jsmith @ CONTOSO.COM
        Server: MSSQLSvc/SQLNODE1.contoso.com:1433 @ CONTOSO.COM
        KerbTicket Encryption Type: AES-256-CTS-HMAC-SHA1-96
        Ticket Flags 0x40a10000 -> forwardable renewable pre-authent
        Start Time: 5/13/2026 9:01:15 (local)
        End Time:   5/13/2026 19:00:01 (local)
```

**Ticket #0** is the Ticket-Granting Ticket (TGT) — issued by the KDC to prove the user's identity. **Ticket #1** is the service ticket for SQL Server — issued only when the SPN exists in AD.

**Ticket flag meanings:**

| Flag | Meaning | Diagnostic significance |
|------|---------|------------------------|
| `forwardable` | Ticket can be forwarded by the receiving service | Required for KCD and RBCD delegation |
| `forwarded` | This ticket was obtained via delegation | Confirms delegation actually worked end-to-end |
| `renewable` | Ticket can be refreshed without re-entering credentials | Normal for TGTs; 7-day default |
| `pre-authent` | Client used Kerberos pre-authentication | Absent signals a weak KDC configuration |
| `ok-as-delegate` | KDC confirms the target service is trusted for delegation | Must be set for KCD to work |

**What to look for:**

- **Service ticket absent entirely** → SPN not found in AD (K1–K6, K12); run `setspn -Q MSSQLSvc/<hostname>:<port>`
- **`forwardable` absent on the service ticket** → user in Protected Users (K27) or `AccountNotDelegated = True` (K26)
- **Encryption type is RC4 on Windows Server 2022** → RC4 disabled; check GPO and service account encryption types
- **`ok-as-delegate` absent** → target service account is not trusted for delegation; check K19/K21 configuration
- **Ticket expiry < 4 hours** → user is likely in Protected Users (K27) — Protected Users limits ticket lifetime to 4 hours non-renewable

**Testing workflow:**
```powershell
klist purge          # Clear cached tickets to force fresh acquisition
# Re-attempt the connection
klist               # Verify the new service ticket and its flags
```

---

## Windows Security Event IDs for Kerberos Failures

When Kerberos fails, the Domain Controller writes events to its Security event log. These are the authoritative source of failure reasons — they show exactly which step failed and why.

| Event ID | Logged on | Trigger | Key field to check |
|----------|-----------|---------|-------------------|
| 4768 | DC | TGT request (client authenticating to domain) | `Result Code` |
| 4769 | DC | Service ticket request (client requesting ticket for SQL Server) | `Result Code` |
| 4771 | DC | Pre-authentication failure | `Failure Code` |

**Critical result codes for SQL/SPN diagnosis (Event 4769):**

| Code | Meaning | Related check |
|------|---------|---------------|
| `0x0` | Success | — |
| `0x7` KDC_ERR_S_PRINCIPAL_UNKNOWN | SPN not found in AD | K1–K6, K12 |
| `0xC` KDC_ERR_BADOPTION | Delegation not permitted (user or service) | K19, K26, K27 |
| `0x1F` KRB_AP_ERR_SKEW | Clock skew > 5 minutes between client and DC | Not an SPN issue |
| `0x12` KDC_ERR_CLIENT_REVOKED | Account disabled, locked, or expired | Not an SPN issue |
| `0x17` KDC_ERR_KEY_EXPIRED | Password expired | Not an SPN issue |
| `0x22` KDC_ERR_CLIENT_NOT_TRUSTED | Smart card required or not trusted | Not an SPN issue |

**How to query from PowerShell (run on the DC or with DC access):**
```powershell
Get-WinEvent -ComputerName DC01 -FilterHashtable @{
    LogName = 'Security'
    Id      = 4769
    StartTime = (Get-Date).AddHours(-1)
} | Where-Object { $_.Message -like '*MSSQLSvc*' } |
    Select-Object TimeCreated, Message | Format-List
```

**Clock skew note:** Kerberos requires all participating machines to be within 5 minutes of DC time. SQL Server hosts using an incorrect NTP source or with no time sync commonly fail with `0x1F`. This is not an SPN problem — fix time synchronization first, then re-test authentication.

---

## SQL Server ERRORLOG SPN Signals

SQL Server writes several distinct messages when SPN registration fails or when Kerberos authentication is rejected. These are the primary indicators visible without accessing the DC.

| ERRORLOG message pattern | Meaning | Related check |
|--------------------------|---------|---------------|
| `could not register the Service Principal Name (SPN) [...] Windows return code: 0x2098` | Service account lacks Write SPN permission | K18 |
| `Error: 17806, Severity: 20, State: 14 — SSPI handshake failed` | SQL Server received a Kerberos token it could not decrypt — SPN is on the wrong account or duplicate exists | K7, K8 |
| `Error: 17807, Severity: 20 — SSPI lookup failed` | Client could not obtain a Kerberos service ticket — SPN missing | K1, K2 |
| `Error: 17832, Severity: 20 — Unable to read login packet` | Network or SSPI negotiation failure during login | K5, K7 |
| `Error: 17836, Severity: 20 — Length specified in network packet payload did not match number of bytes read` | Corrupt or mismatched Kerberos token; often wrong SPN key | K7, K8 |
| `The target principal name is incorrect` | Client's SPN lookup failed | K1–K6, K8 |

**Note:** Error 18456 "Login failed" with `auth_scheme = Kerberos` in `sys.dm_exec_connections` means Kerberos authentication *succeeded* — but the domain account has no SQL Server login. This is a permissions issue, not an SPN problem.

**How to extract from ERRORLOG:**
```powershell
Get-Content "C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\ERRORLOG" |
    Select-String "SPN|SSPI|17806|17807|17832|17836|principal name"
```

Cross-reference: `/errorlog-review` check E22 surfaces login failure bursts that may have SPN misconfig as root cause.

---

## setspn -A vs -S: Avoiding Duplicate SPNs

The `setspn` command has two modes for adding SPNs. Using the wrong one is the most common cause of K8 (Duplicate SPN):

```powershell
# DANGEROUS — adds without checking for duplicates across the domain
setspn -A MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc

# SAFE — checks domain-wide for an existing identical SPN before adding
setspn -S MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc
```

**`-A` behavior:** Adds the SPN to the account unconditionally, even if the same SPN already exists on another account. The duplicate is invisible until `setspn -X` is run or Kerberos authentication breaks.

**`-S` behavior:** Searches the entire domain for a matching SPN first. If a duplicate would be created, it prints a warning and refuses to add. Available since Windows Server 2008 R2.

**Safe SPN workflow:**
```powershell
# 1. Check if SPN already exists anywhere in domain
setspn -Q MSSQLSvc/SQLNODE1:1433

# 2. If clean, add with duplicate protection
setspn -S MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc
setspn -S MSSQLSvc/SQLNODE1.contoso.com:1433 CONTOSO\sqlsvc

# 3. Confirm no duplicates were introduced
setspn -X
```

Never use `-A` in production. If legacy scripts use `-A`, replace them with `-S`.

---

## Loopback Connections and Kerberos

Loopback connections occur when SQL Server connects to itself — SQL Server Agent jobs, SSIS packages running on the SQL host, `OPENQUERY` to `(local)`, maintenance scripts, or linked servers pointing back to the same instance. Windows Kerberos loopback detection blocks these by default.

**Symptom:** Kerberos works for remote client connections but fails for connections originating from the SQL Server host itself. `sys.dm_exec_connections` shows `auth_scheme = 'NTLM'` for these sessions.

**Cause:** Windows checks whether the target hostname resolves to the local machine. If it does, Windows refuses to issue a Kerberos service ticket (loopback restriction — mitigates NTLM relay and reflection attacks). This is a security feature, not a bug.

**This is not an SPN problem.** The SPN may be perfectly correct; it is the loopback detection that prevents the ticket from being issued.

**Resolution options:**

| Option | Registry setting | Security impact |
|--------|-----------------|----------------|
| Disable loopback check entirely | `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\DisableLoopbackCheck = 1` (DWORD) | Reduces protection against reflection attacks — use only if BackConnectionHostNames is not feasible |
| Whitelist specific hostnames | `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0\BackConnectionHostNames` (REG_MULTI_SZ) — add each hostname that needs loopback Kerberos | Preferred — scoped to specific names only |

A restart is required after either registry change.

**Alternative:** Reconfigure the loopback connection to use a service account login (SQL auth) or Windows auth with explicit credentials rather than pass-through Kerberos — this avoids the loopback restriction entirely for administrative jobs.

Related check: K20 (NTLM Fallback Signal).

---

### K1 — Missing Default-Instance SPN

**What it means:** The SQL Server default instance (always on port 1433) has no SPN registered for its hostname. The KDC has nothing to look up when a client requests a Kerberos ticket for this SQL Server.

**How to spot it:** Run `setspn -Q MSSQLSvc/*` and look for entries matching the SQL Server hostname. If neither `MSSQLSvc/<hostname>:1433` nor `MSSQLSvc/<hostname.domain.com>:1433` appears, the SPN is missing.

**Example:**
```
setspn -Q MSSQLSvc/*
-- Expected output showing missing SPN:
Checking domain DC=contoso,DC=com
No such SPN found.
-- Or output shows only other hosts, not SQLNODE1
```

**Fix options:**
1. `setspn -S MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc`
2. `setspn -S MSSQLSvc/SQLNODE1.contoso.com:1433 CONTOSO\sqlsvc`
3. Verify in SQL Server Configuration Manager that TCP/IP is enabled and port 1433 is the static port

**Related checks:** K3, K4, K5, K7

---

### K2 — Missing Named-Instance SPN

**What it means:** A named SQL instance (e.g., `SQL2019\PROD`) uses a dynamic TCP port that changes unless configured as static. The SPN must use the actual port number, not the instance name.

**How to spot it:** Identify the instance's TCP port in SQL Server Configuration Manager → SQL Server Network Configuration → Protocols for INSTANCENAME → TCP/IP → IP Addresses → IPAll → TCP Port. Then verify that `setspn -Q MSSQLSvc/*` shows `MSSQLSvc/<hostname>:<that port>`.

**Example:**
```
-- Instance SQL2019\PROD runs on dynamic port 49200
-- Missing SPN scenario:
setspn -Q MSSQLSvc/SQLNODE1*
-- Returns only:
MSSQLSvc/SQLNODE1:1433   (this is the default instance SPN, not the named instance)
-- Named instance SPN MSSQLSvc/SQLNODE1:49200 is absent
```

**Fix options:**
1. Set a static port for the named instance in SQL Server Configuration Manager (prevents SPN breakage on service restart)
2. `setspn -S MSSQLSvc/SQLNODE1:49200 CONTOSO\sqlsvc` (and the FQDN variant)

**Related checks:** K5, K13, K14

---

### K3 — Missing FQDN SPN

**What it means:** Only the NetBIOS short-hostname SPN exists. Clients that specify the fully-qualified domain name (FQDN) in their connection string — for example, `Server=SQLNODE1.contoso.com,1433` — request a Kerberos ticket for `MSSQLSvc/SQLNODE1.contoso.com:1433`. If that SPN does not exist, the KDC cannot satisfy the request.

**How to spot it:** `setspn -L DOMAIN\sqlsvc` lists only `MSSQLSvc/SQLNODE1:1433` but not `MSSQLSvc/SQLNODE1.contoso.com:1433`.

**Example:**
```
setspn -L CONTOSO\sqlsvc
Registered ServicePrincipalNames for CN=sqlsvc,OU=ServiceAccounts,DC=contoso,DC=com:
    MSSQLSvc/SQLNODE1:1433
-- FQDN variant is absent
```

**Fix options:**
1. `setspn -S MSSQLSvc/SQLNODE1.contoso.com:1433 CONTOSO\sqlsvc`
2. Ensure clients connecting via FQDN can succeed with Kerberos; NTLM fallback may mask this gap

**Related checks:** K1, K4, K11

---

### K4 — Missing Short-Hostname SPN

**What it means:** The complement of K3. Only the FQDN SPN exists. Clients using NetBIOS name in their connection string — `Server=SQLNODE1,1433` — request a ticket for `MSSQLSvc/SQLNODE1:1433`, which is absent.

**How to spot it:** `setspn -L DOMAIN\sqlsvc` shows `MSSQLSvc/SQLNODE1.contoso.com:1433` but not `MSSQLSvc/SQLNODE1:1433`.

**Example:**
```
setspn -L CONTOSO\sqlsvc
Registered ServicePrincipalNames for CN=sqlsvc,OU=ServiceAccounts,DC=contoso,DC=com:
    MSSQLSvc/SQLNODE1.contoso.com:1433
-- Short-hostname variant is absent
```

**Fix options:**
1. `setspn -S MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc`
2. Standardize client connection strings to use FQDN if adding the short-hostname SPN is not feasible

**Related checks:** K1, K3

---

### K5 — SPN on Wrong Port

**What it means:** An SPN exists but its port does not match the port SQL Server is actually listening on. The SPN is useless — clients requesting a ticket for the real port get no match.

**How to spot it:** Compare the port in `setspn -Q MSSQLSvc/<hostname>*` against the actual TCP port in SQL Server Configuration Manager. A common cause is a port change after the SPN was registered, or registering port 1433 for a named instance.

**Example:**
```
-- setspn -Q output shows:
MSSQLSvc/SQLNODE1:1433
-- But SQL Server Configuration Manager shows named instance PROD on port 49200
-- The SPN MSSQLSvc/SQLNODE1:1433 will never match a connection to SQLNODE1\PROD
```

**Fix options:**
1. `setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc`
2. `setspn -S MSSQLSvc/SQLNODE1:49200 CONTOSO\sqlsvc`
3. Configure a static port in SQL Server Configuration Manager to prevent future drift

**Related checks:** K2, K13

---

### K6 — Missing VNN SPN for FCI

**What it means:** In a SQL Server Failover Cluster Instance (FCI), clients connect to a Virtual Network Name (VNN) — a DNS name that always points to whichever node currently owns the cluster group. The SPN must be registered for the VNN, not the physical node names.

**How to spot it:** The FCI virtual server name appears in connection strings and in the SQL Server instance name. `setspn -Q MSSQLSvc/<VNN>*` returns no results.

**Example:**
```
-- FCI virtual server name: SQLFCI01 (not SQLNODE1 or SQLNODE2)
setspn -Q MSSQLSvc/SQLFCI01*
-- Returns: No such SPN found
-- Physical node SPNs may exist but are irrelevant
```

**Fix options:**
1. `setspn -S MSSQLSvc/SQLFCI01:1433 CONTOSO\sqlsvc`
2. `setspn -S MSSQLSvc/SQLFCI01.contoso.com:1433 CONTOSO\sqlsvc`
3. Confirm VNN name from Windows Failover Cluster Manager → Role → SQL Server resource → resource name

**Related checks:** K1, K12

---

### K7 — SPN on Wrong Account

**What it means:** SQL Server's service account is `CONTOSO\sqlsvc`, but the MSSQLSvc SPN is registered on `CONTOSO\oldsqlsvc` or another account. SQL Server cannot decrypt the service ticket because it uses `sqlsvc`'s password, not `oldsqlsvc`'s password.

**How to spot it:** `setspn -Q MSSQLSvc/<hostname>:<port>` returns an account that does not match what SQL Server Configuration Manager shows as the service account.

**Example:**
```
setspn -Q MSSQLSvc/SQLNODE1:1433
Checking domain DC=contoso,DC=com
CN=sqlsvc_old,OU=ServiceAccounts,DC=contoso,DC=com
    MSSQLSvc/SQLNODE1:1433
-- SQL Server is now running as CONTOSO\sqlsvc_new, which has no SPN
```

**Fix options:**
1. `setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc_old`
2. `setspn -S MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc_new`
3. Verify the current service account in SQL Server Configuration Manager before registering

**Related checks:** K8, K10

---

### K8 — Duplicate SPN

**What it means:** The same SPN is registered on two or more AD accounts. The KDC does not know which account's key to use when encrypting the service ticket. Every Kerberos authentication to that SQL Server fails with "The target principal name is incorrect" until the duplicate is removed.

**How to spot it:** `setspn -X` produces a list of all duplicates across the domain. Any line showing `MSSQLSvc/<hostname>:<port>` with multiple accounts is a K8 trigger.

**Example:**
```
setspn -X
Processing entry 1
MSSQLSvc/SQLNODE1:1433
   CONTOSO\sqlsvc      CN=sqlsvc,OU=ServiceAccounts,DC=contoso,DC=com
   CONTOSO\oldsqlsvc   CN=oldsqlsvc,OU=ServiceAccounts,DC=contoso,DC=com
found 1 group of duplicate SPNs.
```

**Fix options:**
1. Identify which account is the current SQL Server service account (SQL Server Configuration Manager)
2. `setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\oldsqlsvc` — remove from the wrong account
3. Confirm with `setspn -Q MSSQLSvc/SQLNODE1:1433` that only one account remains

**Related checks:** K7, K9, K10, K28

---

### K9 — SPN Under Computer Account

**What it means:** When SQL Server runs as NETWORK SERVICE or LOCAL SYSTEM, Windows auto-registers SPNs on the machine (computer) account. If the service is later changed to a domain account but the computer account still holds the old SPN, you have a K8 (duplicate) scenario where the service account has the SPN and so does the computer account.

**How to spot it:** `setspn -L <COMPUTERNAME>$` (note the dollar sign for computer accounts) shows `MSSQLSvc/<hostname>:<port>` entries alongside what `setspn -L DOMAIN\sqlsvc` also shows.

**Example:**
```
setspn -L SQLNODE1$
Registered ServicePrincipalNames for CN=SQLNODE1,OU=Servers,DC=contoso,DC=com:
    MSSQLSvc/SQLNODE1.contoso.com:1433
    MSSQLSvc/SQLNODE1:1433
-- These same SPNs are also on CONTOSO\sqlsvc — duplicate
```

**Fix options:**
1. `setspn -D MSSQLSvc/SQLNODE1:1433 SQLNODE1$` (remove from computer account)
2. `setspn -D MSSQLSvc/SQLNODE1.contoso.com:1433 SQLNODE1$`
3. Consider disabling auto-SPN registration via registry key `DisableLoopbackCheck` or service configuration

**Related checks:** K8, K28

---

### K10 — Stale SPN from Old Account

**What it means:** After a service account change, SPNs from the previous account were not cleaned up. The stale SPNs are functionally equivalent to K7 (wrong account) and will cause K8 (duplicate) if the new account also has SPNs.

**How to spot it:** `setspn -Q MSSQLSvc/<hostname>:<port>` or `setspn -X` shows SPNs on an account whose name includes words like "old", "backup", "legacy", or a former employee's name, or that account is disabled in AD.

**Example:**
```
setspn -Q MSSQLSvc/SQLNODE1:1433
CN=sqlsvc_2021,OU=DisabledAccounts,DC=contoso,DC=com
    MSSQLSvc/SQLNODE1:1433
-- Account is disabled but SPN still registered
```

**Fix options:**
1. `setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc_2021`
2. Purge all `MSSQLSvc` SPNs from the old account: `setspn -A <check -L output>` then `-D` each
3. Establish a runbook for SPN cleanup as part of service account rotation

**Related checks:** K7, K8

---

### K11 — MSA/gMSA Auto-Registration Gap

**What it means:** Managed Service Accounts (MSA) and group Managed Service Accounts (gMSA) can automatically register SPNs, but the auto-registration sometimes creates only the short-hostname variant, leaving the FQDN variant absent. Clients using FQDN in connection strings will fall back to NTLM.

**How to spot it:** `Get-ADServiceAccount <name> -Properties ServicePrincipalNames` shows `MSSQLSvc/SQLNODE1:1433` but not `MSSQLSvc/SQLNODE1.contoso.com:1433`.

**Example:**
```
Get-ADServiceAccount sqlgmsa -Properties ServicePrincipalNames | Select-Object -ExpandProperty ServicePrincipalNames
MSSQLSvc/SQLNODE1:1433
RestrictedKrbHost/SQLNODE1
-- FQDN variant MSSQLSvc/SQLNODE1.contoso.com:1433 is absent
```

**Fix options:**
1. `setspn -S MSSQLSvc/SQLNODE1.contoso.com:1433 CONTOSO\sqlgmsa$` (note dollar sign for MSA/gMSA)
2. Verify both SPN variants after any MSA/gMSA password rotation

**Related checks:** K3, K4

---

### K12 — Missing AG Listener SPN

**What it means:** Always On Availability Group listeners have their own DNS name (e.g., `AGLISTEN01`), separate from the replica node names. Clients connect to the listener name, and Kerberos ticket requests specify `MSSQLSvc/AGLISTEN01:1433`. If no SPN for the listener name exists, Kerberos fails for listener connections even if the replica node SPNs are correct.

**How to spot it:** Identify the listener name from SQL Server Management Studio → Always On Availability Groups → Availability Group Listeners. Then `setspn -Q MSSQLSvc/<listener-name>*` returns no results.

**Example:**
```
-- Listener name: AGLISTEN01
setspn -Q MSSQLSvc/AGLISTEN01*
Checking domain DC=contoso,DC=com
No such SPN found.
-- Node-level SPNs exist but listener SPN is absent
```

**Fix options:**
1. `setspn -S MSSQLSvc/AGLISTEN01:1433 CONTOSO\sqlsvc` (register on each replica's service account if they differ)
2. `setspn -S MSSQLSvc/AGLISTEN01.contoso.com:1433 CONTOSO\sqlsvc`
3. If replicas use different service accounts, register on all accounts or on the primary's account and update after failover

**Related checks:** K6, K16

---

### K13 — Named Instance Using Port 1433

**What it means:** Port 1433 is reserved for the default SQL Server instance. A named instance using port 1433 in its SPN is incorrect — the named instance runs on a different port. This SPN will either be a duplicate of the default instance SPN or will simply never match a named instance connection.

**How to spot it:** `setspn -Q MSSQLSvc/<hostname>:1433` returns results, but the SQL Server instance is a named instance (the instance name appears in connection strings as `SQLNODE1\INSTANCENAME`).

**Example:**
```
-- Named instance: SQLNODE1\PROD running on port 49200
setspn -L CONTOSO\sqlsvc
    MSSQLSvc/SQLNODE1:1433   (WRONG — 1433 is for default instances only)
    -- Correct SPN should be MSSQLSvc/SQLNODE1:49200
```

**Fix options:**
1. `setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc`
2. Determine actual named instance port from SQL Server Configuration Manager
3. `setspn -S MSSQLSvc/SQLNODE1:49200 CONTOSO\sqlsvc`

**Related checks:** K2, K5

---

### K14 — Missing SQL Browser Signal

**What it means:** Named SQL instances use the SQL Browser service to map instance names to port numbers for clients that don't specify the port explicitly in their connection string. If SQL Browser is not running, client connections specifying `SQLNODE1\PROD` (without the explicit port) fail before Kerberos even comes into play.

**How to spot it:** No explicit confirmation that SQL Browser is running was provided. This is an informational signal — the check cannot conclusively fail without evidence that Browser is stopped.

**Example:**
```powershell
Get-Service SQLBrowser
-- Status: Stopped (this would confirm the issue)
-- Or: not present in the output provided
```

**Fix options:**
1. `Start-Service SQLBrowser` and `Set-Service SQLBrowser -StartupType Automatic`
2. If clients always specify the explicit port in the connection string, SQL Browser is not required — document this as intentional

**Related checks:** K2, K13

---

### K15 — Alias Without SPN

**What it means:** A SQL Server alias (configured in SQL Server Configuration Manager or `cliconfg.exe`) maps a friendly name (e.g., `SQLPROD`) to the real hostname and port. Kerberos ticket requests use the alias name in the SPN lookup, not the resolved hostname. If no SPN exists for the alias name, Kerberos fails for alias-based connections.

**How to spot it:** A SQL alias is mentioned in the input (connection string, application config, or cliconfg output), and `setspn -Q MSSQLSvc/<alias-name>*` returns no results.

**Example:**
```
-- Alias: SQLPROD → SQLNODE1.contoso.com:1433
setspn -Q MSSQLSvc/SQLPROD*
No such SPN found.
-- Clients connecting via alias "SQLPROD" will fall back to NTLM
```

**Fix options:**
1. `setspn -S MSSQLSvc/SQLPROD:1433 CONTOSO\sqlsvc`
2. Alternatively, configure the alias at the driver level to pass the real hostname (avoiding the alias SPN requirement) if alias transparency is acceptable

**Related checks:** K1, K12

---

### K16 — Multi-Subnet AG Single-IP SPN

**What it means:** In a multi-subnet Always On AG, the listener DNS record has IP addresses in multiple subnets. Clients on different subnets may resolve the listener to different IPs or DNS aliases. A single SPN covering only one hostname form may not satisfy all clients.

**How to spot it:** The AG listener configuration (from SSMS or `sys.availability_group_listeners`) shows `IP_ADDRESS_COUNT > 1` and the client connection string uses a specific hostname that may differ from the canonical listener name.

**Example:**
```
-- AG listener AGLISTEN01 has IPs in two subnets:
-- Subnet A: 10.1.0.50 (DNS: AGLISTEN01)
-- Subnet B: 10.2.0.50 (DNS: AGLISTEN01-DR)
-- Only MSSQLSvc/AGLISTEN01:1433 is registered
-- Clients on Subnet B connecting via AGLISTEN01-DR will fall back to NTLM
```

**Fix options:**
1. `setspn -S MSSQLSvc/AGLISTEN01-DR:1433 CONTOSO\sqlsvc`
2. Ensure SPN covers all DNS names that clients may use to reach the listener
3. Use `MultiSubnetFailover=True` in connection strings alongside the proper SPN coverage

**Related checks:** K12, K6

---

### K17 — HTTP SPN Missing

**What it means:** Delegation to Reporting Services (SSRS) or a web service over HTTP requires an HTTP SPN on the target service account. Without it, Kerberos cannot issue a service ticket for the HTTP endpoint, and the delegation chain breaks at the HTTP hop.

**How to spot it:** SSRS or a linked server over HTTP is described, and `setspn -Q HTTP/<hostname>*` returns no results for the relevant service account.

**Example:**
```
-- SSRS runs on SSRSNODE1
setspn -Q HTTP/SSRSNODE1*
No such SPN found.
-- Kerberos delegation from SQL Server to SSRS will fail
```

**Fix options:**
1. `setspn -S HTTP/SSRSNODE1 CONTOSO\svcSSRS`
2. `setspn -S HTTP/SSRSNODE1.contoso.com CONTOSO\svcSSRS`
3. Verify IIS/SSRS Kerberos configuration in rsreportserver.config (RSWindowsNegotiate must be listed)

**Related checks:** K21, K22

---

### K18 — SPN Registration Permission Gap

**What it means:** By default, only Domain Admins can write the `ServicePrincipalName` attribute on AD objects. If the SQL service account is granted Self-Write SPN permission, it can register its own SPNs. Without this permission, automated or self-registration attempts fail silently, leaving the SPN absent.

**How to spot it:** The service account consistently lacks SPNs despite the SQL Server service starting, or error 17806/17807 events in the SQL Server ERRORLOG mention SPN registration failure.

**Example:**
```
-- ERRORLOG entry indicating permission gap:
The SQL Server Network Interface library could not register the Service Principal Name (SPN)
[ MSSQLSvc/SQLNODE1.contoso.com:1433 ] for the SQL Server service.
Windows return code: 0x2098, state: 15.
```

**Fix options:**
1. Grant Self-Write SPN: use ADSI Edit → find the service account → Properties → Security → Add permission: Self / Write ServicePrincipalName
2. Or have a Domain Admin run `setspn -S` manually and document a process for SPN updates on port changes
3. Check ERRORLOG after granting permission to confirm SQL Server registers SPNs on next start

**Related checks:** K1, K2

---

### K19 — Unconstrained Delegation Enabled

**What it means:** When `TrustedForDelegation = True`, the service account can forward any user's credentials to any service in the domain, without restriction. This is a severe security risk — if the SQL Server host is compromised, an attacker could impersonate any domain user against any service.

**How to spot it:** `Get-ADUser DOMAIN\sqlsvc -Properties TrustedForDelegation` returns `TrustedForDelegation: True`.

**Example:**
```powershell
Get-ADUser CONTOSO\sqlsvc -Properties TrustedForDelegation
TrustedForDelegation : True   # Critical — must be removed
```

**Fix options:**
1. In AD Users and Computers: service account → Properties → Delegation tab → select "Trust this user for delegation to specified services only (Kerberos only)" or "Do not trust this user for delegation"
2. Populate `msDS-AllowedToDelegateTo` with only the required target SPNs (this implements KCD — see K21)
3. Audit which applications rely on the broad delegation before removing; most legitimate use cases can be replaced with KCD

**Related checks:** K21, K25, K29

---

### K20 — NTLM Fallback Signal

**What it means:** NTLM authentication is being used despite SPNs appearing to exist. This is an informational signal — it does not mean SPNs are wrong, but it warrants investigation. Common causes: the client connection string uses a hostname or IP that does not exactly match any registered SPN; SQL Server encryption settings force a different target name; or the client is behind a load balancer with a virtual IP.

**How to spot it:** `sys.dm_exec_connections` shows `auth_scheme = 'NTLM'` for connections that should be using Kerberos. Or application logs show NTLM in use.

**Example:**
```sql
SELECT session_id, auth_scheme, net_transport, client_net_address
FROM sys.dm_exec_connections
WHERE auth_scheme = 'NTLM';
-- Shows connections that should be Kerberos
```

**Fix options:**
1. Compare the connection string hostname against `setspn -L DOMAIN\sqlsvc` — they must match exactly (case-insensitive, character-for-character)
2. If clients connect via IP address, Kerberos requires either an SPN with the IP (uncommon) or using a hostname instead
3. Check `SQLSERVERAGENT` and linked server connection strings for NTLM usage

**Related checks:** K1, K3, K4, K5, K7

---

### K21 — Constrained Delegation Not Configured

**What it means:** A double-hop scenario requires the middle-tier SQL Server (or application service) to forward the client's identity to a downstream service. Without KCD configuration, the middle-tier cannot obtain a forwarded ticket, and the downstream service sees the machine identity rather than the client identity.

**How to spot it:** `Get-ADUser DOMAIN\sqlsvc -Properties msDS-AllowedToDelegateTo` returns an empty list, or the delegation tab in AD Users and Computers shows "Do not trust this user for delegation."

**Example:**
```powershell
Get-ADUser CONTOSO\sqlsvc -Properties msDS-AllowedToDelegateTo
msDS-AllowedToDelegateTo : {}   # Empty — KCD not configured
```

**Fix options:**
1. Open AD Users and Computers → find service account → Properties → Delegation → "Trust this user for delegation to specified services only (Kerberos only)" → Add target SPNs
2. Add each target SPN: `MSSQLSvc/TARGETSERVER:1433` for each downstream SQL Server
3. Verify target SPNs exist before adding them here (see K22)

**Related checks:** K22, K23, K25, K19

---

### K22 — Delegation Target Missing SPN

**What it means:** KCD lists the SPNs that the service account may delegate to, but one or more of those target SPNs does not exist on any AD account. The KDC cannot issue a ticket for a non-existent SPN, causing delegation to fail silently.

**How to spot it:** `Get-ADUser DOMAIN\sqlsvc -Properties msDS-AllowedToDelegateTo` shows target SPNs, then verify each one with `setspn -Q <target-spn>`. If any returns "No such SPN found," K22 fires.

**Example:**
```powershell
Get-ADUser CONTOSO\sqlsvc -Properties msDS-AllowedToDelegateTo
msDS-AllowedToDelegateTo : {MSSQLSvc/SQLBACK01:1433, MSSQLSvc/SQLBACK01.contoso.com:1433}

setspn -Q MSSQLSvc/SQLBACK01:1433
No such SPN found.   # Critical — delegation target does not exist
```

**Fix options:**
1. Register the missing SPN on the target service account: `setspn -S MSSQLSvc/SQLBACK01:1433 CONTOSO\sqlback_svc`
2. Then re-test delegation; the KDC evaluates delegation at authentication time, not at configuration time

**Related checks:** K21, K1, K2

---

### K23 — Protocol Transition Not Enabled

**What it means:** Some middle-tier applications authenticate users via non-Kerberos mechanisms (NTLM, forms authentication, certificates) and then need to impersonate those users toward a backend SQL Server. Protocol transition (S4U2Self) allows the service to obtain a forwardable Kerberos ticket for any user — but only if `TrustedToAuthForDelegation` is set on the service account.

**How to spot it:** `Get-ADUser DOMAIN\svcaccount -Properties TrustedToAuthForDelegation` returns `False`, but the application requires delegation for non-Kerberos-authenticated users.

**Example:**
```powershell
Get-ADUser CONTOSO\svcSSRS -Properties TrustedToAuthForDelegation
TrustedToAuthForDelegation : False   # S4U2Self not enabled
# SSRS users who authenticate via forms will not have forwardable tickets
```

**Fix options:**
1. In AD Users and Computers → service account → Properties → Delegation → select "Trust this user for delegation to specified services only (Use any authentication protocol)"
2. This enables S4U2Self; combine with KCD (K21) to specify the target services

**Related checks:** K21, K24

---

### K24 — RBCD Misconfigured

**What it means:** Resource-Based Constrained Delegation (RBCD) is a modern alternative to KCD. Instead of configuring delegation on the initiating service account, the target computer controls who may delegate to it via `msDS-AllowedToActOnBehalfOfOtherIdentity`. If the initiating account is not in that ACL, delegation fails.

**How to spot it:** `Get-ADComputer <target> -Properties msDS-AllowedToActOnBehalfOfOtherIdentity` is populated, but the initiating service account's SID is absent from the security descriptor.

**Example:**
```powershell
$acl = (Get-ADComputer SQLBACK01 -Properties msDS-AllowedToActOnBehalfOfOtherIdentity).msDS-AllowedToActOnBehalfOfOtherIdentity
$acl.Access
# Shows only CONTOSO\webserver — but CONTOSO\sqlsvc is not listed
# SQL Server trying to delegate to SQLBACK01 will fail
```

**Fix options:**
1. `Set-ADComputer SQLBACK01 -PrincipalsAllowedToDelegateToAccount @((Get-ADUser CONTOSO\sqlsvc),(Get-ADComputer CONTOSO\webserver))`
2. Verify the initiating account has an SPN (required for RBCD to work)
3. RBCD requires Windows Server 2012 R2+ domain controllers

**Related checks:** K21, K23

---

### K25 — Delegation Scope Too Broad

**What it means:** The service account's `msDS-AllowedToDelegateTo` includes SPNs beyond what is needed for SQL Server access — for example, `cifs/*` (file shares), `host/*` (all Kerberos services on a host), or `RPCSS/*`. Broad delegation grants reduce the security benefit of constrained delegation.

**How to spot it:** `Get-ADUser DOMAIN\sqlsvc -Properties msDS-AllowedToDelegateTo` shows entries beyond `MSSQLSvc/*` for the specific required target servers.

**Example:**
```powershell
Get-ADUser CONTOSO\sqlsvc -Properties msDS-AllowedToDelegateTo
msDS-AllowedToDelegateTo : {
    MSSQLSvc/SQLBACK01:1433,
    MSSQLSvc/SQLBACK01.contoso.com:1433,
    cifs/FILESERVER01,       # Not needed for SQL delegation
    host/SQLBACK01           # Overly broad — grants all Kerberos services on that host
}
```

**Fix options:**
1. Remove non-MSSQLSvc entries from the delegation list in AD Users and Computers → Delegation tab
2. Keep only the specific SPNs required for the documented double-hop path
3. Document the delegation requirements so future changes don't re-add broad entries

**Related checks:** K19, K21

---

### K26 — Connecting User Delegation-Sensitive

**What it means:** Even when the SQL Server service account is perfectly configured for delegation, the connecting user's AD settings can block it. `AccountNotDelegated = True` marks the user's Kerberos tickets as non-forwardable, preventing any service from delegating on their behalf.

**How to spot it:** `Get-ADUser <user> -Properties AccountNotDelegated` returns `True` for users experiencing delegation failures.

**Example:**
```powershell
Get-ADUser jsmith -Properties AccountNotDelegated
AccountNotDelegated : True   # This user's credentials cannot be delegated
# Even with perfect KCD config, delegation will fail for jsmith
```

**Fix options:**
1. If delegation is intentional for this user: `Set-ADUser jsmith -AccountNotDelegated $false`
2. If the user must remain delegation-sensitive, use RBCD on the target — RBCD uses S4U2Proxy which does not require the user's ticket to be forwardable
3. Review security policy — `AccountNotDelegated` is sometimes set on privileged accounts intentionally

**Related checks:** K27, K21

---

### K27 — User in Protected Users Group

**What it means:** The Protected Users security group disables NTLM authentication, RC4 and DES encryption, unconstrained delegation, and Kerberos ticket renewal beyond 4 hours for all members. A user in Protected Users cannot have their Kerberos ticket forwarded — the ticket is non-renewable and non-forwardable by design.

**How to spot it:** `Get-ADUser <user> -Properties MemberOf | Select-Object -ExpandProperty MemberOf` includes the `Protected Users` distinguished name.

**Example:**
```powershell
Get-ADGroupMember "Protected Users" | Where-Object { $_.Name -eq "jsmith" }
# jsmith is in Protected Users
# Kerberos delegation for jsmith will fail regardless of server configuration
```

**Fix options:**
1. Remove the user from Protected Users if delegation is required: `Remove-ADGroupMember "Protected Users" -Members jsmith`
2. Understand the implications: removing from Protected Users re-enables NTLM, RC4, and credential caching on domain controllers — evaluate the security tradeoff
3. If the user is an admin account, consider whether delegation should be required at all — admin accounts should rarely need to be delegated

**Related checks:** K26, K30

---

### K28 — Computer Account SPN Conflict

**What it means:** When SQL Server runs under a service account but the host computer account also holds MSSQLSvc SPNs (often a legacy from when the service ran as NETWORK SERVICE), both the service account and the computer account have the same SPN. This creates a K8 (duplicate) condition.

**How to spot it:** `setspn -L <COMPUTERNAME>$` shows MSSQLSvc SPNs, and the current service account also has them via `setspn -L DOMAIN\sqlsvc`.

**Example:**
```
setspn -L SQLNODE1$
    MSSQLSvc/SQLNODE1:1433
    MSSQLSvc/SQLNODE1.contoso.com:1433   # Duplicate of sqlsvc's SPNs

setspn -L CONTOSO\sqlsvc
    MSSQLSvc/SQLNODE1:1433
    MSSQLSvc/SQLNODE1.contoso.com:1433   # Both accounts hold the same SPNs
```

**Fix options:**
1. Choose the service account as the authoritative SPN owner (preferred for security isolation)
2. `setspn -D MSSQLSvc/SQLNODE1:1433 SQLNODE1$`
3. `setspn -D MSSQLSvc/SQLNODE1.contoso.com:1433 SQLNODE1$`
4. If SQL Server was previously running as NETWORK SERVICE, ensure Configuration Manager is updated to use the domain service account

**Related checks:** K8, K9

---

### K29 — Computer Account Unconstrained Delegation

**What it means:** `TrustedForDelegation = True` on a computer account means every service running on that host can forward any user's credentials to any service in the domain. This is the broadest possible delegation scope and a critical security risk.

**How to spot it:** `Get-ADComputer SQLNODE1 -Properties TrustedForDelegation` returns `True`.

**Example:**
```powershell
Get-ADComputer SQLNODE1 -Properties TrustedForDelegation
TrustedForDelegation : True   # Critical — entire host can forward any credential
```

**Fix options:**
1. In AD Users and Computers → computer object → Properties → Delegation → change from "Trust this computer for delegation to any service (Kerberos only)" to "Trust this computer for delegation to specified services only" or "Do not trust this computer for delegation"
2. Populate the allowed services list with only the required target SPNs
3. If SQL Server is the only service requiring delegation from this host, use RBCD on the target instead — more secure and does not require touching the host computer account

**Related checks:** K19, K21, K25

---

### K30 — Service Account in Protected Users

**What it means:** If the SQL Server service account itself is in the Protected Users group, Kerberos authentication for the SQL Server service may break entirely. Protected Users disables delegation at the account level, prevents RC4 and DES, and restricts ticket lifetimes — these restrictions can prevent SQL Server from accepting Kerberos tickets from clients.

**How to spot it:** `Get-ADGroupMember "Protected Users"` includes the SQL Server service account name.

**Example:**
```powershell
Get-ADGroupMember "Protected Users" | Where-Object { $_.Name -eq "sqlsvc" }
# sqlsvc is in Protected Users
# SQL Server cannot use delegation; clients may fail Kerberos authentication to the service
```

**Fix options:**
1. Remove the service account from Protected Users immediately: `Remove-ADGroupMember "Protected Users" -Members sqlsvc`
2. Restart the SQL Server service after removing (Kerberos settings are evaluated at service startup)
3. Review why the service account was added to Protected Users — if it was a mistake, document the correction; if intentional, understand that this prevents all delegation scenarios

**Related checks:** K27, K19, K21

---

## Quick Reference — All K1–K30 Checks

| Check | Name | AD Object Type | Severity |
|-------|------|---------------|---------|
| K1 | Missing Default-Instance SPN | Service account | Critical |
| K2 | Missing Named-Instance SPN | Service account | Critical |
| K3 | Missing FQDN SPN | Service account | Warning |
| K4 | Missing Short-Hostname SPN | Service account | Warning |
| K5 | SPN on Wrong Port | Service account | Critical |
| K6 | Missing VNN SPN for FCI | Service account | Critical |
| K7 | SPN on Wrong Account | Service account | Critical |
| K8 | Duplicate SPN | Multiple accounts | Critical |
| K9 | SPN Under Computer Account | Computer account | Warning |
| K10 | Stale SPN from Old Account | Former service account | Warning |
| K11 | MSA/gMSA Auto-Registration Gap | Managed service account | Info |
| K12 | Missing AG Listener SPN | Service account | Critical |
| K13 | Named Instance Using Port 1433 | Service account | Critical |
| K14 | Missing SQL Browser Signal | Host service | Info |
| K15 | Alias Without SPN | Service account | Warning |
| K16 | Multi-Subnet AG Single-IP SPN | Service account | Warning |
| K17 | HTTP SPN Missing | Application service account | Warning |
| K18 | SPN Registration Permission Gap | Service account (AD permission) | Warning |
| K19 | Unconstrained Delegation Enabled | Service account | Critical |
| K20 | NTLM Fallback Signal | Service account / client | Info |
| K21 | Constrained Delegation Not Configured | Service account | Critical |
| K22 | Delegation Target Missing SPN | Target service account | Critical |
| K23 | Protocol Transition Not Enabled | Service account | Warning |
| K24 | RBCD Misconfigured | Target computer account | Warning |
| K25 | Delegation Scope Too Broad | Service account | Info |
| K26 | Connecting User Delegation-Sensitive | End-user account | Critical |
| K27 | User in Protected Users Group | End-user account | Critical |
| K28 | Computer Account SPN Conflict | Computer account | Warning |
| K29 | Computer Account Unconstrained Delegation | Computer account | Critical |
| K30 | Service Account in Protected Users | Service account | Critical |
