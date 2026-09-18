# sqlblocking-review — Checks Explained (BL1–BL54)

## Contents
- [Blocking Chain Topology Checks (BL1–BL7)](#blocking-chain-topology-checks-bl1bl7)
- [Head-Blocker State Classification (BL8–BL15)](#head-blocker-state-classification-bl8bl15)
- [Lock-Level Evidence Checks (BL16–BL23)](#lock-level-evidence-checks-bl16bl23)
- [Transaction and Isolation Checks (BL24–BL30)](#transaction-and-isolation-checks-bl24bl30)
- [Observability and Platform Configuration Checks (BL31–BL36)](#observability-and-platform-configuration-checks-bl31bl36)
- [Historical and Aggregate Blocking Evidence (BL37–BL42)](#historical-and-aggregate-blocking-evidence-bl37bl42)
- [Structural and Engine-Level Causes (BL43–BL48)](#structural-and-engine-level-causes-bl43bl48)
- [Client, Tooling, and Platform Patterns (BL49–BL54)](#client-tooling-and-platform-patterns-bl49bl54)
- [Background: how blocking works](#background-how-blocking-works)
- [Quick Reference](#quick-reference)

---

## Blocking Chain Topology Checks (BL1–BL7)

### BL1 — Head Blocker Identified

**What it means:** Blocking happens when one session holds a lock and another asks for a conflicting lock on the same resource. Often the blocker is itself blocked, and so on. The session at the top of that tree — blocked by nobody, blocking somebody — is the head blocker. It is the only session whose behaviour matters; every other session in the chain is waiting for a consequence.

**How to spot it:** In `sys.dm_exec_requests`, `blocking_session_id = 0` means the request is not blocked. The head blocker is a session that is not blocked but appears as another session's `blocking_session_id`.

```
session_id  blocked_by  blocking_these  status     wait_type   open_tran
71          0           84, 90          sleeping   NULL        1          <-- head blocker
84          71          92              suspended  LCK_M_U     1
90          71                          suspended  LCK_M_S     0
92          84                          suspended  LCK_M_S     0
```

**Example (problem + fix):** A report shows "SPID 92 is blocked" and the DBA kills 92. The chain re-forms within seconds, because 92 was a victim. Killing 71 — the head — clears 84, 90, and 92 at once.

**Fix options (ranked by impact):**
1. **Report the head blocker fully** — session ID, login, host, program, its current or last statement, `status`, `wait_type`, `open_transaction_count`. Everything else follows from these five columns.
2. **Rank multiple chains** — when several independent head blockers exist, order them by blocked-session count and longest wait.
3. **Never start with the victims** — a kill on a victim frees nothing and costs a rollback.

**Related checks:** BL2, BL3, BL4, BL8–BL15

---

### BL2 — Long Lock Wait

**What it means:** Short blocking is normal and invisible. Blocking becomes an incident when a wait outlives the client's command timeout, at which point the user sees an error instead of a slow response.

**How to spot it:** `wait_time` in `sys.dm_exec_requests` (milliseconds) or `wait_duration_ms` in `sys.dm_os_waiting_tasks`, on waits whose `wait_type` starts with `LCK_M_`.

```
session_id  wait_type   wait_time  wait_resource
84          LCK_M_U     42117      KEY: 7:72057594045267968 (8194443284a0)
```

**Example:** A 42-second `LCK_M_U` wait against an application with a 30-second command timeout means the session already returned a timeout error to the user — and, if the client did not roll back, has now created a future BL9.

**Fix options:**
1. **Compare two captures.** A falling `wait_time` on a changing `wait_resource` means the session is making progress through many short waits; a rising `wait_time` on the same resource means it is stuck behind a stalled head blocker.
2. **Set the severity from the client timeout**, not from an abstract number — a 20-second wait is fatal to a 15-second timeout and harmless to a 120-second batch job.
3. **Use `SET LOCK_TIMEOUT`** in code that can handle failure, so the session fails fast and predictably instead of piling up.

**Related checks:** BL1, BL6, BL9

---

### BL3 — Deep Blocking Chain

**What it means:** Depth means the queue drains in sequence: the head releases, the next session runs and releases, and so on. Total recovery time is the sum of the chain, not the time of one statement.

**How to spot it:** Follow `blocking_session_id` recursively. The capture query in `SKILL.md` prints a `level` column.

```
level  session_id  blocked_by  wait_type   wait_time
0      71          0           NULL                       <-- head
1      84          71          LCK_M_U     42117
2      92          84          LCK_M_S     38004
3      97          92          LCK_M_S     31220
```

**Example:** Four levels on one table during a nightly archive job: the archive holds an exclusive lock, an update waits, a read waits behind the update, and a second read waits behind the first.

**Fix options:**
1. **Fix the head blocker** — depth resolves from the top down.
2. **Look for a single hot object** — deep chains on one table usually mean BL19 (hot resource) or BL16 (escalation).
3. **Do not kill intermediate sessions** — their rollbacks lengthen the outage and free nothing.

**Related checks:** BL1, BL16, BL19

---

### BL4 — Wide Blocking Fan-Out

**What it means:** Fan-out is how many sessions one blocker stops directly. Wide and shallow is the signature of a coarse lock — a table or page lock against many small, unrelated statements.

**How to spot it:** Count distinct `session_id` values sharing one `blocking_session_id`.

```
blocking_session_id  blocked_count  common_resource
71                   14             OBJECT: 7:1893581784 (dbo.Orders)
```

**Example:** Fourteen order-entry sessions blocked by one session holding an `X` lock on `dbo.Orders` — a nightly `DELETE` that escalated to a table lock.

**Fix options:**
1. **Check the lock granularity** — `OBJECT` with mode `S` or `X` means BL16/BL17; `PAGE` means BL19.
2. **Quantify the business impact** — blocked sessions multiplied by longest wait, stated in the report.
3. **Batch the offending write** so it never reaches the escalation threshold.

**Related checks:** BL16, BL17, BL18, BL19

---

### BL5 — Blocking Chain Spans Multiple Databases

**What it means:** One transaction that touches several databases holds locks in all of them until it commits, so a slow step in the second database blocks users of the first.

**How to spot it:** More than one `DB_NAME(resource_database_id)` among the chain's locks, or `transaction_type = 4` (distributed) in `sys.dm_tran_active_transactions`.

```
request_session_id  database_name   resource_type  request_mode  request_status
71                  Sales           KEY            X             GRANT
71                  Archive         OBJECT         IX            GRANT
```

**Example:** A stored procedure writes to `Sales`, then calls a linked server; the remote call takes 40 seconds and the `Sales` locks are held for all of it.

**Fix options:**
1. **Move remote work out of the transaction** — stage remote results first, then open the transaction and write locally.
2. **Check for orphaned distributed transactions** — `request_session_id = -2` in `sys.dm_tran_locks` marks one; resolve it with `KILL '<UOW>'`.

```sql
SELECT request_session_id, resource_type, request_mode
FROM sys.dm_tran_locks
WHERE request_session_id < 0;
```
3. **Prefer asynchronous patterns** (Service Broker, a queue table) over synchronous cross-database writes inside a transaction.

**Related checks:** BL24, BL25

---

### BL6 — Concurrency Exhaustion Risk

**What it means:** Every blocked request holds a worker thread while it waits. Enough blocked requests and the instance runs out of workers, at which point new connections cannot be scheduled and the server appears down even though it is healthy.

**How to spot it:** The share of active requests that are blocked, plus any `THREADPOOL` wait.

```
total_active_requests  blocked_requests  pct_blocked  threadpool_waiters
118                    54                45.8%        6
```

**Example:** A locking incident on a busy OLTP instance escalates into a total outage: logins hang because no worker is free to run them.

**Fix options:**
1. **Connect through the dedicated administrator connection (DAC)** — it has a reserved scheduler.

```sql
-- sqlcmd -S ADMIN:MYSERVER -E -Q "SELECT session_id, blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0"
```
2. **Kill the head blocker**, then diagnose.
3. **Do not raise `max worker threads`** as a fix — more waiting workers consume more memory and delay recovery.

**Related checks:** BL1, BL2, BL14

---

### BL7 — Chronic Head Blocker Across Captures

**What it means:** The same statement, procedure, or client program appearing at the head of a chain in capture after capture means the blocking is designed in, not incidental.

**How to spot it:** Compare `query_hash`, procedure name, or `program_name` at level 0 across captures or across blocked process reports.

```
capture_time         head_session  head_statement                       program_name
2026-09-16 09:05:11  71            UPDATE dbo.Inventory SET OnHand ...  PayrollBatch.exe
2026-09-17 09:05:47  88            UPDATE dbo.Inventory SET OnHand ...  PayrollBatch.exe
2026-09-18 09:06:02  103           UPDATE dbo.Inventory SET OnHand ...  PayrollBatch.exe
```

**Example:** A batch job at 09:05 every weekday blocks the order desk for two minutes. The fix is not a nightly `KILL` script; it is batching the update or moving the job.

**Fix options:**
1. **Classify the structural cause** — query/index (BL35), transaction length (BL24), isolation (BL26/BL29), scheduling (BL15).
2. **Turn on the blocked process report** (BL31–BL33) so recurrences are captured without a DBA watching.
3. **Track it in Query Store** to see whether a plan regression made a previously harmless statement slow enough to block.

**Related checks:** BL15, BL24, BL31, BL35

---

## Head-Blocker State Classification (BL8–BL15)

These eight checks answer one question: will this clear on its own?

| Head blocker looks like | `wait_type` | `open_tran` | `status` | Resolves on its own? |
|---|---|---|---|---|
| BL8 long-running query | not null | ≥ 0 | runnable/running | Yes, when the query finishes |
| BL9 sleeping with open transaction | null | > 0 | sleeping | No — kill or client rollback |
| BL10 orphaned transaction | null | > 0 | sleeping (long idle) | Only when the connection dies |
| BL11 rollback | null | > 0 | rollback | Yes, when the rollback completes |
| BL12 client not fetching | ASYNC_NETWORK_IO | ≥ 0 | runnable | No, until the client fetches or disconnects |
| BL13 distributed deadlock | varies | ≥ 0 | runnable | No, until a client timeout fires |

---

### BL8 — Head Blocker Is a Long-Running Query

**What it means:** The head blocker is simply slow. It acquired locks legitimately and holds them until it finishes. This is a query performance problem wearing a locking costume.

**How to spot it:** `status` of `running`/`runnable`/`suspended` with a non-lock `wait_type`, and `cpu_time`, `reads`, or `logical_reads` increasing between captures.

```
session_id  status     wait_type       cpu_time  logical_reads  command
71          runnable   NULL            48120     9,412,033      SELECT
```

**Example (problem + fix):** A reporting query scanning a 40 GB table under the default isolation level holds shared locks on each page as it reads and blocks writers behind it for six minutes.

**Fix options:**
1. **Tune the query and its indexes** — route to `/sqlplan-review` and `/sqlindex-advisor`; fewer rows read means fewer locks held for less time.
2. **Move reporting off the OLTP path** — a readable secondary replica or a reporting copy.
3. **Enable RCSI** (BL29) so read-only work stops taking shared locks at all.

**Related checks:** BL14, BL23, BL29, BL35

---

### BL9 — Sleeping Head Blocker with an Open Transaction

**What it means:** The session is doing nothing and still holds every lock its transaction took. A cancel or query timeout ends the *batch*, not the *transaction* — the engine cannot assume the whole transaction should be abandoned because one statement was cancelled, so the application has to roll back and did not.

**How to spot it:** `status = 'sleeping'`, `wait_type IS NULL`, `open_transaction_count > 0`.

```
session_id  status    wait_type  open_tran  last_request_end_time   input_buffer
71          sleeping  NULL       1          2026-09-18 09:04:58     UPDATE dbo.Orders SET Status = 'H' WHERE ...
```

**Example (problem + fix):**

```sql
-- Problem: batch cancelled after BEGIN TRAN; locks stay held
BEGIN TRAN;
UPDATE dbo.Orders SET Status = 'H' WHERE OrderId = 4711;
-- client times out here and issues no ROLLBACK

-- Immediate relief
KILL 71;

-- Durable fix, in the client's error handler
IF @@TRANCOUNT > 0 ROLLBACK TRAN;
```

**Fix options:**
1. **`KILL` the session** to release the locks now; expect a rollback proportional to the work done.
2. **Roll back in the application error handler** — `IF @@TRANCOUNT > 0 ROLLBACK TRAN` after any error, including errors the client believes happened outside a transaction (a called procedure may have opened one).
3. **`SET XACT_ABORT ON`** for connections and procedures that open transactions, so a run-time error aborts the transaction automatically. Statements after the failing one will not execute, so check existing flow control first.
4. **Review connection pooling** — a pooled connection returned with an open transaction is not reset until it is reused, so the locks persist in the meantime.

**Related checks:** BL10, BL24, BL27, BL33

---

### BL10 — Orphaned Transaction

**What it means:** A variant of BL9 where nobody is coming back: the client crashed, the workstation restarted, or a batch-aborting error left the transaction open while SQL Server still sees a live connection. The locks are held until the session is killed or the instance restarts.

**How to spot it:** Sleeping session, `open_transaction_count > 0`, and `last_request_end_time` far in the past.

```
session_id  status    open_tran  last_request_end_time   idle_minutes  host_name
71          sleeping  1          2026-09-18 07:41:12     87            WKS-FIN-14
```

**Example (problem + fix):**

```sql
-- Reproduce a batch-aborting error inside a transaction
BEGIN TRAN;
UPDATE dbo.Orders SET Status = 'H' WHERE OrderId = 4711;
INSERT INTO dbo.NonExistentTable VALUES (10);   -- batch aborts, transaction stays open
-- SELECT @@TRANCOUNT still returns 1

-- Release
KILL 71;   -- may take up to 30 seconds
```

**Fix options:**
1. **`KILL` the session.** The command checks for the kill at intervals, so it can take up to 30 seconds to take effect.
2. **Add `Try-Catch-Finally` cleanup** in the application, rolling back in the `finally` path.
3. **`SET XACT_ABORT ON`** so batch-aborting errors roll the transaction back for you.
4. **Alert on idle-with-open-transaction** sessions so they are caught before they block anyone.

**Related checks:** BL9, BL24, BL27

---

### BL11 — Head Blocker Is Rolling Back

**What it means:** The session was killed, cancelled, disconnected, or chosen as a deadlock victim, and is now undoing its work. The rollback has to finish; it cannot be cancelled, and it can take as long as the original operation or longer.

**How to spot it:** `command` shows `KILLED/ROLLBACK` or `status` is `rollback`, with `percent_complete` populated.

```
session_id  command          status    percent_complete  est_completion_time
71          KILLED/ROLLBACK  rollback  38.44             1,142,000
```

**Example:** A one-hour `DELETE` was killed at minute 55. The rollback runs for the better part of an hour, blocking the same sessions the `DELETE` blocked.

**Fix options:**
1. **Wait, and report progress** — `percent_complete` and `estimated_completion_time` give the users an answer.
2. **Do not restart the instance.** Startup recovery repeats the same work with the database offline for its duration.
3. **Prevent the next one** — chunk large writes (BL16 fix 1) and run them off-hours (BL15).
4. **Enable accelerated database recovery** (SQL Server 2019 and later), which makes long rollbacks rare (BL36).

**Related checks:** BL15, BL16, BL36

---

### BL12 — Client Is Not Consuming Results

**What it means:** SQL Server produced rows and is waiting for the client to take them. Until the result set is consumed, the statement is still executing and its locks are still held — so the client's fetch loop, not the server, now sets lock duration.

**How to spot it:** Head blocker waiting on `ASYNC_NETWORK_IO` while holding locks.

```
session_id  status     wait_type          wait_time  open_tran  program_name
71          suspended  ASYNC_NETWORK_IO   61004      1          LegacyReportViewer
```

**Example (problem + fix):**

```csharp
// Problem: work done inside the reader loop, one row at a time
while (reader.Read()) { CallWebService(reader.GetString(0)); }

// Fix: drain the reader first, then do the work
var rows = new List<string>();
while (reader.Read()) rows.Add(reader.GetString(0));
reader.Close();
foreach (var r in rows) CallWebService(r);
```

**Fix options:**
1. **Fetch the result set to completion promptly**, then process.
2. **Return fewer rows** — server-side paging with `OFFSET`/`FETCH` is a supported way to do this.
3. **Isolate clients that cannot be changed** on a reporting copy.

**Related checks:** BL13, BL24, BL25

---

### BL13 — Client/Server Distributed Deadlock

**What it means:** A cycle where one edge is a SQL Server lock and the other is inside the client — one connection waits for a lock held by a second connection, while the second waits for the client thread or buffer that the first occupies. The lock monitor sees only its half, so it never resolves.

**How to spot it:** The head blocker's `host_name` equals the `host_name` of a session it blocks, with `ASYNC_NETWORK_IO` on one side and a lock wait on the other, and no progress across captures.

```
session_id  blocked_by  wait_type          host_name    program_name
71          0           ASYNC_NETWORK_IO   APP-NODE-03  OrderSync
84          71          LCK_M_X            APP-NODE-03  OrderSync
```

**Example:** One application thread reads rows on connection A and inserts them on connection B, against the same table. B blocks on A's locks; A blocks on the thread B is using.

**Fix options:**
1. **Set a query timeout on the client** — the timeout breaks the cycle.
2. **Do not interleave a read on one connection with a write on another** inside a single logical unit; read to completion first.
3. **Use one connection per unit of work**, or MARS where appropriate, rather than two connections cooperating through a shared buffer.

**Related checks:** BL12, BL25

---

### BL14 — Head Blocker Waits on a Non-Lock Resource

**What it means:** The head blocker is not blocked by anyone, but it is slow for a different reason — storage, memory, log flush, or scheduling. The locking is a side effect; fixing the lock behaviour would not help.

**How to spot it:** The head blocker's `wait_type` is an I/O, memory, log, or CPU wait.

```
session_id  blocked_by  wait_type          wait_time  command
71          0           PAGEIOLATCH_SH     28311      UPDATE
```

**Example:** A storage array degrades; the nightly update that normally takes 20 seconds takes eight minutes, and its locks block the morning shift.

**Fix options:**
1. **Route by wait type** — `PAGEIOLATCH_*`/`WRITELOG` to `/sqldiskio-review`, `RESOURCE_SEMAPHORE` to `/sqlmemory-review`, `CXPACKET`/`SOS_SCHEDULER_YIELD` to `/sqlwait-review`.
2. **Re-measure blocking after the resource problem is fixed** — much of it usually disappears.
3. **Shorten the transaction anyway** (BL24) so the next slowdown has a smaller blast radius.

**Related checks:** BL8, BL24, BL35

---

### BL15 — Head Blocker Is Maintenance or System Work

**What it means:** Backups, index maintenance, statistics updates, `DBCC`, and bulk loads take coarse locks or run long. Running them against a live OLTP workload turns a routine job into an outage.

**How to spot it:** `command` names the operation, or `is_user_process = 0`.

```
session_id  is_user_process  command          status   blocked_count
54          1                ALTER INDEX      running  22
```

**Example (problem + fix):**

```sql
-- Problem: offline rebuild takes Sch-M and blocks everything on the table
ALTER INDEX IX_Orders_CustomerId ON dbo.Orders REBUILD;

-- Fix: online, and yield rather than queue the workload behind it
ALTER INDEX IX_Orders_CustomerId ON dbo.Orders
REBUILD WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)));
```

**Fix options:**
1. **Move the job to a low-activity window.**
2. **Use online index operations** where the edition supports them, with `WAIT_AT_LOW_PRIORITY`.
3. **Chunk large deletes and updates** so each transaction is short.
4. **Check `resource_subtype`** — values such as `DATABASE.BULKOP_BACKUP_DB` identify backup-related conflicts rather than DML blocking.

**Related checks:** BL11, BL16, BL18

---

## Lock-Level Evidence Checks (BL16–BL23)

### BL16 — Lock Escalation to a Table Lock

**What it means:** To cap the memory spent tracking locks, the engine converts many row or page locks on one table or index into a single table lock. That table lock blocks every other user of the table, including sessions working on unrelated rows.

**How to spot it:** An `OBJECT` lock with `request_mode` of `S` or `X` held by the head blocker, with its row/page locks gone. An `OBJECT` lock in an intent mode (`IS`, `IU`, `IX`) is *not* escalation. The `lock_escalation` Extended Event confirms it and reports `escalated_lock_count` and `escalation_cause`.

```
request_session_id  resource_type  request_mode  request_status  lock_count
71                  OBJECT         X             GRANT           1
```

**Example (problem + fix):**

```sql
-- Problem: single statement crosses the 5,000-lock threshold and escalates
DELETE FROM dbo.LogMessages WHERE LogDate < '20250102';

-- Fix: batch below the threshold
DECLARE @done bit = 0;
WHILE (@done = 0)
BEGIN
    DELETE TOP (1000) FROM dbo.LogMessages WHERE LogDate < '20250102';
    IF @@rowcount < 1000 SET @done = 1;
END;
```

**Fix options (ranked by impact):**
1. **Break the operation into smaller transactions** — the simplest and safest prevention.
2. **Reduce the lock footprint** with better indexes and SARGable predicates (BL35) so the threshold is never reached.
3. **Per-table opt-out** — `ALTER TABLE dbo.Orders SET (LOCK_ESCALATION = DISABLE)` when one table is the problem; on partitioned tables `AUTO` escalates to the partition instead.
4. **Instance-wide trace flags 1211 or 1224** — a mitigation of last resort while a real fix is prepared, because disabling escalation lets lock memory grow until allocations fail with error 1204, which aborts the statement and rolls back the transaction.

**Related checks:** BL4, BL23, BL34, BL35

---

### BL17 — Exclusive Object-Level Lock Held

**What it means:** A whole-table exclusive lock taken deliberately — by a hint, a bulk load, or DDL — rather than arrived at through escalation. Nothing else can read or write the table.

**How to spot it:** `resource_type = 'OBJECT'`, `request_mode = 'X'`, no escalation evidence.

```sql
SELECT request_session_id, request_mode, request_status,
       object_name = OBJECT_NAME(resource_associated_entity_id)
FROM sys.dm_tran_locks
WHERE resource_type = 'OBJECT' AND request_mode IN ('X','S');
```

**Example (problem + fix):**

```sql
-- Problem
UPDATE dbo.Prices WITH (TABLOCKX) SET Price = Price * 1.05;

-- Fix: no hint; batch by key range
UPDATE TOP (2000) dbo.Prices SET Price = Price * 1.05 WHERE Updated = 0;
```

**Fix options:**
1. **Remove the hint** unless exclusivity is genuinely required.
2. **Schedule `TABLOCK` bulk loads** for a maintenance window (the hint buys minimal logging, so it is often deliberate).
3. **Use partition switching** for load patterns — the switch is a brief metadata operation instead of a long table lock.

**Related checks:** BL16, BL18, BL28

---

### BL18 — Schema Modification Lock Blocking

**What it means:** `Sch-M` conflicts with every other lock mode, including the `Sch-S` lock that ordinary queries take — and that even `READUNCOMMITTED`/`NOLOCK` readers take. One DDL statement therefore stops all access to the object, and a `Sch-M` request that is itself queued behind a long reader will hold up everything arriving after it.

**How to spot it:** `request_mode = 'Sch-M'` granted or waiting, with `Sch-S` waiters behind it.

```
request_session_id  resource_type  request_mode  request_status  subtype
54                  OBJECT         Sch-M         WAIT            INDEX_OPERATION
88                  OBJECT         Sch-S         WAIT
91                  OBJECT         Sch-S         WAIT
```

**Example (problem + fix):**

```sql
-- Problem: DDL queues behind a long-running SELECT, and everything queues behind the DDL
ALTER TABLE dbo.Orders ADD Notes nvarchar(400) NULL;

-- Fix: fail fast instead of queueing, and retry in a quiet window
SET LOCK_TIMEOUT 5000;
ALTER TABLE dbo.Orders ADD Notes nvarchar(400) NULL;
```

**Fix options:**
1. **Run DDL in a maintenance window**, after confirming no long readers are active.
2. **Use `SET LOCK_TIMEOUT`** (and `WAIT_AT_LOW_PRIORITY` for index operations) so a failed attempt backs off rather than blocking the workload behind it.
3. **Prefer online index operations** and metadata-only changes (adding a nullable column without a default is metadata-only in supported versions).

**Related checks:** BL15, BL17, BL28

---

### BL19 — Hot Resource Contention

**What it means:** Many sessions queue on one specific row, page, or key rather than on the table as a whole. The table is fine; one resource inside it is a serialization point.

**How to spot it:** The same `resource_description` or `resource_associated_entity_id` repeated across waiting tasks.

```
session_id  wait_type  wait_duration_ms  resource_description
84          LCK_M_U    9004              KEY: 7:72057594045267968 (8194443284a0)
90          LCK_M_U    8781              KEY: 7:72057594045267968 (8194443284a0)
92          LCK_M_U    8620              KEY: 7:72057594045267968 (8194443284a0)
```

Resolve the object from the `hobt_id`:

```sql
SELECT OBJECT_NAME(object_id) AS table_name, index_id
FROM sys.partitions
WHERE hobt_id = 72057594045267968;
```

**Example (problem + fix):**

```sql
-- Problem: every transaction updates the same counter row
UPDATE dbo.Counters SET NextId = NextId + 1 WHERE Name = 'OrderId';

-- Fix: use a sequence, which does not hold a row lock for the transaction
CREATE SEQUENCE dbo.OrderIdSeq AS bigint START WITH 1 INCREMENT BY 1 CACHE 1000;
SELECT NEXT VALUE FOR dbo.OrderIdSeq;
```

**Fix options:**
1. **Replace counter rows with `SEQUENCE` or `IDENTITY`.**
2. **Address last-page insert contention** on ever-increasing clustered keys — a different key, a hash-distributed leading column, or `OPTIMIZE_FOR_SEQUENTIAL_KEY` on supporting versions.
3. **For queue tables**, read with `READPAST` and row locks so workers skip locked rows instead of queueing.

**Related checks:** BL3, BL4, BL21

---

### BL20 — Key-Range Locks Present

**What it means:** `SERIALIZABLE` protects against phantom rows by locking the *ranges* between keys, not just the rows that exist. Inserts into a range another session has scanned are blocked even when no row conflicts.

**How to spot it:** `request_mode` values beginning with `Range`.

```
request_session_id  resource_type  request_mode  request_status
71                  KEY            RangeS_S      GRANT
84                  KEY            RangeI_N      WAIT
```

**Example (problem + fix):**

```sql
-- Problem: whole transaction at SERIALIZABLE for one race condition
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRAN;
SELECT @n = COUNT(*) FROM dbo.Bookings WHERE SlotId = @slot;
IF @n = 0 INSERT INTO dbo.Bookings (SlotId, ...) VALUES (@slot, ...);
COMMIT;

-- Fix: default isolation, with a targeted lock on the one key
BEGIN TRAN;
SELECT @n = COUNT(*) FROM dbo.Bookings WITH (UPDLOCK, HOLDLOCK) WHERE SlotId = @slot;
IF @n = 0 INSERT INTO dbo.Bookings (SlotId, ...) VALUES (@slot, ...);
COMMIT;
```

**Fix options:**
1. **Confirm the isolation level** (BL26) — some drivers and distributed transaction stacks default to `SERIALIZABLE`.
2. **Scope the strictness** to the statement that needs it with a hint, rather than the whole transaction.
3. **Index the predicate** so the range locked is narrow instead of the whole table.

**Related checks:** BL26, BL28

---

### BL21 — Lock Conversion Wait

**What it means:** The session already holds a lock on the resource and is waiting to upgrade it — usually shared to exclusive, from a read-then-write pattern in one transaction. Two sessions doing this simultaneously deadlock rather than block.

**How to spot it:** `request_status = 'CONVERT'` in `sys.dm_tran_locks`.

```
request_session_id  resource_type  request_mode  request_status
71                  KEY            X             CONVERT
```

**Example (problem + fix):**

```sql
-- Problem: read with S lock, then upgrade to X
BEGIN TRAN;
SELECT @bal = Balance FROM dbo.Accounts WHERE AccountId = @id;
UPDATE dbo.Accounts SET Balance = @bal - @amt WHERE AccountId = @id;
COMMIT;

-- Fix: take the update lock at the read
BEGIN TRAN;
SELECT @bal = Balance FROM dbo.Accounts WITH (UPDLOCK) WHERE AccountId = @id;
UPDATE dbo.Accounts SET Balance = @bal - @amt WHERE AccountId = @id;
COMMIT;

-- Better: one statement, no upgrade at all
UPDATE dbo.Accounts SET Balance = Balance - @amt WHERE AccountId = @id;
```

**Fix options:**
1. **`UPDLOCK` at the read step** so the intent to write is declared up front.
2. **Collapse read-then-write into a single statement.**
3. **`MERGE ... WITH (HOLDLOCK)`** for upsert patterns, so the existence check and the write share one lock.

**Related checks:** BL19, BL26, BL28

---

### BL22 — Application Lock Contention

**What it means:** `sp_getapplock` gives applications a named mutex managed by the lock manager. Contention here is a critical section held too long or released on some code paths but not others — not a data lock at all.

**How to spot it:** `resource_type = 'APPLICATION'`. The `resource_description` carries the database principal ID, the first characters of the resource name, and a hash of the full name.

```
request_session_id  resource_type  request_mode  request_status  resource_description
71                  APPLICATION    X             GRANT           0:[NightlyPost]:(8e1f2b3c)
84                  APPLICATION    X             WAIT            0:[NightlyPost]:(8e1f2b3c)
```

**Example (problem + fix):**

```sql
-- Problem: session-owned lock, released only on the success path
EXEC sp_getapplock @Resource = 'NightlyPost', @LockMode = 'Exclusive', @LockOwner = 'Session';

-- Fix: transaction-owned with a timeout; commit or rollback always releases it
BEGIN TRAN;
EXEC @rc = sp_getapplock @Resource = 'NightlyPost', @LockMode = 'Exclusive',
                         @LockOwner = 'Transaction', @LockTimeout = 5000;
IF @rc < 0 BEGIN ROLLBACK; THROW 50001, 'Could not acquire NightlyPost lock', 1; END
-- ... work ...
COMMIT;
```

**Fix options:**
1. **Use `@LockOwner = 'Transaction'`** (the default) so commit or rollback always releases the lock; a `Session`-owned lock survives until logout and has to be released by a matching `sp_releaseapplock` call for every acquire.
2. **Always pass `@LockTimeout`** and handle the negative return codes: `-1` timed out, `-2` cancelled, `-3` chosen as a deadlock victim, `-999` parameter error. A deadlock on an application lock does not roll the transaction back for you — code the `ROLLBACK` explicitly.
3. **Shrink the critical section** to the smallest operation that needs serialization.

**Related checks:** BL24, BL25

---

### BL23 — Large Lock Footprint

**What it means:** How many locks one session holds on one table or index. A large footprint blocks widely on its own and is the direct precursor to escalation, which is triggered when the count on a single table or index passes 5,000 (checked after the memory threshold).

**How to spot it:** Group `sys.dm_tran_locks` by session and resource.

```
request_session_id  resource_type  request_mode  lock_count
71                  KEY            X             4,812
71                  PAGE           IX            96
```

**Example:** A bookmark lookup with `PREFETCH` raises part of a read-committed query to repeatable-read behaviour and takes thousands of key locks on both indexes — a `SELECT` that looks harmless escalates.

**Fix options:**
1. **Batch the write** so each transaction stays well under the threshold.
2. **Add a covering index** to remove the lookup, which removes both the reads and the locks.
3. **Watch lock memory instance-wide** — lock memory is limited to 60 percent of the visible buffer pool and escalation is considered at 40 percent of that (about 24 percent of the buffer pool); run `/sqlmemory-review` when footprints are large everywhere.

**Related checks:** BL16, BL34, BL35

---

## Transaction and Isolation Checks (BL24–BL30)

### BL24 — Long-Running Open Transaction

**What it means:** Write locks are held until commit or rollback, so transaction duration *is* lock duration. Almost every durable blocking fix reduces to shortening transactions.

**How to spot it:** `transaction_begin_time` in `sys.dm_tran_active_transactions`, joined to the session.

```
session_id  database_name  transaction_begin_time  transaction_duration_s  session_status
71          Sales          2026-09-18 09:01:12     413                     sleeping
```

**Example (problem + fix):**

```sql
-- Problem: validation, remote call, and logging all inside the transaction
BEGIN TRAN;
UPDATE dbo.Orders SET Status = 'P' WHERE OrderId = @id;
EXEC dbo.usp_CallPartnerService @id;          -- seconds of network time, locks held
INSERT INTO dbo.AuditLog (...) VALUES (...);
COMMIT;

-- Fix: do the slow work outside the transaction
EXEC dbo.usp_CallPartnerService @id;
BEGIN TRAN;
UPDATE dbo.Orders SET Status = 'P' WHERE OrderId = @id;
INSERT INTO dbo.AuditLog (...) VALUES (...);
COMMIT;
```

**Fix options:**
1. **Move non-transactional work out** — remote calls, file and queue work, user round-trips, expensive validation reads.
2. **Commit per batch** inside loops rather than wrapping the whole loop.
3. **Enable RCSI** (BL29) when a long read has to stay long — versioning removes its blocking effect even though the transaction stays open.

**Related checks:** BL9, BL25, BL29, BL30

---

### BL25 — Transaction Held Across Client Round-Trips

**What it means:** The transaction spans a trip back to the client — a screen, a service call, a decision loop. Lock duration becomes a function of human or network latency.

**How to spot it:** A session alternating between sleeping-with-open-transaction and brief activity, or a blocked process report whose blocker `<inputbuf>` shows only part of the unit of work.

```xml
<blocking-process>
  <process status="sleeping" spid="71" trancount="1" lastbatchcompleted="2026-09-18T09:02:41.117">
    <inputbuf>BEGIN TRANSACTION; SELECT * FROM dbo.Orders WITH (UPDLOCK) WHERE OrderId = 4711;</inputbuf>
  </process>
</blocking-process>
```

**Example (problem + fix):** An edit form opens a transaction with `UPDLOCK` when the user opens the record and commits when they click Save. Fix: read without locks, then update with an optimistic concurrency check.

```sql
UPDATE dbo.Orders
SET    Status = @newStatus, RowVer = DEFAULT
WHERE  OrderId = @id AND RowVer = @rowVerReadEarlier;
IF @@ROWCOUNT = 0 THROW 50002, 'Record changed by another user', 1;
```

**Fix options:**
1. **Open the transaction after all input is gathered**, and close it in the same batch or procedure.
2. **Use optimistic concurrency** (`rowversion` check) rather than held read locks.
3. **Keep the unit of work server-side** in a stored procedure where possible.

**Related checks:** BL9, BL12, BL24, BL27

---

### BL26 — Elevated Transaction Isolation Level

**What it means:** Under `READ COMMITTED`, shared locks are released as each row is read. Under `REPEATABLE READ` and `SERIALIZABLE`, they are held until the transaction ends, so reads block writers for the whole transaction, and `SERIALIZABLE` adds key-range locks.

**How to spot it:** `transaction_isolation_level` in `sys.dm_exec_sessions` / `sys.dm_exec_requests`: `0` Unspecified, `1` ReadUncommitted, `2` ReadCommitted, `3` RepeatableRead, `4` Serializable, `5` Snapshot.

```
session_id  transaction_isolation_level  program_name
71          4                            .Net SqlClient Data Provider
```

**Example (problem + fix):**

```sql
-- Problem: level left set on a pooled connection, inherited by unrelated work
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- Fix: set explicitly per connection to the level the work needs
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

**Fix options:**
1. **Find the source** — an explicit `SET`, a `TransactionScope` default (`Serializable` in older .NET defaults), or a driver setting.
2. **Set the level explicitly at the start of each unit of work** so pooling cannot hand a strict level to unrelated code.
3. **Use a statement-level hint** where one operation genuinely needs stronger guarantees.

**Related checks:** BL20, BL28, BL29

---

### BL27 — Implicit Transactions Enabled

**What it means:** With `IMPLICIT_TRANSACTIONS ON`, statements such as `SELECT`, `INSERT`, `UPDATE`, and `DELETE` silently start a transaction that stays open until the client commits. Clients written for autocommit never commit, so locks accumulate and the session sits sleeping with an open transaction.

**How to spot it:** BL9's shape — sleeping, `open_transaction_count > 0` — with no `BEGIN TRAN` anywhere in the input buffer, usually from a driver that sets the option.

```
session_id  status    open_tran  input_buffer                               client_interface_name
71          sleeping  1          SELECT OrderId, Status FROM dbo.Orders ...  Microsoft JDBC Driver
```

**Example (problem + fix):**

```sql
-- Confirm the session setting
SELECT session_id, open_transaction_count FROM sys.dm_exec_sessions WHERE session_id = 71;

-- Fix at the connection
SET IMPLICIT_TRANSACTIONS OFF;
```

**Fix options:**
1. **Turn the option off at the driver or connection string** (for example, autocommit mode in JDBC).
2. **Commit explicitly** after each unit of work if implicit transactions are required.
3. **Alert on sleeping sessions with open transactions** so this is caught in test rather than production.

**Related checks:** BL9, BL10, BL25

---

### BL28 — Blocking Lock Hints in the Blocker's Statement

**What it means:** Hints override the engine's lock choice. They are frequently copied from one procedure to the next long after the reason for them is gone, and they convert short locks into transaction-length ones.

**How to spot it:** Read the head blocker's statement text or input buffer for `HOLDLOCK`, `SERIALIZABLE`, `TABLOCK`, `TABLOCKX`, `XLOCK`, `UPDLOCK`, `PAGLOCK`, `REPEATABLEREAD`.

```sql
SELECT * FROM dbo.Orders WITH (TABLOCKX, HOLDLOCK) WHERE Status = 'N';
```

**Example (problem + fix):**

```sql
-- Problem: table-level exclusivity for a single-row guarantee
SELECT @s = Status FROM dbo.Orders WITH (TABLOCKX, HOLDLOCK) WHERE OrderId = @id;

-- Fix: lock only the row the logic depends on
SELECT @s = Status FROM dbo.Orders WITH (UPDLOCK, ROWLOCK) WHERE OrderId = @id;
```

**Fix options:**
1. **Keep only hints a correctness requirement needs**, and document why at the call site.
2. **Scope the hint to the one table and statement** that needs it.
3. **Do not reach for `NOLOCK` as the answer** — `READUNCOMMITTED` permits dirty, missing, and duplicated rows, and still waits behind a `Sch-M` lock (BL18). Row versioning (BL29) gives consistent reads without blocking.

**Related checks:** BL17, BL20, BL21, BL29

---

### BL29 — Reader-Writer Blocking Curable by Row Versioning

**What it means:** Under read committed with locking, a reader waits for a writer's exclusive lock. Under read committed snapshot isolation (RCSI), the reader takes the last committed version of the row from the version store instead and does not wait at all. Writers still block writers.

**How to spot it:** Victims waiting in `LCK_M_S`/`LCK_M_IS` behind `X`/`IX` holders, with read-only statements, on a database where `is_read_committed_snapshot_on = 0`.

```sql
SELECT name, is_read_committed_snapshot_on, snapshot_isolation_state_desc
FROM sys.databases WHERE database_id > 4;
```

**Example (problem + fix):**

```sql
-- Fix (maintenance window: while this runs, this connection must be the only
-- open connection to the database — single-user mode is not required)
ALTER DATABASE Sales SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
```

**Fix options (ranked by impact):**
1. **Enable RCSI** — no query changes needed, and it removes the whole reader-blocked-by-writer class.
2. **Budget the costs first** — TempDB version store space and I/O, 14 bytes added per row as rows are updated, and different semantics for read-then-write logic, which may need `UPDLOCK` to remain correct.
3. **Where RCSI is not acceptable**, shorten the writer's transaction (BL24) or move the readers to a readable secondary.

**Related checks:** BL24, BL26, BL30, BL36

---

### BL30 — Row-Versioning Side Effects

**What it means:** Versioning trades lock waits for version-store growth. The oldest open transaction pins every version created since it started, so one forgotten transaction can grow the store without bound. The store lives in TempDB, unless accelerated database recovery is enabled on the database, in which case versions go to that database's own persistent version store. Under `SNAPSHOT` isolation, conflicting updates raise error 3960 instead of waiting.

**How to spot it:** Version store size against open transaction age.

```sql
SELECT reserved_page_count, reserved_space_kb
FROM sys.dm_tran_version_store_space_usage;

SELECT TOP 5 session_id, transaction_id,
       elapsed_time_seconds, transaction_sequence_num
FROM sys.dm_tran_active_snapshot_database_transactions
ORDER BY elapsed_time_seconds DESC;
```

**Example:** A reporting session left open under `SNAPSHOT` overnight pins versions until TempDB fills and writes across the instance fail.

**Fix options:**
1. **Keep transactions short** (BL24) — the version store drains only when the oldest transaction ends.
2. **Size and monitor the version store's home** — TempDB, or the database's persistent version store under ADR — for the peak, and alert on growth. When TempDB fills, version generation stops and readers that need a missing version fail with error 3958.
3. **Add retry logic for error 3960** under `SNAPSHOT`, or use RCSI, which does not produce update conflicts.

**Related checks:** BL24, BL29

---

## Observability and Platform Configuration Checks (BL31–BL36)

### BL31 — Blocked Process Threshold Not Configured

**What it means:** The blocked process report is the engine's built-in record of who blocked whom, including both sessions' statements. It is off by default, so an incident that ends before a DBA connects leaves nothing to analyse.

**How to spot it:**

```sql
SELECT name, value_in_use FROM sys.configurations
WHERE name = 'blocked process threshold (s)';
```

**Example (problem + fix):**

```sql
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'blocked process threshold', 20;   -- seconds
RECONFIGURE;
```

**Fix options:**
1. **Set a threshold just under the application's command timeout**, so every block the users notice produces a report. The setting takes effect immediately, with no restart.
2. **Create the capture target** at the same time (BL33) — the setting alone generates the event but stores nothing.
3. **Add an Agent alert** on the event if a person should be paged.

**Related checks:** BL32, BL33, BL7

---

### BL32 — Blocked Process Threshold Set Ineffectively

**What it means:** The lock monitor wakes every 5 seconds, so a threshold below 5 cannot detect anything sooner — it only adds work. Set far too high, the threshold never fires for the blocks users actually experience. The supported range is 5 to 86,400 seconds.

**How to spot it:** `value_in_use` between 1 and 4, or far above the client command timeout.

```
name                            value_in_use
blocked process threshold (s)   2
```

**Example:** A threshold of 2 was chosen to "catch everything"; nothing is caught sooner than 5 seconds, and the deadlock monitor does extra work every interval.

**Fix options:**
1. **Use a value of 5 or more**, tuned to the command timeout (5–30 seconds suits most OLTP applications).
2. **Expect one event per reporting interval per blocked task** — a long block reports repeatedly, which is useful for measuring duration.
3. **Treat reports as best-effort** — they are not real-time, so do not build hard automation on their timing.

**Related checks:** BL31, BL33

---

### BL33 — No Capture Target for Blocking Events

**What it means:** Events without a session to record them are lost. A standing Extended Events session turns the next incident into evidence instead of a phone call.

**How to spot it:**

```sql
SELECT s.name, s.startup_state, e.name AS event_name
FROM sys.server_event_sessions AS s
JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
WHERE e.name IN ('blocked_process_report','lock_escalation','attention');
```

**Example (problem + fix):**

```sql
CREATE EVENT SESSION [Blocking] ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.lock_escalation,
ADD EVENT sqlserver.attention
ADD TARGET package0.event_file (SET filename = N'Blocking.xel', max_file_size = 64, max_rollover_files = 8)
WITH (STARTUP_STATE = ON, MAX_DISPATCH_LATENCY = 30 SECONDS);
ALTER EVENT SESSION [Blocking] ON SERVER STATE = START;
```

**Fix options:**
1. **Capture `blocked_process_report`** as the core event, with `STARTUP_STATE = ON`.
2. **Add `attention`** — client timeouts and cancels are what create the orphaned transactions in BL9/BL10.
3. **Add batch-level events during an active investigation** (`sql_batch_completed`, `rpc_completed`) — the DMVs show only the blocker's *last* statement, while an earlier statement in the same transaction is often the one holding the locks.
4. **Remember deadlocks are already captured** by the default `system_health` session; blocked process reports are not.

**Related checks:** BL7, BL31, BL32

---

### BL34 — Lock Escalation Overrides in Effect

**What it means:** Escalation exists to cap lock memory. Trace flags 1211 and 1224 disable it instance-wide, and `LOCK_ESCALATION = DISABLE` disables it per table. Turning it off to stop blocking moves the risk to memory: lock allocations can fail with error 1204, which aborts the statement and rolls back its transaction.

**How to spot it:**

```sql
DBCC TRACESTATUS(1211, 1224, -1);

SELECT OBJECT_NAME(object_id) AS table_name, lock_escalation_desc
FROM sys.tables WHERE lock_escalation_desc <> 'TABLE';
```

**Example:** Trace flag 1211 was enabled during an incident two years ago and never removed; a large archive job now fails with error 1204 and rolls back, blocking longer than the escalation ever did.

**Fix options:**
1. **Prefer per-table `LOCK_ESCALATION = DISABLE`** over the instance-wide flags — the blast radius is one table.
2. **Treat either as temporary** while the query and transaction are fixed (BL16, BL23, BL35).
3. **On partitioned tables use `AUTO`**, so escalation stops at the partition instead of the table.
4. **Know the difference between the flags** — 1211 disables escalation unconditionally, including under memory pressure; 1224 disables it on the lock-count threshold but still escalates when lock memory is high.

**Related checks:** BL16, BL23

---

### BL35 — Scan-Driven Lock Footprint

**What it means:** Locks are a function of rows touched. A scan locks what it reads, so a query that reads a million rows to return ten locks a million rows' worth of resources and holds them for the length of the read. Index tuning is therefore a locking fix.

**How to spot it:** The head blocker's plan shows a scan, a lookup over many rows, or a predicate that cannot seek.

```sql
-- Non-SARGable: function on the column forces a scan and locks everything it reads
SELECT * FROM dbo.Orders WHERE CONVERT(int, CustomerRef) = @c;

-- SARGable: seek, and only the qualifying rows are locked
SELECT * FROM dbo.Orders WHERE CustomerRef = CONVERT(varchar(20), @c);
```

**Example (problem + fix):** A lookup-heavy plan takes thousands of key locks on two indexes; adding the two output columns to the nonclustered index removes the lookup, the extra locks, and the escalation risk.

**Fix options:**
1. **Add a covering index** for the blocking statement — route to `/sqlindex-advisor`.
2. **Make predicates SARGable** — keep functions and conversions off the column side, and fix implicit conversions.
3. **Reduce the rows the transaction touches** — filter earlier, batch larger writes.

**Related checks:** BL8, BL16, BL23

---

### BL36 — Row-Versioning and Locking Platform Features Not Evaluated

**What it means:** Two engine features change blocking behaviour without query changes. Accelerated database recovery (ADR, SQL Server 2019 and later) makes lengthy rollbacks rare, shortening the BL11 outage class. Optimized locking (SQL Server 2025, and always on in Azure SQL Database and Azure SQL Managed Instance under the always-up-to-date and 2025 update policies) replaces many row and key locks with a single transaction-ID (TID) lock and largely avoids escalation; its lock-after-qualification (LAQ) component requires RCSI.

**How to spot it:**

```sql
SELECT name,
       is_accelerated_database_recovery_on,
       is_read_committed_snapshot_on,
       is_optimized_locking_on
FROM sys.databases WHERE database_id > 4;
```

Under optimized locking the diagnostics look different — `XACT` resources in `sys.dm_tran_locks` and `LCK_M_S_XACT`, `LCK_M_S_XACT_READ`, `LCK_M_S_XACT_MODIFY` wait types:

```
request_session_id  resource_type  request_mode  resource_description
71                  XACT           X             7:1284:0
```

**Example (problem + fix):**

```sql
-- ADR first (prerequisite), then optimized locking
ALTER DATABASE Sales SET ACCELERATED_DATABASE_RECOVERY = ON;
ALTER DATABASE Sales SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;  -- enables LAQ
ALTER DATABASE Sales SET OPTIMIZED_LOCKING = ON;
```

**Fix options:**
1. **Enable ADR** where long rollbacks are the outage (BL11); it is also the prerequisite for optimized locking.
2. **Enable RCSI** to get the LAQ benefit and the BL29 benefit at once.
3. **Validate before enabling optimized locking** — lock hints reduce its benefit, and code that depends on strict execution order under RCSI can produce different results, which the stricter isolation levels address.
4. **Read chains with the new shape in mind** — a single `XACT` lock replaces the row and key locks you would otherwise expect to see.

**Related checks:** BL11, BL16, BL29, BL30

---

## Historical and Aggregate Blocking Evidence (BL37–BL42)

### BL37 — Lock Waits Dominate but No Chain Was Captured

**What it means:** Wait statistics tell you blocking happened and how much it cost. They can never tell you who caused it, because a session that *takes* a lock records no wait — only the session that *waits* for one does. This is the single most common analytical dead end in blocking work: a top-waits report full of `LCK_M_*` looks like an answer and is only a measurement.

**How to spot it:** `LCK_M_*` entries high in `sys.dm_os_wait_stats` (or in `sp_BlitzFirst @SinceStartup = 1`) with no chain capture in the input.

```
wait_type       wait_time_ms   pct_total   waiting_tasks_count
LCK_M_S         48,221,004     31.4%       412,118
LCK_M_U          9,004,551      5.9%        61,442
PAGEIOLATCH_SH   7,118,233      4.6%     1,204,551
```

**Example (problem + fix):** A DBA reports "31% of our waits are locking" and asks which query to tune. No query can be named from this data. The next step is capture, not tuning:

```sql
-- Turn the measurement into evidence
EXEC sp_configure 'blocked process threshold', 15;  RECONFIGURE;   -- BL31
-- plus an XE session on blocked_process_report                     -- BL33
-- plus per-index attribution for where it is happening             -- BL38
```

**Fix options:**
1. **Read the lock modes for direction** — `LCK_M_S`/`LCK_M_IS` means readers waiting behind writers, which RCSI removes outright (BL29); `LCK_M_X`/`LCK_M_U` is writer-versus-writer, which RCSI does not fix; `LCK_M_SCH_S` means something holds `Sch-M` (BL18, BL43, BL44).
2. **Set up the blocked process report** for blocks above five seconds (BL31–BL33).
3. **Add a sampled capture** for shorter blocking the report cannot see (BL42).
4. **Attribute by object** with index operational stats (BL38) while you wait for the next occurrence.

**Related checks:** BL29, BL31, BL33, BL38, BL42

---

### BL38 — Lock Wait Hot Spots by Index

**What it means:** `sys.dm_db_index_operational_stats` accumulates lock wait counts and durations per index partition. It is the closest thing SQL Server has to a built-in "which objects have been blocking" history, and it needs nothing enabled in advance.

**How to spot it:** Aggregate `row_lock_wait_in_ms + page_lock_wait_in_ms` per index and rank.

```
table_name        index_name              total_lock_wait_ms  row_lock_wait_count  avg_row_lock_wait_ms  promotion_attempts
dbo.Orders        PK_Orders                      412,004               1,204               342                 38
dbo.Inventory     IX_Inventory_SkuId              88,110                 402               219                  0
dbo.AuditLog      PK_AuditLog                     61,233               8,914                 7                  0
```

`dbo.Orders` carries 73% of the database's lock wait time — that is where the transaction and index work belongs.

**Example (problem + fix):**

```sql
SELECT  table_name = OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id),
        index_name = ISNULL(i.name, '(heap)'),
        total_lock_wait_ms = os.row_lock_wait_in_ms + os.page_lock_wait_in_ms,
        os.row_lock_wait_count, os.page_lock_wait_count,
        os.index_lock_promotion_attempt_count, os.index_lock_promotion_count
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE os.row_lock_wait_in_ms + os.page_lock_wait_in_ms > 0
ORDER BY total_lock_wait_ms DESC;
```

**Fix options (ranked by impact):**
1. **Treat the top object as the target** for the transaction-length and index work in BL24, BL35, and BL46.
2. **Take two snapshots** and subtract, so the numbers describe the window you care about rather than everything since restart.
3. **Know the blind spots:** counters live in the index's metadata cache entry and reset when it is evicted or the object is rebuilt, and only row and page lock waits are counted — `OBJECT`, `METADATA`, and `APPLICATION` lock waits (BL17, BL18, BL22) never appear here.

**Related checks:** BL19, BL23, BL35, BL39, BL46

---

### BL39 — Lock Escalation Attempts Recorded Against an Index

**What it means:** `index_lock_promotion_attempt_count` counts escalation attempts; `index_lock_promotion_count` counts the ones that succeeded. A large gap means the engine wanted a table lock repeatedly and could not get one, because another session held an incompatible table-level lock. It kept going with fine-grained locks and retried at every 1,250 further locks.

**How to spot it:**

```
table_name    index_name    promotion_attempts  promotions  row_lock_count
dbo.Orders    PK_Orders                    38           2        4,912,004
```

**Example (problem + fix):** A nightly archive `DELETE` attempts escalation 38 times per run. It only succeeded twice, so it mostly *did not* escalate — but the 4.9 million row locks it holds are themselves the blocking problem, and the two successes were table locks nobody expected.

```sql
-- Fix: batch so the statement never approaches the threshold
DECLARE @rows int = 1;
WHILE @rows > 0
BEGIN
    DELETE TOP (1000) FROM dbo.Orders WHERE OrderDate < @cutoff;
    SET @rows = @@ROWCOUNT;
END;
```

**Fix options:**
1. **Batch the statement** — escalation is triggered at 5,000 locks on a *single reference* to a table, so smaller units never reach it.
2. **Reduce locks per row** with a covering index or a SARGable predicate (BL35, BL48).
3. **Do not reach for trace flags 1211/1224** (BL34); attempts recorded here are a reason to fix the statement, not to remove the memory cap.

**Related checks:** BL16, BL23, BL34, BL38

---

### BL40 — Query Store Lock Wait History Unused or Concentrated

**What it means:** From SQL Server 2017, Query Store records per-query waits by category and keeps them for the configured retention. The `Lock` category is blocking, attributed to the query that waited — the one thing plain wait statistics cannot do.

**How to spot it:**

```sql
SELECT TOP (10)
       qsq.query_id,
       total_lock_wait_ms = SUM(ws.total_query_wait_time_ms),
       query_sql_text     = MIN(qst.query_sql_text)
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_plan       AS qsp ON qsp.plan_id  = ws.plan_id
JOIN sys.query_store_query      AS qsq ON qsq.query_id = qsp.query_id
JOIN sys.query_store_query_text AS qst ON qst.query_text_id = qsq.query_text_id
WHERE ws.wait_category_desc = 'Lock'
GROUP BY qsq.query_id
ORDER BY total_lock_wait_ms DESC;
```

**Example (problem + fix):** Three queries account for 91% of lock wait time, and all three read `dbo.Orders`. That is the same finding as BL38 from the other direction — the victims and the object agree, so the blocker is something writing `dbo.Orders` on a long transaction.

**Fix options:**
1. **Turn Query Store on** where it is off; it is the cheapest historical record of blocking victims.
2. **Read it as victims, not culprits** — pair with BL38 (object) and the blocked process report (blocker) before drawing conclusions.
3. **Check for a regression** — a query that only recently started accumulating lock waits often changed plan (route to `/sqlquerystore-review`), or its blocker did.

**Related checks:** BL7, BL37, BL38

---

### BL41 — Blocking Performance Counters Not Baselined

**What it means:** *Processes blocked* is a live count of currently blocked requests, and the `Locks` object counters measure the rate and duration of lock waits. They are cheap enough to sample continuously, which makes them the right trigger for deeper, more expensive capture.

**How to spot it:**

```sql
SELECT object_name = RTRIM(object_name), counter_name = RTRIM(counter_name), cntr_value
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE '%General Statistics%' AND counter_name = 'Processes blocked')
   OR (object_name LIKE '%Locks%' AND counter_name IN ('Lock Waits/sec','Lock Wait Time (ms)','Lock Timeouts/sec'));
```

```
object_name                  counter_name         cntr_value
SQLServer:General Statistics Processes blocked             9
SQLServer:Locks              Lock Waits/sec            41221
```

**Example:** Nine processes blocked at every sample across an hour is chronic blocking, not an incident — it belongs with BL7 and with a structural fix, not with a nightly `KILL`.

**Fix options:**
1. **Sample on a schedule and record a baseline** — "normal" is workload-specific; the number matters only against its own history.
2. **Alert on a sustained non-zero value**, not on a single sample, since brief blocking is normal.
3. **Attach the capture to the alert** (BL42, BL54) so evidence exists before a human logs in.
4. **Note the counter types** — `Lock Waits/sec` and similar are cumulative counters; compute a rate from two samples rather than reading the raw value.

**Related checks:** BL7, BL42, BL54

---

### BL42 — No Sampled Blocking Log for Short-Duration Blocking

**What it means:** The blocked process report only fires above its configured threshold, and the lock monitor that generates it wakes every five seconds. Blocking that lasts two or three seconds — enough to miss an SLA, enough for users to complain — is invisible to it. Sampling a blocking-aware snapshot into a table covers that gap.

**How to spot it:** Reports of repeated short stalls with an empty blocked process report, and no logging table in the input.

**Example (problem + fix):**

```sql
-- Log the blocking chain every 10 seconds into a table, while investigating
EXEC sp_WhoIsActive
     @find_block_leaders = 1,
     @sort_order = '[blocked_session_count] DESC',
     @destination_table = 'dbo.WhoIsActiveLog';
```

Schedule it with an Agent job for the window under investigation, and turn it off afterwards.

**Fix options:**
1. **Sample faster than the blocking clears** — a 10-second interval finds 3-second stalls only by luck; 1–5 seconds during an active investigation is usual.
2. **Log the chain, not just counts** — `blocked_session_count` plus `blocking_session_id` plus statement text is what BL1–BL15 need.
3. **Stop when the investigation ends.** Continuous logging that nobody reads is overhead with no diagnostic value.
4. **Prefer the vendor monitoring tool** if one exists and already stores blocking history; learn it before the incident rather than during it.

**Related checks:** BL2, BL7, BL31, BL41, BL54

---

## Structural and Engine-Level Causes (BL43–BL48)

### BL43 — Benign Head Blocker with a Blocking Request Queued Behind It

**What it means:** Lock requests are granted in order. Once an incompatible request is waiting, later requests queue behind it even if they would have been compatible with what is currently granted. So a harmless long-running `SELECT` (holding `Sch-S`) stalls an index rebuild (`Sch-M`), and everything arriving after the rebuild stops too — while the monitoring tool names the innocent `SELECT` as the lead blocker.

**How to spot it:** The head blocker is a plain reader, its direct waiter wants `Sch-M` or a table-level `X`/`S`, and the sessions below that want modes the head blocker alone would never conflict with.

```
level  session_id  blocked_by  wait_type       request_mode  statement
0      54          0           NULL            Sch-S         SELECT ... FROM dbo.Orders (long report)
1      61          54          LCK_M_SCH_M     Sch-M         ALTER INDEX IX_Orders ... REBUILD
2      72          61          LCK_M_SCH_S     Sch-S         SELECT OrderId FROM dbo.Orders WHERE OrderId = @p1
3      78          61          LCK_M_SCH_S     Sch-S         INSERT dbo.Orders ...
```

**Example (problem + fix):**

```sql
-- Problem: rebuild queues behind a long reader and blocks everything after it
ALTER INDEX IX_Orders_CustomerId ON dbo.Orders REBUILD;

-- Fix: online, and yield instead of queueing
ALTER INDEX IX_Orders_CustomerId ON dbo.Orders
REBUILD WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF)));
```

**Fix options (ranked by impact):**
1. **Read one level down before acting.** Killing the apparent head blocker just lets the `Sch-M` operation proceed — often the more disruptive outcome.
2. **Make the queued operation yield** — `ONLINE = ON` plus `WAIT_AT_LOW_PRIORITY`; set the equivalent parameters in whatever schedules your index maintenance.
3. **Consider resumable index operations** where supported, so a rebuild can be paused rather than held.
4. **Shorten the reader** or move it to a replica (BL8), so the window for this collision closes.

**Related checks:** BL1, BL15, BL18, BL44, BL45

---

### BL44 — Statistics Update Blocking on Schema Locks

**What it means:** Creating or updating statistics takes a schema modification (`Sch-M`) lock on the statistics metadata object; every query compilation takes schema stability (`Sch-S`) on the same object. They conflict. Synchronous automatic updates — the default — additionally make the triggering query wait for the update, which looks like a random timeout on a normally fast query.

**How to spot it:** A session running `UPDATE STATISTICS` or an automatic update holding or waiting for `Sch-M`, with compiling sessions queued on `Sch-S`.

```
session_id  command            request_mode  request_status  blocked_count
88          UPDATE STATISTICS  Sch-M         WAIT                      17
```

**Example (problem + fix):**

```sql
-- SQL Server 2022+ / Azure SQL: let the background stats update queue at low priority
ALTER DATABASE SCOPED CONFIGURATION SET ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY = ON;

-- Where client timeouts are aggressive, stop queries waiting for the update itself
ALTER DATABASE Sales SET AUTO_UPDATE_STATISTICS_ASYNC ON;

-- Before planned index maintenance, update manually so an automatic update does not fire mid-window
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
```

**Fix options:**
1. **`ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY = ON`** (SQL Server 2022 and later, Azure SQL Database, Azure SQL Managed Instance) — the background update waits for `Sch-M` on a low-priority queue instead of blocking compiles.
2. **`AUTO_UPDATE_STATISTICS_ASYNC`** where synchronous waits cause client timeouts; accept that the triggering query compiles on stale statistics.
3. **Pre-update statistics** before maintenance windows.
4. **On readable secondaries**, automatic temporary statistics take the same `Sch-M` and can stall redo — see BL52 and the `READABLE_SECONDARY_TEMPORARY_STATS_AUTO_CREATE` / `READABLE_SECONDARY_TEMPORARY_STATS_AUTO_UPDATE` database-scoped configurations.
5. **Manually created statistics** can block schema changes; from SQL Server 2022 the `AUTO_DROP` option lets them behave like auto-created statistics instead.

**Related checks:** BL18, BL43, BL52

---

### BL45 — Lock Partitioning Amplifies Table-Level Lock Acquisition

**What it means:** On instances with a larger number of logical CPUs, the engine enables lock partitioning automatically: one object lock resource becomes many, one per partition. `NL`, `Sch-S`, `IS`, `IU`, and `IX` are taken on a single partition, but `S`, `X`, `Sch-M`, and other full modes must be taken on *every* partition, in partition-ID order. A table-wide request therefore acquires partitions one at a time and stops at the first partition holding a conflicting intent lock — half-granted, blocking arrivals on the partitions it already owns while itself waiting on one session.

**How to spot it:** `resource_lock_partition` is non-zero in `sys.dm_tran_locks`, the ERRORLOG records lock partitioning at startup, and a table-level request is stuck with an oddly small number of apparent blockers.

```
request_session_id  resource_type  request_mode  request_status  resource_lock_partition
61                  OBJECT         Sch-M         GRANT                                 0
61                  OBJECT         Sch-M         GRANT                                 1
61                  OBJECT         Sch-M         WAIT                                  6
54                  OBJECT         Sch-S         GRANT                                 6
```

Session 61 holds partitions 0–5 and waits on partition 6, where session 54's `Sch-S` sits. Everything arriving on partitions 0–5 is now blocked by 61.

**Example:** An index rebuild on a 32-core box takes far longer to acquire its lock than the same rebuild on a small test server — not because the rebuild is slower, but because it must collect 32 partitions while new readers keep arriving.

**Fix options:**
1. **Do not disable lock partitioning** — it exists to remove spinlock contention on busy objects, and there is no supported switch for it.
2. **Remove the need for table-wide locks** — online and low-priority DDL (BL43), no `TABLOCK`/`TABLOCKX` hints (BL28), batched writes (BL16).
3. **Expect more deadlocks** on these machines when table-wide locks are common, and handle them with retry (BL50).
4. **Note the memory cost** — a full-mode lock on a partitioned resource is effectively one lock per partition, which inflates lock memory (BL23).

**Related checks:** BL16, BL18, BL23, BL28, BL43

---

### BL46 — Unindexed Foreign Key Child Table

**What it means:** When a parent row is deleted, or its key updated, the engine must check for referencing rows in every child table. Without an index on the child's foreign key column, that check is a scan — which takes locks across the child, lengthens the parent transaction, and can cross the escalation threshold. The statement text mentions only the parent, so the blocking looks inexplicable.

**How to spot it:** The head blocker deletes or updates a parent, the lock evidence names a child table, and the child's foreign key column leads no index.

```sql
-- Foreign keys with no supporting index in the child table
SELECT  parent_table = OBJECT_NAME(fk.parent_object_id),
        fk.name,
        fk_column = COL_NAME(fkc.parent_object_id, fkc.parent_column_id)
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
WHERE NOT EXISTS (
    SELECT 1 FROM sys.index_columns AS ic
    WHERE ic.object_id = fkc.parent_object_id
      AND ic.column_id = fkc.parent_column_id
      AND ic.key_ordinal = 1);
```

**Example (problem + fix):**

```sql
-- Problem: deleting one customer scans dbo.Orders to enforce FK_Orders_Customers
DELETE FROM dbo.Customers WHERE CustomerId = @id;

-- Fix: index the child's FK column
CREATE NONCLUSTERED INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId);
```

**Fix options:**
1. **Index the foreign key column** in the child table, leading.
2. **Batch cascading deletes** if the child is large, even with the index.
3. **Check every child** of the parent — one unindexed child is enough to cause the scan.
4. **Expect a deadlock class to disappear** too; this pattern causes both.

**Related checks:** BL19, BL23, BL35, BL47

---

### BL47 — Trigger or Cascading Constraint Extends the Transaction

**What it means:** Triggers and cascading foreign key actions execute inside the calling transaction. Their locks are held until the caller commits, and their duration is added to the caller's — so a one-row `UPDATE` can hold locks on three tables for as long as an audit insert takes.

**How to spot it:** The head blocker's lock footprint includes tables its statement never mentions.

```
request_session_id  resource_type  request_mode  object
71                  KEY            X             dbo.Orders        <- named by the statement
71                  KEY            X             dbo.AuditLog      <- from a trigger
71                  KEY            X             dbo.OrderLines    <- from ON DELETE CASCADE
```

**Example (problem + fix):**

```sql
-- Problem: every writer serialises on one audit table inside the caller's transaction
CREATE TRIGGER trg_Orders_Audit ON dbo.Orders AFTER UPDATE AS
    INSERT dbo.AuditLog (OrderId, ChangedAt) SELECT OrderId, SYSDATETIME() FROM inserted;

-- Fix: use a built-in mechanism that does not extend the transaction's lock footprint
ALTER TABLE dbo.Orders SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.OrdersHistory));
```

**Fix options:**
1. **Move secondary work out of the transaction** — a queue, Service Broker, change tracking, Change Data Capture, or a temporal table instead of a hand-written audit trigger.
2. **Index the tables the cascade touches** (BL46).
3. **Keep trigger bodies seek-only** — a scan inside a trigger is a scan inside every caller's transaction.
4. **Watch for the hot log table** — a single append-only audit table is a classic hot resource (BL19).

**Related checks:** BL19, BL24, BL46

---

### BL48 — Write Statement Locks Every Row It Reads

**What it means:** An `UPDATE` or `DELETE` takes update locks on rows as it *examines* them, not only on the rows that qualify. A non-SARGable write predicate therefore scans and locks its way through an entire index to change a handful of rows — a lock footprint wildly out of proportion to the work done.

**How to spot it:** Lock counts far exceeding rows modified, plus a scan or a function-wrapped column in the plan.

```
session_id  statement                                                  rows_modified  locks_held
71          UPDATE dbo.Orders SET Status='H' WHERE CONVERT(int,Ref)=@r            12      482,110
```

**Example (problem + fix):**

```sql
-- Problem: function on the column forces a scan; every row read is locked
UPDATE dbo.Orders SET Status = 'H' WHERE CONVERT(int, CustomerRef) = @r;

-- Fix: keep the column bare so the index can seek
UPDATE dbo.Orders SET Status = 'H' WHERE CustomerRef = CONVERT(varchar(20), @r);
```

**Fix options:**
1. **Fix the predicate** — no functions or conversions on the column side; match parameter types to column types so no implicit conversion appears.
2. **Index the predicate** so a seek replaces the scan.
3. **Batch legitimately large writes** so no single transaction reaches the escalation threshold (BL16).
4. **Check the plan, not just the text** — an implicit conversion is invisible in the T-SQL and obvious in the plan.

**Related checks:** BL16, BL23, BL35, BL39

---

## Client, Tooling, and Platform Patterns (BL49–BL54)

### BL49 — ORM or Driver Transaction Defaults

**What it means:** A large share of production blocking comes from framework defaults rather than deliberate application design. The connection arrives with an isolation level or a transaction mode the developer never chose, and every pooled connection inherits it.

**How to spot it:** `program_name` / `client_interface_name` identifies a managed driver or ORM, and the session shows a framework signature: elevated isolation with no `SET` in the statement text, an open transaction with no `BEGIN TRAN`, or several sessions from one host interleaving.

```
session_id  program_name                    client_interface_name    iso_level  open_tran  status
71          .Net SqlClient Data Provider    .Net SqlClient           4          1          sleeping
84          Microsoft JDBC Driver           Microsoft JDBC Driver    2          1          sleeping
```

**Example (problem + fix):**

```csharp
// Problem: TransactionScope with no options defaults to Serializable
using (var scope = new TransactionScope()) { /* ... */ }

// Fix: state the isolation level you actually need
using (var scope = new TransactionScope(
    TransactionScopeOption.Required,
    new TransactionOptions { IsolationLevel = IsolationLevel.ReadCommitted }))
{ /* ... */ }
```

**Fix options:**
1. **Set isolation explicitly in the framework**, not in T-SQL — the setting arrives with the connection.
2. **Turn off implicit transactions** at the driver (autocommit in JDBC and several Python drivers) — see BL27.
3. **Review MARS** where one connection interleaves statements, which changes when locks are released.
4. **Check the pool**: a connection returned with an open transaction is not reset until it is reused.

**Related checks:** BL13, BL25, BL26, BL27

---

### BL50 — No Client Timeout or Retry Policy

**What it means:** A blocked request that waits forever turns one stuck session into many, and eventually into worker exhaustion. Timeouts, lock timeouts, and bounded retry are what keep a locking incident from becoming an outage — provided each of them rolls back properly.

**How to spot it:** Victim waits far exceeding any sane client timeout with no cancellation, or recurring orphaned transactions after timeouts (BL10).

**Example (problem + fix):**

```sql
-- Fail fast where the work can be retried safely
SET LOCK_TIMEOUT 5000;            -- error 1222 after 5 seconds
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.Orders SET Status = 'H' WHERE OrderId = @id;
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;  -- without this, the timeout creates a BL9
    THROW;
END CATCH;
```

**Fix options:**
1. **Set a command timeout** on the client, and handle the error.
2. **Add `SET LOCK_TIMEOUT`** for work that can fail fast — always with a rollback handler, since a timeout without rollback is how BL9/BL10 are created.
3. **Retry with backoff**, bounded, for operations that are safe to repeat.
4. **Set `DEADLOCK_PRIORITY` deliberately** on batch work so interactive sessions survive.

**Related checks:** BL2, BL6, BL9, BL10

---

### BL51 — Azure SQL Platform Differences Not Accounted For

**What it means:** The blocking model is the same on Azure SQL, but the defaults and the tooling are not. Applying on-premises assumptions produces recommendations that cannot be implemented, or that are already in place.

**How to spot it:** The artifact comes from Azure SQL Database, Azure SQL Managed Instance, or Fabric SQL database.

```sql
SELECT name, is_read_committed_snapshot_on, snapshot_isolation_state_desc
FROM sys.databases WHERE name = DB_NAME();
```

**Example:** A recommendation to "enable RCSI to stop readers blocking writers" is a no-op on a new Azure SQL Database, where RCSI is already on — so remaining blocking is writer-versus-writer, an isolation level set by the client, or RCSI explicitly disabled.

**Fix options:**
1. **Confirm RCSI and snapshot isolation** rather than assuming; they are on by default for new Azure SQL databases.
2. **Expect optimized locking** — `XACT` resources and `LCK_M_S_XACT*` waits are normal there (BL36).
3. **Skip BL31/BL32** — the blocked process threshold is not user-configurable; capture through Extended Events, and read waits from `sys.dm_db_wait_stats` (database-scoped).
4. **Scale reads out to a replica** instead of a reporting server, and expect transient-fault retry to be part of the application (BL50).

**Related checks:** BL29, BL31, BL36, BL50

---

### BL52 — Readable Secondary Redo Blocked by Report Queries

**What it means:** On a readable secondary, the redo thread applies schema changes coming from the primary and needs schema modification locks to do it. A long-running report holding schema stability blocks redo. The secondary stops keeping up, the redo queue grows, and both failover time and the data-loss window grow with it — a locking problem with an availability consequence.

**How to spot it:** Redo progress stalled behind reader locks, or AG redo waits accumulating while long readers run.

```
session_id  command     wait_type           request_mode  blocked_by  statement
16 (redo)   REDO        LCK_M_SCH_M         Sch-M         92          (redo thread)
92          SELECT      NULL                Sch-S         0           SELECT ... FROM dbo.Orders (report, 22 min)
```

**Example (problem + fix):** A 20-minute report on the secondary holds `Sch-S`; an `ALTER TABLE` replicated from the primary stalls redo for the same 20 minutes, and the redo queue grows to hundreds of megabytes.

**Fix options:**
1. **Keep secondary reports short**, and give them a lock timeout so they yield rather than stall redo.
2. **Schedule schema changes** on the primary for windows when the secondary is not serving long reads.
3. **Evaluate the temporary-statistics configurations** — `READABLE_SECONDARY_TEMPORARY_STATS_AUTO_CREATE` and `READABLE_SECONDARY_TEMPORARY_STATS_AUTO_UPDATE` — since automatic temporary statistics take the same `Sch-M` (BL44).
4. **Quantify the exposure** with `/sqlhadr-review` (redo queue, estimated recovery time) before changing the reporting schedule.

**Related checks:** BL18, BL44, BL53

---

### BL53 — Head Blocker Waiting on Commit Acknowledgement

**What it means:** The head blocker has finished its work and is waiting for somebody else to acknowledge the commit, holding every lock it took. In a synchronous-commit availability group, that somebody is the secondary hardening the log; in a distributed transaction, it is the coordinator. Either way the blocking cause has moved outside this instance.

**How to spot it:** The head blocker's `wait_type` is `HADR_SYNC_COMMIT` or a distributed-transaction wait, with locks still held.

```
session_id  blocked_by  wait_type          wait_time  open_tran  command
71          0           HADR_SYNC_COMMIT      18,442          1  UPDATE
```

**Example:** A WAN-connected synchronous replica adds 18 seconds of commit latency during a network incident; every writer on the primary inherits that as lock duration.

**Fix options (ranked by impact):**
1. **Fix the commit path** — secondary log write latency (`/sqldiskio-review`), network latency, or replica health (`/sqlhadr-review`).
2. **Reconsider the replica's availability mode** if synchronous commit across that link is not a real requirement.
3. **Shorten transactions** so fewer locks ride along on the commit wait (BL24).
4. **Keep remote calls outside transactions** for the distributed-transaction case (BL5).

**Related checks:** BL5, BL14, BL24, BL52

---

### BL54 — No Alerting or Escalation Path for Blocking

**What it means:** Detection without a response is just a nicer way to be surprised. The value of the blocked process report, the counters, and the sampled log is realised only when something fires on them and someone knows what they are allowed to do.

**How to spot it:** Recurring blocking (BL7) with no alert on blocked processes or on the blocked process report event, and no written rule about who may `KILL`.

**Example (problem + fix):**

```sql
-- Alert on the blocked process report event (error 833-style pattern: use an Agent alert on the XE, or on a job that polls the counter)
EXEC msdb.dbo.sp_add_alert
     @name = N'Blocking - processes blocked sustained',
     @performance_condition = N'SQLServer:General Statistics|Processes blocked||>|5',
     @notification_message = N'Blocking detected - blocking capture job started',
     @job_name = N'Capture blocking chain';
```

**Fix options:**
1. **Alert on a sustained counter value** (BL41) or on the blocked process report event.
2. **Have the alert start the capture** (BL42) so evidence exists before anyone logs in.
3. **Write the escalation rule in advance:** which head-blocker states justify an immediate `KILL` (BL9 and BL10 do; BL11 never does), who is authorised, and what is recorded afterwards.
4. **Review the record periodically** so BL7 can be evaluated across incidents instead of one at a time.

**Related checks:** BL7, BL31, BL41, BL42

---

## Background: how blocking works

**Locks and lock modes.** A lock is held on a resource (row, key, page, object, database) in a mode (`S`, `U`, `X`, `IS`, `IU`, `IX`, `Sch-S`, `Sch-M`, range modes). Two requests conflict when their modes are incompatible on the same resource. Intent modes (`IS`, `IU`, `IX`) mark an intention further down the hierarchy and conflict with far less than the full modes do — which is why an `IX` lock on a table is not a blocking problem while an `X` lock on the same table is.

**Lock duration.** Under the default read committed isolation with locking, shared locks for a `SELECT` are taken as each row is read and released immediately. Locks taken by `INSERT`, `UPDATE`, and `DELETE` are held to the end of the transaction, because the engine must be able to roll them back. That asymmetry is why write transaction length dominates blocking.

**Blocking versus deadlock.** Blocking is a queue and clears when the holder releases. A deadlock is a cycle that cannot clear, which the lock monitor breaks by choosing a victim (error 1205). The same evidence — modes, resources, isolation levels, hints — explains both; see `/sqldeadlock-review` for the cycle case.

**Reading `wait_resource`.** The formats are:

| Resource | Format | Example |
|---|---|---|
| Table | `TAB: DatabaseID:ObjectID:IndexID` | `TAB: 5:261575970:1` |
| Page | `PAGE: DatabaseID:FileID:PageID` | `PAGE: 5:1:104` |
| Key | `KEY: DatabaseID:Hobt_id (hash)` | `KEY: 5:72057594044284928 (3300a4f361aa)` |
| Row | `RID: DatabaseID:FileID:PageID:Slot` | `RID: 5:1:104:3` |

Resolve a `hobt_id` with `sys.partitions`, and a page with `sys.dm_db_page_info`. The key hash cannot be reversed to a key value.

**Why the last statement is often innocent.** The DMVs show the head blocker's *current or last* statement. If the session ran several statements inside one transaction, an earlier one may hold the locks that matter — which is why BL33 recommends capturing batch-level events during an investigation.

---

## Quick Reference

| ID | Check | Severity ceiling | Primary signal |
|----|-------|------------------|----------------|
| BL1 | Head blocker identified | Info | `blocking_session_id` = 0 and blocking others |
| BL2 | Long lock wait | Critical | `wait_time` ≥ 30 s on `LCK_M_*` |
| BL3 | Deep blocking chain | Critical | Chain depth ≥ 3 |
| BL4 | Wide blocking fan-out | Critical | ≥ 10 sessions blocked by one head |
| BL5 | Cross-database chain | Warning | Locks in > 1 database, distributed transaction |
| BL6 | Concurrency exhaustion risk | Critical | ≥ 25% of requests blocked, `THREADPOOL` |
| BL7 | Chronic head blocker | Critical | Same statement at head in ≥ 3 captures |
| BL8 | Long-running query at head | Critical | running/runnable, growing CPU and reads |
| BL9 | Sleeping with open transaction | Critical | sleeping, `wait_type` NULL, `open_tran` > 0 |
| BL10 | Orphaned transaction | Critical | sleeping, `open_tran` > 0, long idle |
| BL11 | Rollback at head | Critical | `KILLED/ROLLBACK`, `percent_complete` |
| BL12 | Client not consuming results | Critical | `ASYNC_NETWORK_IO` while holding locks |
| BL13 | Client/server distributed deadlock | Critical | Same `host_name` at both ends, no progress |
| BL14 | Non-lock wait at head | Warning | `PAGEIOLATCH_*`, `WRITELOG`, `RESOURCE_SEMAPHORE` |
| BL15 | Maintenance at head | Critical | `BACKUP`, `DBCC`, `ALTER INDEX` command |
| BL16 | Lock escalation | Critical | `OBJECT` lock in `S`/`X`, `lock_escalation` event |
| BL17 | Object-level X lock | Critical | `OBJECT` + `X`, no escalation evidence |
| BL18 | Sch-M blocking | Critical | `Sch-M` held or waiting, `Sch-S` waiters |
| BL19 | Hot resource contention | Critical | Same `resource_description` across waiters |
| BL20 | Key-range locks | Warning | `RangeS_S`, `RangeI_N`, `RangeX_X` |
| BL21 | Lock conversion wait | Critical | `request_status` = `CONVERT` |
| BL22 | Application lock contention | Warning | `resource_type` = `APPLICATION` |
| BL23 | Large lock footprint | Critical | ≥ 5,000 locks on one table or index |
| BL24 | Long open transaction | Critical | Transaction age ≥ 300 s |
| BL25 | Transaction across round-trips | Critical | Sleeping/active alternation with open transaction |
| BL26 | Elevated isolation level | Critical | `transaction_isolation_level` 3 or 4 |
| BL27 | Implicit transactions | Critical | Open transaction with no `BEGIN TRAN` |
| BL28 | Blocking lock hints | Critical | `TABLOCKX`, `XLOCK`, `HOLDLOCK` in the statement |
| BL29 | RCSI candidate | Critical | `LCK_M_S` victims, RCSI off |
| BL30 | Version store side effects | Warning | Version store growth, error 3960 |
| BL31 | Blocked process threshold off | Warning | `value_in_use` = 0 |
| BL32 | Threshold ineffective | Warning | `value_in_use` 1–4, or far above timeout |
| BL33 | No capture target | Warning | No `blocked_process_report` XE session |
| BL34 | Escalation overrides | Critical | TF 1211/1224, `LOCK_ESCALATION = DISABLE` |
| BL35 | Scan-driven lock footprint | Warning | Scan or lookup in the blocker's plan |
| BL36 | ADR / optimized locking unused | Warning | `is_accelerated_database_recovery_on` = 0 |
| BL37 | Lock waits, no chain captured | Critical | `LCK_M_*` ≥ 20% of wait time, no capture |
| BL38 | Lock hot spots by index | Critical | `row_lock_wait_in_ms` + `page_lock_wait_in_ms` per index |
| BL39 | Escalation attempts per index | Critical | `index_lock_promotion_attempt_count` > 10 |
| BL40 | Query Store lock waits | Warning | `wait_category_desc` = `Lock` |
| BL41 | Blocking counters not baselined | Warning | *Processes blocked* non-zero across samples |
| BL42 | No sampled blocking log | Warning | Short stalls, empty blocked process report |
| BL43 | Queued Sch-M behind a benign reader | Critical | Level-1 waiter wants `Sch-M`, level 2+ queued |
| BL44 | Statistics update blocking | Critical | `Sch-M` from stats update, `Sch-S` compiles queued |
| BL45 | Lock partitioning amplification | Warning | Non-zero `resource_lock_partition`, ≥ 16 CPUs |
| BL46 | Unindexed foreign key | Critical | Parent write, child table locks, no FK index |
| BL47 | Trigger / cascade extends transaction | Warning | Locks on tables the statement does not name |
| BL48 | Write locks rows it reads | Critical | Locks ≫ rows modified, non-SARGable predicate |
| BL49 | ORM / driver transaction defaults | Critical | Framework `program_name` with default isolation |
| BL50 | No timeout or retry policy | Warning | Waits past any client timeout, no cancellation |
| BL51 | Azure platform differences | Warning | Azure artifact read with on-prem assumptions |
| BL52 | Readable secondary redo blocked | Critical | Redo `Sch-M` behind report `Sch-S` |
| BL53 | Commit acknowledgement wait | Critical | `HADR_SYNC_COMMIT` or DTC wait at the head |
| BL54 | No alerting or escalation path | Warning | Recurring blocking, no alert, no `KILL` rule |
