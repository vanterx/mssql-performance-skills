# /sqlclusterlog-review — Example Output

Input: `skills/sqlclusterlog-review/examples/cluster.log`

---

## Cluster Log Analysis

### Summary
- **2 Critical, 2 Warnings, 1 Info**
- **Time range:** 2026/01/15-14:20:00 – 2026/01/15-14:40:00 (20-minute window)
- **Nodes covered:** NODE1, NODE2
- **Highest-risk finding:** [C1 — L1] Lease Timeout — AG1 on NODE1 at 14:32:01

The log captures a complete failover event: NODE1 (primary) experienced SQL Server scheduler
starvation starting at 14:31:00, which prevented the lease renewal thread from running.
After 20 seconds without a successful renewal, the lease expired at 14:32:01.543 and WSFC
declared the AG resource offline. AG1 failed over to NODE2 and was online again within 40
seconds (14:32:40). NODE1 rejoined as a secondary at 14:33:20. Both nodes are synchronized
and stable by the end of the log window.

---

### Critical Issues

### [C1 — L1] Lease Timeout — AG1 on NODE1 (14:32:01)

- **Observed:** At 14:31:00, lease renewal latency was already elevated (1,850 ms). By
  14:31:10, the scheduler was no longer available for 4,200 ms. Latency escalated to 6,800 ms
  (14:31:20), 9,100 ms (14:31:30), and 15,200 ms (14:31:40). At 14:31:55, elapsed time since
  last successful renewal exceeded the 20-second HealthCheckTimeout. At 14:32:01.100, the
  lease thread terminated with message `Lease Thread terminated. Lease time expired.`
  The `[RES]` entry at 14:32:01.543 confirms: `[hadrag] Lease expired. Offline call issued.`
- **Impact:** The lease timeout caused WSFC to immediately declare AG1's resource offline
  on NODE1 with no grace period. All write workloads against the AG1 listener received
  connection errors from approximately 14:32:01 until the failover completed at 14:32:40 —
  a client-visible outage of approximately 39 seconds.
- **Fix:**
  1. Identify the long-running query that caused scheduler starvation between 14:31:00 and
     14:32:01. Capture `sys.dm_os_ring_buffers WHERE ring_buffer_type = 'RING_BUFFER_SCHEDULER_MONITOR'`
     for the incident window and correlate with SQL ERRORLOG and Extended Events for blocking.
  2. Run `/sqlplan-review` on the execution plan of the identified query to locate the
     expensive operator (scan, spill, or hash join) that held the scheduler.
  3. As a short-term guard, review whether `HealthCheckTimeout` on the AG resource property
     should be raised (default: 30,000 ms) to allow more tolerance for brief scheduler delays.
  4. Long-term: add a Resource Governor resource pool to cap CPU consumption by batch queries
     so they cannot saturate all schedulers.

---

### [C2 — L9] AG Offline Transition — Online→Offline (14:32:01)

- **Observed:** At 14:32:01.600, the `[RCM]` entry records:
  `Resource 'SQL Server Availability Group (AG1)': TransitionToState(Online-->Offline) OfflineCallIssued.`
  The transition source was Online (not OnlinePending), confirming the AG was fully running
  and was brought offline unexpectedly — not during a startup attempt.
  The preceding `[hadrag]` entries at 14:32:01.750 confirm: `AG1: PRIMARY_ROLE transitioning
  to RESOLVING_NORMAL. Reason: Lease expiry.`
- **Impact:** The AG resource went offline on the primary node (NODE1). Write operations
  targeting the AG1 listener failed with connection-refused or timeout errors until NODE2
  completed its primary transition at 14:32:40.
- **Fix:** This finding is the direct downstream effect of C1 (lease timeout). The AG
  offline transition itself requires no independent fix — resolving the scheduler starvation
  root cause (C1) will prevent recurrence. Confirm that automatic failover completed
  successfully (it did — NODE2 became primary at 14:32:40 within the expected time window).

---

### Warnings

### [W1 — L4] Error Burst Density — 8 ERR lines in ~3.5 minutes (14:31:42–14:32:01)

- **Observed:** 8 ERR-level entries appeared within a 3.5-minute window:
  - 14:31:42 — `[hadrag]` Lease renewal failed (approaching HealthCheckTimeout)
  - 14:31:44 — `[hadrag]` Lease renewal failed (elapsed 18,100 ms)
  - 14:31:45 — `[RCM]` DLL API (LooksAlive) returned after 62,000 ms
  - 14:31:55 — `[hadrag]` Lease renewal failed (exceeded HealthCheckTimeout)
  - 14:31:58 — `[hadrag]` IsAlive check failed (sp_server_diagnostics timeout)
  - 14:31:59 — `[hadrag]` Resource failure sequence initiated
  - 14:32:01 — `[hadrag]` Lease Thread terminated
  - 14:32:01 — `[RES]` Offline call issued

  The first ERR at 14:31:42 is the originating event; all subsequent ERRs are cascades
  from the same root cause (scheduler starvation → lease thread unable to run).
- **Impact:** The burst confirms a rapid cascade failure. The component ordering (all
  from `[hadrag]` and `[RCM]` on NODE1) indicates this is SQL Server-specific rather than
  a shared infrastructure failure — no `[NM]` or `[NODE]` ERR entries appear in the burst.
- **Fix:** The first ERR entry in the burst (14:31:42) marks the start of the diagnostic
  window. Investigate SQL Server activity between 14:31:00 and 14:31:42 — that is the
  window where the long-running query locked the scheduler. See C1 fix steps.

---

### [W2 — L20] Heartbeat Timeout — 3 missed heartbeats from NODE1 (14:32:03–14:32:07)

- **Observed:** After AG1 went offline on NODE1, NODE2 recorded three consecutive missed
  heartbeats from NODE1:
  - 14:32:03 — `Missed heartbeat #1 from NODE1` (SameSubnetThreshold = 3)
  - 14:32:05 — `Missed heartbeat #2 from NODE1`
  - 14:32:07 — `Missed heartbeat #3 from NODE1 — SameSubnetThreshold reached`
  NODE2 then recalculated quorum (NODE2=1, Witness=1 = 2 votes) and confirmed quorum was
  maintained. NODE1 was not evicted — it rejoined cluster membership at 14:33:15 once the
  SQL Server scheduler recovered.
- **Impact:** The missed heartbeats indicate that NODE1's cluster service thread was also
  affected by the same CPU/scheduler pressure that caused the lease timeout. The cluster
  correctly did not evict NODE1 because quorum was maintained and NODE1 rejoined within
  the expected window. This was a transient condition, not a network failure.
- **Fix:** The missed heartbeats are a secondary symptom of the same scheduler starvation
  as C1. No independent network fix is required. Confirm that `SameSubnetThreshold` (=3)
  and `SameSubnetDelay` are set to appropriate values for same-subnet communication.
  If the starvation event that caused C1 is recurring, the heartbeat failures will recur —
  fix C1 first.

---

### Info

### [I1 — L23] VerboseLogging = 0 — Sparse event density in pre-incident window

- **Observed:** In the 12 minutes before the incident (14:20:00–14:31:00), the log contains
  approximately 1–2 entries per minute from `[hadrag]`. API call durations for individual
  LooksAlive and IsAlive checks are absent in the early window (entries before 14:21:00
  have no `Duration:` field). The log does not record scheduler latency values until the
  degradation began at 14:31:00 — suggesting that VerboseLogging was not enabled, and the
  gradual approach to scheduler saturation is not captured with full detail.
- **Impact:** Without VerboseLogging=1, it is not possible to determine from this log
  whether the scheduler latency issue was building gradually before 14:31:00, or appeared
  suddenly. This limits root cause precision — the query responsible for the starvation
  cannot be pinpointed from the cluster log alone; the SQL ERRORLOG and Extended Events
  must be used for that investigation.
- **Fix:** Enable VerboseLogging on the AG resource on both nodes:
  ```powershell
  Get-ClusterResource | Where-Object {$_.ResourceType -eq 'SQL Server Availability Group'} |
      ForEach-Object { $_ | Set-ClusterParameter VerboseLogging 1 }
  ```
  With VerboseLogging=1, every health check call will include its duration in milliseconds,
  making it possible to see latency trending upward before the threshold is crossed —
  enabling proactive alerting before the next incident.

---

### Passed Checks

| Check | Result |
|-------|--------|
| L2 — Health Check Failure | PASS — IsAlive failure at 14:31:58 is a secondary cascade of L1 (lease timeout), not an independent health check failure. The IsAlive call was not the trigger for the resource offline — the lease expiry was. |
| L3 — RHS Process Crash | PASS — no RHS termination or `creating new RHS process` entries found |
| L5 — Repeated Failover Cycling | PASS — only one failover event in the 20-minute window; AG1 went offline once and recovered without cycling |
| L6 — Quorum Loss | PASS — quorum was maintained throughout (NODE2 + Witness = 2 of 3 votes after NODE1 went silent) |
| L7 — Node Eviction | PASS — NODE1 was not evicted; it rejoined cluster membership at 14:33:15 after the cluster service restarted |
| L8 — Log Time Gap | PASS — no timestamp gaps greater than 5 minutes in the log; coverage is continuous |
| L10 — SQL Connectivity Loss | PASS — no `Disconnect from SQL Server` or ODBC error entries in `[hadrag]` |
| L11 — Forced Failover | PASS — the failover from NODE1 to NODE2 was an automatic failover, not forced; NODE2 was the synchronous commit replica and was SYNCHRONIZED at the time |
| L12 — Long Pending State | PASS — NODE2's OnlinePending duration was 38.3 seconds, within the Warning threshold (30 sec) but below Critical (120 sec). Note: this is borderline — monitor for recurrence |
| L13 — hadrres.dll Init Failure | PASS — no DLL load failure entries in `[RES]` or `[RHS]` |
| L14 — Resource DLL API Timeout | NOTE — the `[RCM]` entry at 14:31:45 records `DLL API call (LooksAlive) returned after 62,000 ms` which technically triggers L14, but this is a direct symptom of the scheduler starvation driving C1 and W1. No independent fix beyond C1 is required. |
| L15 — Cascade Across AGs | PASS — only one AG resource (AG1) appears in ERR entries; no multi-AG cascade |
| L16 — Primary Role Loss | NOTE — AG1 primary role loss on NODE1 is present (`PRIMARY_ROLE transitioning to RESOLVING_NORMAL` at 14:32:01.750) but is logged as a downstream effect of C1 and C2. Not raised as a separate finding. |
| L17 — Replica Disconnection | PASS — NODE2 reconnected to NODE1 at 14:33:28 after NODE1 rejoined; no sustained disconnection |
| L18 — Network Partition / Split-Brain | PASS — no network partition entries in `[NM]`; missed heartbeats (W2) were transient and resolved without partition |
| L19 — Cluster Network Interface Failure | PASS — no NIC failure entries in `[NM]` |
| L21 — Witness Access Failure | PASS — witness contributed its vote (NODE2=1, Witness=1) correctly after NODE1's heartbeat loss |
| L22 — Node Isolation | PASS — NODE1 lost heartbeat but was not isolated from all nodes; cluster service restarted normally |
| L24 — SeparateMonitor Not Set | PASS — insufficient thread-ID detail in this log to confirm SeparateMonitor state. Recommend verifying: `(Get-ClusterResource "SQL Server Availability Group (AG1)") | Get-ClusterParameter SeparateMonitor` |
| L25 — Missing Node Coverage | PASS — log contains entries from both NODE1 and NODE2; 2-node cluster coverage is complete |
