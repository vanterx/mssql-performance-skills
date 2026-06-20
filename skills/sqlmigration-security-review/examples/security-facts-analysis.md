# sqlmigration-security-review Example Analysis

**Input:** `security-facts-input.txt` — SalesDB migrated via backup/restore; logins manually
recreated with `CREATE LOGIN ... WITH PASSWORD` rather than `sp_help_revlogin`.

---

## sqlmigration-security-review

### Summary
2 logins (AppUser, AppReporting) are now orphaned database users on the target because they were
manually recreated rather than scripted with matching SIDs. Both server-role and database-role
membership, plus an explicit DENY, were not re-applied. 3 Critical issues and 1 Warning found.

### Critical Issues

**J2 — SQL Authentication Login SID Mismatch Risk**
- **Evidence:** Logins were recreated using `CREATE LOGIN [AppUser] WITH PASSWORD = 'TempPass123!'`.
- **Impact:** This generates a brand-new SID for each login, regardless of matching names and
  passwords, which is the direct cause of the orphaned users below (J1).
- **Fix:** Re-run login creation using `sp_help_revlogin`'s output from the source instance,
  which preserves the original SID and hashed password.

**J1 — Orphaned Database User After Restore**
- **Evidence:** `AppUser` and `AppReporting` both show `login_name = NULL` in the post-restore
  database-principals-to-server-principals join.
- **Impact:** Both users can no longer authenticate; the application's connection pool will
  receive login failures or "user does not exist" errors despite the database object being
  present and intact.
- **Fix:**
  ```sql
  DROP LOGIN [AppUser]; DROP LOGIN [AppReporting];
  -- Run sp_help_revlogin-generated CREATE LOGIN statements from the source instead
  ALTER USER [AppUser] WITH LOGIN = [AppUser];
  ALTER USER [AppReporting] WITH LOGIN = [AppReporting];
  ```

**J6 — Server-Level Role Membership Not Re-Created**
- **Evidence:** Source `sys.server_role_members` shows `AppUser` is a member of `dbcreator`.
- **Impact:** Once logins are correctly recreated, `AppUser` will still lack `dbcreator` until
  this membership is explicitly re-granted — any deployment automation relying on `AppUser`
  creating databases will fail with permission errors that look unrelated to the login fix.
- **Fix:**
  ```sql
  ALTER SERVER ROLE [dbcreator] ADD MEMBER [AppUser];
  ```

### Warnings

**J7 — Database Role Membership Lost on User Recreation**
- **Evidence:** Source `sys.database_role_members` shows `AppReporting` is a member of
  `db_datareader`.
- **Impact:** After J1's `ALTER USER ... WITH LOGIN` fix, `AppReporting` regains login
  connectivity but not its `db_datareader` membership, producing read-permission failures.
- **Fix:**
  ```sql
  ALTER ROLE [db_datareader] ADD MEMBER [AppReporting];
  ```

### Info
(none fired)

### Passed Checks
- **J3** — No login type/platform mismatch; target is on-premises SQL Server 2019, same login
  types supported.
- **J4** — `is_policy_checked`/`is_expiration_checked` are both 1 on source; no domain-policy
  discontinuity stated for the target.
- **J5** — Default database `SalesDB` is in scope and migrating with the same name.
- **J8** — Explicit DENY on `SalaryDetails` was captured in the input (see Migration Script
  Checklist below) — flagged for inclusion, not missing from capture.
- **J9** — No cross-database dependency evidence in the captured facts.
- **J10, J11, J12** — No credentials, proxies, or linked-server logins present.
- **J13, J14** — No certificates or database master key present in the captured facts.
- **J15** — No CMS registration information provided; not applicable to this input.

### Not Assessed
- None — all facts needed for the provided input were present; J15 was evaluated as not
  applicable rather than unassessed since CMS is out of scope for this particular migration
  (no CMS host mentioned).

### Login/Permission Migration Script Checklist
1. Drop the two incorrectly created logins (`AppUser`, `AppReporting`).
2. Run `sp_help_revlogin` on the source; execute its output on the target.
3. `ALTER USER [AppUser] WITH LOGIN = [AppUser];` and the same for `AppReporting`.
4. `ALTER SERVER ROLE [dbcreator] ADD MEMBER [AppUser];`
5. `ALTER ROLE [db_datareader] ADD MEMBER [AppReporting];`
6. `DENY SELECT ON dbo.SalaryDetails TO [AppReporting];` — re-apply the explicit DENY captured
   from the source; this is not implied by the `db_datareader` grant and must be scripted
   separately.

---
Analyzed by: Claude Sonnet 4.6 · 2026-06-20
