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

### sqlquerystore-review (Q1–Q32) — validated 2026-06-10

Claims checked: Query Store DMV columns and units (runtime stats in microseconds, memory/tempdb in 8-KB pages), `execution_type` values, plan forcing procedures, IQP feedback catalog views and hints, PSP plan types, QS-for-secondaries availability, automatic tuning options.

**Corrections (5):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| Q26 (+refs) | `plan_type_desc IN ('Dispatcher', 'Custom')` | `('Dispatcher Plan', 'Query Variant Plan')` | [sys.query_store_plan](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-plan-transact-sql) |
| Q26–Q29 (+refs) | `sp_query_store_set_hints @query_id = N'<id>'` | `@query_id = <id>` (parameter is bigint) | [sys.sp_query_store_set_hints] |
| Q29 (+refs) | disable MGF via `DISABLE_BATCH_MODE_ADAPTIVE_JOINS`/`DISABLE_INTERLEAVED_EXECUTION_TVF` | `DISABLE_BATCH_MODE_MEMORY_GRANT_FEEDBACK`/`DISABLE_ROW_MODE_MEMORY_GRANT_FEEDBACK` | [Memory grant feedback](https://learn.microsoft.com/sql/relational-databases/performance/intelligent-query-processing-memory-grant-feedback) |
| Q30 (+refs) | `SET QUERY_STORE = ON (READ_WRITE_DATABASES_ONLY = OFF)` | `SET QUERY_STORE FOR SECONDARY = ON` (SQL 2025+/Azure SQL DB; SQL 2022 = TF 12606 preview only) | [Query Store for readable secondaries](https://learn.microsoft.com/sql/relational-databases/performance/query-store-for-secondary-replicas) |
| refs Q30 | "Requires SQL Server 2022+ and compat 160" | GA in SQL 2025/Azure SQL DB; 2022 is unsupported preview | same |

Validated clean: execution_type 0/3/4 semantics, `avg_query_max_used_memory`/`avg_tempdb_space_used` in 8-KB pages, `avg_tempdb_space_used` absent on SQL 2016, wait stats SQL 2017+, `feature_desc` values (CE/Memory Grant/DOP/LAQ Feedback), `DISABLE_CE_FEEDBACK`/`DISABLE_DOP_FEEDBACK` hints, `PARAMETER_SENSITIVE_PLAN_OPTIMIZATION` DBSC, `sys.query_store_query_hints` columns, `sys.dm_db_tuning_recommendations`/`AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON)` (2017+), sp_query_store_* procedure names.

### sqlprocstats-review (R1–R25) — validated 2026-06-10

Claims checked: `sys.dm_exec_procedure_stats`/`sys.dm_exec_query_stats`/`sys.dm_exec_trigger_stats` columns, natively compiled proc identification and stats collection, CLR time exposure, Query Store cross-references.

**Corrections (3):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| R21 (+refs) | identify native procs via "EXECUTE AS + memory-optimized filegroup"; "SCHEMA_AND_DATA binding" | `sys.sql_modules.uses_native_compilation = 1`; stats require `sys.sp_xtp_control_proc_exec_stats`; tables' `DURABILITY = SCHEMA_AND_DATA`; STATISTICS IO reports 0 for memory-optimized tables | [Monitoring natively compiled procs](https://learn.microsoft.com/sql/relational-databases/in-memory-oltp/monitoring-performance-of-natively-compiled-stored-procedures) |
| R22 (+refs) | `total_clr_time_ms` from proc stats | CLR time is not in `sys.dm_exec_procedure_stats`; use `type = 'PC'` and statement-level `sys.dm_exec_query_stats.total_clr_time` (µs) | [sys.dm_exec_procedure_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-procedure-stats-transact-sql), [sys.dm_exec_query_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-stats-transact-sql) |

Validated clean: all delta/avg column derivations (worker/elapsed time in microseconds), `total_spills` (SQL 2017 CU3+ / 2016 SP2+), trigger/function stats DMVs, plan_handle semantics, sp_recompile, sp_query_store_force_plan.

## Batch 3 — sqlplan-review, sqlencryption-review

### sqlplan-review (S1–S36, N1–N72) — validated 2026-06-10

Claims checked: showplan XML elements/attributes across all 108 checks, USE HINT names, IQP feature gates, columnstore runtime counters, statistics metadata.

**Corrections (12):**

| Check | Before | After | Source |
|-------|--------|-------|--------|
| S10 (+refs) | fix via `ENABLE_QUERY_OPTIMIZER_HOTFIXES` | that hint = TF 4199 (QO hotfixes); correct hints are `FORCE_DEFAULT_CARDINALITY_ESTIMATION` / `QUERY_OPTIMIZER_COMPATIBILITY_LEVEL_n` (2017 CU10+) | [Query hints USE HINT list](https://learn.microsoft.com/sql/t-sql/queries/hints-transact-sql-query), [Cardinality Estimation](https://learn.microsoft.com/sql/relational-databases/performance/cardinality-estimation-sql-server) |
| S25 | `ContainsInterleavedExecutionCandidates` on StmtSimple | attribute is on the `QueryPlan` node; `IsInterleavedExecuted` on `RuntimeInformation` | [IQP details](https://learn.microsoft.com/sql/relational-databases/performance/intelligent-query-processing-details) |
| S34 (+refs) | `StatementType="ParameterSensitivity"` | `<Dispatcher>` element (documented PSP showplan element) | [PSP optimization](https://learn.microsoft.com/sql/relational-databases/performance/parameter-sensitive-plan-optimization) |
| N13 | "SQL 2019+ compat 150 interleaved execution" | SQL 2017+ compat 140+ | [IQP details] |
| N47 | window frame attributes `FrameType`/`StartBound`/`EndBound` | detect via Window Spool operator + `RANGE UNBOUNDED PRECEDING` in statement text | — |
| N49/N67 (+refs) | `SegmentsPurged`/`SegmentsTotal` | runtime counters are `SegmentReads`/`SegmentSkips` ("segment reads N, segment skipped M") | [Columnstore query performance](https://learn.microsoft.com/sql/relational-databases/indexes/columnstore-indexes-query-performance) |
| N69 (+refs) | `ApproxCountDistinctHll`/`InternalInfo` trigger; `DISABLE_APPROXIMATE_QUERY` hint | detect `APPROX_COUNT_DISTINCT` in defined values/statement text; no such USE HINT exists — fix is replacing the function | [USE HINT list] |
| N61 + thresholds (+refs) | `EstimatedAvgRowSize` attribute | showplan attribute is `AvgRowSize` (SSMS label "Estimated Row Size") | showplan references |
| N72 | `PERSIST_SAMPLE_PERCENT` "SQL 2016 SP1+" | SQL 2016 SP1 CU4+ | [UPDATE STATISTICS] |
| S22 (+refs) | `RowCountAssignment` attribute | marked [Unverified] (not in documented showplan references); also detect SET ROWCOUNT in batch text | — |
| S36 (+refs) | `ContainsCEFeedback` attribute | marked [Unverified]; reliable signal is `sys.query_store_plan_feedback` feature_desc = 'CE Feedback' | — |
| N70 (+refs) | `DegreeOfParallelismFeedback` element | marked [Unverified]; reliable signal is plan_feedback feature_desc = 'DOP Feedback' | — |

Validated clean: NonParallelPlanReason values, MemoryGrantInfo attributes (GrantedMemory/MaxUsedMemory/GrantWaitTime/RequestedMemory/SerialRequiredMemory), StatementOptmEarlyAbortReason values, PlanAffectingConvert ConvertIssue="Seek Plan"/"Cardinality", SpillToTempDb/SpillLevel, NoJoinPredicate, ColumnsWithNoStatistics, UnmatchedIndexes, EstimateRowsWithoutRowGoal, AdaptiveThresholdRows/IsAdaptive, RunTimeCountersPerThread (ActualElapsedms/ActualRows/ActualRowsRead), ParameterCompiledValue/ParameterRuntimeValue, `DISABLE_OPTIMIZER_ROWGOAL` (=TF 4138), `DISABLE_PARAMETER_SNIFFING` (=TF 4136), STRING_SPLIT 50-row estimate + enable_ordinal (2022+), MSTVF 100/1-row fixed estimates, StatisticsInfo/@SamplingPercent, batch mode on rowstore (2019+, BATCH_MODE_ON_ROWSTORE DBSC).

### sqlencryption-review (A1–A112) — spot-check validated 2026-06-10

This skill's entire current content shipped in a single commit that included a dedicated MS Learn accuracy audit (~25 corrections, recorded in `.claude/docs/ms-learn-validation.md`), and it has not changed since. This pass therefore performed a verification spot-check of high-risk claim classes instead of a full re-audit: TDE DEK algorithms and `encryption_state` semantics, CLE algorithm deprecation (SQL 2016+ compat-120 gate), RC4 deprecation behavior (error 33128), NIST SP 800-131A 3DES claims, TLS 1.3 (SQL 2022+ / Windows Server 2022+) gating.

**Corrections (2):**

| Location | Before | After | Source |
|----------|--------|-------|--------|
| Thresholds table | TDE DEK critical algorithms "TRIPLE_DES_3KEY / RC4" | RC4 is not a valid DEK algorithm (DEK supports AES_128/192/256/TRIPLE_DES_3KEY only) | [CREATE DATABASE ENCRYPTION KEY](https://learn.microsoft.com/sql/t-sql/statements/create-database-encryption-key-transact-sql) |
| A14 (+refs) | "DESX (56-bit key, brute-forceable)" | DESX is misnamed — keys created with ALGORITHM = DESX actually use Triple DES with a 192-bit key (deprecated) | [Choose an encryption algorithm](https://learn.microsoft.com/sql/relational-databases/security/encryption/choose-an-encryption-algorithm) |

Spot-checked clean: `sys.dm_database_encryption_keys.encryption_state` in-progress states (2/4/5/6) with `percent_complete`, SQL 2016+ deprecation of all non-AES algorithms (compat ≤ 120 required for legacy), RC4/RC4_128 encryption failures at compat 110+ (error 33128), TDE cert private key limited to 3072 bits.

## Batch 4 — tsql-review, sqlplan-compare, sqlindex-advisor, sqlstats-review

Validated 2026-06-10. Verified T-SQL feature/version gates (scalar UDF inlining 2019+/compat 150, IS [NOT] DISTINCT FROM 2022+, STRING_AGG 2017+, APPROX_COUNT_DISTINCT 2019+, old-style `*=` joins removed in 2012, Ledger 2022+), missing-index DMV names/columns, STATISTICS IO output tokens (lob/segment/page server reads), plan-compare version gates (adaptive join 2017+, BMoR 2019+, PSP 2022+).

**Corrections (5):**

| Skill/Check | Before | After | Source |
|-------------|--------|-------|--------|
| tsql T81 (+refs) | JSON_OBJECT/JSON_ARRAY "compat level 160 only" | gated by the SQL Server 2022 engine, not compat level (unlike OPENJSON's compat-130 gate) | [JSON_OBJECT](https://learn.microsoft.com/sql/t-sql/functions/json-object-transact-sql), [JSON data](https://learn.microsoft.com/sql/relational-databases/json/json-data-sql-server) |
| tsql T83 | `TRIM(chars FROM col)` "SQL 2022+" | SQL 2017+; only LEADING/TRAILING/BOTH need 2022 + compat 160 | [TRIM](https://learn.microsoft.com/sql/t-sql/functions/trim-transact-sql) |
| sqlindex-advisor (DDL template + guidance, 3 spots) | "SQL 2019+ Standard supports online rebuild"; "RESUMABLE SQL 2017+" for CREATE INDEX | online index create/rebuild is Enterprise-only in every version through SQL 2022; resumable CREATE INDEX is 2019+ (rebuild 2017+), both require ONLINE | [Editions and supported features of SQL Server 2019/2022](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022), [CREATE INDEX](https://learn.microsoft.com/sql/t-sql/statements/create-index-transact-sql) |

Validated clean: tsql-review deprecated-syntax claims, ANSI_NULLS/QUOTED_IDENTIFIER requirements for indexed views/filtered indexes, GETDATE/SYSDATETIME precision, sqlstats-review STATISTICS IO token formats, sqlindex-advisor missing-index DMV columns, sqlplan-compare C-check version gates.

## Batch 5 — sqlhadr-review, sqlclusterlog-review, sqlerrorlog-review, sqlspn-review, sqldeadlock-review, sqltrace-review

_Pending._

## Batch 6 — mssql-performance-review, sqlplan-batch, VERSION_COMPATIBILITY.md

_Pending._
