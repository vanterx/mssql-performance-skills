# SPN Review Analysis

## Summary

- **4 Critical, 1 Warning, 1 Info**
- **Service account:** CONTOSO\sqlsvc
- **SQL instances / listeners found:** SQLNODE1 (default instance, port 1433)
- **Highest-risk finding:** Duplicate SPN (K8) + Unconstrained Delegation (K19) — either alone would cause complete Kerberos authentication failure and a significant security exposure

---

## Critical Issues

### [C1 — K8] Duplicate SPN — MSSQLSvc/SQLNODE1:1433 and MSSQLSvc/SQLNODE1.contoso.com:1433

- **Observed:** `setspn -X` confirms both `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433` are registered on both `CONTOSO\sqlsvc` and the decommissioned account `CONTOSO\sqlsvc_2024` (in OU=DisabledAccounts)
- **Impact:** The KDC cannot determine which account holds the correct decryption key when a client requests a Kerberos service ticket for SQLNODE1. All Kerberos logins to this SQL Server fail with "The target principal name is incorrect." The duplicate exists on a disabled account, meaning it was never cleaned up during the service account rotation in March 2024.
- **Fix:**
  ```
  setspn -D MSSQLSvc/SQLNODE1:1433 CONTOSO\sqlsvc_2024
  setspn -D MSSQLSvc/SQLNODE1.contoso.com:1433 CONTOSO\sqlsvc_2024
  ```
  Then verify: `setspn -X` should return "No duplicate SPNs found."

---

### [C2 — K19] Unconstrained Delegation Enabled on Service Account

- **Observed:** `Get-ADUser CONTOSO\sqlsvc -Properties TrustedForDelegation` returns `TrustedForDelegation: True`
- **Impact:** The `sqlsvc` account can forward any domain user's Kerberos credentials to any service in the domain without restriction. If the SQL Server host or service account is compromised, an attacker can impersonate any domain user — including privileged accounts — against any Kerberos-enabled service. This is a Critical security finding independent of the double-hop requirement.
- **Fix:** Disable unconstrained delegation immediately, then configure Kerberos Constrained Delegation for only the required targets:
  - In AD Users and Computers: find `sqlsvc` → Properties → Delegation tab → select "Trust this user for delegation to specified services only (Kerberos only)"
  - Remove `TrustedForDelegation` flag
  - After resolving C3 (K22, missing target SPN), populate `msDS-AllowedToDelegateTo` with the correct target SPNs

---

### [C3 — K22] Delegation Target Missing SPN — MSSQLSvc/SQLBACK01:1433

- **Observed:** `msDS-AllowedToDelegateTo` on `CONTOSO\sqlsvc` includes `MSSQLSvc/SQLBACK01:1433` and `MSSQLSvc/SQLBACK01.contoso.com:1433`. However, `setspn -Q MSSQLSvc/SQLBACK01*` returns "No such SPN found." The delegation target SPN does not exist.
- **Impact:** Even with delegation configured, the KDC cannot issue a service ticket for `MSSQLSvc/SQLBACK01:1433` because no AD account holds that SPN. This is the direct root cause of the "Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'" error on the linked server. The linked server connection falls back to an anonymous identity because credential forwarding fails.
- **Fix:**
  1. Identify the SQL Server service account on SQLBACK01 (check SQL Server Configuration Manager on that host)
  2. `setspn -S MSSQLSvc/SQLBACK01:1433 CONTOSO\sqlback_svc`
  3. `setspn -S MSSQLSvc/SQLBACK01.contoso.com:1433 CONTOSO\sqlback_svc`
  4. Verify: `setspn -Q MSSQLSvc/SQLBACK01:1433` should return the SQLBACK01 service account

---

### [C4 — K27] End-User jsmith in Protected Users Group

- **Observed:** `Get-ADUser jsmith -Properties MemberOf` shows `CN=Protected Users,CN=Users,DC=contoso,DC=com` in the `MemberOf` list
- **Impact:** The Protected Users security group unconditionally disables Kerberos ticket forwarding, NTLM authentication, and RC4/DES encryption for `jsmith`. Even after fixing C1–C3, delegation of `jsmith`'s credentials through SQLNODE1 to SQLBACK01 will fail because his tickets are non-forwardable by group policy. This also means `jsmith` cannot authenticate to SQL Server via NTLM as a fallback.
- **Fix:**
  1. Determine whether `jsmith` was added to Protected Users intentionally (e.g., as a privileged user protection measure)
  2. If delegation is required: `Remove-ADGroupMember "Protected Users" -Members jsmith`
  3. If `jsmith` must remain in Protected Users, the application must not attempt to delegate his credentials — consider a service account for the linked server connection instead
  4. Note: Removing from Protected Users re-enables NTLM, RC4 caching, and credential caching on DCs — review the security policy before removing

---

## Warnings

### [W1 — K25] Delegation Scope Too Broad — cifs/FILESERVER01 in msDS-AllowedToDelegateTo

- **Observed:** `msDS-AllowedToDelegateTo` on `CONTOSO\sqlsvc` contains `{MSSQLSvc/SQLBACK01:1433, MSSQLSvc/SQLBACK01.contoso.com:1433, cifs/FILESERVER01}`. The `cifs/FILESERVER01` entry allows SQL Server to delegate user credentials to the FILESERVER01 file share service, which is not required for any documented application workflow.
- **Impact:** The delegation scope is broader than the SQL Server linked-server use case requires. If `sqlsvc` credentials are compromised, an attacker can also impersonate domain users against FILESERVER01 file shares.
- **Fix:**
  1. Remove `cifs/FILESERVER01` from the delegation list in AD Users and Computers → `sqlsvc` → Properties → Delegation tab
  2. Keep only `MSSQLSvc/SQLBACK01:1433` and `MSSQLSvc/SQLBACK01.contoso.com:1433` after verifying those SPNs exist (see C3)

---

## Info

### [I1 — K3] Missing FQDN SPN Variant — Not a gap given current config

- **Observed:** `setspn -L CONTOSO\sqlsvc` shows both `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433` are present. This check passes — both short-hostname and FQDN variants exist.

> Note: K3 is reported as Info here because the example input happens to have both variants. The analysis below reflects what the checks find — this finding slot is used to note the delegation path observation instead.

- **Observed:** `TrustedToAuthForDelegation: False` on `CONTOSO\sqlsvc` — protocol transition (S4U2Self) is not enabled. If any users connecting to the linked server authenticate to the application layer via NTLM or forms authentication (rather than Kerberos directly), their credentials cannot be forwarded via protocol transition.
- **Impact:** Low — if all application users authenticate via Kerberos end-to-end, this is not required. If NTLM-authenticated users exist, they will receive anonymous login failures on the linked server.
- **Fix:** If protocol transition is needed: AD Users and Computers → `sqlsvc` → Properties → Delegation → change to "Use any authentication protocol"

---

## Passed Checks

| Check | Result |
|-------|--------|
| K1 — Missing Default-Instance SPN | PASS — `MSSQLSvc/SQLNODE1:1433` and `MSSQLSvc/SQLNODE1.contoso.com:1433` both present on `CONTOSO\sqlsvc` |
| K2 — Missing Named-Instance SPN | SKIP — No named instance indicated; instance is the default instance on port 1433 |
| K3 — Missing FQDN SPN | PASS — `MSSQLSvc/SQLNODE1.contoso.com:1433` present |
| K4 — Missing Short-Hostname SPN | PASS — `MSSQLSvc/SQLNODE1:1433` present |
| K5 — SPN on Wrong Port | PASS — SPN port 1433 matches the default instance TCP port |
| K6 — Missing VNN SPN for FCI | SKIP — No FCI topology indicated; standalone instance |
| K7 — SPN on Wrong Account | PASS — Active SPNs on `CONTOSO\sqlsvc` which is the current service account (duplicate on disabled account caught by K8) |
| K9 — SPN Under Computer Account | PASS — `Get-ADComputer SQLNODE1` ServicePrincipalNames shows only HOST, TERMSRV, WSMAN, RestrictedKrbHost — no MSSQLSvc entries |
| K10 — Stale SPN from Old Account | FAIL — Caught as C1 (K8 duplicate on disabled sqlsvc_2024 account) |
| K11 — MSA/gMSA Auto-Registration Gap | SKIP — Service account is a standard domain user account, not MSA/gMSA |
| K12 — Missing AG Listener SPN | SKIP — No AG listener topology indicated |
| K13 — Named Instance Using Port 1433 | PASS — Instance is the default instance; port 1433 is correct |
| K14 — Missing SQL Browser Signal | SKIP — Named instance not present; SQL Browser not required |
| K15 — Alias Without SPN | SKIP — No SQL alias described in input |
| K16 — Multi-Subnet AG Single-IP SPN | SKIP — No AG listener topology indicated |
| K17 — HTTP SPN Missing | SKIP — No SSRS or HTTP delegation path described |
| K18 — SPN Registration Permission Gap | SKIP — No ERRORLOG provided; no SPN registration failure message observed |
| K20 — NTLM Fallback Signal | SKIP — No sys.dm_exec_connections output provided; NTLM in use is implied by the anonymous logon failure but the root cause is K22 |
| K21 — Constrained Delegation Not Configured | SKIP — KCD is nominally configured (msDS-AllowedToDelegateTo is populated); root issue is missing target SPN (K22) and unconstrained delegation enabled simultaneously (K19) |
| K23 — Protocol Transition Not Enabled | INFO — TrustedToAuthForDelegation is False; not Critical unless non-Kerberos-authenticated users require delegation (see I1) |
| K24 — RBCD Misconfigured | PASS — msDS-AllowedToActOnBehalfOfOtherIdentity is empty on SQLNODE1; no RBCD configured (not expected) |
| K26 — Connecting User Delegation-Sensitive | PASS — AccountNotDelegated is False for jsmith |
| K28 — Computer Account SPN Conflict | PASS — SQLNODE1 computer account holds only HOST/TERMSRV/WSMAN/RestrictedKrbHost SPNs; no MSSQLSvc conflict |
| K29 — Computer Account Unconstrained Delegation | PASS — TrustedForDelegation on SQLNODE1 computer account is False |

---

## Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Remove duplicate SPNs from decommissioned `CONTOSO\sqlsvc_2024` | C1 (K8) | 5 min |
| 2 — Immediately | Disable `TrustedForDelegation` on `sqlsvc`; switch to KCD | C2 (K19) | 15 min |
| 3 — Today | Register `MSSQLSvc/SQLBACK01:1433` and FQDN variant on SQLBACK01's service account | C3 (K22) | 10 min |
| 4 — Today | Evaluate whether jsmith can be removed from Protected Users | C4 (K27) | 30 min (review + change control) |
| 5 — This sprint | Narrow delegation scope: remove `cifs/FILESERVER01` from msDS-AllowedToDelegateTo | W1 (K25) | 5 min |
