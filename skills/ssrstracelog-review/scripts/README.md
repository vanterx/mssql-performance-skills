# ssrstracelog-review — Scripts

Reference script for users. Run it on the SSRS report server host (not inside this
skill) and paste the output into a chat for analysis.

## collect-ssrs-diagnostics.ps1

Collects the artifacts `ssrstracelog-review` needs in one pass: trace configuration,
server (memory/recycle) configuration, trace log rollover frequency, recent
ERROR/Exception lines from the latest trace log, and related Application Event Log
entries.

**Sections collected:**

| # | Section | Checks |
|---|---------|--------|
| 1 | `ReportingServicesService.exe.config` `<RStrace>` settings (`DefaultTraceSwitch`, `FileSizeLimitMb`, `KeepFilesForDays`, component overrides) | G1, G2, G4 |
| 2 | `RSReportServer.config` `<Service>` settings (`MemorySafetyMargin`, `MemoryThreshold`, `WorkingSetMaximum`, `WorkingSetMinimum`, `RecycleTime`, `MaxAppDomainUnloadTime`, `PollingInterval`, `MaxQueueThreads`, `UrlRoot`) | G10, G11, G13 |
| 3 | Count and timestamps of `ReportServerService_<timestamp>.log` files in the lookback window | G3 |
| 4 | `ERROR`/`Exception` lines from the most recent trace log | G5–G9, G19, G20 |
| 5 | Application Event Log entries from "Report Server Windows Service" | G5, G8 |

**Usage:**

```powershell
# Default instance (MSSQLSERVER), last 1 day
.\collect-ssrs-diagnostics.ps1

# Named instance, last 3 days, more error lines
.\collect-ssrs-diagnostics.ps1 -InstanceName MSSQLSERVER -Days 3 -MaxErrorLines 100
```

**Prerequisites:** Windows PowerShell 5.1+ or PowerShell 7+; read access to the
Reporting Services program files folder and the Application event log. Auto-detects SQL
Server 2016 (`MSRS13.<instance>` through `MSRS16.<instance>`) and SSRS 2017+ / Power BI
Report Server (standalone `SSRS` path) layouts — checked in that order, standalone path
first.

**ExecutionLog3 (G14–G18, G21):** not collected by this script — it requires a SQL query
against the report server database:

```sql
SELECT * FROM ExecutionLog3 ORDER BY TimeStart DESC;
```

Run this separately against the `ReportServer` (or named) database and paste the
relevant rows alongside this script's output.
