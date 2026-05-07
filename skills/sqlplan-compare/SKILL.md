---
name: sqlplan-compare
description: Diff two SQL Server execution plans (baseline vs regression) to identify what changed — join strategies, memory grants, operator topology, new warnings, and missing indexes. Use when a query regressed after a deployment, statistics update, or schema change.
triggers:
  - /sqlplan-compare
  - /plan-compare
  - /plan-diff
---

# SQL Server Execution Plan Comparison Skill

## Purpose

Identify what changed between two execution plans for the same query — one known-good (baseline) and one regressed (new). Produce a side-by-side diff that explains why the query is slower and what to fix.

## Input

Accept any of:
- Two `.sqlplan` file paths: `baseline.sqlplan` and `new.sqlplan`
- Two blocks of raw `.sqlplan` XML pasted inline, labeled Baseline and New
- A description of both plans if XML is not available

## How to Run

1. Parse both plans independently
2. Extract the comparison metrics listed below for each plan
3. Produce a side-by-side diff table, then a findings section for every significant change
4. Conclude with a prioritized fix list

---

## Metrics to Compare

### Statement-Level

| Metric | Where to Find | Signal |
|--------|--------------|--------|
| StatementSubTreeCost | `StmtSimple/@StatementSubTreeCost` | > 2× increase = regression |
| DegreeOfParallelism | `QueryPlan/@DegreeOfParallelism` | DOP drop = serial plan forced |
| GrantedMemory (KB) | `MemoryGrantInfo/@GrantedMemory` | > 2× increase = cardinality inflation |
| MaxUsedMemory (KB) | `MemoryGrantInfo/@MaxUsedMemory` | Used > Granted = spill |
| CardinalityEstimationModelVersion | `QueryPlan/@CardinalityEstimationModelVersion` | Version drop = compat level change |
| CompileCPU (ms) | `StmtSimple/@CompileCPU` | > 2× increase = optimizer struggling |
| MissingIndexGroup count | `<MissingIndexes>` children | New suggestions = indexes dropped |

### Operator Topology

Compare these for each plan:

- **Join count by type** — Hash Match, Merge Join, Nested Loops (report count of each)
- **Join type changes** — Identify any operator that changed type between plans (e.g., Hash → Nested Loops is a regression signal when the table is large)
- **New operators** — Operators present in the new plan but not the baseline (e.g., Sort, Spool, Key Lookup appearing)
- **Removed operators** — Operators in baseline but not new (e.g., Seek replaced by Scan)
- **Scan vs Seek changes** — Any table that changed from Seek to Scan is critical

### Warning Changes

- New `<Warnings>` elements in the new plan not present in baseline
- New `SpillToTempDb` entries
- New `PlanAffectingConvert` entries
- New `NoJoinPredicate` flags

---

## Comparison Checks

### C1 — Seek Degraded to Scan
- **Trigger:** A table that had a Seek operator in the baseline now has a Scan in the new plan
- **Severity:** Critical
- **Report:** Table name, old operator (Seek), new operator (Scan), estimated cost ratio
- **Likely causes:** Index dropped, statistics changed causing optimizer to choose full scan, implicit conversion added

### C2 — Hash Join Degraded to Nested Loops on Large Table
- **Trigger:** A join changed from Hash Match to Nested Loops AND `actualRows` on the probe side > 10,000
- **Severity:** Critical
- **Report:** Join operator location, old type, new type, row counts
- **Likely causes:** Bad cardinality estimate making the inner side appear small; parameter sniffing

### C3 — Memory Grant Inflated > 2×
- **Trigger:** New plan `GrantedMemory` > baseline `GrantedMemory` × 2
- **Severity:** Warning
- **Report:** Baseline grant, new grant, ratio
- **Likely causes:** Row estimate inflation (stale statistics, parameter sniffing)

### C4 — Memory Grant Deflated > 2× (Spill Risk)
- **Trigger:** New plan `GrantedMemory` < baseline `GrantedMemory` / 2 AND `MaxUsedMemory` > `GrantedMemory` in new plan
- **Severity:** Warning
- **Report:** Baseline grant, new grant, used memory in new plan
- **Likely causes:** Row estimate collapse; optimizer now thinks fewer rows are involved

### C5 — Parallelism Lost
- **Trigger:** Baseline `DegreeOfParallelism` > 1 AND new plan `DegreeOfParallelism` = 1
- **Severity:** Warning
- **Report:** Old DOP, new DOP, `NonParallelPlanReason` if present
- **Likely causes:** MAXDOP hint added, scalar UDF introduced, table variable used in new code path

### C6 — New Spill to TempDb
- **Trigger:** `SpillToTempDb` present in new plan but not in baseline
- **Severity:** Critical
- **Report:** Operator that spills, spill level, estimated vs actual rows at that operator

### C7 — New Key Lookup Introduced
- **Trigger:** Key Lookup or RID Lookup operator present in new plan but not in baseline
- **Severity:** Warning
- **Report:** Table name, estimated rows, `costPercent`

### C8 — New Missing Index (High Impact)
- **Trigger:** A `MissingIndexGroup` in the new plan is not present in the baseline AND `Impact` > 50
- **Severity:** Warning
- **Report:** Missing index details, impact score, columns

### C9 — Sort Operator Added
- **Trigger:** Sort operator present in new plan but not in baseline AND `costPercent` ≥ 10%
- **Severity:** Warning
- **Report:** Sort columns, cost percent, estimated rows

### C10 — Cardinality Model Downgraded
- **Trigger:** `CardinalityEstimationModelVersion` in new plan < baseline
- **Severity:** Warning
- **Report:** Old version, new version
- **Likely causes:** Database compatibility level was lowered, or plan was compiled under a different database context

---

## Output Format

```
## Execution Plan Comparison

### Summary Table

| Metric | Baseline | New Plan | Change |
|--------|----------|----------|--------|
| Statement Cost | X | Y | +Z% |
| DOP | X | Y | ↓ or ↑ |
| Memory Grant (MB) | X | Y | +Z% |
| Join Types (Hash/NL/Merge) | X/Y/Z | A/B/C | — |
| Spills | None | 2 (Sort, Hash) | ⚠ New |
| Missing Indexes | N | M | +K |

### Regression Findings

**[R1 — C2] Finding Name**
- **Was:** [baseline operator/value]
- **Now:** [new plan operator/value]
- **Why:** [root cause — what changed and why it caused this shift]
- **Fix:** [concrete action with code if applicable]

The bracket suffix (`— C2`, `— C5`) is the check ID from the C1–C10 checks above that fired.
Findings reference each other where one is the root cause of another (e.g., "consequence of R1").
Do not use Critical/Warning severity tiers — regression findings are ranked by fix priority, not severity.

### Root Cause Summary

[One paragraph synthesising all findings into a single root cause statement.
Example: "A single change caused the entire regression: the @status parameter type changed from
VARCHAR to NVARCHAR, introducing an implicit conversion on the Status column. This made the
index non-sargable → cardinality collapsed → Hash Match replaced Nested Loops → 2 GB memory
grant → 3.2-second wait before execution begins."]

```sql
-- Recommended fix (step-by-step code block)
-- Step 1: ...
-- Step 2: ...
```

### Confirmed Stable (Unchanged)
[List key operators, DOP, CE version, compile time that are the same in both plans.
This gives confidence the comparison is valid.]
```

---

## Notes

- If plans are from different queries, note this and refuse to compare — the diff is meaningless across different query shapes.
- If the baseline is estimated-only and the new plan is actual, note the comparison limitation for runtime-dependent metrics.
- When the root cause is parameter sniffing, recommend capturing the plan at the specific parameter value that causes the regression.

## Companion Skills

- **sqlplan-review** — Run the full 99-check analysis on each plan individually before comparing. Findings from sqlplan-review provide context for why the regression occurred.
- **sqlplan-index-advisor** — If the regression introduced a new Key Lookup or expensive scan, use this skill to generate the covering index that would resolve it.
- **sqltrace-review** — If a workload trace showed the query regressing in production, cross-reference trace duration variance (X14) with the plan diff.
- **tsql-review** — If the regression was triggered by a schema or code change, review the T-SQL source for the anti-pattern that caused the plan change.
- **query-store-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.
