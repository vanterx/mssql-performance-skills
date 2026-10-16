# sqlwait-review — Community Practices and Sources

Where the method in `sqlwait-review` comes from, which community tools produce
the same evidence, and where popular advice needs qualifying. This file credits
sources; it does not add checks. Thresholds, DMV columns, wait type names, and
version applicability in `SKILL.md` follow Microsoft Learn, and anything
Microsoft does not document is labelled as such where it is used.

## 1. The method

Wait statistics analysis follows the **Waits and Queues** methodology. Microsoft
first set it out in the *Performance Tuning Using Waits and Queues* whitepaper,
and it has since been carried forward mainly by Paul Randal (SQLskills) and
Brent Ozar's First Responder Kit. The core loop is the one the skill runs:

1. Remove benign background waits that accrue whether or not there is a problem
2. Rank what is left by share of total wait time
3. Explain the top waits by root cause, not by name
4. Compare against a baseline, because the same mix can be normal on one
   system and alarming on another

## 2. Tooling map

| Tool | What it gives `sqlwait-review` | Checks it feeds |
|------|--------------------------------|-----------------|
| `sys.dm_os_wait_stats` (Microsoft) | The raw cumulative counters since startup or since the last clear | All V-checks |
| Two snapshots and a delta (Paul Randal's approach) | Waits for a known window instead of since startup, so a past incident cannot dominate today's picture | V1–V18 differential mode, V18 window-scaled threshold |
| SQLskills wait and latch library | Per-wait meaning, known causes, and the benign-wait exclusion list | Exclusion list in every capture query |
| `sp_BlitzFirst @Seconds = N` | A delta over N seconds, with wait share | V1–V18 |
| `sp_BlitzFirst @SinceStartup = 1` | Cumulative waits since startup | V29 cumulative skew |
| `sp_Blitz` "Poison Wait Detected" | The poison-wait list and its proportional threshold | V18 |

## 3. Practitioner rules this skill encodes

- **Exclude benign waits before ranking.** The exclusion list in the capture
  queries is based on the SQLskills list. Check 50 in `scripts/verify-claims.py`
  keeps every full copy byte-identical, and deliberately keeps waits whose
  magnitude is itself the signal.
- **Measure a window, not "since startup".** Cumulative counters mix last
  week's incident with today's normal load (Paul Randal, *Capturing wait
  statistics for a period of time*). The skill prefers a two-snapshot delta and
  uses cumulative data only for skew detection (V29).
- **No universal thresholds.** A 40% CXPACKET share can be normal for a data
  warehouse and alarming for OLTP. Shares are a starting point; the baseline
  decides.
- **CXPACKET is not a reason to lower MAXDOP on reflex.** Look at whether the
  work is evenly spread across threads first (Paul Randal, *Knee-Jerk Wait
  Statistics: CXPACKET* and *More on CXPACKET Waits: Skewed Parallelism*).
- **SOS_SCHEDULER_YIELD is usually not CPU pressure.** CPU pressure shows up as
  rising signal wait time and long runnable queues. The most common cause of
  this wait is scans of pages already in memory (SQLskills wait library).
- **ASYNC_NETWORK_IO is never a SQL Server problem.** In the SQLskills library's
  words, *"This wait type is never indicative of a problem with SQL Server."*
  See §4 for the network caveat.
- **LOGMGR_RESERVE_APPEND as a top wait is rare and serious.** Look for a
  database in SIMPLE recovery with log auto-growth set to zero or very small
  (SQLskills wait library).
- **Poison waits are emergencies at any meaningful volume.** "Poison wait" is
  the First Responder Kit's term. `sp_Blitz` flags one when
  `SUM(wait_time_ms) > 5000 × hours since startup` and `> 60,000 ms`. It takes
  hours since startup from `tempdb`'s `create_date`. This is a community
  heuristic, unverified against Microsoft Learn. V18 uses it for cumulative
  data and scales it per minute for short windows.

## 4. Where community advice needs qualifying

- **"ASYNC_NETWORK_IO is always the client."** It is outside SQL Server, but not
  always the application. Microsoft Learn lists slow networks and NICs (driver
  issues, filter drivers, misconfigured firewalls, routers) next to slow
  fetching and an overloaded client machine. SQLskills offers a quick test: if
  ping time between the two servers is close to the average wait time, the wait
  is network latency.
- **CXPACKET vs CXCONSUMER.** Older advice predates the split in SQL Server
  2016 SP2 / 2017 CU3. Since then, CXCONSUMER carries the consumer-side waiting
  that is generally benign, and CXPACKET is the part worth investigating. Apply
  older CXPACKET percentages only to CXPACKET alone (see the threshold table in
  `SKILL.md`).
- **The poison-wait formula is a heuristic.** It suits servers that have run
  for days. On a freshly restarted instance the 60,000 ms floor dominates, so
  read V18 together with uptime.

## 5. Sources

- Paul Randal (SQLskills): [SQL Server wait types library](https://www.sqlskills.com/help/waits/), including [ASYNC_NETWORK_IO](https://www.sqlskills.com/help/waits/async_network_io/), [SOS_SCHEDULER_YIELD](https://www.sqlskills.com/help/waits/sos_scheduler_yield/) and [LOGMGR_RESERVE_APPEND](https://www.sqlskills.com/help/waits/logmgr_reserve_append/); [Wait statistics, or please tell me where it hurts](https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/); [Capturing wait statistics for a period of time](https://www.sqlskills.com/blogs/paul/capturing-wait-statistics-period-time/)
- Paul Randal (SQLPerformance.com): [Knee-Jerk Wait Statistics: CXPACKET](https://sqlperformance.com/2015/06/sql-performance/knee-jerk-wait-statistics-cxpacket), [More on CXPACKET Waits: Skewed Parallelism](https://sqlperformance.com/2015/08/sql-performance/more-on-cxpacket-waits-skewed-parallelism)
- Brent Ozar Unlimited: [Poison waits](https://www.brentozar.com/go/poison/), [sp_BlitzFirst](https://www.brentozar.com/askbrent/), [First Responder Kit](https://www.brentozar.com/first-aid/) ([source on GitHub](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit))
- Microsoft Learn: [sys.dm_os_wait_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql), [Troubleshoot slow queries that result from ASYNC_NETWORK_IO wait type](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-query-async-network-io), [Making parallelism waits actionable](https://techcommunity.microsoft.com/t5/sql-server-blog/making-parallelism-waits-actionable/ba-p/385691) (SQL Server team blog)

> Community articles are cited for method and emphasis. Thresholds, DMV columns,
> T-SQL syntax, and version applicability in `SKILL.md` follow Microsoft Learn.
