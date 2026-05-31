# SQL Server Version Compatibility

Which of the 519 checks in this library apply to your SQL Server version.

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
| `sqlplan-index-advisor` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlplan-deadlock` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `sqlplan-batch` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `procstats-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `errorlog-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `spn-review` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◑ | ◑ |
| `hadr-health-review` | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ◑ |
| `clusterlog-review` | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ◑ |
| `query-store-review` | ✗ | ✗ | ✗ | ◑ | ◑ | ◑ | ✓ | ✓ | ✓ |
| `mssql-performance-review` | ◑ | ◑ | ◑ | ◑ | ◑ | ◑ | ✓ | ◑ | ◑ |

**Legend:**
- ✓ Full support — all checks for this skill apply
- ◑ Partial — most checks apply; version-gated checks for newer features are skipped automatically
- ✗ Not applicable — the skill's core feature does not exist on this version

**Notes:**
- `hadr-health-review` and `clusterlog-review` require **Always On Availability Groups** (SQL 2012+). Both skills also work with **SQL Server 2022 on Azure SQL MI** but not on Azure SQL DB (no WSFC or AG infrastructure).
- `query-store-review` requires **Query Store** (SQL 2016+). On SQL 2016 the check count is partial because `sys.query_store_wait_stats` (SQL 2017+) and IQP/PSP/CE Feedback signals (SQL 2019–2022) are not available.
- `sqlwait-review` on Azure SQL DB/MI: many wait types differ or are not exposed. Core I/O, lock, and parallelism checks still apply.
- `sqltrace-review` on Azure: Extended Events are available but some event classes (XE trace capture mechanics) differ from on-premises.
- `spn-review` on Azure: K1–K31 (on-premises SPN/Kerberos) are not relevant for Azure AD–only auth; K32–K33 are Azure-specific.

---

## Active Check Count by SQL Server Version

These cumulative counts show how many of the 519 total checks are active on a given version of on-premises SQL Server. Checks that gate on absent features are automatically skipped (`NOT ASSESSED`).

| SQL Server Version | Active checks | Notes |
|--------------------|:-------------:|-------|
| SQL Server 2022 | **514** | 5 Azure-specific checks (I15, I17, K32, K33, E33) not applicable |
| SQL Server 2019 | **491** | +23 SQL 2022-only checks unavailable |
| SQL Server 2017 | **479** | +12 SQL 2019-only checks unavailable |
| SQL Server 2016 | **468** | +11 SQL 2017-only checks unavailable |
| SQL Server 2014 | **443** | −25 more: all 32 Query Store checks unavailable on SQL 2014 (QS introduced SQL 2016; Q31/Q32 require SQL 2022/2017 and are also absent from SQL 2016); minus S10, K36, P16, R25 |
| SQL Server 2012 | **442** | −1 more: R21 (In-Memory OLTP, SQL 2014+) unavailable |
| SQL Server 2008 R2 | **383** | −59 more: all 57 Always On AG/WSFC checks unavailable; I16 and X23 (Columnstore) unavailable |

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
| H26 | `hadr-health-review` | Read-Scale Secondary Missing RCSI | Always On AG (SQL 2012+) |
| H27 | `hadr-health-review` | AG Without Database-Level Health Detection | Always On AG (SQL 2012+) |
| L30 | `clusterlog-review` | sp_server_diagnostics Component Warning | `sp_server_diagnostics` (SQL 2012+) |

**Entire skills at SQL 2012+:** `hadr-health-review` (H1–H27), `clusterlog-review` (L1–L30). Always On AG was introduced in SQL 2012; these skills have no applicable checks on SQL 2008 R2.

### SQL Server 2014+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| R21 | `procstats-review` | Natively Compiled Proc Regression | In-Memory OLTP / memory-optimized tables (SQL 2014+) |

### SQL Server 2016+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S10 | `sqlplan-review` | Downlevel Cardinality Estimator | Compat level 130 CE baseline (SQL 2016+) |
| H25 | `hadr-health-review` | Parallel Redo Worker Saturation | Parallel redo for AG secondaries (SQL 2016+) |
| K36 | `spn-review` | Distributed AG Forwarder Listener SPN Missing | Distributed Availability Groups (SQL 2016+) |
| P16 | `sqlplan-deadlock` | Ledger / Temporal History Table Deadlock | Temporal tables only (SQL 2016+); see SQL 2022+ for Ledger aspect |
| R25 | `procstats-review` | QS Plan Instability Correlated to Procstats Variance | Query Store (SQL 2016+) |

**Entire skill at SQL 2016+:** `query-store-review` (Q1–Q32). Query Store was introduced in SQL 2016. On SQL 2016 only Q1–Q18 and Q23–Q25 are fully active; the remaining checks require SQL 2017–2022 features (see below).

### SQL Server 2017+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S25 | `sqlplan-review` | Interleaved Execution (MSTVF) Active | IQP Interleaved Execution (SQL 2017+, compat level 140) |
| N71 | `sqlplan-review` | Adaptive Join Threshold Evaluation | Adaptive joins (SQL 2017+) |
| C11 | `sqlplan-compare` | Adaptive Join Threshold Changed | Adaptive joins (SQL 2017+) |
| C12 | `sqlplan-compare` | Batch Mode Lost | Adaptive batch mode (SQL 2017+), Batch Mode on Rowstore (SQL 2019+) |
| T82 | `tsql-review` | STRING_AGG Without Deterministic ORDER BY | `STRING_AGG` function (SQL 2017+) |
| T83 | `tsql-review` | TRIM Misses Non-Space Whitespace | `TRIM` function (SQL 2017+) |
| Q19 | `query-store-review` | High Elapsed Time Wait Dominance | `sys.query_store_wait_stats` (SQL 2017+) |
| Q20 | `query-store-review` | Lock Wait Dominant for High-Contention Queries | `sys.query_store_wait_stats` (SQL 2017+) |
| Q21 | `query-store-review` | Parallel Execution Wait Ratio Above Threshold | `sys.query_store_wait_stats` (SQL 2017+) |
| Q22 | `query-store-review` | Log I/O Wait Dominant for High-Write Queries | `sys.query_store_wait_stats` (SQL 2017+) |
| Q32 | `query-store-review` | Automatic Tuning FORCE_LAST_GOOD_PLAN Not Enabled | `sys.dm_db_tuning_recommendations` + `sys.database_automatic_tuning_options` (SQL 2017+) |

### SQL Server 2019+

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S26 | `sqlplan-review` | Batch Mode Adaptive Join Active | Batch Mode on Rowstore (SQL 2019+, compat level 150) |
| S35 | `sqlplan-review` | ADR Long-Transaction Version Store Accumulation | Accelerated Database Recovery (SQL 2019+) |
| N51 | `sqlplan-review` | Batch Mode on Rowstore | Batch Mode on Rowstore (SQL 2019+, compat level 150) |
| N69 | `sqlplan-review` | IQP Approximate Count Distinct Active | `APPROX_COUNT_DISTINCT` IQP (SQL 2019+) |
| V18 | `sqlwait-review` | Poison / Throttle Waits — LOG_RATE_GOVERNOR | `LOG_RATE_GOVERNOR` / `INSTANCE_LOG_RATE_GOVERNOR` (SQL 2019+) |
| V43 | `sqlwait-review` | ADR PVS Cleanup Worker Wait | `PVSVERSIONSTORE_WAIT` / `ADR_CLEANUP_WAIT` (SQL 2019+) |
| T79 | `tsql-review` | Scalar UDF Inlining Blocked — Blocking Construct | Scalar UDF inlining (SQL 2019+) |
| T84 | `tsql-review` | APPROX_COUNT_DISTINCT Used for Exact Counting | `APPROX_COUNT_DISTINCT` (SQL 2019+) |
| E29 | `errorlog-review` | ADR PVS Cleanup Stall | Accelerated Database Recovery (SQL 2019+) |
| X25 | `sqltrace-review` | ADR Version Cleaner Long-Duration Events | ADR version cleaner XE events (SQL 2019+) |
| Q29 | `query-store-review` | Memory Grant Feedback Instability | Memory Grant Feedback (batch mode SQL 2019+; row mode SQL 2022+) |
| V44 | `sqlwait-review` | TempDB Metadata Latch Contention — Memory-Optimized Metadata Not Enabled | `ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA` (SQL 2019+) |

### SQL Server 2022+ only

| Check | Skill | Name | Feature |
|-------|-------|------|---------|
| S34 | `sqlplan-review` | PSP Dispatcher Plan Detected | Parameter Sensitive Plan optimization (compat level 160) |
| S36 | `sqlplan-review` | CE Feedback Annotation Present | CE Feedback (SQL 2022+) |
| N67 | `sqlplan-review` | Ordered Columnstore Scan — Segment Pruning Confirmed | Ordered columnstore index (SQL 2022+) |
| N68 | `sqlplan-review` | PSP Variant Cardinality Error | PSP variant plans (compat level 160) |
| N70 | `sqlplan-review` | DOP Feedback Adjusted Plan | IQP DOP Feedback (compat level 160) |
| V41 | `sqlwait-review` | PSP Optimization Selector Wait | `QUERY_OPTIMIZER_PSP_WAIT` (SQL 2022+) |
| V42 | `sqlwait-review` | IQP DOP Feedback Adjustment Wait | `DOP_FEEDBACK_WAIT` (SQL 2022+) |
| T80 | `tsql-review` | Ledger Table DML Without Version Column Awareness | Ledger tables (SQL 2022+) |
| T81 | `tsql-review` | JSON_OBJECT / JSON_ARRAY Below Compat Level 160 | `JSON_OBJECT`, `JSON_ARRAY` (compat level 160) |
| T85 | `tsql-review` | IS DISTINCT FROM Below Compat Level 160 | `IS DISTINCT FROM` (compat level 160) |
| E30 | `errorlog-review` | IQP DOP Feedback Applied | DOP Feedback ERRORLOG messages (SQL 2022+) |
| E31 | `errorlog-review` | Ledger Verification Failure | Ledger verification (SQL 2022+) |
| E32 | `errorlog-review` | CE Feedback Model Version Change | CE Feedback model (SQL 2022+) |
| H23 | `hadr-health-review` | Contained AG Misrouted DML | Contained Availability Groups (SQL 2022+) |
| L28 | `clusterlog-review` | Contained AG: Contained System Database Offline | Contained Availability Groups (SQL 2022+) |
| C19 | `sqlplan-compare` | PSP Dispatcher Added | PSP optimization (compat level 160) |
| X21 | `sqltrace-review` | PSP Variant Switching in Trace | PSP variant switching XE events (SQL 2022+) |
| X24 | `sqltrace-review` | Ledger Block Generation Events | `ledger_block_generated` XE event (SQL 2022+) |
| Q26 | `query-store-review` | PSP Optimization Active | PSP plan variants in `sys.query_store_plan_feedback` (SQL 2022+) |
| Q27 | `query-store-review` | CE Feedback Persistent Model Adjustment | CE Feedback in `sys.query_store_plan_feedback` (compat level 160) |
| Q28 | `query-store-review` | DOP Feedback Applied | DOP Feedback in `sys.query_store_plan_feedback` (compat level 160) |
| Q30 | `query-store-review` | Query Store Replica Coverage Gap | `sys.query_store_replicas` (SQL 2022+) |
| P16 | `sqlplan-deadlock` | Ledger / Temporal History Table Deadlock (Ledger aspect) | Ledger tables (SQL 2022+); temporal aspect listed under SQL 2016+ |
| Q31 | `query-store-review` | Query Store Hint Ineffective or Stale | `sys.query_store_query_hints` (SQL 2022+) |

### Windows Server Version-Gated Checks

Two checks gate on Windows Server version rather than SQL Server version.

| Check | Skill | Name | Requirement |
|-------|-------|------|-------------|
| H24 | `hadr-health-review` | Cloud Witness Inaccessible | Cloud Witness requires Windows Server 2016+ |
| L26 | `clusterlog-review` | Cloud Witness Repeated Timeout | Cloud Witness requires Windows Server 2016+ |

### Azure SQL Database / Azure SQL Managed Instance–Only Checks

| Check | Skill | Name | Platform |
|-------|-------|------|----------|
| I15 | `sqlstats-review` | Azure SQL Page Server Reads Detected | Azure SQL Hyperscale only |
| I17 | `sqlstats-review` | Remote Page Server Reads Dominant | Azure SQL Hyperscale only |
| K32 | `spn-review` | Entra-Only Auth With Orphaned AD SPN | Azure SQL (Entra ID / EXTERNAL_PROVIDER auth) |
| K33 | `spn-review` | Azure SQL MI SPN for On-Premises Clients | Azure SQL Managed Instance only |
| E33 | `errorlog-review` | Azure Arc–Enabled SQL: Agent Disconnect | Any SQL Server with Azure Arc agent (any version) |
| L27 | `clusterlog-review` | Azure Arc-Managed Cluster Agent Disconnect | Any SQL Server cluster with Azure Arc agent |

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

**383 of 519 checks (73.8%)** have no version gate and apply to every supported SQL Server version from SQL Server 2008 R2 through SQL Server 2022, Azure SQL Database, and Azure SQL Managed Instance.

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
| **2022** | All 16 skills | 5 Azure-specific checks silently skip on-premises |
| **2019** | All 16 skills | 23 SQL 2022-only checks (PSP, CE Feedback, Ledger, DOP Feedback, QS Hints) skip |
| **2017** | All 16 skills | Above + 12 SQL 2019 checks (ADR, Scalar UDF inlining, BMoR, LOG_RATE_GOVERNOR, TempDB metadata) skip |
| **2016** | All 16 skills | Above + 11 SQL 2017 checks (Interleaved Execution, STRING_AGG, QS wait stats, auto-tuning) skip |
| **2014** | 15 skills (no `query-store-review`) | Above + all QS checks; R21 fires (In-Memory OLTP available) |
| **2012** | 15 skills (no `query-store-review`) | Above + R21 (In-Memory OLTP not yet available) |
| **2008 R2** | 13 skills (no `hadr-health-review`, `clusterlog-review`, `query-store-review`) | Above + all HADR/cluster checks; Columnstore checks (I16, X23) |
| **Azure SQL DB** | `tsql-review`, `sqlstats-review`, `sqlplan-review`, `sqlplan-index-advisor`, `sqlplan-deadlock`, `sqlplan-batch`, `sqlplan-compare`, `query-store-review`, `procstats-review`, `sqltrace-review`, `sqlwait-review` | `hadr-health-review`, `clusterlog-review` not applicable; `spn-review` partial (K1–K31 not relevant for Entra-only auth) |
| **Azure SQL MI** | All 16 skills | `hadr-health-review`/`clusterlog-review` partial (MI uses managed HA, not all WSFC constructs apply) |
