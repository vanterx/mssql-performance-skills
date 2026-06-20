# sqlmigration-review Example Analysis

**Input:** `migration-facts-input.txt` — SalesDB + OrdersDB moving from SQL Server 2014
Enterprise (on-prem) to SQL Server 2019 Standard (on-prem) via Always On AG seeding into a
single new AG, "SalesAG".

---

## sqlmigration-review

### Summary
Source is SQL Server 2014 Enterprise Edition (on-prem); target is SQL Server 2019 Standard
Edition (on-prem); migration mechanism is Always On AG seeding for 2 databases into one AG.
3 Critical issues and 2 Warnings were found — the edition downgrade from Enterprise to Standard
is the headline risk, since it breaks both an in-use feature and the AG topology the plan
assumes.

### Critical Issues

**Y1 — Target Edition Cannot Support Source Feature In Use**
- **Evidence:** `sys.dm_db_persisted_sku_features` on the source returns `Partitioning` and
  `OnlineIndexOperation`.
- **Impact:** Both features are Enterprise-only. SQL Server 2019 Standard Edition cannot host a
  database that depends on table/index partitioning or Online Index Rebuild — the database will
  not come online on the target, or the dependent maintenance jobs will fail post-cutover.
- **Fix:** Before migrating, either consolidate partitioned tables into non-partitioned tables
  and switch index maintenance to offline rebuilds, or upgrade the target to Enterprise Edition.

**Y13 — Target Edition Lacks Always On Availability Group Capacity Needed for Seeding**
- **Evidence:** Target is Standard Edition; migration plan seeds 2 databases (SalesDB, OrdersDB)
  into one AG ("SalesAG").
- **Impact:** Standard Edition only supports Basic Availability Groups, capped at exactly 1
  database per AG. The plan as stated cannot be executed against a Standard Edition target.
- **Fix:** Use Enterprise Edition on the target to host both databases in one AG, or create two
  separate Basic AGs (one per database) if Standard Edition must be retained. See
  `/sqlag-review` F29/F30 for the exact Basic AG limits.

**Y14 — Source SQL Server Version Is Out of Support**
- **Evidence:** Source is SQL Server 2014; extended support for SQL Server 2014 ended July 9,
  2024 — already passed as of the current date.
- **Impact:** The source instance receives no security updates from Microsoft while this
  migration is in flight.
- **Fix:** Treat this migration as time-sensitive and prioritize the cutover; if it cannot
  complete promptly, enroll in Extended Security Updates (on-premises volume licensing or Azure
  Arc) as a bridge.

### Warnings

**Y4 — Server Collation Mismatch Between Source and Target**
- **Evidence:** Source server collation is `SQL_Latin1_General_CP1_CI_AS`; target server
  collation is `Latin1_General_100_CI_AS_SC`. OrdersDB's own database collation
  (`Latin1_General_100_CI_AS_SC`) already matches the target, but SalesDB's database collation
  (`SQL_Latin1_General_CP1_CI_AS`) does not.
- **Impact:** SalesDB's collation is preserved on restore/seed, but any query joining SalesDB
  data against `tempdb` objects or against OrdersDB on the new instance can raise a collation
  conflict that did not exist on the source.
- **Fix:** Test cross-database and tempdb-joining queries explicitly after seeding; add
  `COLLATE` clauses at the comparison points identified.

**Y9 — Source Relies on SQL Server Agent but Target Has No Agent Service**
- **Evidence:** `Nightly_Reindex` job is enabled on the source.
- **Impact:** Not applicable as stated — the target is on-premises SQL Server 2019 Standard,
  which retains SQL Server Agent. This check is included here only to show it does not fire for
  on-prem targets; it would fire if the target were instead Azure SQL Database.
- **Fix:** No action needed for this on-prem target. Re-evaluate if the target platform changes.

*(Note: Y9 is listed under Warnings in the trigger table but evaluates to Not Fired for this
on-premises target — included here for illustration of the Azure-only trigger condition.)*

### Passed Checks
- **Y2** — Target version (2019) is newer than source (2014); supported direction for both
  backup/restore and AG seeding.
- **Y3** — Source compatibility level (120) is well within target's maximum supported level
  (150 for SQL Server 2019).
- **Y5** — No discontinued-feature usage identified in the captured facts.
- **Y6** — No memory-optimized tables present on the source.
- **Y7, Y8** — Not applicable; target platform is on-premises SQL Server, not Azure SQL Database.
- **Y10** — No backup encryption in use (`is_password_protected = 0`, `key_algorithm = NULL`).
- **Y11** — No differential or log chain gap identified; full backups for both databases are
  current and self-consistent.
- **Y12** — Both SalesDB and OrdersDB are already in FULL recovery model, satisfying the
  prerequisite for AG seeding.

### Not Assessed
- None — all 14 Y-checks were evaluated against the captured input.

### Dispatch Recommendations
| Object family | Run next | Why |
|---|---|---|
| Always On AG topology, listener design | `/sqlag-review` | Confirms the new SalesAG's replica, listener, and backup-preference design once the edition decision (Y13) is resolved |
| Windows-authenticated login `DOMAIN\svc_app` | `/sqlmigration-security-review` | Maps Windows logins and their permissions to the target instance |
| SQL Agent job `Nightly_Reindex` | `/sqlmigration-objects-review` | Confirms job step compatibility and re-creates the job definition on the target |

### Migration Runbook

#### Phase 1 — Pre-Migration
1. Resolve Y1 and Y13 first — they block the stated plan outright. Decide between upgrading the
   target to Enterprise Edition or redesigning the AG topology and removing partitioning/Online
   Index Rebuild dependency.
2. Re-run `scripts/capture-migration-facts.sql` on the source immediately before cutover to
   confirm no new edition-gated features have been introduced since planning.
3. Confirm both databases remain in FULL recovery model (already true; re-verify at T-1 day).

#### Phase 2 — Cutover
1. Create the target AG topology decided in Phase 1 (`CREATE AVAILABILITY GROUP`), using
   `sqlcmd`/SSMS native tooling.
2. Seed each database via automatic seeding or manual backup/restore-based seeding, per the
   topology chosen.
3. Join both databases to the AG and confirm `JOINED` state on the secondary via
   `sys.dm_hadr_database_replica_states`.

#### Phase 3 — Validation
1. Confirm object counts and row counts match between source and target for both databases.
2. Re-map `DOMAIN\svc_app` and any other migrated logins via `ALTER USER ... WITH LOGIN` or
   `sp_help_revlogin`-generated scripts, and test application connectivity end-to-end.
3. Confirm `Nightly_Reindex` (or its redesigned replacement, if Online Index Rebuild was removed)
   runs successfully on the new target.

#### Phase 4 — Rollback
1. If validation fails within the cutover window, fail back application connections to the
   original SQL Server 2014 source — do not remove the source AG/databases until the target has
   been confirmed stable for a full business cycle.
2. If the edition decision (Y13) was Enterprise upgrade and licensing falls through mid-cutover,
   halt before seeding and re-plan with the Basic AG topology instead.

---
Analyzed by: Claude Sonnet 4.6 · 2026-06-20
