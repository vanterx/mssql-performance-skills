# SQL Server Performance Review — Unified Report (Baseline-Diff)

**Run ID:** 20260518-1015-post-fix
**Baseline:** ./state/20260517-0942/state.json (`mixed-artifacts-analysis.md`)
**Time since baseline:** 24 hours 33 minutes

This example shows the orchestrator's output when the user returns 24 hours after deploying fixes from the prior review and re-captures the same artifact set with `--baseline` to confirm whether the fixes worked.

---

## Summary

- Files analyzed: 4 (`slow-proc.sql`, `slow-proc.sqlplan`, `stats-iotime.txt`, `wait-stats.txt`)
- Skills applied: 5 (tsql-review, sqlstats-review, sqlwait-review, sqlplan-review, sqlplan-index-advisor)
- Baseline recommendations evaluated: 4
- Verification metric: **3 verified-effective / 1 partial / 0 no-change / 0 regressed-elsewhere / 0 cannot-evaluate**
- New findings: 1 Info (one new minor finding emerged after the fix)
- Cost: ~USD 0.18 (Haiku 22k tokens, Sonnet 28k tokens, Opus 6k tokens)

The primary recommendation (covering index) is **verified-effective**. The secondary parameter-sniffing fix is **partial** — duration variance dropped from ~80% to ~35%, below the 50% threshold but not yet at the 30% target. The SELECT * cleanup is also verified-effective. The recommendation index-tuning loop is winding down.

## Recommendation Status (vs baseline 20260517-0942)

| Rec # | Original recommendation | Tag | Evidence delta |
|-------|------------------------|-----|----------------|
| 1 | Add IX_Orders_CustomerId_OrderDate covering index | **verified-effective** | sqlstats logical reads on Orders: 1,842,734 → 392 (99.98% reduction); sqlplan operator: Clustered Index Scan → Index Seek; statement cost: 124.3 → 3.8; the index is in use (sys.dm_db_index_usage_stats shows 8,221 seeks since deploy). |
| 2 | Add OPTION (OPTIMIZE FOR (@CustomerId UNKNOWN)) to usp_GetOrdersByCustomer | **partial** | Duration variance: 80% → 35% — improved substantially but still above the 30% target. The seek itself is fast for all cardinalities; the residual variance comes from result-set size (8 rows vs 48,221 rows). Recommend: leave the OPTIMIZE FOR hint in place; the residual variance is intrinsic to the query shape, not a sniffing problem. Tag may upgrade to verified-effective after a week of stable workload. |
| 3 | Replace SELECT * with explicit columns | **verified-effective** | Plan shows the same operator topology with smaller EstimateRowSize (down from 384 bytes to 92 bytes); the 4-column explicit list is in the new procedure body (verified via tsql-review on the post-fix source). |
| 4 | (Optional) Add filtered index on DELETED_FLAG = 0 | **not-deployed** | The user opted not to deploy this (recommendation was Info-level only). Skipped from verification. |

### Verification details per recommendation

#### Rec 1 — IX_Orders_CustomerId_OrderDate (verified-effective)

Evidence:
- sqlplan-review N5 PASS — no Clustered Index Scan on Orders for this predicate path; the new index is the chosen access path (Index Seek with `[CustomerId] = @CustomerId AND [OrderDate] >= @StartDate`).
- sqlstats-review I1 PASS — logical reads dropped from 1,842,734 to 392 (well below the 1M threshold).
- sqlwait-review V1 PAGEIOLATCH_SH dropped from 14.7% to 8.2% of total wait time (still below 25% threshold, even further below).
- The index itself: 8,221 seeks recorded in `sys.dm_db_index_usage_stats` since 2026-05-17 14:30 (deploy time per release notes).

Cost vs benefit:
- Storage added: 1.18 GB (estimated 1.2 GB; close to projection).
- Write overhead: 3% projected on Orders inserts. Trend data shows insert latency unchanged within noise.

No side-effect regressions detected. Recommendation is **verified-effective**.

#### Rec 2 — OPTIMIZE FOR UNKNOWN (partial)

Evidence:
- sqlplan-review S9 PASS for the worst-case parameter — actual rows now within 10x of estimate (was 36,854x).
- sqlstats-review across 5 invocations spanning high- and low-cardinality customers:

| Invocation | @CustomerId | Rows returned | Duration ms |
|------------|------------|---------------|-------------|
| 1 | CUST-00001 (high cardinality) | 48,221 | 142 |
| 2 | CUST-99999 (single row) | 1 | 9 |
| 3 | CUST-00005 (medium cardinality) | 8,212 | 38 |
| 4 | CUST-00002 (high cardinality) | 41,884 | 124 |
| 5 | CUST-99998 (single row) | 1 | 11 |

Duration variance: (142 - 9) / mean = 133 / 65 = **~35% relative spread**.

Analysis: the seek itself is fast; the variance comes from result-set size delivery, not from operator choice. The orchestrator notes this is intrinsic to the query and not a sniffing artifact. Recommendation: keep the hint in place; the residual variance is acceptable.

Upgrade path: monitor for a week. If variance stays at 30-40% over a sustained workload, upgrade tag to verified-effective. The 30% target was a conservative threshold; the actual user impact (p99 latency on orders API) is the meaningful metric.

#### Rec 3 — Explicit column list (verified-effective)

Evidence:
- tsql-review on the post-fix source (provided in this run's input): T7 PASS, no SELECT * in the procedure.
- sqlplan-review of the new plan: EstimateRowSize reduced from 384 bytes to 92 bytes (the four projected columns: OrderId, OrderDate, Status, TotalAmount).
- Network payload reduction: at 8,221 invocations/day, ~24 GB/day less data transferred to the application tier.

No regressions detected. Recommendation is **verified-effective**.

## New Findings (since baseline)

### Info

[I1] Slight increase in sqlplan-review S2 over-allocation warnings on the same procedure (no action)

Evidence:
- sqlplan-review S2 fired
  - Source: post-fix.sqlplan
  - Observed: GrantedMemory = 2,048 KB; MaxUsedMemory = 1,024 KB; over-allocation 50%
  - Threshold: > 25% = Warning, but absolute granted memory is small

Impact: The optimizer over-grants memory for the Sort operator. The waste is ~1 MB per execution. At 8,221 invocations/day, ~8 GB/day of wasted grant — but the buffer pool has 384 GB, and the grants are short-lived. Not actionable at current scale.

Suggested action: no action. Note for future review if execution count grows substantially.

## Hypothesis Trace

| Rank | Hypothesis | Initial confidence | Probes run | Final confidence | Status |
|------|-----------|-------------------|------------|------------------|--------|
| 1 | Parameter sniffing residue | LOW (downgraded from prior MEDIUM) | sqlstats-review, sqlplan-review, sqlwait-review | LOW | Refuted — the residual variance is from result-set size, not sniffing |

Single-hypothesis run; baseline-diff is the primary mode.

## Adversarial Check

- Primary hypothesis: parameter sniffing residue
- Disproof attempt: "If sniffing was still the cause, the plan operator would still differ across invocations; sqlplan-review on each of the 5 invocations should show same plan_hash. Confirmed all 5 use plan_hash 0x12345678. Variance is in result delivery, not plan choice."
- Result: `strong_contradiction_alternative_escalated` — alternative identified: result-set size variance, which is not a problem.
- Alternative: result delivery time scales with row count (not pathological).

## Findings (Consolidated, Cross-Skill)

### Critical
[None]

### Warning
[None]

### Info
[I1] Plan memory grant over-allocation on usp_GetOrdersByCustomer — see "New Findings" above.

## Recommendation Conflicts

None detected.

## Consolidated Fix Priority

[Empty — no new critical or warning findings warranting a deploy. The previous recommendation set has converged.]

## Skills Skipped

| Skill | Reason |
|-------|--------|
| sqlplan-compare | Compared the baseline plan to current implicitly via baseline-diff |
| sqlplan-deadlock | No deadlock XML |
| sqlplan-batch | Single-plan input |
| query-store-review | Not in this run's input (would strengthen the partial tag on Rec 2 — recommend adding Query Store output next time) |
| procstats-review | Not in this run's input |
| sqltrace-review | Not in this run's input |
| hadr-health-review, clusterlog-review, errorlog-review, spn-review | No AG/cluster/auth signals in input |

## Missing Artifacts

- [ ] Query Store output for query_hash 0xA1B2C3D4 — would strengthen the Rec 2 partial tag with cross-period stability data (capture: `skills/query-store-review/scripts/01_capture_queries.sql`).

## Passed Checks

Same scope as baseline (5 skills run); 47 of 50 checks evaluated as PASS this run (3 fired only as Info on Rec 1's residual S2 grant pattern).

## Next Steps

1. Leave Rec 2 (`OPTIMIZE FOR UNKNOWN` hint) in place. Monitor variance over the next week.
2. Add Query Store capture to the next review for cross-period stability data on Rec 2.
3. No urgent action required. The performance incident is resolved.

## Feedback Recorded

Appended to `skills/mssql-performance-review/evals/feedback.jsonl`:

```jsonl
{"run_id":"20260518-1015","baseline_run_id":"20260517-0942","rec_id":1,"tag":"verified-effective","hypothesis_class":"missing_index","evidence_delta":{"logical_reads":[1842734,392],"operator":["Clustered Index Scan","Index Seek"],"statement_cost":[124.3,3.8]}}
{"run_id":"20260518-1015","baseline_run_id":"20260517-0942","rec_id":2,"tag":"partial","hypothesis_class":"parameter_sniffing","evidence_delta":{"duration_variance_pct":[80,35]},"notes":"Residual variance from result-set size, not sniffing"}
{"run_id":"20260518-1015","baseline_run_id":"20260517-0942","rec_id":3,"tag":"verified-effective","hypothesis_class":"select_star","evidence_delta":{"estimate_row_size_bytes":[384,92]}}
```

These outcomes inform future hypothesis-class ranking. For example: in this codebase, missing_index recommendations are now 3/3 verified-effective at the covering-index pattern. parameter_sniffing recommendations are 0/1 fully verified-effective (one partial). The orchestrator will weight these patterns accordingly in future symptom-driven hypothesis generation.

---
*Analyzed by: Claude Sonnet 4.6 · 2026-05-18 10:15 NZST*
