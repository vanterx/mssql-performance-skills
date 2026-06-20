# sqlag-review Check Explanations (F1–F36)

Plain-English explanations for all 36 checks. Load this file when a user asks "explain check
F##", requests deeper fix options, or wants to understand why a threshold was chosen.

---

## Contents

- [Category 1 — Prerequisites and Instance Setup (F1–F6)](#category-1--prerequisites-and-instance-setup-f1f6)
- [Category 2 — Replica Configuration Design (F7–F13)](#category-2--replica-configuration-design-f7f13)
- [Category 3 — Listener and Network Design (F14–F18)](#category-3--listener-and-network-design-f14f18)
- [Category 4 — Backup Strategy (F19–F23)](#category-4--backup-strategy-f19f23)
- [Category 5 — Endpoint Security (F24–F27)](#category-5--endpoint-security-f24f27)
- [Category 6 — Distributed AG and Advanced Features (F28–F33)](#category-6--distributed-ag-and-advanced-features-f28f33)
- [Category 7 — Operational Monitoring (F34–F35)](#category-7--operational-monitoring-f34f35)
- [Quick Reference Table](#quick-reference-table)

---

## Category 1 — Prerequisites and Instance Setup (F1–F6)

### F1 — AlwaysOn Feature Disabled

**What it means:** The SQL Server instance has the Always On Availability Groups feature
switched off at the OS/service level. No AG can be created, joined, or operated until it is
enabled. This is a service-level setting, distinct from creating the AG itself.

**How to spot it:**
```sql
SELECT SERVERPROPERTY('IsHadrEnabled') AS hadr_enabled;
-- Returns 0 when disabled
```

**Example:**
```
-- Problem: IsHadrEnabled = 0 — no AG operations possible
-- Fix: Enable via PowerShell (requires SQL Server restart)
Enable-SqlAlwaysOn -ServerInstance 'SQLPROD01\MSSQLSERVER' -Restart
-- Or via SQL Server Configuration Manager:
-- SQL Server Services → instance Properties → AlwaysOn High Availability
```

**Fix options:**
1. Enable via SQL Server Configuration Manager (GUI) — safest for production, requires planned restart
2. PowerShell: `Enable-SqlAlwaysOn -ServerInstance '<instance>' -Restart` — requires SqlServer module
3. After enabling and restarting, create the endpoint and AG

**Related checks:** F3 (endpoint must also exist after enabling AlwaysOn)

---

### F2 — AG Database Not in FULL Recovery Model

**What it means:** An AG database is in SIMPLE or BULK_LOGGED recovery. SIMPLE recovery
truncates the transaction log at every checkpoint, breaking the continuous log chain that
the AG uses to ship changes to secondary replicas. Databases in SIMPLE recovery cannot
maintain synchronization.

**How to spot it:**
```sql
SELECT db.name, db.recovery_model_desc
FROM sys.availability_databases_cluster adc
JOIN sys.databases db ON adc.database_id = db.database_id
WHERE db.recovery_model_desc != 'FULL';
```

**Example:**
```sql
-- Problem: ReportDB shows recovery_model_desc = 'SIMPLE'
-- Fix Step 1: Switch to FULL
ALTER DATABASE [ReportDB] SET RECOVERY FULL;

-- Fix Step 2: Take a full backup to start the log chain
BACKUP DATABASE [ReportDB]
  TO DISK = N'\\BACKUP\ReportDB_full.bak'
  WITH COMPRESSION, STATS = 10;

-- Fix Step 3: Re-join to AG on all secondaries
-- (restore with NORECOVERY on secondary, then:)
ALTER DATABASE [ReportDB] SET HADR AVAILABILITY GROUP = [ProdAG];
```

**Fix options:**
1. Switch to FULL recovery + take full backup + re-join AG — required, no shortcut
2. If the database genuinely needs SIMPLE recovery (very large, no DR), consider excluding it from the AG and protecting it via another method

**Related checks:** F21 (log backups must follow FULL recovery switch)

---

### F3 — Mirroring Endpoint Missing or Not Started

**What it means:** The database mirroring endpoint is the TCP socket through which AG replicas
exchange log blocks. Without it, or if it is stopped, replicas cannot communicate at all.

**How to spot it:**
```sql
SELECT name, state_desc, port, encryption_desc
FROM sys.database_mirroring_endpoints;
-- No rows = endpoint missing; state_desc != 'STARTED' = stopped
```

**Example:**
```sql
-- Problem: No rows returned
-- Fix: Create the endpoint
CREATE ENDPOINT [Hadr_endpoint]
  STATE = STARTED
  AS TCP (LISTENER_PORT = 5022)
  FOR DATABASE_MIRRORING (
    ROLE = ALL,
    ENCRYPTION = REQUIRED ALGORITHM AES,
    AUTHENTICATION = WINDOWS NEGOTIATE
  );

-- Grant CONNECT to SQL Server service account
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [DOMAIN\SQLServiceAccount];
```

**Fix options:**
1. Create endpoint if missing (see above)
2. Start a stopped endpoint: `ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;`
3. Verify port 5022 is open in Windows Firewall on all replica nodes

**Related checks:** F4 (encryption on the endpoint), F24 (authentication method), F27 (port accessibility)

---

### F4 — Endpoint Encryption Disabled or Downgrade-Permitted

**What it means:** `SUPPORTED` allows the two endpoint peers to negotiate plaintext if one
side doesn't enforce encryption. `DISABLED` turns off encryption entirely. Both expose the
AG log stream — which contains every inserted, updated, and deleted row — to network
interception.

**How to spot it:**
```sql
SELECT encryption_desc, encryption_algorithm_desc
FROM sys.database_mirroring_endpoints;
-- 'DISABLED' = Critical; 'SUPPORTED' = Warning
```

**Example:**
```sql
-- Problem: encryption_desc = 'SUPPORTED'
-- Fix: Enforce AES on all replicas (change all replicas before enforcement takes effect)
ALTER ENDPOINT [Hadr_endpoint]
  FOR DATABASE_MIRRORING (ENCRYPTION = REQUIRED ALGORITHM AES);
```

**Fix options:**
1. Set `ENCRYPTION = REQUIRED ALGORITHM AES` on every replica endpoint — must be applied to all before enforcement works (both sides must agree on REQUIRED)
2. After changing all replicas, verify: `SELECT encryption_desc FROM sys.database_mirroring_endpoints` should show `REQUIRED`

**Related checks:** F26 (RC4 algorithm), F3 (endpoint must be started for this change)

---

### F5 — Failure Condition Level at Extremes

**What it means:** The `failure_condition_level` controls which SQL Server health conditions
trigger an automatic AG failover. Level 1 is so permissive it only fires on a full SQL Server
crash; resource exhaustion (memory pressure, scheduler non-yielding) is silently ignored.
Level 5 is so sensitive that transient resource spikes trigger unnecessary failovers.

**How to spot it:**
```sql
SELECT name, failure_condition_level
FROM sys.availability_groups;
-- Level 1: too permissive; Level 5: too aggressive
```

**Level reference:**

| Level | Triggers failover when... |
|-------|--------------------------|
| 1 | SQL Server service is offline or lease expires |
| 2 | Level 1 + SQL Server unresponsive / in failed state |
| 3 (default) | Level 2 + critical internal errors (orphaned spinlocks, write-access violations, excessive dumps) |
| 4 | Level 3 + moderate SQL Server errors |
| 5 | Level 4 + any qualified health condition |

**Fix options:**
1. Level 2 (default): `ALTER AVAILABILITY GROUP [ag] SET (FAILURE_CONDITION_LEVEL = 2);` — suitable for most environments
2. Level 3: Recommended for production — catches hanging schedulers that level 2 misses
3. Avoid level 1 (misses out-of-memory crashes) and level 5 (transient spikes cause failover)

**Related checks:** F9 (health check timeout interacts with failure condition detection)

---

### F6 — SQL Server Version Mismatch Across Replicas

**What it means:** Always On supports mixed versions only during a planned rolling upgrade
window (secondary upgraded first, then the primary fails over to the upgraded node). Running
mismatched versions long-term causes unpredictable behavior after failover: the new primary
may expose features or query plan changes the application was not tested against.

**How to spot it:**
```sql
-- On each replica, run:
SELECT SERVERPROPERTY('ProductVersion') AS version,
       SERVERPROPERTY('ProductLevel')   AS level;
-- Compare across all replicas
```

**Fix options:**
1. Complete the rolling upgrade — secondary first, then failover, then upgrade the old primary
2. Document the current upgrade state if mid-upgrade
3. Test application compatibility on the higher version before promoting it to primary

**Related checks:** F31 (Contained AG — SQL 2022 only), F32 (distributed AG — SQL 2016+)

---

## Category 2 — Replica Configuration Design (F7–F13)

### F7 — Excessive Synchronous-Commit Replicas

**What it means:** Every synchronous secondary must acknowledge a log write before the primary
returns success to the application. With 4 or more synchronous replicas, each commit waits for
the slowest acknowledgement in the set — commit latency fans out multiplicatively.

**How to spot it:**
```sql
SELECT ag.name, COUNT(*) AS sync_replica_count
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
WHERE ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
GROUP BY ag.name
HAVING COUNT(*) >= 4;
```

**Example:**
```sql
-- Problem: 4 SYNCHRONOUS replicas; commit latency tripled since adding 4th
-- Fix: Demote DR replica to async
ALTER AVAILABILITY GROUP [ProdAG]
  MODIFY REPLICA ON N'DR-SQL01'
  WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
```

**Fix options:**
1. Demote DR-site or reporting-only replicas to ASYNCHRONOUS_COMMIT (accepts data loss risk)
2. SQL Server 2019+ supports up to 5 sync replicas (9 total); evaluate if additional sync replicas are truly needed for RPO=0

**Related checks:** H4 (runtime sync stall), H16 (commit latency signal)

---

### F8 — WAN Async Replica Session Timeout Too Low

**What it means:** Session timeout (default 10 seconds) is the period after which an
unacknowledged ping causes the replica to be marked DISCONNECTED. On a WAN link with
variable latency, 10 seconds triggers false disconnections during traffic bursts.

**How to spot it:**
```sql
SELECT replica_server_name, session_timeout, availability_mode_desc
FROM sys.availability_replicas
WHERE availability_mode_desc = 'ASYNCHRONOUS_COMMIT'
  AND session_timeout < 30;
```

**Fix options:**
1. Increase to 30 seconds for WAN links with < 50 ms RTT: `ALTER AVAILABILITY GROUP [ag] MODIFY REPLICA ON N'server' WITH (SESSION_TIMEOUT = 30);`
2. Increase to 60 seconds for satellite or high-latency links
3. Minimum is 5 seconds; very high values (> 120 seconds) delay disconnection detection

**Related checks:** H1 (replica disconnected — may be caused by session timeout expiry)

---

### F9 — Health Check Timeout Too Aggressive

**What it means:** `health_check_timeout` controls how long SQL Server waits for
`sp_server_diagnostics` to respond before declaring the instance unhealthy. The diagnostic
procedure runs every `health_check_timeout / 3` seconds. Values below 15,000 ms increase
diagnostic poll frequency unnecessarily and can trigger false-positive failovers.

**How to spot it:**
```sql
SELECT name, health_check_timeout
FROM sys.availability_groups
WHERE health_check_timeout < 15000;
```

**Fix options:**
1. Default (30,000 ms) is appropriate for LAN topologies: `ALTER AVAILABILITY GROUP [ag] SET (HEALTH_CHECK_TIMEOUT = 30000);`
2. Increase to 60,000–120,000 ms for WAN topologies or slow storage environments
3. LeaseTimeout (WSFC setting) should always be greater than health_check_timeout; confirm in Failover Cluster Manager

**Related checks:** F5 (failure condition level), L1-L8 (cluster log lease timeout events)

---

### F10 — Backup Priority Ties Make Secondary Selection Non-Deterministic

**What it means:** `backup_priority` (0–100) determines which replica `sys.fn_hadr_backup_is_preferred_replica()` selects when the automated backup preference is SECONDARY or SECONDARY_ONLY. All replicas at the same default (50) creates a tie — different replicas may be selected on each evaluation, fragmenting the backup log chain.

**How to spot it:**
```sql
SELECT ar.replica_server_name, ar.backup_priority,
       ag.automated_backup_preference_desc
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.automated_backup_preference_desc IN ('SECONDARY', 'SECONDARY_ONLY');
-- Look for all secondaries with backup_priority = 50
```

**Fix options:**
1. Set distinct priorities: preferred secondary = 70–90, fallback = 30–50, DR-only = 10–20
2. Primary should stay at default 50 if SECONDARY_ONLY preference is used (prevents primary backups unless no secondary is available)

**Related checks:** F19 (backup preference NONE), F20 (backup job guard function), F21 (log backup scheduling)

---

### F11 — Replica Join State Incomplete

**What it means:** A secondary instance was added to `sys.availability_replicas` (typically by
running `CREATE AVAILABILITY GROUP ... FOR REPLICA ON`) but the secondary instance has not yet
executed `ALTER AVAILABILITY GROUP [ag] JOIN`. Until joined, the replica does not participate
in the AG at all.

**How to spot it:**
```sql
-- join_state_desc is in the cluster-states DMV, not sys.availability_replicas
SELECT replica_server_name, join_state_desc
FROM sys.dm_hadr_availability_replica_cluster_states
WHERE join_state_desc = 'NOT_JOINED';
-- Valid joined values: JOINED_STANDALONE (standalone SQL), JOINED_FCI (failover cluster instance)
```

**Fix options:**
1. On the secondary instance: `ALTER AVAILABILITY GROUP [ag] JOIN;`
2. Then restore each AG database and join: `ALTER DATABASE [db] SET HADR AVAILABILITY GROUP = [ag];`
3. Or use automatic seeding if `seeding_mode_desc = 'AUTOMATIC'`

**Related checks:** F12 (databases not joined after replica join), F22 (automatic seeding monitoring)

---

### F12 — AG Databases Missing from Secondary After Replica Join

**What it means:** The secondary replica has joined the AG (`join_state_desc = 'JOINED'`) but
one or more databases have not been restored and joined on that secondary. The replica
participates at the AG level but is not protecting the missing databases.

**How to spot it:**
```sql
-- Run on primary; compare database count per replica vs primary
SELECT ar.replica_server_name, COUNT(adc.database_id) AS db_count
FROM sys.availability_replicas ar
LEFT JOIN sys.availability_databases_cluster adc ON ar.group_id = adc.ag_id
GROUP BY ar.replica_server_name;
-- Lower count on a secondary = missing databases
```

**Fix options:**
1. Manual seeding: restore database with `RESTORE DATABASE [db] FROM DISK = '...' WITH NORECOVERY, REPLACE;` then `ALTER DATABASE [db] SET HADR AVAILABILITY GROUP = [ag];`
2. Automatic seeding (if `seeding_mode_desc = 'AUTOMATIC'` on the replica): databases should seed automatically — monitor with `SELECT * FROM sys.dm_hadr_automatic_seeding`
3. Grant `ALTER ANY AVAILABILITY GROUP` if seeding permission is missing

**Related checks:** F11 (replica not joined), H22 (automatic seeding in progress)

---

### F13 — No Readable Secondary Configured

**What it means:** All secondary replicas reject connections (`secondary_role_allow_connections_desc = 'NO'`). Any reporting, analytics, or read-only application load must run on the primary, consuming its resources. Readable secondaries can offload significant I/O.

**How to spot it:**
```sql
SELECT replica_server_name, secondary_role_allow_connections_desc
FROM sys.availability_replicas
WHERE availability_mode_desc != 'PRIMARY';
-- All showing 'NO' = no read offload possible
```

**Fix options:**
1. Configure READ_ONLY on a secondary: `ALTER AVAILABILITY GROUP [ag] MODIFY REPLICA ON N'server' WITH (SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY));`
2. Enable RCSI on primary to prevent readers from blocking redo: `ALTER DATABASE [db] SET READ_COMMITTED_SNAPSHOT ON;`
3. Configure read-only routing (F15, F16) to automatically direct ApplicationIntent=ReadOnly connections

**Related checks:** F15 (routing URL), F16 (routing list), H26 (RCSI on readable secondary)

---

## Category 3 — Listener and Network Design (F14–F18)

### F14 — Multi-Subnet Listener Missing IP for a Subnet

**What it means:** In a multi-subnet AG, the VNN listener must have one static IP address per
subnet where a replica resides. During failover from subnet A to subnet B, the cluster takes
the subnet B IP online. A missing subnet IP means the listener is unreachable from that subnet
after failover.

**How to spot it:**
```sql
-- Compare distinct subnets in endpoint_url vs listener IPs
SELECT DISTINCT
  SUBSTRING(endpoint_url, CHARINDEX('//', endpoint_url) + 2,
    LEN(endpoint_url)) AS replica_ip_hint
FROM sys.availability_replicas;

SELECT ip_address, ip_subnet_mask, state_desc
FROM sys.availability_group_listener_ip_addresses;
```

**Fix options:**
1. Add missing IP: `ALTER AVAILABILITY GROUP [ag] MODIFY LISTENER N'listener' (ADD IP (N'10.1.2.10', N'255.255.255.0'));`
2. Alternatively, use a Distributed Network Name (DNN) listener — requires no IP-per-subnet configuration (SQL Server 2019+ on Windows Server 2016+)

**Related checks:** F18 (INACTIVE IP — expected for multi-subnet VNN), F17 (non-standard port)

---

### F15 — Read-Only Routing URL Absent on Readable Secondary

**What it means:** `read_only_routing_url` tells the listener where to redirect an
`ApplicationIntent=ReadOnly` connection. Without it, the routing list (F16) has no URL to
route to, so read-intent connections fall through to the primary.

**How to spot it:**
```sql
SELECT replica_server_name, secondary_role_allow_connections_desc, read_only_routing_url
FROM sys.availability_replicas
WHERE secondary_role_allow_connections_desc IN ('READ_ONLY', 'ALL')
  AND read_only_routing_url IS NULL;
```

**Example:**
```sql
-- Fix: Set the routing URL on each readable secondary
-- Format: TCP://FQDN:sql_port (NOT the endpoint port 5022)
ALTER AVAILABILITY GROUP [ProdAG]
  MODIFY REPLICA ON N'SQLREP02'
  WITH (SECONDARY_ROLE
    (READ_ONLY_ROUTING_URL = N'TCP://SQLREP02.corp.local:1433'));
```

**Fix options:**
1. Set `READ_ONLY_ROUTING_URL` on every secondary that allows read connections (see above)
2. URL must use the SQL Server listener port (1433 default), NOT the AG endpoint port (5022)
3. Use the FQDN, not the short hostname, for DNS resolution reliability

**Related checks:** F16 (routing list on primary), F13 (secondary connections allowed)

---

### F16 — Read-Only Routing List Not Set on Primary Replica

**What it means:** The `READ_ONLY_ROUTING_LIST` on each replica (for its primary role)
defines the ordered list of secondaries to receive `ApplicationIntent=ReadOnly` connections.
Without this list, the listener does not redirect read-intent connections even if routing URLs
are configured on secondaries.

**How to spot it:**
Indirectly: if F15 is resolved (routing URLs set on secondaries) but read-intent connections
still hit the primary, the routing list is missing. Confirm via:
```sql
-- Query sys.availability_read_only_routing_lists if it exists in your version
-- Or test: connect via listener with ApplicationIntent=ReadOnly and check @@SERVERNAME
```

**Fix options:**
1. Set routing list on each replica (for when it acts as primary):
   ```sql
   ALTER AVAILABILITY GROUP [ProdAG]
     MODIFY REPLICA ON N'SQLPROD01'
     WITH (PRIMARY_ROLE
       (READ_ONLY_ROUTING_LIST = ('SQLREP02', 'SQLREP03')));
   ```
2. Order matters — first available replica in the list receives the connection
3. Use a nested list for load balancing across read replicas (SQL Server 2016+):
   `READ_ONLY_ROUTING_LIST = (('SQLREP02', 'SQLREP03'), 'SQLDR01')`

**Related checks:** F15 (routing URL must be set first), F17 (non-default port in routing URL)

---

### F17 — Listener on Non-Default Port

**What it means:** The AG listener is listening on a port other than 1433. Applications,
connection strings, ODBC DSNs, and driver configurations that do not specify the port
explicitly will silently connect to the default 1433 port, which may not exist or may
connect to a different SQL Server instance.

**How to spot it:**
```sql
SELECT dns_name, port FROM sys.availability_group_listeners
WHERE port != 1433;
```

**Fix options:**
1. Ensure all application connection strings include the custom port: `Server=listener-name,<port>;`
2. Update ODBC DSNs, linked server definitions, and any hardcoded connection strings
3. Confirm Windows Firewall and network firewalls allow the custom port inbound

**Related checks:** F15 (routing URL must also use the custom SQL port, not 5022)

---

### F18 — Multi-Subnet OFFLINE Listener IP Without MultiSubnetFailover Guidance

**What it means:** In a multi-subnet VNN listener, only the IP for the currently active subnet
is ONLINE. IPs for the other subnets are OFFLINE (state_desc = 'OFFLINE'). This is correct
behavior — but applications without `MultiSubnetFailover=True` experience a 20–30 second delay
during failover while the TCP connection to the offline-subnet IP times out.

**How to spot it:**
```sql
SELECT ip_address, state_desc, ip_subnet_mask
FROM sys.availability_group_listener_ip_addresses
WHERE state_desc = 'OFFLINE';
-- One or more rows = standby-subnet IP; confirm multi-subnet VNN listener is in use
-- Valid state_desc values: ONLINE | OFFLINE | ONLINE_PENDING | FAILED
```

**Fix options:**
1. Add `MultiSubnetFailover=True` to all application connection strings — the driver then attempts all listener IPs simultaneously, reducing failover time from ~30 seconds to ~1 second
2. For .NET apps: `MultiSubnetFailover=True` in the connection string
3. For ODBC: `MultiSubnetFailover=Yes` in the DSN or connection string
4. Alternatively, migrate to a DNN listener (SQL Server 2019+ on WS2016+) which eliminates multi-subnet complexity entirely

**Related checks:** F14 (missing subnet IP), F17 (non-default port)

---

## Category 4 — Backup Strategy (F19–F23)

### F19 — Automated Backup Preference Set to NONE

**What it means:** With preference NONE, `sys.fn_hadr_backup_is_preferred_replica()` always
returns 1 on every replica — every backup job on every replica runs simultaneously. This
creates competing log chains and duplicate backup files unless backup jobs implement their own
replica coordination logic.

**How to spot it:**
```sql
SELECT name, automated_backup_preference_desc
FROM sys.availability_groups
WHERE automated_backup_preference_desc = 'NONE';
```

**Fix options:**
1. SECONDARY_ONLY: backups only on secondaries; primary used if no secondary is available — best for offloading I/O
2. SECONDARY: prefer secondaries; primary is fallback
3. PRIMARY: all backups on primary — avoids secondary-to-primary log chain coordination complexity at the cost of primary I/O

**Related checks:** F10 (backup priority), F20 (guard function), F21 (log backups)

---

### F20 — Backup Jobs Not Guarded by sys.fn_hadr_backup_is_preferred_replica

**What it means:** Without `IF sys.fn_hadr_backup_is_preferred_replica(DB_NAME()) = 1`, every
replica runs the backup job regardless of AG preference. Two parallel `BACKUP LOG` commands on
the same database create two separate log chains, making one or both unusable for restore.

**How to spot it:**
Review `msdb.dbo.sysjobsteps` for backup jobs:
```sql
SELECT j.name, s.command
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.command LIKE '%BACKUP%'
  AND s.command NOT LIKE '%fn_hadr_backup_is_preferred_replica%';
-- Rows found = backup jobs missing the guard
```

**Fix options:**
1. Wrap all backup commands:
   ```sql
   IF sys.fn_hadr_backup_is_preferred_replica(DB_NAME()) = 1
   BEGIN
     BACKUP DATABASE [db] TO DISK = N'...' WITH COMPRESSION, STATS = 10;
   END
   ```
2. The function returns 1 on the replica that should run the backup, 0 on all others
3. Third-party backup tools (Ola Hallengren, Minion Backup) have native AG awareness — configure their AG-aware options

**Related checks:** F10 (backup priority ties), F19 (preference NONE bypasses the function)

---

### F21 — Log Backups Not Scheduled for AG Databases

**What it means:** FULL recovery model databases accumulate transaction log until a log backup
truncates the inactive portion. Without scheduled log backups, the transaction log file grows
without bound until the disk is full, causing all AG transactions to fail.

**How to spot it:**
```sql
-- Check last log backup per database
SELECT db.name, MAX(b.backup_finish_date) AS last_log_backup
FROM sys.databases db
LEFT JOIN msdb.dbo.backupset b
    ON b.database_name = db.name AND b.type = 'L'
WHERE db.recovery_model_desc = 'FULL'
  AND db.database_id > 4
GROUP BY db.name
HAVING MAX(b.backup_finish_date) IS NULL
    OR MAX(b.backup_finish_date) < DATEADD(hour, -2, GETDATE());
```

**Fix options:**
1. Schedule log backups every 15–60 minutes depending on RPO and log volume
2. Backup must use `sys.fn_hadr_backup_is_preferred_replica()` guard (see F20)
3. Log backups can run on any replica; the log chain is maintained regardless of which replica performs them

**Related checks:** F2 (FULL recovery required), F20 (guard function)

---

### F22 — Backup Compression Disabled on Secondary Backup Host

**What it means:** Backup compression reduces file size by 60–80% and reduces backup I/O time,
at the cost of CPU cycles on the backup host. Running backups uncompressed on a secondary
wastes I/O throughput and storage without affecting primary commit latency.

**How to spot it:**
```sql
-- On the preferred secondary instance:
SELECT name, value_in_use
FROM sys.configurations
WHERE name = 'backup compression default';
-- value_in_use = 0 means compression is off
```

**Fix options:**
1. Enable at instance level: `EXEC sp_configure 'backup compression default', 1; RECONFIGURE;`
2. Override per backup: `BACKUP DATABASE [db] ... WITH COMPRESSION;`
3. Monitor CPU impact with `sys.dm_exec_requests` during the first compressed backup

**Related checks:** F10 (preferred secondary selection), F19 (backup preference)

---

### F23 — PRIMARY Preference with 3 or More Replicas

**What it means:** When backup preference is PRIMARY and 3+ replicas exist, all backup I/O
runs on the primary replica, competing directly with production OLTP workloads. The secondary
replicas sit idle from a backup perspective despite being available.

**How to spot it:**
```sql
SELECT ag.name, ag.automated_backup_preference_desc,
       COUNT(ar.replica_id) AS replica_count
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
GROUP BY ag.name, ag.automated_backup_preference_desc
HAVING ag.automated_backup_preference_desc = 'PRIMARY'
   AND COUNT(ar.replica_id) >= 3;
```

**Fix options:**
1. Switch to SECONDARY_ONLY to fully offload backup I/O: `ALTER AVAILABILITY GROUP [ag] SET (AUTOMATED_BACKUP_PREFERENCE = SECONDARY_ONLY);`
2. Set distinct backup_priority values per secondary (see F10)
3. If primary-only backups are a compliance requirement, accept this Info finding with documentation

**Related checks:** F10, F19, F20

---

## Category 5 — Endpoint Security (F24–F27)

### F24 — Windows Authentication on Endpoint in Cross-Domain or Workgroup Scenario

**What it means:** Windows authentication on the mirroring endpoint relies on Kerberos or NTLM,
both of which require Active Directory trust between the domains hosting the replica instances.
In workgroup, cross-domain (no trust), or cloud-hybrid scenarios, Windows auth will fail with
cryptic authentication errors.

**How to spot it:**
```sql
SELECT connection_auth_desc, endpoint_url
FROM sys.database_mirroring_endpoints;
-- connection_auth_desc containing 'WINDOWS' + replicas in different domains = mismatch
```

**Fix options:**
1. Create self-signed certificates on each replica, exchange public keys, and switch to certificate auth:
   ```sql
   -- On each replica: create certificate, back it up, copy .cer to partners
   CREATE CERTIFICATE [hadr_cert] WITH SUBJECT = 'HADR Endpoint Certificate',
     EXPIRY_DATE = '20280101';
   BACKUP CERTIFICATE [hadr_cert] TO FILE = N'C:\hadr_cert.cer';

   -- Alter endpoint to use certificate auth
   ALTER ENDPOINT [Hadr_endpoint]
     FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE [hadr_cert]);
   ```
2. Establish a forest trust between domains if Windows auth is preferred

**Related checks:** F25 (certificate expiry), F3 (endpoint must be started)

---

### F25 — Endpoint Certificate Expiring Within 90 Days

**What it means:** The certificate used for database mirroring endpoint authentication has a
finite validity period. When it expires, the endpoint authentication fails, replicas
disconnect, and the AG health degrades immediately. Certificate rotation under pressure
(after disconnection) is error-prone.

**How to spot it:**
```sql
SELECT name, expiry_date, DATEDIFF(day, GETDATE(), expiry_date) AS days_remaining
FROM sys.certificates
WHERE pvt_key_encryption_type_desc IS NOT NULL
ORDER BY expiry_date;
-- < 90 days = Warning; < 30 days = Critical
```

**Fix options:**
1. Create a new certificate before the old one expires
2. Back up the new certificate and distribute the public key to all partner replicas
3. Create a login and user from the new certificate on each partner and grant CONNECT on the endpoint
4. Alter the endpoint on each replica to use the new certificate
5. Verify the AG remains connected throughout the rotation
6. Automate certificate monitoring: add an alert when `expiry_date < DATEADD(day, 90, GETDATE())`

**Related checks:** F24 (certificate auth in use), F3 (endpoint state)

---

### F26 — Endpoint Using RC4 Encryption Algorithm

**What it means:** RC4 was deprecated by NIST in 2013 and is prohibited under PCI-DSS,
HIPAA, and FedRAMP. SQL Server 2016+ disables RC4 by default. Any AG using RC4 is
transmitting transaction log data with a broken cipher.

**How to spot it:**
```sql
SELECT encryption_algorithm_desc FROM sys.database_mirroring_endpoints;
-- 'RC4' = Critical
```

**Fix options:**
1. Rotate to AES on all replicas simultaneously (or in a maintenance window):
   ```sql
   ALTER ENDPOINT [Hadr_endpoint]
     FOR DATABASE_MIRRORING (ENCRYPTION = REQUIRED ALGORITHM AES);
   ```
2. After the change, verify: `SELECT encryption_algorithm_desc FROM sys.database_mirroring_endpoints` shows `AES`
3. Restart the endpoint if the change does not take effect: `ALTER ENDPOINT [Hadr_endpoint] STATE = STOPPED; ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;`

**Related checks:** F4 (encryption mode), F3 (endpoint state)

---

### F27 — Endpoint Port Documented as Blocked

**What it means:** The database mirroring endpoint communicates on a dedicated TCP port
(default 5022). A firewall blocking this port causes immediate replica disconnection — the AG
log stream and health ping cannot traverse the blocked port.

**How to spot it:**
Detected from user description mentioning firewall rules or network ACLs blocking the port.
Confirm the port: `SELECT port FROM sys.database_mirroring_endpoints;`

**Fix options:**
1. Open the endpoint port (TCP, inbound and outbound) on Windows Firewall:
   `netsh advfirewall firewall add rule name="SQL AG Endpoint" dir=in action=allow protocol=TCP localport=5022`
2. Open on all network layers: Windows Firewall, hardware firewall, security group (AWS), NSG (Azure)
3. Also ensure the SQL Server listener port (1433 or custom) is open for application connectivity
4. Test connectivity: `Test-NetConnection -ComputerName SQLREP02 -Port 5022`

**Related checks:** F3 (endpoint state), F14 (listener subnet IP)

---

## Category 6 — Distributed AG and Advanced Features (F28–F33)

### F28 — Distributed AG Using Instance Name Instead of Listener URL

**What it means:** A distributed AG connects two local AGs together. The `LISTENER_URL` in the
`AVAILABILITY GROUP ON` clause must point to the local AG's listener, not to the primary
instance. If the primary within the local AG fails over to another replica, the instance name
in the distributed AG link becomes invalid.

**How to spot it:**
Review the distributed AG creation script or `sys.availability_groups` DMV for the listener_url:
```sql
SELECT name, listener_url
FROM sys.availability_groups
WHERE is_distributed = 1;  -- SQL 2016+
-- If listener_url contains a server instance name rather than a listener DNS name = check fires
```

**Fix options:**
1. Drop and recreate the distributed AG using the listener URL
2. The listener URL format for a distributed AG: `TCP://listener-name.domain.com:5022` (the AG endpoint port, not the SQL port 1433)
3. The listener itself must be configured with port 5022 (or the endpoint port) for distributed AG use, separate from the 1433 listener for applications

**Related checks:** F3 (endpoint port), F17 (listener port)

---

### F29 — Basic AG with More Than One Database

**What it means:** Basic Availability Groups (SQL Server 2016+ Standard Edition) are limited
to a single database per AG. Adding a second database causes the AG creation to fail or
existing databases to be removed.

**How to spot it:**
```sql
SELECT ag.name, ag.basic_features, COUNT(adc.database_id) AS db_count
FROM sys.availability_groups ag
JOIN sys.availability_databases_cluster adc ON ag.group_id = adc.ag_id
WHERE ag.basic_features = 1
GROUP BY ag.name, ag.basic_features
HAVING COUNT(adc.database_id) > 1;
```

**Fix options:**
1. Create separate Basic AGs — one per database (each AG has its own listener)
2. Upgrade to Enterprise Edition to remove the single-database limitation
3. Alternatively, merge databases into one if the business allows it

**Related checks:** F30 (readable secondary not supported on Basic AG)

---

### F30 — Basic AG Configured with Readable Secondary

**What it means:** Basic AGs do not support readable secondaries. The
`secondary_role_allow_connections` setting is accepted by T-SQL but has no effect — secondary
replicas will refuse all connections. Applications expecting read offload via
`ApplicationIntent=ReadOnly` will receive errors.

**How to spot it:**
```sql
SELECT ag.name, ar.replica_server_name, ar.secondary_role_allow_connections_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
WHERE ag.basic_features = 1
  AND ar.secondary_role_allow_connections_desc != 'NO';
```

**Fix options:**
1. Remove read-intent routing from application connection strings targeting the Basic AG listener
2. Upgrade to Enterprise Edition to enable readable secondaries
3. Consider a separate reporting instance not protected by the AG if read offload is needed

**Related checks:** F29 (Basic AG database limit), F13 (no readable secondary)

---

### F31 — Contained AG Using Windows Endpoint Authentication

**What it means:** Contained AGs (SQL Server 2022) support domain-independent deployment
(containers, Kubernetes, workgroups). Using Windows authentication for the endpoint requires
Active Directory, negating the domain-independence benefit of the containment model.

**How to spot it:**
```sql
SELECT ag.name, ag.is_contained, e.connection_auth_desc
FROM sys.availability_groups ag
CROSS JOIN sys.database_mirroring_endpoints e
WHERE ag.is_contained = 1
  AND e.connection_auth_desc LIKE '%WINDOWS%';
-- SQL 2022+ only
```

**Fix options:**
1. Switch to certificate-based endpoint authentication (see F24 fix)
2. Certificate auth enables truly domain-independent Contained AG deployments

**Related checks:** F24 (certificate auth setup), F6 (SQL version — requires SQL 2022)

---

### F32 — Distributed AG Left in Synchronous Commit as Permanent Configuration

**What it means:** `SYNCHRONOUS_COMMIT` on a distributed AG inter-AG link IS supported and is
used deliberately during planned zero-data-loss failovers (explicitly documented by Microsoft).
However, leaving SYNCHRONOUS_COMMIT as the permanent steady-state configuration for a
WAN-spanning distributed AG adds commit latency proportional to the inter-site round-trip time.
Microsoft recommends ASYNCHRONOUS_COMMIT for normal DR operations and temporarily switching to
SYNCHRONOUS_COMMIT only during planned failover windows.

**How to spot it:**
```sql
SELECT ag.name, ar.availability_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
WHERE ag.is_distributed = 1  -- SQL 2016+
  AND ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT';
-- Context matters: SYNC is expected during a planned failover window
```

**Fix options:**
1. If outside a planned failover window: revert to async for normal DR operations:
   `ALTER AVAILABILITY GROUP [DistributedAG] MODIFY AVAILABILITY GROUP ON 'SecondaryAG'`
   `WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);`
2. During a planned failover: SYNCHRONOUS_COMMIT is the required mode for zero-data-loss
   failover — revert to async after the failover completes
3. Document in runbooks which state is expected (failover window = SYNC; normal = ASYNC)

**Related checks:** F28 (listener URL for distributed AG), F6 (SQL version — requires SQL 2016+)

---

### F33 — AG Databases With Cross-Database Dependencies on Non-AG Databases

**What it means:** If an AG database contains queries, stored procedures, or views that
reference databases outside the AG (via three-part names, linked servers, or `USE [other_db]`),
those references will break after failover. The non-AG databases remain on the old primary
node (or a separate instance), while the AG databases move to the new primary.

**How to spot it:**
Review T-SQL code or application layer for:
- Three-part names: `[OtherDB].[dbo].[TableName]`
- `USE [OtherDB]` within stored procedures that are in an AG database
- Linked server calls to the old primary server name
- `EXEC [LinkedServer].master.dbo.sp_executesql ...`

**Fix options:**
1. Include dependent databases in the same AG (requires all databases to be in FULL recovery)
2. Refactor cross-database dependencies at the AG boundary to use application-layer joins instead
3. If cross-database queries are read-only (reporting), route them through the listener with `ApplicationIntent=ReadOnly` to always target a live replica
4. For linked server calls: update linked server definition to point to the listener DNS name rather than a specific server name

**Related checks:** F2 (FULL recovery required for AG membership), F20 (backup guard function)

---

## Category 7 — Operational Monitoring (F34–F36)

### F34 — No Extended Events Session for AG Diagnostics

**What it means:** Without an AG-specific Extended Events session, lease expiry events, replica
state changes, and log streaming errors are only available in the ERRORLOG (summarized) or
in the Windows Event Log (limited detail). Post-incident root-cause analysis is significantly
harder without a detailed XE trace.

**How to spot it:**
```sql
SELECT name, create_time FROM sys.dm_xe_sessions
WHERE name LIKE '%hadr%' OR name LIKE '%ag%' OR name LIKE '%alwayson%';
-- 0 rows = no AG XE session
```

**Example XE session:**
```sql
CREATE EVENT SESSION [AG_Diagnostics] ON SERVER
  ADD EVENT sqlserver.availability_group_lease_expired,
  ADD EVENT sqlserver.availability_replica_state_change,
  ADD EVENT sqlserver.hadr_log_block_send_complete,
  ADD EVENT sqlserver.hadr_transport_flow_control_action,
  ADD EVENT sqlserver.error_reported
    (WHERE sqlserver.error_number IN (35250, 35264, 35201, 19406))
  ADD TARGET package0.ring_buffer (SET max_memory = 102400)
  WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = ON);
ALTER EVENT SESSION [AG_Diagnostics] ON SERVER STATE = START;
```

**Fix options:**
1. Create the session above (ring buffer, low overhead, always-on)
2. For file target (more history): swap `ring_buffer` for `package0.event_file (SET filename = N'D:\XE\AG_Diagnostics.xel', max_file_size = 50, max_rollover_files = 5)`
3. Use the System Health session as a baseline — it captures some AG events but with limited retention

**Related checks:** H1–H5 (runtime health events that XE would capture in more detail), E1–E8 (ERRORLOG AG events)

---

### F35 — Listener IP Configuration Not Conformant with Windows Cluster

**What it means:** `is_conformant = 0` on a listener IP indicates that the SQL Server catalog
view disagrees with the Windows Failover Cluster IP resource configuration. This mismatch can
prevent the cluster from bringing the listener IP online on the correct subnet during failover.

**How to spot it:**
```sql
-- is_conformant is on sys.availability_group_listeners, not the IP addresses view
SELECT dns_name, port, is_conformant
FROM sys.availability_group_listeners
WHERE is_conformant = 0;
```

**Fix options:**
1. In Failover Cluster Manager, verify the AG listener IP resource matches the IP shown in `sys.availability_group_listener_ip_addresses`
2. If they differ: drop the listener in SQL and recreate it to match the cluster resource, or repair the cluster resource to match the SQL definition
3. Drop and recreate:
   ```sql
   ALTER AVAILABILITY GROUP [ag] REMOVE LISTENER N'listener';
   ALTER AVAILABILITY GROUP [ag] ADD LISTENER N'listener'
     (WITH IP ((N'10.0.1.100', N'255.255.255.0')), PORT = 1433);
   ```
4. After recreation, verify `is_conformant = 1`

**Related checks:** F14 (multi-subnet IPs), F18 (INACTIVE IPs)

---

### F36 — AG Database Count Exceeds Microsoft's Tested Scale Ceiling

**What it means:** Microsoft documents that it has tested up to 10 availability groups and 100
availability databases per physical machine, and explicitly notes this is not an enforced limit
— but it is the boundary of what has actually been validated at scale. Beyond it, the realistic
risks are worker thread exhaustion, slow responses from AG system views and DMVs, and stalled
dispatcher dumps under failure conditions (not necessarily under steady-state load). A migration
that consolidates a very large number of source databases (e.g., from an on-prem FCI or a set of
standalone instances) into a single target AG can land well past this ceiling without anyone
having load-tested that specific shape.

**How to spot it:**
```sql
SELECT ag.name AS ag_name, COUNT(*) AS database_count
FROM sys.availability_groups ag
JOIN sys.availability_databases_cluster adc ON ag.group_id = adc.group_id
GROUP BY ag.name
HAVING COUNT(*) > 100;
```

**Example:**
```
-- Problem: a migration consolidates 200 databases from a retiring on-prem FCI into one
-- 4-replica AG (2 synchronous in the primary region, 2 asynchronous in the DR region).
-- 200 > the 100-database ceiling Microsoft has actually tested — failover time, log-send
-- queue fan-out, and DMV/system-view responsiveness under load are unvalidated at this scale.
```

**Fix options:**
1. Before going live, load-test with a production-like workload under failure conditions
   (not just steady-state) — specifically a forced failover with all databases active — and
   measure failover duration and worker thread headroom.
2. Monitor `sys.dm_os_wait_stats` for `HADR_*` and `DBMIRROR_*` wait categories during the test;
   rising wait time under load is the leading indicator of thread or queue exhaustion.
3. If the test surfaces stress, split the database set across multiple AGs hosted on the same
   replica set — a single instance can host many availability groups, so this doesn't require
   additional hardware, only additional AG definitions and listeners.
4. Re-test after any split to confirm failover time for each AG independently meets the
   migration's RTO target.

**Related checks:** F7 (synchronous replica count — a related but distinct scale dimension),
F9 (health check timeout — symptom surface for an overloaded instance)

---

## Quick Reference Table

| Check | Category | Trigger Summary | Severity |
|-------|----------|----------------|----------|
| F1 | Prerequisites | `IsHadrEnabled = 0` | Critical |
| F2 | Prerequisites | AG database in non-FULL recovery | Critical |
| F3 | Prerequisites | Endpoint missing or not STARTED | Critical |
| F4 | Prerequisites | Endpoint encryption DISABLED or SUPPORTED | Warning/Critical |
| F5 | Prerequisites | failure_condition_level = 1 or 5 | Warning |
| F6 | Prerequisites | Version mismatch across replicas | Warning |
| F7 | Replica Design | ≥ 4 SYNCHRONOUS_COMMIT replicas | Warning |
| F8 | Replica Design | WAN async replica session_timeout < 30 | Warning |
| F9 | Replica Design | health_check_timeout < 15,000 ms | Warning |
| F10 | Replica Design | Backup priority ties with SECONDARY preference | Warning |
| F11 | Replica Design | join_state_desc not JOINED | Warning |
| F12 | Replica Design | Databases missing on joined secondary | Warning |
| F13 | Replica Design | No readable secondary configured | Info |
| F14 | Listener/Network | Multi-subnet listener missing subnet IP | Warning |
| F15 | Listener/Network | read_only_routing_url NULL on readable secondary | Warning |
| F16 | Listener/Network | READ_ONLY_ROUTING_LIST not set on primary | Warning |
| F17 | Listener/Network | Listener port != 1433 | Info |
| F18 | Listener/Network | INACTIVE listener IP without MultiSubnetFailover guidance | Info |
| F19 | Backup Strategy | automated_backup_preference = NONE | Warning |
| F20 | Backup Strategy | Backup jobs missing fn_hadr_backup_is_preferred_replica guard | Warning |
| F21 | Backup Strategy | Log backups not scheduled for FULL recovery AG databases | Warning |
| F22 | Backup Strategy | Backup compression disabled on secondary backup host | Info |
| F23 | Backup Strategy | PRIMARY preference with 3+ replicas | Info |
| F24 | Endpoint Security | Windows auth in cross-domain/workgroup scenario | Warning |
| F25 | Endpoint Security | Endpoint certificate expiry < 90 days | Warning/Critical |
| F26 | Endpoint Security | Endpoint using RC4 algorithm | Critical |
| F27 | Endpoint Security | Endpoint port documented as blocked | Warning |
| F28 | Distributed/Advanced | Distributed AG using instance name not listener URL | Warning |
| F29 | Distributed/Advanced | Basic AG with > 1 database | Warning |
| F30 | Distributed/Advanced | Basic AG with readable secondary configured | Warning |
| F31 | Distributed/Advanced | Contained AG using Windows endpoint auth (SQL 2022+) | Warning |
| F32 | Distributed/Advanced | Distributed AG link set to synchronous (SQL 2016+) | Warning |
| F33 | Distributed/Advanced | Cross-database dependencies on non-AG databases | Info |
| F34 | Monitoring | No XE session for AG diagnostics | Info |
| F35 | Monitoring | Listener IP is_conformant = 0 | Warning |
| F36 | Monitoring | AG database count exceeds Microsoft's tested scale ceiling (>100) | Warning |
