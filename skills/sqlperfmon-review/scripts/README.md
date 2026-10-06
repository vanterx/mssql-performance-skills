# sqlperfmon-review — Capture Scripts

## capture-perfmon.ps1

Captures the counters the 14 PM checks read, or converts an existing `.blg` binary log into the
CSV the skill analyses.

### Modes

| Mode | What it does | Elevation | Touches the server |
|------|--------------|:---------:|--------------------|
| `Collect` (default) | Creates a counter log with `logman`, runs it, stops and deletes the collector, converts the `.blg` to CSV with `relog` | Required | Writes a counter log to `-OutputPath`; nothing inside SQL Server |
| `Convert` | Converts an existing `.blg` to CSV | Not required | Nothing |

Use `Convert` when a collector is already running, or when the `.blg` came from a PSSDIAG or
SQL LogScout capture someone else took.

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Mode` | `Collect` | `Collect` or `Convert` |
| `-DurationMinutes` | 15 | Minimum 5, enforced. PM1, PM3 and PM7 are defined on *sustained* behaviour; a shorter window cannot support them, which is what PM14 reports |
| `-IntervalSeconds` | 15 | Use 5 when hunting short stalls. A rate counter is an average across the interval, so an interval longer than the event hides it |
| `-InstanceName` | *(default instance)* | A named instance exposes `MSSQL$<InstanceName>:*` rather than `SQLServer:*` |
| `-OutputPath` | `C:\PerfLogs\sqlperfmon` | Created if absent |
| `-BlgPath` | — | `Convert` mode only |

### Examples

```powershell
# 20-minute capture at the default 15-second interval
.\capture-perfmon.ps1 -Mode Collect -DurationMinutes 20

# Named instance, 5-second interval for short stalls
.\capture-perfmon.ps1 -Mode Collect -DurationMinutes 15 -IntervalSeconds 5 -InstanceName SQL2019

# Convert a .blg someone else captured
.\capture-perfmon.ps1 -Mode Convert -BlgPath C:\PSSDIAG\output\sqlhost.blg
```

### Counters collected

Seventeen counter paths across five families. Two choices in the set are deliberate:

- **`\LogicalDisk(*)\...` uses the wildcard instance, not `_Total`.** PM8 exists precisely because
  a single hot volume disappears into the average, so a capture holding only `_Total` cannot
  support the check, and the skill will ask for a re-capture rather than draw a conclusion.
- **`\Plan Cache(*)\Cache Object Counts` is per cache type.** PM11's diagnosis *is* the instance:
  growth in `SQL Plans` with `Object Plans` flat means ad hoc SQL, while growth in
  `Temporary Tables & Table Variables` means temp object churn. `_Total` conflates them.

### What the script cannot capture

Two values the skill needs are not performance counters. Run this and supply the output alongside
the CSV:

```sql
SELECT cpu_count, scheduler_count, affinity_type_desc, virtual_machine_type_desc
FROM sys.dm_os_sys_info;
```

Without `cpu_count`, PM1–PM3 are reported NOT ASSESSED rather than guessed:
`Process\% Processor Time` runs from 0 to 100 × the number of logical processors, so as an absolute
number it is uninterpretable. Physical RAM is needed for PM6, which is expressed as a share of
installed memory.

### Engine counters without Perfmon

When a Perfmon capture is not possible, the `SQLServer:*` half of the counter set is available from
a DMV:

```sql
SELECT object_name, counter_name, instance_name, cntr_value, cntr_type
FROM sys.dm_os_performance_counters
WHERE counter_name IN (
        'Page life expectancy', 'Batch Requests/sec', 'SQL Compilations/sec',
        'SQL Re-Compilations/sec', 'SQL Attention rate', 'Cache Object Counts')
ORDER BY object_name, counter_name, instance_name;
```

This covers PM4 and PM9–PM13 only. The `Process`, `Processor`, `Memory` and `LogicalDisk` families
are not in the DMV, so PM1–PM3 and PM5–PM8 stay NOT ASSESSED. Note also that `cntr_type`
272696576 marks a cumulative counter: two samples and the elapsed time between them are needed to
derive a per-second rate, so a single snapshot cannot produce one.

### Exit behaviour

The script uses `$ErrorActionPreference = 'Stop'` and throws on a non-zero exit from `logman` or
`relog`. The collector is stopped and deleted in a `finally` block, so an interrupted run does not
leave a counter log running on the server.
