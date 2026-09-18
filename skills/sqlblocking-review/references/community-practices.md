# Community Practice Digest — Blocking

Field practice from widely-followed SQL Server practitioners, distilled into the
rules this skill applies. Every technical claim repeated here was cross-checked
against Microsoft Learn before it was turned into a check; where community advice
and documentation differ in emphasis, the documented behaviour wins and the
difference is noted.

Load this file when the user asks *why* a check exists, wants the reasoning
behind a recommendation, asks which community tool to run, or is working from
`sp_WhoIsActive` / First Responder Kit / `sp_HumanEvents` output.

---

## 1. The four questions the community converges on

Independently, the practitioners below arrive at the same interrogation order.
It is the order `SKILL.md` encodes in its Analysis Order section.

1. **Who is at the head of the chain?** — not who is complaining loudest.
2. **What state is the head in?** — running, sleeping with an open transaction,
   rolling back, waiting on the client, waiting on something that is not a lock.
3. **What is it holding, and on what object?** — mode and granularity decide
   whether this is escalation, DDL, a hot row, or a hint.
4. **Will it clear on its own?** — this single answer decides between waiting,
   killing, tuning, and redesigning.

## 2. Tooling map

| Tool | Author / source | What it is for here | Notes |
|------|-----------------|---------------------|-------|
| `sp_WhoIsActive` | Adam Machanic | The live chain. Run with `@find_block_leaders = 1` and `@sort_order = '[blocked_session_count] DESC'` | Also logs to a table via `@destination_table` — the standard pattern behind BL42 |
| First Responder Kit (`sp_BlitzWho`, `sp_BlitzFirst`, `sp_BlitzIndex`, `sp_BlitzLock`) | Brent Ozar Unlimited | `sp_BlitzFirst @SinceStartup = 1` sizes lock waits (BL37); `sp_BlitzWho` snapshots the chain; `sp_BlitzIndex` flags "aggressive indexes" (BL38/BL39); `sp_BlitzLock` reads deadlocks and blocked process reports | Open source; run in production |
| `sp_HumanEvents`, `sp_HumanEventsBlockViewer` | Erik Darling | Sets up the blocking Extended Events session and parses the blocked process report into readable rows (BL33, BL37) | Needs `blocked process threshold` set first — the report drives the event |
| Blocking-tree scripts | Pinal Dave (SQLAuthority) and others | Recursive CTE over the chain, printed with indentation | Same shape as the capture script in `scripts/capture-blocking.sql`; older versions read `sys.sysprocesses` |
| Query Store | Microsoft | Per-query lock wait history after the fact (BL40) | `wait_category_desc = 'Lock'`, SQL Server 2017+ |
| `sys.dm_db_index_operational_stats` | Microsoft; popularised for this use by Michael J. Swart and `sp_BlitzIndex` | Attributes historical lock waits to an index (BL38, BL39) | Counters reset with the metadata cache entry |
| Ola Hallengren's `IndexOptimize` | Ola Hallengren | Where `WAIT_AT_LOW_PRIORITY` gets configured in practice (`@WaitAtLowPriorityMaxDuration` + `@WaitAtLowPriorityAbortAfterWait`, used together) | The BL43 fix usually lands here, not in ad-hoc DDL |

## 3. Practitioner rules this skill encodes

**"Look at query #2, too."** (Brent Ozar) The session your tool names as the lead
blocker is sometimes innocent. A long `SELECT` holding `Sch-S` stalls an index
rebuild's `Sch-M`, and everything arriving afterwards queues behind the *rebuild*,
not behind the `SELECT`. Killing the named head blocker releases the more
disruptive operation. → **BL43**, and the analysis-order rule to read one level
down before recommending a `KILL`.

**Lock waits are recorded by victims, never by blockers.** (Erik Darling) A query
that takes locks registers no lock wait; only the query that waits does. So
`sys.dm_os_wait_stats` and Query Store name the blocked, never the blocker, and no
amount of wait analysis substitutes for a chain capture. → **BL37**, **BL40**.

**Implicit transactions and ORM defaults are a leading production cause.**
(Erik Darling; widely corroborated) JDBC and several Python drivers open implicit
transactions unless autocommit is set; a .NET `TransactionScope` built without
options defaults to `Serializable`. Both produce blocking the application code
never asked for — a sleeping session holding locks, or key-range locks on a plain
read. → **BL27**, **BL26**, **BL49**.

**A sleeping session with an open transaction is an application defect.**
(Erik Darling, Pinal Dave, Microsoft) It signals a client that timed out or
cancelled without rolling back, or a connection returned to the pool mid-
transaction. `KILL` is first aid; `IF @@TRANCOUNT > 0 ROLLBACK TRAN` in the error
handler, or `SET XACT_ABORT ON`, is the fix. → **BL9**, **BL10**.

**Three levers fix most blocking: indexes, transaction length, isolation.**
(Brent Ozar) You rarely need all three. Index tuning cuts the lock footprint,
shorter transactions cut lock duration, and row versioning removes the
reader-versus-writer class outright. → **BL35**, **BL24**, **BL29**.

**RCSI is the highest-value single change — and it is not free.**
(Michael J. Swart argues for it as the default move; Kendra Little and Brent Ozar
document the costs.) It removes reader-blocked-by-writer entirely, needs no query
changes, and costs version store space, 14 bytes per row as rows are modified, and
a changed read-then-write risk profile: code that reads into a variable and then
updates can lose an update unless it takes `UPDLOCK` or uses a `rowversion` check.
Writers still block writers. → **BL29**, **BL30**.

**`NOLOCK` is not a blocking fix.** (Brent Ozar, and the documentation) It permits
dirty, missing, and duplicated rows, and it still waits behind `Sch-M`. Where the
goal is "readers should not wait", row versioning is the mechanism that actually
provides it. → **BL28**, **BL18**.

**Escalation goes straight to the table, not row → page → table.** (Paul Randal)
It fires at 5,000 locks on a single reference to a table, is re-checked every
1,250 further locks, and escalates to the partition instead when
`LOCK_ESCALATION = AUTO` on a partitioned table. Repeated *attempts* without
completions mean another session holds an incompatible table lock. → **BL16**,
**BL23**, **BL39**.

**Disabling escalation moves the risk rather than removing it.** (Paul Randal,
Microsoft) Trace flag 1211 disables it unconditionally, 1224 until lock memory
pressure, and 1211 wins if both are set; lock memory is finite, and exhausting it
produces error 1204, which aborts the statement and rolls back. Per-table
`LOCK_ESCALATION = DISABLE` is the smaller blast radius. → **BL34**.

**Index maintenance is a blocking event unless you make it yield.** (Brent Ozar,
Paul Randal, Ola Hallengren's parameters) Offline rebuilds take `Sch-M`, which
conflicts with everything including `READUNCOMMITTED` readers. `ONLINE = ON` with
`WAIT_AT_LOW_PRIORITY` lets the operation step aside instead of queueing the whole
workload behind it. → **BL15**, **BL18**, **BL43**.

**Blocking by index is the historical evidence you already have.**
(Michael J. Swart; `sp_BlitzIndex`) `row_lock_wait_in_ms + page_lock_wait_in_ms`
per index names the object even when the incident is over. `sp_BlitzIndex` flags
an index at roughly 1 second average lock wait, 5 minutes total, or 10 escalation
attempts. Caveats matter: object, metadata and application lock waits are not
counted, and the counters reset with the metadata cache. → **BL38**, **BL39**.

**Application locks hide from every normal diagnostic.** (Brent Ozar) An
`sp_getapplock` mutex shows up as `LCK_M_X` on an `APPLICATION` resource with the
lock name in `resource_description`, and appears nowhere in index or plan
analysis. The giveaway is `sp_getapplock` itself in the blocker's statement text.
→ **BL22**.

**Practise before the incident.** (Brent Ozar) Create blocking deliberately in two
sessions and watch how your monitoring reports it, so the first time you read a
real chain is not during an outage. → the capture and alerting checks, **BL42**,
**BL54**.

## 4. Where community advice needs qualifying

- **"Just turn on RCSI"** is right often enough to be a good default, but it is a
  database-wide semantic change. The documented costs (version store growth pinned
  by the oldest transaction, 14 bytes per row, read-then-write patterns needing
  `UPDLOCK`) are what BL29 and BL30 make explicit, and why this skill states them
  with the recommendation rather than after it.
- **"Kill the head blocker"** is correct for BL9 and BL10 and wrong for BL11: a
  session already rolling back cannot be killed again, and restarting the instance
  moves the same work into startup recovery with the database offline.
- **Blocked process report thresholds below 5 seconds** are commonly suggested and
  cannot work: the lock monitor wakes every 5 seconds, so anything lower only adds
  work. Short-duration blocking needs sampling (BL42) instead.
- **Older blocking scripts read `sys.sysprocesses`.** They still run, but the view
  is deprecated; `sys.dm_exec_sessions` + `sys.dm_exec_requests` +
  `sys.dm_os_waiting_tasks` carry more, and are what this skill's capture script
  uses.

## 5. Sources

- Brent Ozar Unlimited — [How to Troubleshoot Blocking and Deadlocking with Scripts and Tools](https://www.brentozar.com/archive/2018/11/how-to-troubleshoot-blocking-and-deadlocking-with-scripts-and-tools/), [When You're Troubleshooting Blocking, Look at Query #2, Too](https://www.brentozar.com/archive/2020/11/when-youre-troubleshooting-blocking-look-at-query-2-too/), [Troubleshooting Mysterious Blocking Caused By sp_getapplock](https://www.brentozar.com/archive/2024/04/troubleshooting-mysterious-blocking-caused-by-sp_getapplock/), [Locking and Blocking in SQL Server](https://www.brentozar.com/sql/locking-and-blocking-in-sql-server/), [sp_BlitzIndex Aggressive Indexes](https://www.brentozar.com/blitzindex/sp_blitzindex-aggressive-indexes/), [Implementing Snapshot or RCSI: A Guide](https://www.brentozar.com/archive/2013/01/implementing-snapshot-or-read-committed-snapshot-isolation-in-sql-server-a-guide/)
- Pinal Dave (SQL Authority) — [Blocking Tree: Identifying Blocking Chain Using SQL Scripts](https://blog.sqlauthority.com/2020/04/20/sql-server-blocking-tree-identifying-blocking-chain-using-sql-scripts/), [Find Blocking Using Blocked Process Threshold](https://blog.sqlauthority.com/2014/06/30/sql-server-find-blocking-using-blocked-process-threshold/), [Basic Explanation of SET LOCK_TIMEOUT](https://blog.sqlauthority.com/2013/01/28/sql-server-basic-explanation-of-set-lock_timeout-how-to-not-wait-on-locked-query/)
- Erik Darling (Darling Data) — [Capturing and Analyzing Blocking with sp_HumanEvents](https://erikdarling.com/capturing-and-analyzing-blocking-with-sp_humanevents/), [sp_HumanEventsBlockViewer](https://erikdarling.com/sp_humaneventsblockviewer/), [Lock Waits Come From Blocking, Not Locks Being Taken](https://erikdarling.com/lock-waits-come-from-blocking-not-locks-being-taken/)
- Paul Randal (SQLskills) — [A DBA Myth a Day: Lock Escalation](https://www.sqlskills.com/blogs/paul/a-sql-server-dba-myth-a-day-2330-lock-escalation/), [Partition-Level Lock Escalation](https://www.sqlskills.com/blogs/paul/sql-server-2008-partition-level-lock-escalation-details-and-examples/), [LCK_M_SCH_M wait type](https://www.sqlskills.com/help/waits/lck_m_sch_m/)
- Michael J. Swart — [Look at Blocking By Index](https://michaeljswart.com/2015/04/blocking_by_index/), [Use RCSI to Tackle Most Locking and Blocking Issues](https://michaeljswart.com/2022/11/use-rcsi-to-tackle-most-locking-and-blocking-issues-in-sql-server/)
- Kendra Little — [Lost Updates Under RCSI](https://kendralittle.com/2023/10/04/lost-updates-rcsi/)
- Adam Machanic — [sp_WhoIsActive documentation](http://whoisactive.com/docs/)
- Ola Hallengren — [SQL Server Index and Statistics Maintenance](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)
- Microsoft Learn — [Understand and resolve SQL Server blocking problems](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/understand-resolve-blocking), [Understand and resolve blocking problems (Azure SQL Database)](https://learn.microsoft.com/en-us/azure/azure-sql/database/understand-resolve-blocking), [Resolve blocking problems caused by lock escalation](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/resolve-blocking-problems-caused-lock-escalation), [Transaction locking and row versioning guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide), [Statistics](https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics), [sys.dm_db_index_operational_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-operational-stats-transact-sql), [Optimized locking](https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-locking)

> Community articles are cited for method and emphasis. Thresholds, DMV columns,
> T-SQL syntax, and version applicability in `SKILL.md` follow Microsoft Learn.
