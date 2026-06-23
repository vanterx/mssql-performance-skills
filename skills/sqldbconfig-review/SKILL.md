---
name: sqldbconfig-review
description: Analyze SQL Server instance and database configuration drift against proven DBA best practices. Applies 28 checks (B1–B28) across five categories: parallelism tuning (MAXDOP, Cost Threshold for Parallelism, Optimize for Ad Hoc Workloads), memory configuration (Max Server Memory, Lock Pages in Memory), database-level settings (auto-shrink, auto-close, compatibility level, RCSI, page verification, statistics, Trustworthy, cross-DB chaining), file and storage configuration (VLF count, percent auto-growth, Instant File Initialization, TempDB file count), and surface area exposure (CLR, OLE Automation, Ad Hoc Distributed Queries). Use this skill when the server behaves erratically after changes, a new instance needs a configuration audit, or silent misconfiguration is suspected as a root cause of performance or stability problems. Trigger when pasting output from sp_configure, sys.databases, sys.master_files, sys.dm_os_sys_info, or sys.dm_db_log_info.
triggers:
  - /sqldbconfig-review
  - /dbconfig-review
  - /config-audit
---

# SQL Server Database Configuration Review Skill

## Purpose

Detect instance and database configuration drift that degrades performance, causes instability, or creates security exposure. Applies 28 checks (B1–B28) across five categories:

- **B1–B5** — Parallelism: MAXDOP alignment to NUMA topology, Cost Threshold for Parallelism at default, Optimize for Ad Hoc Workloads, query governor
- **B6–B9** — Memory: Max Server Memory unconfigured, Min Server Memory, Lock Pages in Memory model, AWE (legacy 32-bit setting)
- **B10–B18** — Database settings: auto-shrink, auto-close, compatibility level, RCSI, page verification, auto-statistics, Trustworthy, cross-DB chaining
- **B19–B23** — File and storage: excessive VLF count, percent auto-growth on log and data files, Instant File Initialization, TempDB file count vs. scheduler count
- **B24–B28** — Surface area: CLR, OLE Automation Procedures, Ad Hoc Distributed Queries, instance-level cross-DB chaining, remote admin connections

## Input

Accept any of:

- Output from `EXEC sp_configure` (all rows, or filtered to specific options)
- Output from `SELECT … FROM sys.configurations` (equivalent to sp_configure)
- Output from `SELECT … FROM sys.databases` (relevant columns — see capture query below)
- Output from `SELECT … FROM sys.master_files` (file growth columns)
- Output from `SELECT … FROM sys.dm_os_sys_info` (CPU, NUMA, scheduler counts)
- Output from `SELECT … FROM sys.dm_db_log_info(db_id)` or `DBCC LOGINFO` (VLF count)
- Output from `SELECT … FROM sys.dm_server_services` (Instant File Initialization status)
- Combined paste of two or more of the above — apply all applicable checks
- A natural language description of symptoms ("auto-shrink keeps firing", "MAXDOP is 0 on a 4-NUMA server", "TempDB has 2 files on a 16-core box")

### Recommended capture queries

```sql
-- 1. Instance configuration (sp_configure)
EXEC sp_configure;
-- Or via catalog view for scripting:
SELECT name, value, value_in_use, is_dynamic
FROM sys.configurations
ORDER BY name;

-- 2. Database settings
SELECT
    name,
    compatibility_level,
    is_auto_shrink_on,
    is_auto_close_on,
    is_read_committed_snapshot_on,
    page_verify_option_desc,
    is_auto_create_stats_on,
    is_auto_update_stats_on,
    is_trustworthy_on,
    is_db_chaining_on,
    recovery_model_desc,
    state_desc
FROM sys.databases
WHERE database_id > 4       -- exclude system databases from B10-B18 drift checks
   OR database_id IN (1,2,3,4);  -- include all for full picture

-- 3. File growth configuration
SELECT
    DB_NAME(database_id)    AS database_name,
    name                    AS logical_name,
    type_desc,
    size * 8 / 1024         AS size_mb,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS varchar) + '%'
        ELSE CAST(growth * 8 / 1024 AS varchar) + ' MB'
    END                     AS growth_setting,
    is_percent_growth,
    growth,
    max_size
FROM sys.master_files
ORDER BY database_id, type;

-- 4. CPU and NUMA topology
-- numa_node_count: number of NUMA nodes (physical CPU sockets + any soft-NUMA partitions)
-- scheduler_count: user schedulers = logical CPUs visible to SQL Server
-- SQL 2016+ MAXDOP guidance (multi-NUMA):
--   ≤ 16 logical processors per NUMA node → MAXDOP ≤ logical-per-NUMA-node
--   > 16 logical processors per NUMA node → MAXDOP = half(logical-per-NUMA-node), max 16
-- SQL 2014 and earlier: MAXDOP = logical-per-NUMA-node, max 8
-- On single-NUMA or single-socket systems B1/B3 do not fire
SELECT
    cpu_count,
    scheduler_count,
    numa_node_count,            -- SQL Server 2016 SP2+
    socket_count,               -- SQL Server 2016 SP2+
    cores_per_socket,           -- SQL Server 2016 SP2+
    sql_memory_model_desc       -- SQL Server 2012 SP4 / 2016 SP1+
FROM sys.dm_os_sys_info;

-- 5. VLF count per database (SQL Server 2016 SP2+)
SELECT
    DB_NAME(s.database_id)  AS database_name,
    COUNT(l.database_id)    AS vlf_count
FROM sys.databases AS s
CROSS APPLY sys.dm_db_log_info(s.database_id) AS l
GROUP BY s.database_id
ORDER BY vlf_count DESC;

-- 6. VLF count alternative: sys.dm_db_log_stats (SQL Server 2016 SP2+)
SELECT name, total_vlf_count
FROM sys.databases AS s
CROSS APPLY sys.dm_db_log_stats(s.database_id)
ORDER BY total_vlf_count DESC;

-- 7. Instant File Initialization status
SELECT servicename, instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';
```

> **Fallback for older instances (pre-2016 SP2):** Replace queries 5/6 with `DBCC LOGINFO` per database. Replace query 7 with ERRORLOG search: look for `Database Instant File Initialization: enabled` or `disabled` near server startup.

---

## Thresholds Reference

| Check | Warning threshold | Critical threshold |
|-------|------------------|--------------------|
| B2 — Cost Threshold for Parallelism | = 5 (default, unchanged) | — |
| B6 — Max Server Memory | config_value = 0 (not set) | — |
| B7 — Min Server Memory | config_value > 0 | — |
| B12 — Compatibility level | < current SQL version × 10 | — |
| B19 — VLF count | > 1000 per database | > 5000 per database |
| B20/B21 — Percent auto-growth | any percent growth on log or data | — |
| B23 — TempDB file count | < MIN(scheduler_count, 8) | — |

---

## Checks

### B1 — MAXDOP = 0 on Multi-NUMA Instance

- **Trigger:** `sp_configure 'max degree of parallelism' config_value = 0` AND `sys.dm_os_sys_info.numa_node_count > 1`
- **Severity:** Warning
- **Fix:** NUMA (Non-Uniform Memory Access) is a hardware architecture where each CPU socket has its own local memory bank. Accessing memory on a remote NUMA node is 2–3× slower than local access. When MAXDOP = 0, a single query can span all NUMA nodes. Apply the SQL Server 2016+ guidance: if ≤ 16 logical processors per NUMA node, set MAXDOP ≤ logical-per-node; if > 16 per node, set MAXDOP = half that count, max 16. For SQL 2014 and earlier the cap is 8. Example: 4-NUMA, 64 schedulers → 16 per node → MAXDOP ≤ 16 (8 is a common starting point for OLTP). Example: 2-NUMA, 64 schedulers → 32 per node → MAXDOP = 16 (half of 32, max 16). `EXEC sp_configure 'max degree of parallelism', <value>; RECONFIGURE;`

### B2 — Cost Threshold for Parallelism at Default

- **Trigger:** `sp_configure 'cost threshold for parallelism' config_value = 5`
- **Severity:** Warning
- **Fix:** Per MS Learn the default of 5 is "a starting point, not a recommendation" and Microsoft does **not** publish a specific target value — raising it helps keep CPU-light OLTP queries on serial plans. The 25–50 (OLTP) / 45–75 (mixed) ranges below are **community/operational heuristics, not MS-documented values**. Increase in small increments and observe a full business cycle; e.g. start at 50 and tune down if needed: `EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;`. Confirm direction with waits — `CXPACKET`/`CXCONSUMER` dominating suggests it's too low; `SOS_SCHEDULER_YIELD` dominating with under-parallelized heavy queries suggests too high.

### B3 — MAXDOP Exceeds Per-NUMA CPU Count

- **Trigger:** `max degree of parallelism config_value > (scheduler_count / numa_node_count)` when `numa_node_count > 1`
- **Severity:** Warning
- **Fix:** Each NUMA node owns a local memory pool. When a parallel query uses more threads than fit within one NUMA node, allocations spill across nodes — paying the remote-access latency penalty on every page touch. Recalculate using the SQL Server 2016+ formula: logical-per-NUMA = `scheduler_count / numa_node_count`. If ≤ 16: MAXDOP ≤ logical-per-NUMA. If > 16: MAXDOP = half(logical-per-NUMA), max 16. SQL 2014 and earlier: max 8. `EXEC sp_configure 'max degree of parallelism', <value>; RECONFIGURE;`

### B4 — Optimize for Ad Hoc Workloads Disabled

- **Trigger:** `sp_configure 'optimize for ad hoc workloads' config_value = 0`
- **Severity:** Warning
- **Fix:** Enable to avoid caching single-use plans that bloat the plan cache. `EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;` Low risk, immediate benefit on OLTP servers.

### B5 — Query Governor Not Configured

- **Trigger:** `sp_configure 'query governor cost limit' config_value = 0` on instances with reported runaway queries
- **Severity:** Info
- **Fix:** Consider setting a cost limit to cap runaway queries. `EXEC sp_configure 'query governor cost limit', 3600; RECONFIGURE;` Only apply if runaway queries are a documented concern.

### B6 — Max Server Memory Not Configured

- **Trigger:** `sp_configure 'max server memory (MB)' config_value = 0`
- **Severity:** Critical
- **Fix:** Set Max Server Memory so the OS and other processes retain headroom. The "leave 10–15% of RAM (or at least 4 GB)" rule used here is a **simplified operational heuristic**, not MS-documented — MS Learn gives more detailed, tiered guidance (reserve ~1 GB per 4 GB up to 16 GB, then ~1 GB per 8 GB beyond, plus allowances for thread stacks, other instances/services, and any LPIM/columnstore/XTP footprint). Example on a 64 GB single-instance box: `EXEC sp_configure 'max server memory (MB)', 57344; RECONFIGURE;`. An unconfigured instance will consume essentially all available RAM, causing OS paging (error 17890).

### B7 — Min Server Memory Greater Than Zero

- **Trigger:** `sp_configure 'min server memory (MB)' config_value > 0`
- **Severity:** Warning
- **Fix:** Min Server Memory forces SQL Server to hold a floor of RAM even during low-load periods, starving other processes. Set to 0 unless there is a documented reason. `EXEC sp_configure 'min server memory (MB)', 0; RECONFIGURE;`

### B8 — Lock Pages in Memory Active

- **Trigger:** `sys.dm_os_sys_info.sql_memory_model_desc = 'LOCK_PAGES'` (applies SQL Server 2012 SP4 / 2016 SP1+)
- **Severity:** Info
- **Fix:** LPIM prevents the OS from paging the buffer pool but can cause OS memory starvation on busy servers. Verify this is intentional and that Max Server Memory (B6) is correctly set. If LPIM is unintentional, remove the `SE_LOCK_MEMORY` privilege from the SQL Server service account and restart.

### B9 — AWE Enabled on 64-Bit Instance

- **Trigger:** `sp_configure 'awe enabled' config_value = 1`
- **Severity:** Warning
- **Fix:** The `awe enabled` **configuration option** is a SQL Server 2005/2008-era, 32-bit-only switch for addressing memory above 4 GB via Address Windowing Extensions; on 64-bit instances the *option* is ignored (no effect), and it was removed entirely in SQL Server 2012 (11.x) — the option is absent from the `sp_configure` list in all later versions. So `config_value = 1` means the instance is SQL Server 2008 R2 or earlier — set it off and, more importantly, plan to upgrade off an out-of-support version: `EXEC sp_configure 'awe enabled', 0; RECONFIGURE;`. Note: do not confuse this option with the AWE **API**, which *is* still used by 64-bit SQL Server as the "locked pages" mechanism when Lock Pages in Memory is granted (see B8) — this check targets only the obsolete config switch.

### B10 — Auto-Shrink Enabled

- **Trigger:** `sys.databases.is_auto_shrink_on = 1` on any database
- **Severity:** Critical
- **Fix:** Auto-shrink causes severe index fragmentation, repeated file-growth events, and IO spikes. Disable immediately: `ALTER DATABASE [dbname] SET AUTO_SHRINK OFF;` Then reclaim space manually using `DBCC SHRINKFILE` only if disk space is critically low.

### B11 — Auto-Close Enabled

- **Trigger:** `sys.databases.is_auto_close_on = 1` on any database
- **Severity:** Critical
- **Fix:** Auto-close evicts database resources (buffer pool, plan cache, worker threads) after the last connection closes and re-initialises them on next connection — causing latency spikes. Disable: `ALTER DATABASE [dbname] SET AUTO_CLOSE OFF;`

### B12 — Compatibility Level Below SQL Server Version

- **Trigger:** `compatibility_level < (SERVERPROPERTY('ProductMajorVersion') * 10)` for any user database
- **Severity:** Warning
- **Fix:** Running an older compatibility level prevents the Query Optimizer from using newer cardinality estimator improvements, IQP features, and modern T-SQL syntax. Test workload at current level, then: `ALTER DATABASE [dbname] SET COMPATIBILITY_LEVEL = 160;` (for SQL 2022). Valid values: 80, 90, 100, 110, 120, 130, 140, 150, 160, 170 [Unverified — 170 pending future SQL Server release; SQL 2022 currently has level 160 as highest].

### B13 — RCSI Not Enabled

- **Trigger:** `sys.databases.is_read_committed_snapshot_on = 0` on user databases with READ_COMMITTED isolation level workloads
- **Severity:** Warning
- **Fix:** Without RCSI, READ COMMITTED readers block on writers and vice versa. Enable RCSI to eliminate most reader-writer blocking at the cost of tempdb version store space: `ALTER DATABASE [dbname] SET READ_COMMITTED_SNAPSHOT ON;` (requires brief exclusive access to the database).

### B14 — Page Verification Not CHECKSUM

- **Trigger:** `sys.databases.page_verify_option_desc ≠ 'CHECKSUM'` on any database
- **Severity:** Warning
- **Fix:** CHECKSUM page verification detects storage corruption before it causes data loss. NONE and TORN_PAGE_DETECTION provide weaker or no protection. `ALTER DATABASE [dbname] SET PAGE_VERIFY CHECKSUM;`

### B15 — Auto-Create Statistics Disabled

- **Trigger:** `sys.databases.is_auto_create_stats_on = 0`
- **Severity:** Warning
- **Fix:** Without auto-create statistics, the Query Optimizer may use poor cardinality estimates on unindexed columns. Re-enable unless a controlled manual statistics strategy is documented: `ALTER DATABASE [dbname] SET AUTO_CREATE_STATISTICS ON;`

### B16 — Auto-Update Statistics Disabled

- **Trigger:** `sys.databases.is_auto_update_stats_on = 0`
- **Severity:** Warning
- **Fix:** Stale statistics cause cardinality estimation errors that produce bad query plans. Re-enable: `ALTER DATABASE [dbname] SET AUTO_UPDATE_STATISTICS ON;` If disabled deliberately for large tables, implement a manual statistics update job.

### B17 — Trustworthy Enabled on User Database

- **Trigger:** `sys.databases.is_trustworthy_on = 1` on any database except `msdb` (where it is expected ON by SQL Server)
- **Severity:** Warning
- **Fix:** Trustworthy allows modules in the database to impersonate server-level principals if the database owner is a sysadmin. Disable unless Service Broker cross-database messaging or EXTERNAL_ACCESS assemblies require it: `ALTER DATABASE [dbname] SET TRUSTWORTHY OFF;`

### B18 — Cross-Database Ownership Chaining at Database Level

- **Trigger:** `sys.databases.is_db_chaining_on = 1` on user databases
- **Severity:** Warning
- **Fix:** Per-database chaining allows ownership chain traversal across databases when both have chaining enabled. Disable unless cross-database views or procedures explicitly require it: `ALTER DATABASE [dbname] SET DB_CHAINING OFF;`

### B19 — Excessive VLF Count

- **Trigger:** High VLF count per database (via `sys.dm_db_log_info` or `DBCC LOGINFO`). MS Learn's own `sys.dm_db_log_info` example flags **> 100** VLFs as worth investigating ("can affect database startup, restore, and recovery time"), and severe symptoms appear at "several hundred thousand." The 1,000 / 5,000 cutoffs below are **operational severity heuristics, not MS-documented thresholds** — treat > 100 as the documented review point.
- **Severity:** Info/Warning — VLF count > 100 (MS Learn review point) rising to Warning > 1000; Critical — VLF count > 5000 (heuristic)
- **Fix:** Excessive VLFs slow log backups, database recovery, and replication log reader. Shrink and regrow the log in one large step: (1) Take a log backup, (2) `DBCC SHRINKFILE (logfilename, 1)`, (3) Expand to the correct size in one operation using `ALTER DATABASE … MODIFY FILE (SIZE = target_mb MB, FILEGROWTH = 512 MB)`. A single growth of 8 GB creates 16 VLFs of 512 MB each.

### B20 — Log File Using Percent Auto-Growth

- **Trigger:** `sys.master_files: type = 1 AND is_percent_growth = 1 AND growth > 0`
- **Severity:** Warning
- **Fix:** Percent growth on log files produces increasingly large VLF bursts and unpredictable growth events. Switch to a fixed MB increment: `ALTER DATABASE [dbname] MODIFY FILE (NAME = logfilename, FILEGROWTH = 512MB);`

### B21 — Data File Using Percent Auto-Growth

- **Trigger:** `sys.master_files: type = 0 AND is_percent_growth = 1 AND growth > 0`
- **Severity:** Warning
- **Fix:** Percent growth on large data files causes enormous auto-grow events (e.g., 10% of a 1 TB file = 100 GB growth) that block sessions. Switch to a fixed MB increment: `ALTER DATABASE [dbname] MODIFY FILE (NAME = datafilename, FILEGROWTH = 1024MB);`

### B22 — Instant File Initialization Not Enabled

- **Trigger:** `sys.dm_server_services.instant_file_initialization_enabled = 'N'` for the SQL Server service (column is nvarchar(1): 'Y' = enabled, 'N' = disabled; applies SQL 2012 SP4, SQL 2014 SP3, SQL 2016 SP1+)
- **Severity:** Warning
- **Fix:** Without IFI, SQL Server must zero-initialise new data file space before use, causing multi-second or multi-minute stalls during auto-growth events and `RESTORE DATABASE`. Grant the SQL Server service account the `SE_MANAGE_VOLUME_NAME` Windows privilege ("Perform volume maintenance tasks" in Local Security Policy), then restart the SQL Server service. IFI applies to data files at any version; for **transaction log** files it historically did not apply (logs were always zeroed), but starting with SQL Server 2022 (16.x) — all editions, plus Azure SQL Database/MI — transaction log autogrowth events **up to 64 MB** also benefit from IFI (growth events larger than 64 MB still zero, and the 64 MB log benefit does not require the `SE_MANAGE_VOLUME_NAME` privilege). Verify after restart: `SELECT instant_file_initialization_enabled FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server (%';`

### B23 — TempDB File Count Below Recommended

- **Trigger:** Count of TempDB data files (`database_id = 2, type = 0` in `sys.master_files`) < `MIN(sys.dm_os_sys_info.scheduler_count, 8)`
- **Severity:** Warning
- **Fix:** Too few TempDB data files causes PFS/GAM/SGAM allocation page contention under concurrent load. Add files up to MIN(scheduler_count, 8), all equal in size and with equal fixed MB growth: `ALTER DATABASE tempdb ADD FILE (NAME = tempdev2, FILENAME = 'D:\tempdb\tempdev2.ndf', SIZE = 4096MB, FILEGROWTH = 512MB);` All TempDB files must be the same size to enable proportional fill.

### B24 — CLR Enabled

- **Trigger:** `sp_configure 'clr enabled' config_value = 1`
- **Severity:** Info
- **Fix:** CLR integration allows .NET assemblies to run inside SQL Server. If no CLR objects exist (`SELECT COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1` = 0), disable: `EXEC sp_configure 'clr enabled', 0; RECONFIGURE;`

### B25 — OLE Automation Procedures Enabled

- **Trigger:** `sp_configure 'Ole Automation Procedures' config_value = 1`
- **Severity:** Warning
- **Fix:** OLE Automation (`sp_OACreate`, `sp_OAMethod`) exposes COM objects to T-SQL and is a significant attack surface. Disable unless actively used: `EXEC sp_configure 'Ole Automation Procedures', 0; RECONFIGURE;`

### B26 — Ad Hoc Distributed Queries Enabled

- **Trigger:** `sp_configure 'Ad Hoc Distributed Queries' config_value = 1`
- **Severity:** Warning
- **Fix:** Ad Hoc Distributed Queries enables `OPENROWSET` and `OPENDATASOURCE` for arbitrary remote data access. Disable if not actively used: `EXEC sp_configure 'Ad Hoc Distributed Queries', 0; RECONFIGURE;` Use linked servers with controlled permissions instead.

### B27 — Instance-Level Cross-Database Ownership Chaining Enabled

- **Trigger:** `sp_configure 'cross db ownership chaining' config_value = 1`
- **Severity:** Warning
- **Fix:** Instance-level chaining enables ownership chain traversal across all databases on the server, including system databases. Disable and use per-database chaining only where required: `EXEC sp_configure 'cross db ownership chaining', 0; RECONFIGURE;`

### B28 — Remote Admin Connection Disabled

- **Trigger:** `sp_configure 'remote admin connections' config_value = 0`
- **Severity:** Info
- **Fix:** Without remote admin connections enabled, the Dedicated Administrator Connection (DAC) is only accessible from the server console. On named instances or clustered/containerised deployments, enable to allow remote DAC access for emergency diagnostics: `EXEC sp_configure 'remote admin connections', 1; RECONFIGURE;`

---

## Output Format

```
## SQL Server Configuration Review

### Summary
- X Critical, Y Warnings, Z Info
- Highest-risk finding: [check name and ID]
- Databases affected: [list]

### Critical Issues   ([C1], [C2], ...)
**[C1] Auto-Shrink Enabled (B10)**
- Observed: is_auto_shrink_on = 1 on databases: SalesDB, ReportDB
- Impact: Repeated shrink-and-grow cycles fragment indexes and cause IO spikes
- Fix: ALTER DATABASE [SalesDB] SET AUTO_SHRINK OFF;

### Warnings          ([W1], [W2], ...)
**[W1] Max Server Memory Not Configured (B6)**
- Observed: config_value = 0 (value_in_use = 2147483647 MB)
- Impact: SQL Server will consume all available RAM, causing OS paging
- Fix: EXEC sp_configure 'max server memory (MB)', 57344; RECONFIGURE;

### Info              ([I1], [I2], ...)

### Configuration Summary Table
| Category | Setting | Current | Recommended | Check |
|----------|---------|---------|-------------|-------|

### Passed Checks
(List check IDs that were explicitly verified clean)

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6"] · [current date and time in the user's local timezone, or UTC if timezone is unknown]*
```

---

## Companion Skills

| Skill | Relationship |
|-------|-------------|
| `sqlmemory-review` (O) | B6 Max Server Memory and B8 LPIM are root causes for O20 and O19 findings — run `/sqlmemory-review` to see the downstream memory pressure |
| `sqlwait-review` (V) | B19 excessive VLFs → V34 log write stalls; B23 TempDB files → V30–V32 TempDB contention waits |
| `sqldiskio-review` (Z) | B20/B21 percent auto-growth → Z7–Z9 auto-growth event stalls — run `/sqldiskio-review` to quantify the file growth impact |
| `sqlplan-review` (S/N) | B1–B3 MAXDOP misconfiguration → N44–N47 excessive parallelism in plans — cross-reference plan operators |
| `sqlmigration-review` (Y) | Dispatches configuration-drift findings here when comparing source/target instance settings (MAXDOP, compatibility level, TempDB layout) ahead of a migration |
| `mssql-performance-review` | Dispatches to this skill when artifact type is `dbconfig` |
