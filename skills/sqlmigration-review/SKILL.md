---
name: sqlmigration-review
description: Audits a SQL Server migration plan with 15 checks (Y1-Y15) for version, edition, platform, and source-topology compatibility, then dispatches to sqlmigration-security-review, sqlmigration-objects-review, and other specialised skills for overlap areas. Use this skill when a user is planning, mid-flight on, or validating a SQL Server migration via backup/restore or log shipping/Always On seeding, mentions moving databases between instances/editions/versions, off a Failover Cluster Instance, or to Azure SQL, or asks "what breaks if I migrate to X". Trigger whenever migration readiness, cross-version compatibility, or cutover risk is the topic.
triggers:
  - /sqlmigration-review
  - /migration-review
  - /sql-migration-readiness
---

# sqlmigration-review

## Purpose

Reviews a planned or in-progress SQL Server migration for version, edition, and platform compatibility risk, then dispatches to companion skills for the object families a migration touches. This skill owns 15 checks (Y1–Y15) covering exactly one slice of migration risk — **does the target SQL Server version/edition/platform support what the source actually uses, and does the cutover plan account for the source's own topology** — and routes everything else:

- **Version & Edition Compatibility (Y1–Y6)** — edition-gated features, version downgrade risk, compatibility level ceiling, collation mismatch, discontinued features, In-Memory OLTP support
- **Platform Compatibility — Azure SQL (Y7–Y9)** — instance-scoped object support, Windows Authentication migration path, SQL Server Agent availability
- **Migration Mechanism Readiness (Y10–Y13)** — backup/restore chain integrity, recovery model, Always On AG edition limits for seeding
- **Lifecycle (Y14)** — source version support-end urgency
- **Source Topology Transition (Y15)** — Failover Cluster Instance client redirect planning

The [dbatools.io `Start-DbaMigration`](https://dbatools.io/Start-DbaMigration/) page is used only as a checklist of migration object types — every check and fix recipe in this skill family is built on native T-SQL system views, the in-box Microsoft `SqlServer` PowerShell module, and `sqlcmd`/`bcp`. No third-party PowerShell module is referenced or required.

For the security-object family (logins, permissions, credentials, certificates, CMS registrations), this skill dispatches to **`sqlmigration-security-review`** (15 checks, J1–J15). For the operational-object family (SQL Agent jobs, linked servers, Database Mail, backup devices, custom errors, server triggers, XE sessions, endpoints), it dispatches to **`sqlmigration-objects-review`** (16 checks, M1–M16). For overlap areas already covered by existing skills, it dispatches to those skills directly rather than duplicating checks.

## Input

Accepts any of the following:

1. **Source and target server facts pasted as text** — version, edition, platform, recovery model, database list
2. **Capture script output** (`.txt`/`.csv`) — see `scripts/capture-migration-facts.sql`
3. **Natural-language description** — "moving SalesDB from SQL 2014 Standard on-prem to SQL 2022 Enterprise via log shipping"
4. **File path to a directory of exported artifacts** — e.g., SSMS Generate Scripts output, `sp_helpdb`/`sp_helplogins` text dumps

Recommended capture (run on the **source** instance):

```sql
SELECT SERVERPROPERTY('ProductVersion') AS product_version,
       SERVERPROPERTY('Edition') AS edition,
       SERVERPROPERTY('EngineEdition') AS engine_edition;

SELECT name, compatibility_level, recovery_model_desc, collation_name,
       is_read_committed_snapshot_on
FROM sys.databases WHERE database_id > 4;

SELECT DISTINCT feature_name FROM sys.dm_db_persisted_sku_features;

SELECT t.name AS table_name, t.is_memory_optimized
FROM sys.tables t WHERE t.is_memory_optimized = 1;

SELECT database_name, type_desc, backup_start_date, backup_finish_date,
       differential_base_lsn, first_lsn, last_lsn
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -14, GETDATE())
ORDER BY backup_start_date DESC;
```

## Dispatch

| Object family | Routed to | Why not own checks |
|---|---|---|
| Logins, server/db permissions, credentials, certificates/keys ownership, CMS registrations | `sqlmigration-security-review` (J1–J15) | Distinct check-prefix family; large enough scope to warrant its own skill |
| SQL Agent jobs/operators/alerts/proxies, linked servers, Database Mail, backup devices, custom error messages, server triggers, XE sessions, endpoints | `sqlmigration-objects-review` (M1–M16) | Distinct check-prefix family; large enough scope to warrant its own skill |
| Always On AG topology, listener architecture, backup preference | `sqlag-review` (F1–F37) | Already a complete AG-configuration audit; Y13 only checks the edition ceiling for seeding, not AG design |
| AG replica health during/after migration cutover | `sqlhadr-review` (H1–H28, H21 retired) | Runtime health DMVs, not a configuration audit |
| Cross-domain authentication, SPN/Kerberos for the new instance name | `sqlspn-review` (K1–K40) | SPN/delegation is a complete domain of its own |
| TDE, certificate-protected backups, transport encryption | `sqlencryption-review` (A1–A112) | Encryption posture is a complete domain of its own |
| MAXDOP/Max Server Memory/TempDB sizing drift between source and target instance | `sqldbconfig-review` (B1–B28) | Instance configuration drift is a complete domain of its own |

When a user pastes mixed input that includes AG configuration, encryption DMV output, or SPN data alongside migration facts, note in the findings report which companion skill should be run on that slice rather than attempting to re-derive those checks here.

## Category 1 — Version & Edition Compatibility

### Y1 — Target Edition Cannot Support Source Feature In Use
**Trigger:** `sys.dm_db_persisted_sku_features` on the source returns one or more rows, and the stated target edition does not support that feature. This DMV reports exactly seven persisted, edition-gated features: `ChangeCapture`, `ColumnStoreIndex`, `Compression`, `MultipleFSContainers`, `InMemoryOLTP`, `Partitioning`, `TransparentDataEncryption`. (Features such as Always Encrypted secure enclaves, Online/Resumable Index Rebuild, and Resource Governor are edition-gated but are **not** reported by this DMV — verify those against the target's [Editions and supported features] page separately.)
**Severity:** Critical
**Fix:** Cross-reference `sys.dm_db_persisted_sku_features` on the source against the target edition's documented feature set before cutover; upgrade the target edition or redesign the dependent objects.

### Y2 — Target SQL Server Version Older Than Source
**Trigger:** Stated target product major version is lower than the source major version, for a backup/restore or log-shipping migration.
**Severity:** Critical
**Fix:** Native backup/restore and log shipping only restore to an equal or newer engine version; raise the target version or switch to a script-out/data-copy migration method instead.

### Y3 — Source Compatibility Level Exceeds Target's Maximum Supported Level
**Trigger:** Source database `compatibility_level` corresponds to a SQL Server version newer than the target instance's maximum supported compatibility level.
**Severity:** Critical
**Fix:** `ALTER DATABASE ... SET COMPATIBILITY_LEVEL` down to the target's ceiling before migrating, and retest plans — newer cardinality estimator and IQP behaviors will not be present after the downgrade.

### Y4 — Server Collation Mismatch Between Source and Target
**Trigger:** Source instance-level collation differs from the target instance's collation and the migration plan has no collation-aware testing step.
**Severity:** Warning
**Fix:** Database-level restore preserves the database's own collation, but cross-database joins against the new instance's `tempdb`/system databases can raise collation conflict errors; test cross-database queries explicitly and add `COLLATE` clauses where comparisons cross the boundary.

### Y5 — Source Uses a Feature Discontinued in the Target Version
**Trigger:** Source uses a feature already removed (discontinued) by the target SQL Server version's Database Engine. Detect via the **SQL Server, Deprecated Features** performance-counter object or the `deprecation_announcement` / `deprecation_final_support` Extended Events captured on the source — `sys.dm_db_persisted_sku_features` does **not** report discontinued/deprecated features and cannot be used for this check.
**Severity:** Critical
**Fix:** Identify the discontinued feature before migrating and rebuild the dependent functionality with the modern equivalent — do not discover this during cutover.

### Y6 — In-Memory OLTP / Memory-Optimized Objects Unsupported on Target
**Trigger:** Source has memory-optimized tables (`sys.tables.is_memory_optimized = 1`) or a memory-optimized filegroup, and the target edition/platform tier does not support In-Memory OLTP or has an insufficient memory-optimized data cap.
**Severity:** Critical
**Fix:** Confirm target edition's In-Memory OLTP support and size cap before migrating; convert memory-optimized tables to disk-based tables if the target cannot host them.

## Category 2 — Platform Compatibility (Azure SQL)

### Y7 — Azure SQL Database Target Cannot Host Source's Instance-Scoped Objects
**Trigger:** Target platform is Azure SQL Database (not Managed Instance) and the source relies on linked servers, cross-database three-part-name queries, FILESTREAM, or CLR with file system access. Detect FILESTREAM via `SERVERPROPERTY('FilestreamConfiguredLevel')` and `sys.master_files` (`type_desc = 'FILESTREAM'`), and user CLR via `sys.assemblies` (`is_user_defined = 1`) — both collected by `capture-migration-facts.sql` Query 10.
**Severity:** Critical
**Fix:** Re-platform instance-scoped dependencies before migrating: replace linked servers with Elastic Query or external tables, and cross-database queries with Elastic Query or database consolidation. FILESTREAM is not supported on Azure SQL Database (or Managed Instance); migrate BLOBs to `varbinary(max)` or external blob storage. Azure SQL Managed Instance retains linked servers/cross-database queries and SAFE CLR, so it does not require those changes.

### Y8 — Windows-Authenticated Logins Have No Migration Path to Azure SQL Database
**Trigger:** Target platform is Azure SQL Database and the source has on-premises Windows (AD NTLM/Kerberos) logins/users with no corresponding Microsoft Entra ID identity plan.
**Severity:** Critical
**Fix:** Azure SQL Database does not accept on-premises AD Windows authentication (NTLM/Kerberos) directly. It **does** support **Microsoft Entra Integrated** authentication (the modern "Windows Authentication") for Entra hybrid identities — members of an AD domain federated/synced with Microsoft Entra ID get seamless SSO. Sync the source Windows accounts to Microsoft Entra ID (Entra Connect) and create contained Entra users, or map to contained SQL authentication users; then update connection strings to use Entra auth.

### Y9 — Source Relies on SQL Server Agent but Target Has No Agent Service
**Trigger:** Target platform is Azure SQL Database (no Agent service) and the source has active SQL Server Agent jobs the application depends on.
**Severity:** Warning
**Fix:** Re-implement scheduled jobs using Azure Elastic Database Jobs, Azure Automation runbooks, or Azure Data Factory pipelines. Azure SQL Managed Instance retains Agent and does not require this change.

## Category 3 — Migration Mechanism Readiness

### Y10 — Backup Encryption Algorithm May Be Unsupported by Restore-Side Tooling
**Trigger:** The migration's backup is taken `WITH ENCRYPTION` and the target instance's SQL Server version predates support for the algorithm used (e.g., AES_256 backup encryption requires SQL Server 2014+ on the restoring side).
**Severity:** Warning
**Fix:** Confirm the target instance can `RESTORE` the backup's encryption algorithm before relying on it for cutover; re-take an unencrypted or compatible-algorithm backup otherwise.

### Y11 — Backup Chain Has a Differential or Log Gap Before Cutover
**Trigger:** Migration is backup-and-restore based, and `msdb.dbo.backupset` shows the most recent full backup predates a differential base reset, or a gap exists in the log chain (a backup's `last_lsn` does not match the next backup's `first_lsn`).
**Severity:** Critical
**Fix:** Take a fresh full backup immediately before cutover, or repair the chain with a differential backup against the current base, before relying on the restore sequence.

### Y12 — Source Database Recovery Model Incompatible With Log-Based Migration
**Trigger:** Migration mechanism is log shipping or Always On AG seeding, and the source database's `recovery_model_desc` is `SIMPLE`. Note the two mechanisms differ: **log shipping** supports `FULL` *or* `BULK_LOGGED`; **Always On AG** requires `FULL`. `SIMPLE` breaks both.
**Severity:** Critical
**Fix:** `ALTER DATABASE ... SET RECOVERY FULL` (required for AG; for log shipping `BULK_LOGGED` is also acceptable but switching to `SIMPLE` at any point breaks the chain) and take a new full backup to start the log chain — both mechanisms need an unbroken log chain from the initialization point forward.

### Y13 — Target Edition or Platform Cannot Support Always On AG Seeding
**Trigger:** Migration mechanism is Always On AG seeding, and either the target platform is Azure SQL Database (which cannot participate in an Always On Availability Group as a replica at all — it is not a clusterable instance), or the target edition is below Standard Edition, or the source's requirements (more than one database per AG, readable secondary) exceed Basic Availability Groups' limits.
**Severity:** Critical
**Fix:** If the target platform is Azure SQL Database, AG seeding is not a valid mechanism regardless of edition — switch to backup/restore, the Data Migration Assistant, or (if the broader feature set is required) retarget to Azure SQL Managed Instance, which does support standard Always On Availability Groups between Managed Instances, plus auto-failover groups for cross-region HA/DR (a separate geo-replication mechanism, not built on Always On AG technology — do not conflate the two when planning the target topology). If the target is on-prem/Managed Instance, use Enterprise Edition if more than one database must share an AG or a readable secondary is required; otherwise scope the migration to Basic AG's single-database, non-readable-secondary constraints — see `/sqlag-review` F29/F30 for the exact limits.

## Category 4 — Lifecycle

### Y14 — Source SQL Server Version Is Out of Support or Nearing End of Extended Security Updates
**Trigger:** Source product version corresponds to a SQL Server release whose mainstream or extended support end date has passed or is within 12 months, per the Microsoft SQL Server servicing lifecycle for the detected major version. (The support end *dates* are MS-documented in the [SQL Server lifecycle](https://learn.microsoft.com/sql/sql-server/end-of-support/sql-server-end-of-support-overview); the **12-month** warning window is an operational planning heuristic, not an MS-documented threshold — adjust it to your organization's migration lead time.)
**Severity:** Warning
**Fix:** Treat the migration as time-sensitive — schedule the cutover ahead of the support end date, or enroll in Extended Security Updates (on-premises or via Azure Arc) as a bridge if the migration cannot complete in time.

## Category 5 — Source Topology Transition

### Y15 — Failover Cluster Instance Source Retired Without a Client Redirect Plan
**Trigger:** Source instance is a SQL Server Failover Cluster Instance (FCI — detected via `SERVERPROPERTY('IsClustered') = 1` and a non-empty `sys.dm_os_cluster_nodes`, collected by `capture-migration-facts.sql` Query 9; clients connect via its Virtual Network Name/Client Access Point) and the target is not also that same FCI (e.g., target is a standalone instance or an Always On AG), and the migration plan has no documented step to repoint client connection strings, DNS, or load-balancer/listener configuration from the FCI's VNN to the new target's connection endpoint.
**Severity:** Critical
**Fix:** Inventory every application, linked server, reporting subscription, and ETL job connection string that references the FCI's VNN before cutover. For an AG target, repoint to the new AG listener DNS name (not a specific replica's hostname) — see `/sqlag-review` F14–F18 for listener/multi-subnet design. Where the number of call sites is large or undocumented, consider a DNS CNAME swap (retire the old VNN as an alias pointing to the new endpoint with a short TTL) to make the cutover atomic and the rollback fast, rather than chasing every connection string individually. Test resolution (`Resolve-DnsName`/`nslookup`) from each application tier before the go/no-go decision, not after.

## Output Format

```
## sqlmigration-review

### Summary
[2-3 sentences: source/target version+edition+platform, migration mechanism, headline risk count]

### Critical Issues
[Y-checks with Critical severity — each as: **Y# — Name**, evidence, impact, fix]

### Warnings
[Y-checks with Warning severity]

### Info
[Y-checks with Info severity, if any]

### Dispatch Recommendations
| Object family | Run next | Why |
|---|---|---|
[One row per companion skill that should be run on this migration, per the Dispatch table above]

### Passed Checks
[Y-checks evaluated and not fired]

### Not Assessed
[Y-checks that could not be evaluated because the required input was not provided]

### Migration Runbook
#### Phase 1 — Pre-Migration
[Native-tool checklist: capture facts, validate backup chain, resolve Critical findings above]

#### Phase 2 — Cutover
[Native-tool steps for the stated mechanism — backup/restore or log shipping/AG seeding]

#### Phase 3 — Validation
[Post-cutover checks: object counts, login mapping via sp_help_revlogin/ALTER USER ... WITH LOGIN, application connectivity]

#### Phase 4 — Rollback
[Conditions that trigger rollback and the native-tool steps to reverse cutover]

---
Analyzed by: [model name] · [date/time]
```

## Output Filters

- `--brief` — Summary + Critical Issues + Dispatch Recommendations only
- `--critical-only` — Critical Issues only

## Verbose Output (--verbose)

When `--verbose` is passed, also write `output/sqlmigration-review/<timestamp>-Y/analysis.md` (full report) and `trace.md` (which facts were available, which Y-checks were skipped and why).

## Notes

- This skill is strictly offline — it never connects to SQL Server; all checks evaluate pasted facts or capture-script output.
- Y-checks evaluate compatibility risk only. Object inventory and security review are out of scope by design — use the dispatched companion skills.
- `mssql-performance-review` does not route to this skill family; migration readiness is a distinct lifecycle phase from performance triage.

## Companion Skills

- **`sqlmigration-security-review`** — logins, permissions, credentials, certificate/key ownership, CMS registrations (J1–J15)
- **`sqlmigration-objects-review`** — SQL Agent jobs, linked servers, Database Mail, backup devices, custom errors, server triggers, XE sessions, endpoints (M1–M16)
- **`sqlag-review`** — Always On AG configuration audit for the target topology
- **`sqlhadr-review`** — AG replica runtime health during/after cutover
- **`sqlspn-review`** — SPN/Kerberos delegation for the renamed/relocated instance
- **`sqlencryption-review`** — TDE, certificate, and transport encryption posture on the target
- **`sqldbconfig-review`** — instance/database configuration drift between source and target
