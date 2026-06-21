# sqlmigration-objects-review Example Analysis

**Input:** `objects-facts-input.txt` — on-prem-to-on-prem migration, US Eastern → UTC time zone
change, `SalesDB` renamed to `Sales` on the target.

---

## sqlmigration-objects-review

### Summary
One Agent job (`Nightly_ETL`) is in scope, with a job step referencing the pre-rename database
name, an unresolved owner login, a proxy account whose credential migration status is unverified,
and a schedule tuned for the source time zone. 3 Critical issues and 2 Warnings found.

### Critical Issues

**M1 — Agent Job References a Database Not in Migration Scope**
- **Evidence:** Job step `LoadSalesData` in `Nightly_ETL` specifies `database_name = 'SalesDB'`;
  the database is being renamed to `Sales` on the target.
- **Impact:** The job step will fail with "database does not exist" immediately after cutover,
  since `SalesDB` will not be a valid database name on the target.
- **Fix:**
  ```sql
  EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'Nightly_ETL', @step_id = 1, @database_name = N'Sales';
  ```

**M2 — Job Owner Login Does Not Exist on Target**
- **Evidence:** `Nightly_ETL`'s owner SID resolves to `NULL` against the target's
  `sys.server_principals` — the owning login (`AppUser`) has not yet been migrated, or was
  migrated with a mismatched SID.
- **Impact:** Job ownership cannot be displayed or managed correctly until this resolves; some
  job operations may fail outright depending on SQL Server version behavior for unresolved owner
  SIDs.
- **Fix:** Confirm `AppUser` exists on the target with the correct SID (see
  `/sqlmigration-security-review` J1/J2), then:
  ```sql
  EXEC msdb.dbo.sp_update_job @job_name = N'Nightly_ETL', @owner_login_name = N'AppUser';
  ```

**M4 — Alert Tied to an Error Number Not Raised on Target Configuration**
- **Evidence:** `ETL_Failure_Alert` fires on `message_id = 50001`, but the captured custom error
  message inventory (Query 10) returns no rows — message 50001 has not been added to the target
  via `sp_addmessage`.
- **Impact:** The alert is defined but will never fire, since the underlying message it watches
  for does not exist on the target. ETL failures will go silent.
- **Fix:** Identify the original `sp_addmessage` definition for 50001 from the source and add it
  to the target before relying on this alert:
  ```sql
  EXEC sp_addmessage @msgnum = 50001, @severity = 16,
    @msgtext = N'<original message text from source>', @lang = 'us_english';
  ```

### Warnings

**M5 — Proxy Account Migrated Without Matching Credential**
- **Evidence:** Job step `LoadSalesData` uses proxy `BlobProxy`; no credential migration status
  was captured in this input.
- **Impact:** If `BlobProxy`'s backing credential was not migrated, or was migrated after the
  proxy with a stale `credential_id`, the job step will fail at runtime with an authentication
  error that looks unrelated to the migration.
- **Fix:** Confirm via `/sqlmigration-security-review` (checks J10/J11) that the credential exists
  on the target and that the proxy was created after it, resolving `credential_id` by name.

**M6 — Job Schedule Assumes Source Server's Time Zone**
- **Evidence:** Schedule `Nightly_2200` has `active_start_time = 220000` (10 PM), tuned for the
  source's US Eastern time zone; target server runs in UTC.
- **Impact:** Without adjustment, the job will run at 10 PM UTC (6 PM US Eastern), four hours
  earlier than intended — likely before the business-close event the schedule was designed to
  follow.
- **Fix:**
  ```sql
  EXEC msdb.dbo.sp_update_schedule @name = N'Nightly_2200', @active_start_time = 020000;
  -- 2 AM UTC = 10 PM US Eastern (EST); re-verify against EDT/EST seasonally if DST matters
  ```

### Info
(none fired)

### Passed Checks
- **M3** — Operator `DBA_Team`'s notification address was not flagged as unverified in this
  input; no evidence of a mail-path change beyond what M10/M11 already cover.
- **M7, M8, M9** — No linked servers present.
- **M10, M11** — Database Mail profile `Default` is present in the capture; no relay allow-list
  issue stated for this on-prem-to-on-prem move (not assessed for relay specifics — see Not
  Assessed).
- **M12** — No backup devices present.
- **M13** — No other custom error messages besides 50001, which is already flagged under M4.
- **M14** — No server-level triggers present.
- **M15** — No user-defined XE sessions present.
- **M16** — No non-AG endpoints present.

### Not Assessed
- **M11** — SMTP relay allow-list status for the target's outbound IP was not provided in this
  capture; confirm with the network/mail team before relying on `Default` profile delivery
  post-cutover.

### Object Migration Script Checklist
1. Confirm `AppUser` login exists on target with correct SID (prerequisite — see
   `/sqlmigration-security-review` J1/J2).
2. Confirm `BlobProxy`'s backing credential exists on target, created before the proxy (see
   `/sqlmigration-security-review` J10/J11).
3. `EXEC sp_addmessage @msgnum = 50001, ...;` — add the custom error message before the alert is
   relied upon.
4. `EXEC msdb.dbo.sp_update_jobstep ... @database_name = N'Sales';`
5. `EXEC msdb.dbo.sp_update_job ... @owner_login_name = N'AppUser';`
6. `EXEC msdb.dbo.sp_update_schedule ... @active_start_time = 020000;`
7. Confirm Database Mail relay allow-list includes the target's outbound IP; test with
   `sp_send_dbmail` before declaring complete.

---
Analyzed by: Claude Sonnet 4.6 · 2026-06-20
