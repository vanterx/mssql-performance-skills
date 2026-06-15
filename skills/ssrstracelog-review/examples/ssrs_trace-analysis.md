# SSRS Trace Log Analysis — RPTSRV02 (example output)

### SSRS Health Summary
The report server lost its connection to the report server database for several minutes
this morning (`rsReportServerDatabaseUnavailable` / Event 107), restarting twice in the
process; independently, a dashboard report has been timing out daily for two days
(`rsProcessingAborted`, ~95 s processing time) and a file share subscription delivery to a
remote server is failing on every run due to an impersonation error.

### Run Facts

| Property | Value |
|----------|-------|
| Deployment | Standalone SSRS, dedicated host, 32 GB RAM |
| Instance | MSSQLSERVER |
| Trace log window | 2026-06-12 02:00 → 09:15 |
| Trace log files (24h) | 4 (1 daily rollover + 3 within 08:14–08:33) |

### Findings

| Check | Severity | Artifact | Finding | Fix |
|-------|----------|----------|---------|-----|
| G5 | Critical | Trace log + Event Log | `rsReportServerDatabaseUnavailable` at 08:14, Event 107 ×2 | Confirm report server DB instance is up and accepting remote TCP/Named Pipe connections; re-validate via Report Server Configuration Manager |
| G3 | Warning | LogFiles listing | 3 trace log rollovers within 19 minutes (08:14–08:33), outside the daily/size schedule | Correlate with G5 — the connectivity loss is the likely restart trigger |
| G1 | Warning | ReportingServicesService.exe.config | `ComponentTraceSwitch value="all:4"` — verbose tracing for every component | Revert to `all:3` for normal operation; the 31.8 MB midnight log is near `FileSizeLimitMb` (32) partly because of this |
| G16 | Critical | ExecutionLog3 | `/Ops/LiveDashboard` `Status=rsProcessingAborted` on 2 consecutive days, `TimeProcessing` ~94–95 s | Reduce processing time before raising timeouts; `TimeProcessing` dominates `TimeDataRetrieval` (~1.1–1.2 s) — investigate report design (grouping/expressions) |
| G14 | Warning | ExecutionLog3 | `/Finance/DailySales` subscription: `TimeDataRetrieval` ~8.2–8.4 s dominates `TimeProcessing`+`TimeRendering` (~0.5 s) | Capture the dataset query for `/sqlplan-review` or `/sqlquerystore-review` |
| G18 | Info | ExecutionLog3 | `/Finance/DailySales` subscription runs `Source=Live` daily at the same time/parameters | Configure a snapshot schedule for this report so the daily subscription uses `Source=Snapshot` and skips the 8 s data retrieval |
| G19 | Critical | Trace log | `FileShareDeliveryProvider` impersonation error writing to `\\FILESRV01\ExecReports\DailySales.xlsx` | Verify subscription credentials have write access to FILESRV01; check constrained Kerberos delegation from the report server to FILESRV01's CIFS service — hand off to `/sqlspn-review` |
| G11 | Info | RSReportServer.config | `WorkingSetMaximum=2000000` (~2 GB) on a dedicated 32 GB host | Remove the override so the report server can use available memory — current value caps `MemoryThreshold`/`MemorySafetyMargin` zones at ~2 GB instead of ~32 GB |
| G10 | OK | RSReportServer.config | `MemorySafetyMargin=80`, `MemoryThreshold=90` — correct ordering, documented defaults | No action |

### Root Causes (three independent issues)

1. **[G5] Report server database connectivity outage at 08:14** — the report server
   couldn't reach its database for several minutes, triggering Event 107 and (per G3) at
   least one AppDomain restart. The trace log alone doesn't show *why* the database was
   unreachable — check the Database Engine instance's own ERRORLOG for the same window
   via `/sqlerrorlog-review`.
2. **[G16] `/Ops/LiveDashboard` has been timing out for 2 days** — `TimeProcessing` of
   ~95 seconds repeatedly exceeds the effective request timeout. This is a report-design
   issue independent of the morning's connectivity blip.
3. **[G19] File share subscription delivery to FILESRV01 is failing on every run** — an
   impersonation/double-hop issue, independent of the other two findings.

### Recovery Sequence

| Step | Action | Resolves |
|------|--------|----------|
| 1 | Check the Database Engine ERRORLOG for the 08:14 window via `/sqlerrorlog-review` | G5 root cause |
| 2 | Re-validate the report server database connection via Report Server Configuration Manager once the Database Engine side is confirmed healthy | G5 |
| 3 | Review `/Ops/LiveDashboard` report design (grouping, expressions, dataset size) to reduce `TimeProcessing` below the timeout | G16 |
| 4 | Verify the file share subscription's credentials and Kerberos delegation to FILESRV01 via `/sqlspn-review`; test with `runas` + manual file copy | G19 |
| 5 | Revert `ComponentTraceSwitch` from `all:4` to `all:3` | G1 |
| 6 | Remove `WorkingSetMaximum` override on the dedicated host | G11 |
| 7 | Configure a snapshot schedule for `/Finance/DailySales` | G14, G18 |

> Analyzed by: `ssrstracelog-review` (G1–G24)
