# sqlspn-review Scripts

Helper scripts that collect the artifacts the `/sqlspn-review` checks need. All
are read-only: they query state and never register, modify, or delete an SPN or
an Active Directory attribute.

| Script | Purpose |
|--------|---------|
| `capture-spn-config.ps1` | Captures SPN registration, service and computer account delegation attributes, delegation target resolution, Kerberos environment state, and instance authentication scheme into one timestamped file |

## capture-spn-config.ps1

### What it collects

| Section | Contents | Checks served |
|---------|----------|---------------|
| 1 — SPN registration | `setspn -Q MSSQLSvc/*`, `setspn -X`, `setspn -L` for both the service account and the computer account, `setspn -Q HTTP/*` | K1–K16, K17, K28, K35, K36, K40 |
| 2 — Service account | `TrustedForDelegation`, `TrustedToAuthForDelegation`, `msDS-AllowedToDelegateTo`, `msDS-SupportedEncryptionTypes`, `MemberOf`, `PasswordLastSet`, `adminCount`, `LockedOut`; `Test-ADServiceAccount` for a gMSA | K11, K19, K21–K25, K30, K34, K37, K38, K47, K53 |
| 3 — Computer account | Delegation attributes, SPNs, `PrincipalsAllowedToDelegateToAccount`, `operatingSystemVersion` | K9, K28, K29, K50 |
| 4 — Delegation targets | Resolves every `msDS-AllowedToDelegateTo` entry through `setspn -Q` and marks each EXISTS or MISSING | K22 |
| 5 — Kerberos environment | `klist`, clock offset via `w32tm /stripchart`, time source, a direct `klist get` ticket request, encryption bitmask decode, KDC `DefaultDomainSupportedEncTypes` | K38, K45, K47 |
| 6 — Instance state | `net_transport` / `auth_scheme` / `local_tcp_port` from `sys.dm_exec_connections`, plus dynamic-port guidance | K5, K13, K20, K44, K52 |

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- The **ActiveDirectory** module (RSAT). Without it, sections 2–4 are skipped with a warning
- `setspn.exe`, `klist.exe` and `w32tm.exe` — all built into Windows
- A domain-joined host, run as a domain user with read access to Active Directory
- Optional: the **SqlServer** module for section 6. Without it the script prints the query to run manually
- No elevation required — every operation is a read

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-ServiceAccount` | discovered from the local SQL Server service | `DOMAIN\samAccountName`; include the trailing `$` for a gMSA or MSA |
| `-ComputerName` | local machine | The SQL Server host |
| `-ServerInstance` | none | Enables section 6 when supplied |
| `-DomainController` | `$env:LOGONSERVER` | Target for the clock offset measurement |
| `-OutputPath` | current directory | Where the timestamped file is written |

### Examples

```powershell
# Local instance, service account discovered automatically
.\capture-spn-config.ps1

# Explicit domain service account
.\capture-spn-config.ps1 -ServiceAccount CONTOSO\sqlsvc

# gMSA, with live instance state
.\capture-spn-config.ps1 -ServiceAccount CONTOSO\sqlgmsa$ -ServerInstance SQLNODE1

# Remote host, specific DC for the clock check
.\capture-spn-config.ps1 -ComputerName SQLNODE2 -ServiceAccount CONTOSO\sqlsvc -DomainController DC01
```

Then hand the output to the skill:

```
/sqlspn-review spn-capture-SQLNODE1-20260730-141522.txt
```

### Microsoft's own tools

Two first-party tools overlap this script and are worth running alongside it —
Microsoft's "Cannot generate SSPI context" guidance reaches for them first:

- **[Kerberos Configuration Manager for SQL Server](https://www.microsoft.com/download/details.aspx?id=39046)** —
  reports per-SPN status (Good / Missing / Duplicate / Misplaced / Dynamic Port)
  and generates a fix script when the running account lacks AD write rights.
- **[SQLCHECK](https://github.com/microsoft/CSS_SQL_Networking_Tools/wiki/SQLCHECK)** —
  emits a `Suggested SPN / Exists / Status` table covering all four expected name
  forms, mapping directly onto K1, K3 and K4.

### SQL Server on Linux

This script does not apply to SQL Server on Linux, which authenticates from a
keytab rather than through automatic SPN registration. Capture this instead and
paste it into the skill for K49–K51:

```bash
/opt/mssql/bin/mssql-conf validate-ad-config /var/opt/mssql/secrets/mssql.keytab
klist -kte /var/opt/mssql/secrets/mssql.keytab
ls -l /var/opt/mssql/secrets/mssql.keytab
grep -E 'kerberoskeytabfile|privilegedadaccount' /var/opt/mssql/mssql.conf
```
