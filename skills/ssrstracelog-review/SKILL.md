---
name: ssrstracelog-review
description: Analyze SQL Server Reporting Services (SSRS) report server trace logs, RSReportServer.config / ReportingServicesService.exe.config excerpts, ExecutionLog3 query output, and related Windows Event Log entries to diagnose failed report server startups, database connectivity errors, memory pressure and AppDomain recycling, slow or aborted report processing, subscription delivery failures, and scale-out/encryption-key problems. Applies 24 checks (G1–G24) covering trace configuration health, startup and report-server-database connectivity, memory management and recycling, report execution performance from ExecutionLog3, subscription and delivery extensions, and scale-out deployment key management. Use this skill whenever a user pastes ReportServerService_<timestamp>.log content, RSReportServer.config/ReportingServicesService.exe.config XML, ExecutionLog3 output, or describes SSRS symptoms such as "report server unavailable", slow reports, failed subscriptions, or scale-out join errors.
triggers:
  - /ssrstracelog-review
  - /ssrs-trace-review
  - /rs-trace-review
---

# SSRS Trace Log Review Skill

## Purpose

Analyze SQL Server Reporting Services (SSRS) diagnostic artifacts to find why a report
server fails to start, can't reach its report server database, runs reports slowly or
aborts them, drops subscription deliveries, or fails to join a scale-out deployment.
Applies 24 checks (G1–G24) across six categories:

- **G1–G4** — Trace configuration and log health: `DefaultTraceSwitch` level, file size
  and retention settings, restart/recycle frequency visible in trace file rollover, and
  stale component-level trace overrides
- **G5–G9** — Startup and report server database connectivity:
  `rsReportServerDatabaseUnavailable`, `rsReportServerDatabaseLogonFailed`,
  `rsErrorOpeningConnection` sub-causes, orphaned database pointers, and
  `rsServerConfigurationError`
- **G10–G13** — Memory pressure and AppDomain recycling: `MemorySafetyMargin` /
  `MemoryThreshold` / `WorkingSetMaximum` configuration, hard recycles from memory
  allocation failures, and `RecycleTime` / `MaxAppDomainUnloadTime` tuning
- **G14–G18** — Report processing and rendering: `ExecutionLog3` time-phase breakdown,
  legacy processing engine usage, `rsProcessingAborted` and error statuses, and external
  image fetch latency
- **G19–G21** — Subscriptions and delivery: file share and email delivery extension
  failures, and subscription scheduling clustering
- **G22–G24** — Scale-out and encryption keys: `rsInvalidReportServerDatabase` after
  upgrade, `rskeymgmt -j` join failures, and missing symmetric key backups

This skill is the SSRS counterpart to `sqlerrorlog-review` (Database Engine ERRORLOG) —
use both together when SSRS symptoms trace back to the report server database engine.

## Input

Accept any of:

- **Trace log excerpts** — `ReportServerService_<timestamp>.log` or (SSRS 2017+)
  `Microsoft.ReportingServices.Portal.WebHost_<timestamp>.log` content, pasted as text.
  Lines follow the format
  `<component>!<thread>!<pid>!<MM/DD/YYYY-HH:MM:SS> <severity> <LEVEL>: <message>`
  (e.g. `library!WindowsService_10!4c7c!05/24/2016-01:05:06 e ERROR: ...`)
- **`ReportingServicesService.exe.config`** excerpts — the `DefaultTraceSwitch` value
  (in the `<system.diagnostics><switches>` block) plus the `<RStrace>` section
  (`FileName`, `FileSizeLimitMb`, `KeepFilesForDays`, `TraceListeners`, `TraceFileMode`,
  and the `Components` setting that carries per-component trace overrides)
- **`RSReportServer.config`** excerpts — the `<Service>` section (`MemorySafetyMargin`,
  `MemoryThreshold`, `WorkingSetMaximum`, `WorkingSetMinimum`, `RecycleTime`,
  `MaxAppDomainUnloadTime`, `PollingInterval`, `MaxQueueThreads`, `UrlRoot`)
- **`ExecutionLog3` query output** — results of
  `SELECT * FROM ExecutionLog3 ORDER BY TimeStart DESC` against the report server database
- **Windows Application Event Log entries** for source "Report Server Windows Service" or
  "ReportServer" (commonly Event ID 107 and related startup/connectivity events)
- A natural-language description ("SSRS shows 'report server can't open a connection to
  the report server database' after a restart")

### Where the files live

```
SQL Server 2016 (default instance MSSQLSERVER):
  Trace logs:   C:\Program Files\Microsoft SQL Server\MSRS13.MSSQLSERVER\Reporting Services\LogFiles\
  Trace config: C:\Program Files\Microsoft SQL Server\MSRS13.MSSQLSERVER\Reporting Services\ReportServer\bin\ReportingServicesService.exe.config
  Server config: C:\Program Files\Microsoft SQL Server\MSRS13.MSSQLSERVER\Reporting Services\ReportServer\RSReportServer.config

SQL Server Reporting Services 2017+ / Power BI Report Server (standalone installer):
  Trace logs:   C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\LogFiles\
  Trace config: C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\ReportServer\bin\ReportingServicesService.exe.config
  Server config: C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\ReportServer\RSReportServer.config
```

Trace logs are created daily starting at the first entry after local midnight (UTC
timestamp in the filename) and whenever the service restarts — a burst of new trace log
files on the same day is itself a signal (see G3). `ExecutionLog3` is a view in the report
server database (default name `ReportServer`).

## How to Run

1. **Identify the artifact type(s)** in the input: trace log lines, trace config XML,
   server config XML, `ExecutionLog3` rows, Event Log entries, or a mix.
2. **Run G1–G4** against `ReportingServicesService.exe.config` / trace log filenames and
   header lines when present.
3. **Run G5–G9** against trace log error lines and Event Log entries — search for
   `rsReportServerDatabaseUnavailable`, `rsReportServerDatabaseLogonFailed`,
   `rsErrorOpeningConnection`, `rsServerConfigurationError`, and Event ID 107 first; these
   are usually the root cause of "report server unavailable" symptoms.
4. **Run G10–G13** against `RSReportServer.config` `<Service>` settings and trace log
   lines mentioning AppDomain recycling or memory allocation failures.
5. **Run G14–G18** against `ExecutionLog3` rows — compute `TimeDataRetrieval +
   TimeProcessing + TimeRendering` per row and compare to the dominant phase; check
   `Status` and `AdditionalInfo`.
6. **Run G19–G21** against trace log lines from the `emailextension` or
   `FileShareDeliveryProvider` components, and `ExecutionLog3` rows where
   `RequestType = Subscription`.
7. **Run G22–G24** against trace log lines mentioning `rsInvalidReportServerDatabase`,
   `rskeymgmt`, or scale-out join attempts.
8. **Order findings by causality** — a connectivity failure (G5–G9) usually explains
   downstream processing/subscription failures (G14–G21); report it as the root cause and
   the rest as cascade.
9. If a check cannot be evaluated because its artifact is absent, report
   "Cannot evaluate — <artifact> not provided" rather than skipping silently.

---

## Thresholds Reference

| Setting / Metric | Default | Notes |
|-------------------|---------|-------|
| `DefaultTraceSwitch` | `3` (exceptions, restarts, warnings, status messages) | `4` = verbose, `0` = disabled; lives in `<system.diagnostics><switches>` |
| `Components` (in `<RStrace>`) | `all` | per-component overrides as `<component>:<level>`, e.g. `all:3,RunningJobs:4`; components with no level use `DefaultTraceSwitch` |
| `FileSizeLimitMb` | 32 | per trace log file (0 or negative is treated as 1) |
| `KeepFilesForDays` | 14 | trace log retention (0 or negative is treated as 1) |
| `TraceFileMode` | `Unique` | one trace log per component per day; do not modify |
| `MemorySafetyMargin` | 80 (% of `WorkingSetMaximum`) | low/medium pressure boundary |
| `MemoryThreshold` | 90 (% of `WorkingSetMaximum`) | medium/high pressure boundary; must be > `MemorySafetyMargin` |
| `WorkingSetMaximum` / `WorkingSetMinimum` | not set (detected at startup) / 60% of max | KB; absent unless added manually |
| `RecycleTime` | 720 (minutes = 12 hours) | scheduled AppDomain recycle interval |
| `MaxAppDomainUnloadTime` | 30 (minutes) | background AppDomain shutdown wait |
| Execution log retention | 60 days | rows older than this are purged nightly |
| Report processing phase share | — | one of `TimeDataRetrieval`/`TimeProcessing`/`TimeRendering` consistently > 70% of `TimeStart`–`TimeEnd` for the same report flags that phase |

---

## Trace Configuration and Log Health Checks (G1–G4)

### G1 — Verbose or Disabled Tracing in Production
- **Trigger:** `ReportingServicesService.exe.config` shows verbose tracing sustained
  across multiple trace log files with no active investigation — either
  `DefaultTraceSwitch` value `4` (in `<system.diagnostics><switches>`) **or** the
  `<RStrace>` `Components` setting raising `all` to level 4 (`all:4`) — **or** tracing
  disabled (`DefaultTraceSwitch` value `0`)
- **Severity:** Warning
- **Fix:** Reset `DefaultTraceSwitch` to the documented default `3` (exceptions, restarts,
  warnings, status messages) and `Components` to `all`. Verbose mode generates large trace
  files and should only be enabled temporarily while reproducing an issue, then reverted.
  Disabling tracing (`0`) removes the primary diagnostic source for the next incident —
  Microsoft explicitly recommends against it.

### G2 — Trace Log Retention Misconfigured
- **Trigger:** `FileSizeLimitMb` or `KeepFilesForDays` in `ReportingServicesService.exe.config`
  is changed from the documented defaults (32 MB / 14 days) in a way that risks either
  filling the log volume (very large `FileSizeLimitMb` combined with high
  `KeepFilesForDays`) or losing history needed to investigate intermittent issues
  (`KeepFilesForDays` reduced to 1–2)
- **Severity:** Warning
- **Fix:** Size retention to the investigation window required (a week of daily logs at
  32 MB each is a small footprint). If verbose tracing (G1) is enabled temporarily, also
  temporarily raise `FileSizeLimitMb` so a single noisy day doesn't roll multiple files
  and lose context — then revert both together.

### G3 — Frequent Trace Log File Rollover (Service Restarts)
- **Trigger:** Multiple `ReportServerService_<timestamp>.log` files with timestamps close
  together on the same day (trace logs roll on every service restart, in addition to the
  daily midnight UTC rollover and `FileSizeLimitMb` rollover)
- **Severity:** Warning (Critical if rollovers correlate with user-visible outages)
- **Fix:** Each unexpected new trace log file is a service restart or AppDomain hard
  recycle. Correlate timestamps with G5–G9 (connectivity failures that crash startup) and
  G12 (memory-pressure hard recycles) to find the trigger. A healthy server shows at most
  one rollover per day (midnight UTC) plus planned `RecycleTime` recycles (every 12 hours
  by default, which do **not** create a new trace log file — only process restarts do).

### G4 — Stale Component-Level Trace Override
- **Trigger:** the `<RStrace>` `Components` setting contains a component-specific trace
  level override (e.g. `all:3,RunningJobs:4` or `all,SemanticQueryEngine:4`) that raises a
  single component above `DefaultTraceSwitch`, with no corresponding open investigation
- **Severity:** Info
- **Fix:** Component overrides left from a past investigation silently keep one subsystem
  at verbose logging. Remove the override (reverting that component to
  `DefaultTraceSwitch`) once the original issue is resolved — re-add it deliberately the
  next time that component needs to be debugged.

---

## Startup and Report Server Database Connectivity Checks (G5–G9)

### G5 — rsReportServerDatabaseUnavailable
- **Trigger:** Trace log or Event Log contains: *"The report server can't open a
  connection to the report server database. A connection to the database is required for
  all requests and processing. (rsReportServerDatabaseUnavailable)"* — or Windows
  Application Event ID **107**, source "Report Server Windows Service": *"Report Server
  Windows Service (<instance>) can't connect to the report server database."*
- **Severity:** Critical
- **Fix:** This is the report server's generic "can't reach my database" error and blocks
  every request. Check, in order: (1) is the Database Engine instance hosting the report
  server database running — hand off to `/sqlerrorlog-review` if it crashed or is
  recovering; (2) are TCP/IP and Named Pipes enabled for remote connections on that
  instance (SSRS uses both); (3) does the connection string in Report Server Configuration
  Manager's "Database Setup" page still point at a valid server/instance/database name.
  Re-run the connection through Report Server Configuration Manager rather than editing
  `RSReportServer.config` directly — the tool updates dependent settings and restarts the
  service correctly.

### G6 — rsReportServerDatabaseLogonFailed
- **Trigger:** Trace log contains: *"The report server can't open a connection to the
  report server database. The logon failed (rsReportServerDatabaseLogonFailed). Logon
  failure: unknown user name or bad password."*
- **Severity:** Critical
- **Fix:** The domain account used for the report server database connection has an
  expired/changed password or has been locked out. Update the credential through Report
  Server Configuration Manager's "Database Setup" page (do not edit the connection string
  directly — passwords are encrypted with the report server's symmetric key, see G24).
  If the account is a gMSA, verify the report server host still has rights to retrieve the
  managed password.

### G7 — rsErrorOpeningConnection Sub-Causes
- **Trigger:** Trace log shows `rsErrorOpeningConnection` together with an inner
  `SqlException` / `SQL Server Network Interfaces` error, most commonly *"error: 26 -
  Error Locating Server/Instance Specified"*
- **Severity:** Critical
- **Fix:** Error 26 means the connection string's server\instance name can't be resolved —
  check the SQL Server Browser service is running (for named instances), the instance name
  in the connection string matches `@@SERVERNAME`, and firewall rules allow the SQL Server
  port (or UDP 1434 for the Browser service) from the report server host. Also confirm the
  Database Engine service account's password hasn't expired — an expired account password
  can surface here as a generic network/instance-location error rather than an auth error.
  Cross-check with `/sqlspn-review` if the report server and database engine are on
  different hosts and Kerberos is in use.

### G8 — Orphaned Report Server Database Pointer
- **Trigger:** Repeated SQL Server login failures (Error 18456) for the SSRS service
  account against a `ReportServer$<InstanceName>` (or similarly named) database that does
  not exist on the target instance, while the SSRS service itself reports starting
  successfully
- **Severity:** Warning
- **Fix:** The SSRS service is configured to use a report server database that was never
  created or has since been dropped/renamed, and polls it continuously (e.g. via
  `PollingInterval`), generating a steady stream of failed-login noise in the Database
  Engine's ERRORLOG and security logs (visible from `/sqlerrorlog-review` E-checks for
  login failure bursts). Either point the instance at a valid report server database via
  Report Server Configuration Manager, or — if this SSRS instance is unused — disable or
  uninstall the service to stop the noise.

### G9 — rsServerConfigurationError
- **Trigger:** Trace log or Windows application log contains *"The report server
  encountered a configuration error. (rsServerConfigurationError)"* — typically
  immediately following a manual edit of `RSReportServer.config` or `RSReportDesigner.config`
- **Severity:** Critical
- **Fix:** A configuration file is missing, unreadable, or contains an invalid/missing
  XML element value that is critical to server operation (malformed XML stops startup
  entirely; an invalid non-critical value falls back to an internal default and is logged
  to the trace log instead). The accompanying second message states the actual
  cause — read the lines immediately following the `rsServerConfigurationError` entry. If this
  began after a manual edit, revert the change (restore from backup if available) per
  Microsoft's guidance for `RSReportServer.config`. Validate any setting changes against
  the [RsReportServer.config configuration file reference](https://learn.microsoft.com/sql/reporting-services/report-server/rsreportserver-config-configuration-file)
  before re-applying.

---

## Memory Pressure and AppDomain Recycling Checks (G10–G13)

### G10 — MemorySafetyMargin / MemoryThreshold Misconfigured
- **Trigger:** `RSReportServer.config` `<Service>` section sets `MemoryThreshold` ≤
  `MemorySafetyMargin`, or either value is set outside a sane 0–100 percent range
- **Severity:** Critical
- **Fix:** `MemoryThreshold` (default 90) must be greater than `MemorySafetyMargin`
  (default 80) — both are percentages of `WorkingSetMaximum` that define the
  low/medium/high memory-pressure boundaries. If the values are inverted or equal, the
  report server's pressure-response logic is undefined. Restore the documented defaults
  unless there is a specific, documented reason (e.g. lowering `MemorySafetyMargin` to
  react earlier to sudden processing-load spikes) — and if customized, ensure
  `MemoryThreshold > MemorySafetyMargin` is preserved.

### G11 — WorkingSetMaximum Constrains a Dedicated Report Server
- **Trigger:** `WorkingSetMaximum` is present in `RSReportServer.config` and set
  significantly below the host's physical memory on a server dedicated to SSRS (no other
  major workloads)
- **Severity:** Warning
- **Fix:** `WorkingSetMaximum` is normally absent (the report server detects available
  memory at startup and uses all of it). An explicit low value is only appropriate when
  SSRS shares the host with other applications and must be capped to avoid starving them.
  On a dedicated SSRS server, remove the override so the report server can use available
  memory — premature `MemoryThreshold`/`MemorySafetyMargin` pressure responses (slowed
  processing, AppDomain recycles) otherwise occur well below actual physical memory limits.

### G12 — Hard AppDomain Recycle from Memory Allocation Failure
- **Trigger:** Trace log shows an AppDomain recycle entry that is **not** at the scheduled
  `RecycleTime` interval and correlates with memory-pressure messages (high `WorkingSetMaximum`
  utilization, `ScalabilityTime`/`EstimatedMemoryUsageKB` spikes in nearby `ExecutionLog3`
  `AdditionalInfo`)
- **Severity:** Critical
- **Fix:** A memory allocation failure triggers a hard recycle of **all** application
  domains: in-progress requests are cancelled (not restarted), users must refresh, and
  scheduled jobs wait for their next run. This is the report server's last-resort response
  to genuine memory exhaustion — identify the request(s) with the largest
  `EstimatedMemoryUsageKB` around the recycle time (large exports, many concurrent
  instances of a memory-intensive report) and either redesign those reports, stagger
  their schedules, or move SSRS to a host with more memory / dedicated hardware (per
  Microsoft's guidance that tuning `MemorySafetyMargin`/`MemoryThreshold` doesn't improve
  throughput once requests are actually being dropped).

### G13 — RecycleTime / MaxAppDomainUnloadTime Tuned Away from Defaults
- **Trigger:** `RecycleTime` is set far below the 720-minute default (causing frequent
  planned recycles), or `MaxAppDomainUnloadTime` is set below the duration of the longest
  running subscription/snapshot job (causing in-progress jobs to be forcibly terminated
  during a recycle)
- **Severity:** Warning
- **Fix:** A low `RecycleTime` increases recycle frequency without improving stability —
  restore toward the 720-minute default unless a specific memory-leak workaround is
  documented (and prefer fixing the leak). `MaxAppDomainUnloadTime` (default 30 minutes)
  must exceed the longest background job's typical duration, or that job's AppDomain is
  restarted mid-run and the job is terminated incomplete — check `ExecutionLog3` for the
  longest `RequestType = Subscription` durations before lowering this value.

---

## Report Processing and Rendering Checks (G14–G18)

### G14 — Data Retrieval Dominates Execution Time
- **Trigger:** `ExecutionLog3` rows for a report repeatedly show `TimeDataRetrieval`
  accounting for the majority of `TimeDataRetrieval + TimeProcessing + TimeRendering`
- **Severity:** Warning
- **Fix:** The bottleneck is the underlying data source query, not SSRS. Capture the
  dataset query and hand off to `/sqlplan-review` (single execution) or
  `/sqlquerystore-review` (recurring/regressed) for the Database Engine side. SSRS-side
  mitigations are limited to caching (G18) or report snapshots if the data doesn't need to
  be live.

### G15 — Report Processing Dominates Execution Time (Legacy Engine)
- **Trigger:** `ExecutionLog3` rows show `TimeProcessing` dominant **and**
  `AdditionalInfo` contains `<ProcessingEngine>1</ProcessingEngine>` (the legacy SQL Server
  2005 processing engine rather than the on-demand engine)
- **Severity:** Warning
- **Fix:** Reports still using `ProcessingEngine=1` don't benefit from the on-demand
  processing engine's incremental rendering and lower memory footprint. Re-author or
  upgrade the report (republishing from a current version of Report Builder/SSDT
  typically migrates it to the on-demand engine). If processing time is high under the
  on-demand engine (`ProcessingEngine=2`) instead, investigate report complexity —
  nested data regions, excessive grouping/sorting, or expression-heavy designs.

### G16 — Aborted or Failed Report Execution
- **Trigger:** `ExecutionLog3` `Status` is `rsProcessingAborted` or any value other than
  `rsSuccess`
- **Severity:** Critical if recurring for the same report/parameters; Warning if isolated
- **Fix:** `rsProcessingAborted` indicates the request was cancelled — commonly a client
  timeout (browser/HTTP timeout shorter than report processing time) or an administrative
  cancellation via "Manage Jobs". Non-`rsSuccess` error codes point at a specific failure
  (data source, expression, rendering extension) — look up the code in the
  [Cause and resolution of Reporting Services errors](https://learn.microsoft.com/sql/reporting-services/troubleshooting/cause-and-resolution-of-reporting-services-errors)
  reference. Recurring aborts for the same report under load are often resolved by raising
  the relevant timeout (report-level `Timeout` property, or the web server's request
  timeout) once the underlying query performance (G14) is acceptable.

### G17 — External Image Fetch Latency
- **Trigger:** `ExecutionLog3` `AdditionalInfo` contains an `<ExternalImages>` block with
  `ResourceFetchTime` contributing materially to `TimeRendering` for a report that embeds
  external (URL-referenced) images
- **Severity:** Info
- **Fix:** Each external image adds a synchronous fetch during rendering. For reports run
  frequently or by many concurrent users, host images locally (embedded image or same-
  network resource) or accept the added latency as a known cost of remote images. This is
  rarely the primary bottleneck but explains otherwise-unaccounted rendering time.

### G18 — Live Execution Source for Cacheable Reports
- **Trigger:** `ExecutionLog3` `Source = Live` for the same report+parameter combination
  executed repeatedly within a short window, where caching or a snapshot schedule is not
  configured
- **Severity:** Info
- **Fix:** Every `Source = Live` execution re-runs the full data retrieval/processing/
  rendering cycle. If the underlying data doesn't need to be real-time, enable a cache
  refresh plan or a report snapshot schedule — subsequent executions show
  `Source = Cache` or `Source = Snapshot` and skip data retrieval entirely, directly
  reducing load identified by G14.

---

## Subscriptions and Delivery Checks (G19–G21)

### G19 — File Share Delivery Failure
- **Trigger:** Trace log line from the `FileShareDeliveryProvider` (or `filesys`)
  component contains *"Failure writing file"* with a
  `Microsoft.ReportingServices.FileShareDeliveryProvider.FileShareProvider+NetworkErrorException"`
  and an inner *"An impersonation error occurred using the security context of the current
  user"*
- **Severity:** Critical
- **Fix:** The account configured for the file share subscription (or the report server's
  service account, if "Use the credentials supplied by the user...") can't write to the
  target UNC path. Verify the credentials saved on the subscription are current, the
  account has write permission on the share, and — if the share is on a different server
  than the report server — that Kerberos delegation (constrained delegation for the
  report server service account to the file server's CIFS service) is configured; this is
  the classic SSRS double-hop. Cross-check with `/sqlspn-review` for delegation
  configuration.

### G20 — Email Delivery Failure
- **Trigger:** Trace log line from the `emailextension` component contains *"Error sending
  email"* with a `System.Net.Mail.SmtpException` (e.g. *"The SMTP server requires a secure
  connection or the client wasn't authenticated"*)
- **Severity:** Critical
- **Fix:** The SMTP relay configured in `RSReportServer.config` (`<SMTPServer>`,
  `<SMTPServerPin>`, `<SendUsingAccount>`, `<SMTPAuthenticate>`) doesn't match what the mail
  server requires — commonly the server now requires authentication or TLS and SSRS is
  configured for anonymous relay. Update the SMTP settings via Report Server Configuration
  Manager (or the config file per Microsoft's documented procedure) to match the mail
  server's current requirements, and confirm the report server host is permitted to relay
  through that server (IP allow-list).

### G21 — Subscription Scheduling Clustered at Peak Times
- **Trigger:** `ExecutionLog3` rows with `RequestType = Subscription` cluster heavily at
  round-hour boundaries (e.g. many subscriptions all scheduled for 8:00 AM / 9:00 AM),
  producing a visible spike in concurrent executions
- **Severity:** Warning
- **Fix:** A burst of simultaneous scheduled subscriptions competes for the same
  `MaxQueueThreads` and memory budget, increasing the odds of G12 (hard recycle) and G16
  (aborted executions). Stagger subscription schedules across a wider window (minute-level
  offsets rather than all on the hour). If subscriptions consistently run slow as a group,
  cross-check `/sqlwait-review` and `/sqlmemory-review` on the report server database for
  contention during that window.

---

## Scale-Out and Encryption Key Checks (G22–G24)

### G22 — rsInvalidReportServerDatabase After Upgrade
- **Trigger:** Trace log contains an `rsInvalidReportServerDatabase` exception on a report
  server that is part of a scale-out deployment, occurring after another node in the
  deployment was migrated/upgraded to a newer SQL Server version
- **Severity:** Critical
- **Fix:** The report server database schema was upgraded by the first migrated node, but
  this node is still running the old binaries/schema expectations. Either upgrade this
  node promptly, or — if this node is being decommissioned — remove it from the
  deployment. Per Microsoft's migration guidance, after migrating the first node of a
  scale-out deployment, the old encryption keys for not-yet-migrated nodes must be removed
  from the **Keys** table in the report server database (via SSMS — the Reporting Services
  Configuration tool can't do this), or those nodes will keep trying to initialize in
  scale-out mode against a schema they don't recognize.

### G23 — rskeymgmt Scale-Out Join Failure
- **Trigger:** Trace log or command output shows `rskeymgmt -j` failing with an access-
  denied error while joining a remote report server instance to a scale-out deployment
- **Severity:** Warning
- **Fix:** `rskeymgmt -j -m <remotecomputer> -n <instance> -u <account> -v <password>`
  must be run **on a computer already in the deployment**, and the `-u`/`-v` account must
  have local administrator rights on the **remote** computer being joined (the utility
  connects to the local Report Server Windows service via RPC and cannot manage a remote
  instance's keys directly). Confirm the account is a local admin on the target node, that
  the Report Server Windows service is running on both nodes, and that Windows Firewall
  permits the RPC endpoint between them.

### G24 — Symmetric Key Not Backed Up Before Migration/Scale-Out
- **Trigger:** A migration, scale-out join, or encryption-key-recreation (`rskeymgmt -s`)
  is being planned or has occurred, and no symmetric key backup (`rskeymgmt -e` output or
  Reporting Services Configuration tool "Backup" on the Encryption Keys tab) is on record
- **Severity:** Warning
- **Fix:** The symmetric key protects all stored credentials and connection strings in the
  report server database (including the report server database connection itself —
  relevant to G6). Without a current backup, a lost/corrupted key forces `rskeymgmt -d`
  (delete all encryption keys **and** all encrypted content — every stored credential and
  connection string must be re-entered). Back up the symmetric key (`rskeymgmt -e -f
  <path> -p <password>`, or the Configuration tool's Backup button) before any migration,
  scale-out change, or key recreation, and store the backup file and password separately
  per `/sqlencryption-review` key-lifecycle guidance.

---

## Version-Aware Check Suppression

If the SSRS version is stated by the user or can be inferred from the file paths
(`MSRS13.<instance>` = SQL 2016; standalone `SSRS\` path = 2017+/Power BI Report Server),
read `VERSION_COMPATIBILITY.md` (`~/.claude/skills/VERSION_COMPATIBILITY.md` if installed,
or `skills/VERSION_COMPATIBILITY.md` from the repo). If unavailable, skip silently. For
checks whose minimum version exceeds the instance version: verbose mode → log as
`SKIP (version: requires SSRS 20XX+, instance is SSRS 20YY)`; standard report → omit
entirely. This skill applies to SSRS Native mode and Power BI Report Server. SharePoint-
integrated mode uses different log locations (SharePoint ULS) — checks referencing
`ReportServerService_<timestamp>.log` file paths do not apply there, but `ExecutionLog3`
checks (G14–G18) still apply.

---

## Output Format

Present findings in this order:

1. **SSRS Health Summary** — one sentence: symptom, affected component (startup /
   processing / subscriptions / scale-out), root cause.
2. **Run facts table** — SSRS version/edition, deployment mode (standalone/scale-out),
   instance name, log file timestamp range.
3. **Findings table** — one row per triggered check:

| Check | Severity | Artifact | Finding | Fix |
|-------|----------|----------|---------|-----|
| G5 | Critical | Trace log | rsReportServerDatabaseUnavailable after restart | Verify Database Engine is up and remote connections enabled |

4. **Root cause** — single root cause with evidence lines quoted from the trace
   log/config/`ExecutionLog3`.
5. **Recovery sequence** — ordered, concrete steps with companion skill references.
6. **Configuration advisories** — G1–G4, G10–G13 findings, separated from the incident
   analysis.

> Analyzed by: `ssrstracelog-review` (G1–G24)

---

## Companion Skills

- `/sqlerrorlog-review` — when G5/G7/G8 point at the Database Engine instance hosting the
  report server database, the engine's ERRORLOG explains *why* it's unreachable
  (crash, recovery, startup failure)
- `/sqlmemory-review` — when G12 fires, check the report server database's host for
  matching OS-level memory pressure if SSRS and the Database Engine share hardware
- `/sqldbconfig-review` — confirms the report server database (`ReportServer`,
  `ReportServerTempDB`) is configured per Microsoft's recommendations (recovery model,
  compatibility level)
- `/sqlspn-review` — G7, G9, and G19 (double-hop) connectivity failures are often Kerberos
  delegation issues between the report server, the database engine, and file/SMTP servers
- `/sqlplan-review` and `/sqlquerystore-review` — G14 hands off the underlying dataset
  query for plan-level analysis
- `/sqlencryption-review` — G24 symmetric key lifecycle follows the same backup/rotation
  discipline as other SQL Server encryption keys

---

## VERSION_COMPATIBILITY

See [skills/VERSION_COMPATIBILITY.md](../VERSION_COMPATIBILITY.md) for the full compatibility matrix.

| Check | SSRS 2014/2016 | SSRS 2017 | SSRS 2019 | SSRS 2022 | Power BI Report Server |
|-------|----------------|-----------|-----------|-----------|------------------------|
| G1–G4 (trace config) | ✓ | ✓ | ✓ | ✓ | ✓ |
| G5–G9 (DB connectivity) | ✓ | ✓ | ✓ | ✓ | ✓ |
| G10–G13 (memory/recycle) | ✓ | ✓ | ✓ | ✓ | ✓ |
| G14 ProcessingEngine note | ✓ | ✓ | ✓ | ✓ | ✓ |
| G15 legacy engine (ProcessingEngine=1) | ✓ | — | — | — | — |
| G16–G18 (ExecutionLog3) | ✓ | ✓ | ✓ | ✓ | ✓ |
| G19–G21 (subscriptions) | ✓ | ✓ | ✓ | ✓ | ✓ |
| G22–G24 (scale-out/keys) | ✓ | ✓ | ✓ | ✓ | ✓ |

`ExecutionLog3` requires SQL Server 2008 R2 Reporting Services or later; earlier versions
exposing only `ExecutionLog`/`ExecutionLog2` lack `Source` values 5–7 (AdHoc/Session/RDCE)
and the `AdditionalInfo` diagnostics used by G15/G17.
