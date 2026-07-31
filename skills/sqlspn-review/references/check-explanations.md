# SPN Review — Checks Explained

## Contents

- [Kerberos Ticket Flow and The Double-Hop Problem](#kerberos-ticket-flow-and-the-double-hop-problem)
- [AD Objects Involved in SPN and Delegation](#ad-objects-involved-in-spn-and-delegation)
- [Kerberos Encryption Types](#kerberos-encryption-types)
- [Reading klist Output](#reading-klist-output)
- [Windows Security Event IDs for Kerberos Failures](#windows-security-event-ids-for-kerberos-failures)
- [SQL Server ERRORLOG SPN Signals](#sql-server-errorlog-spn-signals)
- [setspn -A vs -S: Avoiding Duplicate SPNs](#setspn--a-vs--s-avoiding-duplicate-spns)
- [Loopback Connections and Kerberos](#loopback-connections-and-kerberos)
- [MSSQLSvc SPN Presence Checks (K1–K6)](#mssqlsvc-spn-presence-checks-k1k6)
- [Service Account Binding Checks (K7–K11)](#service-account-binding-checks-k7k11)
- [AG Listener and Alias Checks (K12–K16)](#ag-listener-and-alias-checks-k12k16)
- [Configuration and Permissions Checks (K17–K20)](#configuration-and-permissions-checks-k17k20)
- [Kerberos Delegation — Service Account Checks (K21–K25)](#kerberos-delegation--service-account-checks-k21k25)
- [AD Account and Computer Sensitivity Checks (K26–K30)](#ad-account-and-computer-sensitivity-checks-k26k30)
- [Entra ID / Hybrid and Advanced Checks (K31–K40)](#entra-id--hybrid-and-advanced-checks-k31k40)
- [Double-Hop Platform Constraints (K41–K44)](#double-hop-platform-constraints-k41k44)
- [Kerberos Environment Prerequisites (K45–K48)](#kerberos-environment-prerequisites-k45k48)
- [SQL Server on Linux Kerberos (K49–K51)](#sql-server-on-linux-kerberos-k49k51)
- [Client Driver and Service State (K52–K54)](#client-driver-and-service-state-k52k54)
- [Quick Reference — All K1–K54 Checks](#quick-reference--all-k1k54-checks)

---


Plain-English explanations for all 54 K-checks (K1–K54) in `/sqlspn-review`.

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

Cross-reference: `/sqlerrorlog-review` check E22 surfaces login failure bursts that may have SPN misconfig as root cause.

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

## MSSQLSvc SPN Presence Checks (K1–K6)

### K1 — Missing Default-Instance SPN

**What it means:** The SQL Server default instance (conventionally on port 1433) has no SPN registered for its hostname. The KDC has nothing to look up when a client requests a Kerberos ticket for this SQL Server.

Which form the client asks for depends on the protocol, not on whether a port appears in the connection string. Over TCP the client builds `MSSQLSvc/<FQDN>:<port>`. Over a protocol other than TCP — named pipes or shared memory — it builds the portless `MSSQLSvc/<FQDN>`. Both forms should exist so either transport can use Kerberos. Microsoft's documented SPN formats are:

| SPN format | When it is used |
|------------|-----------------|
| `MSSQLSvc/<FQDN>:<port>` | The provider-generated default when TCP is used, for both named and default instances |
| `MSSQLSvc/<FQDN>` | The provider-generated default for a **default instance** when a protocol other than TCP is used |
| `MSSQLSvc/<FQDN>:<instancename>` | The provider-generated default for a **named instance** when a protocol other than TCP is used |

The port number is not itself mandatory — a multi-port server, or a protocol that does not use ports, can still authenticate with Kerberos. But where the TCP port *is* included in the SPN, the TCP protocol has to be enabled on the instance for Kerberos to work.

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

**What it means:** A named SQL instance (e.g., `SQL2019\PROD`) uses a dynamic TCP port that changes unless configured as static. Two SPN forms are valid and both should be registered: `MSSQLSvc/<FQDN>:<port>` for TCP clients, and `MSSQLSvc/<FQDN>:<instancename>` for clients arriving over named pipes or shared memory. Registering only the port form leaves non-TCP connections on NTLM; registering only the instance-name form leaves TCP connections on NTLM.

If the instance is still on a dynamic port, fix that first — see K44. A port that changes on restart cannot be represented by a stable SPN at all.

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

## Service Account Binding Checks (K7–K11)

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

## AG Listener and Alias Checks (K12–K16)

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
1. `setspn -S MSSQLSvc/AGLISTEN01.contoso.com:1433 CONTOSO\sqlsvc` — register **once**, using the service account of the instances that host the availability replicas. A domain administrator has to do this; SQL Server does not auto-register listener SPNs
2. Register the short-name form as well: `setspn -S MSSQLSvc/AGLISTEN01:1433 CONTOSO\sqlsvc`
3. Confirm the prerequisite first: for one SPN to work across every replica, **all instances in the WSFC cluster hosting the availability group must run under the same service account**. If they do not, fix the service accounts rather than registering the same SPN on several of them — that produces the duplicate SPN in K8, and the KDC rejects every ticket for the listener
4. If the listener uses a port other than 1433, put that port in the SPN and in the client connection string (`Server=tcp:AGLISTEN01,1445`)

**Related checks:** K6, K8, K16, K36

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

## Configuration and Permissions Checks (K17–K20)

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
1. `setspn -S HTTP/SSRSNODE1.contoso.com CONTOSO\svcSSRS` — HTTP SPNs carry **no port**, unlike `MSSQLSvc`
2. `setspn -S HTTP/SSRSNODE1 CONTOSO\svcSSRS` — register the NetBIOS form too; the host portion must match the name used in the browser URL, which you can confirm on the Web Portal URL tab of Report Server Configuration Manager
3. Place the SPN on the identity the service actually runs under. A domain user account needs it registered manually. A Virtual Service Account or `NETWORK SERVICE` runs in the machine account's context, whose HOST SPN already covers HTTP — no manual SPN unless a virtual or load-balanced URL is used, in which case register it on the machine account
4. Verify `RSWindowsNegotiate` is present and first in `<AuthenticationTypes>` in `rsreportserver.config` — see K54
5. Watch for collateral damage: an HTTP SPN grants tickets to every application running in `HTTP.SYS` on that host, including IIS-hosted ones. Either run them all under the same account, or give each a host header with its own SPN

**Related checks:** K21, K22, K54

---

### K18 — SPN Registration Permission Gap

**What it means:** When the Database Engine starts it tries to register its SPN automatically, calling the `DsWriteAccountSpn` API. That call succeeds only if the startup account holds `Read servicePrincipalName` and `Write servicePrincipalName` rights in Active Directory. When it fails, SQL Server logs a warning to both the SQL Server error log and the Application event log — and then **carries on starting**, so nothing about the service state signals the problem. The same happens in reverse at shutdown, when deregistration fails.

Which identity you are running under decides whether this is a problem at all. Built-in accounts (`Local System`, `NETWORK SERVICE`), virtual accounts, managed service accounts and group managed service accounts can all register an SPN themselves. A plain domain user account generally cannot, unless it has been granted the rights explicitly — and Microsoft grants them on the **SQL Server computer object**, not on the service account's own user object.

**How to spot it:** The service account consistently lacks SPNs despite the SQL Server service starting cleanly, or the SQL Server error log records an SPN registration failure at startup.

**Example:**
```
-- ERRORLOG entry indicating permission gap:
The SQL Server Network Interface library could not register the Service Principal Name (SPN)
[ MSSQLSvc/SQLNODE1.contoso.com:1433 ] for the SQL Server service.
Windows return code: 0x2098, state: 15.
```

**Fix options:**
1. Grant the rights on the **SQL Server computer object**, following Microsoft's documented steps: Active Directory Users and Computers → View → Advanced → Computers → the SQL Server computer → Properties → Security → Advanced. Add the SQL Server startup account if absent, then Edit and select **Validated write to service principal name** under Permissions, plus **Read servicePrincipalName** and **Write servicePrincipalName** under Properties
2. Or have a domain administrator run `setspn -S` manually, and document a process for re-registering when the TCP port or service account changes — manual registration means nothing updates itself
3. Consider switching the service to a virtual account, MSA or gMSA, all of which self-register and remove the whole class of problem
4. Check the SQL Server error log after the next restart to confirm registration now succeeds
5. Do not solve this by running SQL Server under a domain administrator account — that works, but Microsoft advises against it in production, and it triggers K39 via AdminSDHolder

**Related checks:** K1, K2, K11, K39

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

## Kerberos Delegation — Service Account Checks (K21–K25)

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

## AD Account and Computer Sensitivity Checks (K26–K30)

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

The protections arrive from two directions, and knowing which is which tells you whether the group is actually the cause:

| Scope | Requirement | What stops working |
|-------|-------------|--------------------|
| Device-side | User signs in to a Windows 8.1 / Windows Server 2012 R2 or later host | No cached plaintext credentials for CredSSP or Windows Digest, no cached NTLM NTOWF, no cached Kerberos long-term keys after the initial TGT, no offline sign-in |
| Domain-controller-side | Domain functional level Windows Server 2012 R2 or later | No NTLM authentication, no DES or RC4 in Kerberos preauthentication, **no delegation of any kind**, TGT capped at a non-renewable 4 hours |

A member signing in to a host older than Windows 8.1 gets no additional protection at all — which is a common source of confusion when the group appears to work for some users and not others.

**Fix options:**
1. Remove the user from Protected Users if delegation is required: `Remove-ADGroupMember "Protected Users" -Members jsmith`
2. Understand the implications: removing from Protected Users re-enables NTLM, RC4, and credential caching — evaluate the security trade-off before doing it
3. Do not expect RBCD to work around it. The restriction covers unconstrained *and* constrained delegation, so no delegation model is exempt
4. If the user is an admin account, question whether delegation should be involved at all — admin accounts should rarely be delegated
5. Confirm the diagnosis from the `ProtectedUserFailures-DomainController` operational log (disabled by default; enable under Applications and Services Logs → Microsoft → Windows → Authentication). Event 100 is an NTLM sign-in failure, event 104 a DES/RC4 preauthentication failure. `ProtectedUser-Client` event 104 shows the client-side equivalent
6. Consider Authentication Policies and Authentication Policy Silos as the more granular alternative — they apply at the same Windows Server 2012 R2 functional level and can restrict which hosts an account signs in from without disabling delegation wholesale

**Related checks:** K26, K30, K38

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

Microsoft's guidance here is unusually direct: *"Accounts for services and computers should not be members of the Protected Users group. This group provides no local protection because the password or certificate is always available on the host. Authentication will fail with the error 'the user name or password is incorrect' for any service or computer that is added to the Protected Users group."*

So this is not a trade-off to weigh — it is a misconfiguration with no upside. The account gains nothing, because the credential sits on the host regardless, and loses the ability to authenticate. The failure is certain rather than intermittent once the domain functional level reaches Windows Server 2012 R2.

**Fix options:**
1. Remove the service account from Protected Users immediately: `Remove-ADGroupMember "Protected Users" -Members sqlsvc`
2. Restart the SQL Server service afterwards so it re-acquires its Kerberos keys
3. Protect the account properly instead. Authentication Policies and Authentication Policy Silos are designed for exactly this and explicitly support the User, Computer, Managed Service Account and Group Managed Service Account classes — unlike Protected Users, which targets interactive user accounts
4. Audit for the same mistake elsewhere: `Get-ADGroupMember "Protected Users" | Where-Object { $_.objectClass -ne 'user' -or $_.Name -like '*svc*' }` is a rough first pass, but review the full membership by hand — any account backing a service or computer belongs out of the group

**Related checks:** K27, K19, K21, K38

---

## Entra ID / Hybrid and Advanced Checks (K31–K40)

### K31 — Azure AD Hybrid Join SPN Gap

**What it means:** In a hybrid Azure AD (Entra ID) joined environment, clients that authenticate via Kerberos still resolve SPNs through on-premises AD. If the SQL Server instance has no `MSSQLSvc/<host>:<port>` SPN in on-premises AD, hybrid-joined clients cannot obtain a Kerberos ticket for SQL Server.

**How to spot it:** Client receives "The target principal name is incorrect" or falls back to NTLM on a device that is Entra-hybrid joined; `setspn -Q MSSQLSvc/<host>:<port>` returns no results.

**Example:**
```powershell
setspn -Q MSSQLSvc/SQLNODE1:1433
# No results — SPN missing; hybrid-joined clients cannot authenticate with Kerberos
```

**Fix options:**
1. Register the SPN in on-premises AD: `setspn -S MSSQLSvc/SQLNODE1:1433 DOMAIN\sqlsvc` and `setspn -S MSSQLSvc/SQLNODE1.domain.com:1433 DOMAIN\sqlsvc`
2. Verify the on-premises AD is synced to Entra ID via Azure AD Connect — the SPN registration only needs to exist in on-premises AD for Kerberos to work on hybrid-joined devices

**Related checks:** K1, K3, K7

---

### K32 — Entra-Only Auth With Orphaned AD SPN

**What it means:** The SQL Server instance is configured for Azure AD–only authentication (no Windows logins), but a traditional Active Directory `MSSQLSvc` SPN still exists on the service account. This creates confusion — on-premises clients that attempt Kerberos will successfully obtain a ticket but then fail at the SQL Server login step because Windows authentication is disabled.

**How to spot it:** SQL Server configured with `EXTERNAL_PROVIDER`-only logins, yet `setspn -L DOMAIN\sqlsvc` shows `MSSQLSvc` SPNs.

**Fix options:**
1. Remove the orphaned SPN: `setspn -D MSSQLSvc/<host>:<port> DOMAIN\sqlsvc`
2. Document that the instance is Azure AD–only to prevent support teams from wasting time debugging Kerberos for Windows logins that cannot succeed regardless of SPN state

**Related checks:** K1, K7, K20

---

### K33 — Azure SQL MI Windows Authentication Flow Not Configured

**What it means:** Windows Authentication against Azure SQL Managed Instance does not work the way it does on-premises, and there is **no `MSSQLSvc` SPN to register in on-premises AD for a managed instance**. Microsoft Entra ID acts as its own independent Kerberos realm and issues the tickets. Two flows exist, and one of them has to be set up before Windows Authentication works at all:

- **Modern interactive flow** — for Microsoft Entra joined or Entra hybrid joined clients on Windows 10 20H1 / Windows Server 2022 or later. Clients are redirected to Microsoft Entra Kerberos through a KDC proxy, so they need no line of sight to a domain controller and no trust object is created in the customer's AD. Only works from an interactive session, so it covers SSMS and web applications but not services.
- **Incoming trust-based flow** — for AD joined clients on Windows 10 / Windows Server 2012 or later with line of sight to AD. A Trusted Domain Object is created in the customer's AD and registered in Microsoft Entra ID.

Both require Active Directory to be synchronised to Microsoft Entra ID via Microsoft Entra Connect, and both require a system-assigned service principal on each managed instance.

**How to spot it:** Windows Authentication to an MI hostname fails, and neither the KDC proxy group policy nor a Trusted Domain Object is present. `dsregcmd.exe /status` on the client shows the join state, which determines the eligible flow. Note that Windows Authentication for Microsoft Entra principals is not available for Linux clients at all.

**Example:**
```powershell
# Which flow is the client eligible for?
dsregcmd.exe /status
# AzureAdJoined : YES / DomainJoined : YES  -> hybrid joined, modern interactive flow eligible
# AzureAdJoined : NO  / DomainJoined : YES  -> AD joined, incoming trust-based flow

# Incoming trust-based flow: create the Trusted Domain Object on the root domain
Set-AzureADKerberosServer -Domain $domain `
    -UserPrincipalName $cloudUserName `
    -DomainCredential $domainCred `
    -SetupCloudTrust

# Confirm it was created
Get-AzureADKerberosServer -Domain $domain -DomainCredential $domainCred `
    -UserPrincipalName $cloudUserName | Select-Object -ExpandProperty CloudTrustDisplay
```

For the modern interactive flow, enable the `Administrative Templates\System\Kerberos\Specify KDC proxy servers for Kerberos clients` policy and map `KERBEROS.MICROSOFTONLINE.COM` to the tenant's KDC proxy URL.

**Fix options:**
1. Synchronise AD with Microsoft Entra ID using Microsoft Entra Connect if that has not already been done — everything else depends on it
2. Prefer the modern interactive flow where the client fleet qualifies; it needs no trust object and no domain controller line of sight
3. Fall back to the incoming trust-based flow for AD joined clients, then deploy the Kerberos Proxy group policy
4. Create the system-assigned service principal for each managed instance
5. Rotate the Entra Kerberos key periodically with `Set-AzureADKerberosServer -RotateServerKey`; propagation between KDCs takes several hours, so the key can only be rotated once in 24 hours without `-Force`
6. If users fail ticket requests within four hours of a client rebuild or upgrade, force a fresh TGT with `dsregcmd.exe /RefreshPrt`, then lock and unlock the session

**Related checks:** K31, K32, K48

---

### K34 — gMSA Password Rollover SPN Drift

**What it means:** Group Managed Service Accounts (gMSA) automatically rotate their passwords, and in the process, Active Directory updates `ServicePrincipalNames` on the gMSA object. Occasionally, the automatic SPN re-registration after a rollover misses one variant (typically the FQDN form), causing Kerberos failures for clients that use the FQDN in their connection string.

**How to spot it:** SPN list from `setspn -L gMSA$` differs from `Get-ADServiceAccount gMSA -Properties ServicePrincipalNames`.

**Example:**
```powershell
setspn -L DOMAIN\sqlgMSA$
# Shows: MSSQLSvc/SQLNODE1:1433 only

Get-ADServiceAccount sqlgMSA -Properties ServicePrincipalNames
# Shows: MSSQLSvc/SQLNODE1:1433 AND MSSQLSvc/SQLNODE1.domain.com:1433
# Discrepancy — one form is present in AD but not registered
```

**Fix options:**
1. Re-register the missing SPN: `setspn -S MSSQLSvc/SQLNODE1.domain.com:1433 DOMAIN\sqlgMSA$`
2. Run `Test-ADServiceAccount sqlgMSA` to verify the gMSA is functioning correctly
3. Trigger a manual SPN refresh: `Install-ADServiceAccount sqlgMSA` on a host that uses the gMSA

**Related checks:** K3, K4, K11

---

### K35 — FCI Node-Specific SPN Leak

**What it means:** A Failover Cluster Instance (FCI) presents to clients under its Virtual Network Name (VNN), not the physical node names. If physical node-specific `MSSQLSvc/<node>:<port>` SPNs exist alongside the VNN SPN, clients connecting to a physical node name may authenticate with Kerberos while VNN connections fail (or vice versa), creating inconsistent authentication behaviour after a failover.

**How to spot it:** `setspn -Q MSSQLSvc/*` shows both `MSSQLSvc/<VNN>:1433` and `MSSQLSvc/<NodeA>:1433` / `MSSQLSvc/<NodeB>:1433`.

**Fix options:**
1. Remove SPNs for physical node names: `setspn -D MSSQLSvc/<NodeA>:1433 DOMAIN\sqlsvc` and `setspn -D MSSQLSvc/<NodeB>:1433 DOMAIN\sqlsvc`
2. Keep only the VNN SPN (K6) — the VNN is the sole name clients should use
3. After failover, the VNN follows the active node; physical node SPNs are always wrong for FCI connectivity

**Related checks:** K6, K8, K9

---

### K36 — Distributed AG Forwarder Listener SPN Missing

**What it means:** A Distributed Availability Group (DAG) introduces a middle-tier AG whose listener is distinct from either underlying AG's listener. Clients connecting to the global primary listener of the outer AG need the forwarder AG's listener to have its own SPN registered — otherwise the cross-AG traffic uses NTLM rather than Kerberos. Applies to SQL Server 2016+.

**How to spot it:** DAG topology described in input; `setspn -Q MSSQLSvc/<forwarder-listener>:1433` returns no results.

**Fix options:**
1. Identify the forwarder replica's listener name from `sys.availability_group_listeners`
2. Register `setspn -S MSSQLSvc/<forwarder-listener>:1433 DOMAIN\sqlsvc` **once**, against the service account the replicas run under — registering it per replica creates the duplicate SPN K8 flags
3. Verify with `setspn -Q MSSQLSvc/<forwarder-listener>:1433` from each replica

**Related checks:** K12, K16, K6

---

### K37 — TrustedToAuthForDelegation Set for an RBCD Path

**What it means:** It is a common but incorrect belief that Resource-Based Constrained Delegation needs `TrustedToAuthForDelegation` ("Use any authentication protocol") on the initiating account so that S4U2Self can produce a forwardable ticket. Microsoft is explicit that the opposite is true: **RBCD cannot use the Trusted-to-Authenticate-for-Delegation bit that previously controlled protocol transition, and the KDC always allows protocol transition when performing RBCD as though the bit were set.**

So enabling the flag for an RBCD path does nothing for that path, while granting the account real protocol-transition privilege it does not need — a privilege that lets it obtain tickets for arbitrary users. This check therefore fires on the flag being *present*, not absent.

Because the KDC does not limit protocol transition under RBCD, control is moved to the resource owner instead. Two well-known SIDs are stamped into the resulting ticket so a back-end service can tell how the user actually authenticated, and ACL accordingly:

| SID | Meaning |
|-----|---------|
| `S-1-18-1` (`AUTHENTICATION_AUTHORITY_ASSERTED_IDENTITY`) | The client's identity was asserted by an authentication authority based on proof of possession of the client's own credentials |
| `S-1-18-2` (`SERVICE_ASSERTED_IDENTITY`) | The client's identity was asserted by a service — that is, protocol transition occurred |

**How to spot it:** RBCD is configured (`msDS-AllowedToActOnBehalfOfOtherIdentity` populated on the target) and the initiating account also has `TrustedToAuthForDelegation = True`, with no separate classic-KCD path that would justify it.

**Example:**
```powershell
# Target is configured for RBCD...
Get-ADComputer SQLTARGET -Properties PrincipalsAllowedToDelegateToAccount

# ...and the initiator also carries the protocol transition bit, which RBCD ignores
Get-ADUser sqlsvc -Properties TrustedToAuthForDelegation, msDS-AllowedToDelegateTo
# TrustedToAuthForDelegation : True
# msDS-AllowedToDelegateTo   : {}          <- no classic KCD path, so the bit has no purpose

# Remove the unnecessary privilege
Set-ADUser sqlsvc -TrustedToAuthForDelegation $false
```

**Fix options:**
1. Clear the flag when the account's only delegation path is RBCD — it is unused privilege
2. Keep it only where the same account also serves a classic KCD path that genuinely needs protocol transition (K23); document which path requires it
3. To restrict access by authentication method, ACL the back-end service against `S-1-18-1` and `S-1-18-2` rather than trying to control protocol transition on the initiator
4. Before choosing RBCD at all, confirm the feature supports it — linked servers do not (K41)

**Related checks:** K23, K24, K41, K19

---

### K38 — Encryption Type Mismatch Between Account and KDC Policy

**What it means:** The KDC picks a ticket encryption type by intersecting what the client supports with what the target account advertises in `msDS-SupportedEncryptionTypes`. If that intersection is empty, no ticket is issued and the connection falls back to NTLM or fails outright. The attribute is a bitmask, combined by bitwise OR:

| Bit (hex) | Decimal | Encryption type |
|-----------|---------|-----------------|
| `0x1` | 1 | DES-CBC-CRC (legacy) |
| `0x2` | 2 | DES-CBC-MD5 (legacy) |
| `0x4` | 4 | RC4-HMAC (legacy, transition only) |
| `0x8` | 8 | AES128-CTS-HMAC-SHA1-96 |
| `0x10` | 16 | AES256-CTS-HMAC-SHA1-96 |

Common values: **24** (`0x18`) is AES-only, the hardened end state; **28** (`0x1C`) is RC4 plus AES, the usual transitional value; **0 / unset** means the KDC falls back to the domain-wide `DefaultDomainSupportedEncTypes` assumption rather than anything specific to the account.

Kerberos FAST armoring is one case of this mismatch: when domain controllers enforce armoring, an account holding no AES keys cannot participate. But the far more common trigger today is straightforward AES enforcement in a domain that has disabled RC4 — see K47 for that specific case.

**How to spot it:** `klist get MSSQLSvc/<fqdn>:1433` fails with "The encryption type requested is not supported by the KDC"; KDC events 4768 and 4769 carry error code `0xE` (`KDC_ERR_ETYPE_NOTSUPP`). The events also expose the `MSDS-SupportedEncryptionTypes` field for both the account and the service.

**Example:**
```powershell
# Read the current bitmask (returned in decimal)
$parameters = @{
    Filter     = "Name -eq 'sqlsvc' -and (ObjectClass -eq 'Computer' -or ObjectClass -eq 'User')"
    Properties = "msDS-SupportedEncryptionTypes"
}
Get-ADObject @parameters | Format-List DistinguishedName, msDS-SupportedEncryptionTypes, Name, ObjectClass
# msDS-SupportedEncryptionTypes : 4      <- RC4 only; fails in an AES-enforced domain

# Set AES support explicitly
Set-ADUser sqlsvc -KerberosEncryptionType AES128,AES256    # bitmask becomes 24

# Confirm a ticket can now be issued
klist get MSSQLSvc/sqlnode1.contoso.com:1433
```

**Fix options:**
1. Set the attribute explicitly on the account rather than depending on the domain default, so behaviour does not change when `DefaultDomainSupportedEncTypes` is hardened
2. Use `Set-ADServiceAccount -KerberosEncryptionType` for an MSA or gMSA, and `New-ADServiceAccount -KerberosEncryptionType` when creating one
3. Reset the account password if it predates AES support in Windows Kerberos and has never been changed — without a reset the account holds no AES-SHA1 keys at all, whatever the attribute says
4. Restart the machine after changing policy so it refreshes its `msDS-SupportedEncryptionTypes` in AD
5. Audit before enforcing: KDC events 4768 and 4769 on Windows Server 2019+ (and Windows Server 2016 from the January 2025 cumulative update) record RC4 usage, so you can find affected accounts before disabling RC4

**Related checks:** K47, K50, K27, K30

---

### K39 — Write-SPN Blocked by AdminSDHolder

**What it means:** Active Directory's `AdminSDHolder` mechanism periodically (every 60 minutes by default) resets the ACL of any account that is a member of a privileged group (Domain Admins, Schema Admins, Enterprise Admins, etc.) to match the AdminSDHolder template. If the SQL Server service account is — or was — a member of such a group, its `Write ServicePrincipalName` permission is removed by SDProp. This silently prevents automatic or self-service SPN registration.

**How to spot it:** Service account has `adminCount = 1` attribute; `Get-ADUser sqlsvc -Properties adminCount` returns `1`. Or SPN registration attempts fail with "Insufficient access rights" even when run as the service account itself.

**Fix options:**
1. Move the SQL Server service account out of all privileged AD groups — it should be a dedicated low-privilege domain account
2. Clear the `adminCount` attribute (requires Domain Admin): `Set-ADUser sqlsvc -Clear adminCount`
3. Manually reset the ACL on the service account to restore `Write ServicePrincipalName`; SDProp will keep resetting it as long as the account is in a protected group

**Related checks:** K18, K7

---

### K40 — DNS CNAME Alias Without SPN

**What it means:** When a client uses a DNS CNAME alias in its SQL Server connection string (e.g., `sql-prod` resolving to `SQLNODE1.domain.com`), Kerberos constructs the SPN from the alias name — not the resolved hostname. A SPN registered only for the actual hostname (`MSSQLSvc/SQLNODE1:1433`) does not satisfy a Kerberos request for `MSSQLSvc/sql-prod:1433`. The client falls back to NTLM even though a correct SPN exists for the physical host.

**How to spot it:** Connection string uses a CNAME alias; `setspn -Q MSSQLSvc/<cname>:1433` returns no results; `setspn -Q MSSQLSvc/<real-hostname>:1433` returns results.

**Example:**
```powershell
setspn -Q MSSQLSvc/sql-prod:1433    # No results — alias has no SPN
setspn -Q MSSQLSvc/SQLNODE1:1433    # Returns DOMAIN\sqlsvc — real host SPN exists
# Kerberos fails for connections using "sql-prod" despite the host SPN being correct
```

**Fix options:**
1. Register a SPN for the CNAME alias: `setspn -S MSSQLSvc/sql-prod:1433 DOMAIN\sqlsvc`
2. Add both short and FQDN variants of the alias if clients use both: `setspn -S MSSQLSvc/sql-prod.domain.com:1433 DOMAIN\sqlsvc`
3. Alternatively, change the connection string to use the physical hostname or VNN — this avoids maintaining alias SPNs but may require application configuration changes

**Related checks:** K1, K3, K7, K8

---

## Double-Hop Platform Constraints (K41–K44)

Delegation support is not uniform across SQL Server features. Two of the most common double-hop scenarios — linked servers and SSISDB package execution — have documented restrictions that make the generic "use constrained delegation" advice in K21 and K24 wrong. Check this section before recommending a delegation model.

### K41 — Linked Server Delegation Path Relies on RBCD

**What it means:** Microsoft documents linked server delegation support precisely: *"Linked servers support Active Directory pass-through authentication when using full delegation. Starting with SQL Server 2017 (14.x) CU17, pass-through authentication with constrained delegation is also supported; however, resource-based constrained delegation isn't supported."*

Resource-Based Constrained Delegation is therefore never a valid answer for a linked-server double-hop, in any version. This matters because RBCD is otherwise the modern recommendation — it crosses domains, and it puts the decision in the resource owner's hands — so administrators reach for it naturally and then cannot work out why the second hop still lands as `ANONYMOUS LOGON`.

**How to spot it:** A linked-server double-hop is described; the target computer or service account has `msDS-AllowedToActOnBehalfOfOtherIdentity` populated, and the middle-tier account's `msDS-AllowedToDelegateTo` is empty. The symptom is `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'` on the second hop while every SPN check passes.

**Example:**
```powershell
# The RBCD configuration that will not work for a linked server
$MiddleTier = Get-ADUser -Identity sqlsvcA
Set-ADComputer -Identity SQLTARGET -PrincipalsAllowedToDelegateToAccount $MiddleTier

# What a linked server actually needs - classic KCD on the middle tier (SQL 2017 CU17+)
Set-ADUser sqlsvcA -Add @{
    'msDS-AllowedToDelegateTo' = @(
        'MSSQLSvc/sqltarget.contoso.com:1433',
        'MSSQLSvc/sqltarget.contoso.com'
    )
}

# Remove the RBCD entry once the supported path works
Set-ADComputer -Identity SQLTARGET -PrincipalsAllowedToDelegateToAccount $null
```

**Fix options:**
1. Move to classic constrained delegation on the middle-tier service account, listing the target's `MSSQLSvc` SPNs in `msDS-AllowedToDelegateTo`. Requires SQL Server 2017 CU17 or later — see K42
2. Where the version floor cannot be met, use full delegation ("Trust this user for delegation to any service") on the middle-tier account. This re-triggers K19 by design; report it as an accepted exception with the reason, not as a defect to remove
3. Clear the RBCD ACL on the target once a supported path is working, so the configuration does not mislead the next person
4. Remember that classic KCD cannot cross a domain boundary. If the linked server is in another domain and the version floor cannot be met, full delegation is the only remaining option — which is a strong argument for collapsing the hop instead

**Related checks:** K21, K24, K37, K42, K19

---

### K42 — Linked Server Constrained Delegation Below SQL 2017 CU17

**What it means:** Constrained delegation for linked-server pass-through authentication was added in SQL Server 2017 (14.x) CU17. On any earlier build, only full delegation carries the caller's identity across the second hop. A correctly populated `msDS-AllowedToDelegateTo` on an older instance produces no error — it simply does not take effect, and the second hop authenticates as `ANONYMOUS LOGON`.

**How to spot it:** Constrained delegation is configured for a linked-server path, SPNs are correct, delegation targets exist, and the second hop still fails. Check the middle-tier build number before looking any further at AD.

**Example:**
```sql
-- Establish the middle-tier build first
SELECT
    SERVERPROPERTY('ProductVersion')  AS product_version,
    SERVERPROPERTY('ProductLevel')    AS product_level,
    SERVERPROPERTY('ProductUpdateLevel') AS cu_level;
-- 14.0.3238.1 / SP0 / CU17  -> constrained delegation supported
-- 14.0.3045.24 / SP0 / CU12 -> NOT supported, full delegation required
-- 13.x (SQL 2016) or older  -> NOT supported at any CU

-- Confirm which identity actually arrived at the far end
SELECT SYSTEM_USER AS arrived_as, ORIGINAL_LOGIN() AS original_login;
```

**Fix options:**
1. Patch the middle-tier instance to SQL Server 2017 CU17 or later — this is the clean fix and does not weaken the delegation posture
2. Use full delegation on the middle-tier service account as an interim measure, and record it as a known exception to K19 with a removal trigger tied to the patch
3. Do not attempt RBCD as the workaround — it is unsupported for linked servers regardless of version (K41)
4. Where neither is acceptable, remove the second hop: replicate the data, use a SQL Agent job with a stored credential, or query the far end directly from the client

**Related checks:** K41, K21, K19

---

### K43 — SSISDB Package Double-Hop Under Constrained Delegation

**What it means:** Remote execution of packages stored in the SSISDB catalog does not support constrained delegation. When a user on machine A launches a package that lives in the SSISDB catalog on machine B, and the package connects onward to machine C, the `ISServerExec.exe` process on B must delegate the user's credentials to C. Microsoft documents that this requires **unconstrained** delegation ("Trust this user for delegation to any service (Kerberos Only)") on the SQL Server service account hosting SSISDB, and that constrained delegation will not work.

This is the one place in the skill where K19 — unconstrained delegation as a Critical finding — is expected rather than wrong. Report both checks together and state the dependency, so the reviewer does not "fix" K19 and break the packages.

There is a genuine conflict worth surfacing: Windows Credential Guard mandates constrained delegation. Where Credential Guard is enabled, the two requirements cannot both be satisfied and the topology has to change.

**How to spot it:** A package stored in SSISDB is executed from a remote SSMS session and fails with `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'`, while the same package succeeds when launched from a session on the SSISDB host itself. That asymmetry — works locally, fails remotely — is the signature.

**Example:**
```
Machine A (SSMS)  ->  Machine B (SSISDB + ISServerExec)  ->  Machine C (data source)
                          ^
                          |
        needs unconstrained delegation on B's SQL Server service account

Launch from B  -> single hop  -> succeeds
Launch from A  -> double hop  -> "Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'"
```

```powershell
# What SSISDB requires on the machine B service account
Set-ADUser sqlsvcB -TrustedForDelegation $true

# Verify - TrustedForDelegation True and msDS-AllowedToDelegateTo empty is correct here
Get-ADUser sqlsvcB -Properties TrustedForDelegation, msDS-AllowedToDelegateTo
```

**Fix options:**
1. Grant unconstrained delegation to the SQL Server service account on the SSISDB host, and document it as a required exception to K19 with the reason recorded
2. Evaluate the security cost honestly first. Unconstrained delegation means a compromise of machine B yields the ability to impersonate any connecting user against any service — for a machine running arbitrary ETL packages, that is a meaningful blast radius
3. Where Windows Credential Guard is enabled, the requirements are mutually exclusive. Move the packages out of the SSISDB catalog to file system or MSDB deployment, or eliminate the double hop by executing the package on the machine that owns the connection
4. Alternatively, avoid delegation entirely: run the package under a SQL Agent job on machine B with an explicitly configured proxy or stored credential, so no caller identity needs forwarding

**Related checks:** K19, K21, K41

---

### K44 — Named Instance Dynamic Port Prevents Kerberos

**What it means:** Named instances default to dynamic ports: SQL Server picks an available port at startup, which can differ after every restart. An SPN registered against yesterday's port stops matching, so Kerberos works until the first restart and then silently degrades to NTLM — or fails outright. Microsoft's guidance is unambiguous: in environments that need Kerberos, set the named instance to a static port and register the SPN against that port.

This is distinct from K5 and K13, which describe a wrong but *stable* port. Here the problem is that no port is stable enough to register.

**How to spot it:** In SQL Server Configuration Manager, `TCP Dynamic Ports` holds a value and `TCP Port` is empty. Kerberos Configuration Manager reports this condition directly with a Dynamic Port status. Behaviourally, `auth_scheme` flips between `KERBEROS` and `NTLM` across restarts for the same client and connection string.

**Example:**
```sql
-- Current port and auth scheme for this connection
SELECT
    c.net_transport,
    c.auth_scheme,
    c.local_tcp_port
FROM sys.dm_exec_connections AS c
WHERE c.session_id = @@SPID;
-- local_tcp_port 49200 today, 51402 after the next restart
-- and the SPN registered against 49200 no longer matches
```

**Fix options:**
1. Pin a static port. SQL Server Configuration Manager → SQL Server Network Configuration → Protocols for the instance → TCP/IP → IP Addresses tab. If `Listen All` is `Yes`, clear `TCP Dynamic Ports` under `IPAll` and set `TCP Port`. If `Listen All` is `No`, do the same for each enabled IP entry. Restart the instance for the change to take effect
2. Register the SPN against the new static port afterwards, and remove any SPN left over from a previous dynamic port — those become K10 stale entries and can collide as K8 duplicates
3. Also register the instance-name SPN form (`MSSQLSvc/<FQDN>:<instancename>`), which is port-independent and covers named pipe and shared memory clients — see K2
4. Where a static port genuinely cannot be assigned, accept that Kerberos over TCP is not achievable for that instance and plan around NTLM, rather than re-registering SPNs after every restart

**Related checks:** K2, K5, K13, K14

---

## Kerberos Environment Prerequisites (K45–K48)

Everything in this section breaks Kerberos while the SPN configuration is perfectly correct. They are worth ruling out early, because the symptoms — NTLM fallback, SSPI errors, refused logins — are indistinguishable from SPN problems, and a great deal of time gets spent re-registering SPNs that were never wrong.

### K45 — Clock Skew Beyond Kerberos Tolerance

**What it means:** Kerberos tickets carry timestamps set by the KDC, and every participant validates them. If the clock difference between a client or server and the domain controller exceeds five minutes, tickets are rejected as potentially replayed. The tolerance is a deliberate anti-replay control, not an implementation quirk.

Windows normally keeps domain members in sync automatically, so this surfaces in two situations: the clock is out by more than 48 hours (beyond what automatic correction will fix), or the host is not using a domain controller in its own domain as its time source — commonly a virtual machine syncing to its hypervisor host instead, or a server pointed at an external NTP source directly.

**How to spot it:** `KRB_AP_ERR_SKEW` in a network trace, or event ID 4 with `KERB_AP_ERR_SKEW` in the System log. Note that `KRB_AP_ERR_MODIFIED` (K53) can also be caused by clock skew, so check the offset before chasing key problems.

**Example:**
```powershell
# Measure the offset against a domain controller
w32tm /stripchart /computer:DC01.contoso.com /samples:5 /dataonly
# 14:32:01, +00.0412297s   <- healthy
# 14:32:01, +412.8830000s  <- ~7 minutes adrift, Kerberos will fail

# Inspect and repair the time source
w32tm /query /source
w32tm /query /status
w32tm /resync /rediscover
```

**Fix options:**
1. Resynchronise the affected host against a domain controller in its own domain, then confirm with `w32tm /stripchart`
2. Fix the time source rather than the symptom — a member server should inherit time from the domain hierarchy, not from a hypervisor host or an external NTP server
3. For the forest, designate the forest-root PDC emulator as the single authoritative source, syncing to a reliable external stratum-1 or stratum-2 server; every other DC follows the domain hierarchy, and members follow their local DC. Multiple upstream sources across sites produce exactly the cross-site drift this check catches
4. Where a DC's own clock is wrong, treat it as urgent — its members inherit the error and Kerberos may keep working locally while failing against everything else

**Related checks:** K53, K20

---

### K46 — Kerberos Token Size Exceeded

**What it means:** Kerberos carries the user's authorization data — the SIDs of the user and every group they belong to, plus any SIDs in `sIDHistory` — inside the Privilege Attribute Certificate in the ticket. That structure has a fixed maximum size, `MaxTokenSize`. A user in enough groups overflows it and cannot authenticate.

SQL Server surfaces this as **error 17832**, which makes it one of the few Kerberos environment problems with a SQL-specific documented error to key on.

Defaults: 12,000 bytes on Windows Server 2008 R2 and earlier, 48,000 bytes on Windows Server 2012 and later. As a rule of thumb, more than about 120 universal group memberships overflows the default. Estimate precisely with:

```
TokenSize = 1200 + 40d + 8s
```

where `d` is the count of universal groups outside the user's account domain plus SIDs in `sIDHistory`, and `s` is the count of in-domain universal, domain-local and global group memberships. Older Windows versions count domain-local memberships in `d` rather than `s`. If unconstrained delegation is in play, double the result.

**How to spot it:** SQL Server error 17832, or authentication failures with "out of memory" or "Not enough storage is available to complete this operation" for specific users while others connect fine. The correlation with a single user's group membership is the tell.

**Example:**
```powershell
# Count the memberships that drive token size for one user
$user = Get-ADUser jsmith -Properties MemberOf, sIDHistory
$groups = $user.MemberOf.Count
$sidHistory = @($user.sIDHistory).Count
"Groups: $groups  sIDHistory: $sidHistory  rough token estimate: $(1200 + 40*$sidHistory + 8*$groups) bytes"
```

**Fix options:**
1. Reduce the token before raising the limit. Rationalise group membership, and clear `sIDHistory` entries left over from a forest migration — those count double, once for the user SID and once per group
2. Where the registry must change, set `MaxTokenSize` (REG_DWORD, decimal) under `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters` on **every** machine in the authentication chain — the client, any middle tier such as an IIS or SSRS server, and the SQL Server host — and restart each one. Setting it on the SQL Server alone does not help
3. Keep the value at or below 48,000 where IIS is in the path. IIS caps HTTP request buffers at 64 KB, and base64 encoding inflates the ticket to about 133% of its size, so a larger token produces HTTP 400 errors instead of Kerberos errors
4. Do not exceed 65,535 — values at or above that break other components, and setting the value as hexadecimal 65535 rather than decimal is a documented way to break Kerberos outright
5. Get warning before failure: enable `Computer Configuration\Administrative Templates\System\KDC\Warning for large Kerberos tickets` to log event ID 31 when tokens approach the threshold
6. Note the separate 1,010-group limit on the LSA access token, which fails similarly but is governed by different rules and affects NTLM too

**Related checks:** K45, K20

---

### K47 — RC4-Only Encryption Types Under AES Enforcement

**What it means:** As domains harden and disable RC4, any account still advertising RC4 as its only supported Kerberos encryption type stops being able to receive service tickets. For a SQL Server service account this means every Kerberos login to that instance fails at once, usually immediately after a domain hardening change that appears unrelated.

Two states trigger it. Either `msDS-SupportedEncryptionTypes` is explicitly `4` (RC4 only), or it is unset — in which case the KDC falls back to the domain-wide `DefaultDomainSupportedEncTypes` assumption, and hardening that registry value changes the account's effective behaviour without anyone touching the account.

A third case catches people out: an account created before AES support existed in Windows Kerberos, whose password has never been reset, holds no AES keys at all. Setting the attribute does not conjure them — only a password change generates them.

**How to spot it:** `klist get MSSQLSvc/<fqdn>:1433` returns "The encryption type requested is not supported by the KDC" (`0xc00002fd`). KDC event 4769 shows error code `0xE`, `KDC_ERR_ETYPE_NOTSUPP`. Events 4768 and 4769 also expose the account's `MSDS-SupportedEncryptionTypes` and the ticket encryption type actually used — `0x17` there means RC4.

**Example:**
```powershell
# What does the account actually advertise?
$parameters = @{
    Filter     = "Name -eq 'sqlsvc' -and (ObjectClass -eq 'Computer' -or ObjectClass -eq 'User')"
    Properties = "msDS-SupportedEncryptionTypes"
}
Get-ADObject @parameters | Format-List DistinguishedName, msDS-SupportedEncryptionTypes, Name, ObjectClass
# msDS-SupportedEncryptionTypes : 4    <- RC4 only

# What has the domain been hardened to?
Get-ItemProperty 'HKLM:\System\CurrentControlSet\services\KDC' -Name DefaultDomainSupportedEncTypes -ErrorAction SilentlyContinue
# 0x18 (24) = AES only - so an RC4-only account cannot get a ticket

# Fix and verify
Set-ADUser sqlsvc -KerberosEncryptionType AES128,AES256
klist purge
klist get MSSQLSvc/sqlnode1.contoso.com:1433
```

**Fix options:**
1. Set the encryption types explicitly on the account rather than relying on the domain default, so a later hardening change cannot alter its behaviour silently. `Set-ADUser -KerberosEncryptionType AES128,AES256` produces a bitmask of 24
2. Use 28 (RC4 plus AES) as a transitional value if RC4 is still needed elsewhere, and plan the move to 24
3. Reset the service account password if the account predates AES support — without it the account has no AES-SHA1 keys no matter what the attribute claims. Restart SQL Server afterwards
4. Restart the machine after a policy change so it refreshes its own `msDS-SupportedEncryptionTypes` in the directory
5. Audit before enforcing rather than after. KDC events 4768 and 4769 on Windows Server 2019+ (and on Windows Server 2016 from the January 2025 cumulative update) record RC4 usage, so RC4-dependent accounts can be found and fixed before RC4 is switched off
6. Members of Protected Users (K27, K30) cannot use RC4 at all by design — if the account is in that group, the encryption type is a symptom rather than the cause

**Related checks:** K38, K50, K27, K30

---

### K48 — Client and Server Across a Forest Boundary

**What it means:** Kerberos authentication to SQL Server requires that the client and server computers be in the same Windows domain or in trusted domains. Where there is no trust path, no referral can be issued and no service ticket can be obtained — the connection falls back to NTLM if that is permitted, or fails. Microsoft's SSPI troubleshooting guidance adds that the SQL Server's domain and the connecting account's domain need to be in the same forest for SSPI to work.

A trust that exists but does not advertise a shared encryption type produces the same practical outcome, with a different error.

**How to spot it:** The connecting account's domain differs from the SQL Server's domain and `nltest /domain_trusts` shows no path between them. Where a trust does exist, an "unsupported etype" failure with KDC event ID 14 points at the trust object's encryption configuration rather than at either account.

**Example:**
```powershell
# Is there a trust path at all?
nltest /domain_trusts /all_trusts /v

# Can the client resolve and reach the far KDC?
nltest /dsgetdc:remote.contoso.com
```

```console
:: If the trust exists but tickets fail with an unsupported etype,
:: set the encryption types on the trust from a DC in the trusted domain
ksetup /setenctypeattr child.contoso.com AES128-CTS-HMAC-SHA1-96 AES256-CTS-HMAC-SHA1-96
```

**Fix options:**
1. Establish or repair the trust between the domains, or move the connecting principal into a domain that already has one
2. Where the trust exists but tickets fail on encryption type, configure it on both sides — a two-way transitive trust needs `ksetup /setenctypeattr` run from a DC in each direction, or the referral ticket cannot be built
3. Remember the delegation consequence: classic KCD (K21) is restricted to a single domain and cannot cross this boundary at all. RBCD (K24) can, because the delegation is configured on the resource side — but not for linked servers, which do not support RBCD (K41)
4. Where no trust is possible, stop trying to make Windows Authentication work across the boundary. Use SQL Authentication, or a Microsoft Entra-based path, and document the decision

**Related checks:** K21, K24, K33, K41

---

## SQL Server on Linux Kerberos (K49–K51)

SQL Server on Linux does not register SPNs at startup and has no service account in the Windows sense. It authenticates from a **keytab** — a file holding the long-term Kerberos keys for its SPNs and for a privileged AD account — referenced from `mssql-conf`. The SPN checks earlier in this skill still apply, since the SPNs live in the same Active Directory; these three cover the Linux-specific state that has no Windows equivalent. Applies to SQL Server 2017 and later on Linux, including containers.

### K49 — Keytab Not Configured in mssql-conf

**What it means:** Two `mssql-conf` settings connect the instance to Active Directory: `network.kerberoskeytabfile`, the path to the keytab, and `network.privilegedadaccount`, the AD user whose entry in that keytab SQL Server uses to talk to the directory. If either is unset, or the keytab does not contain the SPNs clients ask for, Active Directory authentication does not work regardless of how correct the AD-side SPN registration is.

Note that SPN registration and keytab creation are separate steps on Linux. `adutil spn addauto` registers the SPNs in AD; `adutil keytab createauto` or `mssql-conf setup-ad-keytab` writes the matching keys into the keytab. Doing one without the other leaves a half-configured instance.

**How to spot it:** `mssql-conf validate-ad-config` reports failures, or `klist -kte` on the keytab shows no `MSSQLSvc` entries for the hostname and port clients use.

**Example:**
```bash
# Validate the whole configuration in one step
/opt/mssql/bin/mssql-conf validate-ad-config /var/opt/mssql/secrets/mssql.keytab

# Inspect what the keytab actually contains
klist -kte /var/opt/mssql/secrets/mssql.keytab
# Expect MSSQLSvc/sqllinux.contoso.com:1433 and MSSQLSvc/sqllinux.contoso.com
# plus an entry for the privileged account, e.g. sqluser@CONTOSO.COM

# Read the current settings
grep -E 'kerberoskeytabfile|privilegedadaccount' /var/opt/mssql/mssql.conf
```

```bash
# Register the SPNs in AD, then build the keytab, then point SQL Server at it
kinit privilegeduser@CONTOSO.COM
adutil spn addauto -n sqluser -s MSSQLSvc -H sqllinux.contoso.com -p 1433

su mssql
/opt/mssql/bin/mssql-conf setup-ad-keytab /var/opt/mssql/secrets/mssql.keytab sqluser
/opt/mssql/bin/mssql-conf set network.kerberoskeytabfile /var/opt/mssql/secrets/mssql.keytab
/opt/mssql/bin/mssql-conf set network.privilegedadaccount sqluser
sudo systemctl restart mssql-server
```

**Fix options:**
1. Create the keytab with `mssql-conf setup-ad-keytab`, which is the preferred route when `adutil` is integrated with `mssql-conf`, or with `adutil keytab createauto -k <path> -p <port> -H <fqdn> -s MSSQLSvc` otherwise
2. Set both settings, then restart with `systemctl restart mssql-server` and re-run `validate-ad-config`
3. Supply `-p <port>` when registering SPNs with `adutil spn addauto`. Omitting it generates portless SPNs only, which work solely when SQL Server listens on the default 1433
4. Confirm `/var/opt/mssql/mssql.conf` is owned by `mssql` rather than `root`, otherwise every `mssql-conf` command needs `sudo` and the setup steps behave differently from the documented flow
5. For containers, build the keytab on a domain-joined Linux host and mount it into the container — the container host itself does not need to be domain joined
6. Note that `adutil keytab create` and `createauto` append rather than overwrite. Re-running after a port change leaves stale entries behind alongside the new ones

**Related checks:** K1, K2, K50, K51

---

### K50 — Keytab Encryption Types Mismatch the AD Account

**What it means:** Every keytab entry is bound to a specific encryption type. If the types in the keytab do not intersect what the AD account and the domain will issue, ticket decryption fails even though the keytab exists and holds the right SPNs. The most common form is a keytab built with `arcfour-hmac` only, in a domain that has since disabled RC4.

Linux hosts have an additional, non-obvious failure mode. Active Directory reads the `operatingSystemVersion` attribute to decide whether a host understands modern encryption types, parsing left to right and stopping at the first decimal point. A Linux machine account reporting `3.10.0x` yields `3`, below the threshold of six, so the KDC **ignores `msDS-SupportedEncryptionTypes` entirely** and falls back to the domain's assumed types. This is by design, to accommodate Windows 2000 and XP era clients. It means setting the attribute on a Linux account may have no effect at all, and the fix has to come from `DefaultDomainSupportedEncTypes` or from the keytab side.

**How to spot it:** `klist -kte` shows only `arcfour-hmac`, or shows types the domain no longer accepts. Ticket requests fail with an unsupported-etype error while the SPNs are demonstrably present.

**Example:**
```bash
klist -kte /var/opt/mssql/secrets/mssql.keytab
# KVNO Timestamp           Principal
# ---- ------------------- ------------------------------------------------------
#    3 01/15/2026 09:14:22 MSSQLSvc/sqllinux.contoso.com:1433@CONTOSO.COM (arcfour-hmac)
#    3 01/15/2026 09:14:22 MSSQLSvc/sqllinux.contoso.com@CONTOSO.COM (arcfour-hmac)
# ^ RC4 only - fails in an AES-enforced domain

# Rebuild with AES
adutil keytab createauto -k /var/opt/mssql/secrets/mssql.keytab \
    -p 1433 -H sqllinux.contoso.com -s MSSQLSvc \
    -e aes256-cts-hmac-sha1-96 --password '<password>'
```

**Fix options:**
1. Rebuild the keytab entries with an AES type the domain supports, passing `-e` to `adutil` to avoid the interactive prompt
2. On the domain controller, enable **This account supports Kerberos AES 128 bit encryption** and **This account supports Kerberos AES 256 bit encryption** on the privileged AD account, under the Account tab
3. Choose encryption types the host *and* the domain both support — `adutil` accepts several, and more than one entry per principal is normal and useful during transition
4. Treat `arcfour-hmac` as transitional only; Microsoft documents it as weak and not recommended for production
5. If AES still is not negotiated after all of the above, check `operatingSystemVersion` on the Linux machine account before assuming the keytab is wrong — the attribute-ignoring behaviour described above is the usual explanation for Linux accounts stuck on RC4

**Related checks:** K38, K47, K49

---

### K51 — Keytab File Ownership or Permissions Wrong

**What it means:** The keytab holds long-term Kerberos keys — cryptographically equivalent to the service account's password. Two failure modes sit on either side of the same setting. Too permissive, and any local user can read credentials that authenticate as SQL Server and as the privileged AD account. Too restrictive, or owned by the wrong user, and the `mssql` process cannot read its own keytab, so Active Directory authentication stops entirely.

Microsoft's documented state is ownership by `mssql` with mode `440` — read for owner and group, nothing for others, no write for anyone.

**How to spot it:** `ls -l` on the keytab shows an owner other than `mssql`, or a mode granting more than owner and group read.

**Example:**
```bash
ls -l /var/opt/mssql/secrets/mssql.keytab
# -rw-r--r-- 1 root root 1129 Jan 15 09:14 mssql.keytab
# ^ owned by root, world-readable - both wrong

chown mssql /var/opt/mssql/secrets/mssql.keytab
chmod 440 /var/opt/mssql/secrets/mssql.keytab

ls -l /var/opt/mssql/secrets/mssql.keytab
# -r--r----- 1 mssql root 1129 Jan 15 09:14 mssql.keytab
```

**Fix options:**
1. `chown mssql <keytab>` then `chmod 440 <keytab>`
2. Treat any period of world-readability as a credential exposure. Rotate the affected passwords and rebuild the keytab rather than only tightening the mode — the keys may already have been copied
3. Apply the same care in containers, where the keytab is mounted from the host: set ownership and mode on the host copy before mounting, since a permissive file on the host is exposed regardless of what the container sees
4. Keep the keytab out of backups and configuration management repositories that have a wider audience than the host itself

**Related checks:** K49, K50

---

## Client Driver and Service State (K52–K54)

### K52 — Legacy Provider Cannot Use Kerberos Over Named Pipes

**What it means:** The legacy OLE DB provider (`SQLOLEDB`) and the legacy ODBC driver (`SQL Server`), both bundled with Windows, do not support Kerberos authentication over Named Pipes at all — they support only NTLM on that protocol. No amount of SPN correction changes this. It is a driver limitation, and the fix is on the client side.

This is worth checking early whenever `auth_scheme` reports `NTLM` while every SPN check passes, because the natural instinct is to keep re-examining AD.

**How to spot it:** `sys.dm_exec_connections` shows `net_transport = 'Named pipe'` and `auth_scheme = 'NTLM'` for a connection whose SPNs are demonstrably correct, and the application uses a legacy provider in its connection string.

**Example:**
```sql
SELECT
    c.session_id,
    c.net_transport,
    c.auth_scheme,
    s.program_name,
    s.client_interface_name
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions AS s
    ON s.session_id = c.session_id
WHERE c.auth_scheme = 'NTLM';
-- net_transport 'Named pipe' + client_interface_name 'SQLOLEDB' or 'ODBC'
-- explains the NTLM without any SPN being wrong
```

**Fix options:**
1. Switch the connection to TCP. Microsoft recommends TCP over Named Pipes regardless of driver version, and it resolves this immediately
2. Migrate to a current driver — `MSOLEDBSQL` (the Microsoft OLE DB Driver for SQL Server) or ODBC Driver 17 or later. Note that SQL Server Native Client (`SQLNCLI`, `SQLNCLI11`) was removed in SQL Server 2022 and is not the upgrade path
3. Confirm with `sys.dm_exec_connections` after the change rather than assuming
4. Record the finding clearly when it fires: this is a client configuration issue, and re-registering SPNs will not move it

**Related checks:** K20, K44

---

### K53 — Service Account Password Changed Without Service Restart

**What it means:** SQL Server derives its Kerberos long-term key from the service account password at service start. Change the password in Active Directory and the running service keeps using the old key, so it can no longer decrypt service tickets the KDC has encrypted with the new one. The instance keeps running and accepting SQL logins; only Windows Authentication breaks.

Account lockout produces a closely related failure, and is worth checking at the same time.

**How to spot it:** Windows Authentication began failing at a time that correlates with a password change or a lockout, with "Cannot generate SSPI context" on the client or `KRB_AP_ERR_MODIFIED` in a trace. The instance has not been restarted since.

`KRB_AP_ERR_MODIFIED` means "the client couldn't decrypt the service ticket" and has more than one cause, so confirm the others before settling here: a duplicate SPN (K8), a service account name that is not unique across the forest, or clock skew (K45).

**Example:**
```powershell
# When did the password last change, and has the service restarted since?
Get-ADUser sqlsvc -Properties PasswordLastSet, LockedOut, BadLogonCount |
    Format-List Name, PasswordLastSet, LockedOut, BadLogonCount

Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" |
    ForEach-Object { Get-Process -Id $_.ProcessId } |
    Select-Object Name, StartTime
# PasswordLastSet later than StartTime -> the running service holds a stale key
```

**Fix options:**
1. Verify the account can sign in to Windows with the current password and is not locked out — that separates a stale key from a broken credential
2. Restart the SQL Server service so it re-derives its Kerberos key. Change the password through SQL Server Configuration Manager rather than in AD alone, so the stored credential and the directory stay in step
3. Rule out the other causes of `KRB_AP_ERR_MODIFIED` first: duplicate SPN (K8), non-unique service account name across the forest, clock skew (K45)
4. Remove the failure mode entirely by moving to a gMSA or MSA, where Windows rotates and applies the password without a service restart. This is the durable fix for environments with a password rotation policy — see K11 and K34

**Related checks:** K8, K45, K11, K34, K20

---

### K54 — Report Server Missing RSWindowsNegotiate

**What it means:** A Reporting Services or Power BI Report Server only attempts Kerberos when `RSWindowsNegotiate` appears in the `<AuthenticationTypes>` section of `rsreportserver.config`, and it should be first in that list. Without it the report server authenticates with NTLM, and NTLM cannot delegate — so a report that connects onward to a SQL Server or Analysis Services data source as the viewing user fails, no matter how completely SPNs and delegation attributes are configured.

The inverse also causes trouble: `RSWindowsNegotiate` present *without* an `HTTP` SPN on a domain service account produces repeated credential prompts followed by an empty browser window. The two settings have to move together, which is why this check pairs with K17.

**How to spot it:** `<AuthenticationTypes>` in `rsreportserver.config` lacks `RSWindowsNegotiate`, or lists it after `RSWindowsNTLM`. Symptomatically: reports render when the data source uses stored credentials but fail with a connection error when set to use the viewing user's credentials.

**Example:**
```xml
<!-- Kerberos will not be attempted -->
<AuthenticationTypes>
    <RSWindowsNTLM />
</AuthenticationTypes>

<!-- Correct - Negotiate first -->
<AuthenticationTypes>
    <RSWindowsNegotiate />
    <RSWindowsKerberos />
    <RSWindowsNTLM />
</AuthenticationTypes>
```

A quick way to confirm the diagnosis is to remove `RSWindowsNegotiate` temporarily and retry — if the symptom changes, the failure was Kerberos-related.

**Fix options:**
1. Add `<RSWindowsNegotiate />` as the first entry in `<AuthenticationTypes>`, then stop and restart the Report Server service from Report Server Configuration Manager. Configuration file changes do not take effect until the service restarts
2. Register the matching `HTTP` SPNs on the report server service account at the same time — both NetBIOS and FQDN forms, no port. See K17
3. Configure delegation on the report server service account so it can reach the data source, and register the data source's own SPNs (`MSSQLSvc` for SQL Server, `MSOLAPSvc.3` for Analysis Services). A named Analysis Services instance also needs the SQL Browser SPN on that machine
4. Where Kerberos is not actually required, the documented alternative is to remove `RSWindowsNegotiate` and leave only `RSWindowsNTLM`. That permits a domain service account with no SPN at all, at the cost of losing delegation — acceptable when every data source uses stored credentials
5. For trace-log evidence of what the report server was doing when a report failed, see `/ssrstracelog-review`

**Related checks:** K17, K21, K22

---

## Quick Reference — All K1–K54 Checks

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
| K31 | Azure AD Hybrid Join SPN Gap | Service account (on-premises AD) | Critical |
| K32 | Entra-Only Auth With Orphaned AD SPN | Service account | Warning |
| K33 | Azure SQL MI Windows Authentication Flow Not Configured | Entra ID tenant / Trusted Domain Object | Critical |
| K34 | gMSA Password Rollover SPN Drift | gMSA account | Warning |
| K35 | FCI Node-Specific SPN Leak | Service account | Warning |
| K36 | Distributed AG Forwarder Listener SPN Missing | Service account | Critical |
| K37 | TrustedToAuthForDelegation Set for an RBCD Path | Initiating service account | Warning |
| K38 | Encryption Type Mismatch Between Account and KDC Policy | Service account | Warning |
| K39 | Write-SPN Blocked by AdminSDHolder | Service account (AD ACL) | Warning |
| K40 | DNS CNAME Alias Without SPN | Service account | Critical |
| K41 | Linked Server Delegation Path Relies on RBCD | Target computer / service account | Critical |
| K42 | Linked Server Constrained Delegation Below SQL 2017 CU17 | Middle-tier instance build | Critical |
| K43 | SSISDB Package Double-Hop Under Constrained Delegation | SSISDB host service account | Critical |
| K44 | Named Instance Dynamic Port Prevents Kerberos | Instance TCP configuration | Critical |
| K45 | Clock Skew Beyond Kerberos Tolerance | Host time configuration | Critical |
| K46 | Kerberos Token Size Exceeded | Connecting user / MaxTokenSize registry | Critical |
| K47 | RC4-Only Encryption Types Under AES Enforcement | Service account | Critical |
| K48 | Client and Server Across a Forest Boundary | Domain / forest trust | Warning |
| K49 | Keytab Not Configured in mssql-conf | Linux keytab / mssql-conf | Critical |
| K50 | Keytab Encryption Types Mismatch the AD Account | Linux keytab / AD account | Critical |
| K51 | Keytab File Ownership or Permissions Wrong | Linux keytab file | Warning |
| K52 | Legacy Provider Cannot Use Kerberos Over Named Pipes | Client driver | Warning |
| K53 | Service Account Password Changed Without Service Restart | Service account / service state | Warning |
| K54 | Report Server Missing RSWindowsNegotiate | rsreportserver.config | Warning |
