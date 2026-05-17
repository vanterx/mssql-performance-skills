---
name: mssql-performance-review
description: Agentic offline orchestrator for end-to-end SQL Server performance reviews. Forms hypotheses from artifacts or symptoms, dispatches the specialised review skills (tsql-review, sqlplan-review, sqlwait-review, sqlstats-review, sqltrace-review, query-store-review, procstats-review, sqlplan-deadlock, hadr-health-review, clusterlog-review, errorlog-review, spn-review, sqlplan-compare, sqlplan-index-advisor, sqlplan-batch), runs an adversarial check on the primary root cause, and produces a consolidated fix priority with explicit evidence chain, risk, and rollback for each recommendation. Use this skill whenever a user has mixed SQL Server artifacts (.sqlplan, .sql, statistics output, trace data, wait stats, deadlock XML, AG / cluster / ERRORLOG, setspn output, Query Store, procstats) and is not sure which specialised skill to run, or when the user describes a symptom ("CPU is high", "AG failed over", "this query is slow") and needs the analysis routed for them. Trigger on /mssql-performance-review, /mssql-perf-review, /mssql-full-review, /sql-triage, full SQL Server performance review, end-to-end SQL Server review, root cause analysis with mixed artifacts. Strictly offline — never opens a connection to SQL Server.
triggers:
  - /mssql-performance-review
  - /mssql-perf-review
  - /mssql-full-review
  - /sql-triage
---

# SQL Server Performance Review Orchestrator Skill

## Purpose

A dispatch skill that turns a mixed pile of SQL Server artifacts (or a symptom description) into a single, evidence-backed performance review. It does not redefine any checks — it routes work to the 14 specialised review skills, then synthesises their findings into one consolidated report.

The orchestrator is **strictly offline**: it reads files the user provides, generates capture-script bundles when artifacts are missing, and emits analysis reports. It never opens a connection to a SQL Server. All execution against the database is the user's action.

This skill applies four cross-cutting primitives that distinguish it from a naive dispatcher:

- **Evidence chain** (E-tags) — every finding cites the source artifact, the specialised check ID, the observed value, and the threshold violated, so any recommendation is reproducible from the input set
- **Risk-aware recommendations** — every recommended fix carries action, effort, blocking window, risk class, side effects, explicit rollback, and post-deployment verification
- **Adversarial root cause check** — after the primary hypothesis is identified, a deliberate pass tries to disprove it; contradicting evidence escalates an alternative hypothesis instead of being suppressed
- **Confidence-driven early termination** — once three or more specialised skills converge on the same root cause with HIGH confidence and no active contradiction, additional probes are skipped to control token cost

These primitives are tier-1 features. Multi-model cost routing, skill-graph DAG, domain memory, follow-up Q&A, the capture-bundle generator, and the verification checklist arrive in tier 2 and tier 3 (see `backlog/performance-review-orchestrator-plan-v4.md`).

## Input

Accept any of:

- A directory path containing mixed artifacts (`.sqlplan`, `.sql`, `.txt`, `.xdl`, `.log`, `.json`)
- A list of file paths
- Inline content blocks pasted into chat (one block per artifact, with type hint)
- A natural-language symptom description ("CPU is high on prod since 09:00, no recent deploy")

The orchestrator first classifies each input, then routes per the dispatch table below. When the input is symptom-only and no artifacts are available, the orchestrator describes which captures would resolve the hypothesis and (in tier 3) generates a capture bundle the user can run.

## Artifact Classification

Content-based, not extension-reliant:

| Artifact signal | Routes to |
|-----------------|-----------|
| `<ShowPlanXML` root element | sqlplan-review (single) / sqlplan-compare (pair) / sqlplan-batch (folder) |
| T-SQL source: `CREATE PROCEDURE`, `SELECT`, `GO` markers | tsql-review |
| `Table '...'. Scan count ... logical reads ...` lines | sqlstats-review |
| `EventClass`, `Duration`, `CPU`, `TextData` tabular headers, `.trc` / `.xel` files | sqltrace-review |
| `wait_type`, `wait_time_ms`, `waiting_tasks_count` columns | sqlwait-review |
| `<deadlock>` root + `<victim-list>` | sqlplan-deadlock |
| `query_store_*` table refs, plan_id / runtime_stats columns | query-store-review |
| `total_worker_time`, `database_id` from `sys.dm_exec_procedure_stats` | procstats-review |
| `replica_id`, `synchronization_state` columns | hadr-health-review |
| `RES_EVENT`, `00000a1c` GUID prefixes, `Cluster.Resource` lines | clusterlog-review |
| `spid` prefixes with `Logon`, `Server`, `Backup` markers | errorlog-review |
| `MSSQLSvc/`, `setspn` output, `Existing SPN found for` | spn-review |
| Ambiguous `.txt` | Inspect first 100 lines, pick the highest-priority match; ask the user if still ambiguous |

## Hypothesis Generation

Before dispatching skills, generate two or three ranked hypotheses from the classified inputs (and the symptom description, if any). Each hypothesis maps to a probe sequence — the subset of specialised skills that would confirm or refute it.

Example hypotheses:

| Hypothesis class | Trigger signals | Probe sequence |
|------------------|----------------|----------------|
| Parameter sniffing | Wide duration variance in stats / trace; multiple plans for same query_hash | sqlstats-review → sqlplan-review → query-store-review → sqlplan-compare |
| Missing index | Key Lookup or large scan visible in plan; high logical reads on one table | sqlplan-review → sqlplan-index-advisor → sqlplan-batch (if folder) |
| Server-wide I/O bottleneck | PAGEIOLATCH_SH dominant in wait stats | sqlwait-review → sqlstats-review → sqlplan-review on top reader |
| Deadlock loop | error 1205 reported, deadlock XML present | sqlplan-deadlock → sqlplan-review on victim |
| AG failover root cause | ERRORLOG shows lease expiry, CLUSTER.LOG present | errorlog-review → clusterlog-review → hadr-health-review |
| Kerberos auth fail | NTLM fallback, login burst, setspn output present | spn-review → errorlog-review (login burst correlation) |
| Workload regression | Two plans for same query, dates differ, durations diverge | sqlplan-compare → sqlplan-review on both |

Record hypotheses with initial confidence (HIGH / MEDIUM / LOW). Confidence updates as probes complete.

## Dispatch Order

The dispatcher prefers the cheapest informative skill first, then deeper analyses only as needed.

1. tsql-review on any `.sql` files (no execution needed; finds static defects up front)
2. Triage breadth pass — parallel where independent:
   - sqlwait-review on wait stats
   - sqltrace-review on trace data
   - sqlstats-review on STATISTICS output
   - query-store-review on Query Store data
   - procstats-review on procedure stats
3. Deep dive on plans:
   - sqlplan-review per `.sqlplan` (or sqlplan-batch on a folder)
   - sqlplan-index-advisor consolidated across plans
4. Targeted analyses:
   - sqlplan-compare for plan pairs
   - sqlplan-deadlock for deadlock XML
5. Availability and platform context (only when matching artifacts present):
   - errorlog-review → clusterlog-review → hadr-health-review for AG / failover questions
   - spn-review for Kerberos / login issues

Each skill is invoked via the existing skill loader. Findings are captured under a uniform structure (see Output Format) regardless of which specialised skill produced them.

## Evidence Chain (E-tags)

Every consolidated finding includes a structured evidence record. The on-disk schema is in `references/evidence-schema.md`. The human-readable form follows this shape:

```
Finding C1 — Parameter sniffing on dbo.usp_GetOrders
- Evidence:
  - sqlplan-review S9 fired
    - Source: order_proc.sqlplan
    - Observed: actual rows 1,842,734 vs estimated 50 (36,854x ratio)
    - Threshold: >= 1,000x = Critical
  - sqlstats-review I1 corroborates
    - Source: stats-iotime.txt
    - Observed: 1,842,734 logical reads on Orders
    - Threshold: > 1,000,000 = Warning
  - query-store-review Q7 corroborates
    - Source: query-store-output.txt
    - Observed: 3 plans for query_hash 0xA1B2C3D4 over 24h
    - Threshold: >= 2 distinct plans in same window = plan instability
- Confidence: HIGH (three skills agree)
```

Each finding is reproducible: the recipient of the report can re-derive it by inspecting the cited source artifact at the cited location.

## Risk-Aware Recommendations

Every recommended fix carries the following fields. The full rubric is in `references/risk-rubric.md`.

| Field | Purpose |
|-------|---------|
| Action | The exact T-SQL or configuration change to make |
| Effort | Estimated implementation time (e.g., "5 min online build", "1 hour change-control window") |
| Window | When this is safe to run (anytime / off-hours / maintenance window) |
| Risk class | Low / Medium / High based on the rubric |
| Side effects | Storage impact, lock duration, write overhead, other queries affected |
| Rollback | The exact T-SQL or steps to undo the change |
| Verification | Which capture to re-run after deployment and the expected metric change |
| Confidence | HIGH / MEDIUM / LOW, inherited from the underlying finding |

Recommendations without explicit rollback are rejected — "just do this" is not acceptable output.

## Adversarial Root Cause Check

After the primary hypothesis is identified, run a deliberate pass that **tries to disprove it**. Load `references/adversarial-prompts.md` and apply the relevant template for the hypothesis class. Examples:

- Primary: parameter sniffing. Adversarial probe: "If parameter sniffing was the root cause, the wait profile should be CPU-dominant. If wait stats show PAGEIOLATCH_SH dominant instead, the bottleneck is I/O — reconsider whether sniffing matters here."
- Primary: missing index. Adversarial probe: "If a missing index was the root cause, fixing it should drop logical reads ~10x. If query-store-review shows the same plan was fast last month, the regression is something else — stats, parameter values, or a config change."
- Primary: deadlock from lock order. Adversarial probe: "If lock order was the cause, the deadlock graph should show two transactions taking the same two resources in opposite orders. If a third resource appears, the pattern may be different (escalation, page-level conflict)."

If the contradicting evidence is strong, surface the alternative hypothesis at equal or higher priority. If weak, note it as a caveat in the report. The adversarial pass is mandatory in tier 1 — it catches the most common failure mode (confirmation bias on the first hypothesis).

## Confidence-Driven Early Termination

After each phase completes, evaluate whether to continue. Terminate early if all of:

- Three or more specialised skills have surfaced the same root cause
- The consolidated confidence is HIGH
- No active contradiction from the adversarial pass

Otherwise, continue with the next dispatch phase. The user can override with `--exhaustive` (or by saying "run everything") to force all applicable skills to complete.

Early termination saves token cost on confirmed-cause cases without sacrificing thoroughness on ambiguous ones.

## Cost Budget

Before running, estimate the input token cost and surface it. Use a simple estimator:

- ~3.8 characters per token
- Per-artifact SKILL.md load cost (see `LLM_COST_ESTIMATION.md`)
- Per-artifact input size

Offer up to three scope options when the input is large:

- Full review (every applicable skill on every artifact)
- Batch mode (sqlplan-batch summary, drill into top N)
- Symptom-driven (only skills relevant to the highest-ranked hypothesis)

The user picks; the orchestrator routes accordingly.

## Reference Files (load on demand)

| File | When to load |
|------|--------------|
| `references/evidence-schema.md` | Building or validating the `evidence.json` block emitted with the report |
| `references/risk-rubric.md` | Grading a fix as Low/Medium/High risk; need an example of the rubric in action |
| `references/adversarial-prompts.md` | Running the adversarial pass; need the disproof template for the active hypothesis class |
| `references/check-explanations.md` | User asks "explain the methodology" or "why this skill order" |

The reference files are progressive disclosure — keep SKILL.md compact; load deeper material only when needed.

## Output Format

```
## SQL Server Performance Review — Unified Report

### Summary
- Files analyzed: N
- Skills applied: M (of 14 available)
- Hypotheses considered: H (primary + adversarial alternatives)
- Findings: X Critical, Y Warnings, Z Info
- Primary bottleneck: [single sentence stating the root cause]
- Highest-priority fix: [single most impactful action with check ID and skill source]
- Early termination: [Yes - 3 skills converged at phase N | No - exhaustive run | Override: --exhaustive]

### Hypothesis Trace
| Rank | Hypothesis | Initial confidence | Probes run | Final confidence | Status |
|------|-----------|-------------------|------------|------------------|--------|
| 1 | [name] | HIGH/MED/LOW | [skill list] | HIGH/MED/LOW | Confirmed / Refuted / Inconclusive |
| 2 | [name] | HIGH/MED/LOW | [skill list] | HIGH/MED/LOW | Confirmed / Refuted / Inconclusive |
| ... | ... | ... | ... | ... | ... |

### Adversarial Check
- Primary hypothesis: [name]
- Disproof attempt: [the template-driven counter-probe]
- Result: [No contradiction | Weak contradiction noted as caveat | Strong contradiction — alternative escalated]
- Alternative (if escalated): [name + brief evidence]

### Findings (Consolidated, Cross-Skill)

#### Critical
[C1] [Name] — [skill IDs that fired, e.g., S9 + I1 + Q7]
- Evidence:
  - [source artifact]: [observed value] vs threshold [threshold value]
  - [source artifact]: [observed value] vs threshold [threshold value]
  - [source artifact]: [observed value] vs threshold [threshold value]
- Confidence: HIGH/MEDIUM/LOW
- Impact: [one-sentence runtime effect]

#### Warnings
[W1] ...

#### Info
[I1] ...

### Per-Skill Section (raw outputs, for drill-down)

#### tsql-review
[passthrough of tsql-review's structured output]

#### sqlwait-review
[passthrough]

#### sqlplan-review (per plan)
[passthrough per plan or sqlplan-batch summary]

[... one subsection per skill that ran ...]

### Cross-Cutting Findings
| Finding | Source skills | Evidence link | Impact |
|---------|---------------|---------------|--------|

### Recommendation Conflicts
[If any: e.g., sqlplan-index-advisor recommends index X but sqlplan-batch shows that table over-indexed.
Each conflict explicit with both sides cited. Empty section if no conflicts detected.]

### Consolidated Fix Priority
| Rank | Action | Effort | Window | Risk | Side effects | Rollback | Verification | Confidence | Resolves |
|------|--------|--------|--------|------|--------------|----------|--------------|------------|----------|
| 1 | [exact T-SQL or config change] | [time] | [window] | Low/Med/High | [list] | [exact rollback T-SQL] | [capture to re-run and expected delta] | HIGH/MED/LOW | [C1, W2, ...] |

### Missing Artifacts
- [ ] [artifact name] — would resolve [hypothesis name] (capture: [skill/scripts/...sql])

### Passed Checks
[Per-skill list of evaluated-but-not-fired checks. Confirms analytical coverage was thorough.]

### Skills Skipped
| Skill | Reason |
|-------|--------|
| sqlplan-deadlock | No deadlock XML in input |
| clusterlog-review | No CLUSTER.LOG in input |
| ... | ... |

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-17 09:30 NZST"]*
```

Every Critical finding must cite at least one check ID plus the source artifact (file path or pasted-block label) plus the observed value plus the threshold. Findings without that evidence are downgraded to Info or removed.

The Recommendation Conflicts section is mandatory — if no conflicts, state "None detected" explicitly. Silence is not acceptable.

## Notes

- The orchestrator never opens a network connection to SQL Server. The capture-bundle generator (tier 3) emits scripts for the user to run; result files come back to the orchestrator as inputs.
- If a single artifact triggers multiple skills (e.g., a `.sqlplan` for both sqlplan-review and sqlplan-index-advisor), invoke them in the documented order (review before advisor) so the advisor can reference the review's findings.
- For inputs where classification is ambiguous (e.g., a `.txt` that matches two skill signals), prefer the higher-cost skill — analysis cost is bounded by the cost budget but missed findings are unbounded.
- The "Skills Skipped" section is required so the user can see at a glance which areas had no input data. Missing data is itself a finding.

## Companion Skills

- `/tsql-review` — Static T-SQL source analysis. The orchestrator routes any `.sql` source to this first because it needs no execution data.
- `/sqlstats-review` — Per-statement STATISTICS IO/TIME parser. Routed when SSMS Messages-tab output is present.
- `/sqltrace-review` — Profiler / Extended Events trace analysis. Routed when `.trc`, `.xel`, or `fn_trace_gettable()` output is present.
- `/sqlwait-review` — Server-wide wait statistics. The cheapest informative skill for "server feels slow" with no other artifacts.
- `/sqlplan-review` — Single-plan deep-dive. The orchestrator routes per `.sqlplan` after triage skills complete.
- `/sqlplan-compare` — Two-plan diff for regression cases. Routed when two plans for the same query are provided.
- `/sqlplan-index-advisor` — Index DDL recommendations. Runs after sqlplan-review to consolidate suggestions.
- `/sqlplan-deadlock` — Deadlock graph analysis. Routed on `.xdl` / system_health XE output.
- `/sqlplan-batch` — Folder-of-plans dashboard. Routed when more than ~10 `.sqlplan` files are present, instead of per-plan sqlplan-review.
- `/query-store-review` — Query Store DMV analysis. Routed when Query Store output is present; informs regression hypotheses.
- `/procstats-review` — Procedure / trigger / function runtime stats. Routed when `sys.dm_exec_procedure_stats` output is present.
- `/hadr-health-review` — Always On AG state. Routed for AG topology questions or failover root cause.
- `/clusterlog-review` — WSFC cluster log. Routed alongside hadr-health-review and errorlog-review for failover analysis.
- `/errorlog-review` — SQL Server ERRORLOG. Routed for outage timelines, login bursts, memory pressure, I/O warnings.
- `/spn-review` — SPN and Kerberos delegation. Routed when Kerberos / login failure signals are present.
