# MSSQL Performance Skills — Comprehensive SKILL.md Inventory

Generated: 2026-06-06
Source: 19 SKILL.md files in `skills/*/SKILL.md`

---

## 1. DMV Names (sys.dm_*, sys.*)

| DMV / System View | Referenced In (file:line) |
|---|---|
| `sys.dm_exec_cached_plans` | sqlplan-review:202, tsql-review:274; sqlmemory-review:61,157 |
| `sys.dm_exec_sql_text` | sqlplan-review:202; sqlwait-review:136 |
| `sys.dm_os_wait_stats` | sqlplan-review:218; sqlwait-review:3,23,35,43,98-99,115,202,206,241 |
| `sys.dm_exec_requests` | sqlwait-review:24,135,381; sqlquerystore-review:263; sqlmemory-review:176; sqlhadr-review:337; sqlerrorlog-review:187 |
| `sys.dm_os_waiting_tasks` | sqlwait-review:402 |
| `sys.dm_os_performance_counters` | sqlwait-review:427; sqlmemory-review:27,51,117; sqlmemory-review:151 |
| `sys.dm_hadr_availability_replica_states` | sqlwait-review:181; sqlhadr-review:66,90-94,236-237; sqlclusterlog-review:439 |
| `sys.dm_hadr_database_replica_states` | sqlwait-review:423; sqlhadr-review:68,98-106,229,145; sqlerrorlog-review:107,145 |
| `sys.dm_exec_procedure_stats` | sqlprocstats-review:13; mssql-performance-review:474 |
| `sys.dm_exec_trigger_stats` | sqlprocstats-review:14,207 |
| `sys.dm_exec_function_stats` | sqlprocstats-review:14 |
| `sys.dm_exec_sessions` | sqlprocstats-review:179; sqlerrorlog-review:121 |
| `sys.dm_os_buffer_descriptors` | sqlmemory-review:132; sqlwait-review:371 |
| `sys.dm_db_column_store_row_group_physical_stats` | sqlplan-review:447 |
| `sys.dm_query_store_*` DMV family | sqlquerystore-review:14,23-24 |
| `sys.query_store_runtime_stats` | sqlquerystore-review:23,71-78,306 |
| `sys.query_store_query` | sqlquerystore-review:23,66-78 |
| `sys.query_store_plan` | sqlquerystore-review:23,69-78; sqlprocstats-review:214-217 |
| `sys.query_store_query_text` | sqlquerystore-review:67-68,99-100 |
| `sys.query_store_wait_stats` | sqlquerystore-review:24,94-101 |
| `sys.database_query_store_options` | sqlquerystore-review:25,124 |
| `sys.query_store_plan_feedback` | sqlquerystore-review:295,299,303,309,378,388 |
| `sys.query_store_replicas` | sqlquerystore-review:314-315 |
| `sys.query_store_query_hints` | sqlquerystore-review:319-320 |
| `sys.dm_db_tuning_recommendations` | sqlquerystore-review:324 |
| `sys.database_automatic_tuning_options` | sqlquerystore-review:324 |
| `sys.dm_os_nodes` | sqlmemory-review:129; sqlstats-review:226 |
| `sys.dm_os_sys_info` | sqlmemory-review:137,219 |
| `sys.dm_os_sys_memory` | sqlmemory-review:28,90; sqlmemory-review:221 |
| `sys.dm_os_ring_buffers` | sqlmemory-review:26,214; sqlclusterlog-review:84 |
| `sys.dm_exec_query_memory_grants` | sqlmemory-review:27,80,175,179,188 |
| `sys.dm_os_memory_clerks` | sqlmemory-review:23,36; sqlerrorlog-review:158; sqlwait-review:307; sqlprocstats-review:112; sqlerrorlog-review:80 |
| `sys.dm_resource_governor_resource_pools` | sqlmemory-review:191 |
| `sys.dm_os_buffer_pool_extension_configuration` | sqlmemory-review:195 |
| `sys.dm_db_xtp_memory_consumers` | sqlmemory-review:211 |
| `sys.dm_tran_locks` | sqlmemory-review:163 |
| `sys.dm_db_missing_index_details` | sqlindex-advisor:17-18,48 |
| `sys.dm_db_missing_index_group_stats` | sqlindex-advisor:17-18,48 |
| `sys.dm_db_missing_index_groups` | sqlindex-advisor:46 |
| `sys.dm_hadr_automatic_seeding` | sqlhadr-review:321 |
| `sys.dm_hadr_cluster` | sqlhadr-review:330 |
| `sys.dm_hadr_physical_seeding_stats` | sqlhadr-review:335 |
| `sys.dm_io_virtual_file_stats` | sqldiskio-review:22-23,52,136 |
| `sys.master_files` | sqlwait-review:174-175,326; sqldiskio-review:53,71-72 |
| `sys.traces` | sqldiskio-review:78 |
| `sys.configurations` | sqlwait-review:149; sqlmemory-review:224; sqlerrorlog-review:306 |
| `sys.databases` | sqlwait-review:169; sqlerrorlog-review:253; sqlhadr-review:341 |
| `sys.availability_groups` | sqlhadr-review:63; sqlhadr-review:324 |
| `sys.availability_replicas` | sqlwait-review:179; sqlhadr-review:64 |
| `sys.availability_group_listeners` | sqlhadr-review:79 |
| `sys.availability_group_listener_ip_addresses` | sqlhadr-review:81 |
| `sys.dm_exec_plan_attributes` | sqlplan-review:275 |
| `sys.dm_exec_query_resource_semaphores` | sqlwait-review:295 |
| `sys.dm_tran_active_transactions` | sqltrace-review:197; sqlerrorlog-review:373; sqlwait-review:440 |
| `sys.dm_tran_persistent_version_store_stats` | sqlplan-review:230; sqltrace-review:198 |
| `sys.database_ledger_blocks` | sqltrace-review:193 |
| `sys.dm_os_workers` | sqlwait-review:405 |
| `sys.dm_os_latch_stats` | sqlwait-review:435 |
| `sys.dm_exec_connections` | sqlspn-review:171; sqlencryption-review:55,174 |
| `sys.dm_database_encryption_keys` | sqlencryption-review:51 |
| `sys.columns` | sqlencryption-review:53,97 |
| `sys.column_encryption_keys` | sqlencryption-review:53,99 |
| `sys.column_master_keys` | sqlencryption-review:53,100 |
| `sys.symmetric_keys` | sqlencryption-review:54,124 |
| `sys.asymmetric_keys` | sqlencryption-review:54,136 |
| `sys.certificates` | sqlencryption-review:54,150 |
| `sys.key_encryptions` | sqlencryption-review:54 |
| `msdb.dbo.backupset` | sqlencryption-review:54,163 |
| `sys.sensitivity_classifications` | sqlencryption-review:56,207 |
| `sys.cryptographic_providers` | sqlencryption-review:57,196 |
| `sys.endpoints` | sqlencryption-review:58,219 |
| `sys.server_audits` | sqlencryption-review:59 |
| `sys.database_audit_specifications` | sqlencryption-review:59 |
| `sys.ledger_*` DMV family | sqlencryption-review:60 |
| `sys.server_principals` | sqlencryption-review:442 |
| `sys.database_permissions` | sqlencryption-review:477 |
| `sys.sql_modules` | sqlencryption-review:486; sqlprocstats-review:197 |
| `sys.database_mirroring_endpoints` | sqlhadr-review:239 |
| `sys.plan_guides` | sqlplan-review:214 |
| `sys.remote_service_bindings` | sqlencryption-review:434 |
| `sys.linked_logins` | sqlencryption-review:520 |
| `sys.dm_db_session_space_usage` | sqlerrorlog-review:241 |
| `sys.dm_resource_governor_resource_pools` | sqlmemory-review:191 |
| `sys.dm_os_sys_memory` | sqlmemory-review:28 |
| `sys.dm_server_registry` | sqlencryption-review:398 |

---

## 2. Threshold Values

| Threshold | Value | File:Line |
|---|---|---|
| Expensive operator costPercent | ≥ 25% | sqlplan-review:45 |
| High-cost operator costPercent | ≥ 50% | sqlplan-review:46 |
| Memory grant info | granted ≥ 512 MB | sqlplan-review:47 |
| Large memory grant | granted ≥ 1,024 MB | sqlplan-review:48 |
| Excessive memory grant | granted / used ≥ 10× AND granted ≥ 1 GB | sqlplan-review:49 |
| Memory grant critical | ≥ 4,096 MB | sqlplan-review:50 |
| Grant wait warning | > 0 ms | sqlplan-review:51 |
| Grant wait critical | ≥ 5,000 ms | sqlplan-review:52 |
| High compile CPU warning | ≥ 1,000 ms | sqlplan-review:53 |
| High compile CPU critical | ≥ 5,000 ms | sqlplan-review:54 |
| Expensive scan | rowsRead / rowsReturned > 100× | sqlplan-review:56 |
| Key lookup concern | actualRows > 1,000 OR actualExecutions > 1,000 | sqlplan-review:57 |
| Sort spill risk | actualRows > estimateRows × 10 | sqlplan-review:58 |
| Hash spill risk | probeRows > buildRows × 100 | sqlplan-review:59 |
| High loop count (warning) | actualExecutions > 10,000 | sqlplan-review:60 |
| High loop count (info) | actualExecutions > 1,000 with high inner cost | sqlplan-review:61 |
| Bad row estimate (warning) | actual vs estimated > 1,000× | sqlplan-review:62 |
| Bad row estimate (info) | actual vs estimated > 100× | sqlplan-review:63 |
| Parallel efficiency low | < 50% AND DOP × 0.5 AND elapsed ≥ 1,000 ms | sqlplan-review:66 |
| Large IN list | > 20 discrete seek ranges | sqlplan-review:67 |
| Missing indexes excessive | > 5 MissingIndexGroup children | sqlplan-review:68 |
| Excessive parameters | > 50 ColumnReference children in ParameterList | sqlplan-review:69 |
| Window frame large | RANGE UNBOUNDED PRECEDING with actualRows > 100,000 | sqlplan-review:70 |
| Cached plan size (info) | ≥ 1,024 KB | sqlplan-review:71 |
| Cached plan size (warning) | ≥ 5,120 KB | sqlplan-review:72 |
| Serial required memory (info) | ≥ 524,288 KB (512 MB) | sqlplan-review:74 |
| Compile wait (info) | CompileTime > CompileCPU × 2 AND CompileTime > 1,000 ms | sqlplan-review:75 |
| Wide row (warning) | EstimatedAvgRowSize > 8,192 bytes | sqlplan-review:76 |
| Wide row (critical) | EstimatedAvgRowSize > 32,768 bytes | sqlplan-review:77 |
| Wide output list (info) | OutputList ColumnReference count > 20 | sqlplan-review:78 |
| Elapsed time hotspot | ActualElapsedms > 1,000 ms AND > 50% of statement elapsed | sqlplan-review:79 |
| Thread starvation | Any thread ActualRows = 0 while total > 0 | sqlplan-review:80 |
| CompileMemory warning | ≥ 1,048,576 KB (1 GB) | sqlplan-review:148 |
| RECOMPILE compile CPU warning | CompileCPU ≥ 500 ms | sqlplan-review:168 |
| RECOMPILE compile CPU critical | CompileCPU ≥ 2,000 ms | sqlplan-review:168 |
| CTE chain depth warning | > 4 levels deep | tsql-review:36,152 |
| Large IN list | > 20 discrete values | tsql-review:37 |
| Nested subquery depth | ≥ 3 levels | tsql-review:38 |
| Excessive parameters (proc) | > 50 named parameters | tsql-review:39 |
| Wide index suggestion | > 4 key columns OR > 5 INCLUDE columns | tsql-review:40 |
| NOLOCK overuse | ≥ 3 tables WITH (NOLOCK) in same query | tsql-review:41 |
| Small variable-length type | ≤ 2 characters | tsql-review:42 |
| PAGEIOLATCH — investigate | ≥ 10% of total wait time | sqlwait-review:339 |
| PAGEIOLATCH — critical | ≥ 40% | sqlwait-review:339 |
| LCK_M — warning | any presence; ≥ 20% critical | sqlwait-review:340 |
| CXPACKET — investigate | ≥ 15% (with no CXCONSUMER) | sqlwait-review:341 |
| CXPACKET — critical | ≥ 40% | sqlwait-review:341 |
| RESOURCE_SEMAPHORE — any | any presence > 0 ms | sqlwait-review:343 |
| RESOURCE_SEMAPHORE — critical | ≥ 5% of total | sqlwait-review:344 |
| WRITELOG — investigate | ≥ 10% | sqlwait-review:345 |
| ASYNC_NETWORK_IO | ≥ 20% | sqlwait-review:346 |
| SOS_SCHEDULER_YIELD | ≥ 15% investigate | sqlwait-review:347 |
| Signal wait ratio — warning | ≥ 15% | sqlwait-review:348 |
| Signal wait ratio — critical | ≥ 25% | sqlwait-review:348 |
| THREADPOOL | any presence = Critical | sqlwait-review:349 |
| LATCH_EX/SH | ≥ 5% investigate | sqlwait-review:351 |
| LOGMGR_RESERVE_APPEND | any presence = Critical | sqlwait-review:352 |
| Single wait type dominance | ≥ 60% | sqlwait-review:353 |
| Poison waits window-scaled | wait_time_ms > 1,000 × window_minutes | sqlwait-review:354 |
| Trend spike (V20) | ≥ 200% of own average | sqlwait-review:356 |
| Trend worsening (V19) | monotonic ≥ 3 consecutive periods | sqlwait-review:357 |
| Trend emerging (V23) | < 0.5% → ≥ 2.0% | sqlwait-review:358 |
| Forced memory grant (V37) | forced_grant_count > 0 warning; > 10 critical | sqlwait-review:360 |
| Memory grant timeout (V38) | timeout_error_count > 0 = Critical | sqlwait-review:361 |
| Stolen memory (V39) | ≥ 15% warning; > 30% critical | sqlwait-review:362 |
| File I/O latency (V40) | ≥ 100 ms warning; ≥ 500 ms critical | sqlwait-review:363 |
| Duration regression | current avg ≥ 2× baseline avg | sqlquerystore-review:142 |
| CPU regression | current avg ≥ 2× baseline avg | sqlquerystore-review:143 |
| Logical reads regression | current avg ≥ 3× baseline avg | sqlquerystore-review:144 |
| Plan instability | ≥ 3 plans for same query_hash | sqlquerystore-review:145 |
| Aborted execution rate | > 10% of total | sqlquerystore-review:146 |
| Single query resource share | > 30% of any metric | sqlquerystore-review:147-151 |
| Workload concentration | top 3 queries > 80% of any metric | sqlquerystore-review:152 |
| Wait dominant | > 50% of query duration on single wait category | sqlquerystore-review:153 |
| Lock wait dominant | LCK category ≥ 20% | sqlquerystore-review:154 |
| Query Store storage | > 80% of max_storage_size_mb | sqlquerystore-review:155 |
| Force failure count | any failure > 0 | sqlquerystore-review:156 |
| Parameter sensitivity variance | max_duration > 10× min_duration AND ≥ 10 executions | sqlquerystore-review:157 |
| Volatile metric variance | (max - min) / avg > 10× AND max > 1000 ms | sqlquerystore-review:158 |
| Long duration — warning | ≥ 5,000 ms | sqltrace-review:69 |
| Long duration — critical | ≥ 30,000 ms | sqltrace-review:70 |
| High CPU — warning | ≥ 5,000 ms | sqltrace-review:71 |
| High reads — warning | ≥ 100,000 | sqltrace-review:72 |
| High reads — critical | ≥ 1,000,000 | sqltrace-review:73 |
| High writes — warning | ≥ 10,000 pages | sqltrace-review:74 |
| Recompile threshold | ≥ 3 for same object | sqltrace-review:76 |
| High-frequency query | ≥ 1,000 executions | sqltrace-review:77 |
| Parameter sniffing signal | max duration > 10× min, ≥ 10 executions | sqltrace-review:78 |
| Global recompile ratio | > 5% of completed events | sqltrace-review:79 |
| Workload concentration | top 3 > 80% of total CPU | sqltrace-review:80 |
| Ad-hoc ratio | distinct / total > 80% | sqltrace-review:81 |
| High logical reads (warning) | ≥ 1,000,000 | sqlstats-review:85 |
| High logical reads (critical) | ≥ 10,000,000 | sqlstats-review:86 |
| High scan count — warning | ≥ 1,000 | sqlstats-review:87 |
| High scan count — critical | ≥ 10,000 | sqlstats-review:88 |
| High physical read ratio | physical / logical ≥ 10% | sqlstats-review:89 |
| LOB reads dominant | lob_logical / logical ≥ 50% | sqlstats-review:90 |
| Read-ahead scan indicator | ≥ 80% AND logical ≥ 10,000 | sqlstats-review:91 |
| Single-table dominance — warning | ≥ 80% of statement logical reads | sqlstats-review:92 |
| Single-table dominance — critical | ≥ 95% | sqlstats-review:93 |
| Columnstore low skip rate | skipped / (reads + skipped) < 50% | sqlstats-review:94 |
| Elapsed time — warning | ≥ 30,000 ms | sqlstats-review:95 |
| Elapsed time — critical | ≥ 300,000 ms | sqlstats-review:96 |
| CPU time — warning | ≥ 60,000 ms | sqlstats-review:97 |
| I/O wait indicator | cpu < 10% of elapsed | sqlstats-review:98 |
| Parallelism indicator | cpu > 150% of elapsed | sqlstats-review:99 |
| High compile overhead | compile_cpu > 20% of execution_cpu AND compile_elapsed ≥ 200 ms | sqlstats-review:100 |
| Zero-return high-read | rows_affected = 0 AND logical reads ≥ 10,000 | sqlstats-review:101 |
| cpu_ms_per_sec (warning) | ≥ 50 ms/s | sqlprocstats-review:72 |
| cpu_ms_per_sec (critical) | ≥ 500 ms/s | sqlprocstats-review:72 |
| Single proc share of CPU | > 50% warning; > 80% critical | sqlprocstats-review:73 |
| avg_cpu_ms (warning) | ≥ 1,000 ms | sqlprocstats-review:74 |
| avg_cpu_ms (critical) | ≥ 10,000 ms | sqlprocstats-review:74 |
| avg_logical_reads (warning) | ≥ 50,000 | sqlprocstats-review:75 |
| avg_logical_reads (critical) | ≥ 500,000 | sqlprocstats-review:75 |
| Physical reads % of logical | > 10% warning; > 50% critical | sqlprocstats-review:76 |
| execs_in_interval (warning) | ≥ 10,000 | sqlprocstats-review:77 |
| execs_per_sec (warning) | ≥ 10/s; ≥ 100/s critical | sqlprocstats-review:78 |
| avg_spills (warning) | ≥ 1; ≥ 10 critical | sqlprocstats-review:79 |
| cpu_to_elapsed_ratio (parallel waste) | > 1.5 warning; > 3.0 critical | sqlprocstats-review:80 |
| cpu_to_elapsed_ratio (blocking/IO wait) | < 0.2 warning; < 0.05 critical | sqlprocstats-review:81 |
| max_to_avg_cpu_ratio (sniffing) | ≥ 3 info; ≥ 10 warning; ≥ 100 critical | sqlprocstats-review:82 |
| avg_elapsed_ms (warning) | ≥ 5,000 ms; ≥ 30,000 ms critical | sqlprocstats-review:84 |
| Estimated data loss | > 30 sec Critical; > 5 sec Warning | sqlhadr-review:113 |
| Estimated recovery time | > 300 sec Warning | sqlhadr-review:114 |
| Secondary lag | > 60 sec Critical; > 10 sec Warning | sqlhadr-review:115 |
| Redo queue size | > 500 MB Critical; > 100 MB Warning | sqlhadr-review:116 |
| Log send queue size | > 500 MB Warning | sqlhadr-review:117 |
| Multi-database lag | ≥ 3 databases > 10 sec on same replica Critical | sqlhadr-review:118 |
| Login failure burst — Warning | > 5 in 5-min window | sqlerrorlog-review:64 |
| Login failure burst — Critical | > 20 in 5-min window | sqlerrorlog-review:65 |
| Restart cycling | ≥ 2 startup messages within 60 min | sqlerrorlog-review:66 |
| I/O slow built-in threshold | 15 seconds | sqlerrorlog-review:67 |
| Log backup overdue FULL/BULK_LOGGED | > 24 hr | sqlerrorlog-review:68 |
| Log backup overdue active log pressure | > 8 hr | sqlerrorlog-review:69 |
| Data file avg read latency — warning | 10–20 ms; Critical > 20 ms | sqldiskio-review:100 |
| Data file avg write latency — warning | 10–20 ms; Critical > 20 ms | sqldiskio-review:101 |
| Log file avg write latency — warning | 5–10 ms; Critical > 10 ms | sqldiskio-review:102 |
| Stall ratio — warning | 5–15%; Critical > 15% | sqldiskio-review:103 |
| Hot file: single file share | 60–80% Warning; > 80% Critical | sqldiskio-review:104 |
| Auto-growth events 24h | 1–3 Warning; > 3 Critical | sqldiskio-review:105 |
| Auto-growth fixed-size increment | < 64 MB Critical | sqldiskio-review:106 |
| Error burst window | > 10 ERR lines in 5 min Critical | sqlclusterlog-review:64 |
| Failover cycling | ≥ 3 group moves in 30 min Critical | sqlclusterlog-review:65 |
| Log time gap | > 30 min Critical | sqlclusterlog-review:66 |
| Pending state duration | > 120 sec Critical | sqlclusterlog-review:67 |
| Lease timeout | 20 sec default | sqlclusterlog-review:68 |
| Health check timeout | 30 sec default | sqlclusterlog-review:69 |
| Heartbeat timeout | 3 missed heartbeats | sqlclusterlog-review:70 |
| PLE (single NUMA) — warning | < 300 s; Critical < 60 s | sqlmemory-review:99 |
| PLE decline — warning | ≥ 10 s/min; Critical ≥ 60 s/min | sqlmemory-review:101 |
| Single-use plan cache | ≥ 30% warning; ≥ 60% critical | sqlmemory-review:102 |
| RESOURCE_SEMAPHORE wait | 1–5 queued warning; > 5 critical | sqlmemory-review:103 |
| Memory grant timeout | any = Critical | sqlmemory-review:104 |
| Stolen memory | ≥ 15% warning; ≥ 30% critical | sqlmemory-review:105 |
| Buffer pool: one DB share | ≥ 60% warning; ≥ 80% critical | sqlmemory-review:106 |
| ColumnStore pool | > 25% warning; > 50% critical | sqlmemory-review:107 |
| In-Memory OLTP memory | > 25% warning; > 50% critical | sqlmemory-review:108 |
| Orphaned CMK composite index width | > 4 key OR > 5 include | sqlindex-advisor:397 |
| Composite index total columns | > 10 = Warning | sqlindex-advisor:399 |
| Certificate / key days until expiry | < 90 days warning; ≤ 0 critical | sqlencryption-review:240 |
| Key rotation age (symmetric/CEK) | > 365 days warning; > 730 days critical | sqlencryption-review:241 |
| CMK rotation age | > 730 days warning | sqlencryption-review:242 |
| RSA key length | RSA_1024 warning; RSA_512 critical | sqlencryption-review:243 |
| Unencrypted remote connections | > 0 Warning | sqlencryption-review:244 |
| TDE DEK algorithm | TRIPLE_DES_3KEY/RC4 = Critical | sqlencryption-review:245 |
| Symmetric key algorithm (CLE) | DES/DESX/TRIPLE_DES = Warning; RC4/RC2 = Critical | sqlencryption-review:246 |
| Backup encryption algorithm | TRIPLE_DES_3KEY Warning; None Critical | sqlencryption-review:247 |
| Non-FIPS algorithm | SHA1/DES/3DES Warning; RC4/MD5 Critical | sqlencryption-review:248 |
| Duplicate SPN | 2+ accounts holding same SPN = Critical | sqlspn-review:71 |

---

## 3. SQL Server Feature Claims

| Feature | File:Line |
|---|---|
| Intelligent Query Processing (IQP) | sqlplan-review:3 |
| Adaptive Joins | sqlplan-review:192-194,311-315 |
| Interleaved Execution (MSTVF) | sqlplan-review:186-190 |
| Parameter Sensitive Plan (PSP) Optimization | sqlplan-review:223-226; sqlquerystore-review:293-296 |
| Cardinality Estimation (CE) Feedback | sqlplan-review:231-234; sqlquerystore-review:298-301 |
| DOP Feedback | sqlquerystore-review:303-306; sqlerrorlog-review:375-378 |
| Memory Grant Feedback | sqlquerystore-review:308-311 |
| Batch Mode on Rowstore | sqlplan-review:448-451; sqlstats-review:172 |
| Accelerated Database Recovery (ADR) | sqlplan-review:227-230; sqlerrorlog-review:370-373 |
| Columnstore Index | sqlplan-review:317-319,440-447; sqlstats-review:145-148 |
| In-Memory OLTP | sqlplan-review:436-439; sqlmemory-review:208-211; sqlprocstats-review:196-199 |
| Query Store | sqlplan-review:184-186; sqlquerystore-review:14 |
| Query Store Wait Stats | sqlquerystore-review:253-255 |
| Query Store Forced Plan | sqlplan-review:184-186 |
| Query Store Hints | sqlquerystore-review:296,318-322 |
| Automatic Tuning (FORCE_LAST_GOOD_PLAN) | sqlquerystore-review:322-326 |
| Always On Availability Groups | sqlhadr-review:11-14 |
| Contained AG | sqlhadr-review:324-327; sqlclusterlog-review:204-207 |
| Distributed AG | sqlspn-review:246-249 |
| Read-Only Routing | sqlhadr-review:306-312 |
| Transparent Data Encryption (TDE) | sqlencryption-review:255-295 |
| Always Encrypted | sqlencryption-review:298-339 |
| Cell-Level Encryption (CLE) | sqlencryption-review:342-368 |
| Backup Encryption | sqlencryption-review:371-391 |
| Transport/TLS Encryption | sqlencryption-review:395-421 |
| Azure Key Vault / EKM | sqlencryption-review:526-547 |
| Secure Enclaves (for AE) | sqlencryption-review:306-318 |
| SQL Server Ledger | sqltrace-review:189-193; sqlencryption-review:44; sqldeadlock-review:168-172 |
| Temporal Tables | sqldeadlock-review:168-172 |
| Dynamic Data Masking | sqlencryption-review:44 |
| Buffer Pool Extension (BPE) | sqlmemory-review:194-198 |
| Lock Pages in Memory (LPIM) | sqlmemory-review:218-222 |
| Resource Governor | sqlmemory-review:189-193; sqlwait-review:451 |
| Partitioning | sqlplan-review:147-150 |
| Parallel Redo | sqlhadr-review:334-337 |
| Automatic Seeding | sqlhadr-review:314-320 |
| Database-Level Health Detection (DB_FAILOVER) | sqlhadr-review:344-347 |
| Cloud Witness | sqlhadr-review:329-332; sqlclusterlog-review:194-197 |
| Azure Arc–Enabled SQL Server | sqlerrorlog-review:390-393; sqlclusterlog-review:199-202 |
| gMSA (group Managed Service Account) | sqlspn-review:238-241 |
| Resource-Based Constrained Delegation (RBCD) | sqlspn-review:190-193 |
| Kerberos FAST Armoring | sqlspn-review:254-257 |
| Scalar UDF Inlining | tsql-review:399-403 |
| STRING_AGG | tsql-review:360-362,411-414 |
| APPROX_COUNT_DISTINCT | tsql-review:420-424 |
| JSON_OBJECT / JSON_ARRAY | tsql-review:408-411 |
| IS DISTINCT FROM | tsql-review:424-427 |
| TRIM (SQL 2017+) | tsql-review:416-419 |

---

## 4. Version-Specific Claims

| Version | Claim | File:Line |
|---|---|---|
| SQL Server 2016+ | Query Store baseline feature | sqlquerystore-review:16 |
| SQL Server 2016+ | DISABLE_OPTIMIZER_ROWGOAL | sqlplan-review:308 |
| SQL Server 2016+ | Parallel Redo | sqlhadr-review:334 |
| SQL Server 2016+ | Temporal Tables | sqldeadlock-review:169 |
| SQL Server 2016+ | CXCONSUMER separated from CXPACKET | sqlwait-review:380 |
| SQL Server 2017+ (compat 140) | Interleaved Execution | sqlplan-review:188 |
| SQL Server 2017+ | Adaptive Joins | sqlplan-compare:113 |
| SQL Server 2017+ | Columnstore Batch Mode | sqlplan-compare:118 |
| SQL Server 2017+ | STRING_AGG | tsql-review:362,413 |
| SQL Server 2017+ | TRIM | tsql-review:417-418 |
| SQL Server 2017+ | Query Store Wait Stats | sqlquerystore-review:255 |
| SQL Server 2017+ | Automatic Tuning | sqlquerystore-review:324 |
| SQL Server 2017+ | RESUMABLE online index rebuild | sqlindex-advisor:472 |
| SQL Server 2019+ (compat 150) | Batch Mode Adaptive Joins | sqlplan-review:192 |
| SQL Server 2019+ | ADR (Accelerated Database Recovery) | sqlplan-review:229 |
| SQL Server 2019+ | Batch Mode on Rowstore | sqlplan-review:449-451 |
| SQL Server 2019+ | Scalar UDF Inlining | tsql-review:80,401 |
| SQL Server 2019+ | APPROX_COUNT_DISTINCT | tsql-review:422 |
| SQL Server 2019+ | Memory Grant Feedback (batch mode) | sqlquerystore-review:309 |
| SQL Server 2019+ | LOG_RATE_GOVERNOR | sqlwait-review:452 |
| SQL Server 2019+ | ADR PVS cleanup | sqlerrorlog-review:370 |
| SQL Server 2022+ (compat 160) | PSP Optimization / Dispatcher | sqlplan-review:224; sqlplan-compare:154 |
| SQL Server 2022+ | Cardinality Estimation Feedback | sqlplan-review:232 |
| SQL Server 2022+ | DOP Feedback | sqlquerystore-review:304 |
| SQL Server 2022+ | IQP DOP Feedback (ERRORLOG) | sqlerrorlog-review:375 |
| SQL Server 2022+ | CE Feedback (ERRORLOG) | sqlerrorlog-review:385 |
| SQL Server 2022+ | Memory Grant Feedback (row mode) | sqlquerystore-review:309 |
| SQL Server 2022+ | Query Store Replica Coverage | sqlquerystore-review:314 |
| SQL Server 2022+ | Query Store Hints | sqlquerystore-review:318 |
| SQL Server 2022+ | IS DISTINCT FROM | tsql-review:425 |
| SQL Server 2022+ | JSON_OBJECT / JSON_ARRAY | tsql-review:409 |
| SQL Server 2022+ | SQL Ledger | sqltrace-review:189; sqlencryption-review:44 |
| SQL Server 2022+ | Contained AG | sqlhadr-review:325 |
| SQL Server 2022+ | Columnstore ORDER clause | sqlplan-review:443 |
| SQL Server 2022+ | TRIM characters parameter | tsql-review:419 |
| SQL Server 2022+ | STRING_SPLIT ordinal | sqlplan-review:475 |
| SQL Server 2014+ | Buffer Pool Extension (deprecated 2019, removed 2022) | sqlmemory-review:197 |
| SQL Server 2014+ | In-Memory OLTP | sqlprocstats-review:197 |
| SQL Server 2012+ | THROW | tsql-review:130,230 |
| SQL Server 2012+ | Cloud Witness (WS2016+) | sqlclusterlog-review:194 |
| SQL Server 2012+ | Columnstore features | sqlstats-review:170 |
| SQL Server 2012+ | sp_server_diagnostics | sqlclusterlog-review:213 |
| SQL Server 2005+ | Partitioning | sqlplan-compare:148 |
| Windows Server 2012+ | Kerberos FAST Armoring | sqlspn-review:255 |
| Windows Server 2012 R2+ | RBCD | sqlspn-review:324 |
| Windows Server 2016+ | Cloud Witness | sqlhadr-review:330 |

---

## 5. T-SQL Functions / Commands Referenced

| Function / Command | File:Line |
|---|---|
| `OPTION (RECOMPILE)` | sqlplan-review:97,168-170; tsql-review:165-166; sqlprocstats-review:136 |
| `OPTION (OPTIMIZE FOR)` | sqlplan-review:97,170; sqlquerystore-review:185,215 |
| `OPTION (OPTIMIZE FOR UNKNOWN)` | sqlplan-review:170,369-371 |
| `OPTION (HASH JOIN)` | sqlplan-review:271 |
| `OPTION (MAXRECURSION N)` | sqlplan-review:173-174; tsql-review:306-308 |
| `OPTION (DISABLE_OPTIMIZER_ROWGOAL)` | sqlplan-review:308,312 |
| `OPTION (KEEPFIXED PLAN)` | sqlwait-review:387 |
| `OPTION (MIN_GRANT_PERCENT)` | sqlwait-review:386; sqlstats-review:130-131; sqlerrorlog-review:182 |
| `OPTION (MAX_GRANT_PERCENT)` | sqlmemory-review:177 |
| `OPTION (USE HINT(...))` | sqlplan-review:130,190-191; sqlerrorlog-review:378 |
| `SET NOCOUNT ON` | tsql-review:367-370 |
| `SET ROWCOUNT` | sqlplan-review:175-178; tsql-review:160-162 |
| `SET ANSI_NULLS OFF` | sqlplan-review:220-222; tsql-review:240-242 |
| `SET QUOTED_IDENTIFIER OFF` | sqlplan-review:220-222; tsql-review:240-242 |
| `SET STATISTICS IO, TIME ON` | sqlstats-review:12-14 |
| `EXEC` (dynamic) | tsql-review:178-180 |
| `sp_executesql` | tsql-review:176-177,193-197 |
| `THROW` | tsql-review:130,230-231 |
| `RAISERROR` | tsql-review:227-231 |
| `BEGIN TRY / END TRY / BEGIN CATCH / END CATCH` | tsql-review:129-132 |
| `BEGIN TRANSACTION / COMMIT / ROLLBACK` | tsql-review:132-134 |
| `TRUNCATE TABLE` | tsql-review:56 |
| `SELECT *` | tsql-review:49-52 |
| `SELECT DISTINCT` | tsql-review:105-108 |
| `UNION` vs `UNION ALL` | tsql-review:135-138 |
| `TOP (N)` | tsql-review:103-104; tsql-review:283-285 |
| `OFFSET N ROWS FETCH NEXT M ROWS ONLY` | tsql-review:104,266-268 |
| `CROSS JOIN` | tsql-review:85-88 |
| `WITH (NOLOCK)` | tsql-review:41,386-389 |
| `WITH (HOLDLOCK)` | tsql-review:309-312 |
| `CREATE TABLE #temp` | tsql-review:243-256 |
| `DECLARE @table TABLE` | tsql-review:253-256 |
| `STRING_AGG` | tsql-review:360-362,392-393,412-414 |
| `FOR XML PATH` | tsql-review:360-362,392-393 |
| `STUFF` | tsql-review:360-362 |
| `STRING_SPLIT` | sqlplan-review:472-475 |
| `JSON_VALUE` / `JSON_QUERY` | sqlplan-review:484-485 |
| `JSON_OBJECT` / `JSON_ARRAY` | tsql-review:408-411 |
| `TRIM` | tsql-review:416-419 |
| `LTRIM` / `RTRIM` | sqlplan-review:251 |
| `UPPER` / `LOWER` | sqlplan-review:251 |
| `SUBSTRING` | sqlplan-review:251 |
| `LEFT` / `RIGHT` | sqlplan-review:251 |
| `REPLACE` | sqlplan-review:251 |
| `CAST` / `CONVERT` | sqlplan-review:251 |
| `ISNULL` / `COALESCE` | sqlplan-review:251,97-100 |
| `CASE` | sqlplan-review:251 |
| `ABS` / `CEILING` / `FLOOR` / `ROUND` | sqlplan-review:251 |
| `DATEADD` / `DATEDIFF` / `DATEPART` | sqlplan-review:251; tsql-review:313-316 |
| `YEAR` / `MONTH` / `DAY` | sqlplan-review:251; tsql-review:62-64 |
| `GETDATE` / `GETUTCDATE` / `SYSUTCDATETIME` | sqlplan-review:251; tsql-review:232-234 |
| `SYSDATETIME` | tsql-review:232-234 |
| `TRY_CAST` / `TRY_CONVERT` | sqlplan-review:251; tsql-review:327-328 |
| `PARSE` / `TRY_PARSE` | sqlplan-review:251 |
| `ISNUMERIC` | tsql-review:325-328 |
| `NULLIF` | tsql-review:278-281 |
| `LEN` / `DATALENGTH` | tsql-review:378-381 |
| `CHARINDEX` / `PATINDEX` | tsql-review:258-259 |
| `@@IDENTITY` | tsql-review:296-300 |
| `SCOPE_IDENTITY` | tsql-review:296-300 |
| `@@ROWCOUNT` | tsql-review:301-304 |
| `@@SPID` | sqlwait-review:138 |
| `IS DISTINCT FROM` | tsql-review:118,424-427 |
| `APPROX_COUNT_DISTINCT` | tsql-review:420-424 |
| `ROW_NUMBER` / `ROW_NUMBER() OVER` | sqlplan-review:432; tsql-review:266 |
| `FIRST_VALUE` / `MAX` / `COUNT` / `SUM` / `AVG` / `MIN` | tsql-review:156-158 |
| `EXISTS` | tsql-review:288-289 |
| `MERGE` | tsql-review:309-312; sqldeadlock-review:131,139-142 |
| `CROSS APPLY` / `OUTER APPLY` | sqlplan-review:464; tsql-review:84 |
| `CTE` / `WITH ... AS` | sqlplan-review:360-363; tsql-review:147-154 |
| `OPENQUERY` / `OPENROWSET` | tsql-review:198-201 |
| `sp_testlinkedserver` | sqlerrorlog-review:309 |
| `sp_configure` | sqlmemory-review:148,226; sqlwait-review:387; sqlerrorlog-review:346 |
| `RECONFIGURE` | sqlmemory-review:226 |
| `ALTER DATABASE ... SET` | sqlwait-review:392-393; sqlplan-review:222 |
| `ALTER DATABASE ... SET ENCRYPTION ON` | sqlencryption-review:259 |
| `ALTER DATABASE ... SET HADR SUSPEND / RESUME` | sqlhadr-review:230 |
| `ALTER AVAILABILITY GROUP ... MODIFY REPLICA` | sqlhadr-review:165 |
| `DBCC SQLPERF` | sqlwait-review:439 |
| `DBCC CHECKDB` | sqlerrorlog-review:229 |
| `DBCC TRACEON` / `DBCC TRACESTATUS` | sqlerrorlog-review:199,334 |
| `DBCC SHRINKFILE` | sqlerrorlog-review:239 |
| `DBCC LOGINFO` | sqlerrorlog-review:263 |
| `DBCC FREEPROCCACHE` | sqlprocstats-review:158 |
| `BACKUP CERTIFICATE` | sqlencryption-review:269,381,459 |
| `BACKUP MASTER KEY` | sqlencryption-review:502 |
| `BACKUP SERVICE MASTER KEY` | sqlencryption-review:515 |
| `CREATE CERTIFICATE` | sqlencryption-review:274 |
| `CREATE SYMMETRIC KEY` | sqlencryption-review:347 |
| `CREATE ASYMMETRIC KEY` | sqlencryption-review:473 |
| `OPEN SYMMETRIC KEY` / `CLOSE SYMMETRIC KEY` | sqlencryption-review:350-352 |
| `ENCRYPTBYKEY` / `DECRYPTBYKEY` | sqlencryption-review:347 |
| `EXECUTE AS` / `REVERT` | tsql-review:185-188 |
| `sp_OACreate` / `sp_OAMethod` / etc. | tsql-review:337-338 |
| `xp_cmdshell` | tsql-review:202-204; sqlwait-review:427 |
| `xp_regread` / `xp_regwrite` / etc. | tsql-review:337-338 |
| `xp_readerrorlog` | sqlerrorlog-review:39-47 |
| `sp_query_store_force_plan` | sqlquerystore-review:181,189; sqlprocstats-review:219 |
| `sp_query_store_unforce_plan` | sqlplan-review:186; sqlquerystore-review:189 |
| `sp_query_store_set_hints` | sqlplan-review:226; sqlquerystore-review:296-311 |
| `sp_query_store_clear_hints` | sqlquerystore-review:321 |
| `sp_create_plan_guide` | sqlplan-review:213-214 |
| `sp_verify_database_ledger` | sqlerrorlog-review:381 |
| `sp_control_dbmasterkey_password` | sqlencryption-review:3 |
| `sp_server_diagnostics` | sqlclusterlog-review:217 |
| `setspn` | sqlspn-review:39-42 |
| `Get-ADUser` / `Get-ADComputer` | sqlspn-review:42-43 |
| `klist` | sqlspn-review:60-62 |
| `Test-ADServiceAccount` | sqlspn-review:241 |

---

## 6. Extended Event Names Referenced

| XE Event Name | File:Line |
|---|---|
| `rpc_completed` | sqltrace-review:46 |
| `sql_batch_completed` | sqltrace-review:47 |
| `sql_batch_starting` | sqltrace-review:48 |
| `attention` | sqltrace-review:49,105 |
| `error_reported` | sqltrace-review:50,116 |
| `sql_statement_recompile` | sqltrace-review:51-52,115 |
| `lock_timeout` | sqltrace-review:53,109 |
| `xml_deadlock_report` | sqltrace-review:54,274 |
| `hash_warning` | sqltrace-review:55,125 |
| `sort_warning` | sqltrace-review:56,121 |
| `missing_column_statistics` | sqltrace-review:57,129 |
| `missing_join_predicate` | sqltrace-review:58,133 |
| `data_file_auto_grow` | sqltrace-review:59 |
| `log_file_auto_grow` | sqltrace-review:60 |
| `query_post_execution_showplan` | sqltrace-review:61,171-172,182-183 |
| `columnstore_delta_store_flush` | sqltrace-review:186 |
| `ledger_block_generated` | sqltrace-review:190-191 |
| `hadr_db_partner_set_sync_state` | sqltrace-review:196 |
| `pvs_garbage_collection` | sqltrace-review:196 |
| `database_file_size_change` | sqltrace-review:168 |
| `sql_batch_starting` (with cert check) | sqlencryption-review:413 |
| `rpc_starting` | sqlencryption-review:413 |
| `Failed Logins` | sqlerrorlog-review:300 |

---

## 7. Wait Types Referenced

| Wait Type | File:Line |
|---|---|
| `PAGEIOLATCH_SH` | sqlwait-review:369; sqlplan-review:266; sqlerrorlog-review:222; sqlmemory-review:250 |
| `PAGEIOLATCH_EX` | sqlwait-review:369; sqlerrorlog-review:222 |
| `PAGEIOLATCH_UP` | sqlwait-review:369 |
| `LCK_M_S` | sqlwait-review:376 |
| `LCK_M_IX` | sqlwait-review:375 |
| `LCK_M_RS_*` | sqlwait-review:375 |
| `LCK_M_RIn_*` | sqlwait-review:375 |
| `LCK_M_RX_*` | sqlwait-review:375 |
| `CXPACKET` | sqlwait-review:341,378-381 |
| `CXCONSUMER` | sqlwait-review:342,378 |
| `RESOURCE_SEMAPHORE` | sqlwait-review:343,383-388; sqlerrorlog-review:175-176; sqlmemory-review:103,114,174 |
| `RESOURCE_SEMAPHORE_QUERY_COMPILE` | sqlplan-review:218; sqlwait-review:383,384-388 |
| `WRITELOG` | sqlwait-review:345,390-393; sqldiskio-review:127 |
| `LOGBUFFER` | sqlwait-review:390,392 |
| `ASYNC_NETWORK_IO` | sqlwait-review:346,396-398; sqlquerystore-review:271 |
| `SOS_SCHEDULER_YIELD` | sqlwait-review:347,399-402 |
| `THREADPOOL` | sqlwait-review:349,403-405; sqlerrorlog-review:188 |
| `PAGELATCH_EX` | sqlwait-review:350,407-409; sqlmemory-review:252 |
| `PAGELATCH_SH` | sqlwait-review:350,407 |
| `LATCH_EX` | sqlwait-review:351,433-435 |
| `LATCH_SH` | sqlwait-review:351,433 |
| `LOGMGR_RESERVE_APPEND` | sqlwait-review:352,437-440 |
| `OLEDB` | sqlwait-review:415-418 |
| `HADR_SYNC_COMMIT` | sqlwait-review:420-423; sqlerrorlog-review:83; sqlclusterlog-review:333 |
| `HADR_WORK_QUEUE` | sqlerrorlog-review:83 |
| `HADR_LOGCAPTURE_WAIT` | sqlerrorlog-review:486 |
| `HADR_TRANSPORT_SESSION_CHANNEL_LOCK` | sqlclusterlog-review:333 |
| `HADR_REPLICA_DDL_END` | sqlclusterlog-review:333 |
| `IO_QUEUE_LIMIT` | sqlwait-review:447,449 |
| `IO_RETRY` | sqlwait-review:447,450 |
| `RESMGR_THROTTLED` | sqlwait-review:447,451 |
| `LOG_RATE_GOVERNOR` | sqlwait-review:447,452 |
| `POOL_LOG_RATE_GOVERNOR` | sqlwait-review:447,452 |
| `INSTANCE_LOG_RATE_GOVERNOR` | sqlwait-review:447,452 |
| `SE_REPL_CATCHUP_THROTTLE` | sqlwait-review:447,454 |
| `SE_REPL_COMMIT_ACK` | sqlwait-review:447 |
| `SE_REPL_COMMIT_TURN` | sqlwait-review:447 |
| `SE_REPL_ROLLBACK_ACK` | sqlwait-review:447 |
| `SE_REPL_SLOW_SECONDARY_THROTTLE` | sqlwait-review:447 |
| `HADR_THROTTLE_LOG_RATE_GOVERNOR` | sqlwait-review:447,453 |
| `PREEMPTIVE_OS_WRITEFILEGATHERER` | sqlwait-review:427-428 |
| `CMEMTHREAD` | sqlmemory-review:249 |
| `HTBUILD` | sqlwait-review:378 |
| `HTDELETE` | sqlwait-review:378 |
| `HTMEMO` | sqlwait-review:378 |
| `HTREINIT` | sqlwait-review:378 |
| `HTREPARTITION` | sqlwait-review:378 |

---

## 8. Performance Counters Referenced

| Counter | Object / Source | File:Line |
|---|---|---|
| Page life expectancy | Buffer Manager | sqlmemory-review:50-53,117,122 |
| Page life expectancy (per node) | Buffer Node | sqlmemory-review:117 |
| SQL Compilations/sec | SQL Statistics | sqlmemory-review:151 |
| SQL Re-Compilations/sec | SQL Statistics | sqlmemory-review:151 |
| Cache Hit Ratio | Exec Statistics / Plan Cache | sqlmemory-review:166 |
| Log Growths | sys.dm_os_performance_counters | sqlwait-review:427 |

---

*Total: ~19,000 lines across 19 SKILL.md files. This document captures all explicitly referenced entities with file:line citations.*
