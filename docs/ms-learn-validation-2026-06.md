# Microsoft Learn Validation Report — June 2026

Repo-wide validation of all 20 skills (697 checks) against current Microsoft Learn
documentation, per the mandatory policy in `.claude/docs/ms-learn-validation.md`.
Plan and progress tracker: `docs/backlog/ms-learn-validation-plan.md`.

Method: for each skill, every Microsoft-attributable factual claim in `SKILL.md` and
`references/check-explanations.md` was extracted and verified against pages fetched
from learn.microsoft.com via the Microsoft Learn MCP tools (`microsoft_docs_search`,
`microsoft_docs_fetch`). Inaccuracies were corrected inline; claims that could not be
confirmed in official documentation were marked `[Unverified]`. The repo's own
heuristic thresholds were not treated as Microsoft claims.

Claim categories verified per skill:

1. DMV / catalog view names and column names
2. Wait type names
3. `sp_configure` option names and default values
4. Trace flags and version applicability
5. Version / compatibility-level gates
6. Error numbers and message text
7. T-SQL syntax in capture queries and fix recipes
8. Deprecated-feature claims

---

## Batch 1 — sqldbconfig-review, sqlmemory-review, sqldiskio-review

Validated 2026-06-10.

### sqldbconfig-review (B1–B28)

Claims checked: ~12 DMV/catalog-view column groups, 5 sp_configure defaults, 4 version gates, Microsoft MAXDOP/TempDB sizing guidance, error numbers 9017/8649/824, compat levels 80–170.

**Corrections (1):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| B8 + capture query | `sql_memory_model_desc` "SQL Server 2012 SP4+" | "SQL Server 2012 SP4 / 2016 SP1+" (SQL 2016 RTM lacks the column) | [sys.dm_os_sys_info](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-sys-info-transact-sql) |

Validated clean: MAXDOP per-NUMA guidance, cost threshold default 5, Max Server Memory default 2147483647, TempDB files = MIN(logical processors, 8), error 9017 VLF thresholds, `instant_file_initialization_enabled` (2012 SP4 / 2016 SP1+), `sys.dm_db_log_info`/`sys.dm_db_log_stats` (2016 SP2+), all `sys.databases`/`sys.master_files`/`sys.configurations` columns, all ALTER DATABASE/sp_configure fix syntax. No [Unverified] markers needed.

### sqlmemory-review (O1–O20)

Claims checked: memory clerk type names, perf counter object/counter names, ring buffer types, BPE state values and lifecycle, memory grant DMV columns and timeout semantics, error numbers, XTP memory governance, LPIM, Max Server Memory default.

**Corrections (9):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| O9 (+refs, example) | "`LOCK` clerk" | `OBJECTSTORE_LOCK_MANAGER` | [sys.dm_os_memory_clerks](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-memory-clerks-transact-sql) |
| O10 | "Cache Hit Ratio from `Exec Statistics`" | "Cache Hit Ratio from the `Plan Cache` performance object" | [SQL Server, Plan Cache object](https://learn.microsoft.com/sql/relational-databases/performance-monitor/sql-server-plan-cache-object) |
| O12 (+refs) | timeout indicated by `timeout_sec` / error 701 only | timeout raises error 8645; `timeout_sec` is the configured time-out, not an occurrence flag; 701 = insufficient system memory | [MSSQLSERVER_8645](https://learn.microsoft.com/sql/relational-databases/errors-events/mssqlserver-8645-database-engine-error), [sys.dm_exec_query_memory_grants](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-memory-grants-transact-sql) |
| O15 trigger | `state = 2` (Enabled) | `state = 5` (BUFFER POOL EXTENSION ENABLED); 2 is reserved | [sys.dm_os_buffer_pool_extension_configuration](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-buffer-pool-extension-configuration-transact-sql) |
| O15 fix (+refs, version tables) | "BPE deprecated in SQL 2019 and removed in SQL 2022" | BPE is not deprecated or removed — current docs fully document it; Enterprise/Standard editions only | [Buffer pool extension](https://learn.microsoft.com/sql/database-engine/configure-windows/buffer-pool-extension), [Editions and supported features of SQL Server 2022](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022) |
| O16 (+example, evals) | clerk `COLUMNSTORE_OBJECT_POOL`; "delta store rowgroup memory, batch mode hash tables" | clerk `CACHESTORE_COLUMNSTOREOBJECTPOOL`; caches column segments and dictionaries | [sys.dm_os_memory_clerks](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-memory-clerks-transact-sql) |
| O17 trigger | clerks "XTP_DEFAULT, XTP_PROCEDURE_CACHE, XDES, XTP_TRANSACTION_CONTEXT" | clerk `MEMORYCLERK_XTP` | same page |
| O17 fix | "fixed memory allocation per database (`MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT OFF`)" | XTP memory unbounded by default; bind to Resource Governor pool via `sp_xtp_bind_db_resource_pool` | [Bind a database with memory-optimized tables to a resource pool](https://learn.microsoft.com/sql/relational-databases/in-memory-oltp/bind-a-database-with-memory-optimized-tables-to-a-resource-pool) |
| O18 (+input list, refs) | `RING_BUFFER_OOM` with `PROCESS_PHYSICAL_MEMORY_HIGH`/`VIRTUAL_MEMORY_HIGH` | `RING_BUFFER_RESOURCE_MONITOR` with `RESOURCE_MEMPHYSICAL_LOW`/`RESOURCE_MEMVIRTUAL_LOW` | [Memory management architecture guide](https://learn.microsoft.com/sql/relational-databases/memory-management-architecture-guide) |

Ripple fixes: `skills/VERSION_COMPATIBILITY.md` sqlmemory note + matrix row (2022 now ✓) and Quick Reference (removed "BPE removed in SQL 2022"). Validated clean: `sys.dm_os_memory_clerks`/`sys.dm_os_sys_memory`/`sys.dm_exec_query_memory_grants`/`sys.dm_exec_cached_plans` columns, `SQL Compilations/sec`/`SQL Re-Compilations/sec` (SQL Statistics object), Page life expectancy (Buffer Manager/Buffer Node), error 701 text, LPIM via "Lock pages in memory" right, `sql_memory_model_desc` values, `MIN_GRANT_PERCENT`/`MAX_GRANT_PERCENT` hints.

### sqldiskio-review (Z1–Z15)

Claims checked: `sys.dm_io_virtual_file_stats` signature and columns, `sys.master_files` growth semantics (8-KB pages, 64-KB rounding), default trace event classes 92/93, IFI privilege and log-growth behavior, errors 1105/1121, TempDB file guidance, proportional fill.

**Corrections (4):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| Capture query 3 + Z11 refs | `Duration / 1000 AS duration_ms`; "Duration is in microseconds" | `Duration` is reported in **milliseconds** for event classes 92/93 (unlike most trace events) | [Data File Auto Grow Event Class](https://learn.microsoft.com/sql/relational-databases/event-classes/data-file-auto-grow-event-class), [Log File Auto Grow Event Class](https://learn.microsoft.com/sql/relational-databases/event-classes/log-file-auto-grow-event-class) |
| Z5 (+thresholds, refs, example) | `stall_pct = 100.0 * io_stall / (io_stall_read_ms + io_stall_write_ms + 1)` — degenerate (≈100% always, since io_stall is the sum of read+write stall) | `avg_stall_per_io_ms = io_stall / (num_of_reads + num_of_writes)`, thresholds 5/15 ms | [sys.dm_io_virtual_file_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-io-virtual-file-stats-transact-sql) |
| Z11/Z13 refs | "log files always zero-initialize" | SQL Server 2022+ log autogrowth events ≤ 64 MB can use IFI | [Database instant file initialization](https://learn.microsoft.com/sql/relational-databases/databases/database-instant-file-initialization) |
| Z9 (+refs) | TempDB sizes from `sys.master_files` | added: `sys.master_files` shows TempDB startup size only; use `tempdb.sys.database_files` for current | [sys.master_files](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-master-files-transact-sql) |

Validated clean: DMV signature `(database_id|NULL, file_id|NULL)`, all columns, `growth` in 8-KB pages rounded to 64 KB, `IntegerData` = pages grown, EventClass 92/93 IDs, errors 1105/1121, "Perform volume maintenance tasks"/SE_MANAGE_VOLUME_NAME, TempDB one-file-per-logical-CPU-up-to-8, autogrow-as-contingency guidance. No [Unverified] markers needed.

## Batch 2 — sqlwait-review, sqlquerystore-review, sqlprocstats-review

_Pending._

## Batch 3 — sqlplan-review, sqlencryption-review

_Pending._

## Batch 4 — tsql-review, sqlplan-compare, sqlindex-advisor, sqlstats-review

_Pending._

## Batch 5 — sqlhadr-review, sqlclusterlog-review, sqlerrorlog-review, sqlspn-review, sqldeadlock-review, sqltrace-review

_Pending._

## Batch 6 — mssql-performance-review, sqlplan-batch, VERSION_COMPATIBILITY.md

_Pending._
