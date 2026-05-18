# Verification Checklist (V7')

Every recommendation in tier 1 already carries a `verification` field describing which capture to re-run and the expected metric change. Tier 3 promotes this into a dedicated **Verification — After Deploying Fixes** section in the report, plus the baseline-diff feedback loop that tags prior recommendations after the user returns with new captures.

## Why this exists

A fix that isn't verified isn't a fix — it's a hypothesis. Without verification, the orchestrator's recommendations are educated guesses that may have worked or may have shifted the bottleneck to somewhere else. The verification section makes the verification step a first-class part of the workflow.

Tier 3 keeps the trust model intact: the orchestrator never re-captures itself. It tells the user what to re-capture, expected results, and how to come back with the data. The user does the deploy and the re-capture; the orchestrator does the comparison.

## Output structure

A Verification section appears in every report:

```markdown
## Verification — After Deploying Fixes

After the recommended fixes are live, re-run these captures to confirm. The orchestrator
will tag each prior recommendation as verified-effective / partial / no-change /
regressed-elsewhere when you return with `--baseline ./state/<this-run-id>/state.json`.

### Suggested timing

- **Plan changes (indexes, hints):** 24 hours — allows plan cache to repopulate.
- **Statistics updates:** 1 hour — next compile picks up new stats.
- **Configuration changes (MAXDOP, RCSI):** 24 hours — allows workload mix to exercise the new setting.
- **Trend-based fixes (procstats, query store regressions):** 7 days — needs a full workload week.
- **AG / failover fixes:** as soon as the next workload cycle through the AG primary.

### Re-captures

| Rec # | Source recommendation | Re-capture script | Expected metric movement |
|-------|----------------------|-------------------|--------------------------|
| 1 | Add index IX_Orders_CustomerId_OrderDate | `skills/sqlplan-review/scripts/01_capture_from_cache.sql` (filtered to usp_GetOrdersByCustomer) | Clustered Index Scan → Index Seek; statement cost < 5 (was 124.3); logical reads on Orders < 1,000 (was 1,842,734) |
| 2 | OPTION (OPTIMIZE FOR UNKNOWN) on procedure | sqlstats-review on 5 invocations spanning parameter values | Duration variance < 30% (was ~80%) |
| 3 | Replace SELECT * with explicit columns | Next sqlplan-review of same procedure | Smaller EstimateRowSize; same operator topology |

### Resume command

When ready to verify, run:

    /mssql-performance-review --baseline ./state/20260517-0942/state.json ./captures/post-fix-<timestamp>/

If you used the capture-bundle generator for the original review, re-run those same scripts
into a new bundle directory and use `--resume --baseline ./state/<original>/state.json`.
```

## Suggested timing rules

Timing depends on what the recommendation changes:

| Change type | Suggested wait | Reason |
|-------------|----------------|--------|
| Index creation | 24h | Plan cache must repopulate; workload mix exercises the new index |
| Index drop | 1h | Affected plans recompile on first call |
| `UPDATE STATISTICS` | 1h | Next compile picks up new stats |
| `OPTION (RECOMPILE)` / `OPTION (OPTIMIZE FOR UNKNOWN)` added | 1h | First compile after deploy |
| MAXDOP, CTfP change | 24h | New setting applies to new compiles; old plans persist until evicted |
| Enable RCSI/SI on database | 1h to 1d | Reads start using row-versioning immediately; full workload exercises the new behaviour over a day |
| Add/remove trace flag | After next restart | Some apply at startup; differential timing if dynamic |
| Force plan in Query Store | 1h | Next execution uses forced plan |
| Unforce plan | 1h | Optimizer regains choice; new plan compiles on next call |
| Statistics histogram refresh on partitioned table | 4h | Per-partition stats refresh at workload pace |
| AG failover-related fix (lease, health check) | After next stress / next planned failover | Symptoms may not recur until the trigger condition recurs |

If the recommendation has the `verification` field already populated from the risk-rubric, prefer that field's wording. The timing table is the fallback when the field is generic.

## Baseline-diff feedback loop

When the user returns with `--baseline ./state/<prior>/state.json` and new artifacts:

1. **Load prior state.** Read `state.json` (the prior evidence chain, hypotheses, recommendations).
2. **Run normal dispatch.** The new artifacts go through tier 1/2 flow producing a fresh report.
3. **Match prior recommendations to current findings.** For each prior recommendation (referenced by `finding_id`), look for the corresponding finding in the new report's evidence chain.
4. **Tag the prior recommendation.**

### Tagging rules

| Tag | Condition |
|-----|-----------|
| `verified-effective` | The prior finding's evidence is gone (metric below threshold) AND no new findings of the same hypothesis class appeared elsewhere |
| `partial` | The prior finding's evidence is reduced but still above threshold; OR the metric improved but a related finding now appears (sub-optimal but better) |
| `no-change` | The prior finding's evidence is unchanged (within ±10% of prior values) |
| `regressed-elsewhere` | The prior finding is gone but new related findings appeared elsewhere — the fix shifted the bottleneck (e.g., index added → CPU OK → now PAGEIOLATCH dominant) |
| `cannot-evaluate` | The required artifact for verification is absent from the new input |

### Output section

```markdown
## Recommendation Status (vs baseline 20260517-0942)

Verification of recommendations from the prior review.

| Prior rec | Tag | Evidence delta |
|-----------|-----|----------------|
| 1 | verified-effective | sqlstats logical reads on Orders: 1,842,734 → 412 (99.98% reduction); sqlplan operator: Clustered Index Scan → Index Seek; statement cost: 124.3 → 4.1 |
| 2 | partial | Duration variance: 80% → 35% (still above 30% target). Likely needs OPTIMIZE FOR specific parameter for largest-customer outlier, or a plan guide. |
| 3 | no-change | Plan operator topology unchanged; EstimateRowSize unchanged. The deploy may not have applied — check release notes. |
| 4 | regressed-elsewhere | CPU dropped (verified-effective on that surface) but PAGEIOLATCH_SH now dominant — the index made queries fast enough to expose an underlying I/O subsystem limit. Consider RAM increase or storage upgrade. |
| 5 | cannot-evaluate | New input did not include wait stats; cannot confirm CXPACKET reduction. Re-capture wait stats to evaluate. |

### Summary

- 1 of 5 recommendations verified-effective
- 1 partial (needs refinement)
- 1 no-change (deploy not confirmed)
- 1 regressed-elsewhere (next steps: address I/O)
- 1 cannot-evaluate (re-capture needed)
```

### Feedback file

Each baseline-diff run appends to `skills/mssql-performance-review/evals/feedback.jsonl`:

```json
{"run_id": "20260518-1000", "baseline_run_id": "20260517-0942", "rec_id": 1, "tag": "verified-effective", "hypothesis_class": "missing_index", "evidence_delta": {"sqlstats_logical_reads": [1842734, 412], "sqlplan_operator": ["Clustered Index Scan", "Index Seek"], "statement_cost": [124.3, 4.1]}}
{"run_id": "20260518-1000", "baseline_run_id": "20260517-0942", "rec_id": 2, "tag": "partial", "hypothesis_class": "parameter_sniffing", "evidence_delta": {"duration_variance_pct": [80, 35]}, "notes": "Below 50% but above 30% target"}
{"run_id": "20260518-1000", "baseline_run_id": "20260517-0942", "rec_id": 3, "tag": "no-change", "hypothesis_class": "select_star", "evidence_delta": {}, "notes": "Operator topology unchanged"}
{"run_id": "20260518-1000", "baseline_run_id": "20260517-0942", "rec_id": 4, "tag": "regressed-elsewhere", "hypothesis_class": "missing_index", "evidence_delta": {"sqlwait_pageiolatch_share": [0.147, 0.524]}, "notes": "Bottleneck shifted from CPU to I/O"}
{"run_id": "20260518-1000", "baseline_run_id": "20260517-0942", "rec_id": 5, "tag": "cannot-evaluate", "hypothesis_class": "parallelism", "evidence_delta": null, "notes": "Wait stats not in new input"}
```

`evals/feedback.jsonl` is gitignored (it's user-specific outcome data). Append-only; never rewrites prior entries.

## Use of feedback over time

Future runs of the orchestrator can read `feedback.jsonl` to refine hypothesis-class-to-recommendation patterns:

- "For `parameter_sniffing` hypotheses in this codebase, recommendations using `OPTION (OPTIMIZE FOR UNKNOWN)` are tagged `verified-effective` 60% of the time, `partial` 30% of the time, `no-change` 10%."
- "For `missing_index` hypotheses, the covering index pattern is `verified-effective` 85% of the time."
- "For `server_wide_io` hypotheses, single-index fixes are `regressed-elsewhere` 40% of the time — the orchestrator should pair them with capacity recommendations."

This is the self-improvement loop. The orchestrator becomes more accurate over time by learning from real-world outcomes.

The feedback is **user-local** by default — the orchestrator reads only the local `feedback.jsonl`. Teams wanting shared learning can point the orchestrator at a team-managed file via `--feedback-file <path>`. Sharing happens through the file system, not over the network.

## When the user does not return

If 30 days pass without a `--baseline` invocation referencing a prior `state.json`, the orchestrator does nothing special — that state simply remains unverified.

The orchestrator does not nag, schedule, or alert. The trust model is preserved (no async, no automation). The user's deployment cadence is their own concern.

## Edge cases

### Recommendation was rolled back

Tag: `verified-effective` (the rollback IS effective — the original recommendation's evidence is gone). The orchestrator notes "appears the recommendation was rolled back per facts.json or `notes` field; if intentional, the bottleneck likely needs a different fix" and surfaces a new finding.

### Multiple prior recommendations targeted the same finding

The orchestrator tags each independently. If recommendations 1 and 2 both targeted parameter sniffing, and rec 1 alone resolved it, rec 1 = `verified-effective`, rec 2 = `cannot-evaluate` (or `no-change` if explicitly tested).

### New finding appears that was not in the prior review

The new finding is reported normally in the current report's Findings section. It's not part of the recommendation-status diff (no prior recommendation targeted it). The Summary block notes the count of new findings.

### Artifact set changed between baseline and current

If the user submitted different artifact types this time (e.g., previously had Query Store, now doesn't), the `cannot-evaluate` tag is used for recommendations that depended on the missing artifact type. The Summary block notes the artifact set diff.

## Verification quality metric

For each report, the orchestrator computes a simple verification quality metric:

- `verifiable_count` — recommendations where verification is possible from the artifact set
- `verified_count` — recommendations tagged verified-effective
- `partial_count` — recommendations tagged partial
- `regression_count` — recommendations tagged regressed-elsewhere

These appear in the Summary:

```
Verification metric: 1 verified / 1 partial / 1 no-change / 1 regressed-elsewhere / 1 cannot-evaluate
```

Used internally to drive feedback file analytics; surfaced to the user as a heads-up about how the prior review's recommendations actually performed.
