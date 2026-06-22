# sqlag-review Example Analysis

**Input:** `ag-config-input.txt` — 3-replica AG (2 sync, 1 async WAN) with 3 databases,
multi-subnet listener, SECONDARY_ONLY backup preference, SUPPORTED endpoint encryption.

---

## AG Configuration Analysis

### Summary
- 1 Critical, 5 Warnings, 3 Info
- Availability group: **FinanceAG** | Replicas: 3 | Version: SQL Server 2019 (15.0.4375.4) | Edition: Enterprise Edition
- Highest-risk finding: **[C1 — F2] AG Database in Non-FULL Recovery — ArchiveReports**

---

### Critical Issues

### [C1 — F2] AG Database in Non-FULL Recovery Model — ArchiveReports
- **Observed:** `recovery_model_desc = 'SIMPLE'` for ArchiveReports in `sys.databases`; this database is a member of FinanceAG
- **Impact:** A database in SIMPLE recovery cannot participate in an AG. SIMPLE recovery truncates the transaction log automatically, breaking the log chain that AG uses to replicate changes to secondaries. The database may appear to join initially but will fail synchronization after the next checkpoint.
- **Fix:**
  ```sql
  ALTER DATABASE [ArchiveReports] SET RECOVERY FULL;
  BACKUP DATABASE [ArchiveReports] TO DISK = N'\\BACKUP\ArchiveReports_full.bak'
    WITH COMPRESSION, STATS = 10;
  ```
  Then ensure log backups are scheduled. The database must be re-joined to the AG after this change on all secondary replicas.

---

### Warnings

### [W1 — F4] Endpoint Encryption Set to SUPPORTED (Downgrade Permitted)
- **Observed:** `encryption_algorithm_desc = 'NONE, AES'` (SUPPORTED/negotiable — `NONE` in the list) with `is_encryption_enabled = 1` on `Hadr_endpoint_FIN` — allows plaintext if the remote endpoint does not enforce encryption
- **Impact:** A misconfigured remote replica or a man-in-the-middle scenario could negotiate a plaintext connection, exposing unencrypted transaction log data in transit (including financial data in PayrollDB and GeneralLedger).
- **Fix:**
  ```sql
  ALTER ENDPOINT [Hadr_endpoint_FIN]
    FOR DATABASE_MIRRORING (ENCRYPTION = REQUIRED ALGORITHM AES);
  ```
  Apply this change on ALL replicas (SQLPROD01, SQLPROD02, SQLDR01) before it takes effect.

### [W2 — F5] Failure Condition Level 1 — Too Permissive
- **Observed:** `failure_condition_level = 1` on FinanceAG
- **Impact:** Level 1 triggers automatic failover only when the SQL Server service goes offline entirely. Resource pressure failures (out-of-memory, scheduler non-yielding) do not trigger failover at this level. A SQL Server instance that is alive but unresponsive will not fail over automatically.
- **Fix:**
  ```sql
  ALTER AVAILABILITY GROUP [FinanceAG] SET (FAILURE_CONDITION_LEVEL = 3);
  ```
  Level 3 covers instance failure, resource failure, and query processor not yielding — appropriate for most production configurations.

### [W3 — F8] WAN Async Replica Session Timeout Too Low — SQLDR01\FINANCEDB
- **Observed:** `session_timeout = 10` on SQLDR01\FINANCEDB with `availability_mode_desc = 'ASYNCHRONOUS_COMMIT'`
- **Impact:** A 10-second session timeout on a WAN-connected DR replica causes spurious DISCONNECTED state reports for network latency spikes > 10 ms. This generates false health alerts and can trigger unnecessary failover if failure_condition_level is increased (see W2).
- **Fix:**
  ```sql
  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLDR01\FINANCEDB'
    WITH (SESSION_TIMEOUT = 30);
  ```

### [W4 — F10] Backup Priority Ties on All Secondary Replicas
- **Observed:** `automated_backup_preference_desc = 'SECONDARY_ONLY'` AND all replicas (SQLPROD01, SQLPROD02, SQLDR01) have `backup_priority = 50`
- **Impact:** When all replicas have equal backup priority and the preference is SECONDARY_ONLY, `sys.fn_hadr_backup_is_preferred_replica()` uses a non-deterministic tiebreaker. Both SQLPROD02 and SQLDR01 may attempt backups simultaneously, fragmenting the log chain and producing duplicate backup files.
- **Fix:**
  ```sql
  -- Prefer SQLPROD02 for backups; use SQLDR01 only if SQLPROD02 unavailable
  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLPROD02\FINANCEDB' WITH (BACKUP_PRIORITY = 80);
  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLDR01\FINANCEDB' WITH (BACKUP_PRIORITY = 40);
  ```

### [W5 — F15] Read-Only Routing URL Absent on Readable Secondaries
- **Observed:** `secondary_role_allow_connections_desc = 'ALL'` on SQLPROD02\FINANCEDB and SQLDR01\FINANCEDB (secondary role), AND `read_only_routing_url IS NULL` on both replicas
- **Impact:** `ApplicationIntent=ReadOnly` connections via the listener will not be redirected to a readable secondary even if a routing list is configured — the listener has nowhere to route them.
- **Fix:**
  ```sql
  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLPROD02\FINANCEDB'
    WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://SQLPROD02.corp.local:1433'));

  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLDR01\FINANCEDB'
    WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://SQLDR01.corp.local:1433'));
  ```
  Then configure the routing list on each replica for its primary role (see I2).

---

### Info

### [I1 — F18] Multi-Subnet Listener Has OFFLINE IP — MultiSubnetFailover=True Required
- **Observed:** `ip_address = 10.1.1.200` shows `ip_state = 'OFFLINE'` — indicates a multi-subnet VNN listener is configured; the DR-subnet IP is offline because this replica is not currently active on that subnet
- **Impact:** This is normal for multi-subnet VNN listeners. However, applications without `MultiSubnetFailover=True` in their connection strings will take 20–30 seconds longer to detect failover (the TCP timeout for the offline-subnet IP must expire first).
- **Fix:** Verify all application connection strings and ODBC/DSN configurations include `MultiSubnetFailover=True`:
  `Server=finance-ag-l;Database=PayrollDB;Integrated Security=SSPI;MultiSubnetFailover=True;`

### [I2 — F16] Read-Only Routing List Not Set on Primary Replicas
- **Observed:** No `READ_ONLY_ROUTING_LIST` appears to be configured (dependent on F15 fix being applied first)
- **Impact:** Even after setting `READ_ONLY_ROUTING_URL` (W5), ApplicationIntent=ReadOnly connections will land on the primary until the routing list is also configured on each replica.
- **Fix:** After applying the W5 fix, configure routing lists:
  ```sql
  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLPROD01\FINANCEDB'
    WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = ('SQLPROD02\FINANCEDB', 'SQLDR01\FINANCEDB')));

  ALTER AVAILABILITY GROUP [FinanceAG]
    MODIFY REPLICA ON N'SQLPROD02\FINANCEDB'
    WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = ('SQLPROD01\FINANCEDB', 'SQLDR01\FINANCEDB')));
  ```

### [I3 — F34] No Extended Events Session for AG Diagnostics
- **Observed:** `sys.dm_xe_sessions` returned 0 rows for AG-related sessions
- **Impact:** Without an XE session, AG state changes (lease expiry, replica disconnection, role changes) are only captured in the ERRORLOG with limited diagnostic detail. Root-cause analysis after an incident is significantly harder.
- **Fix:** Create a lightweight always-on XE session to capture AG events (see SKILL.md F34 for the full CREATE EVENT SESSION script).

---

### Passed Checks

| Check | Result |
|-------|--------|
| F1 — AlwaysOn Feature Disabled | PASS — IsHadrEnabled = 1 |
| F3 — Mirroring Endpoint Missing or Not Started | PASS — endpoint STARTED |
| F6 — SQL Server Version Mismatch | PASS — all replicas on SQL Server 2019 (15.0.4375.4) |
| F7 — Excessive Synchronous-Commit Replicas | PASS — 2 SYNC replicas (below threshold of 4) |
| F9 — Health Check Timeout Too Aggressive | PASS — health_check_timeout = 30,000 ms |
| F11 — Replica Join State Incomplete | PASS — all replicas show JOINED |
| F12 — AG Databases Missing from Secondary | NOT ASSESSED — secondary-side join state not provided |
| F13 — No Readable Secondary | PASS — SQLPROD02 and SQLDR01 allow ALL connections |
| F14 — Multi-Subnet Listener Missing Subnet IP | PASS — both subnets (10.0.1.x, 10.1.1.x) have listener IPs |
| F17 — Listener on Non-Default Port | PASS — listener port = 1433 |
| F19 — Backup Preference Set to NONE | PASS — preference is SECONDARY_ONLY |
| F20 — Backup Jobs Not Using Preferred-Replica Guard | NOT ASSESSED — msdb.dbo.sysjobsteps not provided |
| F21 — Log Backups Not Scheduled | NOT ASSESSED — job schedule not provided |
| F22 — Backup Compression Disabled | NOT ASSESSED — sp_configure not provided |
| F23 — PRIMARY Preference with 3+ Replicas | PASS — preference is SECONDARY_ONLY, not PRIMARY |
| F24 — Windows Auth in Cross-Domain Scenario | PASS — all replicas on corp.local domain |
| F25 — Endpoint Certificate Expiry | PASS — Windows auth in use, no certificates |
| F26 — Endpoint Using RC4 | PASS — AES algorithm in use |
| F27 — Endpoint Port Blocked | NOT ASSESSED — firewall configuration not described |
| F28 — Distributed AG Server Name Instead of Listener | NOT ASSESSED — no distributed AG described |
| F29 — Basic AG with Multiple Databases | PASS — basic_features = 0 (Enterprise AG) |
| F30 — Basic AG with Readable Secondary | PASS — basic_features = 0 |
| F31 — Contained AG with Windows Auth | PASS — is_contained = 0 |
| F32 — Distributed AG Synchronous Link | NOT ASSESSED — no distributed AG described |
| F33 — Cross-Database Dependencies | NOT ASSESSED — T-SQL code not provided |
| F35 — Listener Not Conformant with Cluster | PASS — sys.availability_group_listeners.is_conformant = 1 |

---

### Prioritized Action Order

| Priority | Action | Resolves | Effort |
|----------|--------|----------|--------|
| 1 — Immediately | Switch ArchiveReports to FULL recovery, take full backup, re-join to AG | C1 | 30 min |
| 2 — Today | Change endpoint encryption from SUPPORTED to REQUIRED on all 3 replicas | W1 | 10 min |
| 3 — Today | Raise failure_condition_level from 1 to 3 | W2 | 5 min |
| 4 — This week | Increase session_timeout to 30 on SQLDR01 WAN replica | W3 | 5 min |
| 5 — This week | Set distinct backup_priority values (80/40) on secondaries | W4 | 10 min |
| 6 — This sprint | Set read_only_routing_url on SQLPROD02 and SQLDR01 | W5 | 15 min |
| 7 — This sprint | Configure read_only_routing_list on primary replicas | I2 | 15 min |
| 8 — This sprint | Add MultiSubnetFailover=True to all application connection strings | I1 | varies |
| 9 — Next sprint | Create AG Extended Events diagnostic session | I3 | 20 min |

---

*Analyzed by: Claude Sonnet 4.6 · 2026-06-16 02:45 UTC*
