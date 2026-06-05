# mssql-performance-review — Methodology Reference

## Contents

- [Why a dispatcher skill exists](#why-a-dispatcher-skill-exists)
- [The dispatch order, explained](#the-dispatch-order-explained)
- [Symptom-to-probe-sequence map](#symptom-to-probe-sequence-map)
- [Hypothesis classes](#hypothesis-classes)
- [Recommendation conflict catalogue](#recommendation-conflict-catalogue)
- [Why the adversarial pass is mandatory](#why-the-adversarial-pass-is-mandatory)
- [Confidence grading](#confidence-grading)
- [When to use this skill vs the specialised skill directly](#when-to-use-this-skill-vs-the-specialised-skill-directly)

---

## Why a dispatcher skill exists

A senior DBA presented with mixed SQL Server artifacts (`.sqlplan` files, statistics output, wait stats, a trace excerpt, an ERRORLOG fragment) does not run every diagnostic in sequence. They form two or three hypotheses based on what they see, then probe the cheapest signal that would confirm or refute each. They re-route as evidence accumulates. They look for contradictions before declaring a root cause.

This skill encodes that workflow so a less-experienced operator gets the same outcome. The 15 specialised review skills (tsql-review, sqlplan-review, sqlwait-review, etc.) already exist; this skill chooses which ones to run, in what order, and how to merge their findings.

It is intentionally a thin orchestration layer — it does not redefine any checks. Every finding still comes from one of the specialised skills.

## The dispatch order, explained

The default order is: source code → triage breadth (wait stats / trace / stats / Query Store / procstats) → plan deep dive → targeted analyses (compare, deadlock) → availability and platform context.

Each step is chosen so the next step's input is as well-scoped as possible.

| Step | Why it runs at this point |
|------|---------------------------|
| `tsql-review` first | Static analysis needs no execution data. Defects found here can change which plan you should capture. Cheapest informative skill. |
| `sqlwait-review` next (breadth) | Identifies the dominant bottleneck class (CPU vs I/O vs lock vs memory vs network) for the whole instance. Cheap to run, narrows the deep-dive scope. |
| `sqltrace-review` / `sqlstats-review` / `sqlquerystore-review` / `sqlprocstats-review` in parallel where independent | Each reveals workload-level patterns that change which specific plan deserves deep analysis. They do not depend on each other. |
| `sqlplan-review` per plan (or `sqlplan-batch` for folder) | Deep operator-level analysis. By now we know which plan to focus on. |
| `sqlindex-advisor` | Consolidates missing-index suggestions across plans. Needs sqlplan-review findings to validate. |
| `sqlplan-compare` | Only meaningful when two plans for the same query exist. Routed after sqlplan-review identifies the regressed query. |
| `sqldeadlock-review` | Specialised input (deadlock XML). Routed if `.xdl` or system_health XE output present. |
| `sqlerrorlog-review` → `sqlclusterlog-review` → `sqlhadr-review` | AG / failover root cause chain. Read in this order because ERRORLOG often points at the WSFC event, and WSFC events explain the AG state change. |
| `sqlspn-review` | Kerberos / login auth specialty. Routed only when login failures or Kerberos signals are present. |

The order is a default. The hypothesis loop can shortcut by jumping straight to the skill most likely to confirm the top hypothesis.

## Symptom-to-probe-sequence map

When the user describes a symptom but supplies no (or insufficient) artifacts, the orchestrator suggests captures in this order:

| Symptom | Probe sequence |
|---------|----------------|
| High CPU, low waits | sqlwait-review → sqlprocstats-review → sqlplan-review on top consumer |
| Slow specific procedure | tsql-review on source → sqlplan-review on plan from cache → sqlstats-review |
| Recent regression (worked yesterday, slow today) | sqlquerystore-review → sqlplan-compare (before/after) |
| AG failover | sqlerrorlog-review → sqlclusterlog-review → sqlhadr-review |
| Deadlock errors | system_health XE (capture) → sqldeadlock-review |
| Mystery slowness | sqlwait-review first (cheapest), then drill based on dominant wait |
| Login failures / Kerberos | sqlerrorlog-review (burst detection) → sqlspn-review |
| "Server is hung" | sqlwait-review → check blocking signals → sqlplan-review on head blocker |

Each row is also the order in which captures should be taken if the user is still gathering data. The tier-3 capture-bundle generator emits scripts in this order.

## Hypothesis classes

A hypothesis is a class of root cause plus the evidence that would confirm it. The orchestrator ranks two or three at the start of every review.

| Hypothesis class | Required confirming evidence | Refuting evidence |
|------------------|------------------------------|-------------------|
| Parameter sniffing | Wide duration variance for same query + multiple plans in Query Store + cardinality mismatch ratio >= 1,000x | Single plan in Query Store across capture window; consistent duration |
| Missing index | Key Lookup or expensive scan in plan + high logical reads on the affected table + matching missing-index suggestion | Plan has covering index already; reads driven by row count, not absent index |
| Stats stale | Cardinality mismatch in plan + `sys.dm_db_stats_properties` shows old `last_updated` | Stats current; mismatch driven by predicate complexity not row count |
| Server-wide I/O | PAGEIOLATCH_SH dominant wait + multiple plans show large reads + `sys.dm_io_virtual_file_stats` shows file-level latency | Specific table dominates reads — not server-wide |
| Lock / blocking | LCK_M_* waits dominant + lock escalation events + plan shows page-level locks on hot table | LCK waits trivial; isolation-level appropriate; no escalation |
| Deadlock pattern | Deadlock XML + repeating signature (same procs, same tables) | Single-occurrence deadlock with novel resources — different root cause |
| AG / failover | ERRORLOG lease expiry + CLUSTER.LOG health check failure aligned in time + AG state change | One symptom only without temporal correlation — different root cause |
| Kerberos auth | Login burst + NTLM fallback evidence + missing/duplicate SPN | Login burst from app pool restart — not Kerberos |

The "Refuting evidence" column drives the adversarial pass (see `references/adversarial-prompts.md`).

## Recommendation conflict catalogue

The mandatory Recommendation Conflicts section detects these classes:

| Conflict | How to detect | Resolution rule |
|----------|---------------|-----------------|
| Index add vs index unused | sqlindex-advisor recommends index on table T; sqlplan-batch usage stats show T over-indexed; an existing index is unused | Recommend dropping the unused index first; reassess advisor output |
| RECOMPILE hint vs stable plan | tsql-review suggests OPTION RECOMPILE for sniffing; sqlplan-compare history shows plan is stable | Surface contradiction; recommend OPTIMIZE FOR or plan guide instead of RECOMPILE |
| Index suggested vs covered by computed-column index | Advisor suggests index on column C; sqlplan-review notes plan already uses a covering computed-column index | Reject the suggestion; cite the existing covering index |
| MAXDOP change vs domain memory | Recommendation: change MAXDOP; domain memory facts.json says current value already matches Microsoft recommendation for server size | Reject the recommendation; cite the facts.json value |
| Isolation change vs AG mode | Recommendation: enable RCSI; sqlhadr-review shows AG in synchronous mode (RCSI on AG primary works but increases version store pressure on secondaries) | Surface side effect; require explicit confirmation |
| Force plan vs sniffing fix | sqlquerystore-review suggests forcing a plan; tsql-review or sqlplan-review identified the root cause as something the forced plan also has | Reject the forced-plan workaround; recommend root-cause fix |

The catalogue grows as new conflict patterns are observed. Each conflict in the report must cite both sides explicitly.

## Why the adversarial pass is mandatory

Confirmation bias is the orchestrator's biggest failure mode. The first plausible root cause that fits the loudest signal becomes the conclusion, even when a contradicting signal is also present. The adversarial pass exists to surface that contradicting signal before it is suppressed.

Concretely: after a primary hypothesis is identified with HIGH confidence, run the template from `adversarial-prompts.md` for that hypothesis class. If the contradicting evidence is strong, escalate the alternative hypothesis to equal or higher priority in the report. If weak, note it as a caveat.

The adversarial pass cannot be skipped — even if early termination (confidence-driven) would otherwise stop the dispatch. Termination saves probe cost; it must not skip the disproof attempt.

## Confidence grading

| Grade | Meaning | UX consequence |
|-------|---------|----------------|
| HIGH | Three or more skills surface the same root cause; no adversarial contradiction | Recommend deploying the fix |
| MEDIUM | Two skills surface the same root cause; adversarial contradiction is weak or not applicable | Recommend validating with an additional capture before deploying |
| LOW | One skill identified; corroborating signals are absent or inconclusive | List as "investigate further" rather than "fix" |

The grade flows through to every recommendation. A LOW-confidence finding cannot produce a HIGH-confidence recommendation.

## When to use this skill vs the specialised skill directly

Use **`/mssql-performance-review`** when:

- You have mixed artifact types and want one consolidated report
- You have a symptom but are not sure which skill to run
- You want cross-skill validation (conflicts, corroboration) automatically
- You want evidence chain output suitable for a change ticket or post-mortem

Use the **specialised skill directly** when:

- You have one artifact and you know which skill it needs (e.g., one `.sqlplan` → `/sqlplan-review`)
- You want a faster turnaround on a single, narrow question
- You want the specialised skill's full uncompressed output (the orchestrator summarises into the per-skill section)

The orchestrator does not duplicate the specialised skills — it composes them. Direct use of the specialised skills remains the right answer for narrow questions.
