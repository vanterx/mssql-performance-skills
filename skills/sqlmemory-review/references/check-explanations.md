# sqlmemory-review — Checks Explained (O1–O20)

## Contents
- [Buffer Pool and PLE Checks (O1–O5)](#buffer-pool-and-ple-checks-o1o5)
- [Plan Cache Checks (O6–O10)](#plan-cache-checks-o6o10)
- [Memory Grant Checks (O11–O15)](#memory-grant-checks-o11o15)
- [Memory Clerks, OS Pressure, and Configuration (O16–O20)](#memory-clerks-os-pressure-and-configuration-o16o20)
- [Quick Reference](#quick-reference)

---

## Buffer Pool and PLE Checks (O1–O5)

### O1 — Low Page Life Expectancy

**What it means:** Page Life Expectancy (PLE) measures how long a data page stays in the buffer pool before being evicted. Microsoft does not publish a fixed healthy value — per MS Learn, "a higher, growing value is best; a sudden dip indicates a significant churn." The old "300 seconds" rule is only meaningful on a ~4 GB pool; scale it as `(buffer pool GB / 4) × 300` (so ~9,600 s on 128 GB). When PLE falls below that scaled floor, or dips sharply, the buffer pool is recycling pages faster than the working set needs and queries read from disk more often, causing PAGEIOLATCH waits.

**How to spot it:**
```sql
SELECT object_name, counter_name, instance_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Buffer Manager%'
  AND counter_name = 'Page life expectancy';
```
A value below the scaled floor `(GB/4)×300` triggers Warning; below ~25% of the floor (or < 60 s on a small server) triggers Critical. Compare against the buffer pool size (`Buffer Manager : Database pages` × 8 KB) and against O2's trend, not a flat number.

**Example:**
```
object_name                       counter_name             cntr_value
--------------------------------- ------------------------ ----------
SQLServer:Buffer Manager          Page life expectancy     47
```
PLE of 47 is Critical — the server is unable to keep a working set in memory.

**Fix options (ranked by impact):**
1. **Add RAM** — the most direct fix. SQL Server's buffer pool is bounded by available physical memory and Max Server Memory.
2. **Set Max Server Memory** (see O20) — if it is not set, SQL Server may be competing with other processes.
3. **Identify and eliminate full table scans** — use `/sqltrace-review` to find large-read workloads flushing the cache.
4. **Partition workloads** — separate OLTP and reporting onto different instances or use Resource Governor to cap reporting memory.

**Related checks:** O2 (trend), O3 (NUMA imbalance), O4 (DB concentration), O20 (Max Server Memory)

---

### O2 — PLE Declining Trend

**What it means:** A sustained monotonic decline in PLE signals memory pressure is accumulating — not a one-time spike but a pattern. The rate of decline predicts how soon PLE will hit the critical threshold.

**How to spot it:** Capture PLE at 5-minute intervals and track the trend. A decline of 10+ seconds per minute means PLE will hit critical within minutes.

**Example:**
```
Time       PLE
09:00      2400
09:05      2180
09:10      1920
09:15      1680
```
Rate: ~240 s lost per 5 minutes = 48 s/min decline → Critical.

**Fix options:**
1. **Correlate decline onset with batch execution** — check `/sqltrace-review` for queries that started around the time PLE began dropping.
2. **Review for new queries with large scan footprints** added recently (deployments, schema changes).
3. **Check if DBCC CHECKDB or an index REBUILD** job is running — these flush the buffer pool with large sequential reads.

**Related checks:** O1, O4, O16, O17

---

### O3 — NUMA Node PLE Imbalance

**What it means:** On multi-socket servers with NUMA architecture, each NUMA node has its own memory pool. If one node's PLE is significantly lower than another's, queries scheduled on that node's CPUs are hitting cache misses disproportionately.

**How to spot it:**
```sql
SELECT object_name, counter_name, instance_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Buffer Node%'
  AND counter_name = 'Page life expectancy';
```
Compare `cntr_value` across all nodes.

**Example:**
```
instance_name    cntr_value
Node 000         8400
Node 001         1200
```
Node 001 is at 14% of Node 000's PLE — Critical imbalance.

**Fix options:**
1. **Check BIOS/hardware memory population** — unequal DIMM population across sockets causes one node to have less memory.
2. **Review NUMA configuration** in `sys.dm_os_nodes` — verify memory_node_id assignments.
3. **Use soft-NUMA** to rebalance scheduler-to-memory-node mappings.

**Related checks:** O1, O4

---

### O4 — Buffer Pool Dominated by Single Database

**What it means:** When one database holds 60–80%+ of the buffer pool, it evicts other databases' pages. This is often benign (it IS the primary workload), but it becomes a problem when reports, ETL, or dev databases crowd out production.

**How to spot it:**
```sql
SELECT
    DB_NAME(database_id) AS db,
    COUNT(*) * 8 / 1024 AS buffer_mb,
    100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS pct
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY buffer_mb DESC;
```

**Example:**
```
db               buffer_mb    pct
ReportingDB      45312        72.4
ProductionDB     12288        19.6
tempdb           3840         6.1
```
ReportingDB dominates despite not being the primary OLTP database — a workload separation issue.

**Fix options:**
1. **Schedule reports off-peak** to stop the eviction pattern during production hours.
2. **Use Resource Governor** to cap the memory available to the reporting workload.
3. **Separate OLTP and reporting** onto dedicated instances.

**Related checks:** O1, O11

---

### O5 — Stolen Memory Excessive

**What it means:** Memory "stolen" from the buffer pool covers all SQL Server memory usage outside the buffer pool itself: plan cache, lock structures, CLR, linked servers, ColumnStore pools, and XTP. When stolen memory grows beyond 15–30% of target, the buffer pool shrinks.

**How to spot it:**
```sql
SELECT type, SUM(pages_kb) / 1024 AS total_mb
FROM sys.dm_os_memory_clerks
WHERE type NOT LIKE 'MEMORYCLERK_SQLBUFFERPOOL'
GROUP BY type
ORDER BY total_mb DESC;
```

**Fix options:**
1. **Identify the largest non-buffer clerk** — see O9 (locks), O16 (ColumnStore), O17 (XTP).
2. **Review linked servers** — linked server connections and OLE DB providers allocate outside the buffer pool.
3. **Review CLR assemblies** — CLR memory is not bounded by Max Server Memory on older SQL versions.

**Related checks:** O9, O16, O17, O18

---

## Plan Cache Checks (O6–O10)

### O6 — Single-Use Plan Cache Bloat

**What it means:** An ad-hoc query that runs once generates a full compiled plan stored in cache. If thousands of unique ad-hoc queries run per hour (e.g., ORM-generated SQL with literal values), the plan cache fills with plans that will never be reused, consuming hundreds of MB of stolen memory.

**How to spot it:**
```sql
SELECT
    SUM(CASE WHEN usecounts = 1 THEN size_in_bytes ELSE 0 END) / 1048576 AS single_use_mb,
    SUM(size_in_bytes) / 1048576                                           AS total_plan_cache_mb,
    100.0 * SUM(CASE WHEN usecounts = 1 THEN size_in_bytes ELSE 0 END)
           / NULLIF(SUM(size_in_bytes), 0)                                AS single_use_pct
FROM sys.dm_exec_cached_plans
WHERE objtype IN ('Adhoc', 'Prepared');
```

**Example:**
```
single_use_mb    total_plan_cache_mb    single_use_pct
2840             3200                   88.75
```
88.75% of plan cache is single-use waste — Critical.

**Fix options:**
1. **Enable `optimize for ad hoc workloads`**: `sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;` — stores only a stub on first execution, full plan on second.
2. **Parameterize application queries** — use `sp_executesql` with `@params`.
3. **Enable Forced Parameterization** on the database as a last resort: `ALTER DATABASE [name] SET PARAMETERIZATION FORCED` — but verify this does not break queries that rely on literal-specific plans.

**Related checks:** O7, O10

---

### O7 — High Plan Cache Compilation Rate

**What it means:** Frequent compilations burn CPU and generate plan cache churn. High recompile rates often indicate dynamic SQL, `WITH RECOMPILE` hints on hot procedures, or DDL/statistics changes forcing recompiles.

**How to spot it:**
```sql
SELECT counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%SQL Statistics%'
  AND counter_name IN ('SQL Compilations/sec', 'SQL Re-Compilations/sec');
```

**Fix options:**
1. **Identify the recompiling object** — use an XE session tracing `sql_statement_recompile` events.
2. **Remove `WITH RECOMPILE`** from hot procedures where parameter sniffing is not the actual problem.
3. **Avoid `SET` option changes per connection** — ARITHABORT, ANSI_NULLS, etc. changes invalidate cached plans.

**Related checks:** O6, O8

---

### O8 — Large Individual Plan in Cache

**What it means:** A plan exceeding 10 MB represents a query that generates an enormous execution tree — typically a dynamically-built query with dozens of tables, many OR predicates, or a stored procedure with hundreds of conditional branches.

**How to spot it:**
```sql
SELECT TOP 5
    size_in_bytes / 1048576         AS plan_mb,
    usecounts,
    objtype,
    st.text
FROM sys.dm_exec_cached_plans
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS st
WHERE size_in_bytes > 10485760
ORDER BY size_in_bytes DESC;
```

**Fix options:**
1. **Rewrite OR-heavy predicates** as UNION ALL to give the optimizer separate, smaller plan branches.
2. **Break stored procedures** with dynamic WHERE clause construction into smaller targeted procedures.
3. **Add selective indexes** to reduce the number of join alternatives the optimizer must consider.

**Related checks:** O7

---

### O9 — Lock Memory Excessive

**What it means:** SQL Server's lock manager allocates a structure per lock held (row, page, object, database). Heavy transactional workloads or long-running transactions holding many locks inflate the OBJECTSTORE_LOCK_MANAGER clerk.

**How to spot it:**
```sql
SELECT pages_kb / 1024 AS lock_memory_mb
FROM sys.dm_os_memory_clerks
WHERE type = 'OBJECTSTORE_LOCK_MANAGER';
```

**Fix options:**
1. **Identify long-running transactions**: `SELECT * FROM sys.dm_tran_active_transactions WHERE transaction_begin_time < DATEADD(MINUTE,-5,GETDATE());`
2. **Review lock escalation settings** — if lock escalation is disabled on a table (`ALTER TABLE ... SET (LOCK_ESCALATION = DISABLE)`), row-level locks accumulate instead of escalating to table locks.
3. **Use RCSI (Read Committed Snapshot Isolation)** to eliminate reader-writer lock contention.

**Related checks:** O5, O11

---

### O10 — Plan Cache Hit Rate

**What it means:** Plan cache churn wastes CPU on recompiles instead of reusing cached plans. Diagnose it from O6 (single-use plan bloat) and O7 (compiles/sec) — **not** from a 90% threshold on the `Plan Cache : Cache Hit Ratio` counter. Per MS Learn the documented "90 or higher is desirable" applies to the **Buffer Cache Hit Ratio** (Buffer Manager object); Plan Cache Hit Ratio is just "the ratio between cache hits and lookups for plans," has no documented healthy floor, and frequently reads near 100% even when ad-hoc bloat is severe. Use it only as a soft corroborating signal.

**Fix options:**
1. **Enable `optimize for ad hoc workloads`** (see O6).
2. **Review application parameterization** — ORM frameworks often generate unique query text per literal value.
3. **Check DBCC FREEPROCCACHE** usage** — a DBA manually flushing the plan cache will drop the hit rate.

**Related checks:** O6, O7

---

## Memory Grant Checks (O11–O15)

### O11 — Memory Grant Queue Depth

**What it means:** Before a query can execute sort, hash join, or hash aggregate operations, SQL Server must grant it a memory reservation. If granted memory is insufficient, the query queues. A non-zero queue means memory grants are becoming a throughput bottleneck.

**How to spot it:**
```sql
SELECT COUNT(*) AS queued_grants
FROM sys.dm_exec_query_memory_grants
WHERE grant_time IS NULL;
```

**Example:**
```
queued_grants
12
```
12 sessions queuing for memory grants — Critical.

**Fix options:**
1. **Add RAM** and increase Max Server Memory (O20).
2. **Reduce max degree of parallelism** — parallel queries request more grant memory. `OPTION (MAXDOP 1)` on the offending query as emergency mitigation.
3. **Add indexes** to eliminate hash operations in the most grant-heavy queries (run `/sqlindex-advisor`).
4. **Use `OPTION (MAX_GRANT_PERCENT = 10)`** as a per-query cap.

**Related checks:** O12, O13, O20

---

### O12 — Memory Grant Timeout

**What it means:** A query waited longer than its timeout for a memory grant and failed with error 8645 ("A timeout occurred while waiting for memory resources to execute the query"). This is the most severe memory grant condition — queries are not completing.

**Fix options (all urgent):**
1. **Kill the sessions holding the largest grants** using `KILL <session_id>`.
2. **Run `/sqlplan-review`** on the failing query — look for N21 (cardinality mismatch) which causes oversized grant requests.
3. **Update statistics** on the tables in the failing query with `UPDATE STATISTICS ... WITH FULLSCAN`.
4. **Set `OPTION (MIN_GRANT_PERCENT = 1)`** on the query to let it start with a minimal grant and spill to TempDB rather than timeout.

**Related checks:** O11, O13

---

### O13 — Oversized Memory Grant

**What it means:** A query received a large grant but used only a fraction of it. The unused portion is still reserved and unavailable to other queries, contributing to grant queuing (O11).

**How to spot it:**
```sql
SELECT session_id, granted_memory_kb, used_memory_kb, max_used_memory_kb,
       100.0 * max_used_memory_kb / NULLIF(granted_memory_kb, 0) AS used_pct
FROM sys.dm_exec_query_memory_grants
WHERE grant_time IS NOT NULL
ORDER BY granted_memory_kb DESC;
```

**Fix options:**
1. **Update statistics** on join input tables — overestimated row counts cause oversized grants.
2. **Add `OPTION (MAX_GRANT_PERCENT = 25)`** to cap the grant for specific queries.
3. **Review for implicit conversions** — type mismatches in join predicates inflate row count estimates.

**Related checks:** O11, O12

---

### O14 — Resource Governor Memory Pool Imbalance

**What it means:** Resource Governor allows defining memory limits per workload group. When pools are unconfigured (all at default 0–100%), the governor provides no protection against runaway queries or reporting workloads crowding out OLTP.

**Fix options:**
1. `ALTER RESOURCE POOL [OLTPPool] WITH (MIN_MEMORY_PERCENT = 30, MAX_MEMORY_PERCENT = 60);`
2. `ALTER RESOURCE POOL [ReportPool] WITH (MAX_MEMORY_PERCENT = 30);`
3. `ALTER RESOURCE GOVERNOR RECONFIGURE;`

**Related checks:** O11, O13

---

### O15 — Buffer Pool Extension Active

**What it means:** Buffer Pool Extension (BPE) extends the buffer pool onto an SSD-backed file. While it can improve read performance when RAM is insufficient, it is available in Enterprise and Standard editions only and adding physical RAM generally outperforms it. If it's active on a spinner, performance will be worse than without it.

**Fix options:**
1. **Verify the BPE file is on NVMe/fast SSD**: check `sys.dm_os_buffer_pool_extension_configuration`.
2. **Plan migration to more RAM** — BPE is a workaround for insufficient memory, not a long-term solution.
3. **Remove BPE** on SQL 2019+: `ALTER SERVER CONFIGURATION SET BUFFER POOL EXTENSION OFF;`

**Related checks:** O1, O20

---

## Memory Clerks, OS Pressure, and Configuration (O16–O20)

### O16 — ColumnStore Buffer Pool Pressure

**What it means:** ColumnStore operations (batch mode hash tables, delta store rowgroups, segment dictionaries) use dedicated memory pools. On servers with many ColumnStore indexes and active analytical queries, this clerk can consume 30–50% of all SQL Server memory.

**Fix options:**
1. **Drop ColumnStore indexes** on tables that are not benefiting from them.
2. **Schedule analytical queries** during off-peak hours.
3. **Use Resource Governor** to isolate analytical from OLTP workloads.

**Related checks:** O1, O5, O17

---

### O17 — In-Memory OLTP (XTP) Memory Pressure

**What it means:** In-Memory OLTP tables are allocated in a dedicated memory pool per database. Unlike the buffer pool, this memory is not shared and cannot be reclaimed by other SQL Server components. Unbounded XTP growth can starve the buffer pool.

**How to spot it:**
```sql
SELECT type, SUM(pages_kb) / 1024 AS mb
FROM sys.dm_os_memory_clerks
WHERE type LIKE 'XTP%'
GROUP BY type
ORDER BY mb DESC;
```

**Fix options:**
1. **Review `sys.dm_db_xtp_memory_consumers`** to identify which tables hold the most memory.
2. **Set a memory-optimized data FILEGROUP limit**: `ALTER DATABASE ... ADD FILE (NAME=..., SIZE=..., MAXSIZE=...)`.
3. **Review non-durable tables** — if rows accumulate without truncation, memory grows unboundedly.

**Related checks:** O5, O16

---

### O18 — OS Memory Pressure Notifications

**What it means:** Windows sends SQL Server a low-memory notification, which the Resource Monitor task records in the `RING_BUFFER_RESOURCE_MONITOR` ring buffer (`RESOURCE_MEMPHYSICAL_LOW` / `RESOURCE_MEMVIRTUAL_LOW`). SQL Server responds by shrinking the buffer pool, which can cause a PLE crash to near-zero within seconds.

**How to spot it:**
```sql
SELECT CAST(record AS XML).value('(/Record/ResourceMonitor/Notification)[1]', 'varchar(30)') AS notification,
       DATEADD(ms, -1 * (SELECT cpu_ticks / (cpu_ticks/ms_ticks) FROM sys.dm_os_sys_info) + timestamp, GETDATE()) AS event_time
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR';
```

**Fix options:**
1. **Reduce Max Server Memory** to leave 4–10% or minimum 4 GB for the OS.
2. **Identify other memory consumers** on the server (non-SQL processes, antivirus, backup agents).
3. **Enable Lock Pages in Memory** (O19) to prevent Windows from paging out the buffer pool.

**Related checks:** O1, O19, O20

---

### O19 — Lock Pages in Memory (LPIM) Misconfiguration

**What it means:** Without LPIM, Windows Virtual Memory Manager can swap SQL Server's buffer pool pages to the page file during OS memory pressure, even if the server has RAM available. This causes PAGEIOLATCH waits for pages that are physically on disk.

**Fix options:**
1. Grant the SQL Server service account the `Lock Pages in Memory` right in Local Security Policy (`secpol.msc` → Local Policies → User Rights Assignment).
2. Restart the SQL Server service — LPIM takes effect on restart.
3. Confirm activation: `SELECT sql_memory_model_desc FROM sys.dm_os_sys_info` should return `'LOCK_PAGES'`.

**Related checks:** O18, O20

---

### O20 — Max Server Memory Not Explicitly Set

**What it means:** The default value of 2,147,483,647 MB effectively means "unlimited." SQL Server will consume all available RAM on the server, leaving none for the OS scheduler, network stack, antivirus, backup agents, or other services. This can cause OS instability and SQL Server self-throttling from OS pressure notifications (O18).

**How to calculate the right value:**
```
Max Server Memory = Total RAM
                  − OS overhead (4 GB minimum, or 10% of RAM if larger)
                  − SSAS memory (if co-located)
                  − SSRS memory (if co-located)
                  − 1 GB per 4 GB RAM for non-buffer SQL components
```

**Example:** 256 GB server, SQL Server only:
```
256 GB − 25 GB (OS, 10%) − ~16 GB (non-buffer at 1/4 ratio) = ~215 GB
sp_configure 'max server memory (MB)', 220160; RECONFIGURE;
```

**Related checks:** O1, O18, O19

---

## Quick Reference

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| O1 | PLE | PLE < scaled floor `(GB/4)×300` or sudden dip | Warn; < 25% of floor (or < 60 s) = Critical |
| O2 | PLE | PLE declining ≥ 10 s/min | Warn; ≥ 60 s/min = Critical |
| O3 | NUMA | NUMA node PLE < 50% of max node | Warning |
| O4 | Buffer Pool | Single DB ≥ 60% of pool | Warn; ≥ 80% = Critical |
| O5 | Stolen Memory | Non-buffer clerks ≥ 15% of target | Warn; ≥ 30% = Critical |
| O6 | Plan Cache | Single-use plans ≥ 30% of cache | Warn; ≥ 60% = Critical |
| O7 | Plan Cache | Compilations/sec > 500 | Warn; > 1,000 = Critical |
| O8 | Plan Cache | Single plan > 10 MB | Warn; > 50 MB = Critical |
| O9 | Clerk | OBJECTSTORE_LOCK_MANAGER > 100 MB | Warn; > 500 MB = Critical |
| O10 | Plan Cache | Churn via O6/O7 (Plan Cache Hit Ratio is a soft signal, no MS 90% floor) | Warn on low reuse + high compiles/sec |
| O11 | Grants | Any session waiting for grant | Warn (1–5); Critical (> 5) |
| O12 | Grants | Grant timeout (error 8645) / error 701 | Critical |
| O13 | Grants | Used/granted ratio < 25% | Warning |
| O14 | Resource Gov | Pool max = 100% with RG enabled | Warning |
| O15 | BPE | BPE active | Info |
| O16 | Clerk | ColumnStore > 25% of target | Warn; > 50% = Critical |
| O17 | Clerk | XTP > 25% of target | Warn; > 50% = Critical |
| O18 | OS | RING_BUFFER_RESOURCE_MONITOR low-memory events < 24h | Warn / Critical |
| O19 | Config | LPIM off on > 32 GB server | Warning |
| O20 | Config | Max Server Memory = default | Critical |
