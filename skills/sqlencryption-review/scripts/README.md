# sqlencryption-review — Scripts

## Scripts

### `capture-all-encryption.ps1`

Connects to a SQL Server instance and captures encryption DMV data to timestamped output files.

| Parameter | Default | Description |
|---|---|---|
| `-ServerInstance` | `localhost` | SQL Server instance name |
| `-Database` | `master` | Initial database for the connection |
| `-OutputDir` | `.\encryption-audit` | Directory to write output files |
| `-IncludeSource` | (switch) | Also capture T-SQL module source metadata |

Output files written to `OutputDir`:

| File | Contents |
|---|---|
| `01-tde-status.txt` | TDE status across all databases |
| `02-always-encrypted-columns.txt` | Always Encrypted column inventory |
| `03-cek-version-history.txt` | CEK rotation history |
| `04-symmetric-asymmetric-keys.txt` | All user keys (symmetric + asymmetric) |
| `05-certificates.txt` | All certificates |
| `06-backup-encryption.txt` | Recent 30-day backup encryption |
| `07-connection-encryption.txt` | Connection encryption status |
| `08-dmk-status.txt` | DMK protection status per database |
| `09-ekm-providers.txt` | EKM providers |
| `10-sensitivity-classifications.txt` | Sensitivity classifications |
| `11-endpoints.txt` | Endpoints using certificate authentication |
| `12-module-source.txt` | T-SQL module source metadata (with `-IncludeSource`) |
| `_summary.txt` | Capture summary (what captured, when, errors) |

### `test-tls.ps1`

Verifies the TLS configuration of a SQL Server instance.

| Parameter | Default | Description |
|---|---|---|
| `-ComputerName` | `localhost` | SQL Server hostname or IP |
| `-Port` | `1433` | SQL Server TCP port |

Checks performed:
1. SChannel registry for TLS 1.0, 1.1, 1.2, 1.3 protocol server/client states
2. Custom cipher suite order and weak cipher detection
3. ForceEncryption status via `sys.dm_server_registry` (if SQL is accessible)
4. TCP connectivity test to the target port
5. Suggests `openssl s_client` and `nmap ssl-enum-ciphers` commands if those tools are on PATH

## Prerequisites

- **PowerShell 7+** (recommended; Windows PowerShell 5.1 also works)
- **SqlServer PowerShell module** (optional — provides `Invoke-SqlCmd`):
  ```powershell
  Install-Module -Name SqlServer -Scope CurrentUser -Force
  ```
  If SqlServer module is not installed, the scripts fall back to `System.Data.SqlClient` from the .NET Framework / .NET SDK.
- `capture-all-encryption.ps1` requires **VIEW SERVER STATE** and **VIEW ANY DEFINITION** permissions on the target SQL Server instance.
- `test-tls.ps1` requires local registry read access and optionally SQL connectivity for ForceEncryption check.

## Usage Examples

Capture encryption audit data from a production instance:

```powershell
.\capture-all-encryption.ps1 -ServerInstance prod-sql-01 -OutputDir C:\audit\prod-encryption
```

Capture with source metadata:

```powershell
.\capture-all-encryption.ps1 -ServerInstance localhost\sqlexpress -IncludeSource
```

Test TLS configuration:

```powershell
.\test-tls.ps1 -ComputerName prod-sql-01
```

Test a named instance on a non-standard port:

```powershell
.\test-tls.ps1 -ComputerName prod-sql-01 -Port 51433
```
