## SPN Review Analysis

### Summary
- 6 Critical, 2 Warnings, 1 Info
- Service account: `CONTOSO\sqlsvc` (previous account `CONTOSO\sqlsvc_2024`, decommissioned 2024-03)
- SQL instances / listeners found: `SQLNODE1` (default instance, TCP 1433, SQL Server 2016 SP3 — 13.0.6300.2); linked server target `SQLBACK01` referenced but not registered
- Highest-risk finding: K8 — Duplicate SPN on `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433`

The reported symptom — `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'` on linked
server queries from SQLNODE1 to SQLBACK01 — has **four independent causes** in this capture,
any one of which is sufficient to break the double hop. All four must be fixed; resolving
only the duplicate SPN will not restore the linked server.

---

### Critical Issues

### [C1 — K8] Duplicate SPN — MSSQLSvc/SQLNODE1:1433 and MSSQLSvc/SQLNODE1.contoso.com:1433
- **Observed:** `setspn -X` reports 2 groups of duplicate SPNs. Both `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433` are registered on `CONTOSO\sqlsvc` (current, `OU=ServiceAccounts`) and on `CONTOSO\sqlsvc_2024` (decommissioned, `OU=DisabledAccounts`).
- **Impact:** The KDC cannot determine which account holds the correct decryption key, so it refuses to issue a service ticket for either name. Every Kerberos login to SQLNODE1 fails with "The target principal name is incorrect", and clients permitted to fall back land on NTLM — which is what `auth_scheme = NTLM` shows. NTLM cannot delegate, so this alone breaks the double hop.
- **Fix:**
  ```
  setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc_2024
  setspn -D MSSQLSvc/SQLNODE1.contoso.com:1433 CONTOSO\sqlsvc_2024
  ```
  Remove from the decommissioned account, not the current one. Verify afterwards with `setspn -X` — it should report 0 groups.

### [C2 — K19] Unconstrained Delegation Enabled on CONTOSO\sqlsvc
- **Observed:** `TrustedForDelegation : True` on the SQL Server service account, while `msDS-AllowedToDelegateTo` is also populated with three targets.
- **Impact:** The UAC unconstrained-delegation flag takes precedence over the constrained delegation list, so the account can forward any authenticated user's credentials to any service in the domain. If SQLNODE1 is compromised, an attacker can impersonate every connecting user against every service — including the `cifs/FILESERVER01` target already listed. The populated `msDS-AllowedToDelegateTo` gives a false impression that delegation is constrained when it is not.
- **Fix:** Clear the flag so the constrained list actually governs:
  ```powershell
  Set-ADUser sqlsvc -TrustedForDelegation $false
  ```
  Then restart the SQL Server service. Note the interaction with C4 — constrained delegation does not work on this build, so sequence this change as shown in the Prioritized Action Order rather than clearing the flag in isolation.

### [C3 — K22] Delegation Target Missing SPN — MSSQLSvc/SQLBACK01
- **Observed:** `msDS-AllowedToDelegateTo` lists `MSSQLSvc/SQLBACK01:1433` and `MSSQLSvc/SQLBACK01.contoso.com:1433`, but `setspn -Q MSSQLSvc/SQLBACK01*` returns "No such SPN found."
- **Impact:** A constrained delegation entry pointing at an SPN that exists on no AD account fails silently at the KDC — no ticket, and no error explaining why. Even with unconstrained delegation cleared and the version floor met, delegation to SQLBACK01 cannot succeed until the target SPN exists.
- **Fix:** Register the SPNs on the service account that runs SQL Server **on SQLBACK01** — not on `sqlsvc`:
  ```
  setspn -S MSSQLSvc/SQLBACK01.contoso.com:1433 CONTOSO\<sqlback01-service-account>
  setspn -S MSSQLSvc/SQLBACK01:1433 CONTOSO\<sqlback01-service-account>
  ```
  Confirm the SQLBACK01 service account first in SQL Server Configuration Manager on that host.

### [C4 — K42] Linked Server Constrained Delegation Below SQL 2017 CU17
- **Observed:** `SERVERPROPERTY('ProductVersion')` returns `13.0.6300.2` — SQL Server 2016 SP3. Constrained delegation is configured for a linked-server pass-through path via `msDS-AllowedToDelegateTo`.
- **Impact:** Pass-through authentication over a linked server with constrained delegation was introduced in SQL Server 2017 (14.x) CU17. On SQL Server 2016 only *full* delegation carries the caller's identity across the second hop, so the constrained delegation configuration on this account has no effect for the linked server path. This is why the delegation "looks correct" in AD yet the second hop still arrives as `ANONYMOUS LOGON`, and why C2 cannot be actioned on its own.
- **Fix:** Patch SQLNODE1 to SQL Server 2017 CU17 or later, then clear `TrustedForDelegation` and let the constrained list govern. If the upgrade cannot be scheduled, retain full delegation as a documented, time-boxed exception to K19 with the patch as its removal trigger. Do not substitute RBCD — linked servers do not support it in any version (K41).

### [C5 — K27] End User in Protected Users — jsmith
- **Observed:** `jsmith` is a member of `CN=Protected Users,CN=Users,DC=contoso,DC=com`. `AccountNotDelegated` is `False`, so the per-account sensitivity flag is not the cause. Domain functional level is Windows Server 2016.
- **Impact:** At Windows Server 2012 R2 or later domain functional level, Protected Users members cannot be delegated by unconstrained *or* constrained delegation, cannot use NTLM, and cannot use DES or RC4 in preauthentication. jsmith's credentials cannot traverse the second hop under any delegation model, so his queries fail even once C1–C4 are resolved. No server-side change helps.
- **Fix:** Decide per user whether delegation is genuinely required. To restore it:
  ```powershell
  Remove-ADGroupMember "Protected Users" -Members jsmith
  ```
  Review the security trade-off first — removal re-enables NTLM and credential caching for that user. RBCD is not a workaround; the restriction covers every delegation type. Confirm the diagnosis from the `ProtectedUserFailures-DomainController` log (event 104 for a DES/RC4 preauthentication failure).

### [C6 — K47] RC4-Only Encryption Types Under AES Enforcement
- **Observed:** `msDS-SupportedEncryptionTypes : 4` on `CONTOSO\sqlsvc` — RC4-HMAC only. The KDC's `DefaultDomainSupportedEncTypes` is `24` (AES128 + AES256), and the AD team confirms RC4 was disabled domain-wide in November 2025.
- **Impact:** The service account advertises only an encryption type the domain no longer issues, so the KDC cannot build a service ticket for `MSSQLSvc/SQLNODE1:1433` at all — it returns `KDC_ERR_ETYPE_NOTSUPP` (`0xE`). This is a second, independent cause of the NTLM fallback already attributed to C1: fixing the duplicate SPN alone will not restore Kerberos while the account remains RC4-only.
- **Fix:**
  ```powershell
  Set-ADUser sqlsvc -KerberosEncryptionType AES128,AES256
  ```
  `PasswordLastSet` is 2025-11-02, comfortably after AES support existed in Windows Kerberos, so the account already holds AES keys and no password reset is needed. Restart the SQL Server service, then confirm with `klist purge` followed by `klist get MSSQLSvc/SQLNODE1.contoso.com:1433`.

---

### Warnings

### [W1 — K25] Delegation Scope Too Broad — cifs/FILESERVER01
- **Observed:** `msDS-AllowedToDelegateTo` contains `cifs/FILESERVER01` alongside the two `MSSQLSvc/SQLBACK01` entries.
- **Impact:** The stated requirement is a SQL-to-SQL linked server hop. A `cifs` target lets the SQL Server service impersonate users against the file server's SMB shares, which is outside that requirement and enlarges the blast radius of a SQLNODE1 compromise.
- **Fix:** Remove the entry unless a documented requirement exists:
  ```powershell
  Set-ADUser sqlsvc -Remove @{'msDS-AllowedToDelegateTo' = 'cifs/FILESERVER01'}
  ```

### [W2 — K10] Stale SPNs on Decommissioned Account CONTOSO\sqlsvc_2024
- **Observed:** The service account decommissioned in March 2024 still holds `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433`, in `OU=DisabledAccounts`.
- **Impact:** These stale registrations are the direct cause of the C1 duplicates. Left in place after any future re-registration, they will reintroduce the same outage.
- **Fix:** Covered by the C1 `setspn -D` commands. Add an SPN-cleanup step to the service account decommissioning runbook so the next account change does not repeat this.

---

### Info

### [I1 — K20] NTLM Fallback Confirmed on a Live Connection
- **Observed:** `sys.dm_exec_connections` reports `auth_scheme = NTLM` with `net_transport = TCP` on `local_tcp_port` 1433, from the .Net SqlClient Data Provider.
- **Impact:** Confirms the failure empirically rather than by inference — the instance is genuinely not authenticating with Kerberos. TCP transport and a modern driver rule out K52 (legacy provider over named pipes) as a contributing cause, which narrows the diagnosis to C1 and C6.
- **Fix:** No independent action. Re-run this query after C1 and C6 are resolved; `auth_scheme` should read `KERBEROS`. This is the acceptance test for the whole remediation.

---

### Prioritized Action Order

Order matters here. C4 gates C2 — clearing unconstrained delegation before the instance can
actually use constrained delegation would break the linked server outright rather than fix it.

| # | Action | Check | Risk | Downtime |
|---|--------|-------|------|----------|
| 1 | `setspn -D` both SPNs from `CONTOSO\sqlsvc_2024` | K8, K10 | Low | None |
| 2 | `Set-ADUser sqlsvc -KerberosEncryptionType AES128,AES256` | K47 | Low | Service restart |
| 3 | Register `MSSQLSvc/SQLBACK01` SPNs on the SQLBACK01 service account | K22 | Low | None |
| 4 | Verify `auth_scheme = KERBEROS` on SQLNODE1 before proceeding | K20 | None | None |
| 5 | Remove `cifs/FILESERVER01` from the delegation list | K25 | Low | None |
| 6 | Decide on jsmith's Protected Users membership | K27 | Medium — security posture | None |
| 7 | Patch SQLNODE1 to SQL Server 2017 CU17 or later | K42 | Medium | Planned maintenance |
| 8 | `Set-ADUser sqlsvc -TrustedForDelegation $false` — **only after step 7** | K19 | Medium | Service restart |

Steps 1–4 restore Kerberos to SQLNODE1 itself. Steps 7–8 are what actually fix the linked
server double hop, and until step 7 completes the account must keep unconstrained delegation
(C2) for the linked server to work at all — record that as an accepted exception with step 7
as its removal trigger.

---

### Passed Checks

| Check | Result |
|-------|--------|
| K1 — Missing Default-Instance SPN | PASS — `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433` both present on `CONTOSO\sqlsvc` |
| K2 — Missing Named-Instance SPN | SKIP — SQLNODE1 is the default instance |
| K3 — Missing FQDN SPN | PASS — `MSSQLSvc/SQLNODE1.contoso.com:1433` present |
| K4 — Missing Short-Hostname SPN | PASS — `MSSQLSvc/SQLNODE1:1433` present |
| K5 — SPN on Wrong Port | PASS — SPN port 1433 matches `local_tcp_port` 1433 |
| K6 — Missing VNN SPN for FCI | SKIP — no FCI topology indicated in input |
| K7 — SPN on Wrong Account | PASS — SPNs present on the current service account `CONTOSO\sqlsvc`; also duplicated on the old account, reported as C1 |
| K9 — SPN Under Computer Account | PASS — `SQLNODE1$` holds only HOST / TERMSRV / WSMAN / RestrictedKrbHost SPNs, no `MSSQLSvc` |
| K11 — MSA/gMSA Auto-Registration Gap | SKIP — `sqlsvc` is a standard domain user account, not an MSA or gMSA |
| K12 — Missing AG Listener SPN | SKIP — no availability group listener in input |
| K13 — Named Instance Using Port 1433 | SKIP — default instance, 1433 is correct |
| K14 — Missing SQL Browser Signal | SKIP — default instance does not require SQL Browser |
| K15 — Alias Without SPN | SKIP — no alias configuration provided |
| K16 — Multi-Subnet AG Single-IP SPN | SKIP — no availability group in input |
| K17 — HTTP SPN Missing | SKIP — no SSRS or HTTP delegation target described |
| K18 — SPN Registration Permission Gap | NOT ASSESSED — computer object ACL not provided; SPNs exist, so registration has succeeded at some point |
| K21 — Constrained Delegation Not Configured | PASS — `msDS-AllowedToDelegateTo` is populated, though ineffective on this build (see C4) |
| K23 — Protocol Transition Not Enabled | PASS — `TrustedToAuthForDelegation : False`, and no protocol-transition requirement described |
| K24 — RBCD Misconfigured | SKIP — RBCD not in use; `msDS-AllowedToActOnBehalfOfOtherIdentity` empty on SQLNODE1 |
| K26 — Connecting User Delegation-Sensitive | PASS — `AccountNotDelegated : False` on jsmith; blocked by Protected Users instead (see C5) |
| K28 — Computer Account SPN Conflict | PASS — no `MSSQLSvc` SPNs on `SQLNODE1$` |
| K29 — Computer Account Unconstrained Delegation | PASS — `TrustedForDelegation : False` on `SQLNODE1$` |
| K30 — Service Account in Protected Users | PASS — `sqlsvc` is in SQLServerAdmins and DomainUsers only |
| K31 — Entra ID Hybrid Join SPN Gap | SKIP — no Entra ID hybrid join indicated |
| K32 — Entra-Only Auth With Orphaned AD SPN | SKIP — instance uses Windows Authentication, not Entra-only |
| K33 — Azure SQL MI Windows Authentication Flow | SKIP — no Azure SQL Managed Instance in input |
| K34 — gMSA Password Rollover SPN Drift | SKIP — not a gMSA |
| K35 — FCI Node-Specific SPN Leak | SKIP — no FCI topology |
| K36 — Distributed AG Forwarder Listener SPN Missing | SKIP — no distributed AG |
| K37 — TrustedToAuthForDelegation Set for an RBCD Path | PASS — RBCD not in use and the flag is `False` |
| K38 — Encryption Type Mismatch | PASS at this level — the specific RC4-only condition is reported as C6 under K47 |
| K39 — Write-SPN Blocked by AdminSDHolder | PASS — `adminCount` empty on `sqlsvc`; not a member of a protected group |
| K40 — DNS CNAME Alias Without SPN | SKIP — no CNAME alias described |
| K41 — Linked Server Delegation Path Relies on RBCD | PASS — delegation uses `msDS-AllowedToDelegateTo`, not RBCD; correct model for a linked server |
| K43 — SSISDB Double-Hop Under Constrained Delegation | SKIP — no SSIS package execution described |
| K44 — Named Instance Dynamic Port | SKIP — default instance on static port 1433 |
| K45 — Clock Skew Beyond Kerberos Tolerance | PASS — offset against DC01 is +0.022 s across 3 samples, far inside the 5-minute tolerance |
| K46 — Kerberos Token Size Exceeded | PASS — jsmith holds 3 group memberships; no error 17832 reported |
| K48 — Client and Server Across a Forest Boundary | PASS — all principals are in `DC=contoso,DC=com` |
| K49 — Keytab Not Configured in mssql-conf | SKIP — Windows instance, not SQL Server on Linux |
| K50 — Keytab Encryption Types Mismatch | SKIP — Windows instance |
| K51 — Keytab File Ownership or Permissions | SKIP — Windows instance |
| K52 — Legacy Provider Over Named Pipes | PASS — `net_transport = TCP` with the .Net SqlClient Data Provider; Kerberos is supported on this path |
| K53 — Password Changed Without Service Restart | PASS — `PasswordLastSet` 2025-11-02, `LockedOut : False`; no recent password change correlates with the failure |
| K54 — Report Server Missing RSWindowsNegotiate | SKIP — no Reporting Services in input |

---
*Analyzed by: Claude Opus 5 · 2026-07-30 14:22 NZST*
