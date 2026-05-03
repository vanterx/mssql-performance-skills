---
name: sqlplan-deadlock
description: Analyze SQL Server deadlock XML (from system_health XE session, SSMS deadlock graph, or trace) to identify root cause and produce a prioritized remediation plan. Use when a deadlock monitor captures a graph or users report intermittent deadlock errors (error 1205).
triggers:
  - /sqlplan-deadlock
  - /deadlock
  - /deadlock-analyze
---

# SQL Server Deadlock Analysis Skill

## Purpose

Parse a SQL Server deadlock XML graph, identify the victim and winner processes, extract the queries and lock acquisition patterns involved, match against known deadlock patterns, and produce a prioritized remediation plan.

## Input

Accept any of:
- Raw `<deadlock>` XML (from system_health XE session or SSMS deadlock graph Save As XML)
- A file path to a `.xdl` or `.xml` deadlock graph file
- A description of the deadlock if XML is not available

## How to Run

1. Parse the XML structure
2. Extract process list (victim, winner, their queries, lock waits)
3. Extract resource list (what locks are held and requested)
4. Match against pattern library
5. Generate remediation recommendations

---

## XML Structure Reference

```xml
<deadlock>
  <victim-list>
    <victimProcess id="process1a2b" />
  </victim-list>
  <process-list>
    <process id="process1a2b" taskpriority="0" logused="0"
             waitresource="KEY: 5:72057594038910976 (abc123)"
             waittime="4023" ownerId="123456"
             transactionname="user_transaction"
             currentdb="5" spid="52" kpid="1234"
             status="suspended" isolationlevel="read committed">
      <executionStack>
        <frame procname="adhoc" line="3" stmtstart="100" stmtend="200"
               sqlhandle="0x...">
          UPDATE Orders SET Status = 1 WHERE Id = @id
        </frame>
      </executionStack>
      <inputbuf>UPDATE Orders SET Status = 1 WHERE Id = @id</inputbuf>
    </process>
    ...
  </process-list>
  <resource-list>
    <keylock hobtid="72057594038910976" dbid="5" objectname="dbo.Orders"
             indexname="PK_Orders" id="lock1" mode="X" associatedObjectId="...">
      <owner-list>
        <owner id="process2c3d" mode="X" />
      </owner-list>
      <waiter-list>
        <waiter id="process1a2b" mode="U" requestType="wait" />
      </waiter-list>
    </keylock>
    ...
  </resource-list>
</deadlock>
```

---

## Extraction Checklist

For each process:
- Process ID, SPID, victim status (yes/no)
- Query text (from `<inputbuf>` and `<executionStack>`)
- `waitresource` — what lock it is waiting for
- `transactionname` — the transaction context
- `isolationlevel` — READ COMMITTED, SNAPSHOT, SERIALIZABLE, etc.
- `logused` — how much log has been written (indicator of transaction size)

For each resource:
- Resource type: `keylock`, `pagelock`, `objectlock`, `ridlock`, `metadatalock`
- Object and index name
- Mode held by each owner (S, U, X, IS, IX, SIX)
- Mode requested by each waiter

---

## Pattern Library

### P1 — Classic Forward/Reverse Access Order
- **Signature:** Process A holds X on resource R1, waits for resource R2. Process B holds X on R2, waits for R1.
- **Severity:** High
- **Cause:** Two transactions update the same pair of rows in opposite order.
- **Fix:** Enforce a consistent access order in application code (always update table A before table B, always process rows in ascending PK order).

### P2 — Reader/Writer Deadlock (Shared vs Exclusive)
- **Signature:** Process A holds S lock (SELECT), waits for X. Process B holds X (UPDATE), waits for S to be released.
- **Severity:** High
- **Cause:** A long-running read transaction blocks a writer; another reader prevents the writer from completing, causing a cycle.
- **Fix:** Enable READ_COMMITTED_SNAPSHOT isolation (`ALTER DATABASE ... SET READ_COMMITTED_SNAPSHOT ON`). Readers take no shared locks under RCSI — the most common fix for reader/writer deadlocks without changing application code.

### P3 — Update Lock Escalation Deadlock
- **Signature:** Multiple processes hold U locks on different rows, each waiting for U on the other's row.
- **Severity:** High
- **Cause:** `UPDATE` statements taking U locks in different orders on the same table.
- **Fix:** Add an index on the `WHERE` clause columns so each update targets exactly one row (reduces lock scope). Consider using `WITH (ROWLOCK)` hint. Consistent access order also applies.

### P4 — Missing Index Causing Page Lock Escalation
- **Signature:** `objectlock` or `pagelock` resource type (not `keylock`) in the resource list.
- **Severity:** High
- **Cause:** Without a row-level index, SQL Server takes page or table locks. Multiple transactions competing for the same page deadlock each other.
- **Fix:** Add a nonclustered index on the filter column so SQL Server takes row-level (`keylock`) locks instead of page locks. Use the `sqlplan-index-advisor` skill if an execution plan is available.

### P5 — Bookmark Lookup Deadlock (Key Lookup)
- **Signature:** Two `keylock` resources: one on a nonclustered index, one on the clustered index (PK). Process A holds lock on NC index, waits for PK. Process B holds lock on PK, waits for NC index.
- **Severity:** Medium
- **Cause:** A query does a Key Lookup (NC index → PK), taking locks on both. Another query updates via the PK, taking locks in reverse order.
- **Fix:** Eliminate the Key Lookup by adding INCLUDE columns to the NC index so no bookmark lookup is needed. This removes the two-resource lock acquisition.

### P6 — SERIALIZABLE Phantom Deadlock
- **Signature:** `isolationlevel = serializable` on one or more processes AND range locks (RangeX-X, RangeS-U) visible in the resource type.
- **Severity:** Medium
- **Cause:** SERIALIZABLE isolation holds range locks to prevent phantoms. Two transactions holding range locks on adjacent ranges block each other's inserts.
- **Fix:** Downgrade to SNAPSHOT isolation if application semantics allow. SNAPSHOT uses optimistic row versioning and eliminates range locks entirely. If SERIALIZABLE is required, reduce transaction scope.

### P7 — Foreign Key Check Deadlock
- **Trigger:** `objectname` in the resource list references a parent table, and one process is inserting into the child table while another deletes from the parent.
- **Severity:** Medium
- **Cause:** Inserting into a child table takes a shared lock on the parent (FK validation). Deleting from the parent takes an exclusive lock. If done concurrently in opposite order, deadlock occurs.
- **Fix:** Add an index on the FK column in the child table (prevents table scan during FK validation). Ensure parent deletes and child inserts do not overlap in concurrent transactions.

### P8 — Self-Deadlock (Single Process)
- **Signature:** `victim-list` and `process-list` contain only one process ID.
- **Severity:** Medium
- **Cause:** A single SPID is requesting a lock it already holds in an incompatible mode (rare, usually triggered by cursors or certain MERGE statements).
- **Fix:** Rewrite the query to avoid cursor-based row-by-row processing. Review MERGE statements for self-deadlock edge cases documented in KB articles.

---

## Lock Compatibility Reference

| Held \ Requested | S | U | X | IS | IX | SIX |
|---|---|---|---|---|---|---|
| S | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ |
| U | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ |
| X | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| IS | ✓ | ✓ | ✗ | ✓ | ✓ | ✗ |
| IX | ✗ | ✗ | ✗ | ✓ | ✓ | ✗ |
| SIX | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |

---

## Output Format

```
## Deadlock Analysis

### Deadlock Summary

| | Victim | Winner |
|--|--------|--------|
| **SPID** | X | Y |
| **Host** | [hostname] | [hostname] |
| **Procedure / Batch** | [proc name or first 80 chars of ad-hoc SQL] | [proc name or first 80 chars] |
| **Started** | [timestamp] | [timestamp] |
| **Log used** | [KB] | [KB] |
| **Pattern detected** | [P1–P8 or Unknown] | — |

### Lock Cycle

```
SPID X → holds [mode on object.index] → waits for [mode on object.index]
SPID Y → holds [mode on object.index] → waits for [mode on object.index]
```

[One sentence confirming the circular wait and which SPID SQL Server chose as victim.]

### Pattern Match

**[Pattern name — e.g., P1 Classic Forward/Reverse Access Order]**

| Session | Step 1 | Step 2 |
|---------|--------|--------|
| SPID X — ProcA | [lock mode] on [Table1] ([index]) | Needs [lock mode] on [Table2] |
| SPID Y — ProcB | [lock mode] on [Table2] | Needs [lock mode] on [Table1] |

[One sentence explaining why this access order is deterministic and under what concurrency condition it fires.]

### Queries Involved

**Victim (SPID X) — [proc/batch name]**
```sql
[query text]
```
[One sentence: what lock it acquires and on which resource.]

**Winner (SPID Y) — [proc/batch name]**
```sql
[query text]
```
[One sentence: what lock it acquires first and what it then waits for.]

### Root Cause

[Pattern name, why the cycle is deterministic, which tables/indexes are involved, and what concurrent execution condition triggers it.]

### Remediation Plan

**Fix 1 (Recommended)** — [Action]
- Effort: Low / Medium / High
- Effectiveness: Eliminates / Reduces frequency / Hides symptom
- SQL: [DDL or setting change with code block if applicable]

**Fix 2** — [Action]
...

### Remediation Priority

| Fix | Effort | Effectiveness |
|-----|--------|--------------|
| Fix 1 — [name] | Low/Medium/High | Eliminates the deadlock |
| Fix 2 — [name] | Low | Reduces frequency; does not eliminate |
| Fix N — [name] | Low | Implement regardless as defensive coding |
```

---

## Notes

- If more than one deadlock graph is provided, analyze each separately then note if they share the same root cause.
- If the graph is incomplete (SSMS sometimes truncates long query text), note which processes have truncated queries and base the analysis on what is visible.
- Do not recommend disabling deadlock retry logic in the application — this masks the problem. Fix the root cause.
- For high-frequency deadlocks (> 10/hour), an immediate mitigation is to enable READ_COMMITTED_SNAPSHOT while the permanent fix is implemented.

## Companion Skills

- **sqlplan-review** — Analyze the execution plans of the deadlocked queries to identify missing indexes that extend lock hold time.
- **sqlplan-index-advisor** — Generate index DDL to eliminate the missing index patterns (P4, P5) that cause page-level lock escalation and bookmark lookup deadlocks.
- **tsql-review** — Review the T-SQL source of the deadlocked procedures for lock-order inconsistencies and missing TRY/CATCH (T19, T20).
- **sqltrace-review** — If the trace includes Lock:Timeout (X6) or repeated deadlock events, use sqltrace-review to quantify frequency and identify peak periods.
- **query-store-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.
