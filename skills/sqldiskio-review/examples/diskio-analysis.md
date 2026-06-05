# sqldiskio-review Analysis — I/O Latency and Auto-Growth Example

**Input:** `diskio_input.txt` — sys.dm_io_virtual_file_stats, sys.master_files configuration, default trace auto-growth events

---

## I/O Health Summary

**I/O is unhealthy** across 3 critical dimensions: the Orders database log file shows 31 ms write latency (3× the 10 ms Critical threshold), the Orders data file shows 47 ms read latency, and both data and log files share the same volume (D:\Data\). Three log auto-growth events occurred during production hours, each taking ~4.3 seconds and blocking all committing transactions.

---

## Findings

| Check | Severity | File | Metric | Finding | Fix |
|-------|----------|------|--------|---------|-----|
| Z1 | **Critical** | Orders.mdf | avg_read_ms = 47 | 4.7× the 10 ms warning threshold | Migrate data file to faster storage tier |
| Z3 | **Critical** | Orders_log.ldf | avg_write_ms = 31 | 3.1× the 10 ms critical threshold; every commit waits 31 ms | Separate log to dedicated NVMe volume |
| Z4 | **Warning** | tempdb.mdf | 73.2% of TempDB I/O | Primary TempDB file handles 3× its fair share | Equalize TempDB file sizes |
| Z6 | **Warning** | Orders DB | D:\Data\ | Data and log files share same volume | Move log to dedicated volume (L:\) |
| Z7 | **Warning** | tempdb | D:\Data\ | TempDB shares D:\Data\ with Orders.mdf | Move TempDB to dedicated T:\ volume |
| Z9 | **Warning** | tempdb | 20,480 MB vs 4,096 MB | tempdev (20 GB) is 5× larger than tempdev1–3 (4 GB each) | Equalize to equal sizes via SHRINKFILE + MODIFY FILE |
| Z11 | **Critical** | Orders_log.ldf | 3 events in 24 h | 3 log auto-grows + 1 data auto-grow on production hours | Pre-size log; increase growth increment (Z13) |
| Z12 | **Warning** | Orders.mdf | growth = 64 MB | Fixed 64 MB increment — too small for an 80 GB database | Set FILEGROWTH = 512MB minimum |
| Z13 | **Warning** | Orders_log.ldf | growth = 64 MB | Log grows 64 MB at a time; each growth takes ~4.3 seconds | Set log FILEGROWTH = 256MB or larger |
| Z14 | **Warning** | Orders_log.ldf | 08:14, 11:27, 14:51 | All 3 growth events during business hours (08:00–15:00) | Pre-grow during nightly maintenance window |

---

## Top I/O Offenders

1. **Orders.mdf** — 47 ms avg read (Critical), on shared D:\Data\ volume competing with log and TempDB
2. **Orders_log.ldf** — 31 ms avg write (Critical), 3 auto-grow events, 64 MB growth increment
3. **tempdb.mdf** — 73.2% of TempDB I/O load due to file size imbalance

---

## Auto-Growth Summary

- **4 events in 24 hours** — 3 log + 1 data, all on the Orders database
- **Average log growth duration: 4.27 seconds** per event — each blocked all active committers
- **Total downgrade time: ~12.8 seconds** of transaction stall from log growth alone
- **Files with undersized growth:** Orders.mdf (64 MB), Orders_log.ldf (64 MB); tempdev files (10% growth on a 20 GB file = 2 GB growth event — dangerous)

---

## Recommended Next Steps

1. **Immediate:** Move Orders_log.ldf to a dedicated NVMe volume — this eliminates Z3 (31 ms log latency) and Z6 (data/log co-location) simultaneously
   ```sql
   ALTER DATABASE Orders MODIFY FILE (NAME = Orders_log, FILENAME = 'L:\Logs\Orders_log.ldf');
   -- Restart SQL Server or use offline/online cycle to move the file
   ```
2. **Immediate:** Increase Orders log growth increment and pre-size the log:
   ```sql
   ALTER DATABASE Orders MODIFY FILE (NAME = Orders_log, SIZE = 20480MB, FILEGROWTH = 512MB);
   ALTER DATABASE Orders MODIFY FILE (NAME = Orders, FILEGROWTH = 512MB);
   ```
3. **Short-term:** Equalize TempDB data files and move to a dedicated volume:
   ```sql
   DBCC SHRINKFILE (tempdev, 4096);
   ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev',  SIZE = 4096MB, FILEGROWTH = 512MB);
   ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev1', SIZE = 4096MB, FILEGROWTH = 512MB);
   ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev2', SIZE = 4096MB, FILEGROWTH = 512MB);
   ```
4. **Short-term:** Investigate why Orders.mdf has 47 ms read latency — pair with `/sqlmemory-review` to check if low PLE is forcing physical reads, and `/sqlwait-review` for PAGEIOLATCH wait composition
5. **Nightly maintenance job:** Pre-grow Orders database files during the 02:00–04:00 window to eliminate Z14 production-hours growth events

> Analyzed by: `sqldiskio-review` (Z1–Z15)
