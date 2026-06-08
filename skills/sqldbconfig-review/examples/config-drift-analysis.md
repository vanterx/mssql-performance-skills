# SQL Server Configuration Review

## Summary
- **3 Critical, 12 Warnings, 3 Info**
- **Highest-risk finding:** [C1] Max Server Memory not configured on a 256 GB server — SQL Server can consume all available RAM
- **Databases affected:** SalesDB (auto-shrink, VLF, percent growth), ReportDB (compatibility level, auto-close, page verify, auto-update stats, Trustworthy, db-chaining), tempdb (file count)
- **Instance-level:** MAXDOP = 0 on 4-NUMA, CTP at default, OLE Automation on, cross-DB chaining on, MAXDOP misconfigured, IFI disabled

---

### Critical Issues

**[C1] Max Server Memory Not Configured (B6)**
- **Observed:** `max server memory (MB) config_value = 0` — `value_in_use = 2,147,483,647 MB`
- **Impact:** On a 256 GB server, SQL Server will eventually claim 240+ GB, leaving insufficient memory for the OS kernel and other services. OS paging will cause catastrophic performance degradation.
- **Fix:** Reserve ~10% for OS (25 GB). Set immediately — no restart required:
  ```sql
  EXEC sp_configure 'max server memory (MB)', 235520;  -- 230 GB
  RECONFIGURE;
  ```

**[C2] Auto-Shrink Enabled — SalesDB (B10)**
- **Observed:** `SalesDB.is_auto_shrink_on = 1`
- **Impact:** SalesDB undergoes repeated shrink-grow cycles. Each growth on the 10% percent-configured data file can be 5+ GB, blocking sessions during the zeroing operation (IFI is also disabled — B22). Severe index fragmentation accumulates.
- **Fix:**
  ```sql
  ALTER DATABASE [SalesDB] SET AUTO_SHRINK OFF;
  ```

**[C3] Auto-Close Enabled — ReportDB (B11)**
- **Observed:** `ReportDB.is_auto_close_on = 1`
- **Impact:** ReportDB evicts its buffer pool and plan cache on every connection drain. The first connection to each new pool burst incurs 2–10 second re-initialisation latency.
- **Fix:**
  ```sql
  ALTER DATABASE [ReportDB] SET AUTO_CLOSE OFF;
  ```

---

### Warnings

**[W1] MAXDOP = 0 on 4-NUMA Instance (B1)**
- **Observed:** `max degree of parallelism config_value = 0`, `numa_node_count = 4`, `scheduler_count = 64`
- **Impact:** Queries may consume all 64 schedulers, forcing cross-NUMA memory allocation (2–3× latency) and starving concurrent workloads.
- **Fix:** Set MAXDOP to schedulers-per-NUMA-node = 64/4 = 16, capped at 8:
  ```sql
  EXEC sp_configure 'max degree of parallelism', 8;
  RECONFIGURE;
  ```

**[W2] Cost Threshold for Parallelism at Default (B2)**
- **Observed:** `cost threshold for parallelism config_value = 5`
- **Impact:** On a 64-core server, queries with cost as low as 6 units trigger parallel plans — causing excessive CXPACKET waits and thread pool pressure.
- **Fix:**
  ```sql
  EXEC sp_configure 'cost threshold for parallelism', 50;
  RECONFIGURE;
  ```

**[W3] Optimize for Ad Hoc Workloads Disabled (B4)**
- **Observed:** `optimize for ad hoc workloads config_value = 0`
- **Impact:** Single-use ad hoc query plans are cached in full on first execution, bloating the plan cache and crowding the buffer pool.
- **Fix:**
  ```sql
  EXEC sp_configure 'optimize for ad hoc workloads', 1;
  RECONFIGURE;
  ```

**[W4] Compatibility Level Below SQL Version — ReportDB (B12)**
- **Observed:** `ReportDB.compatibility_level = 100` (SQL 2008) on SQL Server 2019 (level 150)
- **Impact:** ReportDB misses 11 years of cardinality estimator improvements, IQP features (Adaptive Joins, Memory Grant Feedback, Batch Mode on Rowstore), and modern T-SQL syntax.
- **Fix:** Test workload with Query Store enabled, then:
  ```sql
  ALTER DATABASE [ReportDB] SET COMPATIBILITY_LEVEL = 150;
  ```

**[W5] RCSI Not Enabled — SalesDB, ReportDB (B13)**
- **Observed:** `is_read_committed_snapshot_on = 0` on SalesDB and ReportDB
- **Impact:** READ COMMITTED readers block on writers and vice versa — common cause of blocking chains in OLTP workloads.
- **Fix:**
  ```sql
  ALTER DATABASE [SalesDB] SET READ_COMMITTED_SNAPSHOT ON;
  ALTER DATABASE [ReportDB] SET READ_COMMITTED_SNAPSHOT ON;
  ```

**[W6] Page Verification Not CHECKSUM — ReportDB (B14)**
- **Observed:** `ReportDB.page_verify_option_desc = 'NONE'`
- **Impact:** Storage corruption on ReportDB pages will not be detected until the corruption causes query errors or data inconsistency.
- **Fix:**
  ```sql
  ALTER DATABASE [ReportDB] SET PAGE_VERIFY CHECKSUM;
  DBCC CHECKDB ([ReportDB]) WITH NO_INFOMSGS;
  ```

**[W7] Auto-Update Statistics Disabled — ReportDB (B16)**
- **Observed:** `ReportDB.is_auto_update_stats_on = 0`
- **Impact:** Statistics on ReportDB will not be refreshed as data changes, causing increasingly inaccurate cardinality estimates and plan regressions over time.
- **Fix:**
  ```sql
  ALTER DATABASE [ReportDB] SET AUTO_UPDATE_STATISTICS ON;
  ```

**[W8] Trustworthy Enabled — ReportDB (B17)**
- **Observed:** `ReportDB.is_trustworthy_on = 1`
- **Impact:** CLR assemblies or EXECUTE AS modules in ReportDB could impersonate sysadmin if the database owner is a sysadmin member.
- **Fix:**
  ```sql
  ALTER DATABASE [ReportDB] SET TRUSTWORTHY OFF;
  ```

**[W9] Cross-DB Chaining — ReportDB (B18) and Instance-Level (B27)**
- **Observed:** `ReportDB.is_db_chaining_on = 1`; `cross db ownership chaining config_value = 1`
- **Impact:** Ownership chain traversal bypasses permission checks on cross-database and cross-server object access.
- **Fix:**
  ```sql
  ALTER DATABASE [ReportDB] SET DB_CHAINING OFF;
  EXEC sp_configure 'cross db ownership chaining', 0;
  RECONFIGURE;
  ```

**[W10] Excessive VLF Count — SalesDB (B19)**
- **Observed:** `SalesDB vlf_count = 4,821`
- **Impact:** SalesDB log backups are slow; database recovery during failover takes extended time; replication log reader scans 4,821 VLFs per scan.
- **Fix (maintenance window):**
  ```sql
  BACKUP LOG [SalesDB] TO DISK = 'NUL';
  USE [SalesDB]; DBCC SHRINKFILE (SalesDB_log, 1);
  ALTER DATABASE [SalesDB] MODIFY FILE (NAME = SalesDB_log, SIZE = 8192MB, FILEGROWTH = 512MB);
  ```

**[W11] Percent Auto-Growth — SalesDB Data + Log, TempDB Log (B20/B21)**
- **Observed:** `SalesDB_Data is_percent_growth = 1 (10%)`, `SalesDB_log is_percent_growth = 1 (10%)`, `tempdb templog is_percent_growth = 1 (10%)`
- **Impact:** A 10% growth on the 50 GB SalesDB data file = 5 GB event. A 10% growth on the 8 GB log = 819 MB event. Log files cannot use IFI, causing blocking.
- **Fix:**
  ```sql
  ALTER DATABASE [SalesDB] MODIFY FILE (NAME = SalesDB_Data, FILEGROWTH = 1024MB);
  ALTER DATABASE [SalesDB] MODIFY FILE (NAME = SalesDB_log,  FILEGROWTH = 512MB);
  ALTER DATABASE [tempdb]  MODIFY FILE (NAME = templog,      FILEGROWTH = 256MB);
  ```

**[W12] Instant File Initialization Not Enabled (B22)**
- **Observed:** `instant_file_initialization_enabled = 0`
- **Impact:** All data file growth events (B21) and `RESTORE DATABASE` operations require full zeroing of new space, causing multi-second to multi-minute blocking.
- **Fix:** Grant `SE_MANAGE_VOLUME_NAME` to the SQL Server service account via Local Security Policy → "Perform volume maintenance tasks", then restart SQL Server service.

**[W13] TempDB File Count Below Recommended (B23)**
- **Observed:** 2 TempDB data files vs. MIN(64 schedulers, 8) = 8 recommended
- **Impact:** On a 64-scheduler server, 2 TempDB files cause severe PFS/GAM/SGAM allocation page contention during concurrent workloads, manifesting as PAGELATCH_EX waits.
- **Fix:** Add 6 TempDB data files equal in size to the existing 8192 MB files:
  ```sql
  ALTER DATABASE [tempdb] ADD FILE (NAME = tempdev3, FILENAME = 'D:\TempDB\tempdev3.ndf', SIZE = 8192MB, FILEGROWTH = 512MB);
  -- Repeat for tempdev4 through tempdev8
  ```

---

### Info

**[I1] OLE Automation Procedures Enabled (B25)**
- **Observed:** `Ole Automation Procedures config_value = 1`
- **Impact:** COM objects can be invoked from T-SQL, expanding the attack surface. Verify usage before disabling.
- **Action:** Search for `sp_OA*` usage: `SELECT name FROM sys.sql_modules WHERE definition LIKE '%sp_OA%'`. If none found: `EXEC sp_configure 'Ole Automation Procedures', 0; RECONFIGURE;`

**[I2] Remote Admin Connection Disabled (B28)**
- **Observed:** `remote admin connections config_value = 0`
- **Impact:** DAC access is console-only. During a server crisis, remote DAC connection is unavailable.
- **Action:** Enable if servers are managed remotely: `EXEC sp_configure 'remote admin connections', 1; RECONFIGURE;`

**[I3] Query Governor Not Configured (B5)**
- **Observed:** `query governor cost limit config_value = 0`
- **Action:** Consider enabling if runaway queries are a documented concern. Not required for all environments.

---

### Passed Checks
B7 (Min Server Memory = 0 ✓), B8 (LPIM not active ✓), B9 (AWE disabled ✓), B15 (auto-create stats ON all databases ✓), B24 (CLR disabled ✓), B26 (Ad Hoc Distributed Queries disabled ✓), B12 for SalesDB/ArchiveDB/HRDB (compatibility levels 130–150 ✓ — only ReportDB flagged), B10 for ReportDB/ArchiveDB/HRDB ✓, B11 for all except ReportDB ✓

---

### Configuration Summary Table

| Category | Setting | Current | Recommended | Check |
|----------|---------|---------|-------------|-------|
| Memory | Max Server Memory | Not set (0) | 235,520 MB | B6 ⛔ |
| Parallelism | MAXDOP | 0 | 8 | B1 ⚠️ |
| Parallelism | Cost Threshold | 5 | 50 | B2 ⚠️ |
| Parallelism | Optimize for Ad Hoc | Off | On | B4 ⚠️ |
| SalesDB | Auto-Shrink | On | Off | B10 ⛔ |
| SalesDB | RCSI | Off | On | B13 ⚠️ |
| SalesDB | Log VLF count | 4,821 | < 100 | B19 ⛔ |
| SalesDB | Data auto-growth | 10% | 1024 MB | B21 ⚠️ |
| SalesDB | Log auto-growth | 10% | 512 MB | B20 ⚠️ |
| ReportDB | Compat level | 100 | 150 | B12 ⚠️ |
| ReportDB | Auto-Close | On | Off | B11 ⛔ |
| ReportDB | Page Verify | NONE | CHECKSUM | B14 ⚠️ |
| ReportDB | Auto-Update Stats | Off | On | B16 ⚠️ |
| ReportDB | Trustworthy | On | Off | B17 ⚠️ |
| ReportDB | DB Chaining | On | Off | B18 ⚠️ |
| Instance | Cross-DB Chaining | On | Off | B27 ⚠️ |
| Instance | IFI | Disabled | Enabled | B22 ⚠️ |
| TempDB | Data file count | 2 | 8 | B23 ⚠️ |

---

*Analyzed by: Claude Sonnet 4.6 · 2026-06-08 UTC*
