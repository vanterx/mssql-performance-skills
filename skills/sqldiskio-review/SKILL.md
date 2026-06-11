---
name: sqldiskio-review
description: Analyze SQL Server file-level I/O latency and auto-growth events using sys.dm_io_virtual_file_stats, sys.master_files, and default trace auto-growth records. Applies 15 checks (Z1–Z15) covering data and log file latency thresholds, hot file detection, stall ratio analysis, data and log placement on the same volume, TempDB co-location with user databases, auto-growth event frequency and sizing, file growth during production hours, system drive file placement, and multi-snapshot I/O trend analysis. Use this skill whenever a DBA suspects slow I/O, queries show PAGEIOLATCH or WRITELOG waits, or a file grew unexpectedly. Trigger when pasting output from sys.dm_io_virtual_file_stats or sys.master_files.
triggers:
  - /sqldiskio-review
  - /diskio-review
  - /io-latency
---

# SQL Server Disk I/O Review Skill

## Purpose

Analyze SQL Server file-level I/O performance and storage configuration issues. Applies 15 checks (Z1–Z15) across three categories:

- **Z1–Z5** — Latency and stall analysis: data file read/write latency, log file write latency, stall ratio per file, and hot file detection
- **Z6–Z10** — Storage placement and configuration: data and log on the same volume, TempDB co-location, system drive placement, file count imbalance, and TempDB log latency
- **Z11–Z15** — Auto-growth patterns: auto-growth events in recent hours, fixed-MB growth on data files, log file growth too small, growth events during peak hours, and multi-snapshot I/O trend worsening

## Input

Accept any of:
- A **snapshot pair** from `sys.dm_io_virtual_file_stats` capture query below — two captures taken seconds/minutes apart with the delta calculated (preferred)
- A single raw output from `sys.dm_io_virtual_file_stats` (cumulative since startup); note that single captures reflect all-time averages since the last SQL Server restart
- Output from `sys.master_files` for file placement and auto-growth configuration
- Default trace query output showing recent auto-growth events
- A natural language description of symptoms ("log file grew three times today, data drive showing 80ms reads")

### Recommended capture queries

```sql
-- 1. I/O latency snapshot (cumulative since restart or since last baseline)
-- Best practice: capture twice 60 seconds apart and subtract to get interval stats
SELECT
    DB_NAME(vfs.database_id)            AS database_name,
    mf.physical_name,
    mf.type_desc,
    vfs.io_stall_read_ms,
    vfs.num_of_reads,
    vfs.io_stall_write_ms,
    vfs.num_of_writes,
    vfs.io_stall,
    vfs.num_of_bytes_read    / 1048576  AS mb_read,
    vfs.num_of_bytes_written / 1048576  AS mb_written,
    CASE WHEN vfs.num_of_reads  > 0
         THEN vfs.io_stall_read_ms  / vfs.num_of_reads  ELSE 0 END AS avg_read_ms,
    CASE WHEN vfs.num_of_writes > 0
         THEN vfs.io_stall_write_ms / vfs.num_of_writes ELSE 0 END AS avg_write_ms,
    CASE WHEN (vfs.num_of_reads + vfs.num_of_writes) > 0
         THEN vfs.io_stall / (vfs.num_of_reads + vfs.num_of_writes)
         ELSE 0 END AS avg_stall_per_io_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
  ON vfs.database_id = mf.database_id
 AND vfs.file_id     = mf.file_id
ORDER BY vfs.io_stall DESC;

-- 2. File configuration (placement and auto-growth settings)
SELECT
    DB_NAME(database_id) AS database_name,
    name                 AS logical_name,
    physical_name,
    type_desc,
    size * 8 / 1024      AS size_mb,
    CASE is_percent_growth
         WHEN 1 THEN CAST(growth AS VARCHAR) + '%'
         ELSE CAST(growth * 8 / 1024 AS VARCHAR) + ' MB'
    END AS growth_setting,
    max_size,
    is_read_only
FROM sys.master_files
ORDER BY database_id, type;

-- 3. Auto-growth events from default trace (last 24 hours)
DECLARE @tracefile NVARCHAR(500);
SELECT @tracefile = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX('\', REVERSE(path)), 500))
    + N'log.trc'
FROM sys.traces WHERE is_default = 1;

SELECT
    DatabaseName,
    FileName,
    CASE EventClass WHEN 92 THEN 'Data Auto-Grow'
                    WHEN 93 THEN 'Log Auto-Grow' END AS event_type,
    Duration                        AS duration_ms,  -- Duration is reported in milliseconds for event classes 92/93
    IntegerData * 8 / 1024          AS growth_mb,
    StartTime
FROM fn_trace_gettable(@tracefile, DEFAULT)
WHERE EventClass IN (92, 93)
  AND StartTime >= DATEADD(HOUR, -24, GETDATE())
ORDER BY StartTime DESC;
```

---

## Thresholds Reference

| Metric | Good | Warning | Critical |
|--------|------|---------|----------|
| Data file avg read latency | < 10 ms | 10–20 ms | > 20 ms |
| Data file avg write latency | < 10 ms | 10–20 ms | > 20 ms |
| Log file avg write latency | < 5 ms | 5–10 ms | > 10 ms |
| Stall ratio (avg stall ms per I/O operation) | < 5 ms | 5–15 ms | > 15 ms |
| Hot file: single file share of total I/O | < 60% | 60–80% | > 80% |
| Auto-growth events in last 24 h | 0 | 1–3 | > 3 |
| Auto-growth fixed-size increment | ≥ 256 MB | 64–255 MB | < 64 MB |

---

## Latency and Stall Checks (Z1–Z5)

Run these first — latency is the direct measure of disk I/O quality.

### Z1 — Data File Read Latency
- **Trigger:** `avg_read_ms` for any data file (type_desc = `ROWS`) > 20 ms
- **Severity:** Warning if 10–20 ms; Critical if > 20 ms
- **Fix:** Data read latency above 20 ms indicates the storage subsystem is not keeping up with SQL Server's I/O demands. Root causes: (1) insufficient IOPS on the volume — check if the storage tier (HDD, SSD, NVMe) is appropriate for the workload; (2) storage contention from another workload on the same spindles/LUN; (3) RAID rebuild in progress; (4) the working set is larger than the buffer pool (pair with `/sqlmemory-review` O1 for low PLE). On Azure VMs, verify the disk is Premium SSD and the VM I/O bandwidth cap is not being hit.

### Z2 — Data File Write Latency
- **Trigger:** `avg_write_ms` for any data file (type_desc = `ROWS`) > 20 ms
- **Severity:** Warning if 10–20 ms; Critical if > 20 ms
- **Fix:** Write latency above 20 ms on data files indicates checkpoint writes are stalling. Causes: (1) write cache disabled or write-through on the storage controller; (2) RAID write penalty (RAID-5/6 should be avoided for SQL data files); (3) storage controller cache is full due to heavy write workload. Enable write-back caching on the storage controller (with a battery-backed unit or supercapacitor to protect against power loss). For Azure, check if Azure Write Accelerator is appropriate for log files.

### Z3 — Log File Write Latency
- **Trigger:** `avg_write_ms` for any transaction log file (type_desc = `LOG`) > 10 ms
- **Severity:** Warning if 5–10 ms; Critical if > 10 ms
- **Fix:** Log writes are synchronous — every committed transaction waits for the log write to complete. High log latency directly translates to transaction latency and WRITELOG waits (see `/sqlwait-review` V6). The transaction log should be on a separate volume from data files, on low-latency storage (NVMe preferred). Check: (1) is the log file on its own dedicated volume? (Z6); (2) is the volume on a spinner? Migrate to SSD; (3) is another workload sharing the log volume?

### Z4 — Hot Data File
- **Trigger:** A single data file receives ≥ 60% of all I/O operations (reads + writes) across all data files in the same database
- **Severity:** Warning if 60–79%; Critical if ≥ 80%
- **Fix:** One file is serving the majority of I/O, indicating the database's working set is concentrated in that file's extent ranges. Solutions: (1) add secondary data files to distribute I/O — SQL Server distributes new allocations proportionally across equally-sized files; (2) check that existing data files are the same size — unequal sizes cause disproportionate fill (the larger file fills first). This is the most common TempDB issue — also check Z7 for TempDB-specific guidance.

### Z5 — High Stall Ratio
- **Trigger:** `avg_stall_per_io_ms` for any file > 15 ms (combined `io_stall / (num_of_reads + num_of_writes)` — average time each I/O operation spent stalled)
- **Severity:** Warning if 5–15 ms; Critical if > 15 ms
- **Fix:** The stall ratio measures average wait per I/O operation across reads and writes combined. A high stall ratio independent of latency can indicate: storage QoS throttling, LUN queue depth saturation, or iSCSI/FC network congestion. If latency is normal but stall ratio is high, investigate the storage path (HBA driver, multipath I/O configuration, SAN QoS policy).

---

## Storage Placement and Configuration Checks (Z6–Z10)

### Z6 — Data and Log on Same Volume
- **Trigger:** Any database has data files and log files sharing the same drive letter or mount point path prefix (comparing `physical_name` from `sys.master_files`)
- **Severity:** Warning
- **Fix:** Data and log files compete for I/O when co-located, and a data file growth event can fill the volume and immediately prevent log writes. Place log files on a dedicated volume. Separate physical spindles or SSD tiers ensure that log writes (which must be sequential and low-latency) do not compete with random data read/write traffic.

### Z7 — TempDB on Same Volume as User Database Files
- **Trigger:** TempDB data files share a volume with user database data or log files
- **Severity:** Warning
- **Fix:** TempDB is heavily used for sort spills, hash joins, temporary tables, and row versioning. Co-locating it with user databases creates I/O interference in both directions. Place TempDB data files on a dedicated, low-latency volume. On systems with NVMe drives, TempDB is an ideal candidate for local NVMe storage since it is recreated at startup and does not need to survive restarts.

### Z8 — TempDB Log File Latency
- **Trigger:** `avg_write_ms` for the TempDB log file > 10 ms
- **Severity:** Warning if 5–10 ms; Critical if > 10 ms
- **Fix:** TempDB log latency is particularly impactful because version store operations and row-level locking all pass through the TempDB log. High TempDB log latency stalls even simple update workloads. Place TempDB on NVMe or dedicated SSD. Also check Z7 for volume co-location issues.

### Z9 — File Count Imbalance (Single File Handles Most I/O)
- **Trigger:** When a database (especially TempDB) has multiple data files, one file handles > 70% of total data file I/O
- **Severity:** Warning
- **Fix:** Files must be the same size for SQL Server's proportional fill algorithm to distribute I/O evenly. Shrink and resize files to equal sizes, then grow them together. For TempDB specifically, a common misconfiguration is having the primary file larger because it was created at setup before secondary files were added. Use `DBCC SHRINKFILE` + `ALTER DATABASE ... MODIFY FILE` to equalize sizes. Note: for TempDB, `sys.master_files` shows the configured startup size, not the current size — query `tempdb.sys.database_files` for current file sizes.

### Z10 — Database File on System Drive
- **Trigger:** Any database file (data or log) has `physical_name` starting with the system drive letter (typically `C:\`)
- **Severity:** Warning
- **Fix:** Database files on the system drive compete for space and I/O with the OS, Windows paging file, and application logs. A data file filling the system drive can freeze the OS. Move user database files to a dedicated data volume using `ALTER DATABASE ... MODIFY FILE` (then detach/reattach or use `ALTER DATABASE ... SET OFFLINE` + file move). System databases (master, msdb, model) may be on the system drive but should be assessed for growth risk.

---

## Auto-Growth Pattern Checks (Z11–Z15)

### Z11 — Auto-Growth Events in Last 24 Hours
- **Trigger:** Default trace shows ≥ 1 auto-growth event for any database file in the past 24 hours
- **Severity:** Warning if 1–3 events; Critical if > 3 events
- **Fix:** Auto-growth is a reactive, blocking operation — queries stall while the file grows. The goal is to pre-size files to avoid auto-growth during normal operations. Identify the database growing, estimate its daily growth rate, and pre-grow by 1–4 weeks of projected growth. Auto-growth should be a safety net for unusual spikes, not a routine occurrence. Monitor with a SQL Agent job or custom XE session targeting EventClass 92/93.

### Z12 — Data File Auto-Growth Too Small (Fixed MB)
- **Trigger:** Any data file in `sys.master_files` has `is_percent_growth = 0` AND `growth * 8 / 1024` < 256 MB (i.e., grows in increments < 256 MB)
- **Severity:** Warning if 64–255 MB; Critical if < 64 MB
- **Fix:** Small fixed-MB increments mean the file will grow frequently in small steps, each causing a stall. SQL Server databases should grow in large increments (256 MB to 1 GB or more for large databases) or use percentage growth only on small databases (< 10 GB). Avoid percent growth on large databases — a 10% growth on a 1 TB database triggers a 100 GB allocation event that can take minutes. Use: `ALTER DATABASE [name] MODIFY FILE (NAME = logical_name, FILEGROWTH = 512MB)`.

### Z13 — Log File Auto-Growth Too Small
- **Trigger:** Any log file has `growth * 8 / 1024` < 128 MB (if fixed) OR `is_percent_growth = 1` AND `growth` > 10 (percent growth on a large log)
- **Severity:** Warning
- **Fix:** Log auto-growth events are especially impactful because they are synchronous — the writing session must wait. Set log file growth to a fixed increment large enough to avoid frequent events: typically 256 MB for small databases, 1 GB+ for databases with high transaction volume. Avoid percentage-based growth on log files as the increments become unmanageably large.

### Z14 — Auto-Growth During Production Hours
- **Trigger:** Default trace shows auto-growth events occurring between 07:00 and 21:00 local time (configurable), especially on high-transaction databases
- **Severity:** Warning
- **Fix:** Auto-growth during peak hours directly impacts user-facing transactions. This indicates the database was not pre-sized appropriately for the day's expected load. Pre-grow the file in a nightly maintenance window using a SQL Agent job: `ALTER DATABASE [name] MODIFY FILE (NAME = logical_name, SIZE = <new_size>MB)`. Monitor growth trends over 30–90 days to project future needs.

### Z15 — I/O Stall Trend Worsening Across Snapshots
- **Trigger:** When ≥ 3 time-based snapshots of `sys.dm_io_virtual_file_stats` are provided, `avg_read_ms` or `avg_write_ms` for the same file shows a monotonically increasing pattern across snapshots
- **Severity:** Warning if worsening over 2 consecutive snapshots; Critical if worsening over 3+ consecutive snapshots
- **Fix:** Worsening I/O latency over time suggests: storage subsystem degradation (drive health — check Windows Event Log for disk errors), growing data volume outpacing storage IOPS capacity, or a storage maintenance operation (RAID rebuild, snapshot replication). Pull storage controller event logs and correlate with the latency onset time. For cloud storage (Azure Managed Disks, AWS EBS), check the cloud provider's disk metrics for throttling events.

---

## Output Format

Present findings in this order:

1. **I/O Health Summary** — one sentence: is I/O within acceptable latency bounds for all files?
2. **Findings table** — one row per triggered check:

| Check | Severity | File | Metric | Finding | Fix |
|-------|----------|------|--------|---------|-----|
| Z3 | Critical | AdventureWorks.ldf | avg_write_ms = 42 ms | Log write latency 4× threshold | Move log to dedicated NVMe volume |

3. **Top I/O offenders** — list the 3 files with highest latency or stall count.
4. **Auto-growth summary** — count of events in 24 h, files affected, growth sizes.
5. **Recommended next steps** — ordered action list with companion skill references.

> Analyzed by: `sqldiskio-review` (Z1–Z15)

---

## Companion Skills

- `/sqlwait-review` — PAGEIOLATCH_SH/EX (V1–V3) and WRITELOG (V6) waits are the live signal of disk I/O pressure that this skill explains at the file level; run both together
- `/sqlmemory-review` — low PLE (O1) often manifests as high read latency (Z1) because the buffer pool can't keep the working set in memory; fix memory first, then reassess I/O
- `/sqltrace-review` — identifies which queries are generating the most physical I/O, pairing trace patterns with file-level stats
- `/sqlplan-review` — scan operators (N17–N19) explain why a single query is driving high read I/O; key lookups (N3) translate to random I/O on data files

---

## VERSION_COMPATIBILITY

See [skills/VERSION_COMPATIBILITY.md](../VERSION_COMPATIBILITY.md) for the full compatibility matrix.

| Check | 2008 R2 | 2012 | 2014 | 2016 | 2017 | 2019 | 2022 | Azure SQL |
|-------|---------|------|------|------|------|------|------|-----------|
| Z1 Data read latency | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z2 Data write latency | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z3 Log write latency | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z4 Hot data file | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z5 Stall ratio | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z6 Data+log same vol | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Managed |
| Z7 TempDB co-location | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A |
| Z8 TempDB log latency | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A |
| Z9 File imbalance | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z10 System drive | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A |
| Z11 Auto-grow 24h | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Partial |
| Z12 Growth increment | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z13 Log growth | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z14 Peak-hour growth | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Partial |
| Z15 Trend worsening | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
