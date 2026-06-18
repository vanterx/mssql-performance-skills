# sqldeadlock-review — Explained

## Contents

- [What Is a Deadlock?](#what-is-a-deadlock)
- [How to Get the Deadlock XML](#how-to-get-the-deadlock-xml)
- [Lock Concepts](#lock-concepts)
- [Deadlock Patterns (P1–P8)](#deadlock-patterns-p1p8)
- [Extended Patterns (P9–P16)](#extended-patterns-p9p16)
- [Reading the Output](#reading-the-output)

---


A plain-English guide to SQL Server deadlocks: what they are, how to capture the XML, what the lock concepts mean, and a full explanation of each of the 16 patterns (P1–P16) the skill detects.

---

## What Is a Deadlock?

A deadlock is a situation where two or more sessions are each waiting for a lock that the other holds — neither can proceed, neither will release. SQL Server detects this cycle within seconds and kills one session (the **victim**), rolling back its transaction and returning error **1205** to the application:

```
Transaction (Process ID 52) was deadlocked on lock resources with another process
and has been chosen as the deadlock victim. Rerun the transaction.
```

**Victim selection:** SQL Server picks the victim that minimises work lost — typically the transaction with the lowest `@@TRANCOUNT` and least log written (`logused` attribute in the XML). You can influence this with `SET DEADLOCK_PRIORITY LOW/HIGH/NORMAL`.

**The right response in application code:** Catch error 1205 and retry the transaction. This is necessary but not sufficient — retrying a deadlock-prone pattern just retries the deadlock. Fix the root cause.

---

## How to Get the Deadlock XML

### Option 1 — system_health Extended Events Session (always running)

SQL Server's built-in `system_health` XE session captures deadlock graphs automatically:

```sql
SELECT xdr.value('@timestamp', 'datetime2') AS [timestamp],
       xdr.query('.') AS deadlock_xml
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets t
    JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
    WHERE s.name = 'system_health'
      AND t.target_name = 'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS xdr(xdr)
ORDER BY [timestamp] DESC;
```

The ring buffer holds the last ~1,000 events. For longer retention, read from the `.xel` files in the SQL Server log directory.

### Option 2 — SSMS Deadlock Graph

In SSMS, go to **Activity Monitor → Processes**, right-click a deadlock entry, and select **Save Deadlock File As**. This saves a `.xdl` file (XML with a different extension).

### Option 3 — Trace Flags (legacy)

```sql
DBCC TRACEON(1222, -1)  -- verbose XML-like deadlock info to SQL error log
DBCC TRACEON(1204, -1)  -- less verbose, node-focused deadlock info to SQL error log
```
Note: `1205` is the error number returned to the client when a deadlock occurs — it is NOT a trace flag. The correct less-verbose trace flag is `1204`.

Output goes to the SQL Server error log. Use `xp_readerrorlog` or view in SSMS under Management → SQL Server Logs.

---

## Lock Concepts

### Lock Modes

SQL Server takes different types of locks depending on the operation:

| Mode | Name | Taken by | Compatible with |
|------|------|----------|----------------|
| **S** | Shared | SELECT | S, IS, U |
| **U** | Update | Start of UPDATE (read phase) | S, IS |
| **X** | Exclusive | INSERT/UPDATE/DELETE (write phase) | Nothing |
| **IS** | Intent Shared | Table/page lock signalling row S locks below | S, IS, U, IX |
| **IX** | Intent Exclusive | Table/page lock signalling row X locks below | IS, IX |
| **SIX** | Shared + Intent Exclusive | Read table, update some rows | IS |

**Key insight:** U locks are used in the read phase of an UPDATE to prevent two sessions from both reading the same row with S locks and then both trying to convert to X — that would deadlock. U is compatible with S (readers can still read) but not with another U (only one session can be in the update read phase at a time).

### Lock Granularity

SQL Server locks at the finest granularity it can:

| Type | XML element | What it protects |
|------|-------------|-----------------|
| `keylock` | `<keylock>` | A single index row (B-tree key) |
| `ridlock` | `<ridlock>` | A single heap row (Row ID) |
| `pagelock` | `<pagelock>` | An 8KB data or index page (~100s of rows) |
| `objectlock` | `<objectlock>` | An entire table |
| `metadatalock` | `<metadatalock>` | Schema objects |

When SQL Server can't use row-level locks (no suitable index exists), it escalates to page or table locks — making deadlocks far more likely because many unrelated rows share a lock. This is P4.

### Lock Compatibility Matrix

A ✗ means the two modes conflict — one session must wait for the other to release:

| Held ↓ \ Requested → | S | U | X | IS | IX | SIX |
|---|---|---|---|---|---|---|
| **S** | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ |
| **U** | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ |
| **X** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **IS** | ✓ | ✓ | ✗ | ✓ | ✓ | ✗ |
| **IX** | ✗ | ✗ | ✗ | ✓ | ✓ | ✗ |
| **SIX** | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |

### Isolation Levels

The isolation level determines how aggressively SQL Server takes and holds locks:

| Level | Shared locks held until | Risk |
|-------|------------------------|------|
| READ UNCOMMITTED | Not taken | Dirty reads |
| READ COMMITTED | Statement end | Default; most common |
| READ COMMITTED SNAPSHOT (RCSI) | Not taken (uses row versions) | **Best default fix for reader/writer deadlocks** |
| REPEATABLE READ | Transaction end | Deadlock risk ↑ |
| SERIALIZABLE | Transaction end + range locks | Deadlock risk ↑↑ |
| SNAPSHOT | Not taken (uses row versions) | Requires tempdb space |

RCSI and SNAPSHOT both use **row versioning** — readers don't take shared locks, so readers and writers never deadlock. The difference: RCSI is statement-level consistency, SNAPSHOT is transaction-level consistency.

---

## Deadlock Patterns (P1–P8)

### P1 — Classic Forward/Reverse Access Order

**What the lock cycle looks like:**
```
Session A: holds X on Orders row 1001 → waiting for X on Orders row 1002
Session B: holds X on Orders row 1002 → waiting for X on Orders row 1001
```

**Why it forms:** Two transactions update the same rows but in opposite order. Session A processes rows in ascending order (1001, then 1002). Session B processes in descending order (1002, then 1001). They cross each other.

**Real scenario:** A batch job updates orders by region (North → South). A customer-facing process updates orders by customer (which crosses regions). They inevitably intersect.

**Fix:** Enforce a consistent row access order everywhere. If all transactions process rows in ascending primary key order, no cycle can form. In the batch job: `ORDER BY OrderId ASC` before processing. In stored procedures: process in ascending ID order.

---

### P2 — Reader/Writer Deadlock (Shared vs Exclusive)

**What the lock cycle looks like:**
```
Session A (SELECT): holds S on row 1001 → waiting for X on row 1002 (because it needs to read row 1002 next)
Session B (UPDATE): holds X on row 1002 → waiting for S on row 1001 to be released (because A holds S)
```

Wait — session A is a SELECT. How does it deadlock? In standard READ COMMITTED, SELECT holds S locks only for the duration of each row read. The deadlock forms when A needs to read a row that B has exclusively locked, AND B needs A's shared lock to be released before it can finish.

**Why it forms:** Under default READ COMMITTED, readers and writers can deadlock when a reader's transaction spans multiple statements and a writer's transaction needs rows the reader is still holding.

**Fix:** Enable **READ_COMMITTED_SNAPSHOT** (RCSI):
```sql
ALTER DATABASE YourDatabase SET READ_COMMITTED_SNAPSHOT ON
```
Under RCSI, readers never take shared locks — they read the last committed version of each row from TempDB. Readers and writers can never deadlock. This is the most common and least disruptive fix. Test write-heavy workloads as it increases TempDB version store usage.

---

### P3 — Update Lock Escalation Deadlock

**What the lock cycle looks like:**
```
Session A: holds U on Orders row 1001 → waiting for U on Orders row 1002
Session B: holds U on Orders row 1002 → waiting for U on Orders row 1001
```

**Why it forms:** U locks prevent two sessions from both reading a row in preparation for an update. But if session A has a U lock on row 1001 and needs row 1002 next, and session B has a U lock on row 1002 and needs row 1001 next — the same forward/reverse pattern from P1, but with U locks instead of X locks.

**Why U locks appear here and not X:** The UPDATE statement acquires U in the read phase (finding the row to update) then converts to X in the write phase. The deadlock forms during the read phase, before any writes happen.

**Fix options:**
1. Add an index on the UPDATE's WHERE clause columns — this makes the U lock acquire exactly one row with no ambiguity about which row comes next
2. Enforce access order (as in P1) if multiple rows are updated per transaction
3. Use `WITH (ROWLOCK)` hint to prevent page-level U locks when the optimizer is taking page locks instead of row locks

---

### P4 — Missing Index Causing Page Lock Escalation

**What gives it away in the XML:** Resource type is `pagelock` or `objectlock` rather than `keylock`.

**Why it forms:** When SQL Server has no index to navigate to specific rows, it scans pages. During a scan update, it takes a U lock on each page (not each row). Two sessions updating different rows on the same page compete for the page-level U lock — deadlocking even though they would never compete at row level.

**Why this is fixable:** Add an index on the filter column. SQL Server will then seek to the exact row and take a row-level `keylock` instead of a page-level `pagelock`. Rows on the same page are now independently lockable.

**Fix:**
```sql
-- Identify the table from the XML's objectname attribute
-- Check what index would help:
SELECT i.name, ic.key_ordinal, c.name AS column_name
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('dbo.Orders')
ORDER BY i.index_id, ic.key_ordinal

-- Then create an index on the WHERE clause columns of the deadlocking query
```

---

### P5 — Bookmark Lookup Deadlock (Key Lookup)

**What the lock cycle looks like:**
```
Session A (SELECT): holds S on NC index row → waiting for S on clustered index (PK) row
Session B (UPDATE): holds X on clustered index (PK) row → waiting for S on NC index row to release
```

**Why it forms:** A Key Lookup acquires locks on two separate indexes: first the nonclustered index (to find the row), then the clustered index (to fetch the non-covered columns). An UPDATE that goes directly through the PK acquires locks in the reverse order: clustered first, then any NC indexes it needs to update. This is the classic two-resource P1 pattern, but the two resources are two different indexes on the same table.

**Fix:** Eliminate the Key Lookup by extending the NC index with INCLUDE columns:
```sql
-- Before: index causes Key Lookup to fetch Status and TotalAmount
CREATE INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId)

-- After: index covers the query, no Key Lookup needed
CREATE INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId)
INCLUDE (Status, TotalAmount)
WITH (ONLINE = ON, DROP_EXISTING = ON)
```
No Key Lookup = no two-index lock acquisition = deadlock eliminated.

---

### P6 — SERIALIZABLE Phantom Deadlock

**What gives it away in the XML:** `isolationlevel="serializable"` on one or more processes, and range lock modes like `RangeX-X` or `RangeS-U` in the resource list.

**Why range locks exist:** SERIALIZABLE isolation prevents phantom rows — rows that would appear if you re-read the same range within a transaction. To prevent phantoms, SQL Server holds **range locks** that lock the gap between existing rows. An insert into the range must wait for the range lock.

**Why it deadlocks:** Session A holds a range lock on (1000, 2000). Session B holds a range lock on (1500, 2500). Session A tries to insert 1800 (into B's range). Session B tries to insert 1300 (into A's range). Cycle.

**Fix:**
```sql
-- Switch to SNAPSHOT isolation (transaction-level consistency without range locks):
ALTER DATABASE YourDatabase SET ALLOW_SNAPSHOT_ISOLATION ON

-- Then in the application/procedure:
SET TRANSACTION ISOLATION LEVEL SNAPSHOT
```
SNAPSHOT uses row versioning. There are no range locks. Phantom prevention is handled by conflict detection at commit time rather than by blocking.

If SERIALIZABLE is genuinely required for correctness, reduce the transaction scope: do the SERIALIZABLE read and the subsequent write as close together as possible, minimizing the window where range locks are held.

---

### P7 — Foreign Key Check Deadlock

**What gives it away:** The `objectname` in the resource list is the **parent** table, but the deadlocking query targets the **child** table.

**Why it forms:** Inserting into a child table requires SQL Server to validate the FK — it reads the parent table to confirm the referenced key exists. This takes a shared lock on the parent row. Simultaneously, a DELETE on the parent takes an exclusive lock on that same row and waits for the child's shared lock to release. If a third session is inserting a different child row that references the same parent, a cycle forms.

**Fix:**
1. Add an index on the FK column **in the child table**:
```sql
CREATE INDEX IX_Orders_CustomerId ON dbo.Orders (CustomerId)
-- FK validation now does an index seek (1 page read) instead of a table scan
```
This doesn't eliminate the lock on the parent, but it minimises the time the child holds its own locks, reducing the collision window.

2. Ensure parent DELETEs and child INSERTs don't run concurrently in overlapping transactions.

---

### P8 — Self-Deadlock (Single Process)

**What gives it away:** The `victim-list` and `process-list` contain only one process ID — a single SPID is deadlocked with itself.

**Why it happens:** A single session requests a lock that it already holds in an incompatible mode. This is rare and almost always caused by:
- A cursor iterating over rows while updating them (the cursor holds a shared lock, the update needs exclusive)
- Certain `MERGE` statement patterns where the same row can match multiple WHEN clauses
- A transaction that opens a connection to itself via a linked server

**Fix:**
- Replace cursor-based row-by-row processing with a set-based UPDATE
- Review MERGE statements: ensure each target row can only be matched by one source row (add a uniqueness guarantee on the source)
- Check for loopback linked server usage

---

## Extended Patterns (P9–P16)

### P9 — RCSI Reader Deadlock Despite RCSI Enabled

**What gives it away:** The database has `READ_COMMITTED_SNAPSHOT` ON, yet the deadlock XML shows a reader (S lock) and a writer (X lock) in a cycle.

**Why it happens:** RCSI only eliminates shared locks for sessions running at READ COMMITTED isolation. Sessions explicitly using REPEATABLE READ, SERIALIZABLE, or `WITH (HOLDLOCK)` / `WITH (UPDLOCK)` hints continue to acquire shared locks even under RCSI. The deadlock occurs because these sessions hold their S locks for the full transaction duration while a writer needs X on the same resource.

**Fix:**
- Identify the reader's `isolationlevel` attribute in the process XML. If REPEATABLE READ or SERIALIZABLE is not required, change the application to use READ COMMITTED.
- Remove unnecessary `WITH (HOLDLOCK)` hints — they escalate lock hold time for no benefit in most cases.
- If the higher isolation level is legitimately required, use SNAPSHOT isolation instead: it provides the same consistency guarantees as REPEATABLE READ without taking shared locks.

---

### P10 — MERGE Statement Deadlock

**What gives it away:** One or more processes has a MERGE statement in its `<executionStack>` as the outermost or active frame.

**Why it happens:** SQL Server's MERGE operator must apply Halloween Protection — it reads all matching target rows into a spool before performing any writes, to prevent updates from interfering with the scan used to find update targets. This two-phase (read-then-write) lock acquisition pattern can cycle with concurrent MERGE or DML on the same rows. SQL Server KB articles document multiple MERGE deadlock edge cases.

**Fix:**
- Replace MERGE with explicit INSERT/UPDATE/DELETE statements where possible. This eliminates the Halloween Protection spool and allows more predictable lock ordering.
- If MERGE is required, use `WITH (TABLOCK)` on the target as a short-term serialization guard (at the cost of concurrency).
- Stage source data into a temp table and process in batches to reduce per-MERGE lock scope.

---

### P11 — Heap Table RID Lock Deadlock

**What gives it away:** The resource list contains `ridlock` entries. RID (Row Identifier) locks are used exclusively on heap tables.

**Why it happens:** Heap tables store rows without any ordering. SQL Server tracks each row by its physical location (File:Page:Slot = RID). RID locks have the same S/U/X hierarchy as key locks but are bound to a physical page slot. Under concurrent inserts, two sessions can acquire RID locks in different orders across pages, forming a cycle.

**Fix:**
- Add a clustered index to the table. The heap becomes a B-tree, row-level `keylock` entries replace `ridlock` entries, and lock ordering becomes more predictable.
- Use `/sqlindex-advisor` to identify the best clustering key based on the deadlocked queries' access patterns.

---

### P12 — Distributed Transaction Deadlock

**What gives it away:** One or more process entries has `transactionname` containing "Distributed Transaction" or shows `dtcState` attributes.

**Why it happens:** MS DTC coordinates a two-phase commit protocol across multiple resource managers (SQL Server instances, MSMQ, etc.). During Phase 1 (prepare), all participants hold locks. Phase 2 (commit) releases them. The total lock hold time spans both phases — often several seconds — vs milliseconds for a local transaction. This extended hold time dramatically increases the window during which another session can form a deadlock cycle.

**Fix:**
- Eliminate distributed transactions by co-locating dependent data on a single SQL Server instance.
- If DTC is required, minimize transaction scope — commit or roll back as quickly as possible before acquiring locks on the next resource.
- Review DTC timeout settings; an artificially extended timeout means locks are held longer before DTC aborts a participant.

---

### P13 — Multiple Deadlock Graphs: Shared Root Cause

**What gives it away:** Multiple deadlock XML graphs are provided and they all reference the same `objectname` or `indexname` in their resource lists.

**Why it happens:** This is not a set of independent deadlocks — it is one recurring concurrency pattern on a single table. The application or workload executes a consistent access pattern that guarantees a deadlock cycle whenever two instances overlap.

**Fix:**
- Identify which single deadlock type (P1–P12) applies to each graph — they will all be the same type.
- Apply one fix to the shared table. A single index addition, isolation level change, or access-order fix will resolve all graphs simultaneously.
- Monitor for recurrence after the fix; if a different table appears in subsequent graphs, a second unrelated hotspot may exist.

---

### P14 — TempDB Resource Deadlock

**What gives it away:** `objectname` in the resource list references a tempdb object — a user temp table (`tempdb.dbo.#SessionState`), a work table, or a system allocation page (GAM, PFS, SGAM, DIFF_MAP).

**Why it happens:** Two distinct scenarios:
1. **Allocation page contention:** High-concurrency workloads with frequent temp table CREATE/DROP operations fight over PFS and GAM pages in tempdb. Multiple sessions create objects simultaneously and take X locks on the same allocation pages in different orders.
2. **User temp table DML:** Two sessions share a temp table (via a global temp table `##name` or SPID-scoped temp table used by nested procedures) and DML from one session deadlocks with another.

**Fix:**
- For allocation page contention: add tempdb data files (one per CPU up to 8), enable trace flag 1118 on SQL Server 2014 and earlier, or ensure `tempdb` is using the default SQL Server 2016+ configuration.
- For user temp table DML deadlocks: apply the same lock-order fix as P1 (ensure consistent row access order), or convert the shared global temp table to a dedicated permanent staging table with tighter concurrency control.

---

### P15 — Lock Escalation Deadlock

**What gives it away:** The resource list contains an `objectlock` entry (table-level lock, granularity = Object) alongside `keylock` or `ridlock` entries on the same table, held by different sessions.

**Why it happens:** SQL Server escalates row-level locks to a table lock when a single transaction holds more than 5,000 locks on a table (or exceeds a memory threshold). The escalated table lock (IS → X) conflicts with row-level locks already held by another concurrent session, forming a deadlock cycle between the escalating session and the row-level holder.

**Fix:**
- Prevent escalation with `ALTER TABLE dbo.YourTable SET (LOCK_ESCALATION = DISABLE)` — this stops escalation on that table. Use only when RCSI or SNAPSHOT isolation is also enabled, otherwise the lock count can grow unbounded.
- Reduce transaction batch size so the 5,000-lock threshold is never reached in a single transaction.
- Enable RCSI to eliminate S locks from readers, reducing total lock count and making escalation less likely.

---

### P16 — Ledger or Temporal History Table Deadlock

**What gives it away:** `objectname` references a ledger history table (name starts with `MSSQL_LedgerHistoryFor_`) or a temporal period history table. Applies to SQL 2016+ (temporal tables) and SQL 2022+ (ledger tables).

**Why it happens:** Both ledger and system-versioned temporal tables automatically insert history rows on UPDATE and DELETE operations. The history insert is performed by the SQL Server engine as part of the DML — the user transaction holds locks on both the base table and the history table simultaneously. If another session accesses the history table in a different order (e.g., a direct query against the history table while the base table is being updated), a deadlock cycle can form.

**Fix:**
- Keep base table DML transactions short — history row insertion is proportional to the number of rows updated/deleted per transaction.
- Route queries against the history table to a readable secondary replica (Always On) to separate read traffic from write traffic.
- Avoid explicit DML on the history table from application code; let the engine manage it.

---

## Reading the Output

### Lock Cycle Diagram

```
SPID 52 → holds [X on dbo.Orders PK row 1001]
         → waits for [X on dbo.Orders IX_Status row 1001]
SPID 67 → holds [X on dbo.Orders IX_Status row 1001]
         → waits for [X on dbo.Orders PK row 1001]
```

Read this as a directed graph. Each `→` is a "blocked by" edge. A cycle = deadlock. The diagram shows exactly which resources form the cycle and which sessions hold them.

### Remediation Effort/Risk Ratings

Each fix is rated:

| Rating | Effort | Risk |
|--------|--------|------|
| Low | Schema/config change, minutes to deploy | Isolated, well-understood |
| Medium | Code change or index addition, hours to test | Affects specific queries |
| High | Isolation level change, application retry logic, architectural change | Broad impact, needs thorough testing |

Always implement the lowest-effort, lowest-risk fix first and monitor whether the deadlock recurs before applying higher-risk changes.

### Monitoring Recommendation

After applying a fix, monitor for recurrence:

```sql
-- Check for recent deadlocks in system_health:
SELECT xdr.value('@timestamp', 'datetime2') AS [timestamp]
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets t
    JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
    WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS xdr(xdr)
WHERE xdr.value('@timestamp', 'datetime2') > DATEADD(hour, -1, GETUTCDATE())
ORDER BY [timestamp] DESC;
```

If deadlocks recur, check whether the same pattern reappears or a different pattern is now surfacing (fixing P4 often reveals P2 underneath).
