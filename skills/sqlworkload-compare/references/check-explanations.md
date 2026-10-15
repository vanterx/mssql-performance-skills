# sqlworkload-compare — Check Explanations (WC1–WC14)

Plain-English explanations for all 14 workload comparison checks. Each entry follows the five-part structure: What it means / How to spot it / Example / Fix options / Related checks. `SKILL.md` carries the triggers and thresholds the skill acts on; this file is background and on-demand detail.

---

## Contents

- [Before You Start: Comparing Two Captures Honestly](#before-you-start-comparing-two-captures-honestly)
- [WC1 — Comparability](#wc1--comparability)
- [WC2–WC10 — Query-Level Change](#wc2wc10--query-level-change)
- [WC11–WC13 — Configuration Change](#wc11wc13--configuration-change)
- [WC14 — Wait Profile](#wc14--wait-profile)
- [Quick Reference Table](#quick-reference-table)

---

## Before You Start: Comparing Two Captures Honestly

Four rules decide whether a comparison finds the change or invents one.

**1. Match everything, then rank.** A full outer match keeps every query that ran on either side, labelled `both`, `baseline only` or `current only`. The alternative — take the top 30 from each side, then join — silently drops the most interesting row: the query that was 40th on Monday and 3rd on Tuesday.

**2. Normalise by what you are comparing.** Per-execution averages compare cost. Per-minute rates compare volume. Totals compare nothing unless the two windows are the same length — a four-hour capture has four times the total of a one-hour capture of the same workload.

**3. Weight averages by executions.** Query Store stores an average per plan per interval. Combining them as `AVG(avg_duration)` treats an interval with 3 executions the same as one with 30,000. Use `SUM(avg_duration × count_executions) / SUM(count_executions)`.

**4. Treat filters as part of the data.** A trace with a 100 ms duration floor does not contain the queries that ran in under 100 ms. If only one side was filtered, a query that got faster than the floor looks like it disappeared.

These rules are the corrections to the comparison in `microsoft/SqlNexus` (MIT) that this skill grew from. That implementation inner-joins its two sides, takes a top 30 per side before matching, applies its 10 ms floor to the slow side only, compares totals across windows of different length, and reports a zero baseline as a 999% change.

---

## WC1 — Comparability

### WC1 — Captures Not Comparable as Supplied

**What it means:** Something about the two captures, rather than the workload, would make them differ: different window lengths reported as totals, different core counts, different sources or filters, or different points in the business cycle.

**How to spot it:**

```
                 baseline                 current
window           Mon 09:00-10:00 (60 m)   Tue 09:00-13:00 (240 m)
cpu_count        16                       16
source           Query Store              Query Store
total duration   1,257,260 ms             5,180,400 ms
```

The current total is 4.1× the baseline, and the window is 4× as long. Per minute, the workload grew about 3% — not 312%.

**Example:** A user compares Monday morning to the last day of the month. Every report query "regressed" because month-end runs the same reports over a month of data, not a day. Nothing in the engine changed.

**Fix options:**
1. Normalise totals to per-minute rates and waits to milliseconds per second per CPU before any other check runs.
2. Report a different `cpu_count` explicitly; CPU-time comparisons then describe two machines.
3. When one side is filtered and the other is not, treat that side's `baseline only` or `current only` rows as suspect (WC5).
4. Ask whether the windows are equivalent business periods; re-capture an equivalent window if not.

**Related checks:** WC5 (absent queries that may be a filter artefact), WC12 (capacity differences), WC14 (normalised waits)

---

## WC2–WC10 — Query-Level Change

### WC2 — Query Regressed

**What it means:** The same query, matched by `query_hash`, takes materially longer per execution in the current window.

**How to spot it:**

```
query_hash          presence  b_execs  c_execs  b_avg_ms  c_avg_ms  ratio  added_ms
0x1A2B3C4D5E6F7081  both       12,400   12,950     18.4      61.2   3.33   554,260
0x92031425364F5A6B  both        1,800    1,750     95.0     160.0   1.68   113,750
```

Added time is `(current avg − baseline avg) × current executions` — the wall-clock time the regression cost in the current window.

**Example:** The first row is a 3.3× regression that cost 554 seconds in one hour and is 27.6% of the current window's total duration — Critical. The second is a 1.7× regression costing 114 seconds — Warning.

**Fix options:**
1. Rank by added time, not ratio.
2. Read the maximum alongside the average — a regression carried by a few long executions is a different problem from one carried by every execution.
3. Classify with WC7–WC9 before choosing a fix.
4. Diff one plan from each side with `/sqlplan-compare`; with Query Store on, `/sqlquerystore-review` has the plan history and can force the earlier plan while the cause is fixed.

**Related checks:** WC6, WC7–WC9, `/sqlplan-compare`, `/sqlquerystore-review` Q1–Q4

### WC3 — Query Improved

**What it means:** The same query takes materially less time per execution in the current window.

**How to spot it:** Current average ≤ 0.7× baseline, with ≥ 10 executions on both sides and either average ≥ 10 ms.

**Example:** `0x708192031425364F` went from 25.0 ms to 14.8 ms (0.59×) and its reads fell from 2,100 to 900 per execution. Something about its plan improved in the same change window in which other queries regressed — evidence that the change touched plan choice.

**Fix options:**
1. Report improvements next to regressions; they help locate the change.
2. Label by direction (`improved`, `regressed`), never by which side was "slow", so the report reads correctly when the baseline is the slower period.

**Related checks:** WC2, WC6, WC13

### WC4 — New Heavy Query in the Current Window

**What it means:** A query that did not run in the baseline is now a large share of the current window.

**How to spot it:** `presence = current only`, and its total duration or CPU is ≥ 5% of the current window's total.

**Example:** `0x5E6F708192031425`, 140 executions at 2,100 ms, 294 seconds — 10.3% of the current window. It is a reconciliation procedure a new Agent job started calling at 09:15.

**Fix options:**
1. Treat it as new load, not a regression; ask what was deployed or scheduled.
2. Before reporting it as new, pair it with any WC5 row of similar text — a rewritten query gets a new `query_hash`.
3. If it is legitimate but badly timed, move it out of the business window before tuning it.

**Related checks:** WC5, WC10, `/sqltrace-review` X13

### WC5 — Heavy Query Absent From the Current Window

**What it means:** A query that was a large share of the baseline does not appear in the current window.

**How to spot it:** `presence = baseline only`, and its total duration or CPU is ≥ 5% of the baseline window's total.

**Example:** `0x6F70819203142536`, 60 executions at 1,500 ms in the baseline — 7.2% of it — and absent on Tuesday. The nightly export it belonged to was moved to 02:00.

**Fix options:**
1. Decide which of three readings applies: the work stopped, the query changed shape (pair with WC4), or the current capture missed it (WC1).
2. When Query Store is the source, check `query_capture_mode_desc` — `AUTO` can skip infrequent queries.

**Related checks:** WC1, WC4

### WC6 — Regression Is Systemic, Not One Query

**What it means:** A large fraction of unrelated queries regressed together, which points at a shared cause rather than at each query.

**How to spot it:** ≥ 30% of the queries matched on both sides (with ≥ 10 executions each) meet the WC2 regression rule.

**Example:** 4 of 8 matched queries regressed (50%). Two of the four are reads-driven, one CPU-driven, one wait-driven — and the configuration tables show the compatibility level moved from 140 to 160 and a cumulative update was applied. The reads-driven half is the cardinality estimator; the rest needs WC14.

**Fix options:**
1. Look at the configuration and version differences (WC11–WC13) before any single query.
2. Group the regressions by class (WC7–WC9) — the dominant class names the shared cause.
3. Use Query Store plan forcing for the worst regressions as a stopgap while the shared cause is addressed.

**Related checks:** WC7–WC9, WC11–WC14

### WC7 — Regression Class: CPU-Driven

**What it means:** The query does more computation per execution over about the same amount of data.

**How to spot it:** CPU per execution rose by at least half of the rise in duration, while reads rose by less than 1.5×.

**Example:** `0x3C4D5E6F70819203`: duration 210 → 690 ms (+480), CPU 180 → 610 ms (+430), reads 22,000 → 24,300 (1.10×). The time went into computation, not data access — consistent with the cost threshold for parallelism dropping from 50 to 5 and the query now running parallel with a more expensive plan shape.

**Fix options:**
1. Diff the plans (`/sqlplan-compare`) for operator changes over the same data.
2. When CPU-driven regressions are broad, compare `cpu_count`, scheduler count and power plan (`/sqldbconfig-review` B34, B36) and the host (`/sqlperfmon-review` PM1).

**Related checks:** WC2, WC11, WC12

### WC8 — Regression Class: Reads-Driven

**What it means:** The query touches more data per execution.

**How to spot it:** Logical reads per execution rose ≥ 1.5×.

**Example:** `0x1A2B3C4D5E6F7081`: reads 1,240 → 9,860 per execution (7.95×) with duration 3.3×. A plan change to a different access path — after the compatibility level change, the estimator now expects more rows and chooses a scan.

**Fix options:**
1. Compare plans; check WC13 for compatibility level and `LEGACY_CARDINALITY_ESTIMATION`.
2. Check whether the data grew — reads that rose with row counts are growth.
3. `/sqlindex-advisor` on the current plan.

**Related checks:** WC2, WC6, WC13, `/sqlindex-advisor`

### WC9 — Regression Class: Wait-Driven

**What it means:** The query does the same work and spends longer waiting.

**How to spot it:** CPU and reads per execution each within 1.2× of baseline while duration rose ≥ 1.5×.

**Example:** `0x2B3C4D5E6F708192`: duration 42 → 118.5 ms (2.8×), CPU 38.0 → 41.2 (1.08×), reads 3,400 → 3,520 (1.04×). Its plan is not the problem; lock waits across the instance rose 5.1× per second per CPU (WC14).

**Fix options:**
1. Do not apply a plan fix — `RECOMPILE` adds compile cost and changes nothing about the wait.
2. Route to `/sqlblocking-review` and `/sqlwait-review` with a current-window capture.
3. With Query Store on SQL Server 2017 or later, `sys.query_store_wait_stats` gives this query's own wait categories on each side.

**Related checks:** WC2, WC14, `/sqlblocking-review`, `/sqlwait-review`

### WC10 — Execution Volume Shifted With Flat Per-Execution Cost

**What it means:** The query is not slower; it runs more (or less) often.

**How to spot it:** Executions per minute changed ≥ 2× (or ≤ 0.5×) with duration, CPU and reads per execution each within 1.2×.

**Example:** `0x4D5E6F7081920314`: 750 → 1,600 executions per minute (2.13×), 1.9 → 2.0 ms each. A caching layer stopped serving a lookup and every request now reaches the database.

**Fix options:**
1. Find why the call rate changed — a new caller, a retry loop, a cache, an N+1 pattern.
2. Compare per-minute rates, not totals.

**Related checks:** WC4, `/sqltrace-review` X13

---

## WC11–WC13 — Configuration Change

### WC11 — Server Configuration (`sp_configure`) Differs

**What it means:** An instance-level setting has a different running value on the two sides.

**How to spot it:**

```sql
SELECT name, value_in_use FROM sys.configurations ORDER BY name;
```

Run on each side and match by `name`, including names present on one side only.

**Example:**

| Setting | Baseline | Current | Severity |
|---------|----------|---------|----------|
| cost threshold for parallelism | 50 | 5 | Warning |
| max server memory (MB) | 114688 | 114688 | — |

**Fix options:**
1. Compare `value_in_use`, not `value` — the configured value can differ from the running one until `RECONFIGURE` or a restart.
2. Treat `max server memory (MB)` `value_in_use` of 2147483647 as the default (Microsoft documents the default of 0 showing as that value).
3. Connect each difference to the query-level findings it would explain.

**Related checks:** WC6, WC7, `/sqldbconfig-review` B1–B9

### WC12 — Server Property Differs

**What it means:** The engine build, edition, or the machine's capacity differs between the sides.

**How to spot it:** `SERVERPROPERTY('ProductVersion')`, `ProductLevel`, `ProductUpdateLevel`, `Edition`, and `sys.dm_os_sys_info.cpu_count` / `physical_memory_kb` on each side.

**Example:** `ProductUpdateLevel` CU12 → CU14 overnight. The "nothing changed" incident had a change: a cumulative update.

**Fix options:**
1. Name both builds and check the newer update's fix list for optimizer or engine changes.
2. A capacity difference qualifies every CPU and wait comparison (WC1).
3. An edition change can cap usable cores or memory (`/sqldbconfig-review` B34).

**Related checks:** WC1, WC6, WC13

### WC13 — Database Option or Database-Scoped Configuration Differs

**What it means:** A setting of the compared database differs — and some of them select the cardinality estimator or change parameter sniffing, so they move many plans at once.

**How to spot it:**

```sql
SELECT compatibility_level, is_read_committed_snapshot_on, is_parameterization_forced
FROM sys.databases WHERE database_id = DB_ID();
SELECT name, value FROM sys.database_scoped_configurations;
```

**Example:** `compatibility_level` 140 → 160 with `LEGACY_CARDINALITY_ESTIMATION` 0 on both sides: the database moved from the cardinality estimator for level 140 to the one for level 160, and the reads-driven regressions (WC8) followed.

**Fix options:**
1. Use Query Store to force the earlier plans for the worst regressions while the estimator change is evaluated.
2. Consider `LEGACY_CARDINALITY_ESTIMATION` or a `USE HINT` per query as a targeted rollback rather than lowering the whole database's level.
3. A database-scoped `MAXDOP` overrides the server setting — read it alongside WC11.

**Related checks:** WC6, WC8, WC11, `/sqlquerystore-review`

---

## WC14 — Wait Profile

### WC14 — Wait Profile Shifted

**What it means:** The time the instance spent waiting moved between categories, or one category grew sharply, after normalising for window length and core count.

**How to spot it:**

```
ms per second per CPU = wait_time_ms delta / window seconds / cpu_count

category       baseline   current   ratio
buffer I/O        2.1       6.8     3.2×
lock              0.9       4.6     5.1×
parallelism       1.2       3.9     3.3×
CPU/scheduler     0.8       2.0     2.5×
log               0.5       0.6     1.2×
```

**Example:** Buffer I/O stays the dominant category, but lock waits grew 5.1× — matching the wait-driven regression in WC9 — and parallelism waits grew 3.3×, matching the cost threshold change in WC11.

**Fix options:**
1. Normalise before comparing; never compare raw totals across windows of different length or core count.
2. Group by category and exclude the idle and background waits `/sqlwait-review` excludes.
3. Hand the current side to `/sqlwait-review` for the full V-check pass.

**Related checks:** WC1, WC9, WC11, `/sqlwait-review`

---

## Quick Reference Table

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| WC1 | Comparability | Window length > 2× apart as totals, `cpu_count` differs, different filters, one-sided artifact, non-equivalent periods | Warning |
| WC2 | Query change | Current avg ≥ 1.5× baseline, ≥ 10 execs both sides, avg ≥ 10 ms either side | Warning / Critical at ≥ 10% of current duration |
| WC3 | Query change | Current avg ≤ 0.7× baseline | Info |
| WC4 | Query change | Current-only query ≥ 5% of current duration or CPU | Warning |
| WC5 | Query change | Baseline-only query ≥ 5% of baseline duration or CPU | Info |
| WC6 | Query change | ≥ 30% of matched queries regressed | Warning |
| WC7 | Query change | Regression with CPU rise ≥ half the duration rise, reads < 1.5× | Info (class) |
| WC8 | Query change | Regression with reads ≥ 1.5× | Info (class) |
| WC9 | Query change | Regression with CPU and reads within 1.2× | Info (class) |
| WC10 | Query change | Execs/min ≥ 2× or ≤ 0.5× with flat per-execution cost | Info / Warning if now top 3 |
| WC11 | Configuration | `sys.configurations.value_in_use` differs or one-sided | Warning / Info |
| WC12 | Configuration | Version, update level, edition, `cpu_count` or memory differs | Warning |
| WC13 | Configuration | Database option or database-scoped configuration differs | Warning / Info |
| WC14 | Waits | Dominant category changed, or a category ≥ 2× per second per CPU | Warning |
