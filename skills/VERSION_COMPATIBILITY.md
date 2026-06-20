# SQL Server Version Compatibility

Which of the 829 checks in this library apply to your SQL Server version.

---

## How Version Gating Works

Each check's **Trigger** line documents its minimum SQL Server version using the suffix `— SQL 20XX+` or `— SQL 20XX+ only`. At runtime:

- **Checks without a version tag** are universal (SQL 2008 R2+) — they rely on attributes always present in execution plans, wait stats, and T-SQL syntax.
- **Version-gated checks** self-skip when the relevant feature is absent from the artifact. For example, a PSP dispatcher check finds no `ParameterSensitivePredicate` element in a SQL 2019 plan and marks itself `NOT ASSESSED`.
- **Compatibility-level gating** is separate from server version. SQL Server 2022 running a database at compat level 130 will NOT trigger SQL 2022-only checks — the optimizer won't generate the relevant XML attributes or annotations at that level.
- **No false positives** on older versions: feature-specific XML attributes, DMV columns, wait types, and ERRORLOG messages simply won't be present, so version-gated checks are either `NOT ASSESSED` or silently skipped.

---

## Skill-Level Version Support Matrix

| Skill | 2008 R2 | 2012 | 2014 | 2016 | 2017 | 2019 | 2022 | Azure SQL DB | Azure SQL MI |
|-------|:-------:|:----:|:----:|:----:|:----:|:----:|:----:|:------------:|:------------:|
| `tsql-review` | ◑ | ◑ | ◑ | ◑ | ◑ | ◑ | ✓ | ✓ | ✓ |
| `sqlstats-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqltrace-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `sqlwait-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `sqlplan-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlplan-compare` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlindex-advisor` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqldeadlock-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlplan-batch` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlprocstats-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlerrorlog-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `sqlspn-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `sqlhadr-review` | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ◑ |
| `sqlag-review` | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ◑ |
| `sqlclusterlog-review` | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ◑ |
| `sqlquerystore-review` | ✗ | ✗ | ✗ | ◑ | ◑ | ◑ | ✓ | ✓ | ✓ |
| `sqlencryption-review` | ◑ | ◑ | ◑ | ◑ | ◑ | ◑ | ✓ | ◑ | ◑ |
| `sqldbconfig-review` | ◑ | ◑ | ◑ | ◑ | ◑ | ✓ | ✓ | ◑ | ◑ |
| `sqlmemory-review` | ◑ | ◑ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `sqldiskio-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `sqlbootstraplog-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| `ssrstracelog-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| `sqlmigration-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlmigration-security-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlmigration-objects-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mssql-performance-review` | ◑ | ◑ | ◑ | ◑ | ◑ | ◑ | ✓ | ◑ | ◑ |

**Legend:**
- ✓ Full support — all checks for this skill apply
- ◑ Partial — most checks apply; version-gated checks for newer features are skipped automatically
- ✗ Not applicable — the skill's core feature does not exist on this version

**Notes:**
- `sqlhadr-review` and `sqlclusterlog-review` require **Always On Availability Groups** (SQL 2012+). Both skills also work with **SQL Server 2022 on Azure SQL MI** but not on Azure SQL DB (no WSFC or AG infrastructure).
- `sqlquerystore-review` requires **Query Store** (SQL 2016+). On SQL 2016 the check count is partial because `sys.query_store_wait_stats` (SQL 2017+) and IQP/PSP/CE Feedback signals (SQL 2019–2022) are not available.
- `sqlwait-review` on Azure SQL DB/MI: many wait types differ or are not exposed. Core I/O, lock, and parallelism checks still apply.
- `sqltrace-review` on Azure: Extended Events are available but some event classes (XE trace capture mechanics) differ from on-premises.
- `sqlspn-review` on Azure: K1–K31 (on-premises SPN/Kerberos) are not relevant for Azure AD–only auth; K32–K33 are Azure-specific.
- `sqlencryption-review` on SQL 2008 R2: A9–A16 (AE, SQL 2016+), A22–A25 (backup enc, SQL 2014+), A82 (SSISDB, SQL 2012+), A87/A88 (DDM, SQL 2016+) not applicable. On SQL 2012: A82 applicable, A87/A88 still skipped. On SQL 2016: A9–A16, A87/A88 applicable; A10/A12 (enclave), A63–A67 (AE Advanced, SQL 2019+) skipped. On SQL 2019: A59, A73–A76, A94 (TLS 1.3, Ledger, GDPR append-only, SQL 2022+) skipped. Azure SQL DB/MI: A50, A51, A77–A80, A101, A112 are Azure-specific; A53 (`sys.sensitivity_classifications`) available SQL 2019+/Azure.
- `sqldbconfig-review` on SQL 2008 R2–SQL 2016 (pre-SP2): B8 (`sql_memory_model_desc` — SQL 2012 SP4+), B22 (`sys.dm_server_services.instant_file_initialization_enabled` — SQL 2012 SP4+), and B19 via `sys.dm_db_log_info` (SQL 2016 SP2+) fall back to ERRORLOG or `DBCC LOGINFO` — mark as [Unverified] if those sources are not included in the input. B1/B3 `numa_node_count` in `sys.dm_os_sys_info` requires SQL 2016 SP2+; use `cpu_count` as a proxy on older versions. All B10–B18 checks (sys.databases columns) are available SQL 2005+. Azure SQL DB: most instance-level sp_configure checks (B1–B9, B24–B28) are not user-configurable and should be skipped; B10–B18 database-level checks apply.
- `sqlmemory-review`: O3 (per-NUMA-node PLE) requires SQL 2012+. O15 (Buffer Pool Extension) applies SQL 2014+ (Enterprise/Standard editions only). O16 (ColumnStore clerk) and O17 (XTP clerk) require SQL 2014+. On Azure SQL DB: O3, O15, O18 (OS-level pressure) do not apply, and O19 (LPIM)/O20 (Max Server Memory) are platform-managed.
- `sqlbootstraplog-review`: analyzes the Windows Setup Bootstrap log layout — applies to SQL Server on Windows only. U20 (`SQLSVCINSTANTFILEINIT`) and U21 (setup-time TempDB parameters) require SQL 2016+ setup; U1–U19/U22–U24 apply to all on-premises versions. Azure SQL DB/MI have no user-visible setup: ✗.
- `ssrstracelog-review`: analyzes SQL Server Reporting Services report server trace logs, configuration, and `ExecutionLog3` — applies to on-premises SSRS (SQL 2008 R2–2022) on Windows Server only. G15 (legacy `ProcessingEngine=1` setting) applies to SSRS 2014/2016 only — removed in SSRS 2017+ and self-skips on later versions. Azure SQL DB/MI: ✗ — SSRS does not run as a service on Azure-managed platforms (only the report server catalog database can be hosted on Azure SQL MI for an SSRS instance running on a VM).
- `sqldiskio-review`: all Z checks rely on `sys.dm_io_virtual_file_stats`, available on every supported version. On Azure SQL DB: file placement checks (Z6–Z8, Z10) are platform-managed and skipped; Z11/Z14 (auto-growth event trace) are partial because the default trace is not exposed.
- `sqlag-review`: requires Always On AG (SQL 2012+). F31 (Contained AG — SQL 2022+) and F32 (Distributed AG — SQL 2016+) self-skip on earlier versions. On Azure SQL MI: AG catalog views (`sys.availability_groups`, `sys.availability_replicas`) are accessible; F1 (IsHadrEnabled), F6 (version mismatch), and some endpoint checks may not apply in Azure-managed contexts. Azure SQL DB: ✗ — no Always On AG infrastructure.

---

## Active Check Count by SQL Server Version

These cumulative counts show how many of the 829 total checks are active on a given version of on-premises SQL Server. Checks that gate on absent features are automatically skipped (`NOT ASSESSED`). The 45 migration-readiness checks (Y1–Y15, J1–J15, M1–M16) are not version-gated — they assess portability of a planned move rather than a feature available on the running version — so they are active on every row below.

| SQL Server Version | Active checks | Notes |
|--------------------|:-------------:|-------|
| SQL Server 2022 | **757** | Azure-specific checks (I15, I17, K32, K33, A50, A51, A77–A80, A112) not applicable; E33 and L27 apply when Azure Arc agent is installed |
| SQL Server 2019 | **726** | −31 SQL 2022-only checks unavailable (includes A59, A73–A76, A94, F31) |
| SQL Server 2017 | **704** | −22 SQL 2019-only checks unavailable (includes A2, A10, A12, A53, A63–A67) |
| SQL Server 2016 | **691** | −13 SQL 2017-only checks unavailable |
| SQL Server 2014 | **654** | −37 more: U20/U21 (setup-time IFI/TempDB parameters, SQL 2016+) unavailable; all Query Store base checks unavailable; A9/A11/A13–A16 (AE, SQL 2016+), A87/A88 (DDM, SQL 2016+), F32 (distributed AG, SQL 2016+) unavailable |
| SQL Server 2012 | **648** | −6 more: A22–A25 (Backup Encryption, SQL 2014+), A72, R21 unavailable |
| SQL Server 2008 R2 | **552** | −96 more: all 58 Always On AG/WSFC checks and 37 AG-config checks (F1–F37) unavailable; A82 (SSISDB, SQL 2012+), I16, X23 unavailable |

**Azure SQL Database / Azure SQL Managed Instance:** Active check counts vary significantly by service tier and feature availability — use the skill matrix above and the cloud-specific notes below.

---

## Version-Gated Check Catalog

All checks with an explicit version requirement, organized by minimum SQL Server version.

### SQL Server 2012+

These checks require features introduced in SQL Server 2012.

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| I16 | `sqlstats-review` | Columnstore Batch Mode I/O Absent Despite CS Index | Columnstore indexes (SQL 2012+) |
| X23 | `sqltrace-review` | Columnstore Delta Store Flush Frequency | Columnstore indexes (SQL 2012+) |
| H26 | `sqlhadr-review` | Read-Scale Secondary Missing RCSI | Always On AG (SQL 2012+) |
| H27 | `sqlhadr-review` | AG Without Database-Level Health Detection | Always On AG (SQL 2012+) |
| H28 | `sqlhadr-review` | Secondary Database Stuck in INITIALIZING State | Always On AG (SQL 2012+) |
| L30 | `sqlclusterlog-review` | sp_server_diagnostics Component Warning | `sp_server_diagnostics` (SQL 2012+) |
| F37 | `sqlag-review` | Automatic Seeding Left Enabled During a Manual-Restore Workflow | Always On AG automatic seeding (SQL 2012+) |

**Entire skills at SQL 2012+:** `sqlhadr-review` (H1–H28), `sqlclusterlog-review` (L1–L30), `sqlag-review` (F1–F37, except F32 SQL 2016+ and F31 SQL 2022+). Always On AG was introduced in SQL 2012; these skills have no applicable checks on SQL 2008 R2.

| A82 | `sqlencryption-review` | SSISDB DMK Password Not Registered | SSISDB catalog (SQL Server Integration Services, SQL 2012+) |

### SQL Server 2014+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| R21 | `sqlprocstats-review` | Natively Compiled Proc Regression | In-Memory OLTP / memory-optimized tables (SQL 2014+) |
| A22 | `sqlencryption-review` | Recent Backups Not Encrypted | `WITH ENCRYPTION` backup option (SQL 2014+) |
| A23 | `sqlencryption-review` | Backup Encryption Certificate Not Separately Backed Up | Encrypted backup metadata in `msdb.dbo.backupset` (SQL 2014+) |
| A24 | `sqlencryption-review` | Backup Encryption Using TRIPLE_DES_3KEY or AES_128 | Backup encryption algorithm metadata (SQL 2014+) |
| A25 | `sqlencryption-review` | Backup Encryption Certificate Expiring Within 90 Days | Encrypted backup cert tracking (SQL 2014+) |
| A72 | `sqlencryption-review` | Log Backup Encryption Not Enabled | Log backup encryption (`WITH ENCRYPTION` on log backups) — SQL 2014+ |

### SQL Server 2016+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S10 | `sqlplan-review` | Downlevel Cardinality Estimator | Compat level 130 CE baseline (SQL 2016+) |
| U20 | `sqlbootstraplog-review` | IFI Not Granted at Setup | `SQLSVCINSTANTFILEINIT` setup parameter (SQL 2016+) |
| U21 | `sqlbootstraplog-review` | TempDB Setup Parameters Undersized | Setup-time TempDB parameters `SQLTEMPDB*` (SQL 2016+) |
| H25 | `sqlhadr-review` | Parallel Redo Worker Saturation | Parallel redo for AG secondaries (SQL 2016+) |
| K36 | `sqlspn-review` | Distributed AG Forwarder Listener SPN Missing | Distributed Availability Groups (SQL 2016+) |
| F32 | `sqlag-review` | Distributed AG Replication Link Set to Synchronous | Distributed Availability Groups (SQL 2016+) |
| P16 | `sqldeadlock-review` | Ledger / Temporal History Table Deadlock | Temporal tables only (SQL 2016+); see SQL 2022+ for Ledger aspect |
| R25 | `sqlprocstats-review` | QS Plan Instability Correlated to Procstats Variance | Query Store (SQL 2016+) |

**Entire skill at SQL 2016+:** `sqlquerystore-review` (Q1–Q32). Query Store was introduced in SQL 2016. On SQL 2016 only Q1–Q18 and Q23–Q25 are fully active; the remaining checks require SQL 2017–2022 features (see below).

| A9 | `sqlencryption-review` | Deterministic Encryption on Non-Searchable Columns | Always Encrypted (SQL 2016+) |
| A87 | `sqlencryption-review` | Sensitive Column Masked but Not Encrypted | Dynamic Data Masking (SQL 2016+) |
| A88 | `sqlencryption-review` | UNMASK Permission Granted to Broad Role | Dynamic Data Masking UNMASK permission (SQL 2016+) |
| A11 | `sqlencryption-review` | Column Encryption Algorithm is not AEAD_AES_256_CBC_HMAC_SHA_256 | Always Encrypted (SQL 2016+) |
| A13 | `sqlencryption-review` | Column Master Key Stored in Windows Certificate Store | Always Encrypted CMK (SQL 2016+) |
| A14 | `sqlencryption-review` | Sensitive-Pattern Column Names Without Always Encrypted | Always Encrypted column check (SQL 2016+) |
| A15 | `sqlencryption-review` | No CEK Rotation Ever Performed | `sys.column_encryption_key_values` (SQL 2016+) |
| A16 | `sqlencryption-review` | Column Master Key Overdue for Rotation (> 2 Years) | `sys.column_master_keys` (SQL 2016+) |

### SQL Server 2017+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S25 | `sqlplan-review` | Interleaved Execution (MSTVF) Active | IQP Interleaved Execution (SQL 2017+, compat level 140) |
| N71 | `sqlplan-review` | Adaptive Join Threshold Evaluation | Adaptive joins (SQL 2017+) |
| C11 | `sqlplan-compare` | Adaptive Join Threshold Changed | Adaptive joins (SQL 2017+) |
| C12 | `sqlplan-compare` | Batch Mode Lost | Adaptive batch mode (SQL 2017+), Batch Mode on Rowstore (SQL 2019+) |
| T82 | `tsql-review` | STRING_AGG Without Deterministic ORDER BY | `STRING_AGG` function (SQL 2017+) |
| T83 | `tsql-review` | TRIM Misses Non-Space Whitespace | `TRIM` function (SQL 2017+) |
| Q19 | `sqlquerystore-review` | High Elapsed Time Wait Dominance | `sys.query_store_wait_stats` (SQL 2017+) |
| Q20 | `sqlquerystore-review` | Lock Wait Dominant for High-Contention Queries | `sys.query_store_wait_stats` (SQL 2017+) |
| Q21 | `sqlquerystore-review` | Parallel Execution Wait Ratio Above Threshold | `sys.query_store_wait_stats` (SQL 2017+) |
| Q22 | `sqlquerystore-review` | Log I/O Wait Dominant for High-Write Queries | `sys.query_store_wait_stats` (SQL 2017+) |
| Q32 | `sqlquerystore-review` | Automatic Tuning FORCE_LAST_GOOD_PLAN Not Enabled | `sys.dm_db_tuning_recommendations` + `sys.database_automatic_tuning_options` (SQL 2017+) |

### SQL Server 2019+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S26 | `sqlplan-review` | Batch Mode Adaptive Join Active | Batch Mode on Rowstore (SQL 2019+, compat level 150) |
| S35 | `sqlplan-review` | ADR Long-Transaction Version Store Accumulation | Accelerated Database Recovery (SQL 2019+) |
| N51 | `sqlplan-review` | Batch Mode on Rowstore | Batch Mode on Rowstore (SQL 2019+, compat level 150) |
| N69 | `sqlplan-review` | IQP Approximate Count Distinct Active | `APPROX_COUNT_DISTINCT` IQP (SQL 2019+) |
| V18 | `sqlwait-review` | Poison / Throttle Waits — LOG_RATE_GOVERNOR | `LOG_RATE_GOVERNOR` / `INSTANCE_LOG_RATE_GOVERNOR` (SQL 2016+; primarily observable in Azure SQL/MI where log rate is tier-enforced) |
| V43 | `sqlwait-review` | ADR PVS Cleanup Worker Wait | `PVS_CLEANUP_LOCK` (SQL 2019+) |
| T79 | `tsql-review` | Scalar UDF Inlining Blocked — Blocking Construct | Scalar UDF inlining (SQL 2019+) |
| T84 | `tsql-review` | APPROX_COUNT_DISTINCT Used for Exact Counting | `APPROX_COUNT_DISTINCT` (SQL 2019+) |
| E29 | `sqlerrorlog-review` | ADR PVS Cleanup Stall | Accelerated Database Recovery (SQL 2019+) |
| X25 | `sqltrace-review` | ADR Version Cleaner Long-Duration Events | ADR version cleaner XE events (SQL 2019+) |
| Q29 | `sqlquerystore-review` | Memory Grant Feedback Instability | Memory Grant Feedback (batch mode SQL 2019+; row mode SQL 2022+) |
| V44 | `sqlwait-review` | TempDB Metadata Latch Contention — Memory-Optimized Metadata Not Enabled | `ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA` (SQL 2019+) |
| A2 | `sqlencryption-review` | TDE Encryption Scan In Progress | Suspendable TDE scan (`ALTER DATABASE … SUSPEND | RESUME DATABASE ENCRYPTION SCAN`) — SQL 2019+; scan itself exists from SQL 2008 but suspension requires SQL 2019+ |
| A10 | `sqlencryption-review` | Randomized Encryption Without Secure Enclave Where Queries Require It | Always Encrypted with Secure Enclaves (SQL 2019+) |
| A12 | `sqlencryption-review` | Secure Enclave Not Configured for Range / LIKE Queries | `column encryption enclave type` configuration (SQL 2019+) |
| A53 | `sqlencryption-review` | Sensitivity-Classified Columns Lacking Encryption | `sys.sensitivity_classifications` (SQL 2019+; also Azure SQL) |
| A63 | `sqlencryption-review` | Always Encrypted with Secure Enclaves — Attestation URL Misconfigured | Always Encrypted Advanced — attestation configuration (SQL 2019+) |
| A64 | `sqlencryption-review` | Always Encrypted — Enclave Computation Without Secure Enclave Configuration | Always Encrypted Advanced — enclave computation (SQL 2019+) |
| A65 | `sqlencryption-review` | Column Encryption Key Encrypted with RSA-OAEP in Azure Key Vault Without Secure Enclave | Always Encrypted Advanced — CEK encryption key (SQL 2019+) |
| A66 | `sqlencryption-review` | Always Encrypted — Enclave-Enabled Key Rotation Not Performed | Always Encrypted Advanced — enclave key rotation (SQL 2019+) |
| A67 | `sqlencryption-review` | Always Encrypted — `ALTER DATABASE ENCRYPTION` with Enclave Metadata Missing | Always Encrypted Advanced — enclave metadata (SQL 2019+) |

### SQL Server 2022+ only

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S34 | `sqlplan-review` | PSP Dispatcher Plan Detected | Parameter Sensitive Plan optimization (compat level 160) |
| S36 | `sqlplan-review` | CE Feedback Annotation Present | CE Feedback (SQL 2022+) |
| N67 | `sqlplan-review` | Ordered Columnstore Scan — Segment Pruning Confirmed | Ordered columnstore index (SQL 2022+) |
| N68 | `sqlplan-review` | PSP Variant Cardinality Error | PSP variant plans (compat level 160) |
| N70 | `sqlplan-review` | DOP Feedback Adjusted Plan | IQP DOP Feedback (compat level 160) |
| V3 | `sqlwait-review` | Parallelism — CXSYNC_PORT / CXSYNC_CONSUMER sub-triggers | `CXSYNC_PORT` and `CXSYNC_CONSUMER` wait types (SQL 2022+/Azure SQL only; CXPACKET/CXCONSUMER aspects of V3 are universal) |
| V41 | `sqlwait-review` | PSP Optimization Selector Wait | `QUERY_OPTIMIZER_PSP_WAIT` (SQL 2022+) |
| V42 | `sqlwait-review` | IQP DOP Feedback Adjustment Wait | `DOP_FEEDBACK_WAIT` (SQL 2022+) |
| T80 | `tsql-review` | Ledger Table DML Without Version Column Awareness | Ledger tables (SQL 2022+) |
| T81 | `tsql-review` | JSON_OBJECT / JSON_ARRAY Below Compat Level 160 | `JSON_OBJECT`, `JSON_ARRAY` (compat level 160) |
| T85 | `tsql-review` | IS DISTINCT FROM Below Compat Level 160 | `IS DISTINCT FROM` (compat level 160) |
| E30 | `sqlerrorlog-review` | IQP DOP Feedback Applied | DOP Feedback ERRORLOG messages (SQL 2022+) |
| E31 | `sqlerrorlog-review` | Ledger Verification Failure | Ledger verification (SQL 2022+) |
| E32 | `sqlerrorlog-review` | CE Feedback Model Version Change | CE Feedback model (SQL 2022+) |
| H23 | `sqlhadr-review` | Contained AG Misrouted DML | Contained Availability Groups (SQL 2022+) |
| F31 | `sqlag-review` | Contained AG Using Windows Endpoint Auth | Contained Availability Groups (SQL 2022+) |
| L28 | `sqlclusterlog-review` | Contained AG: Contained System Database Offline | Contained Availability Groups (SQL 2022+) |
| C19 | `sqlplan-compare` | PSP Dispatcher Added | PSP optimization (compat level 160) |
| X21 | `sqltrace-review` | PSP Variant Switching in Trace | PSP variant switching XE events (SQL 2022+) |
| X24 | `sqltrace-review` | Ledger Block Generation Events | `ledger_block_generated` XE event (SQL 2022+) |
| Q26 | `sqlquerystore-review` | PSP Optimization Active | PSP plan variants in `sys.query_store_plan_feedback` (SQL 2022+) |
| Q27 | `sqlquerystore-review` | CE Feedback Persistent Model Adjustment | CE Feedback in `sys.query_store_plan_feedback` (compat level 160) |
| Q28 | `sqlquerystore-review` | DOP Feedback Applied | DOP Feedback in `sys.query_store_plan_feedback` (compat level 160) |
| Q30 | `sqlquerystore-review` | Query Store Replica Coverage Gap | `sys.query_store_replicas` (SQL 2025+ on-premises GA; Azure SQL Database GA; SQL 2022 limited preview with TF 12606 only — not production-supported) |
| P16 | `sqldeadlock-review` | Ledger / Temporal History Table Deadlock (Ledger aspect) | Ledger tables (SQL 2022+); temporal aspect listed under SQL 2016+ |
| Q31 | `sqlquerystore-review` | Query Store Hint Ineffective or Stale | `sys.query_store_query_hints` (SQL 2022+) |
| Q12 | `sqlquerystore-review` | Plan Feedback Active | Automated plan feedback via `plan_feedback` column (SQL 2022+) |
| A59 | `sqlencryption-review` | TLS 1.3 Not Enforced for Connections | TLS 1.3 support (SQL 2022+) |
| A73 | `sqlencryption-review` | Ledger Table Without Automated Digest Management | Ledger tables (SQL 2022+) |
| A74 | `sqlencryption-review` | Ledger Digest Storage Not Configured | Ledger tables (SQL 2022+) |
| A75 | `sqlencryption-review` | Ledger Database Without Automatic Digest Upload | Ledger tables (SQL 2022+) |
| A76 | `sqlencryption-review` | Ledger Verification Incomplete or Overdue | Ledger verification (SQL 2022+) |
| A94 | `sqlencryption-review` | GDPR Art. 17: PII in Append-Only Ledger Without Crypto-Shredding Strategy | `sys.tables.ledger_type = 2` append-only ledger (SQL 2022+) |

### Windows Server Version-Gated Checks

Two checks gate on Windows Server version rather than SQL Server version.

| Check | Skill | Name | Requirement |
|-------|-------|------|-------------|
| H24 | `sqlhadr-review` | Cloud Witness Inaccessible | Cloud Witness requires Windows Server 2016+ |
| L26 | `sqlclusterlog-review` | Cloud Witness Repeated Timeout | Cloud Witness requires Windows Server 2016+ |

### Azure SQL Database / Azure SQL Managed Instance–Only Checks

These checks only fire on Azure SQL Database or Azure SQL Managed Instance. They are silently skipped on on-premises SQL Server.

| Check | Skill | Name | Platform |
|-------|-------|------|----------|
| I15 | `sqlstats-review` | Azure SQL Page Server Reads Detected | Azure SQL Hyperscale only |
| I17 | `sqlstats-review` | Remote Page Server Reads Dominant | Azure SQL Hyperscale only |
| K32 | `sqlspn-review` | Entra-Only Auth With Orphaned AD SPN | Azure SQL (Entra ID / EXTERNAL_PROVIDER auth) |
| K33 | `sqlspn-review` | Azure SQL MI SPN for On-Premises Clients | Azure SQL Managed Instance only |
| A50 | `sqlencryption-review` | Azure Key Vault BYOK TDE Without Automatic Key Rotation | Azure SQL / SQL on Azure VM with AKV TDE protector |
| A51 | `sqlencryption-review` | TDE Using Service-Managed Key in Compliance-Sensitive Azure SQL Environment | Azure SQL service-managed TDE (`encryptor_type = SERVICE_MANAGED`) |
| A101 | `sqlencryption-review` | Azure Key Vault Soft-Delete or Purge Protection Not Enabled | Azure SQL using AKV BYOK TDE or AE CMK |
| A112 | `sqlencryption-review` | Azure SQL Managed Instance: Managed Identity Missing AKV Permissions for CMK | Azure SQL Managed Instance BYOK TDE only |

### Arc-Conditional Checks (On-Premises or Cloud with Azure Arc Agent)

These checks fire on **any** SQL Server instance — on-premises or cloud — that has the Azure Arc agent installed. They are skipped automatically when Arc agent events are absent from the log. They are **not** Azure-only: count them for on-premises SQL Server assessments when Arc is deployed.

| Check | Skill | Name | Condition |
|-------|-------|------|-----------|
| E33 | `sqlerrorlog-review` | Azure Arc–Enabled SQL: Agent Disconnect | Any SQL Server with Azure Arc agent (any version) |
| L27 | `sqlclusterlog-review` | Azure Arc-Managed Cluster Agent Disconnect | Any SQL Server cluster with Azure Arc agent |

---

## Compatibility Level Reference

SQL Server allows a database to run at a **compatibility level lower than the installed server version** (e.g., SQL Server 2022 with `COMPATIBILITY_LEVEL = 140`). Some checks gate on compatibility level rather than server version, so a newer server running an older compat level will have those checks silently skip.

| Compat Level | SQL Server baseline | Checks that require this level |
|:------------:|:-------------------:|-------------------------------|
| 110 | SQL 2012 | None explicitly — core CE 2012 is assumed baseline |
| 120 | SQL 2014 | None explicitly |
| 130 | SQL 2016 | S10 (Downlevel CE fires when ≥ 130 is NOT used) |
| 140 | SQL 2017 | S25 (Interleaved Execution, MSTVF); C11 (Adaptive Join) |
| 150 | SQL 2019 | S26, N51 (Batch Mode on Rowstore, Adaptive Join BMoR) |
| 160 | SQL 2022 | S34, N68 (PSP dispatcher); Q27, Q28 (CE/DOP Feedback); T81 (JSON_OBJECT); T85 (IS DISTINCT FROM); C19 (PSP compare) |

**Practical implication:** Migrating a database to SQL Server 2022 while keeping `COMPATIBILITY_LEVEL = 140` gives you the SQL 2022 execution engine but none of the compat-level-160 features. Checks S34, N68, Q27, Q28, T81, T85, C19 will all return `NOT ASSESSED` in that configuration.

---

## Universal Checks (SQL 2008 R2+)

**551 of 829 checks (66.5%)** have no version gate and apply to every supported SQL Server version from SQL Server 2008 R2 through SQL Server 2022, Azure SQL Database, and Azure SQL Managed Instance.

These checks analyze behaviors present since SQL Server 2008 R2:

| Category | Examples |
|----------|---------|
| Execution plan operators | Key Lookups, Nested Loops inefficiency, Hash Match spills, merge join spool, scan vs. seek |
| Row estimate accuracy | Estimated vs. actual row divergence, statistics staleness signals |
| Implicit conversions | Type mismatch causing scan, `PlanAffectingConvert` warnings |
| Missing index hints | Optimizer `MissingIndex` XML attributes |
| T-SQL anti-patterns | Cursors, `SELECT *`, non-sargable predicates, correlated subqueries, `NOLOCK` hints |
| I/O statistics | Logical reads, physical reads, scan count ratios, worktable/worktfile spills |
| Core wait types | `PAGEIOLATCH_*`, `LCK_M_*`, `CXPACKET`, `RESOURCE_SEMAPHORE`, `ASYNC_IO_COMPLETION` |
| Deadlock patterns | Lock ordering, RCSI reader bypass, heap RID locks, MERGE statement deadlocks |
| WSFC health (SQL 2012+) | Quorum loss, lease timeout, node eviction, network partition |
| ERRORLOG patterns | I/O slow subsystem, memory pressure, login failure bursts, `sp_configure` changes |
| SPN / Kerberos | `MSSQLSvc` SPN presence, delegation configuration, service account binding |

---

## Quick Reference: "What works on my version?"

| "I'm on SQL…" | Run these skills without restrictions | Skip or expect partial results |
|---|---|---|
| **2022** | All 22 skills | Azure-specific checks silently skip on-premises |
| **2019** | All 22 skills | 29 SQL 2022-only checks (PSP, CE Feedback, Ledger, DOP Feedback, QS Hints, Plan Feedback, TLS 1.3) skip |
| **2017** | All 22 skills | Above + 22 SQL 2019 checks (ADR, Scalar UDF inlining, BMoR, LOG_RATE_GOVERNOR, TempDB metadata, Always Encrypted Advanced) skip |
| **2016** | All 22 skills | Above + 13 SQL 2017 checks (Interleaved Execution, STRING_AGG, QS wait stats, auto-tuning) skip |
| **2014** | 21 skills (no `sqlquerystore-review`) | Above + all QS checks; R21 fires (In-Memory OLTP available) |
| **2012** | 21 skills (no `sqlquerystore-review`) | Above + R21 (In-Memory OLTP not yet available); A22–A25, A72 (Backup Encryption, SQL 2014+); O15–O17 (BPE/ColumnStore/XTP clerks, SQL 2014+) unavailable |
| **2008 R2** | 19 skills (no `sqlhadr-review`, `sqlclusterlog-review`, `sqlquerystore-review`) | Above + all HADR/cluster checks; Columnstore checks (I16, X23); O3 (per-NUMA PLE, SQL 2012+) |
| **Azure SQL DB** | `tsql-review`, `sqlstats-review`, `sqlplan-review`, `sqlindex-advisor`, `sqldeadlock-review`, `sqlplan-batch`, `sqlplan-compare`, `sqlquerystore-review`, `sqlprocstats-review` | `sqlhadr-review`, `sqlclusterlog-review` not applicable; `sqltrace-review`/`sqlwait-review` partial (wait types and XE event classes differ); `sqlspn-review` partial (K1–K31 not relevant for Entra-only auth); `sqlerrorlog-review`, `sqlencryption-review`, `sqldbconfig-review`, `sqlmemory-review`, `sqldiskio-review`, `mssql-performance-review` partial (instance-level settings are platform-managed); `sqlbootstraplog-review` not applicable (no user-visible setup); `ssrstracelog-review` not applicable (SSRS does not run on Azure SQL Database) |
| **Azure SQL MI** | 20 skills (no `sqlbootstraplog-review`, `ssrstracelog-review` — neither has a user-visible footprint on managed instances) | `sqlhadr-review`/`sqlclusterlog-review` partial (MI uses managed HA, not all WSFC constructs apply) |
