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

### sqlwait-review (V1–V44) — validated 2026-06-10

Claims checked: ~60 wait-type names and version gates, DMV columns (`sys.dm_os_wait_stats`, `sys.dm_exec_query_resource_semaphores`, `sys.dm_exec_query_memory_grants`), trace flags, IQP/feedback catalog views, full-text procedures, parallel redo architecture.

**Corrections (13):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| V3 (+refs) | CXCONSUMER "SQL 2016 SP2 CU3+" | SQL 2016 SP2 / SQL 2017 CU3+ | [sys.dm_os_wait_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql) |
| V9 | "set Mixed Extent Allocations = 0 (SQL 2016+)" | SQL 2016+ TempDB always uses uniform extents; user DBs use `MIXED_PAGE_ALLOCATION` | [ALTER DATABASE SET options] |
| V18 | log-rate governor waits gated "SQL 2019+" | `LOG_RATE_GOVERNOR`/`POOL_`/`INSTANCE_`/`IO_QUEUE_LIMIT`/`HADR_THROTTLE_LOG_RATE_GOVERNOR` are SQL 2016+, primarily Azure-observable; SE_REPL_* re-labelled Azure SQL DB [Unverified] | [sys.dm_os_wait_stats], [Azure SQL resource governance](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server) |
| V35 (+refs) | `sp_fulltext_service 'resource_usage', 1` to throttle crawl | `resource_usage` has no function in SQL 2008+; use `master_merge_dop` / off-peak scheduling | [sp_fulltext_service](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-fulltext-service-transact-sql) |
| V36 (+refs, +H-check in sqlhadr) | "PARALLEL_REDO_WORKER_POOL_SIZE" DBSC; "TF 3468 = extended parallel redo" | No such DBSC option; TF 3468 disables indirect checkpoints on tempdb. Parallel redo is automatic (≤100 threads instance-wide 2016–2019); TF 3459 disables it | [DBCC TRACEON trace flags](https://learn.microsoft.com/sql/t-sql/database-console-commands/dbcc-traceon-trace-flags-transact-sql), [Troubleshoot redo queuing](https://learn.microsoft.com/troubleshoot/sql/database-engine/availability-groups/troubleshooting-recovery-queuing-in-alwayson-availability-group) |
| V37 (+capture query) | `total_reduced_memory_grant_count` column | column does not exist in `sys.dm_exec_query_resource_semaphores`; use `forced_grant_count` growth | [sys.dm_exec_query_resource_semaphores](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-resource-semaphores-transact-sql) |
| V38 | "ID 0 = regular (small) query pool, ID 1 = large query pool" | 0 = regular semaphore, 1 = small-query semaphore (< 5 MB grant, cost < 3) | same |
| V41 (+refs, version matrix) | `feedback_type = 'PSP'` in sys.query_store_plan_feedback | PSP variants live in `sys.query_store_query_variant`; wait name `QUERY_OPTIMIZER_PSP_WAIT` marked [Unverified] | [sys.query_store_plan_feedback](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-plan-feedback) |
| V42 (+refs) | unqualified "DOP-type entries" | `feature_desc = 'DOP Feedback'`; `DISABLE_DOP_FEEDBACK` hint / `DOP_FEEDBACK` DBSC; wait name marked [Unverified] | same + [DOP feedback](https://learn.microsoft.com/sql/relational-databases/performance/intelligent-query-processing-degree-parallelism-feedback) |
| V43 (+refs, version matrix) | waits `PVSVERSIONSTORE_WAIT` / `ADR_CLEANUP_WAIT` | documented wait is `PVS_CLEANUP_LOCK`; added `sys.sp_persistent_version_cleanup` + `ADR Cleaner Thread Count` (SQL 2022+) | [Monitor and troubleshoot ADR](https://learn.microsoft.com/sql/relational-databases/accelerated-database-recovery-troubleshoot) |
| V5 | "SQL 2012+ increased max outstanding log writes from 32 to 112" | marked [Unverified] (not found in MS Learn) | — |

Validated clean: PAGEIOLATCH/LCK_M/CXPACKET/CXSYNC/THREADPOOL/WRITELOG/LOGBUFFER/LOGMGR_RESERVE_APPEND/SOS_SCHEDULER_YIELD/HADR_SYNC_COMMIT wait definitions, OPTIMIZE_FOR_SEQUENTIAL_KEY (2019+), Delayed Durability (2014+), Query Store DATA_FLUSH_INTERVAL_SECONDS default 900, MEMORY_OPTIMIZED TEMPDB_METADATA (2019+), MIN/MAX_GRANT_PERCENT (2012 SP3+), TempDB file guidance, sp_configure option names.

### sqlquerystore-review, sqlprocstats-review

_Pending._

## Batch 3 — sqlplan-review, sqlencryption-review

_Pending._

## Batch 4 — tsql-review, sqlplan-compare, sqlindex-advisor, sqlstats-review

_Pending._

## Batch 5 — sqlhadr-review, sqlclusterlog-review, sqlerrorlog-review, sqlspn-review, sqldeadlock-review, sqltrace-review

_Pending._

## Batch 6 — mssql-performance-review, sqlplan-batch, VERSION_COMPATIBILITY.md

_Pending._
