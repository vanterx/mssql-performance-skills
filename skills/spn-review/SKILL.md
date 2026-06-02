---
name: spn-review
description: Analyzes SQL Server SPN (Service Principal Name) configuration and Kerberos delegation settings to diagnose authentication failures, NTLM fallback, and double-hop connectivity problems. Use this skill when users receive Kerberos errors, linked servers fall back to NTLM, AG listener connections fail, or constrained delegation is needed for a middle-tier application, and you need to identify missing, duplicate, or misconfigured SPNs and delegation settings. Applies 40 checks (K1–K40) covering SPN presence, service account binding, AG listener and alias, permissions, Kerberos delegation, AD account sensitivity, Azure AD hybrid, and advanced gMSA/FCI/delegation scenarios.
triggers:
  - /spn-review
---

# SQL Server SPN and Kerberos Delegation Review Skill

## Purpose

Analyze SQL Server SPN configuration and Active Directory delegation attributes to surface
Kerberos authentication failures, NTLM fallback causes, and double-hop connectivity problems.
Applies 40 checks (K1–K40) across seven categories:

- **K1–K6** — MSSQLSvc SPN presence: default instance, named instance, FQDN variant,
  short-hostname variant, port mismatch, and FCI Virtual Network Name
- **K7–K11** — Service account binding: SPN on wrong account, duplicate SPNs, machine account
  vs domain account, stale SPNs from old accounts, MSA/gMSA auto-registration gaps
- **K12–K16** — AG listener and alias: listener SPN, named instance port conflict, SQL Browser,
  alias SPN, multi-subnet listener coverage
- **K17–K20** — Configuration and permissions: HTTP SPN, registration permission gap,
  unconstrained delegation, NTLM fallback signal
- **K21–K25** — Kerberos delegation — service account: constrained delegation (KCD) not
  configured, missing target SPN, protocol transition, RBCD misconfiguration, delegation scope
- **K26–K30** — AD account and computer sensitivity: AccountNotDelegated on end-user, Protected
  Users membership on end-user, computer account SPN conflict, computer account unconstrained
  delegation, service account in Protected Users
- **K31–K40** — Azure AD / hybrid and advanced scenarios: Entra ID hybrid SPN gap, Entra-only
  auth with orphaned AD SPN, Azure SQL MI on-premises SPN, gMSA rollover drift, FCI node SPN
  leak, distributed AG forwarder SPN, S4U2Proxy without protocol transition, Kerberos FAST
  incompatibility, AdminSDHolder SPN write block, DNS CNAME alias without SPN

## Input

Accept any of:

1. **setspn output** — paste output from one or more of:
   - `setspn -L domain\sqlsvc` (SPNs registered on a specific account)
   - `setspn -Q MSSQLSvc/*` (all MSSQLSvc SPNs in the domain)
   - `setspn -X` (duplicate SPN report across all accounts)
2. **AD attribute output** — paste output from `Get-ADUser` or `Get-ADComputer` showing
   delegation attributes (`TrustedForDelegation`, `TrustedToAuthForDelegation`,
   `msDS-AllowedToDelegateTo`, `msDS-AllowedToActOnBehalfOfOtherIdentity`, `memberOf`)
3. **Natural language description** — describe the authentication failure, the SQL instance
   name, the service account, and any error messages observed

For best results, provide output from all capture commands below. When only partial data is
available, state which checks cannot be evaluated and why.

### Capture Commands

```powershell
setspn -Q MSSQLSvc/*
setspn -L DOMAIN\sqlsvc
setspn -X
Get-ADUser DOMAIN\sqlsvc -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo, ServicePrincipalNames, MemberOf
Get-ADComputer SQLNODE1 -Properties TrustedForDelegation, msDS-AllowedToActOnBehalfOfOtherIdentity, ServicePrincipalNames
# Verify cached Kerberos tickets on the client machine (run as the connecting user)
klist
# Clear ticket cache to force fresh acquisition during testing
klist purge
```

---

## Thresholds Reference

| Threshold | Value | Used by |
|-----------|-------|---------|
| Duplicate SPN | 2 or more accounts holding identical SPN | K8 — Critical |
| Port mismatch tolerance | Exact match required between SPN port and SQL TCP port | K5, K13 |
| Unconstrained delegation | Any account with TrustedForDelegation = True | K19, K29 — Critical |
| Delegation target missing SPN | Any missing target SPN in msDS-AllowedToDelegateTo | K22 — Critical |
| Protected Users membership | Any SQL service account or end-user in Protected Users | K27, K30 — Critical |

---

## MSSQLSvc SPN Presence Checks (K1–K6)

Run these first. They confirm the KDC can resolve the SQL Server target.
### K1 — Missing Default-Instance SPN
- **Trigger:** SQL Server is the default instance (port 1433) but no `MSSQLSvc/<host>:1433` or `MSSQLSvc/<FQDN>:1433` SPN is present on the service account
- **Severity:** Critical
- **Fix:** `setspn -S MSSQLSvc/<host>:1433 DOMAIN\sqlsvc` and `setspn -S MSSQLSvc/<host.domain.com>:1433 DOMAIN\sqlsvc`
### K2 — Missing Named-Instance SPN
- **Trigger:** Named SQL instance present but no `MSSQLSvc/<host>:<port>` SPN exists for the instance's TCP port
- **Severity:** Critical
- **Fix:** `setspn -S MSSQLSvc/<host>:<port> DOMAIN\sqlsvc` using the actual dynamic port from SQL Server Configuration Manager
### K3 — Missing FQDN SPN
- **Trigger:** Short-hostname SPN exists (`MSSQLSvc/SQLNODE1:1433`) but no fully-qualified SPN (`MSSQLSvc/SQLNODE1.domain.com:1433`)
- **Severity:** Warning
- **Fix:** `setspn -S MSSQLSvc/<host.domain.com>:1433 DOMAIN\sqlsvc`; clients using FQDN in their connection string fail Kerberos without the FQDN variant
### K4 — Missing Short-Hostname SPN
- **Trigger:** FQDN SPN exists (`MSSQLSvc/SQLNODE1.domain.com:1433`) but no short-hostname SPN (`MSSQLSvc/SQLNODE1:1433`)
- **Severity:** Warning
- **Fix:** `setspn -S MSSQLSvc/<netbios>:1433 DOMAIN\sqlsvc`; clients using NetBIOS name in the connection string will fall back to NTLM
### K5 — SPN on Wrong Port
- **Trigger:** A `MSSQLSvc/<host>:<port>` SPN exists but the port does not match the SQL Server's actual TCP listening port
- **Severity:** Critical — see Thresholds Reference (exact match required)
- **Fix:** `setspn -D MSSQLSvc/<host>:<wrong-port> DOMAIN\sqlsvc` then `setspn -S MSSQLSvc/<host>:<correct-port> DOMAIN\sqlsvc`
### K6 — Missing VNN SPN for FCI
- **Trigger:** Failover Cluster Instance (FCI) detected but no SPN registered for the Virtual Network Name (VNN)
- **Severity:** Critical
- **Fix:** Register `MSSQLSvc/<VNN>:1433` (or appropriate port) on the service account; the VNN, not the physical node name, is what clients connect to

---

## Service Account Binding Checks (K7–K11)
### K7 — SPN on Wrong Account
- **Trigger:** `MSSQLSvc/<host>:<port>` SPN is registered on an account other than the SQL Server service account currently running the instance
- **Severity:** Critical
- **Fix:** `setspn -D MSSQLSvc/<host>:<port> DOMAIN\wrongaccount` then `setspn -S MSSQLSvc/<host>:<port> DOMAIN\sqlsvc`; verify the SQL Server service account in SQL Server Configuration Manager
### K8 — Duplicate SPN
- **Trigger:** `setspn -X` or `setspn -Q` reveals the same `MSSQLSvc/<host>:<port>` registered on 2 or more accounts — see Thresholds Reference
- **Severity:** Critical
- **Fix:** `setspn -D MSSQLSvc/<host>:<port> DOMAIN\duplicate-account`; only one account should own the SPN; the KDC cannot disambiguate and will reject all Kerberos tickets for that target
### K9 — SPN Under Computer Account
- **Trigger:** SQL Server runs under a domain account but an identical `MSSQLSvc/<host>:<port>` SPN is found on the machine (computer) account
- **Severity:** Warning
- **Fix:** Remove SPN from computer account; move to service account; disable automatic SPN registration to prevent re-registration by NETWORK SERVICE logic
### K10 — Stale SPN from Old Account
- **Trigger:** `MSSQLSvc/<host>:<port>` SPN found on a former service account after the service account was changed
- **Severity:** Warning
- **Fix:** `setspn -D MSSQLSvc/<host>:<port> DOMAIN\oldsqlsvc`; stale SPNs cause K8 (duplicate) even after a planned account migration
### K11 — MSA/gMSA Auto-Registration Gap
- **Trigger:** SQL Server runs as a Managed Service Account (MSA) or group Managed Service Account (gMSA) but the FQDN variant of the SPN is absent from the account's `ServicePrincipalNames` attribute
- **Severity:** Info
- **Fix:** Verify both `MSSQLSvc/<host>:port` and `MSSQLSvc/<host.domain.com>:port` exist; MSA/gMSA auto-registration creates the short-hostname SPN but sometimes skips the FQDN variant

---

## AG Listener and Alias Checks (K12–K16)
### K12 — Missing AG Listener SPN
- **Trigger:** An Always On Availability Group listener name is referenced in the input but no `MSSQLSvc/<listener>:<port>` SPN is registered
- **Severity:** Critical
- **Fix:** Register `setspn -S MSSQLSvc/<listener-name>:1433 DOMAIN\sqlsvc` on each replica's service account; the listener name resolves differently than the node hostname
### K13 — Named Instance Using Port 1433
- **Trigger:** Named instance SPN is registered with port 1433 (`MSSQLSvc/<host>:1433`) but the instance is not the default instance — see Thresholds Reference
- **Severity:** Critical
- **Fix:** Remove wrong-port SPN; determine the actual dynamic port in SQL Server Configuration Manager; register the correct port SPN
### K14 — Missing SQL Browser Signal
- **Trigger:** Named instance exists and no confirmation that SQL Browser service is running is provided
- **Severity:** Info
- **Fix:** Verify SQL Browser service is running (`Start-Service SQLBrowser`); named instances depend on SQL Browser for port resolution when clients omit the explicit port from the connection string
### K15 — Alias Without SPN
- **Trigger:** A SQL Server alias (via cliconfg or SQL Server Configuration Manager) is configured using a name that has no corresponding `MSSQLSvc/<alias-name>:<port>` SPN
- **Severity:** Warning
- **Fix:** Register `setspn -S MSSQLSvc/<alias-name>:<port> DOMAIN\sqlsvc`; Kerberos ticket requests use the connection target name, not the resolved hostname
### K16 — Multi-Subnet AG Single-IP SPN
- **Trigger:** AG listener has multiple IP addresses (multi-subnet AG) but SPN is registered for only one hostname variant
- **Severity:** Warning
- **Fix:** Register SPN for each DNS name that resolves to the listener across subnets; clients on the secondary subnet may connect using a different name resolution path

---

## Configuration and Permissions Checks (K17–K20)
### K17 — HTTP SPN Missing
- **Trigger:** Delegation to a Reporting Services (SSRS) endpoint or linked server using HTTP is described, but no `HTTP/<host>` SPN is registered on the relevant service account
- **Severity:** Warning
- **Fix:** `setspn -S HTTP/<host> DOMAIN\svcaccount`; Kerberos delegation to HTTP targets requires the HTTP SPN on the target service account
### K18 — SPN Registration Permission Gap
- **Trigger:** Service account lacks the `Write ServicePrincipalName` permission on its own AD user object, preventing self-registration of SPNs; or SQL Server ERRORLOG contains error 17806, 17807, or Windows return code 0x2098 in an SPN registration failure message
- **Severity:** Warning
- **Fix:** Grant the service account Self-Write SPN permission via ADSI Edit or `dsacls`; alternatively, a Domain Admin can register SPNs manually using `setspn -S`
### K19 — Unconstrained Delegation Enabled
- **Trigger:** `TrustedForDelegation = True` on the SQL Server service account — see Thresholds Reference
- **Severity:** Critical
- **Fix:** Disable unconstrained delegation in AD Users and Computers; configure Kerberos Constrained Delegation (KCD) instead by populating `msDS-AllowedToDelegateTo` with only the target service SPNs; unconstrained delegation allows credential forwarding to any service
### K20 — NTLM Fallback Signal
- **Trigger:** NTLM authentication is observed despite SPNs appearing to exist (`sys.dm_exec_connections` shows `auth_scheme = NTLM`); or Kerberos ticket requests fail with "target principal name is incorrect"; or the connection is a loopback (SQL Agent job, SSIS package on the same host, `OPENQUERY` to `(local)`) where Windows loopback detection blocks Kerberos regardless of SPN state
- **Severity:** Info
- **Fix:** Verify SPN matches the exact hostname in the client connection string (case-insensitive but must be character-for-character the same); check that SQL Server encryption settings do not redirect the connection to a different hostname; confirm the SPN is on the active service account

---

## Kerberos Delegation — Service Account Checks (K21–K25)
### K21 — Constrained Delegation Not Configured
- **Trigger:** A double-hop scenario is described (client → SQL A → SQL B or SQL → SSRS/linked server) but `msDS-AllowedToDelegateTo` is empty on the middle-tier service account
- **Severity:** Critical
- **Fix:** Configure KCD via AD Users and Computers → service account → Delegation tab → "Trust this user for delegation to specified services only"; add the target service SPNs
### K22 — Delegation Target Missing SPN
- **Trigger:** KCD is configured (`msDS-AllowedToDelegateTo` is populated) but one or more listed target SPNs do not exist on any AD account — see Thresholds Reference
- **Severity:** Critical
- **Fix:** Register the missing SPN on the target service account; a KCD entry pointing to a non-existent SPN will fail silently at the KDC
### K23 — Protocol Transition Not Enabled
- **Trigger:** Middle-tier application (SSRS, web service) needs to delegate credentials for users who authenticated via non-Kerberos means (NTLM, forms, certificate), but `TrustedToAuthForDelegation` is absent from the service account
- **Severity:** Warning
- **Fix:** Enable "Use any authentication protocol" on the service account in AD Users and Computers → Delegation tab; this enables S4U2Self (protocol transition) so the service can obtain a forwardable ticket for any user
### K24 — RBCD Misconfigured
- **Trigger:** Resource-based Constrained Delegation (RBCD) is intended: `msDS-AllowedToActOnBehalfOfOtherIdentity` is present on the target computer, but the initiating service account is not in the ACL
- **Severity:** Warning
- **Fix:** Add the initiating service account's SID to the RBCD ACL on the target computer object: `Set-ADComputer <target> -PrincipalsAllowedToDelegateToAccount <initiating-account>`
### K25 — Delegation Scope Too Broad
- **Trigger:** `msDS-AllowedToDelegateTo` contains service SPNs beyond `MSSQLSvc/*` — for example, `cifs/*` or `host/*` — that are not required for the intended SQL Server delegation path
- **Severity:** Info
- **Fix:** Narrow the delegation scope to only the specific target SPNs required; broad delegation targets reduce the security benefit of constrained delegation

---

## AD Account and Computer Sensitivity Checks (K26–K30)
### K26 — Connecting User Delegation-Sensitive
- **Trigger:** `AccountNotDelegated = True` is set on the end-user AD account that needs to authenticate through a delegating SQL Server
- **Severity:** Critical
- **Fix:** Remove `AccountNotDelegated` flag if delegation is intentional for this user (`Set-ADUser <user> -AccountNotDelegated 0`); alternatively, use RBCD (K24) which does not require the user's ticket to be forwardable
### K27 — User in Protected Users Group
- **Trigger:** The end-user whose credentials need to be delegated is a member of the Protected Users security group — see Thresholds Reference
- **Severity:** Critical
- **Fix:** Remove the user from Protected Users if Kerberos delegation is required; note that Protected Users also disables NTLM authentication and RC4 encryption for the user — review the security implications before removing
### K28 — Computer Account SPN Conflict
- **Trigger:** SQL Server runs under a domain service account but the host computer account also holds `MSSQLSvc/<host>:<port>` SPNs — both accounts have the same SPN
- **Severity:** Warning
- **Fix:** Choose one owner: service account (preferred for security) or computer account; remove SPNs from the non-authoritative account using `setspn -D`
### K29 — Computer Account Unconstrained Delegation
- **Trigger:** The SQL Server host computer account has `TrustedForDelegation = True` — see Thresholds Reference
- **Severity:** Critical
- **Fix:** Disable unconstrained delegation on the computer account; configure KCD or RBCD on the computer object for only the specific service SPNs required
### K30 — Service Account in Protected Users
- **Trigger:** The SQL Server service account is a member of the Protected Users security group — see Thresholds Reference
- **Severity:** Critical
- **Fix:** Remove the SQL service account from Protected Users immediately; Protected Users disables delegation, RC4, and DES encryption, and may prevent Kerberos authentication from working for the service at all

---

## Azure AD / Hybrid and Advanced Checks (K31–K40)
### K31 — Azure AD Hybrid Join SPN Gap
- **Trigger:** SQL Server instance is in an Entra ID (Azure AD) hybrid-joined environment but no `MSSQLSvc/<host>:<port>` SPN is registered in the on-premises AD for the SQL instance
- **Severity:** Critical
- **Fix:** Register the SPN in on-premises AD (`setspn -S MSSQLSvc/<host>:<port> DOMAIN\sqlsvc`); Entra Kerberos for hybrid-joined devices still resolves SPNs through on-premises AD for SQL Server targets — the SPN must exist on both legs
### K32 — Entra-Only Auth With Orphaned AD SPN
- **Trigger:** SQL Server is configured for Azure AD–only authentication (`CREATE LOGIN ... FROM EXTERNAL PROVIDER`) but `setspn -L` shows a traditional AD `MSSQLSvc` SPN still registered on the service account — SQL 2022+ / Azure SQL
- **Severity:** Warning
- **Fix:** Remove the orphaned SPN (`setspn -D MSSQLSvc/<host>:<port> DOMAIN\sqlsvc`) to avoid confusing on-premises clients that attempt Kerberos against a SQL instance that no longer accepts Windows-integrated logins
### K33 — Azure SQL Managed Instance SPN for On-Premises Clients
- **Trigger:** An Azure SQL Managed Instance hostname is referenced in the input but no `MSSQLSvc/<mi-hostname>:1433` SPN is registered in the on-premises AD — Azure SQL MI only
- **Severity:** Critical
- **Fix:** Register the SPN for the MI private endpoint hostname in on-premises AD; on-premises applications connecting to MI via VPN or ExpressRoute need the SPN for Kerberos ticket issuance
### K34 — gMSA Password Rollover SPN Drift
- **Trigger:** SQL Server runs as a group Managed Service Account (gMSA) and the SPN list returned by `setspn -L` differs from the `ServicePrincipalNames` attribute in `Get-ADServiceAccount` output for the same gMSA
- **Severity:** Warning
- **Fix:** Re-register the missing SPNs manually; gMSA automatic password rollover can occasionally cause SPN registration to lag behind; verify with `Test-ADServiceAccount` and `setspn -L`
### K35 — FCI Node-Specific SPN Leak
- **Trigger:** Physical node hostnames of a Failover Cluster Instance (FCI) appear in `setspn -Q MSSQLSvc/*` results alongside the Virtual Network Name (VNN) SPN
- **Severity:** Warning
- **Fix:** Remove SPNs registered against physical node names (`setspn -D MSSQLSvc/<node-name>:<port> DOMAIN\sqlsvc`); clients connecting to the physical node name may succeed with Kerberos while VNN connections fail, creating intermittent authentication failures after failover
### K36 — Distributed AG Forwarder Listener SPN Missing
- **Trigger:** A Distributed Availability Group (DAG) is described and the forwarder replica's listener name has no `MSSQLSvc/<forwarder-listener>:<port>` SPN registered — SQL 2016+
- **Severity:** Critical
- **Fix:** Register `setspn -S MSSQLSvc/<forwarder-listener-name>:<port> DOMAIN\sqlsvc` on each replica's service account; the forwarder introduces a second AG whose listener is an additional Kerberos target distinct from either underlying AG's listener
### K37 — S4U2Proxy Without Protocol Transition
- **Trigger:** Resource-based Constrained Delegation (RBCD) is configured (`msDS-AllowedToActOnBehalfOfOtherIdentity` present on target) but the initiating service account lacks `TrustedToAuthForDelegation` (S4U2Self / protocol transition not enabled)
- **Severity:** Warning
- **Fix:** Enable "Use any authentication protocol" on the initiating service account (`Set-ADUser <account> -TrustedToAuthForDelegation $true`); S4U2Proxy (forwarding a ticket to the target) requires S4U2Self to first obtain a forwardable service ticket for the user
### K38 — Kerberos FAST Armoring Incompatibility
- **Trigger:** Domain controllers enforce Kerberos FAST armoring (Flexible Authentication Secure Tunneling) via policy and the SQL Server service account's `msDS-SupportedEncryptionTypes` attribute does not include AES keys — Windows Server 2012+
- **Severity:** Warning
- **Fix:** Add AES 128/256 encryption type support to the service account (`Set-ADUser <sqlsvc> -KerberosEncryptionType AES128,AES256`); RC4-only accounts cannot authenticate under FAST policy, causing silent fallback to NTLM
### K39 — Write-SPN Blocked by AdminSDHolder
- **Trigger:** The SQL Server service account's `ServicePrincipalName` attribute shows `DENY` on `Write ServicePrincipalName` or the account is a member of a privileged AD group (Domain Admins, Enterprise Admins, etc.) — AdminSDHolder resets ACLs hourly via SDProp
- **Severity:** Warning
- **Fix:** Move the SQL Server service account out of privileged AD groups (use a dedicated low-privilege domain account for SQL services); SDProp only resets ACLs on accounts in adminCount=1 groups; a dedicated service account is not subject to AdminSDHolder
### K40 — DNS CNAME Alias Without SPN
- **Trigger:** The connection string or client configuration references a DNS CNAME alias that resolves to the SQL Server host's A record, but no `MSSQLSvc/<cname>:<port>` SPN is registered for the alias name
- **Severity:** Critical
- **Fix:** Register `setspn -S MSSQLSvc/<cname>:<port> DOMAIN\sqlsvc`; Kerberos ticket requests use the name from the client connection string, not the resolved A record; a CNAME alias requires its own SPN entry independent of the host's SPN

---

## Output Format

Structure the report as follows:

```
## SPN Review Analysis

### Summary
- X Critical, Y Warnings, Z Info
- Service account: [detected or "unknown — not provided"]
- SQL instances / listeners found: [list]
- Highest-risk finding: [check name and ID]

### Critical Issues

### [C1 — K8] Duplicate SPN — MSSQLSvc/SQLNODE1:1433
- **Observed:** SPN MSSQLSvc/SQLNODE1:1433 registered on both DOMAIN\sqlsvc and DOMAIN\oldsqlsvc (from setspn -X output)
- **Impact:** KDC cannot determine which account holds the correct decryption key; all Kerberos logins to SQLNODE1:1433 fail with "The target principal name is incorrect"
- **Fix:** Remove duplicate: setspn -D MSSQLSvc/SQLNODE1:1433 DOMAIN\oldsqlsvc

### Warnings

### Info

### Passed Checks

| Check | Result |
|-------|--------|
| K1 — Missing Default-Instance SPN | PASS — MSSQLSvc/SQLNODE1:1433 and MSSQLSvc/SQLNODE1.domain.com:1433 both present on DOMAIN\sqlsvc |
| K6 — Missing VNN SPN for FCI | SKIP — no FCI topology indicated in input |

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*
```

Output labels use `[C1]`, `[W1]`, `[I1]` sequential numbering with check ID in parentheses.
Each finding includes Observed (what the input shows), Impact (why it matters), and Fix
(concrete command or step). The Passed Checks table explicitly lists every check evaluated
and the evidence for each PASS or SKIP.

---

## Notes

- When `setspn -X` output is not provided, K8 (duplicate SPN) cannot be fully evaluated — state the limitation.
- When AD attribute output is absent, K19–K25 and K26–K30 may be partially or fully unevaluable — list each as SKIP with the missing data noted.
- Connection string hostname must match the SPN hostname character-for-character (case-insensitive); an alias, IP address, or CNAME resolving to the host does not satisfy the SPN requirement.
- SPNs for named instances use the TCP port, not the instance name; the SQL Browser service resolves instance names to ports but is not involved in Kerberos ticket issuance.
- FCI SPNs must use the VNN, not the physical node names; individual node SPNs are irrelevant to client connections.
- RBCD (K24) requires Windows Server 2012 R2 or later domain controllers; classic KCD (K21) requires the middle-tier service account to be in the same domain as the target.

---

### Section: Output Filters (--brief / --critical-only)

**`--brief`** — Omit the Passed Checks table and attribution footer. Output the Summary, Findings, and Prioritized Fix Sequence sections only. Use when a quick scan of what fired is all that's needed.

**`--critical-only`** — Suppress Warning and Info findings. Show only Critical findings. The Passed Checks table is also omitted. Use when triaging an incident and only actionable blockers matter.

Both flags can be combined: `--brief --critical-only` produces the Summary section plus Critical findings only.

When neither flag is present, produce the full report as documented above.

---

### Section: Verbose Output (--verbose)

When the user's request includes `--verbose`, `--trace`, or the word `verbose`:

**1. Append a `## Check Evaluation Log` section** after the Passed Checks table.

Include one row for every check in this skill's ruleset, in check-ID order:

| Check | Evidence | Threshold | Result |
|-------|----------|-----------|--------|
| [ID — Name] | [key attribute(s) and value found, or "absent"] | [threshold or condition] | PASS / **FIRE → [severity]** / NOT ASSESSED |

Result conventions:
- `PASS` — attribute present, threshold not met
- `**FIRE → Critical/Warning/Info**` — threshold met; bold to distinguish from passes
- `NOT ASSESSED` — required attribute absent from input

**2. Save both files** to the current working directory using the Write tool:

  output/<skill-name>/<YYYY-MM-DD-HHmmss>-<input-prefix>/analysis.md  ← full report
  output/<skill-name>/<YYYY-MM-DD-HHmmss>-<input-prefix>/trace.md     ← Check Evaluation Log

Derive `<input-prefix>`:
1. Filename stem if a file path was provided (e.g. `horrible.sqlplan` → `horrible`)
2. First meaningful identifier from the artifact (top wait type, first table name, procedure name, etc.)
3. Fallback: `run`
Sanitize: alphanumeric + hyphens/underscores only, max 32 chars.

File headers:
  analysis.md → `# Analysis — <skill-name> / # Input: <first 80 chars> / # Generated: <UTC timestamp>`
  trace.md    → `# Check Evaluation Log — <skill-name> / # Input: <first 80 chars> / # Generated: <UTC timestamp>`

Create directories as needed. When `--verbose` is not present, write nothing to disk.

---

## Companion Skills

- **/errorlog-review** — Login failure bursts (E22) and Kerberos-specific error messages
  (17806, 17807, 0x8009030c) in ERRORLOG are the first signal that authentication is broken;
  spn-review finds the SPN or delegation root cause
- **/clusterlog-review** — FCI VNN and AG listener connectivity issues in CLUSTER.LOG
  (L10, L17) may have missing VNN or listener SPNs as root cause
- **/hadr-health-review** — AG listener replica disconnection (H1, H5) may be SPN-driven
  when the listener name has no registered SPN and clients fall back to NTLM or fail entirely

- **mssql-performance-review** — Orchestrator that routes mixed artifacts to multiple specialised skills (this one included), runs an adversarial root-cause check, and produces a single consolidated report with evidence chain, risk-rated fixes, and rollback. Use when you have several artifact types together or describe a symptom without knowing which skill to run.
