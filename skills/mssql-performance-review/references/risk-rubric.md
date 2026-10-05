# Risk Rubric for Recommendations

Every recommendation emitted by the orchestrator carries a risk class (Low / Medium / High). This document is the source of truth for grading.

## Why risk grading is mandatory

A "Critical finding + concrete fix" pair is not enough. Many fixes carry real downside risk — they change other plans, consume storage, block writes during deployment, or alter behaviour subtly. Surfacing that risk explicitly is what separates a useful recommendation from a dangerous one.

A recommendation without a risk class is rejected and re-graded before the report is emitted.

## Risk classes

| Class | Meaning | Examples |
|-------|---------|----------|
| **Low** | Safe to deploy in any window with low chance of negative side effects. Rollback is trivial. | Add a covering index with ONLINE=ON on a non-LOB table; enable RCSI on a non-AG database; suppress backup success messages in ERRORLOG; update statistics on a single table |
| **Medium** | Safe with caveats. Test in non-prod first. Side effects are bounded and well understood. | Add a non-covering index (changes other plans); change MAXDOP on instance; add OPTION RECOMPILE hint to a hot query; enable RCSI on an AG database; rebuild a fragmented index online |
| **High** | Production-impacting. Requires change window, explicit approval, and rollback plan in hand before execution. | Change Cost Threshold for Parallelism on busy OLTP; drop an existing index; change recovery model; change compatibility level; alter table to add NOT NULL column on large table; partition switch on hot table |

## Default risk per recommendation type

| Recommendation | Default risk | Escalates to High when |
|---------------|--------------|-----------------------|
| `CREATE INDEX ... ONLINE = ON` (covering, non-LOB table) | Low | Table has LOB columns + Standard edition (forces offline); table is > 100M rows on Standard edition |
| `CREATE INDEX ... ONLINE = OFF` | Medium | Hot OLTP table + production hours; AG primary (replicates the build) |
| `DROP INDEX` | Medium | The index has any reads in `sys.dm_db_index_usage_stats` |
| `ALTER INDEX ... REBUILD` | Medium | Offline rebuild (Standard edition); large table during production hours |
| `UPDATE STATISTICS` | Low | None — read-only, brief schema lock |
| `OPTION (RECOMPILE)` on a procedure | Medium | Procedure runs > 100 times per minute (compile cost) |
| `OPTION (OPTIMIZE FOR ...)` on a procedure | Low | None — bounded behavioural change |
| `OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'))` | Medium | Used to mask a regression rather than fix root cause |
| Enable RCSI / SI | Medium | AG primary (increases version store load on secondaries) |
| Change MAXDOP at instance level | High | OLTP workload, > 1,000 queries/second |
| Change Cost Threshold for Parallelism at instance level | High | Same as above |
| Change Max Server Memory | High | Production server with other workloads (Reporting Services, SSIS) |
| Enable / disable a trace flag at startup | High | Always — requires restart and changes optimizer behaviour globally |
| Force a Query Store plan | Medium | The forced plan was last good > 30 days ago (may not represent current workload) |
| Unforce a Query Store plan | Low | None — restores choice to optimizer |
| Restart SQL Server / failover AG | High | Always |
| Change AG synchronous → asynchronous | High | Data loss risk increases |
| Change AG asynchronous → synchronous | High | Latency increases on primary commits |
| Add memory grant feedback opt-out | Medium | Used to mask a regression |
| Enable / disable a SQL Agent job | Medium | Disabling a maintenance job (backups, index maint) |

## Environmental escalators

Even when a recommendation's default class is Low or Medium, escalate one step (Low → Medium, Medium → High) if any apply:

| Escalator | Effect |
|-----------|--------|
| Table is partitioned and the recommendation does not align with partition strategy | +1 step |
| Target is AG primary and recommendation replicates to secondaries | +1 step |
| Target database is in FULL recovery and recommended action will generate large log volume (e.g., REBUILD of a 100 GB table) | +1 step |
| Production hours, hot OLTP table | +1 step |
| Standard edition (no online rebuild for tables with LOB; limited parallelism) | +1 step where relevant |
| Domain memory facts.json shows the proposed change conflicts with a documented setting | +1 step (or reject) |

Domain memory escalators are checked against `references/domain-memory.md` when a facts file is loaded for the target instance (`~/.mssql-perf-review/instances/<server>.json`). When no facts file is present, the defaults in this table apply.

## Finding severity: confirmation, not just thresholds

Risk grades the *fix*. This section grades the *finding*, and exists because a single skill reading a single artifact routinely reports a symptom at a severity the whole picture does not support. The orchestrator sees several artifacts at once and is the only place the correction can be made.

Grade a finding in three passes.

**Pass 1 — base severity from the owning skill.** Take the Info / Warning / Critical the specialised skill assigns from its own thresholds. Do not re-derive it.

**Pass 2 — confirmation from a co-firing peer.** A finding whose evidence is corroborated by an independent artifact is worth more than one that stands alone. Raise one step when a peer finding in a *different* artifact points at the same mechanism:

| Finding | Confirming peer | Why it corroborates |
|---|---|---|
| High `CXPACKET` share | `SOS_SCHEDULER_YIELD` share, or runnable-task queue depth | Distinguishes real CPU oversubscription from parallelism that is merely visible |
| `RESOURCE_SEMAPHORE` waits | Spills in plans, or oversized grants in `sqlmemory-review` | Confirms grant pressure is reaching queries rather than sitting in a counter |
| Lock wait share (`/sqlwait-review`) | A captured chain or blocked process report | Wait statistics size blocking; only a chain names a blocker |
| Plan regression (`/sqlquerystore-review`) | Matching CPU or I/O rise in the same window | Separates a plan change that mattered from one that did not |
| Configuration drift (`/sqldbconfig-review`) | A runtime symptom the setting predicts | MAXDOP 0 matters when parallelism waits are present, not merely because it is 0 |

**Pass 3 — tuning-class ceiling.** Some findings are chronically over-reported because they are always present to some degree. Cap these at **Warning** unless a confirming peer from Pass 2 fired:

- Parallelism waits (`CXPACKET`, `CXCONSUMER`, `HT*`)
- Any deviation-from-baseline or anomaly finding
- High-DOP query counts
- Single-use plan cache percentage on a cache below the size gate
- Configuration drift with no matching runtime symptom

The ceiling is not a downgrade of the evidence; it is a statement that the artifact cannot on its own distinguish "present" from "causing harm". Say which peer is missing when the ceiling is applied — "capped at Warning: no scheduler pressure in the wait capture to confirm it" — so the reader knows what to capture next rather than dismissing the finding.

**Never capped:** THREADPOOL, poison waits, corruption signals, dumps, data-loss risks, and anything in the security or availability domains. These stand at their own severity with no corroboration required.

## Side-effects checklist (per recommendation)

The orchestrator must list every applicable side effect. Categories:

| Category | What to declare |
|----------|----------------|
| Storage | Additional MB or GB consumed (estimate from row count × index width) |
| Write overhead | Estimated % increase in write cost on the affected table (each non-clustered index ~3-5%) |
| Lock duration | Estimated blocking window (none / seconds / minutes) |
| Compilation cost | Estimated CPU increase from RECOMPILE / plan invalidation |
| Plan-shape impact | Other queries on the same table whose plans may change |
| Memory grant | Change in memory-grant requirement for affected queries |
| AG replication | Volume of log generated (estimate from index size if structural change) |
| Backup chain | Whether the action breaks the log chain (it should not for any recommendation here) |

Empty categories may be omitted. A recommendation with no side effects in any category should be re-examined — almost every change has at least storage or compilation cost.

## Rollback rules

Every recommendation must include an exact rollback step. The rollback is itself graded for risk (separately), so the user can see whether undoing the change is safe.

| Recommendation rollback | Rollback risk |
|-------------------------|---------------|
| `DROP INDEX ix_new` after `CREATE INDEX ix_new` | Low (if no plans have been recompiled to use it) → Medium (if plans now depend on it) |
| `UPDATE STATISTICS` again with prior sample rate | Low — stats refresh |
| Remove `OPTION (RECOMPILE)` hint | Low — back to default behaviour |
| `EXEC sp_query_store_unforce_plan` | Low — optimizer regains choice |
| Restore MAXDOP to prior value | High — must run during a window |
| Re-enable a dropped index | Medium / High — must rebuild from scratch |

State the rollback risk explicitly in the report alongside the action risk.

## Verification rules

Every recommendation must specify a verification step: which capture to re-run after deployment and the expected metric movement. Examples:

| Recommendation | Verification |
|---------------|--------------|
| Add covering index for usp_GetOrders | Re-run `skills/sqlplan-review/scripts/01_capture_from_cache.sql` for the procedure 24h later; expect Key Lookup operator removed, statement cost < 50 (was 124.3) |
| Update statistics on Orders | Re-run sqlplan-review on the affected query; expect cardinality mismatch < 10x (was 36,854x) |
| Disable XP_CMDSHELL | No re-capture needed; verify via `sys.configurations` |
| Add OPTION RECOMPILE to a procedure | Re-run sqlstats-review on the procedure across 5 invocations; expect duration variance < 20% |

A recommendation without a verification step is incomplete and must be re-graded.

## Examples of rejection

These recommendations are **rejected** before they reach the report:

- "Just add an index here" — no exact T-SQL, no risk, no rollback.
- "Try OPTION RECOMPILE" — no exact statement, no scope (procedure-wide or per-statement?), no verification.
- "Change MAXDOP" — no target value, no risk class, no environmental check.
- "Force the good plan in Query Store" — no plan_id, no risk note (forced plan can fail), no monitoring rule.

The orchestrator either re-grades them with the missing fields filled, or downgrades them to Info.
