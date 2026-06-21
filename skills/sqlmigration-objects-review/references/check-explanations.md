# sqlmigration-objects-review Check Explanations (M1–M16)

Plain-English explanations for all 16 checks. Load this file when a user asks "explain check
M##", requests deeper fix options, or wants to understand why a threshold was chosen.

---

## Contents

- [Category 1 — SQL Agent (M1–M6)](#category-1--sql-agent-m1m6)
- [Category 2 — Linked Servers (M7–M9)](#category-2--linked-servers-m7m9)
- [Category 3 — Database Mail (M10–M11)](#category-3--database-mail-m10m11)
- [Category 4 — Backup Infrastructure (M12)](#category-4--backup-infrastructure-m12)
- [Category 5 — Custom Errors (M13)](#category-5--custom-errors-m13)
- [Category 6 — Server Triggers (M14)](#category-6--server-triggers-m14)
- [Category 7 — XE Sessions (M15)](#category-7--xe-sessions-m15)
- [Category 8 — Endpoints (M16)](#category-8--endpoints-m16)
- [Quick Reference Table](#quick-reference-table)

---

## Category 1 — SQL Agent (M1–M6)

### M1 — Agent Job References a Database Not in Migration Scope

**What it means:** Job steps store a literal `database_name`. If that database isn't part of
this migration wave, or is renamed on the target, the job step either fails outright or silently
runs against the wrong (possibly nonexistent) database context.

**How to spot it:**
```sql
SELECT j.name AS job_name, js.database_name
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE js.database_name IS NOT NULL;
```

**Example:**
```sql
EXEC msdb.dbo.sp_update_jobstep
  @job_name = N'Nightly_Reindex', @step_id = 1, @database_name = N'SalesDB_New';
```

**Fix options:**
1. Cross-reference every job step's `database_name` against the final target database names
   before migrating job definitions.
2. Update job steps with `sp_update_jobstep` once the target name is confirmed, or exclude the
   job if its database isn't migrating.

**Related checks:** none directly, but see M2 (owner) and M5 (proxy) for the other two common
job-migration breakage points.

---

### M2 — Job Owner Login Does Not Exist on Target

**What it means:** A job's owner is stored as a SID, resolved to a login name at display time.
If login migration hasn't happened yet, or used a different SID-generating method (see
`/sqlmigration-security-review` J2), the job appears to migrate fine but its owner reference is
broken.

**How to spot it:**
```sql
SELECT j.name, sp.name AS owner_login
FROM msdb.dbo.sysjobs j
LEFT JOIN sys.server_principals sp ON j.owner_sid = sp.sid
WHERE sp.sid IS NULL;
```

**Example:**
```sql
EXEC msdb.dbo.sp_update_job @job_name = N'Nightly_Reindex', @owner_login_name = N'DBA_Login';
```

**Fix options:**
1. Sequence login migration (see `/sqlmigration-security-review` J1/J2) strictly before Agent job
   migration.
2. If the original owner is intentionally not migrating, reassign ownership to a service account
   or `sa` explicitly rather than leaving it unresolved.

**Related checks:** `/sqlmigration-security-review` J1, J2

---

### M3 — Operator Notification Address Is Stale or Unreachable From Target

**What it means:** An Agent operator's contact address migrates as plain text — SQL Server has
no way to verify it's deliverable. The risk is specifically that the target's outbound mail path
(a different Database Mail profile, a different SMTP relay with a different allow-list) hasn't
been proven to reach that same address yet.

**How to spot it:**
```sql
SELECT name, email_address, pager_address FROM msdb.dbo.sysoperators;
```

**Example:**
```sql
EXEC msdb.dbo.sp_notify_operator @profile_name = N'Default', @recipients = N'dba@company.com',
  @subject = N'Migration test notification';
```

**Fix options:**
1. Send a test notification through the target's mail path to each operator's address before
   relying on alerting in production.
2. Update addresses that have changed since the source's operator definitions were last reviewed.

**Related checks:** M10, M11 (the Database Mail path this notification depends on)

---

### M4 — Alert Tied to an Error Number Not Raised on Target Configuration

**What it means:** Agent alerts fire on a specific `message_id`/severity combination. If that
message is a custom user-defined error (`sys.messages` ≥ 50000) that hasn't been migrated yet, or
is tied to a feature (e.g., AG health) not configured the same way on the target, the alert is
defined but will never fire.

**How to spot it:**
```sql
SELECT a.name AS alert_name, a.message_id, a.severity
FROM msdb.dbo.sysalerts a;
```

**Example:**
```
-- Problem: Alert fires on message_id = 50001 (custom "BatchJobFailed" error); that custom
--          message was never added to the target via sp_addmessage
-- Fix: add the custom message (M13) before relying on this alert
```

**Fix options:**
1. Cross-reference every alert's `message_id` against `sys.messages` on the target before
   migrating the alert.
2. Migrate the underlying custom error message first (M13) if it's user-defined.

**Related checks:** M13

---

### M5 — Proxy Account Migrated Without Matching Credential

**What it means:** A job step that runs as a non-SQL-Agent-service-account context references a
proxy, which in turn references a credential. If the credential isn't migrated first (it can't
be scripted with its secret intact — see `/sqlmigration-security-review` J10), the proxy exists
but the job step using it fails at runtime with an authentication error.

**How to spot it:**
```sql
SELECT js.step_name, p.name AS proxy_name
FROM msdb.dbo.sysjobsteps js
JOIN msdb.dbo.sysproxies p ON js.proxy_id = p.proxy_id;
```

**Example:**
```
-- Sequence: credential (J10) -> proxy (sp_add_proxy) -> job step referencing proxy by name
```

**Fix options:**
1. Sequence credential migration, then proxy migration, then job migration — in that order,
   never reversed.
2. See `/sqlmigration-security-review` J10/J11 for the credential and proxy-id-resolution detail.

**Related checks:** `/sqlmigration-security-review` J10, J11

---

### M6 — Job Schedule Assumes Source Server's Time Zone

**What it means:** `active_start_time` is a plain `HHMMSS` integer with no time zone attached —
it is evaluated against the server's local OS time zone at run time. Migrating to a server in a
different time zone (a different region, or Azure which defaults to UTC) changes the real-world
time the job runs without changing the stored value.

**How to spot it:** Compare the source server's OS time zone against the target's, and check
whether any job schedule's timing is tied to a real-world event ("after business close," "before
market open").

**Example:**
```sql
-- Problem: Schedule active_start_time = 220000 was tuned for source's Eastern Time (10 PM ET)
-- Target server time zone is UTC -- job now runs at 10 PM UTC (6 PM ET), four hours early
EXEC msdb.dbo.sp_update_schedule @name = N'Nightly_2200', @active_start_time = 020000; -- 2 AM UTC = 10 PM ET
```

**Fix options:**
1. Recompute `active_start_time` for the target's time zone for every schedule tied to a
   real-world event.
2. Document which schedules are intentionally "wall-clock on the server" vs. "tied to a specific
   real-world time" so future migrations don't repeat this analysis from scratch.

**Related checks:** none — standalone scheduling check.

---

## Category 2 — Linked Servers (M7–M9)

### M7 — Linked Server Provider Not Available on Target

**What it means:** Linked servers depend on an installed OLE DB provider. Some providers (legacy
Jet/ACE for Access/Excel files, certain third-party ODBC-via-OLEDB bridges) may not be installed,
licensed, or even supported anymore on the target OS/SQL Server version.

**How to spot it:**
```sql
SELECT name, product, provider FROM sys.servers WHERE is_linked = 1;
```

**Example:**
```
-- Problem: Linked server uses Microsoft.ACE.OLEDB.12.0 to read a legacy Excel import file
-- Target is a 2019 instance on a server without the ACE redistributable installed
-- Fix: install the provider, or replace the integration with BULK INSERT/OPENROWSET or SSIS
```

**Fix options:**
1. Confirm the provider is installed and registered on the target before migrating the linked
   server definition.
2. For discontinued or unsupported providers, redesign the integration using a currently
   supported import mechanism.

**Related checks:** M8 (network reachability, a separate prerequisite)

---

### M8 — Linked Server Data Source Unreachable From Target Network Path

**What it means:** A linked server's connectivity depends on network path, DNS resolution, and
firewall rules scoped to the source server's identity — none of which automatically extend to
the target, especially across VLANs, on-prem-to-cloud boundaries, or Azure VNet peering gaps.

**How to spot it:** Compare the target's network segment/IP against the firewall rules and DNS
entries that currently permit the source to reach the linked server's `data_source`.

**Example:**
```
-- Problem: Linked server points at 10.20.5.10; firewall rule only allows 10.10.1.0/24 (source's
--          subnet); target is in 10.10.2.0/24
-- Fix: request firewall rule update to include target's subnet before relying on this link
```

**Fix options:**
1. Confirm network connectivity explicitly (test connection, not just configuration review)
   before cutover.
2. Update firewall rules, DNS entries, or VNet peering as needed for the target's actual network
   position.

**Related checks:** M7

---

### M9 — Linked Server Collation-Compatible Setting Mismatched

**What it means:** `collation_compatible = true` tells the optimizer it can push comparison
predicates to the remote server because collations are assumed to match — if the migration
changes the local instance's collation (see `/sqlmigration-review` Y4) without re-evaluating this
setting, queries can silently return incorrect comparison results rather than erroring.

**How to spot it:**
```sql
SELECT name, collation_compatible FROM sys.servers WHERE is_linked = 1;
```

**Example:**
```sql
EXEC sp_serveroption 'RemoteServer', 'collation compatible', 'false';
```

**Fix options:**
1. Re-evaluate `collation_compatible` against the actual post-migration collation relationship,
   not the pre-migration one.
2. When in doubt, set it to `false` — it costs query optimization opportunity, not correctness,
   whereas leaving a stale `true` risks silent wrong results.

**Related checks:** `/sqlmigration-review` Y4

---

## Category 3 — Database Mail (M10–M11)

### M10 — Database Mail Profile/Account Not Migrated

**What it means:** Database Mail profiles and accounts are `msdb`-level configuration, not part
of any user database — moving the database does nothing for this. Every dependent operator
notification (M3) or application-level `sp_send_dbmail` call needs this configured fresh on the
target.

**How to spot it:**
```sql
SELECT name, description FROM msdb.dbo.sysmail_profile;
SELECT name, email_address FROM msdb.dbo.sysmail_account;
```

**Example:**
```sql
EXEC msdb.dbo.sysmail_add_account_sp
  @account_name = 'DBA_Alerts', @email_address = 'sqlalerts@company.com',
  @mailserver_name = 'smtp.company.com';
EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = 'Default';
EXEC msdb.dbo.sysmail_add_profileaccount_sp
  @profile_name = 'Default', @account_name = 'DBA_Alerts', @sequence_number = 1;
```

**Fix options:**
1. Script the profile/account structure from the source's `sysmail_profile`/`sysmail_account`.
2. Re-enter the SMTP account password manually — it is not exposed by any system view.

**Related checks:** M3, M11

---

### M11 — SMTP Relay Allow-List Missing the New Instance

**What it means:** Many SMTP relays restrict which sending hosts they accept mail from by
IP/hostname. Database Mail being correctly configured on the target doesn't help if the relay
itself silently drops or rejects mail from the target's identity.

**How to spot it:** Not directly visible from SQL Server-side configuration — confirmed by
sending an actual test message and checking for delivery or a relay-rejection bounce.

**Example:**
```sql
EXEC msdb.dbo.sp_send_dbmail @profile_name = 'Default',
  @recipients = 'dba@company.com', @subject = 'Post-migration mail test';
```

**Fix options:**
1. Request the target instance's IP/hostname be added to the SMTP relay's allow-list before
   cutover, not discovered reactively when the first production alert silently fails to deliver.
2. Test with `sp_send_dbmail` and confirm receipt before declaring the migration complete.

**Related checks:** M10, M3

---

## Category 4 — Backup Infrastructure (M12)

### M12 — Backup Device Path Unreachable From Target

**What it means:** A logical backup device is just a name pointing at a physical path. If that
path is a UNC share or local path the target's SQL Server service account cannot reach or write
to, every backup job referencing the device fails — possibly not noticed until the first
scheduled backup after cutover.

**How to spot it:**
```sql
SELECT name, physical_name FROM sys.backup_devices;
```

**Example:**
```sql
EXEC sp_addumpdevice 'disk', 'SalesDB_Backup', N'\\NEWBACKUPSHARE\SQLBackups\SalesDB.bak';
```

**Fix options:**
1. Recreate the device pointing at a path reachable from the target.
2. Grant the target's SQL Server service account explicit write access to that path.
3. Run a trivial test backup through the device before relying on it for the first production
   scheduled backup.

**Related checks:** none — standalone infrastructure check.

---

## Category 5 — Custom Errors (M13)

### M13 — Custom Error Message Definition Not Migrated

**What it means:** User-defined error messages (`message_id >= 50000`) registered with
`sp_addmessage` are instance-level (`master`), not part of any database. Application code calling
`RAISERROR` with that message ID, or Agent alerts watching for it (M4), will fail to resolve the
message text — or in RAISERROR's case, may error outright if the message ID doesn't exist.

**How to spot it:**
```sql
SELECT message_id, severity, text FROM sys.messages WHERE message_id >= 50000 AND language_id = 1033;
```

**Example:**
```sql
EXEC sp_addmessage @msgnum = 50001, @severity = 16,
  @msgtext = N'Batch job %s failed validation: %s', @lang = 'us_english';
```

**Fix options:**
1. Script `sp_addmessage` for every custom message found, in the same language(s) as the source.
2. Migrate this before any dependent application code or Agent alerts (M4) go live against the
   target.

**Related checks:** M4

---

## Category 6 — Server Triggers (M14)

### M14 — Server-Level DDL/Logon Trigger Not Migrated

**What it means:** Server-scoped triggers are stored in `master`, entirely separate from any user
database. A logon trigger restricting which logins/IPs/applications can connect, or a DDL audit
trigger, silently does not exist on the target unless explicitly recreated.

**How to spot it:**
```sql
SELECT name, type_desc, is_disabled, OBJECT_DEFINITION(object_id) AS definition
FROM sys.server_triggers;
```

**Example:**
```sql
CREATE TRIGGER block_remote_admin_logon
ON ALL SERVER
FOR LOGON
AS
BEGIN
  IF ORIGINAL_LOGIN() = 'sa' AND HOST_NAME() NOT LIKE 'DBA-%'
    ROLLBACK;
END;
```

**Fix options:**
1. Script each trigger's `OBJECT_DEFINITION` and recreate with `CREATE TRIGGER ... ON ALL SERVER`
   on the target.
2. Test logon triggers in a controlled, non-production-hours window — a misconfigured logon
   trigger can block all connections including `sysadmin`, requiring the Dedicated Administrator
   Connection (`sqlcmd -A`) to recover.

**Related checks:** none — standalone server-object check.

---

## Category 7 — XE Sessions (M15)

### M15 — Extended Events Session Definition Not Migrated

**What it means:** User-defined XE sessions for ongoing diagnostics or auditing are configuration
in `master`/the XE engine, not part of any database. They do not travel with a database migration
and are easy to forget since they're often "set and forget" tooling from a previous
troubleshooting effort.

**How to spot it:**
```sql
SELECT name FROM sys.server_event_sessions
WHERE name NOT IN ('system_health', 'AlwaysOn_health', 'telemetry_xevents');
```

**Example:** Use SSMS Object Explorer → Management → Extended Events → Sessions → right-click the
session → "Script Session as" → CREATE To → New Query Editor Window, then run the generated
script on the target.

**Fix options:**
1. Script each user-defined session's full definition (events, actions, targets, predicates).
2. Set `STATE = START` in the recreated session if it should begin capturing immediately.

**Related checks:** none — standalone diagnostics-tooling check.

---

## Category 8 — Endpoints (M16)

### M16 — Non-AG Endpoint Not Migrated

**What it means:** Always On AG mirroring endpoints are covered by `/sqlag-review` — this check
is specifically for the *other* endpoint types: Service Broker `TSQL` endpoints (cross-instance
messaging) and legacy SOAP/HTTP endpoints. Neither travels with a database migration since
endpoints are instance-level objects.

**How to spot it:**
```sql
SELECT name, type_desc, state_desc FROM sys.endpoints
WHERE type_desc NOT IN ('DATABASE_MIRRORING');
```

**Example:**
```sql
CREATE ENDPOINT [ServiceBrokerEndpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = 4022)
FOR SERVICE_BROKER (AUTHENTICATION = WINDOWS, ENCRYPTION = REQUIRED ALGORITHM AES);
```

**Fix options:**
1. Script the endpoint's full definition from `sys.endpoints`/`sys.service_broker_endpoints` and
   recreate with matching port, authentication, and encryption settings.
2. For legacy SOAP/HTTP endpoints (discontinued since SQL Server 2008 R2), there is no native
   migration path — redesign the integration using a currently supported API surface.

**Related checks:** none in this skill — see `/sqlag-review` for AG mirroring endpoints
specifically.

---

## Quick Reference Table

| Check | Category | Trigger Summary | Severity |
|-------|----------|----------------|----------|
| M1 | SQL Agent | Job step `database_name` not in migration scope | Critical |
| M2 | SQL Agent | Job owner SID does not resolve to a target login | Warning |
| M3 | SQL Agent | Operator notification address not verified reachable from target | Warning |
| M4 | SQL Agent | Alert tied to a message_id not present/raised on target | Warning |
| M5 | SQL Agent | Proxy migrated without matching credential, or wrong sequence | Critical |
| M6 | SQL Agent | Job schedule assumes source server's time zone | Warning |
| M7 | Linked Servers | Linked server provider not installed on target | Critical |
| M8 | Linked Servers | Linked server data source unreachable from target network | Warning |
| M9 | Linked Servers | `collation_compatible` mismatched after collation change | Info |
| M10 | Database Mail | Mail profile/account not migrated | Warning |
| M11 | Database Mail | SMTP relay allow-list missing the new instance | Warning |
| M12 | Backup Infrastructure | Backup device path unreachable from target | Warning |
| M13 | Custom Errors | Custom `sys.messages` definition not migrated | Warning |
| M14 | Server Triggers | Server-level DDL/logon trigger not migrated | Warning |
| M15 | XE Sessions | User-defined XE session definition not migrated | Info |
| M16 | Endpoints | Non-AG endpoint (Service Broker/legacy SOAP) not migrated | Warning |
