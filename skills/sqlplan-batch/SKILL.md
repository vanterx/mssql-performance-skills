---
name: sqlplan-batch
description: Batch-analyze a folder of SQL Server .sqlplan files and produce a summary dashboard of the top issues, most common check violations, and deduplicated missing indexes across all plans. Use after a workload capture to identify systemic problems.
triggers:
  - /sqlplan-batch
  - /plan-batch
  - /batch-review
---

# SQL Server Execution Plan Batch Analysis Skill

## Purpose

Analyze multiple `.sqlplan` files in bulk — applying the full 87-check ruleset (S1–S27, N1–N60) from `sqlplan-review` to each plan — and produce a single aggregated dashboard that identifies the most expensive queries, most common violations, and consolidated missing index recommendations.

## Input

Accept any of:
- A directory path containing `.sqlplan` files: `/path/to/plans/`
- A list of `.sqlplan` file paths
- A description of the available plans if files cannot be provided

## How to Run

1. Enumerate all `.sqlplan` files in the input
2. Apply the full check ruleset to each plan (same logic as `sqlplan-review`)
3. Aggregate findings into the summary structures below
4. Generate a consolidated missing index script via the same merge rules as `sqlplan-index-advisor`
5. Write output to `batch-analysis.md` in the same directory

---

## Per-Plan Data to Collect

For each plan, collect:

| Field | Source |
|-------|--------|
| File name | file system |
| Query text (first 200 chars) | `StmtSimple/@StatementText` |
| Statement cost | `StmtSimple/@StatementSubTreeCost` |
| DOP | `QueryPlan/@DegreeOfParallelism` |
| Memory grant (MB) | `MemoryGrantInfo/@GrantedMemory` ÷ 1024 |
| Critical issue count | checks fired at Critical severity |
| Warning count | checks fired at Warning severity |
| Spill present | `SpillToTempDb/@SpillLevel` > 0 |
| Missing index count | `<MissingIndexGroup>` children count |
| Missing index max impact | max `@Impact` across all MissingIndexGroups |
| Check IDs fired | list of S/N codes |

---

## Aggregation Structures

### 1. Top 10 Most Expensive Plans

Rank by `StatementSubTreeCost` descending. Report:

| Rank | File | Cost | DOP | Memory (MB) | Criticals | Warnings |
|------|------|------|-----|-------------|-----------|---------|

### 2. Top 10 Plans by Critical Issue Count

Rank by `Critical issue count` descending, break ties by cost.

| Rank | File | Criticals | Warnings | Primary Issue |
|------|------|-----------|---------|--------------|

### 3. Check Violation Frequency

Count how many plans triggered each check ID. Report top 15 most common violations:

| Check | Name | Plans Affected | % of Total |
|-------|------|---------------|-----------|

Example output:
```
N21 (Bad Row Estimate)          — 31 / 50 plans (62%)
S1  (Serial Plan)               — 28 / 50 plans (56%)
N4  (Expensive Scan)            — 25 / 50 plans (50%)
```

### 4. Spill Summary

List all plans with confirmed spills:

| File | Operator | Spill Level | Memory Grant (MB) | Memory Used (MB) |
|------|----------|------------|-------------------|-----------------|

### 5. Plans With Memory Grant > 1 GB

| File | Memory Grant (MB) | Grant Used (MB) | Ratio |
|------|------------------|----------------|-------|

### 6. Consolidated Missing Index Report

Apply the same merge rules as `sqlplan-index-advisor`:
- Group by table
- Merge overlapping suggestions
- Rank by Impact × occurrence count
- Generate `CREATE INDEX` statements for top 10 (or all, if ≤ 20 total)

---

## Output Format

Write `batch-analysis.md` with the following structure:

```markdown
# Batch Execution Plan Analysis
**Plans analyzed:** N  
**Generated:** [timestamp]  
**Checks applied:** 80 (S1–S27, N1–N60)

---

## Executive Summary

- Total Critical issues: X across Y plans
- Total Warnings: A across B plans
- Plans with confirmed spills: C
- Plans with memory grant > 1 GB: D
- Unique tables with missing index suggestions: E

**Systemic issues (> 30% of plans):**
- [Check ID]: [name] — N plans (X%)
- ...

---

## Top 10 Most Expensive Plans

| Rank | File | Cost | DOP | Memory (MB) | Criticals | Warnings |
|------|------|------|-----|-------------|-----------|---------|
| 1 | ... | | | | | |

---

## Top 10 Plans by Critical Issues

[table]

---

## Check Violation Frequency (Top 15)

[table]

---

## Spill Report

[table or "No spills detected across all plans."]

---

## Consolidated Missing Index Script

### Summary
- Raw suggestions across all plans: N
- After merging: M
- Tables affected: K

### Recommended Indexes

[CREATE INDEX statements in ranked order]

---

## Per-Plan Summary

| File | Cost | DOP | Memory (MB) | Criticals | Warnings | Spill | Check IDs |
|------|------|-----|-------------|-----------|---------|-------|-----------|
| ... | | | | | | | |
```

---

## Notes

- Apply the checks from `sqlplan-review` (the parent skill) — do not re-define them here. This skill is an aggregation layer, not a separate ruleset.
- If a plan file is malformed or cannot be parsed, log it in a "Skipped Plans" section and continue.
- For very large directories (> 100 plans), report only the top findings to keep the output actionable. Note the total plan count and that full per-plan data is in the Per-Plan Summary table.
- The `batch-analysis.md` output file should be placed in the same directory as the input plans (or a specified output path) so it stays with the workload capture.
- After generating the batch report, offer to run `/sqlplan-index-advisor` on the consolidated missing indexes for a deployment-ready script, or `/sqlplan-review` on any specific high-cost plan for detailed analysis.

## Companion Skills

- **sqlplan-review** — Deep-dive analysis on any individual plan from the batch. Apply the full 87-check ruleset to the highest-cost or most-critical plan.
- **sqlplan-index-advisor** — Generate a deployment-ready `CREATE INDEX` script from the consolidated missing index recommendations in the batch report.
- **sqlplan-compare** — Diff the worst-performing plan against a known-good baseline to explain why a specific query regressed.
- **sqlplan-deadlock** — If deadlock graphs were captured alongside the `.sqlplan` files, analyze them with this companion skill.
- **sqltrace-review** — If a Profiler or Extended Events trace was captured from the same workload, cross-reference trace findings with batch plan findings.
