# ssrstracelog-review — Checks Explained (G1–G24)

## Contents
- [Trace Configuration and Log Health Checks (G1–G4)](#trace-configuration-and-log-health-checks-g1g4)
- [Startup and Report Server Database Connectivity Checks (G5–G9)](#startup-and-report-server-database-connectivity-checks-g5g9)
- [Memory Pressure and AppDomain Recycling Checks (G10–G13)](#memory-pressure-and-appdomain-recycling-checks-g10g13)
- [Report Processing and Rendering Checks (G14–G18)](#report-processing-and-rendering-checks-g14g18)
- [Subscriptions and Delivery Checks (G19–G21)](#subscriptions-and-delivery-checks-g19g21)
- [Scale-Out and Encryption Key Checks (G22–G24)](#scale-out-and-encryption-key-checks-g22g24)
- [Quick Reference](#quick-reference)

Configuration setting names, defaults, error message text, and log file locations come
from Microsoft's
[Report server service trace log](https://learn.microsoft.com/sql/reporting-services/report-server/report-server-service-trace-log),
[RsReportServer.config configuration file](https://learn.microsoft.com/sql/reporting-services/report-server/rsreportserver-config-configuration-file),
[Configure available memory for report server applications](https://learn.microsoft.com/sql/reporting-services/report-server/configure-available-memory-for-report-server-applications),
[Application domains for report server applications](https://learn.microsoft.com/sql/reporting-services/report-server/application-domains-for-report-server-applications),
[Use ExecutionLog and the ExecutionLog3 view](https://learn.microsoft.com/sql/reporting-services/report-server/report-server-executionlog-and-the-executionlog3-view),
[Troubleshoot server and database connection problems with Reporting Services](https://learn.microsoft.com/sql/reporting-services/troubleshooting/troubleshoot-server-and-database-connection-problems-with-reporting-services),
[Troubleshoot Reporting Services subscriptions and delivery](https://learn.microsoft.com/sql/reporting-services/troubleshooting/troubleshoot-reporting-services-subscriptions-and-delivery),
and the [rskeymgmt utility](https://learn.microsoft.com/sql/reporting-services/tools/rskeymgmt-utility-ssrs) reference.

---

## Trace Configuration and Log Health Checks (G1–G4)

### G1 — DefaultTraceSwitch Left at Verbose or Disabled in Production

**What it means:** `DefaultTraceSwitch` in `ReportingServicesService.exe.config`
controls how much detail the report server writes to its trace log. Level `3`
(exceptions, restarts, warnings, status messages) is the documented default and
is appropriate for normal operation. Level `4` (verbose) adds SOAP envelopes, HTTP
headers, and debug trace — useful while reproducing a specific issue but noisy and
disk-hungry long-term. Level `0` disables the trace log entirely. Verbose tracing can
also be turned on through the `<RStrace>` `Components` setting (raising `all` to `all:4`),
so check both places.

**How to spot it:**
```xml
<system.diagnostics>
  <switches>
    <add name="DefaultTraceSwitch" value="4" />
  </switches>
</system.diagnostics>
<RStrace>
  <add name="Components" value="all:4" />   <!-- or all components at verbose here -->
  ...
</RStrace>
```
combined with a series of large daily trace log files and no open investigation, or
`DefaultTraceSwitch value="0"` with no `ReportServerService_*.log` files being produced at all.

**Example:** A trace level of `4` was set six months ago to debug a one-time rendering
issue and never reverted — the report server now writes multi-hundred-MB trace logs
every day.

**Fix options (ranked):**
1. Set `DefaultTraceSwitch` back to `3` for normal operation.
2. If actively debugging, raise to `4` temporarily and pair with G2 (raise
   `FileSizeLimitMb`/`KeepFilesForDays` for the duration) — then revert both.
3. Never leave `DefaultTraceSwitch` at `0` — Microsoft explicitly recommends against
   disabling the trace log, since it's the primary source for diagnosing the *next*
   incident.

**Related checks:** G2 (retention), G4 (component overrides)

---

### G2 — Trace Log Retention Misconfigured

**What it means:** `FileSizeLimitMb` (default 32) and `KeepFilesForDays` (default 14)
in `ReportingServicesService.exe.config` bound how large each trace log file grows and
how long old files are kept before automatic deletion.

**How to spot it:**
```xml
<add name="FileSizeLimitMb" value="32" />
<add name="KeepFilesForDays" value="14" />
```
Values far outside these defaults — e.g. `KeepFilesForDays` set to `1` (losing
yesterday's context before an intermittent issue is even reported) or `FileSizeLimitMb`
raised to hundreds of MB with `KeepFilesForDays` left high (unbounded disk growth on the
log volume).

**Example:** `KeepFilesForDays` was reduced to `2` to save disk space, but the team's
incident review process runs weekly — by the time someone investigates a Monday report,
Friday's trace logs are gone.

**Fix options:**
1. Set retention to cover the realistic investigation window (a week of 32 MB daily
   files is under 250 MB).
2. If verbose tracing (G1) is enabled temporarily, raise `FileSizeLimitMb` together with
   it so a noisy day doesn't roll through multiple files and fragment the context — then
   revert both together.
3. Monitor the log volume's free space if either value is increased significantly.

**Related checks:** G1, G3

---

### G3 — Frequent Trace Log File Rollover (Service Restarts)

**What it means:** Trace logs roll over to a new `ReportServerService_<timestamp>.log`
file on three conditions: the daily UTC-midnight boundary, `FileSizeLimitMb` being
reached, and **every Report Server Windows service restart**. A scheduled `RecycleTime`
AppDomain recycle does *not* create a new trace log file — only a process restart does.

**How to spot it:** Several `ReportServerService_<timestamp>.log` files with close
timestamps on the same day, more than the daily/size-based rollovers would explain.

**Example:** Five trace log files appear between 09:00 and 09:45 on the same day — the
report server service is crashing and being restarted (by a watchdog or manually) roughly
every 10 minutes.

**Fix options:**
1. Open each new-file boundary and read the last lines of the *previous* file — that's
   where the crash/shutdown reason is recorded.
2. Correlate timestamps with G5–G9 (a startup connectivity failure that crash-loops the
   service) and G12 (memory-pressure hard recycles, which restart the process).
3. If a watchdog is auto-restarting the service, disable the auto-restart temporarily so
   the crash is captured in full rather than truncated by the restart.

**Related checks:** G5–G9, G12

---

### G4 — Stale Component-Level Trace Override

**What it means:** the `<RStrace>` `Components` setting supports per-component trace
levels using `<component>:<level>` syntax (the documented default is `all`, which means
every component uses `DefaultTraceSwitch`). A component pinned to a higher level keeps
that one subsystem verbose indefinitely. Valid component categories include `all`,
`RunningJobs`, `SemanticQueryEngine`, `SemanticModelGenerator`, and `http`.

**How to spot it:**
```xml
<add name="TraceFileMode" value="Unique"/>
<add name="Components" value="all:3,RunningJobs:4,SemanticQueryEngine:4" />
```
where `DefaultTraceSwitch` itself is `3` but specific components are pinned to `4` with
no documented reason.

**Example:** `SemanticModelGenerator:4` was added while investigating a Power BI Report
Server data model issue eight months ago and was never removed.

**Fix options:**
1. Remove component-specific overrides once the originating investigation is closed,
   returning that component to `DefaultTraceSwitch`.
2. Document any override that must remain (e.g. a recurring intermittent issue under
   active monitoring) with a removal date.
3. Re-add the override deliberately the next time that specific component needs deeper
   tracing.

**Related checks:** G1

---

## Startup and Report Server Database Connectivity Checks (G5–G9)

### G5 — rsReportServerDatabaseUnavailable

**What it means:** The report server requires a working connection to its report server
database (`ReportServer` by default) for every request. `rsReportServerDatabaseUnavailable`
is the generic "I can't reach my database at all" error, and Windows Application Event ID
**107** (source "Report Server Windows Service") reports the same condition at service
startup.

**How to spot it:**
```
The report server can't open a connection to the report server database. A connection
to the database is required for all requests and processing. (rsReportServerDatabaseUnavailable)
```
or, in the Windows Application log:
```
Event ID: 107
Source: Report Server Windows Service
Report Server Windows Service (MSSQLSERVER) can't connect to the report server database.
```

**Example:** After a Database Engine restart for patching, SSRS comes up first and logs
Event 107 repeatedly until the Database Engine finishes recovery.

**Fix options (ranked):**
1. Confirm the Database Engine instance hosting the report server database is running
   and has finished recovery — hand off to `/sqlerrorlog-review` if it's still
   recovering or crashed.
2. Confirm TCP/IP and Named Pipes are enabled for remote connections on that instance
   (SSRS uses both protocols) via SQL Server Configuration Manager.
3. Re-validate the connection through Report Server Configuration Manager's "Database
   Setup" page — it updates dependent settings and restarts the service correctly,
   unlike a direct config file edit.

**Related checks:** G6, G7, G8

---

### G6 — rsReportServerDatabaseLogonFailed

**What it means:** The report server reached the Database Engine instance but the
configured credential was rejected — `rsReportServerDatabaseLogonFailed` specifically
means the *logon* failed, not that the server is unreachable.

**How to spot it:**
```
The report server can't open a connection to the report server database. The logon
failed (rsReportServerDatabaseLogonFailed). Logon failure: unknown user name or bad password.
```

**Example:** A domain account used for the report server database connection had its
password rotated by a periodic AD policy; SSRS still has the old password cached and
every request now fails this logon.

**Fix options:**
1. Update the credential through Report Server Configuration Manager's "Database Setup"
   page — this re-encrypts the new password with the report server's symmetric key (see
   G24) and restarts the service.
2. For a gMSA, confirm the report server host still has rights to retrieve the managed
   password (`Test-ADServiceAccount`).
3. If the account was locked out (not just password-changed), unlock it in AD before
   retrying — repeated failed attempts from a stuck SSRS service can itself cause
   lockouts.

**Related checks:** G5, G24

---

### G7 — rsErrorOpeningConnection Sub-Causes

**What it means:** `rsErrorOpeningConnection` wraps an underlying `SqlException`. The
most common inner cause is **"error: 26 - Error Locating Server/Instance Specified"** —
the connection string's server\instance name couldn't be resolved on the network, which
is a name-resolution/Browser-service/firewall problem, not necessarily an authentication
problem (even though the surrounding text can mention remote connections).

**How to spot it:**
```
rsErrorOpeningConnection ...
An error occurred while establishing a connection to the server. When connecting to SQL
Server, this failure may be caused by the fact that under the default settings SQL Server
does not allow remote connections.
provider: SQL Server Network Interfaces, error: 26 - Error Locating Server/Instance Specified
```

**Example:** The report server database connection string specifies
`SQLPROD\REPORTING`, but the SQL Server Browser service on `SQLPROD` is stopped, so the
named-instance port can't be resolved.

**Fix options (ranked):**
1. Confirm SQL Server Browser is running on the target host (required for named
   instances) and that UDP 1434 is allowed through the firewall from the report server.
2. Confirm the instance name in the connection string matches `@@SERVERNAME` on the
   target, and that TCP/IP is enabled with the firewall allowing the instance's TCP port.
3. Rule out an expired Database Engine service account password — an expired account can
   surface as this same network/location error rather than a clear auth error.
4. If the report server and Database Engine are on different hosts and use Windows
   authentication, cross-check `/sqlspn-review` for SPN/Kerberos issues that can also
   manifest as connection failures.

**Related checks:** G5, G6, G9

---

### G8 — Orphaned Report Server Database Pointer

**What it means:** An SSRS service instance can start successfully (service status =
Running) while still being configured to use a report server database that doesn't
exist on the target instance. Because the report server polls its database
(`PollingInterval`, default 10 seconds) for alerts/jobs, this produces a continuous
stream of failed logons (SQL Server Error 18456) visible in the Database Engine's
ERRORLOG and security audit — not in the SSRS trace log itself.

**How to spot it:** From `/sqlerrorlog-review` or the Windows Security log: repeated
Error 18456 entries for the SSRS service account, with
`Reason: Failed to open the explicitly specified database 'ReportServer$<InstanceName>'`
where that database does not exist — while the SSRS Windows service itself shows as
Running.

**Example:** An SSRS named instance (`MSSQLSERVER2016`) was installed but its report
server database was never created/configured; the service generates thousands of Error
18456 entries per day, triggering SIEM brute-force alerts.

**Fix options:**
1. If this SSRS instance should be in use: configure a valid report server database via
   Report Server Configuration Manager's Database Setup page (this also creates the
   database if it doesn't exist).
2. If this SSRS instance is not in use: stop and disable (or uninstall) the service —
   running an unconfigured report server provides no value and only generates security
   noise.
3. Cross-check `/sqlerrorlog-review` E-checks for login-failure-burst patterns to confirm
   the volume and source before deciding.

**Related checks:** G5; sqlerrorlog-review login-failure-burst checks

---

### G9 — rsServerConfigurationError

**What it means:** `rsServerConfigurationError` is a general-purpose error indicating
`RSReportServer.config` or `RSReportDesigner.config` is missing, unreadable, or contains
an XML element with a missing/invalid value that is critical to server operation. The
report server returns this error only when the invalid setting is critical; for a
non-critical invalid value it instead falls back to an internal default and logs that to
the trace log. Malformed XML stops the server from starting at all. A second message
immediately following the error states the actual cause.

**How to spot it:**
```
rsServerConfigurationError: The report server encountered a configuration error.
<second message naming the missing/invalid file or element>
```
typically appearing immediately after a manual edit of `RSReportServer.config`. Errors
about missing or invalid critical settings are also logged to the Windows application
event log.

**Example:** A `<MemoryThreshold>` element was added with a non-numeric value while
hand-editing the config file; the service fails to start and logs
`rsServerConfigurationError` followed by a message naming the invalid element.

**Fix options:**
1. Read the line(s) immediately after the `rsServerConfigurationError` entry — that's where
   the specific cause is named.
2. If this began after a manual edit, revert to the previous version of the file
   (restore from backup) rather than guessing at the correct value.
3. Validate any setting against the
   [RsReportServer.config configuration file reference](https://learn.microsoft.com/sql/reporting-services/report-server/rsreportserver-config-configuration-file)
   before re-applying — valid value ranges and modes (Native/SharePoint/PowerBI) are
   documented per setting.

**Related checks:** G10 (a common source of invalid values)

---

## Memory Pressure and AppDomain Recycling Checks (G10–G13)

### G10 — MemorySafetyMargin / MemoryThreshold Misconfigured

**What it means:** `MemorySafetyMargin` (default 80) and `MemoryThreshold` (default 90)
are percentages of `WorkingSetMaximum` that define the low/medium/high memory-pressure
zones. `MemoryThreshold` must be greater than `MemorySafetyMargin` — if it isn't, the
boundary between "medium" and "high" pressure is undefined or inverted.

**How to spot it:**
```xml
<MemorySafetyMargin>90</MemorySafetyMargin>
<MemoryThreshold>80</MemoryThreshold>
```
(inverted from the documented `80`/`90` defaults), or either value outside 0–100.

**Example:** Someone swapped the two values while trying to make the server "more
sensitive" to memory pressure, but instead made the medium-pressure zone disappear
entirely.

**Fix options:**
1. Restore the documented defaults (`MemorySafetyMargin=80`, `MemoryThreshold=90`)
   unless there's a specific, documented load-spike scenario.
2. If customizing to react earlier to spikes (Microsoft's documented use case), lower
   `MemorySafetyMargin` while keeping `MemoryThreshold` higher — e.g. `60`/`90` makes the
   medium-pressure zone start earlier without breaking the ordering.
3. Re-check after any change via G9 (a bad value here is a common
   `rsServerConfigurationError` trigger).

**Related checks:** G9, G11, G12

---

### G11 — WorkingSetMaximum Constrains a Dedicated Report Server

**What it means:** `WorkingSetMaximum` doesn't appear in `RSReportServer.config` by
default — the report server detects available physical memory at service startup and
uses that as the ceiling. An explicit, low `WorkingSetMaximum` artificially caps the
report server's memory budget below what the hardware actually provides.

**How to spot it:**
```xml
<WorkingSetMaximum>2000000</WorkingSetMaximum>  <!-- ~2 GB, in KB -->
```
on a host with significantly more physical RAM and no other major workloads competing
for it.

**Example:** A report server with 32 GB RAM has `WorkingSetMaximum` set to ~2 GB
(2,000,000 KB) — left over from when the host ran multiple applications that have since
been moved off. The report server now hits "high pressure" responses (slowed processing,
G12 recycles) at a small fraction of available memory.

**Fix options:**
1. On a dedicated SSRS host, remove the `WorkingSetMaximum`/`WorkingSetMinimum` overrides
   entirely so the report server auto-detects available memory.
2. If the host genuinely runs multiple applications, size `WorkingSetMaximum` to the
   SSRS-specific budget intentionally and document it.
3. After changing, confirm `MemorySafetyMargin`/`MemoryThreshold` (G10) still produce
   sensible absolute thresholds against the new ceiling.

**Related checks:** G10, G12

---

### G12 — Hard AppDomain Recycle from Memory Allocation Failure

**What it means:** Unlike the scheduled `RecycleTime` recycle (soft — new requests go to
a new AppDomain while in-flight requests finish), a memory allocation failure triggers a
**hard** recycle of *all* application domains: every in-progress request is cancelled
(not restarted), interactive users must refresh, and scheduled jobs simply wait for their
next scheduled run.

**How to spot it:** A recycle event in the trace log that does not align with the
`RecycleTime` schedule (every 720 minutes / 12 hours by default) and is preceded by
memory-pressure indicators — `ExecutionLog3` `AdditionalInfo` showing large
`EstimatedMemoryUsageKB` values for concurrently-running requests just before the
recycle.

**Example:** Five users simultaneously export a large pivot-heavy report to Excel at
month-end close. `EstimatedMemoryUsageKB` for each is in the hundreds of MB; combined,
they exceed `WorkingSetMaximum`, and the report server hard-recycles, cancelling all five
exports plus everyone else's in-flight requests.

**Fix options (ranked):**
1. Identify the request(s) with the largest `EstimatedMemoryUsageKB` around the recycle
   time in `ExecutionLog3.AdditionalInfo` — these are the proximate cause.
2. Redesign the heaviest reports (reduce in-memory row counts via filters/aggregation
   pushed to the data source) or stagger their schedules (pair with G21).
3. If the load is legitimate and recurring, move SSRS to dedicated hardware with more
   memory — per Microsoft's guidance, tuning `MemorySafetyMargin`/`MemoryThreshold` (G10)
   doesn't increase throughput once requests are genuinely being dropped; it only changes
   *when* the server starts slowing down in advance of that point.

**Related checks:** G3 (new trace log file from the restart), G10, G11, G21

---

### G13 — RecycleTime / MaxAppDomainUnloadTime Tuned Away from Defaults

**What it means:** `RecycleTime` (default 720 minutes / 12 hours) controls how often
application domains are proactively recycled for process health. `MaxAppDomainUnloadTime`
(default 30 minutes) is the wait time the background-processing AppDomain gets to finish
in-flight jobs during a recycle before being forcibly restarted (terminating those jobs
incomplete).

**How to spot it:**
```xml
<RecycleTime>60</RecycleTime>             <!-- every hour, vs. default 720 -->
<MaxAppDomainUnloadTime>5</MaxAppDomainUnloadTime>  <!-- vs. default 30 -->
```
combined with `ExecutionLog3` rows where `RequestType = Subscription` and
`TimeEnd - TimeStart` regularly exceeds `MaxAppDomainUnloadTime`.

**Example:** `RecycleTime` was lowered to 60 minutes as a workaround for a memory leak.
Every hour, a nightly subscription batch that takes 12 minutes per report is at risk of
landing in the recycle window; with `MaxAppDomainUnloadTime` also lowered to 5 minutes,
some subscriptions are terminated mid-run.

**Fix options:**
1. Restore `RecycleTime` toward the 720-minute default — frequent recycling doesn't fix
   a memory leak, it only resets symptoms temporarily while adding restart overhead
   (G3).
2. Fix the underlying memory growth (G10–G12) rather than masking it with recycle
   frequency.
3. Ensure `MaxAppDomainUnloadTime` exceeds the longest observed `RequestType =
   Subscription` duration in `ExecutionLog3` — check the 95th-percentile duration before
   lowering this value for any reason.

**Related checks:** G3, G10, G19–G21

---

## Report Processing and Rendering Checks (G14–G18)

### G14 — Data Retrieval Dominates Execution Time

**What it means:** `ExecutionLog3` breaks each execution into `TimeDataRetrieval`,
`TimeProcessing`, and `TimeRendering` (all in milliseconds). When `TimeDataRetrieval` is
the dominant component, the report server is mostly waiting on the data source — SSRS
itself isn't the bottleneck.

**How to spot it:**
```sql
SELECT ItemPath, TimeStart, TimeDataRetrieval, TimeProcessing, TimeRendering
FROM ExecutionLog3
WHERE TimeDataRetrieval > (TimeProcessing + TimeRendering)
ORDER BY TimeStart DESC;
```

**Example:** A report's `TimeDataRetrieval` is consistently 8,000 ms while
`TimeProcessing` + `TimeRendering` together total under 500 ms — the dataset query is
the entire problem.

**Fix options:**
1. Capture the dataset's query/stored procedure and run `/sqlplan-review` (one-off) or
   `/sqlquerystore-review` (recurring/regressed) against it.
2. If the data doesn't need to be live, configure a cache refresh plan or report
   snapshot (G18) so most users hit `Source = Cache`/`Snapshot` instead of re-running the
   query.
3. Check for parameter-driven query plans (parameter sniffing) if `TimeDataRetrieval`
   varies widely for the same report across different parameter values.

**Related checks:** G18; sqlplan-review, sqlquerystore-review

---

### G15 — Report Processing Dominates Execution Time (Legacy Engine)

**What it means:** `TimeProcessing` covers laying out the report (grouping, sorting,
expression evaluation) independent of data retrieval and rendering. `AdditionalInfo`
includes a `ProcessingEngine` value: `1` = the legacy SQL Server 2005 processing engine,
`2` = the on-demand processing engine (incremental rendering, lower memory footprint).
Reports still on `ProcessingEngine=1` carry old-engine overhead.

**How to spot it:**
```xml
<AdditionalInfo>
  <ProcessingEngine>1</ProcessingEngine>
</AdditionalInfo>
```
with `TimeProcessing` dominant relative to `TimeDataRetrieval`/`TimeRendering`.

**Example:** A report originally authored against SQL Server 2008 Reporting Services
has never been republished from a current authoring tool and still executes under
`ProcessingEngine=1`, with noticeably higher `TimeProcessing` than newer reports of
similar complexity.

**Fix options:**
1. Republish the report from a current version of Report Builder or SSDT — this
   typically migrates it onto the on-demand processing engine.
2. If already on `ProcessingEngine=2` and `TimeProcessing` is still dominant,
   investigate report design: nested data regions, heavy expression use, or excessive
   grouping/sorting on large datasets.
3. Compare `TimeProcessing` across similarly-sized reports to confirm whether a specific
   report is an outlier before investing in a redesign.

**Related checks:** G14, G16

---

### G16 — Aborted or Failed Report Execution

**What it means:** `ExecutionLog3.Status` is `rsSuccess` on a normal execution. Any other
value is a failure or cancellation — `rsProcessingAborted` specifically means the
request was cancelled (client timeout or administrative "Manage Jobs" cancellation), not
that it errored.

**How to spot it:**
```sql
SELECT ItemPath, UserName, Status, TimeStart, TimeEnd
FROM ExecutionLog3
WHERE Status <> 'rsSuccess'
ORDER BY TimeStart DESC;
```

**Example:** A report that takes 95 seconds to render is repeatedly logged with
`Status = rsProcessingAborted` — the browser's default request timeout (often 100
seconds including network overhead) is being hit just as the report would have finished.

**Fix options (ranked):**
1. For recurring `rsProcessingAborted` on the same report: first reduce
   `TimeDataRetrieval`/`TimeProcessing` (G14/G15) so the report finishes well inside
   existing timeouts — increasing timeouts treats the symptom.
2. If the report is legitimately long-running, raise the report-level `Timeout`
   property and any intermediate proxy/web-server timeouts together (mismatched timeouts
   between layers cause the abort to appear at the shortest one).
3. For non-`rsProcessingAborted` error statuses, look up the specific error code in
   [Cause and resolution of Reporting Services errors](https://learn.microsoft.com/sql/reporting-services/troubleshooting/cause-and-resolution-of-reporting-services-errors).

**Related checks:** G14, G15, G21

---

### G17 — External Image Fetch Latency

**What it means:** When a report embeds images referenced by URL (rather than embedded
binary images), `AdditionalInfo` records an `ExternalImages` block with `Count`,
`ByteCount`, and `ResourceFetchTime` (milliseconds) — time spent synchronously fetching
those images during rendering.

**How to spot it:**
```xml
<ExternalImages>
  <Count>3</Count>
  <ByteCount>9268</ByteCount>
  <ResourceFetchTime>1800</ResourceFetchTime>
</ExternalImages>
```
where `ResourceFetchTime` is a material fraction of `TimeRendering`.

**Example:** A report header pulls a company logo from an external marketing CDN;
`ResourceFetchTime` of 1.8 seconds accounts for most of a 2.1-second `TimeRendering` for
an otherwise simple report.

**Fix options:**
1. Replace URL-referenced images with embedded images (stored in the report definition)
   for frequently-run reports.
2. If the image must stay external, host it on infrastructure with reliable
   low-latency access from the report server.
3. Treat this as a minor contributor — it rarely explains large `TimeRendering` values on
   its own; check for other rendering-heavy elements (large tables/charts, many pages)
   first.

**Related checks:** G15

---

### G18 — Live Execution Source for Cacheable Reports

**What it means:** `ExecutionLog3.Source` records how the execution was served:
`Live` (full data retrieval/processing/rendering), `Cache`, `Snapshot`, `History`,
`AdHoc`, `Session`, or `RDCE`. Repeated `Source = Live` for the same report and parameter
combination within a short window means every execution pays the full cost identified
by G14, even though the underlying data likely hasn't changed.

**How to spot it:**
```sql
SELECT ItemPath, Parameters, COUNT(*) AS live_runs
FROM ExecutionLog3
WHERE Source = 'Live'
GROUP BY ItemPath, Parameters
HAVING COUNT(*) > 5
ORDER BY live_runs DESC;
```

**Example:** A dashboard report with the same default parameters is run `Live` over 200
times in a single business day by different users — each run re-executes the same
dataset query.

**Fix options:**
1. Configure a cache refresh plan (time-based or on a schedule) so subsequent requests
   with matching parameters return `Source = Cache`.
2. For reports that only need periodic data (e.g. daily totals), configure a report
   snapshot schedule — executions return `Source = Snapshot` and skip data retrieval
   entirely.
3. Re-run the G18 query after enabling caching/snapshots to confirm `Live` executions
   dropped as expected.

**Related checks:** G14

---

## Subscriptions and Delivery Checks (G19–G21)

### G19 — File Share Delivery Failure

**What it means:** File share subscriptions write rendered reports to a UNC path using
the `FileShareDeliveryProvider`. A failure here is logged in the trace log (not
`ExecutionLog3`, which only covers report execution, not delivery) by the `filesys`/
`FileShareDeliveryProvider` component.

**How to spot it:**
```
filesys!WindowsService_10!4c7c!05/24/2016-01:05:06 e ERROR: Failure writing file
\\ServerName\SalesReports\report.xls :
Microsoft.ReportingServices.FileShareDeliveryProvider.FileShareProvider+NetworkErrorException:
An impersonation error occurred using the security context of the current user.
```

**Example:** A file share subscription that worked for months starts failing every run
with the impersonation exception above after the report server's service account
password was rotated, or after the target file share moved to a different server.

**Fix options (ranked):**
1. Verify the credentials saved on the subscription (or the report server service
   account, if using "credentials supplied by the user running the subscription") are
   current and have write permission on the target share.
2. If the file share is on a different host than the report server, this is the classic
   SSRS double-hop — constrained Kerberos delegation from the report server's service
   account to the file server's CIFS service is required. Cross-check `/sqlspn-review`.
3. Test writing to the UNC path manually as the configured account
   (`runas /user:<account> cmd`, then `copy` a test file) to isolate permissions from
   delegation.

**Related checks:** G13 (long-running subscriptions vs. recycle timing), sqlspn-review

---

### G20 — Email Delivery Failure

**What it means:** Email subscriptions use the `emailextension` component and SMTP
settings from `RSReportServer.config` (`SMTPServer`, `SendUsingAccount`,
`SMTPAuthenticate`, etc.). A delivery failure here is an `SmtpException` logged by the
`emailextension` component.

**How to spot it:**
```
emailextension!WindowsService_7!b60!05/20/2019-22:34:41 ERROR: Error sending email.
Exception: System.Net.Mail.SmtpException: The SMTP server requires a secure connection
or the client wasn't authenticated. The server response was: 5.7.1 Client wasn't authenticated
```

**Example:** A company-wide move to require authenticated/TLS SMTP relays breaks every
SSRS email subscription overnight — they were all configured for anonymous relay.

**Fix options:**
1. Update SMTP settings (server, port, authentication mode, credentials) via Report
   Server Configuration Manager to match the mail server's current requirements.
2. Confirm the report server host's IP is still permitted to relay through the SMTP
   server (IP allow-lists are a common companion change when authentication is added).
3. Test the new SMTP configuration with a single manual subscription before assuming all
   subscriptions are fixed — different subscriptions can use different
   `SendUsingAccount`/credential combinations.

**Related checks:** G19, G24 (SMTP credentials are encrypted with the symmetric key)

---

### G21 — Subscription Scheduling Clustered at Peak Times

**What it means:** Scheduled subscriptions execute concurrently when their schedules
overlap. `ExecutionLog3` rows with `RequestType = Subscription` clustering at round-hour
boundaries indicate many subscriptions were configured with the same convenient
"top of the hour" time, creating a burst of concurrent processing.

**How to spot it:**
```sql
SELECT DATEPART(hour, TimeStart) AS run_hour, DATEPART(minute, TimeStart) AS run_minute,
       COUNT(*) AS subscription_count
FROM ExecutionLog3
WHERE RequestType = 'Subscription'
GROUP BY DATEPART(hour, TimeStart), DATEPART(minute, TimeStart)
ORDER BY subscription_count DESC;
```

**Example:** 40 subscriptions are all scheduled for 08:00, competing for
`MaxQueueThreads` and memory at the same moment every business day — some run slowly,
and on heavy days a few hit G12 (hard recycle) or G16 (aborted).

**Fix options:**
1. Stagger subscription schedules across a wider window using minute-level offsets
   (08:00, 08:02, 08:05, ...) rather than identical times.
2. For data-driven subscriptions delivering to many recipients, consider whether all
   recipients need the same delivery time, or whether batching across a longer window is
   acceptable.
3. If subscriptions consistently run slow as a group during the clustered window,
   cross-check `/sqlwait-review` and `/sqlmemory-review` on the report server database
   for contention during that window.

**Related checks:** G12, G13, sqlwait-review, sqlmemory-review

---

## Scale-Out and Encryption Key Checks (G22–G24)

### G22 — rsInvalidReportServerDatabase After Upgrade

**What it means:** In a scale-out deployment, multiple report server instances share one
report server database. When the first node is migrated/upgraded, the database schema is
upgraded with it. Any node not yet migrated, still running against the now-upgraded
schema, can throw `rsInvalidReportServerDatabase`.

**How to spot it:**
```
rsInvalidReportServerDatabase: ... (on a node that has not yet been migrated, following
migration of another node in the same scale-out deployment)
```

**Example:** A 3-node scale-out deployment is migrated one node at a time. After node 1
completes and the shared database schema upgrades, nodes 2 and 3 (still online, not yet
migrated) begin throwing `rsInvalidReportServerDatabase`.

**Fix options (ranked):**
1. Migrate the remaining nodes promptly — the schema mismatch is expected and transient
   during a rolling migration.
2. If a node is being decommissioned rather than migrated, remove it from the deployment
   (`rskeymgmt -r <installationID>`, found in that node's `RSReportServer.config`) rather
   than leaving it online to error indefinitely.
3. Per Microsoft's migration guidance: after the first node's migration, if that node
   becomes the shared-database node for the scale-out, old encryption keys for
   not-yet-migrated nodes may need to be removed from the **Keys** table in the report
   server database (via SSMS — the Configuration tool can't do this) before those nodes
   can re-initialize correctly. Back up the symmetric key (G24) before doing this.

**Related checks:** G23, G24

---

### G23 — rskeymgmt Scale-Out Join Failure

**What it means:** `rskeymgmt -j` joins a remote report server instance to a scale-out
deployment that shares the local instance's database. It must be run **on a node already
in the deployment**, and the `-u`/`-v` credentials must be a **local administrator on the
remote node being joined** — the utility connects to the local Report Server Windows
service via RPC and cannot manage a remote instance's keys directly.

**How to spot it:**
```
rskeymgmt -j -m <remotecomputer> -n <instance> -u <account> -v <password>
... Access is denied.
```

**Example:** An administrator runs `rskeymgmt -j` from node A to join node B, using their
own domain account — which has admin rights on node A but not on node B — and the join
fails with Access Denied.

**Fix options:**
1. Confirm the `-u`/`-v` account has local administrator rights on the **remote**
   computer (`-m`/`-n`), not just the computer where the command is run.
2. Confirm the Report Server Windows service is running on both the local node and the
   remote node being joined.
3. Confirm Windows Firewall permits the RPC endpoint (DCOM/RPC dynamic port range, or a
   configured static range) between the two nodes.
4. After a successful join, restart the Reporting Services Windows service on the joined
   node.

**Related checks:** G22, G24

---

### G24 — Symmetric Key Not Backed Up Before Migration/Scale-Out

**What it means:** The report server's symmetric key encrypts every stored credential
and connection string in the report server database — including the report server
database connection itself (G6), data source credentials, and SMTP credentials (G20).
Operations that touch this key (`rskeymgmt -s` to recreate it, migration, joining/leaving
a scale-out deployment) are destructive without a current backup.

**How to spot it:** A migration, scale-out change, or key-recreation is planned or has
occurred, and no record exists of a recent `rskeymgmt -e -f <path> -p <password>` export
or a "Backup" action from the Reporting Services Configuration tool's Encryption Keys
tab.

**Example:** An administrator runs `rskeymgmt -s` to recreate the symmetric key after a
suspected compromise, without a prior backup. The recreation itself re-encrypts existing
content with the new key (this is the documented, safe path) — but if it had failed
partway, or if `rskeymgmt -d` had been used instead, every stored credential would need
manual re-entry with no backup to fall back on.

**Fix options (ranked):**
1. Before any migration, scale-out join/leave, or key recreation: back up the symmetric
   key (`rskeymgmt -e -f <path> -p <password>`, or Configuration tool → Encryption Keys
   → Backup).
2. Store the backup file and password separately (different storage, different access
   list) — per `/sqlencryption-review` key-lifecycle guidance for symmetric key handling.
3. As a security best practice independent of any planned change, recreate the symmetric
   key periodically (e.g. every few months, or immediately following a major version
   upgrade) — `rskeymgmt -s` re-encrypts existing content automatically.

**Related checks:** G6, G20, G22; sqlencryption-review key-lifecycle checks

---

## Quick Reference

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| G1 | Trace config | DefaultTraceSwitch at 4 (sustained) or 0 | Warning |
| G2 | Trace config | FileSizeLimitMb/KeepFilesForDays misconfigured | Warning |
| G3 | Trace config | Frequent trace log rollover (service restarts) | Warning/Critical |
| G4 | Trace config | Stale component-level trace override | Info |
| G5 | Connectivity | rsReportServerDatabaseUnavailable / Event 107 | Critical |
| G6 | Connectivity | rsReportServerDatabaseLogonFailed | Critical |
| G7 | Connectivity | rsErrorOpeningConnection (Error 26 etc.) | Critical |
| G8 | Connectivity | Orphaned report server DB pointer (18456 burst) | Warning |
| G9 | Connectivity | rsServerConfigurationError | Critical |
| G10 | Memory | MemoryThreshold ≤ MemorySafetyMargin or out of range | Critical |
| G11 | Memory | WorkingSetMaximum constrains dedicated server | Warning |
| G12 | Memory | Hard AppDomain recycle from allocation failure | Critical |
| G13 | Memory | RecycleTime/MaxAppDomainUnloadTime tuned away from defaults | Warning |
| G14 | Processing | TimeDataRetrieval dominates execution | Warning |
| G15 | Processing | TimeProcessing dominates, ProcessingEngine=1 | Warning |
| G16 | Processing | ExecutionLog3 Status <> rsSuccess | Critical/Warning |
| G17 | Processing | ExternalImages ResourceFetchTime material | Info |
| G18 | Processing | Repeated Source=Live for same report/params | Info |
| G19 | Subscriptions | FileShareProvider impersonation/write failure | Critical |
| G20 | Subscriptions | emailextension SmtpException | Critical |
| G21 | Subscriptions | Subscriptions clustered at peak times | Warning |
| G22 | Scale-out | rsInvalidReportServerDatabase after upgrade | Critical |
| G23 | Scale-out | rskeymgmt -j Access Denied | Warning |
| G24 | Scale-out | Symmetric key not backed up before migration | Warning |
