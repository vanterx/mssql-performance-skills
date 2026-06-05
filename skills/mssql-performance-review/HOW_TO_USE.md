# How to Use `mssql-performance-review`

A detailed user guide for the orchestrator skill. Covers installation, every input mode, every command flag, worked examples, output interpretation, follow-up Q&A, cost management, domain memory, the capture-bundle workflow, and the baseline-diff verification loop.

Last updated: 2026-05-18 NZST.

---

## Table of Contents

1. [What this skill is](#1-what-this-skill-is)
2. [When to use it vs when not to](#2-when-to-use-it-vs-when-not-to)
3. [Installation](#3-installation)
4. [Quick start (30 seconds)](#4-quick-start-30-seconds)
5. [The four input modes](#5-the-four-input-modes)
6. [Command flags reference](#6-command-flags-reference)
7. [Worked examples](#7-worked-examples)
8. [Reading the report](#8-reading-the-report)
9. [Follow-up Q&A patterns](#9-follow-up-qa-patterns)
10. [Cost management](#10-cost-management)
11. [Domain memory (`facts.json`)](#11-domain-memory-factsjson)
12. [Capture-bundle workflow](#12-capture-bundle-workflow)
13. [Verification and the baseline-diff loop](#13-verification-and-the-baseline-diff-loop)
14. [Troubleshooting](#14-troubleshooting)
15. [Privacy and the offline trust model](#15-privacy-and-the-offline-trust-model)
16. [Reference index](#16-reference-index)

---

## 1. What this skill is

`mssql-performance-review` is an **agentic, offline orchestrator**. You give it a mix of SQL Server artifacts (or a one-sentence symptom description), and it produces a single consolidated performance review report — with explicit evidence, risk-rated fix recommendations, rollback steps, and verification instructions.

Under the hood, it routes the artifacts to the 15 specialised review skills in this repo (tsql-review, sqlplan-review, sqlwait-review, etc.), runs an adversarial check to disprove its own primary hypothesis, and merges every skill's findings into one report.

**Strictly offline.** The orchestrator never opens a connection to your SQL Server. Every script it suggests is for you to run; every result is something you paste back. This is intentional — air-gap compatible, no connection strings, no consent prompts, no surprise writes.

Eleven cross-cutting primitives distinguish this from a naive dispatcher:

| Primitive | What it does |
|-----------|--------------|
| Evidence chain | Every Critical finding cites ≥3 check IDs from ≥2 skills with source artifact + observed value + threshold |
| Risk-aware recommendations | Every fix has action + effort + window + risk class + side effects + rollback + verification + confidence |
| Adversarial root-cause check | A mandatory pass that tries to disprove the primary hypothesis before declaring a root cause |
| Confidence-driven early termination | Stop probing when 3+ skills converge HIGH with no contradiction |
| Multi-model cost routing | Haiku for triage, Sonnet for synthesis, Opus for the adversarial pass — ~40% cheaper than all-Sonnet |
| Skill-graph DAG | Dynamic dispatch graph — probes that depend on each other sequence correctly; everything else runs in parallel |
| Domain memory | Per-instance facts (`MAXDOP`, AG topology, partitioning) inform every recommendation |
| Follow-up Q&A | After the report, ask "why?" — most answers are free from the in-context evidence chain |
| Capture bundle generator | When artifacts are missing, emit read-only `.sql` scripts for you to run |
| Verification checklist | Every recommendation specifies which capture to re-run and the expected metric change |
| Baseline-diff feedback loop | After deploy, `--baseline` tags each prior recommendation as verified-effective / partial / no-change / regressed-elsewhere |

> **What is a DAG?** A Directed Acyclic Graph is a set of nodes connected by one-way edges with no cycles — you can never follow edges back to where you started. Here the nodes are the 15 sub-skills and the edges are dependencies or findings-triggered follow-ups. *Directed* means `sqlwait-review` finding a missing-index signal can open an edge *to* `sqlindex-advisor` — not the other way around. *Acyclic* means the analysis always terminates. The orchestrator walks this graph in dependency order and runs independent nodes in parallel, so a simple input might dispatch 2–3 sub-skills while a complex mixed-artifact input dispatches 8–10.

---

## 2. When to use it vs when not to

### Use `mssql-performance-review` when:

- **You have a mixed pile of artifacts** (a `.sqlplan` + a `.sql` source + statistics output + wait stats + a trace excerpt) and aren't sure where to start.
- **You have a symptom but no artifacts yet** ("CPU on prod is high since 09:00, users complaining"). The orchestrator generates a capture-script bundle for you.
- **You want one consolidated report** suitable for a change ticket or post-mortem, with cross-skill validation and explicit evidence chains.
- **You want adversarial scrutiny** of the recommendations — confirmation bias is the orchestrator's biggest failure mode, and the mandatory adversarial pass guards against it.
- **You want the verification loop** — close the gap between "we recommended X" and "did X work?"

### Use a specialised skill directly when:

- **You have one artifact and you know what it is.** A single `.sqlplan` → `/sqlplan-review`. A wait-stats capture → `/sqlwait-review`. A deadlock XML → `/sqldeadlock-review`. Faster turnaround; no synthesis overhead.
- **You want the specialised skill's full raw output.** The orchestrator summarises into a Per-Skill section; the specialised skill's standalone output is more detailed.
- **You're doing a narrow targeted analysis** (e.g., index advisor from a single plan). The orchestrator would still work but adds unnecessary cost.

The orchestrator does not replace the specialised skills — it composes them.

---

## 3. Installation

This skill is part of the [mssql-performance-skills](https://github.com/vanterx/mssql-performance-skills) repository. Install all skills (recommended):

```bash
# Project-scoped install
npx skills add vanterx/mssql-performance-skills

# Global install (skills available in every project)
npx skills add vanterx/mssql-performance-skills -g
```

After install, verify:

```bash
ls ~/.claude/skills/mssql-performance-review/   # global
# or
ls ./.claude/skills/mssql-performance-review/   # project
```

The directory should contain `SKILL.md`, `references/`, `evals/`, `scripts/`, `assets/`.

You can also clone the repo and use the skills directly:

```bash
git clone https://github.com/vanterx/mssql-performance-skills.git
cp -r mssql-performance-skills/skills/* ~/.claude/skills/
```

### Prerequisites

- Node.js ≥ 18 (only for `npx skills add`)
- Claude Code, OpenCode, or another agent harness that supports SKILL.md files
- Your SQL Server tooling of choice (SSMS, sqlcmd, Azure Data Studio) — for **you** to run the capture scripts; the orchestrator never touches the database

---

## 4. Quick start (30 seconds)

Have a `.sqlplan` file you want analyzed alongside its T-SQL source and STATISTICS IO output?

```
/mssql-performance-review ./my-artifacts/
```

The orchestrator classifies every file in the directory, dispatches the right specialised skills (sqlplan-review, tsql-review, sqlstats-review), runs the adversarial check, and emits a unified report.

No artifacts yet? Just a symptom?

```
/sql-triage CPU is pegged at 95% on PROD-SQL01 since 09:00 today, no recent deploy
```

The orchestrator generates a [capture bundle](#12-capture-bundle-workflow) — a directory of read-only `.sql` scripts plus instructions. Run them in SSMS, paste results back, then:

```
/mssql-performance-review --resume ./captures/<run-id>/
```

You get a full report. Cost: ~USD 0.04–0.25 depending on artifact volume.

---

## 5. The four input modes

The orchestrator accepts input four ways. Each one routes to the same dispatch pipeline.

### 5.1 Directory mode

```
/mssql-performance-review ./path/to/artifacts/
```

The orchestrator enumerates every file under the directory, classifies each by content (not extension), and routes to the appropriate sub-skill. Mixed artifact types are fine. Subdirectories are walked recursively.

**Best for:** Incidents where you have a folder full of captures from production.

### 5.2 File list mode

```
/mssql-performance-review ./slow-proc.sqlplan ./slow-proc.sql ./wait-stats.txt
```

Same as directory mode but with explicit files. Useful when you only want a subset of a larger capture directory.

**Best for:** Targeted analysis of specific files.

### 5.3 Inline paste mode

```
/mssql-performance-review

Here's my STATISTICS IO output:

Table 'Orders'. Scan count 1, logical reads 1842734, ...

And here's the wait stats snapshot:

wait_type             wait_time_ms  pct_total
SOS_SCHEDULER_YIELD   518,442       41.34
CXPACKET              482,221       38.45
...
```

Paste artifact content directly. The orchestrator detects the boundaries between blocks by recognizing artifact signatures. You can prefix each block with a type hint (`STATISTICS IO:`, `Wait stats:`) if classification is ambiguous.

**Best for:** Quick one-off reviews where the artifacts are small enough to paste.

### 5.4 Symptom-only mode

```
/sql-triage CPU is pegged at 95% on PROD-SQL01 since 09:00 today, no recent deploy
```

```
/mssql-performance-review users say the orders page is slow today; we changed nothing
```

No artifacts. The orchestrator generates 2–3 ranked hypotheses based on the symptom and emits a [capture bundle](#12-capture-bundle-workflow) for you to run. After running it, return with `--resume`.

**Best for:** "Something's wrong but I don't know what to look at first."

---

## 6. Command flags reference

All flags are optional. The orchestrator's defaults work well for most reviews.

| Flag | Default | Effect |
|------|---------|--------|
| `--model-tier {economy\|standard\|maximum}` | `standard` | Force a particular model routing tier. See [Cost management](#10-cost-management). |
| `--no-adversarial` | adversarial enabled | Skip the Opus adversarial pass. Saves ~6k tokens. Trades off confirmation-bias resistance. |
| `--exhaustive` | early termination enabled | Run every applicable skill even after 3+ skills converge HIGH. Useful for audits. |
| `--phases` | DAG dispatch | Revert to tier-1 fixed five-phase dispatch order. Useful for reproducibility against an older review. |
| `--baseline <path>` | none | Load a prior `state.json` and tag prior recommendations as verified/partial/no-change/regressed. See [Verification](#13-verification-and-the-baseline-diff-loop). |
| `--resume <bundle-dir>` | none | Resume from a capture-bundle paste-back. See [Capture-bundle workflow](#12-capture-bundle-workflow). |
| `--instance <name>` | auto-detected from artifacts | Load `~/.mssql-perf-review/instances/<name>.json` domain memory. See [Domain memory](#11-domain-memory-factsjson). |
| `--instance-facts <path>` | uses `--instance` resolution | Override the facts.json path (e.g., team-shared location). |
| `--feedback-file <path>` | `evals/feedback.jsonl` (local) | Override the feedback append path. |
| `--capture-instance-facts` | n/a (mutually exclusive with normal modes) | Emit a one-shot DMV-survey bundle for populating `facts.json`. |
| `--save-session` | session ends with report | Persist the session state (evidence chain + Q&A history) to `./state/<run-id>/` even if no `--baseline` is expected later. |

### Combined examples

```
# Cheapest review (Haiku-only, no adversarial)
/mssql-performance-review --model-tier economy --no-adversarial ./artifacts/

# Exhaustive audit review with maximum quality
/mssql-performance-review --model-tier maximum --exhaustive ./artifacts/

# Verification after deploying fixes
/mssql-performance-review --baseline ./state/20260517-0942/state.json ./captures/post-fix/

# Resume a capture bundle, route domain memory for a specific instance
/mssql-performance-review --resume ./captures/20260517-0930/ --instance PROD-SQL01
```

---

## 7. Worked examples

Three end-to-end examples showing the orchestrator in action. Sample artifacts and reference outputs ship in `skills/mssql-performance-review/examples/`.

### Example 1 — Artifact-driven review (most common path)

You've captured: `slow-proc.sql` (procedure source), `slow-proc.sqlplan` (actual plan from SSMS), `stats-iotime.txt` (STATISTICS IO/TIME output), `wait-stats.txt` (sys.dm_os_wait_stats snapshot). All four are in `./incident-20260517/`.

**Invocation:**

```
/mssql-performance-review ./incident-20260517/
```

**What happens:**

1. **Classification** (Haiku, ~2 sec). The orchestrator identifies each file: tsql source, execution plan, statistics output, wait stats.
2. **Hypothesis generation** (Haiku, ~3 sec). Two ranked hypotheses: parameter sniffing (MEDIUM) and missing index (MEDIUM).
3. **Parallel triage** (Haiku × 4 subagents, ~30 sec). tsql-review on the `.sql`, sqlstats-review on stats, sqlwait-review on waits, sqlquerystore-review skipped (no QS artifact).
4. **Plan deep dive** (Sonnet, ~45 sec). sqlplan-review on the `.sqlplan`. Fires S9 (parameter sniffing) and N5 (missing index).
5. **Index advisor** (Sonnet, ~20 sec). sqlindex-advisor consolidates the missing-index suggestion.
6. **Synthesis** (Sonnet, ~25 sec). Cross-references findings; builds evidence chain; ranks recommendations.
7. **Adversarial pass** (Opus, ~15 sec). Tries to disprove the parameter-sniffing hypothesis. Wait profile is CPU-dominant (SOS_SCHEDULER_YIELD) — consistent with sniffing. No contradiction.
8. **Report** (Sonnet, ~5 sec). Renders the full report.

**Total time:** ~2.5 minutes. **Total cost:** ~USD 0.21.

**Reference output:** [`skills/mssql-performance-review/examples/mixed-artifacts-analysis.md`](examples/mixed-artifacts-analysis.md)

### Example 2 — Symptom-only triage with capture bundle

Users report the app is slow. You have nothing captured yet.

**Invocation:**

```
/sql-triage CPU is pegged at 95% on PROD-SQL01 since 09:00, no recent deploy. Users complaining about orders page.
```

**What happens:**

1. **Hypothesis generation** (Haiku, ~3 sec). Three hypotheses: runaway query (MEDIUM), parameter sniffing (MEDIUM), compile pressure (LOW).
2. **Capture bundle generation** (Haiku, ~5 sec). The orchestrator writes `./captures/20260517-0930-cpu-spike/` with three curated scripts (wait stats, plan-from-cache, query-store instability), a README, a paste-back template, and a manifest.json.
3. **Orchestrator response:**
   ```
   I need more data to confirm my hypotheses. Generated capture bundle:
   
     ./captures/20260517-0930-cpu-spike/
     ├── README.md
     ├── 01-wait-stats.sql          (5 min sample — paste-back §1)
     ├── 02-plan-from-cache.sql     (single query — §2)
     ├── 03-query-store-instability.sql (last 24h — §3)
     ├── PASTE-RESULTS-HERE.md      (template — fill this in)
     └── manifest.json
   
   Run the scripts in your tool (SSMS, sqlcmd), paste outputs into PASTE-RESULTS-HERE.md,
   then run:
     /mssql-performance-review --resume ./captures/20260517-0930-cpu-spike/
   
   Note: I will not contact your SQL Server. All execution is your action.
   ```
4. **You run the scripts**, paste results, and re-invoke:
   ```
   /mssql-performance-review --resume ./captures/20260517-0930-cpu-spike/
   ```
5. The orchestrator parses paste-back, routes each section to the right sub-skill, and emits the full report just like Example 1.

**Total time:** ~5 minutes (mostly your time running the scripts). **Total cost:** ~USD 0.06.

**Reference output:** [`skills/mssql-performance-review/examples/symptom-first-analysis.md`](examples/symptom-first-analysis.md) (bundle-generation response) and [`skills/mssql-performance-review/examples/capture-bundle-example/`](examples/capture-bundle-example/) (sample bundle contents).

### Example 3 — Verification after deploying a fix

Yesterday you ran a review and got recommendations. You deployed the top fix (a covering index). Today, 24 hours later, you re-capture and verify:

**Invocation:**

```
/mssql-performance-review --baseline ./state/20260517-0942/state.json ./incident-followup-20260518/
```

**What happens:**

1. The orchestrator loads the prior state.json (evidence chain + recommendations from yesterday).
2. Runs the normal dispatch on the new artifacts (~2 min, ~USD 0.18).
3. For each prior recommendation, finds the corresponding finding in the new report.
4. Tags each as `verified-effective` / `partial` / `no-change` / `regressed-elsewhere` / `cannot-evaluate`.
5. Emits a Recommendation Status section in the new report.
6. Appends tags to `evals/feedback.jsonl` (gitignored) for future learning.

**Reference output:** [`skills/mssql-performance-review/examples/baseline-diff-analysis.md`](examples/baseline-diff-analysis.md)

---

## 8. Reading the report

The output structure is consistent across every invocation. Each section answers a specific question.

### 8.1 Summary block (first thing you read)

```
## Summary

- Files analyzed: 4
- Skills applied: 5 (of 14 available)
- Hypotheses considered: 2 (primary + 1 adversarial alternative)
- Findings: 2 Critical, 3 Warning, 2 Info
- Primary bottleneck: Parameter sniffing on dbo.usp_GetOrdersByCustomer
- Highest-priority fix: Add covering index on Orders(CustomerId, OrderDate) INCLUDE (Status, TotalAmount)
- Early termination: No — full dispatch ran (5 applicable skills)
- Cost: ~USD 0.21 (Haiku 23k tokens, Sonnet 31k tokens, Opus 6k tokens)
```

The Summary tells you the answer in one screen. Everything below is supporting evidence.

### 8.2 Hypothesis Trace

```
## Hypothesis Trace

| Rank | Hypothesis | Initial confidence | Probes run | Final confidence | Status |
|------|-----------|-------------------|------------|------------------|--------|
| 1 | Parameter sniffing on usp_GetOrders | MEDIUM | sqlstats, sqlplan, sqlwait | HIGH | Confirmed |
| 2 | Server-wide I/O bottleneck | LOW | sqlwait | LOW | Refuted (PAGEIOLATCH_SH only 14.7%) |
```

Shows what the orchestrator considered and why it converged on the primary. If your gut says "the real issue is X" and X isn't in the trace, that's a flag — either provide more artifacts or ask the orchestrator directly (see [Follow-up Q&A](#9-follow-up-qa-patterns)).

### 8.3 Adversarial Check

```
## Adversarial Check

- Primary hypothesis: Parameter sniffing
- Disproof attempt: "If sniffing was the root cause, wait profile should be CPU-dominant.
  PAGEIOLATCH_SH > 25% would refute. Observed: SOS_SCHEDULER_YIELD = 41.3%,
  PAGEIOLATCH_SH = 14.7% → consistent with sniffing."
- Result: no_contradiction
```

This is the orchestrator showing its work on disproving its own conclusion. If you see `strong_contradiction_alternative_escalated`, two competing hypotheses are surfaced in the Findings section.

### 8.4 Findings (Critical / Warning / Info)

```
## Findings

### Critical

[C1] Parameter sniffing on dbo.usp_GetOrdersByCustomer
- Confidence: HIGH (primary skill: sqlplan-review)
- Evidence:
  - sqlplan-review S9 fired
    - Source: order_proc.sqlplan (Stmt 1, NodeId 12)
    - Observed: actual rows 1,842,734 vs estimated 50 (36,854× ratio)
    - Threshold: ≥ 1,000× = Critical
  - sqlstats-review I1 corroborates
    - Source: stats-iotime.txt (Statement 1, Table 'Orders')
    - Observed: 1,842,734 logical reads
    - Threshold: > 1,000,000 = Warning
  - sqlquerystore-review Q7 corroborates
    - ...
- Impact: Runtime varies from 200ms to 8s depending on first-compile parameters.
```

Every Critical finding cites **at least 3 evidence entries from at least 2 distinct skills**. Findings that don't meet this bar are downgraded to Info or removed. Reproducibility is guaranteed — open the cited artifact, look at the cited location, compare to the cited threshold.

### 8.5 Per-Skill Section

Raw outputs from each specialised skill that ran. Used for drill-down when the consolidated findings aren't enough detail.

### 8.6 Cross-Cutting Findings

Findings that span multiple skills. For example: "CXPACKET share will drop after the missing-index fix" — combining sqlwait-review and sqlindex-advisor signals.

### 8.7 Recommendation Conflicts

**Mandatory section** — if no conflicts, the orchestrator states "None detected" explicitly. Silent omission isn't acceptable. Conflicts look like:

> sqlindex-advisor recommends `IX_A` on table `T`. sqlplan-batch's usage stats show 3 existing unused indexes on `T`. **Conflict:** drop the unused indexes first before adding more.

### 8.8 Consolidated Fix Priority

```
| Rank | Action | Effort | Window | Risk | Side effects | Rollback | Verification | Confidence | Resolves |
|------|--------|--------|--------|------|--------------|----------|--------------|------------|----------|
| 1 | CREATE NONCLUSTERED INDEX ... | 5 min | Anytime | Low | +1.2 GB storage; ~3% write | DROP INDEX ... | Re-run /sqlplan-review on usp_GetOrders 24h later — expect Index Seek replacing Scan, statement cost < 5 | HIGH | C1, C2, W2 |
```

This is the deploy-ready output. Every column is required:
- **Action** — exact T-SQL or configuration change. Never "consider adding an index".
- **Effort** — your time to implement.
- **Window** — when it's safe to run. "Anytime" only when truly anytime.
- **Risk** — Low / Medium / High per the [risk rubric](references/risk-rubric.md).
- **Side effects** — storage, write overhead, AG replication volume, plan-shape impact on other queries.
- **Rollback** — exact T-SQL to undo.
- **Verification** — re-capture instruction + expected metric movement.
- **Confidence** — HIGH / MEDIUM / LOW.

If any column is missing or vague, that's a bug; ask the orchestrator to expand it via [Follow-up Q&A](#9-follow-up-qa-patterns).

### 8.9 Verification — After Deploying Fixes

A standalone section that promotes the per-recommendation verification field into an actionable checklist. Suggested timing per recommendation type:

| Recommendation type | Suggested wait | Why |
|---------------------|----------------|-----|
| Index creation | 24h | Plan cache repopulates; workload exercises the index |
| Index drop | 1h | Affected plans recompile on first call |
| UPDATE STATISTICS | 1h | Next compile picks up new stats |
| OPTION (RECOMPILE) hint | 1h | First compile after deploy |
| MAXDOP / CTfP change | 24h | New setting applies to new compiles; old plans persist |
| Enable RCSI / SI | 1h–1d | Reads use row-versioning immediately; full mix over a day |
| Trace flag change | After next restart | Some apply at startup |
| Force / unforce plan | 1h | Next execution uses the change |
| AG / failover fix | After next planned failover or stress | May not recur until trigger condition does |

After your wait period: `/mssql-performance-review --baseline ./state/<this-run>/state.json ./<new-captures>/`.

### 8.10 Missing Artifacts

What the orchestrator would have run if you'd provided more data. Each entry cites the suggested capture script:

> - [ ] Query Store output for `query_hash` of `usp_GetOrders` — would confirm plan instability over time (capture: `skills/sqlquerystore-review/scripts/01_capture_queries.sql`)

### 8.11 Passed Checks

Every check that was evaluated but didn't fire. Proves analytical coverage — silence on a check isn't an absence of analysis, it's an explicit PASS.

### 8.12 Skills Skipped

Every specialised skill that didn't run, with a reason. Confirms the orchestrator considered them.

---

## 9. Follow-up Q&A patterns

After the report, the orchestrator stays in the session. **Most follow-ups are free** — they read from the in-context evidence chain without new tool calls.

### Free follow-ups (in-context)

Ask "why" or "why not" about anything in the report:

```
You: Why this index ordering? Why not (OrderDate, CustomerId)?
```

```
You: Why was MAXDOP not in the recommendations? CXPACKET was 38% of waits.
```

```
You: Show me only the Critical findings.
```

```
You: Re-rank the fixes by effort, not impact.
```

```
You: What did sqlwait-review say about WRITELOG specifically?
```

### Cheap follow-ups (new probe, ~USD 0.02–0.05)

When you provide new artifacts:

```
You: Here are the wait stats from 30 minutes after the fix. Did the WRITELOG share drop?
```

When you ask for a check that requires new analysis:

```
You: I forgot — did you check the plan for parallel scan operators specifically?
```

### Refusals

The orchestrator refuses requests that violate the trust model or are out of scope:

```
You: Can you connect to PROD-SQL01 and run this query yourself?
Orchestrator: No — I'm strictly offline. Run it yourself; paste back the output.
```

```
You: What version of SQL Server should I upgrade to?
Orchestrator: Out of scope. I analyze performance artifacts; version-selection
strategy depends on factors I don't have (licensing, hardware, application
compatibility). The DBA team or a Microsoft sizing exercise is the right path.
```

### Cost-guard warnings

After ~12k follow-up tokens, the orchestrator warns:

```
Note: this Q&A session has consumed ~12,000 tokens beyond the original report.
Total session cost: ~USD 0.18 (within budget). Continuing.
```

After ~50k:

```
Warning: this Q&A session has consumed ~50,000 tokens beyond the original report.
Total session cost: ~USD 0.42. Consider summarising and starting a new session
to reset context.
```

You can ignore and continue; there's no hard cap.

---

## 10. Cost management

The orchestrator's default is `--model-tier standard` — the cost/quality sweet spot. Three knobs let you trade cost against thoroughness.

### Per-tier cost (typical mixed-artifact review)

| Tier | Adversarial | Total tokens | USD | Quality notes |
|------|-------------|--------------|-----|---------------|
| `economy` | Haiku-only | ~50k | ~USD 0.06 | Lower quality on complex multi-statement plans; adversarial drops to Sonnet (still mandatory) |
| `standard` | Opus | ~66k | ~USD 0.21 | Best cost/quality balance |
| `maximum` | Opus | ~85k | ~USD 0.50 | Highest quality; uses Opus for synthesis + adversarial + deep-dive |
| `standard --no-adversarial` | none | ~60k | ~USD 0.13 | Saves ~USD 0.08; trades off confirmation-bias resistance |

### When to choose each tier

| Situation | Recommended |
|-----------|-------------|
| Routine review of well-understood workload | `economy` |
| Production incident review with confidence-critical recommendations | `standard` (default) |
| Compliance/audit review driving a change ticket | `maximum --exhaustive` |
| Cost-sensitive scheduled review (daily batch across many servers) | `economy --no-adversarial` |
| Previous review missed the obvious problem | `maximum` (escalates synthesis + adversarial to Opus) |

### Cost reporting in the report

Every report's Summary block includes a one-line cost report:

```
Cost: ~USD 0.21 (Haiku 23k tokens, Sonnet 31k tokens, Opus 6k tokens). Override with --model-tier {economy|standard|maximum}.
```

For a per-phase breakdown, ask in follow-up Q&A:

```
You: Show me the cost breakdown per phase.
```

---

## 11. Domain memory (`facts.json`)

The orchestrator can read per-instance facts (MAXDOP, AG topology, partitioning, RCSI state) to make recommendations environment-aware. Without facts, recommendations are generic; with facts, redundant recommendations are rejected and environment-specific escalators kick in.

### File location

Default: `~/.mssql-perf-review/instances/<server-name>.json`

The orchestrator auto-detects the instance name from `@@SERVERNAME` if it appears in any artifact, or from the `--instance` flag.

### Populating `facts.json`

The orchestrator emits a one-shot DMV-survey bundle:

```
/sql-triage --capture-instance-facts
```

This generates `./captures/instance-facts-<run-id>/` with a single SQL script that surveys instance configuration. You run it; the orchestrator on resume parses the output into a draft `facts.json` and shows it for review. You copy the JSON to the suggested path (the orchestrator never writes silently).

### Example `facts.json`

```json
{
  "instance": "PROD-SQL01",
  "captured_at": "2026-05-17T08:30:00+12:00",
  "facts": {
    "physical_cores": 96,
    "maxdop": 8,
    "cost_threshold_for_parallelism": 50,
    "max_server_memory_mb": 384000,
    "edition": "Enterprise",
    "is_ag_primary": true,
    "ag_replicas": [...],
    "rcsi_enabled_dbs": ["OrdersDB"],
    "partitioned_tables": [
      {"schema": "dbo", "table": "OrdersHeader", "partition_function": "PF_OrdersByMonth"}
    ],
    "user_notes": [
      "OrdersHeader partitioned monthly; index recommendations must be partition-aligned.",
      "Do not recommend changing MAXDOP without DBA approval."
    ]
  }
}
```

### What facts change

| Recommendation | If facts say... | Effect |
|---------------|-----------------|--------|
| Change MAXDOP to N | `maxdop == N` already | **Rejected** |
| Enable RCSI on DB | DB in `rcsi_enabled_dbs` | **Rejected** (no-op) |
| Add index on T | T in `partitioned_tables` | **Escalated** — DDL must include partition column; risk raised one step |
| ALTER DATABASE | `is_ag_primary == true` | **Escalated** — side effect: replicates to all secondaries |
| Online index rebuild | `edition != "Enterprise"` and LOB columns | **Rejected** — Standard edition forces offline; suggest maintenance window |

### Stale facts

If `captured_at` is older than 90 days, the orchestrator warns:

```
Warning: domain memory at ~/.mssql-perf-review/instances/PROD-SQL01.json was captured
2026-02-15 (97 days ago). MAXDOP, AG topology, edition may have changed. Re-run
/sql-triage --capture-instance-facts to refresh.
```

Rejection/escalation rules that depend on a stale fact are downgraded to "review and confirm".

### Team-shared facts

Different DBAs may have different views of an instance. Per-user `facts.json` is the default. For team-shared facts, copy the file to a team location and use `--instance-facts <path>`.

For full schema, rejection/escalation catalogue, and staleness rules: [`references/domain-memory.md`](references/domain-memory.md).

---

## 12. Capture-bundle workflow

When the orchestrator detects missing artifacts (or you invoke `/sql-triage` with just a symptom), it generates a self-contained **capture bundle** — a directory of read-only `.sql` scripts plus instructions.

### Lifecycle

```
1. /sql-triage <symptom>
   or /mssql-performance-review <artifacts with gaps>
        ↓
2. Orchestrator emits ./captures/<run-id>/
   - README.md (run order, security notes, time estimates)
   - 01-<script>.sql, 02-<script>.sql, ... (curated for the active hypotheses)
   - PASTE-RESULTS-HERE.md (template)
   - manifest.json (machine-readable mapping)
        ↓
3. You run the scripts in SSMS / sqlcmd / your tool
        ↓
4. You paste outputs into PASTE-RESULTS-HERE.md (or use FILE: path for large outputs)
        ↓
5. /mssql-performance-review --resume ./captures/<run-id>/
        ↓
6. Orchestrator parses paste-back, routes to sub-skills, emits the full report
```

### Bundle directory layout

```
./captures/20260517-0930-cpu-spike/
├── README.md                       # Generated from assets/bundle-readme-template.md
├── 01-wait-stats.sql               # Copy of skills/sqlwait-review/scripts/01_capture_wait_stats.sql
├── 02-plan-from-cache.sql          # Copy of skills/sqlplan-review/scripts/01_capture_from_cache.sql
├── 03-query-store-instability.sql  # Copy of skills/sqlquerystore-review/scripts/01_capture_queries.sql
├── PASTE-RESULTS-HERE.md           # Generated from assets/paste-results-template.md
└── manifest.json                   # Machine-readable bundle metadata
```

`<run-id>` follows the format `YYYYMMDD-HHMM-<short-symptom>`. You can rename the directory — `--resume` works on the path.

### Curation rules

Not all 27 available scripts every time — the bundle is curated to 3–5 scripts targeting the active hypotheses:

| Hypothesis | Curated scripts |
|------------|-----------------|
| Parameter sniffing | wait stats, plan-from-cache for top consumer, query-store plan history |
| Missing index | plan-from-cache, sqlstats template, missing-index DMV extract |
| Server-wide I/O | wait stats, sys.dm_io_virtual_file_stats, top reader plan |
| Lock/blocking | sys.dm_exec_requests, sys.dm_tran_locks, blocked process report |
| AG / failover | ERRORLOG read query, Get-ClusterLog command, hadr DMVs |
| Kerberos auth | setspn -L command, Get-AD* commands, ERRORLOG login filter |

If total estimated paste-back exceeds ~50k tokens, the orchestrator emits a smaller bundle and warns that follow-up bundles may be needed.

### Partial captures are fine

You don't have to run every script. Re-invoke `--resume` after any subset; the orchestrator gives a partial report and tells you which remaining scripts would most improve confidence.

### Paste-back format

The template has one section per script:

```markdown
## 01-wait-stats

<paste output here>

## 02-plan-from-cache

<paste output, or reference a file:>
FILE: ./post-fix-plan.sqlplan
```

For large outputs (especially `.sqlplan` XML), use `FILE: <path>` to reference a separate file. The orchestrator reads the file at resume time.

### Reference

Full bundle layout, manifest schema, edit-required scripts, and the resume flow: [`references/capture-bundle-spec.md`](references/capture-bundle-spec.md). Sample bundle: [`skills/mssql-performance-review/examples/capture-bundle-example/`](examples/capture-bundle-example/).

---

## 13. Verification and the baseline-diff loop

A fix without verification is a hypothesis. The verification loop closes the gap.

### Step 1 — Get a report with verification instructions

Every report ends with a **Verification — After Deploying Fixes** section. Per-recommendation re-capture instructions, suggested timing, expected metric movement.

### Step 2 — Deploy the fix

Out of scope for the orchestrator. Your deployment, your release process.

### Step 3 — Wait the suggested period

24h for plan changes; 1h for stats updates; 7d for trend-based fixes. The Verification section in your report has the specifics.

### Step 4 — Re-capture

Re-run the same captures the original review used (or run the orchestrator's capture-bundle for them).

### Step 5 — Run baseline-diff

```
/mssql-performance-review --baseline ./state/<original-run-id>/state.json ./<new-captures>/
```

The orchestrator:
1. Loads prior state (evidence + recommendations).
2. Runs normal dispatch on new artifacts.
3. Tags each prior recommendation.

### Tags

| Tag | Condition |
|-----|-----------|
| `verified-effective` | Prior evidence gone; no new related findings |
| `partial` | Prior evidence reduced but still above threshold; OR finding gone but a related one appeared |
| `no-change` | Prior evidence unchanged (within ±10%) |
| `regressed-elsewhere` | Prior finding gone but new related findings appeared — bottleneck shifted |
| `cannot-evaluate` | Required artifact missing from new input |

### Feedback file

Every baseline-diff run appends to `evals/feedback.jsonl`:

```jsonl
{"run_id":"20260518-1015","baseline_run_id":"20260517-0942","rec_id":1,"tag":"verified-effective","hypothesis_class":"missing_index","evidence_delta":{"logical_reads":[1842734,392]}}
```

`feedback.jsonl` is **user-local** (gitignored). For team-shared learning, point the orchestrator at a team file: `--feedback-file <path>`.

### Why this matters

Over time, the orchestrator can use `feedback.jsonl` to refine hypothesis ranking:
- "In this codebase, missing_index recommendations are verified-effective 85% of the time."
- "Parameter-sniffing recommendations using OPTIMIZE FOR are verified-effective 60% / partial 30% / no-change 10%."

This is the self-improvement loop. Your real-world outcomes train the orchestrator's future recommendations.

For full tagging rules, timing guidance, edge cases (rollbacks, multi-rec findings, artifact drift), and the verification quality metric: [`references/verification-checklist.md`](references/verification-checklist.md).

---

## 14. Troubleshooting

### "The orchestrator picked the wrong root cause"

Three escalations:

1. **Provide more artifacts.** Often the orchestrator picked the loudest signal because it had nothing else. Add wait stats, Query Store, or a trace.
2. **Run with `--model-tier maximum`.** Promotes synthesis and the adversarial pass to Opus.
3. **Tell it directly in follow-up Q&A.** "I think the actual issue is X. Why didn't you flag it?" The orchestrator either points to evidence supporting its conclusion (and you can decide if you accept that) or dispatches a targeted probe for X.

### "The report flags something that's not a problem in our environment"

Use [domain memory](#11-domain-memory-factsjson). Add a `user_notes` entry to `facts.json` saying "do not recommend changing X" and the orchestrator will reject those recommendations on future runs.

### "I can't run all the capture scripts in the bundle"

Run what you can. `--resume` works on partial captures. The orchestrator gives a partial report and tells you which remaining scripts would most improve confidence. You can also remove scripts you don't want to run before re-invoking.

### "The cost was higher than expected"

Check the cost report in the Summary. Common causes:
- `.sqlplan` files are very large (>50k tokens each). Use `sqlplan-batch` instead of running sqlplan-review per plan.
- The folder had many trace excerpts and STATISTICS outputs. Filter to the most relevant.
- `--exhaustive` was set — every applicable skill ran. Use default early termination unless you specifically need exhaustive.
- The Q&A session ran long. Each follow-up adds tokens.

### "verify-docs.sh fails after I added something"

The orchestrator's verify gates:
- SKILL.md ≤ 1000 lines (warn ≥ 900)
- `references/check-explanations.md` and `references/README.md` exist
- `evals/evals.json` exists
- `scripts/` directory non-empty (`.gitkeep` is fine for dispatchers)
- `assets/` directory present (`.gitkeep` is fine if no assets)
- Attribution footer (`*Analyzed by: ...*`) in the Output Format block

Run `bash scripts/verify-docs.sh` from the repo root for the full check list.

### "I want to disable the adversarial pass to save cost"

`--no-adversarial`. Saves ~6k tokens (~USD 0.09 with Opus pricing). Trades off confirmation-bias resistance — you'll lose the disproof attempt that catches "loudest signal" errors.

### "The orchestrator suggested an index, but I want to know if it'll regress other queries"

Ask in follow-up Q&A:

```
You: Will the new index from Rank 1 regress any other queries on Orders?
```

The orchestrator scans the in-context evidence and looks for other queries that touch Orders. If sqlplan-batch was run (multi-plan workload), it has the data; otherwise it tells you what to capture for confidence.

### "I'm in an air-gapped environment without npx"

Clone the repo and copy manually:

```bash
git clone https://github.com/vanterx/mssql-performance-skills.git
cp -r mssql-performance-skills/skills/* ~/.claude/skills/
```

The orchestrator works offline — it doesn't need network at runtime (it never contacts your SQL Server either).

---

## 15. Privacy and the offline trust model

The orchestrator is strictly offline. Here is exactly what it does and doesn't do.

### What the orchestrator does

| Action | Scope |
|--------|-------|
| Reads files you provide | Yes |
| Reads `~/.mssql-perf-review/instances/<server>.json` if it exists | Yes (user-managed, read-only) |
| Writes `./captures/<run-id>/` directories (capture bundles) | Yes — scripts copied from `skills/<name>/scripts/`, README + paste-back template + manifest only |
| Writes `./state/<run-id>/` directories (analysis state) | Yes — evidence chain + report |
| Appends to `evals/feedback.jsonl` after baseline-diff | Yes — append-only, gitignored, user-local |

### What the orchestrator never does

| Action | Why |
|--------|-----|
| Opens a network connection to SQL Server | Architectural — the orchestrator has no SQL client; cannot make connections |
| Executes T-SQL against any server | Same reason |
| Writes to `facts.json` silently | User-managed; orchestrator only reads |
| Schedules async tasks or cron jobs | No scheduler integration |
| Transmits data over the network | The skill is a Markdown file; no exfiltration paths |
| Modifies your SQL Server, your tooling, or anything outside `./captures/` and `./state/` | Trust boundary |

### Data in artifacts

Your artifacts may contain sensitive data — query text, parameter values, login names, server names. The orchestrator processes this data in-memory during the review and writes evidence records into `./state/<run-id>/`. Review the output before sharing.

Capture bundles in `./captures/<run-id>/` contain the `.sql` scripts (no data); paste-back files contain DMV output you pasted (potentially sensitive). Both are local to your machine.

### Air-gap compatibility

Yes. The orchestrator is a set of Markdown files plus the LLM that interprets them. No live SQL contact, no scheduled tasks, no network calls. Works in air-gapped, regulated, or third-party-DBA-on-jump-box environments.

---

## 16. Reference index

For each tier-2 and tier-3 primitive, the deep reference is in `references/`. Load them on demand when you need detail beyond what `SKILL.md` and this guide provide.

| Reference | Topic |
|-----------|-------|
| [`references/README.md`](references/README.md) | Index of all reference files with load-when guidance |
| [`references/check-explanations.md`](references/check-explanations.md) | Methodology — dispatch heuristics, hypothesis classes, conflict catalogue, why the adversarial pass is mandatory |
| [`references/evidence-schema.md`](references/evidence-schema.md) | `evidence.json` schema, field rules, human-readable rendering, reproducibility guarantee |
| [`references/risk-rubric.md`](references/risk-rubric.md) | Risk-class definitions, environmental escalators, side-effect checklist, rollback rules |
| [`references/adversarial-prompts.md`](references/adversarial-prompts.md) | Disproof templates per hypothesis class |
| [`references/model-routing.md`](references/model-routing.md) | Multi-model routing tier table, override flags, cost profile |
| [`references/skill-dag.md`](references/skill-dag.md) | DAG construction, static and dynamic edge catalogues, walk algorithm |
| [`references/domain-memory.md`](references/domain-memory.md) | `facts.json` schema, rejection/escalation rules, staleness handling |
| [`references/followup-qa.md`](references/followup-qa.md) | Question taxonomy, when-to-probe rules, refusal patterns |
| [`references/capture-bundle-spec.md`](references/capture-bundle-spec.md) | Bundle layout, curation rules, manifest schema, resume flow |
| [`references/verification-checklist.md`](references/verification-checklist.md) | Verification section structure, tagging rules, feedback.jsonl schema |

### Examples

| File | Demonstrates |
|------|--------------|
| [`skills/mssql-performance-review/examples/mixed-artifacts-analysis.md`](examples/mixed-artifacts-analysis.md) | Artifact-driven review — full report with evidence chain, adversarial check, ranked fixes |
| [`skills/mssql-performance-review/examples/symptom-first-analysis.md`](examples/symptom-first-analysis.md) | Symptom-only triage — hypotheses, capture suggestions, no SQL Server contact |
| [`skills/mssql-performance-review/examples/capture-bundle-example/`](examples/capture-bundle-example/) | Sample capture bundle with README, manifest, paste-back template, and one SQL script |
| [`skills/mssql-performance-review/examples/baseline-diff-analysis.md`](examples/baseline-diff-analysis.md) | Baseline-diff after deploy — recommendation status tags, feedback.jsonl appends |

### Related skills

The orchestrator composes the 15 specialised review skills. To use a specialised skill directly (when you have a single artifact and know which one it needs), see each skill's own SKILL.md and references:

- [`/tsql-review`](../tsql-review/) — T-SQL static analysis
- [`/sqlplan-review`](../sqlplan-review/) — execution plan deep dive
- [`/sqlplan-compare`](../sqlplan-compare/) — diff two plans
- [`/sqlindex-advisor`](../sqlindex-advisor/) — ranked CREATE INDEX script
- [`/sqldeadlock-review`](../sqldeadlock-review/) — deadlock root cause + pattern match
- [`/sqlplan-batch`](../sqlplan-batch/) — folder of plans, dashboard summary
- [`/sqlstats-review`](../sqlstats-review/) — STATISTICS IO/TIME parser
- [`/sqltrace-review`](../sqltrace-review/) — Profiler/XE trace analysis
- [`/sqlwait-review`](../sqlwait-review/) — wait statistics
- [`/sqlquerystore-review`](../sqlquerystore-review/) — Query Store DMV analysis
- [`/sqlprocstats-review`](../sqlprocstats-review/) — `sys.dm_exec_procedure_stats` analysis
- [`/sqlhadr-review`](../sqlhadr-review/) — Always On AG state
- [`/sqlclusterlog-review`](../sqlclusterlog-review/) — WSFC CLUSTER.LOG
- [`/sqlerrorlog-review`](../sqlerrorlog-review/) — SQL Server ERRORLOG
- [`/sqlspn-review`](../sqlspn-review/) — SPN / Kerberos delegation

---

## Quick reference card

Print this and tape it to your monitor:

```
ENTRY MODES
  /mssql-performance-review <directory|files|inline>   — artifact-driven
  /sql-triage <symptom>                                — symptom-driven
  /mssql-performance-review --resume <bundle-dir>      — after running a capture bundle
  /mssql-performance-review --baseline <state.json> <new-artifacts> — verification

FLAGS
  --model-tier {economy|standard|maximum}    cost tier
  --no-adversarial                            skip Opus disproof attempt
  --exhaustive                                run every applicable skill
  --phases                                    fixed phases instead of DAG
  --instance <name>                           load domain memory
  --capture-instance-facts                    emit DMV survey bundle for facts.json

WHAT YOU GET
  Summary → Hypothesis Trace → Adversarial Check → Findings (C/W/I)
  → Per-Skill raw → Cross-Cutting → Conflicts → Fix Priority table
  → Verification → Missing Artifacts → Passed Checks → Skills Skipped

TRUST MODEL
  Reads files you provide. Writes ./captures/ and ./state/. Never contacts SQL Server.

COST
  Typical: USD 0.06 (economy) — 0.21 (standard) — 0.50 (maximum)
```
