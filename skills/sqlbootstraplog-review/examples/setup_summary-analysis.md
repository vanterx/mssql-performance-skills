# Setup Bootstrap Log Analysis — PRDSQL07 (example output)

### Setup Outcome Summary
The SQL Server 2022 Standard install on PRDSQL07 **failed**: the Database Engine
installed its binaries but did not start during configuration (0x851A001A), taking
Replication down as a dependency; Analysis Services and Reporting Services passed,
leaving a partial install.

### Run Facts

| Property | Value |
|----------|-------|
| Product / edition | SQL Server 2022 (RTM) Standard |
| Requested action | Install |
| Final result | Failed |
| Exit code (decimal) | -2061893606 (0x851A001A) |
| Run window | 2026-06-10 21:42:08 → 21:49:55 |
| Log folder | `...\160\Setup Bootstrap\Log\20260610_214208\` |

### Findings

| Check | Severity | Artifact | Finding | Fix |
|-------|----------|----------|---------|-----|
| U1 | Critical | Summary.txt | Final result Failed; SQLEngine + Replication failed | Resolve root cause, uninstall failed features, rerun |
| U2 | Critical | Summary.txt | 0x851A001A — "Wait on the Database Engine recovery handle failed" | Engine didn't start during configuration — read the new instance ERRORLOG (`MSSQL16.MSSQLSERVER\MSSQL\LOG\ERRORLOG`), hand off to /sqlerrorlog-review |
| U4 | Critical | Summary.txt | Partial install: AS and RS Passed, engine Failed | Fix engine first; AS/RS are installed and serviceable |
| U17 | Info | Summary.txt | Replication failure is cascade ("dependency of the feature") | One root cause: Database Engine start |
| U19 | Warning | User Input Settings | `SQLSVCACCOUNT: NT AUTHORITY\SYSTEM` | Use the default virtual account `NT Service\MSSQLSERVER` or a gMSA — LocalSystem widens blast radius and is a plausible contributor to the start failure (directory ACLs) |
| U20 | Warning | User Input Settings | `SQLSVCINSTANTFILEINIT: false` | Grant "Perform volume maintenance tasks" to the engine account; verify via sys.dm_server_services (B22) |
| U21 | Warning | User Input Settings | TempDB: 1 file × 8 MB on a 16-core server | Set SQLTEMPDBFILECOUNT=8, equal pre-sized files, dedicated SQLTEMPDBDIR |
| U22 | Warning | User Input Settings | `SECURITYMODE: SQL` and `NPENABLED: 1` | Confirm mixed auth is a documented requirement (then disable/rename sa); disable named pipes unless a legacy client needs it |
| U23 | Info | User Input Settings | FEATURES include AS + RS on an engine box | Remove unused services or document their purpose; they compete for memory outside max server memory |
| U24 | Warning | User Input Settings | All data/log/TempDB/backup dirs default to the system drive | Repoint SQLUSERDBDIR / SQLUSERDBLOGDIR / SQLTEMPDBDIR / SQLBACKUPDIR to dedicated volumes before reinstalling |
| U3 | Info | Rules section | `IsFirewallEnabled` warning only | Open port 1433 (or instance port) for remote access |

### Root Cause
**[U2] Database Engine failed to start during setup configuration (0x851A001A).**
The setup log cannot say why the engine did not start — that evidence is in the new
instance's ERRORLOG. Given `SQLSVCACCOUNT: NT AUTHORITY\SYSTEM` with all data
directories defaulted to the system drive, service-account/ACL and directory issues are
the first hypotheses to test in the ERRORLOG.

### Recovery Sequence

| Step | Action | Resolves |
|------|--------|----------|
| 1 | Read `MSSQL16.MSSQLSERVER\MSSQL\LOG\ERRORLOG` → run /sqlerrorlog-review on it | U2 root cause |
| 2 | Correct the INI: virtual account or gMSA (U19), `SQLSVCINSTANTFILEINIT="True"` (U20), TempDB count/size/dir (U21), directory parameters off `C:\` (U24), drop AS/RS or justify (U23), revisit `SECURITYMODE`/`NPENABLED` (U22) | U19–U24 |
| 3 | Uninstall the failed Database Engine feature per the Summary's Next Step | U1/U4 |
| 4 | Run `scripts/check-pending-reboot.ps1` (must exit 0), then rerun setup with the corrected INI | U7 pre-flight |
| 5 | Post-install: /sqldbconfig-review (B22/B23 confirm IFI + TempDB) and /sqldiskio-review (Z6–Z10 placement) | validation |

> Analyzed by: `sqlbootstraplog-review` (U1–U24)
