# sqlmigration-review Check Explanations (Y1–Y14)

Plain-English explanations for all 14 checks. Load this file when a user asks "explain check
Y##", requests deeper fix options, or wants to understand why a threshold was chosen.

---

## Contents

- [Category 1 — Version & Edition Compatibility (Y1–Y6)](#category-1--version--edition-compatibility-y1y6)
- [Category 2 — Platform Compatibility — Azure SQL (Y7–Y9)](#category-2--platform-compatibility--azure-sql-y7y9)
- [Category 3 — Migration Mechanism Readiness (Y10–Y13)](#category-3--migration-mechanism-readiness-y10y13)
- [Category 4 — Lifecycle (Y14)](#category-4--lifecycle-y14)
- [Quick Reference Table](#quick-reference-table)

---

## Category 1 — Version & Edition Compatibility (Y1–Y6)

### Y1 — Target Edition Cannot Support Source Feature In Use

**What it means:** The source database persists evidence of using an edition-gated feature
(Always Encrypted with secure enclaves, partitioning on pre-2016 SP1 Standard, Online/Resumable
Online Index Rebuild, Change Data Capture). Several of these features are recorded by SQL
Server itself in `sys.dm_db_persisted_sku_features` so the engine can refuse to start the
database on an edition that no longer supports the feature it was built with.

**How to spot it:**
```sql
SELECT DISTINCT feature_name FROM sys.dm_db_persisted_sku_features;
```

**Example:**
```
-- Problem: source returns feature_name = 'Partitioning' from a SQL 2014 Standard database
-- Target stated as SQL 2016 RTM Standard — partitioning on Standard requires 2016 SP1+
-- Fix: confirm target is 2016 SP1 or later, or consolidate partitions before migrating
```

**Fix options:**
1. Cross-reference every returned `feature_name` against the target edition's documented
   feature matrix before cutover.
2. If the target edition cannot host the feature, either upgrade the target edition or redesign
   the dependent objects (e.g., drop partitioning, rebuild AE columns without enclaves).
3. Re-run the DMV against the database immediately before cutover — feature usage can change
   between planning and execution.

**Related checks:** Y5 (discontinued features), Y6 (In-Memory OLTP, the most common edition-gated
feature for OLTP workloads)

---

### Y2 — Target SQL Server Version Older Than Source

**What it means:** Native backup/restore and log shipping/AG seeding can only move a database
forward to an equal-or-newer engine version — the on-disk page format and metadata are not
guaranteed backward-readable. A stated target major version below the source major version
makes the chosen migration mechanism impossible, regardless of how clean the rest of the plan is.

**How to spot it:** Compare `SERVERPROPERTY('ProductVersion')` major version on source vs. the
stated/observed target major version.

**Example:**
```
-- Problem: Source = SQL Server 2019 (15.x), Target = SQL Server 2016 (13.x)
-- RESTORE DATABASE will fail with:
-- Msg 3169: "The database was backed up on a server running version 15.00.xxxx.
--            That version is incompatible with this server, which is running version 13.00.xxxx."
```

**Fix options:**
1. Raise the target version to match or exceed the source.
2. If downgrading the version is a hard requirement, switch migration mechanism entirely —
   script out objects and `bcp`/`INSERT ... SELECT` the data, since backup/restore and log
   shipping cannot cross this boundary in either direction.

**Related checks:** Y3 (compatibility level ceiling — a related but distinct constraint that can
still block a same-or-newer-version migration)

---

### Y3 — Source Compatibility Level Exceeds Target's Maximum Supported Level

**What it means:** `compatibility_level` is independent of the physical backup format — a
database can be restored onto a newer engine while still running an older compatibility level.
The problem is the reverse: if the source database's compatibility level corresponds to a SQL
Server version *newer* than the target instance supports, `RESTORE DATABASE` succeeds but the
database will not run at that level, and query plans, cardinality estimation, and IQP behavior
silently change.

**How to spot it:**
```sql
SELECT name, compatibility_level FROM sys.databases WHERE database_id > 4;
-- Compare against target instance's maximum supported compatibility_level
```

**Example:**
```
-- Problem: Source database compatibility_level = 160 (SQL 2022), target instance is SQL 2019
--          (max supported compatibility_level = 150)
-- RESTORE succeeds, but SQL Server silently caps the database to 150
ALTER DATABASE [SalesDB] SET COMPATIBILITY_LEVEL = 150;
```

**Fix options:**
1. Explicitly set the compatibility level down to the target's ceiling before migrating, rather
   than relying on the engine's silent cap.
2. Re-test query plans after the downgrade — newer cardinality estimator and Intelligent Query
   Processing features tied to the higher level will no longer apply.

**Related checks:** Y2 (engine version itself, the harder boundary)

---

### Y4 — Server Collation Mismatch Between Source and Target

**What it means:** A database-level restore preserves the source database's own collation
regardless of the target instance's collation. The risk surfaces only when queries compare or
join across the database boundary against `tempdb` or other databases on the new instance,
which use the *instance's* collation — a mismatch there raises collation conflict errors that
did not exist on the source.

**How to spot it:** Compare instance-level collation (`SERVERPROPERTY('Collation')`) between
source and target.

**Example:**
```sql
-- Problem: Source instance collation = SQL_Latin1_General_CP1_CI_AS
--          Target instance collation = Latin1_General_100_CI_AS_SC
-- A query joining a restored table against #temp_table built in the new tempdb fails with:
-- Msg 468: "Cannot resolve the collation conflict..."
-- Fix: add explicit COLLATE clauses at the comparison
SELECT * FROM dbo.Orders o
JOIN #temp t ON o.CustomerCode = t.CustomerCode COLLATE SQL_Latin1_General_CP1_CI_AS;
```

**Fix options:**
1. Inventory all cross-database/tempdb comparisons before cutover (stored procedures using
   temp tables with string joins are the most common source).
2. Add `COLLATE` clauses at each identified comparison point, or standardize on the target's
   collation for newly created application-side temp objects.
3. Test explicitly post-restore rather than waiting for a production error.

**Related checks:** none — this is the only collation-specific check in this skill family.

---

### Y5 — Source Uses a Feature Discontinued in the Target Version

**What it means:** SQL Server periodically removes entire engine features outright (not just
edition-gates them). A feature present and in active use on the source simply does not exist on
the target version, and restoring the database does not fail — the failure surfaces later, at
first use, often in production.

**How to spot it:** Cross-reference `sys.dm_db_persisted_sku_features` output and any captured
deprecated-feature-usage Extended Events trace against the list of features the target major
version has removed (per the Microsoft documentation for that release).

**Example:**
```
-- Problem: Source uses SQL Server 2008-era SQL Mail; target is SQL Server 2017+
--          (SQL Mail was removed; Database Mail is the only supported replacement)
-- Restoring the database succeeds; the first sp_send_dbmail-equivalent call referencing
-- the old feature fails at runtime.
```

**Fix options:**
1. Capture deprecated-feature-usage Extended Events on the source ahead of migration planning,
   not just at cutover time.
2. Rebuild the dependent functionality using the modern equivalent before migrating, and test it
   against the source before cutover so the replacement is proven, not improvised under deadline.

**Related checks:** Y1 (edition-gated, still-supported features — a different failure mode than
fully discontinued features)

---

### Y6 — In-Memory OLTP / Memory-Optimized Objects Unsupported on Target

**What it means:** Memory-optimized tables and filegroups depend on edition and platform-tier
support for In-Memory OLTP, plus a memory-optimized data size cap that varies by edition/tier.
A target that lacks the feature or has an insufficient cap cannot host the database without
redesign.

**How to spot it:**
```sql
SELECT t.name AS table_name, t.is_memory_optimized
FROM sys.tables t WHERE t.is_memory_optimized = 1;
```

**Example:**
```
-- Problem: Source has 3 memory-optimized tables; target is Azure SQL Database Basic/Standard
--          tier, which does not support In-Memory OLTP at that tier
-- Fix: move to a tier with In-Memory OLTP support, or convert tables to disk-based
ALTER TABLE dbo.SessionState SET (MEMORY_OPTIMIZED = OFF); -- conceptual; requires table rebuild
```

**Fix options:**
1. Confirm the target edition/tier's In-Memory OLTP support and memory-optimized data cap before
   migrating.
2. If unsupported or under-capacity, convert memory-optimized tables to disk-based tables ahead
   of cutover and validate the workload still meets latency requirements without the in-memory
   engine.

**Related checks:** Y1 (other edition-gated features), Y7 (Azure SQL Database platform limits
generally)

---

## Category 2 — Platform Compatibility (Azure SQL) (Y7–Y9)

### Y7 — Azure SQL Database Target Cannot Host Source's Instance-Scoped Objects

**What it means:** Azure SQL Database (the single-database PaaS tier, not Managed Instance) has
no concept of "the instance" the way on-premises SQL Server does — there are no linked servers,
no cross-database three-part-name queries, no FILESTREAM, and CLR cannot touch the file system.
Source databases that depend on any of these have no migration path to Azure SQL Database
without re-platforming.

**How to spot it:** Source uses linked servers (`sys.servers` with `is_linked = 1`), three-part
or four-part name queries across databases, FILESTREAM filegroups, or CLR assemblies with
`PERMISSION_SET = UNSAFE`/file I/O.

**Example:**
```
-- Problem: Stored procedure references [OtherDB].[dbo].[Lookup] — cross-database query
-- Azure SQL Database cannot resolve a three-part name to a different database on the
-- same logical server the way on-prem SQL Server can.
-- Fix: replace with Elastic Query external table, or consolidate both databases.
```

**Fix options:**
1. Replace linked servers with Elastic Query or external tables.
2. Replace cross-database queries with Elastic Query, or consolidate the databases if they must
   remain tightly coupled.
3. Re-platform FILESTREAM data to Azure Blob Storage with application-side references.
4. If these dependencies are extensive, target Azure SQL Managed Instance instead — it retains
   instance-scoped behavior and does not require this rework.

**Related checks:** Y8 (auth path), Y9 (Agent dependency) — all three Y7–Y9 checks share the same
root cause: Azure SQL Database is not "SQL Server in the cloud," it is a different platform tier.

---

### Y8 — Windows-Authenticated Logins Have No Migration Path to Azure SQL Database

**What it means:** Azure SQL Database does not support Windows Authentication at all. Every
Windows-authenticated login and the database users mapped to it need an explicit migration
target — either a Microsoft Entra ID (formerly Azure AD) identity or a converted SQL
authentication user — or the application cannot connect after cutover.

**How to spot it:** Source has logins with `type_desc = 'WINDOWS_LOGIN'` or
`'WINDOWS_GROUP'` that map to database users the application actually uses.

**Example:**
```sql
-- Problem: sp_helplogins shows DOMAIN\svc_app as WINDOWS_LOGIN, used by the app's connection string
-- Azure SQL Database fix: create a Microsoft Entra ID-backed user instead
CREATE USER [svc_app@yourtenant.onmicrosoft.com] FROM EXTERNAL PROVIDER;
```

**Fix options:**
1. Map each Windows login to a Microsoft Entra ID user or group (preferred — preserves
   group-based access patterns).
2. Where Entra ID is not feasible, convert to a contained SQL authentication user with a new
   password, and update the application's connection string and secret store accordingly.
3. Test connectivity end-to-end before cutover — this is a connection-string change, not just a
   server-side change.

**Related checks:** Y7 (instance-scoped objects), Y9 (Agent) — and `sqlmigration-security-review`
for the rest of the login/permission migration beyond this one Azure-specific gap.

---

### Y9 — Source Relies on SQL Server Agent but Target Has No Agent Service

**What it means:** Azure SQL Database has no SQL Server Agent service. Scheduled jobs the
application depends on (maintenance, ETL triggers, alerting) simply do not run after cutover
unless re-implemented on an Azure-native scheduler.

**How to spot it:** Source has active jobs in `msdb.dbo.sysjobs` (`enabled = 1`) and the target
platform is stated as Azure SQL Database.

**Example:**
```
-- Problem: Job "Nightly_Reindex" runs sp_executesql maintenance against SalesDB nightly
-- Azure SQL Database has no Agent; the job has no execution context after migration.
-- Fix: re-implement as an Azure Elastic Database Job or Azure Automation runbook.
```

**Fix options:**
1. Re-implement scheduled work as Azure Elastic Database Jobs (closest conceptual match to
   Agent jobs running T-SQL against the database).
2. Use Azure Automation runbooks for jobs that orchestrate beyond pure T-SQL.
3. Use Azure Data Factory pipelines for ETL-style jobs that move or transform data.
4. If Agent dependency is heavy and re-implementation is too costly, target Azure SQL Managed
   Instance instead, which retains Agent.

**Related checks:** Y7, Y8 — and `sqlmigration-objects-review` for full job/operator/alert/proxy
inventory and migration detail.

---

## Category 3 — Migration Mechanism Readiness (Y10–Y13)

### Y10 — Backup Encryption Algorithm May Be Unsupported by Restore-Side Tooling

**What it means:** Encrypted native backups (`BACKUP ... WITH ENCRYPTION`) record the algorithm
used, and not every restoring-side SQL Server version can decrypt every algorithm — most notably
AES_256 requires SQL Server 2014 or later on the side performing the `RESTORE`. If the migration
plan relies on this backup for cutover, confirming restore-side support ahead of time avoids a
cutover-day surprise.

**How to spot it:**
```sql
SELECT is_password_protected, key_algorithm, encryptor_type
FROM msdb.dbo.backupset WHERE database_name = 'SalesDB'
ORDER BY backup_start_date DESC;
```

**Example:**
```
-- Problem: Backup taken WITH ENCRYPTION using AES_256; target instance is SQL Server 2012
--          (AES_256 backup encryption requires 2014+ on the restoring side)
-- RESTORE DATABASE fails or rejects the encrypted backup set.
```

**Fix options:**
1. Confirm the target instance's version supports the recorded encryption algorithm before
   relying on this backup for cutover.
2. If unsupported, take a fresh, compatible-algorithm (or unencrypted, if policy allows)
   backup, or transport the encrypted backup file securely and decrypt/restore on a
   version that supports it before moving it to its final location.

**Related checks:** Y11 (backup chain integrity, the more common backup-based blocker)

---

### Y11 — Backup Chain Has a Differential or Log Gap Before Cutover

**What it means:** A backup/restore migration replays a full backup, optionally a differential,
and then a sequence of log backups. If the differential's base LSN doesn't match the current
full backup, or if one log backup's `last_lsn` doesn't connect to the next log backup's
`first_lsn`, the restore sequence cannot reach a consistent, up-to-date state at cutover.

**How to spot it:**
```sql
SELECT database_name, type_desc, backup_start_date, backup_finish_date,
       differential_base_lsn, first_lsn, last_lsn
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -14, GETDATE())
ORDER BY backup_start_date DESC;
```

**Example:**
```
-- Problem: Differential backup's differential_base_lsn does not match the most recent
--          full backup's checkpoint_lsn — the differential base was reset by an
--          intervening full backup the migration plan didn't account for.
-- Fix: take a fresh full backup immediately before cutover to re-anchor the chain.
BACKUP DATABASE [SalesDB] TO DISK = N'\\BACKUP\SalesDB_full_precutover.bak' WITH COMPRESSION;
```

**Fix options:**
1. Take a fresh full backup immediately before cutover if any gap is detected, restarting the
   chain cleanly.
2. If a gap is in the log chain specifically, take a new differential against the current full
   backup to repair it without needing a brand-new full backup.
3. Validate the chain with `RESTORE VERIFYONLY` and a `RESTORE ... WITH NORECOVERY` dry run in a
   non-production environment before the real cutover.

**Related checks:** Y12 (recovery model — a prerequisite for an unbroken log chain existing at
all)

---

### Y12 — Source Database Not in FULL Recovery Model for Log-Based Migration

**What it means:** Log shipping and Always On AG seeding both require an unbroken, continuously
shippable transaction log from the chosen initialization point forward. SIMPLE recovery
truncates the log at checkpoints, and BULK_LOGGED recovery can produce a log backup that cannot
be safely replayed for point-in-time continuity — neither is compatible with these two
mechanisms.

**How to spot it:**
```sql
SELECT name, recovery_model_desc FROM sys.databases WHERE database_id > 4;
```

**Example:**
```
-- Problem: SalesDB shows recovery_model_desc = 'SIMPLE'; migration mechanism is log shipping
-- Fix:
ALTER DATABASE [SalesDB] SET RECOVERY FULL;
BACKUP DATABASE [SalesDB] TO DISK = N'\\BACKUP\SalesDB_full.bak' WITH COMPRESSION;
-- Log shipping/AG seeding can only begin from this new full backup forward
```

**Fix options:**
1. Switch to FULL recovery and take a new full backup to start the log chain — this is
   mandatory, not optional, for either mechanism.
2. Re-baseline any existing log shipping or AG seeding plan to start from the new full backup,
   since backups taken before the recovery model change cannot be used to seed the log chain.

**Related checks:** Y11 (backup chain integrity for the backup/restore mechanism), Y13 (AG
seeding edition limits)

---

### Y13 — Target Edition Lacks Always On Availability Group Capacity Needed for Seeding

**What it means:** Always On Availability Groups require at least Standard Edition; Standard
Edition's Basic Availability Groups are further capped at one database per AG with no readable
secondary. A migration plan that seeds via AG but needs more than one database in the AG or a
readable secondary needs Enterprise Edition on the target, regardless of how well everything
else in the plan is prepared.

**How to spot it:** Compare the stated target edition against the AG topology the migration plan
assumes (number of databases per AG, whether a readable secondary is required).

**Example:**
```
-- Problem: Migration plan seeds 3 databases into one AG on SQL Server 2019 Standard Edition
-- Basic Availability Groups (Standard Edition) support exactly 1 database per AG
-- Fix: either split into 3 separate Basic AGs, or use Enterprise Edition for one AG with 3 DBs
```

**Fix options:**
1. Use Enterprise Edition on the target if more than one database must share an AG, or if a
   readable secondary is required for the migration's intended use (e.g., offloading reporting
   immediately after cutover).
2. Otherwise, scope the plan to Basic AG's single-database, non-readable-secondary constraints —
   one Basic AG per database.
3. See `/sqlag-review` checks F29/F30 for the exact Basic AG limits and how they're detected from
   live configuration once the AG exists.

**Related checks:** Y12 (recovery model prerequisite for any log-based seeding) — and
`sqlag-review` for full AG topology/listener/backup-preference design beyond this edition-ceiling
check.

---

## Category 4 — Lifecycle (Y14)

### Y14 — Source SQL Server Version Is Out of Support or Nearing End of Extended Security Updates

**What it means:** Every SQL Server major version has a published mainstream and extended
support end date. A source version whose support window has already closed, or is closing soon,
turns the migration from a planned project into a time-sensitive one — security patches stop
(or already have), and waiting too long to cut over removes the option to patch known
vulnerabilities on the source while the migration is still in flight.

**How to spot it:** Compare the source's detected major version against the Microsoft SQL Server
servicing lifecycle dates for that release.

**Example:**
```
-- Problem: Source is SQL Server 2014 (extended support ended July 2024)
-- The source instance currently receives no security updates from Microsoft.
-- Fix: prioritize this migration ahead of less time-sensitive work; consider Extended
--      Security Updates as a bridge if the cutover cannot complete before further patches
--      would be needed.
```

**Fix options:**
1. Schedule the cutover ahead of (or as close as possible after) the support end date, treating
   this migration with higher priority than its technical risk alone would suggest.
2. If the migration cannot complete before the support boundary, enroll in Extended Security
   Updates — available on-premises via a volume licensing agreement, or via Azure Arc for
   Arc-enabled servers — as a temporary bridge, not a long-term substitute for migrating.

**Related checks:** none — this is a standalone lifecycle/urgency signal rather than a technical
compatibility blocker.

---

## Quick Reference Table

| Check | Category | Trigger Summary | Severity |
|-------|----------|----------------|----------|
| Y1 | Version & Edition | Edition-gated feature in `sys.dm_db_persisted_sku_features` unsupported on target | Critical |
| Y2 | Version & Edition | Target major version lower than source | Critical |
| Y3 | Version & Edition | Source compatibility_level exceeds target's max supported level | Critical |
| Y4 | Version & Edition | Server collation mismatch, no cross-DB testing planned | Warning |
| Y5 | Version & Edition | Source uses a feature discontinued on target | Critical |
| Y6 | Version & Edition | Memory-optimized objects unsupported/under-capped on target | Critical |
| Y7 | Platform (Azure) | Azure SQL Database target with instance-scoped dependencies | Critical |
| Y8 | Platform (Azure) | Windows-auth logins with no Entra ID/SQL auth migration plan | Critical |
| Y9 | Platform (Azure) | Azure SQL Database target with active Agent job dependency | Warning |
| Y10 | Mechanism Readiness | Encrypted backup algorithm unsupported by restore-side version | Warning |
| Y11 | Mechanism Readiness | Differential/log chain gap in `msdb.dbo.backupset` | Critical |
| Y12 | Mechanism Readiness | Source not in FULL recovery for log-based migration | Critical |
| Y13 | Mechanism Readiness | Target edition below AG seeding requirements | Critical |
| Y14 | Lifecycle | Source version support end date passed or within 12 months | Warning |
