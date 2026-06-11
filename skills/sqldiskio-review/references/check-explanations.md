# sqldiskio-review — Checks Explained (Z1–Z15)

## Contents
- [Latency and Stall Checks (Z1–Z5)](#latency-and-stall-checks-z1z5)
- [Storage Placement and Configuration Checks (Z6–Z10)](#storage-placement-and-configuration-checks-z6z10)
- [Auto-Growth Pattern Checks (Z11–Z15)](#auto-growth-pattern-checks-z11z15)
- [Quick Reference](#quick-reference)

---

## Latency and Stall Checks (Z1–Z5)

### Z1 — Data File Read Latency

**What it means:** Read latency measures how long SQL Server waits for the storage subsystem to return a data page. The buffer pool reads pages from disk when they are not in memory (a buffer pool miss). Latency above 20 ms causes PAGEIOLATCH waits that directly hurt query response time.

**How to spot it:** Calculate `avg_read_ms = io_stall_read_ms / NULLIF(num_of_reads, 0)` from `sys.dm_io_virtual_file_stats`.

**Example:**
```
database_name   physical_name           avg_read_ms   num_of_reads
Orders          D:\data\Orders_data.mdf 47            128,403
```
47 ms average read latency on a data file — Critical.

**Fix options (ranked by impact):**
1. **Move data files to faster storage** — NVMe (< 1 ms), SAS SSD (1–3 ms), SATA SSD (2–5 ms), SAS HDD (5–15 ms).
2. **Add more RAM** to reduce physical read demand — a larger buffer pool means fewer disk reads.
3. **Add indexes** to convert full-scan operations to seeks, reducing I/O volume.
4. **Separate workloads** — report queries performing full scans should not share storage with OLTP.
5. **For cloud (Azure/AWS)**: verify the disk SKU has sufficient IOPS; check for disk-level throttling in platform metrics.

**Related checks:** Z4 (hot file), Z5 (stall ratio), paired with `/sqlwait-review` V1–V3

---

### Z2 — Data File Write Latency

**What it means:** Write latency measures the time SQL Server waits for a data page write to complete. Data file writes occur during checkpoint (dirty page flush to disk) and lazy writer operations. High write latency delays checkpoints, increasing recovery time after a crash.

**How to spot it:** `avg_write_ms = io_stall_write_ms / NULLIF(num_of_writes, 0)` from `sys.dm_io_virtual_file_stats`.

**Example:**
```
database_name   physical_name           avg_write_ms  num_of_writes
Warehouse       E:\data\Warehouse.mdf   38            52,108
```
38 ms data write latency — Critical.

**Fix options:**
1. **Enable write-back caching** on the storage controller (requires battery-backed or supercapacitor-protected cache unit).
2. **Avoid RAID-5/6** for data files — each write triggers a read-modify-write parity update, multiplying write I/O.
3. **Migrate to SSD** — NAND write latency is measured in microseconds vs. milliseconds for HDDs.
4. **Check checkpoint interval** — a very aggressive `recovery interval` triggers frequent small checkpoints. Indirect checkpoints (SQL 2016+) are more I/O-efficient.

**Related checks:** Z1, Z4, Z5

---

### Z3 — Log File Write Latency

**What it means:** Transaction log writes are synchronous — every committed transaction must wait for its log records to reach stable storage before control returns to the application. Log write latency > 10 ms directly translates to commit latency for every transaction. This is the most impactful single I/O metric for OLTP workloads.

**How to spot it:** Filter `sys.dm_io_virtual_file_stats` to `type_desc = 'LOG'`. `avg_write_ms > 10` triggers Critical.

**Example:**
```
database_name   physical_name               avg_write_ms  num_of_writes
ProductionDB    L:\logs\ProductionDB_log.ldf 28           2,840,103
```
28 ms log write latency on the production database — Critical. Every committed transaction waited ~28 ms.

**Fix options:**
1. **Dedicate the log volume** — no other files should share the log drive (see Z6).
2. **Migrate log to NVMe** — NVMe delivers < 0.5 ms sequential write latency.
3. **Enable write-back caching** with a battery-backed controller for the log volume.
4. **For Azure**: use Azure Write Accelerator on M-series VMs for log file volumes.
5. **Check for excessive small transactions** — high write count with low `avg_write_ms` may indicate chatty commits; batching reduces log flush frequency.

**Related checks:** Z6 (shared volume), Z8 (TempDB log), paired with `/sqlwait-review` V6 (WRITELOG)

---

### Z4 — Hot Data File

**What it means:** When one data file handles 60%+ of all data file I/O in a database, it creates a single-file bottleneck regardless of how many files exist. This is especially common in TempDB when secondary files are smaller than the primary.

**How to spot it:** Sum `num_of_reads + num_of_writes` per file, compute each file's share as a percentage of the database total.

**Example — TempDB:**
```
file_name        num_of_reads   num_of_writes   share_pct
tempdb.mdf       4,820,103      892,441          73.2%
tempdev1.ndf     1,203,022      215,841          18.4%
tempdev2.ndf     428,311         87,933           8.4%
```
Primary tempdb.mdf handles 73% of I/O despite two secondary files existing.

**Root cause:** Primary file is larger than secondary files — SQL Server's proportional fill algorithm allocates new extents to larger files more frequently.

**Fix options:**
1. **Equalize file sizes** — shrink the primary to match secondary files, then grow all together:
```sql
DBCC SHRINKFILE (tempdev, 8192);   -- shrink primary to 8 GB
ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev', SIZE = 8192MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev1', SIZE = 8192MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev2', SIZE = 8192MB);
```
2. **Add more equally-sized files** — TempDB should have one file per logical processor up to 8 files.

**Related checks:** Z9 (file count imbalance), Z7 (TempDB co-location)

---

### Z5 — High Stall Ratio

**What it means:** The stall ratio measures the average time each I/O operation spent stalled, across reads and writes combined. A high stall ratio independent of high average latency can indicate: QoS throttling by the storage array, iSCSI/FC network congestion, or HBA queue depth saturation. (`io_stall` is the total time users waited for I/O on the file — the sum of read and write stall time — so it must be divided by the operation count, not by the read/write stall components.)

**How to spot it:** `avg_stall_per_io_ms = io_stall / NULLIF(num_of_reads + num_of_writes, 0)` — values > 15 ms are Critical.

**Fix options:**
1. **Check storage QoS policies** — the LUN or volume may be QoS-throttled by the SAN/NAS.
2. **Review HBA queue depth** — increase the HBA queue depth setting if it is set lower than storage can handle.
3. **Check multipath I/O (MPIO) configuration** — unbalanced paths concentrate I/O on one path.
4. **Review network switch utilization** for iSCSI deployments.

**Related checks:** Z1, Z2, Z3

---

## Storage Placement and Configuration Checks (Z6–Z10)

### Z6 — Data and Log on Same Volume

**What it means:** Data files generate random I/O (reads scattered across the extent map). Log files generate sequential I/O (append-only writes). Co-locating them forces the disk head to context-switch between random and sequential patterns, degrading both. A data file growth event can also fill the volume and prevent log writes, causing transactions to fail.

**How to spot it:** Compare the drive letter prefix of `physical_name` for `type_desc = 'ROWS'` vs. `type_desc = 'LOG'` files in the same database.

**Example:**
```
database_name   type_desc   physical_name
SalesDB         ROWS        C:\SQLData\SalesDB.mdf
SalesDB         LOG         C:\SQLData\SalesDB_log.ldf
```
Both on `C:\SQLData\` — same volume.

**Fix options:**
1. `ALTER DATABASE SalesDB MODIFY FILE (NAME = SalesDB_log, FILENAME = 'L:\Logs\SalesDB_log.ldf');`
2. Stop SQL Server, move the file, restart SQL Server.
3. Or use `ALTER DATABASE ... SET OFFLINE` + `ALTER DATABASE ... MODIFY FILE` + file move + `SET ONLINE`.

**Related checks:** Z3, Z10

---

### Z7 — TempDB on Same Volume as User Database Files

**What it means:** TempDB I/O is often unpredictable and bursty — sort spills, hash join spills, and row versioning all generate sudden I/O spikes. Sharing a volume with production databases means those spikes degrade user database I/O.

**Fix options:**
1. Move TempDB data files to a dedicated volume: `ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev', FILENAME = 'T:\TempDB\tempdev.mdf');` — restart SQL Server to move.
2. On Azure or AWS, consider ephemeral local NVMe storage for TempDB (recreated on restart — no durability requirement).

**Related checks:** Z4, Z8, Z9

---

### Z8 — TempDB Log File Latency

**What it means:** The TempDB log records version store activity and row-level locking metadata. Even though TempDB is non-durable (not needed for recovery), write latency on the TempDB log still stalls user sessions because each TempDB operation must complete synchronously.

**Fix options:**
1. Same as Z3 — place TempDB log on fast storage dedicated to TempDB.
2. Reduce TempDB log demand: review queries generating large version stores (check V20 in `/sqlwait-review`).

**Related checks:** Z3, Z7

---

### Z9 — File Count Imbalance

**What it means:** SQL Server's proportional fill algorithm allocates new extents in proportion to file sizes. If one file is larger, it receives more allocations, becoming the hot file (Z4). This is especially important for TempDB, where the recommended configuration is equal-sized files.

**How to spot it:** Compare `size * 8 / 1024` (MB) across files in the same database from `sys.master_files`. For TempDB, `sys.master_files` shows the configured startup size, not the current size — use `tempdb.sys.database_files` for current sizes.

**Example:**
```
name          size_mb
tempdev       20480
tempdev1      4096
tempdev2      4096
tempdev3      4096
```
Primary file is 5× larger than secondaries — 80% of allocations go to the primary.

**Fix options:** Same as Z4 — equalize file sizes.

**Related checks:** Z4, Z7

---

### Z10 — Database File on System Drive

**What it means:** The system drive (usually C:\) hosts the OS, page file, application logs, and Windows system files. Database files on the system drive compete for space and I/O with these essential components. If a database file fills the system drive, the server can become unresponsive or blue-screen.

**Fix options:**
1. For user databases: `ALTER DATABASE [name] MODIFY FILE (NAME = logical_name, FILENAME = 'D:\SQLData\file.mdf');` — offline/move/online cycle required.
2. For system databases (master, msdb, model): moving requires reconfiguring the startup parameters in SQL Server Configuration Manager — document carefully.
3. Set a max size on files left on the system drive as a safety measure: `ALTER DATABASE [name] MODIFY FILE (NAME = logical_name, MAXSIZE = 10240MB);`

**Related checks:** Z6, Z11

---

## Auto-Growth Pattern Checks (Z11–Z15)

### Z11 — Auto-Growth Events in Last 24 Hours

**What it means:** An auto-growth event pauses the writing session while the OS allocates new disk space and optionally initializes it. For data files without instant file initialization (IFI) enabled, initialization zeros out the new space, which can take minutes for large increments on HDDs.

**How to spot it:** Query the default trace for EventClass 92 (Data Auto-Grow) and 93 (Log Auto-Grow). For these two event classes, Duration is reported in milliseconds (unlike most trace events, which report microseconds), and IntegerData is the number of 8-KB pages by which the file grew.

**Example:**
```
event_type        database   file                    duration_ms   growth_mb   time
Log Auto-Grow     Orders     Orders_log.ldf          4,280         64          2024-06-05 14:32:11
Data Auto-Grow    Orders     Orders.mdf              312           64          2024-06-05 14:33:05
Log Auto-Grow     Orders     Orders_log.ldf          4,190         64          2024-06-05 15:44:22
```
3 auto-growth events on a production database in 2 hours, log growth taking ~4 seconds each — Critical.

**Fix options:**
1. **Pre-size the database**: estimate monthly growth rate from trace history, pre-grow by 3–6 months.
2. **Enable Instant File Initialization**: grant the SQL Server service account the `Perform Volume Maintenance Tasks` right — eliminates data file initialization time. Log files zero-initialize on growth, except that starting with SQL Server 2022, log autogrowth events up to 64 MB can use instant file initialization.
3. **Increase growth increment** (see Z12) to reduce frequency.
4. **Alert on auto-growth** using a SQL Agent alert on Event 1105/1121 or a custom XE session.

**Related checks:** Z12, Z13, Z14

---

### Z12 — Data File Auto-Growth Too Small

**What it means:** A growth increment below 256 MB means the database will grow frequently in small steps. Each step is a blocking event. A 64 MB increment on a database that grows 1 GB per day triggers 16 growth events daily — each one stalling production writes.

**How to spot it:** `sys.master_files` where `type_desc = 'ROWS'` and `is_percent_growth = 0` and `growth * 8 / 1024 < 256`.

**Fix options:**
```sql
-- Set 512 MB fixed growth for data files
ALTER DATABASE [Orders] MODIFY FILE (NAME = Orders, FILEGROWTH = 512MB);
-- For large databases (> 100 GB), use 1 GB or more
ALTER DATABASE [Warehouse] MODIFY FILE (NAME = Warehouse, FILEGROWTH = 1024MB);
```
Avoid percentage growth on large databases — 10% of 1 TB = 100 GB per growth event.

**Related checks:** Z11, Z13

---

### Z13 — Log File Auto-Growth Too Small

**What it means:** Log file growth events are synchronous and block committing transactions. Unlike data files, log growth generally zeroes new space — although starting with SQL Server 2022, log autogrowth events up to 64 MB can use instant file initialization. A small log increment on a high-transaction database means frequent growth events, each adding latency to all concurrent transactions.

**Fix options:**
```sql
-- Set 256 MB fixed log growth for OLTP
ALTER DATABASE [Orders] MODIFY FILE (NAME = Orders_log, FILEGROWTH = 256MB);
-- For very active logs
ALTER DATABASE [Warehouse] MODIFY FILE (NAME = Warehouse_log, FILEGROWTH = 1024MB);
```
Also investigate whether the log is growing because log backups are not running frequently enough (broken log chain or too-infrequent backup schedule).

**Related checks:** Z11, Z12

---

### Z14 — Auto-Growth During Production Hours

**What it means:** Auto-growth during peak hours (07:00–21:00 or business hours) directly impacts end users. A 4-second growth event on a database receiving 1,000 transactions/second means 4,000 transactions are delayed or fail.

**Fix options:**
1. **Nightly pre-growth maintenance job**:
```sql
-- Run as SQL Agent job at 02:00
DECLARE @target_size_mb INT = (SELECT size * 8 / 1024 + 2048 FROM sys.master_files WHERE name = 'Orders');
ALTER DATABASE Orders MODIFY FILE (NAME = Orders, SIZE = @target_size_mb);
```
2. **Implement a growth monitoring alert** that fires when a file is within 20% of its current size.

**Related checks:** Z11, Z12, Z13

---

### Z15 — I/O Stall Trend Worsening

**What it means:** A monotonically increasing latency trend across multiple snapshots indicates the storage subsystem is degrading over time — not a one-time spike. Causes: drive failure starting, RAID rebuild in progress, growing data volume outpacing storage capacity.

**How to spot it:** Capture `sys.dm_io_virtual_file_stats` at 15-minute intervals and compare `avg_read_ms` or `avg_write_ms` per file. Three consecutive increases constitute a trend.

**Example (4 snapshots, 15 minutes apart):**
```
time     file              avg_read_ms
09:00    Orders.mdf        8
09:15    Orders.mdf        14
09:30    Orders.mdf        22
09:45    Orders.mdf        38
```
Latency more than 4× in 45 minutes — Critical trend.

**Fix options:**
1. **Check Windows Event Log** for disk error events (Event ID 7 in System log — disk I/O error).
2. **Check storage controller event log** — RAID rebuild, dead drive, or SSD wear indicator.
3. **For cloud**: check platform disk metrics for IOPS/throughput throttling events.
4. **Correlate with workload changes**: new reports, batch jobs, index rebuilds that began around the onset time.

**Related checks:** Z1, Z2, Z3

---

## Quick Reference

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| Z1 | Latency | Data read > 20 ms | Warn (10–20); Critical (> 20) |
| Z2 | Latency | Data write > 20 ms | Warn (10–20); Critical (> 20) |
| Z3 | Latency | Log write > 10 ms | Warn (5–10); Critical (> 10) |
| Z4 | Latency | Hot file ≥ 60% of DB I/O | Warn (60–79); Critical (≥ 80) |
| Z5 | Latency | Avg stall per I/O > 15 ms | Warn (5–15); Critical (> 15) |
| Z6 | Placement | Data + log same volume | Warning |
| Z7 | Placement | TempDB + user DB same volume | Warning |
| Z8 | Latency | TempDB log write > 10 ms | Warn (5–10); Critical (> 10) |
| Z9 | Config | File size imbalance in multi-file DB | Warning |
| Z10 | Placement | Any file on system drive | Warning |
| Z11 | Auto-grow | ≥ 1 growth event in 24 h | Warn (1–3); Critical (> 3) |
| Z12 | Auto-grow | Data file growth < 256 MB fixed | Warn (64–255); Critical (< 64) |
| Z13 | Auto-grow | Log file growth < 128 MB fixed | Warning |
| Z14 | Auto-grow | Growth during production hours | Warning |
| Z15 | Trend | Latency increasing across 3+ snapshots | Warn (2 inc); Critical (3+ inc) |
