# Evidence Schema

Every consolidated finding in the orchestrator's report is backed by a structured evidence record. The on-disk form is JSON (in `state/<run-id>/evidence.json`). The human-readable form is rendered in the Findings section of the report. This document defines both.

## Goals

- **Reproducibility.** A recipient of the report can re-derive every finding by inspecting the cited source artifact at the cited location.
- **Auditability.** Findings are traceable to the specialised check that fired (skill name + check ID).
- **Downstream tooling.** Change tickets, post-mortems, and dashboards can ingest `evidence.json` without parsing the human report.

## JSON schema (per finding)

```json
{
  "finding_id": "C1",
  "label": "Parameter sniffing on dbo.usp_GetOrders",
  "severity": "Critical",
  "confidence": "HIGH",
  "primary_skill": "sqlplan-review",
  "evidence": [
    {
      "skill": "sqlplan-review",
      "check_id": "S9",
      "source_artifact": "order_proc.sqlplan",
      "source_location": "Stmt 1, NodeId 12",
      "observed_value": "actual rows 1,842,734 vs estimated 50",
      "observed_metric": "row_estimate_ratio",
      "observed_numeric": 36854,
      "threshold": ">= 1,000",
      "threshold_severity": "Critical"
    },
    {
      "skill": "sqlstats-review",
      "check_id": "I1",
      "source_artifact": "stats-iotime.txt",
      "source_location": "Statement 1, Table 'Orders'",
      "observed_value": "1,842,734 logical reads",
      "observed_metric": "logical_reads",
      "observed_numeric": 1842734,
      "threshold": "> 1,000,000",
      "threshold_severity": "Warning"
    },
    {
      "skill": "query-store-review",
      "check_id": "Q7",
      "source_artifact": "query-store-output.txt",
      "source_location": "query_hash 0xA1B2C3D4",
      "observed_value": "3 plans in 24h window",
      "observed_metric": "distinct_plans",
      "observed_numeric": 3,
      "threshold": ">= 2 plans = plan instability",
      "threshold_severity": "Warning"
    }
  ],
  "adversarial": {
    "ran": true,
    "template_class": "parameter_sniffing",
    "result": "no_contradiction",
    "notes": "PAGEIOLATCH_SH was 14% of wait time (under 25% I/O-bound threshold); CPU dominant signal confirmed."
  },
  "impact": "Query runtime varies from 200ms (fast plan) to 8s (slow plan) depending on first compilation parameters. Affects p99 latency on the orders API.",
  "related_findings": ["W3", "I2"]
}
```

### Field rules

| Field | Required | Validation |
|-------|----------|-----------|
| `finding_id` | Yes | `C1`/`W1`/`I1` sequence within severity |
| `label` | Yes | One sentence, no trailing period |
| `severity` | Yes | One of `Critical`, `Warning`, `Info` |
| `confidence` | Yes | One of `HIGH`, `MEDIUM`, `LOW` |
| `primary_skill` | Yes | Name of the specialised skill that contributed the most signal |
| `evidence[]` | Yes | At least 1 entry for Info, at least 2 entries for Warning, at least 3 entries for Critical (or explicit explanation why fewer) |
| `evidence[].skill` | Yes | Skill that fired the check |
| `evidence[].check_id` | Yes | The specialised skill's check ID (S9, I1, V1, etc.) |
| `evidence[].source_artifact` | Yes | File path or paste-block label |
| `evidence[].source_location` | Yes | Statement number, NodeId, line range, wait_type, etc. — enough to re-locate |
| `evidence[].observed_value` | Yes | Human-readable value |
| `evidence[].observed_numeric` | Yes (when meaningful) | Machine-readable scalar — enables downstream aggregation |
| `evidence[].threshold` | Yes | The threshold that classified this as a finding |
| `adversarial.ran` | Yes for Critical/Warning | Adversarial pass executed? |
| `adversarial.result` | Yes if ran | `no_contradiction` / `weak_contradiction` / `strong_contradiction_alternative_escalated` |
| `impact` | Yes for Critical/Warning | One- or two-sentence runtime effect |
| `related_findings` | No | IDs of other findings this corroborates or contradicts |

## Human-readable rendering

The same record renders in the report as:

```
[C1] Parameter sniffing on dbo.usp_GetOrders
- Confidence: HIGH (primary skill: sqlplan-review)
- Evidence:
  - sqlplan-review S9 fired
    - Source: order_proc.sqlplan (Stmt 1, NodeId 12)
    - Observed: actual rows 1,842,734 vs estimated 50 (36,854x ratio)
    - Threshold: >= 1,000x = Critical
  - sqlstats-review I1 corroborates
    - Source: stats-iotime.txt (Statement 1, Table 'Orders')
    - Observed: 1,842,734 logical reads
    - Threshold: > 1,000,000 = Warning
  - query-store-review Q7 corroborates
    - Source: query-store-output.txt (query_hash 0xA1B2C3D4)
    - Observed: 3 plans in 24h window
    - Threshold: >= 2 plans = plan instability
- Adversarial pass: ran, no contradiction (PAGEIOLATCH_SH 14% < 25% I/O-bound threshold)
- Impact: runtime varies 200ms to 8s depending on first-compile parameters; affects p99 on orders API
- Related: W3, I2
```

The conventions are:
- Bullet hierarchy preserved
- `[C1]` prefix matches the finding_id
- Source format is `artifact (location)`
- Observed value reads as a natural-language sentence
- Threshold reads as `relation value = severity`

## Reproducibility guarantee

A recipient can re-derive any finding by:

1. Opening the cited source artifact
2. Locating the cited position (statement, NodeId, wait type, log line)
3. Reading the cited metric
4. Comparing it to the cited threshold

If the value at the location no longer matches (e.g., artifacts were edited), the report cannot be trusted — re-run the orchestrator on the current artifact set.

The `evidence.json` is the canonical record. The human-readable rendering is for humans; the JSON is for tools.

## Validation rules

Before emitting the report, the orchestrator validates every record:

- Critical findings have at least 3 evidence entries from at least 2 distinct skills (or carry an explanation field stating why fewer is acceptable)
- Warning findings have at least 2 evidence entries
- Every recommendation in the Consolidated Fix Priority section links to at least one finding_id
- No finding cites a skill that did not actually run in this dispatch
- No finding cites a check_id that does not exist in the cited skill

Validation failures block the report — the orchestrator either downgrades the finding or asks the user for additional captures.

## What this is NOT

- Not a replacement for the specialised skill's own check-explanations.md (those still explain the underlying check)
- Not an attempt to formalise the specialised checks (each skill defines its own thresholds)
- Not a billing record (cost tracking is separate, see model-routing.md in tier 2)
