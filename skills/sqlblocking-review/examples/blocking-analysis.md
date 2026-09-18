# sqlblocking-review Analysis — Two Chains, One Orphaned Transaction

**Input:** `blocking_input.txt` — output of `scripts/capture-blocking.sql`, two captures 60 seconds apart

---

## Blocking Summary

- **Head blocker (chain A): session 71** (`CORP\svc_orders` / `WKS-FIN-14` / `OrderEntry.exe`)
- **State:** `sleeping`, `wait_type` NULL, `open_transaction_count` 1, idle 362 s — **does not resolve on its own; needs a `KILL` or a client rollback**
- **Head blocker (chain B): session 54** (`CORP\svc_etl` / `BI-ETL-01` / `SSIS-NightlyExtract`) — `PAGEIOLATCH_SH`, cleared without intervention between captures
- **Impact:** 6 sessions blocked at capture time (chain A: 84, 92, 97, 101, 105, 110; chain B: 118), deepest chain 3 levels, longest wait 354 s. Three reporting sessions had already timed out by the second capture.
- **7 Critical, 6 Warnings, 2 Info**

---

## Blocking Chain Map

```
Chain A — session 71 (head)   sleeping, open_tran 1, idle 6m02s
  input buffer: BEGIN TRANSACTION; UPDATE dbo.Orders SET Status = 'H' WHERE OrderId = 4711;
  holds: OBJECT X on dbo.Orders
  ├─ 84   LCK_M_U   354 s  KEY 72057594045267968 (dbo.Orders)   UPDATE dbo.Orders SET ShipDate ...
  │    └─ 92   LCK_M_S   349 s  same KEY                        SELECT ... FROM dbo.Orders
  │         └─ 97   LCK_M_S   344 s  same KEY                   SELECT ... FROM dbo.Orders
  ├─ 101  LCK_M_IS  323 s  OBJECT 1893581784 (dbo.Orders)       SELECT ... JOIN dbo.Customers
  ├─ 105  LCK_M_IS  318 s  OBJECT 1893581784                    SELECT SUM(Total) ...
  └─ 110  LCK_M_IS  301 s  OBJECT 1893581784                    SELECT TOP 500 ...

Chain B — session 54 (head)   running, PAGEIOLATCH_SH 18 s, SERIALIZABLE, HOLDLOCK
  holds: 4,863 RangeS_S KEY locks on dbo.Inventory
  └─ 118  LCK_M_X   96 s   KEY 72057594047823872 (dbo.Inventory)  UPDATE dbo.Inventory SET OnHand ...
```

---

## Critical Issues

**[C1] Sleeping head blocker holding locks (BL9)**
**Observed:** Session 71 — `status` `sleeping`, `wait_type` NULL, `session_open_tran` 1, last request ended 09:01:12, capture at 09:07:14. Input buffer shows `BEGIN TRANSACTION; UPDATE dbo.Orders ...` with no `COMMIT` or `ROLLBACK`.
**Impact:** Six sessions blocked behind a session that is doing nothing. The state is unchanged 60 seconds later, so it will not clear on its own.
**Fix:** `KILL 71` for immediate relief (rollback is one row, so the cost is negligible). Durable fix: roll back in the client error handler — `IF @@TRANCOUNT > 0 ROLLBACK TRAN` — or set `XACT_ABORT ON` in `OrderEntry.exe` connections.

**[C2] Orphaned transaction (BL10)**
**Observed:** The same session 71 has been idle 362 s inside an open read/write transaction started at 09:01:09 on a workstation host (`WKS-FIN-14`).
**Impact:** The transaction outlived the user's interaction with it; the client has hit a timeout or been closed, and SQL Server still sees the connection as live, so the locks are held indefinitely.
**Fix:** As [C1]. `KILL` can take up to 30 seconds to take effect. Add `Try-Catch-Finally` cleanup in the client and check whether connection pooling is returning connections with open transactions.

**[C3] Long lock waits past the client timeout (BL2)**
**Observed:** 354 s, 349 s, 344 s, 323 s, 318 s, 301 s — all far past the Critical threshold of 30 s. `wait_time` on session 84 grows from 354,117 ms to 414,230 ms across the two captures on the same `wait_resource`.
**Impact:** Growing waits on an unchanging resource confirm no progress. The three reporting sessions had already disappeared by the second capture — they timed out and returned errors to users.
**Fix:** Resolve [C1]. Set `LOCK_TIMEOUT` in the reporting client so it fails predictably instead of holding a worker for five minutes.

**[C4] Deep blocking chain (BL3)**
**Observed:** Chain A reaches level 3 (71 → 84 → 92 → 97).
**Impact:** The queue drains serially after 71 releases; sessions 92 and 97 wait for 84 to finish its own update after that.
**Fix:** Kill the head only. Killing 84 or 92 frees nothing and adds rollback work.

**[C5] Object-level exclusive lock on dbo.Orders (BL17)**
**Observed:** Session 71 holds `OBJECT` / `X` / `GRANT` on object 1893581784 (`dbo.Orders`) with no KEY or PAGE locks recorded for that session.
**Impact:** Sessions 101, 105, and 110 wait in `LCK_M_IS` — they cannot even take an intent-shared lock on the table, so this single lock stops all reads of `dbo.Orders`, not just the one row being updated.
**Fix:** Confirm the escalation evidence against BL16 — trace flag 1211 is enabled globally (see [C7]), so escalation on `dbo.Orders` is disabled and this `X` lock came from somewhere else: check `OrderEntry.exe` for a `TABLOCKX` hint on the update path (BL28).

**[C6] Key-range locks from SERIALIZABLE with HOLDLOCK (BL20, BL26)**
**Observed:** Session 54 runs at `transaction_isolation_level` 3 (`RepeatableRead` per the DMV mapping — value 4 would be `Serializable`) with an explicit `HOLDLOCK` hint, holding 4,863 `RangeS_S` KEY locks on `dbo.Inventory`.
**Impact:** The range locks block the inventory update on session 118 for 96 s, and the footprint sits just below the 5,000-lock escalation threshold.
**Fix:** Remove `HOLDLOCK` from the ETL extract — it reads, it does not need phantom protection. If a consistent snapshot is genuinely required, use `SNAPSHOT` isolation instead of range locks, after enabling row versioning on `Sales`.

**[C7] Lock escalation disabled instance-wide (BL34)**
**Observed:** `DBCC TRACESTATUS` shows trace flag 1211 enabled globally; `dbo.Inventory` additionally has `LOCK_ESCALATION = DISABLE`.
**Impact:** Trace flag 1211 disables escalation unconditionally, including under memory pressure, so lock memory can grow until allocations fail with error 1204 — which aborts the statement and rolls back its transaction, producing a longer outage than the escalation it was meant to prevent. Session 54's 4,863 locks would normally have escalated.
**Fix:** Remove trace flag 1211 from the startup parameters and rely on the per-table `LOCK_ESCALATION = DISABLE` on `dbo.Inventory` alone while the ETL query is fixed (remove `HOLDLOCK`, batch the read). Re-test under load before removing the per-table override too.

---

## Warnings

**[W1] Wide fan-out on dbo.Orders (BL4)** — session 71 directly blocks five sessions (84, 101, 105, 110, plus 92/97 indirectly). Blocked sessions × longest wait ≈ 30 session-minutes of stalled work in one incident.

**[W2] Large lock footprint approaching the escalation threshold (BL23)** — session 54 holds 4,863 KEY locks plus 142 PAGE locks on `dbo.Inventory`. Without the escalation overrides this would have escalated to a table lock and blocked every inventory session rather than one.

**[W3] Long-running open transactions (BL24)** — session 71 at 365 s (Critical band) and session 54 at 192 s (Warning band). Both hold write-mode locks for their full duration.

**[W4] Reader-writer blocking curable by RCSI (BL29)** — sessions 92, 97, 101, 105, and 110 are read-only statements waiting in `LCK_M_S`/`LCK_M_IS`, and `Sales` has `is_read_committed_snapshot_on = 0`. Five of the six victims would not have waited at all under RCSI.

**[W5] Blocked process threshold not configured (BL31)** — `blocked process threshold (s)` is 0, so this incident produced no automatic record; the evidence above exists only because someone ran the capture script while it was happening.

**[W6] No capture target for blocking events (BL33)** — the only Extended Events session is `system_health`, which captures deadlock graphs but not blocked process reports, lock escalation, or attention events.

---

## Info

**[I1] Non-lock wait at the head of chain B (BL14)** — session 54's head wait is `PAGEIOLATCH_SH` (18 s), so its blocking is downstream of storage latency rather than a locking fault. Chain B cleared on its own between captures. Pair with `/sqldiskio-review`.

**[I2] Accelerated database recovery not enabled (BL36)** — `Sales` has `is_accelerated_database_recovery_on = 0`. Not the cause of this incident, but it is the mitigation for the long-rollback class (BL11) and the prerequisite for optimized locking on supporting versions.

---

## Lock Evidence

| Session | Role | Resource | Mode | Status | Count | Object |
|---------|------|----------|------|--------|-------|--------|
| 71 | Head blocker (chain A) | OBJECT | X | GRANT | 1 | dbo.Orders |
| 84 | Victim / intermediate | KEY | U | WAIT | 1 | dbo.Orders (clustered) |
| 92, 97 | Victims | KEY | S | WAIT | 1 each | dbo.Orders (clustered) |
| 101, 105, 110 | Victims | OBJECT | IS | WAIT | 1 each | dbo.Orders |
| 54 | Head blocker (chain B) | KEY | RangeS_S | GRANT | 4,863 | dbo.Inventory (clustered) |
| 54 | Head blocker (chain B) | PAGE | IS | GRANT | 142 | dbo.Inventory |
| 118 | Victim | KEY | X | WAIT | 1 | dbo.Inventory (clustered) |

---

## Remediation Priority

| # | Action | Addresses | Effect | Risk | Rollback |
|---|--------|-----------|--------|------|----------|
| 1 | `KILL 71` | C1, C2, C3, C4, C5, W1 | Clears chain A immediately — six sessions released | Low — one row of rollback; the user's edit is lost and has to be redone | None needed; the transaction is undone by the kill |
| 2 | Add `IF @@TRANCOUNT > 0 ROLLBACK TRAN` to the `OrderEntry.exe` error handler, or `SET XACT_ABORT ON` | C1, C2 | Stops this incident class recurring | Low; with `XACT_ABORT ON`, statements after an aborting error no longer run — review existing flow control | Revert the client build |
| 3 | Remove `HOLDLOCK` from the SSIS extract query | C6, W2 | Removes 4,863 range locks and the inventory blocking | Low — the extract reads only; confirm no downstream logic depends on phantom protection | Restore the hint |
| 4 | Set `blocked process threshold` to 20 s and create a `Blocking` XE session (`blocked_process_report`, `lock_escalation`, `attention`, `STARTUP_STATE = ON`) | W5, W6 | Next incident is captured without a DBA present | Low — the report is best-effort and generated by the existing deadlock monitor thread | `sp_configure` back to 0; drop the session |
| 5 | Audit `OrderEntry.exe` for a `TABLOCKX` hint on the update path | C5 | Removes the table-wide `X` lock that stopped all reads | Low | Restore the hint if a correctness requirement is found |
| 6 | Remove trace flag 1211 from startup parameters, keep the per-table override on `dbo.Inventory` | C7, W2 | Restores the lock-memory cap and removes the error 1204 exposure | Medium — escalation resumes on other tables; test under load, and fix the ETL query (item 3) first | Re-add `-T1211` and restart |
| 7 | Enable RCSI on `Sales` in a maintenance window | W4 | Removes reader-blocked-by-writer entirely — five of six victims here | Medium — TempDB version store space and I/O, 14 bytes per row on update, read-then-write patterns may need `UPDLOCK` | `ALTER DATABASE Sales SET READ_COMMITTED_SNAPSHOT OFF` (also needs exclusive access) |
| 8 | Enable ADR on `Sales` | I2 | Shortens future rollback outages; prerequisite for optimized locking | Medium — persistent version store space; test first | `SET ACCELERATED_DATABASE_RECOVERY = OFF` |

---

## Historical Evidence

Not supplied with this capture. Two sources would have added attribution without needing a live chain, and are worth collecting before the next occurrence:

| Source | What it would answer | Check |
|--------|---------------------|-------|
| `sys.dm_db_index_operational_stats` (section 6a of the capture script) | Whether `dbo.Orders` and `dbo.Inventory` are chronic lock-wait hot spots, and whether the 4,863 range locks on `dbo.Inventory` have been driving escalation attempts | BL38, BL39 |
| `sys.query_store_wait_stats` where `wait_category_desc = 'Lock'` | Which queries have been the repeat victims over the retention window, and whether the ETL extract is a new arrival | BL40 |
| *Processes blocked* counter samples | Whether 7 blocked sessions is this instance's normal state or today's incident | BL41 |

---

## Passed Checks

BL5 (single database per chain), BL6 (7 blocked of 94 active requests = 7.4%, no `THREADPOOL` waits), BL11 (no session in rollback), BL12 (no `ASYNC_NETWORK_IO` at either head), BL13 (head blocker host `WKS-FIN-14` does not match any victim host), BL15 (neither head blocker is maintenance or a system session), BL16 (no escalation evidence — trace flag 1211 prevents it), BL18 (no `Sch-M` locks), BL19 (no single resource with a queue beyond the chain structure), BL21 (no `CONVERT` request status), BL22 (no `APPLICATION` locks), BL27 (session 71's input buffer contains an explicit `BEGIN TRANSACTION`, so this is not implicit transactions), BL30 (no row versioning enabled, so no version store exposure), BL32 (threshold is 0, covered by BL31 rather than this check), BL35 (no scan or lookup evident in the blocking statements — all seek on `OrderId`).

Also clean in this capture: BL43 (the level-1 waiter on chain A holds no incompatible table-level request — the sessions below 84 are queued on the same KEY resource, not behind a `Sch-M`), BL44 (no statistics operation in the chain), BL46 (the blocking statements seek on primary keys; no foreign-key scan evidence), BL48 (rows modified match the locks held), BL52 and BL53 (no readable-secondary or commit-acknowledgement waits at either head).

**Not evaluated:** BL7 (chronic head blocker) — the two captures are 60 seconds apart within one incident. Compare `query_hash` at level 0 across separate incidents, or collect blocked process reports over a week, to evaluate it. BL37–BL42 (historical evidence) — not supplied; see the Historical Evidence section above for what to collect. BL45 (lock partitioning) — the capture does not state the instance's logical CPU count or include `resource_lock_partition`; re-run section 4 with that column if the instance has 16 or more logical CPUs. BL47 (triggers and cascades) — the lock footprint names only tables the statements reference, but the capture does not rule out triggers on `dbo.Orders`. BL49 (ORM defaults) — `OrderEntry.exe` and `InventorySync.exe` are custom clients; check their connection configuration for isolation level and implicit transactions. BL50 and BL54 (timeout, retry, and alerting policy) — organisational, not visible in a DMV capture.

> Analyzed by: `sqlblocking-review` (BL1–BL54)
