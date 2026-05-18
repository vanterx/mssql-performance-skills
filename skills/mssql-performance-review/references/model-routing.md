# Multi-Model Cost Routing (V5)

The orchestrator dispatches each phase of the review to a different model tier based on the reasoning required. The default routing minimises cost without sacrificing quality on high-stakes phases.

## Default routing (`--model-tier standard`)

| Phase | Model | Why this model |
|-------|-------|----------------|
| File classification | Haiku 4.5 | Pattern match against the artifact-signal table. No multi-step reasoning. |
| Hypothesis generation | Haiku 4.5 | Map artifacts to known hypothesis classes (catalogue in check-explanations.md). |
| Triage subagents (each calls a specialised skill) | Haiku 4.5 | The specialised skill loader does the deep work. The orchestrator subagent just dispatches and formats. |
| Deep-dive sqlplan-review per plan | Sonnet 4.6 | Operator-level XML reasoning, cardinality math, parameter sniffing detection. Quality-sensitive. |
| Cross-skill synthesis + conflict detection | Sonnet 4.6 | Build the evidence chain, detect cross-skill conflicts, derive the consolidated fix priority. |
| Adversarial root-cause check | Opus 4.7 | Counterfactual reasoning. Opus is best at "what would refute this hypothesis?" — the highest-leverage phase to protect against confirmation bias. |
| Cost summary, recommendation rendering | Haiku 4.5 | Arithmetic and templating. |
| Follow-up Q&A | Haiku 4.5 | In-context lookup against the evidence chain — no new tool calls. |

## Tier overrides

| Flag | Effect |
|------|--------|
| `--model-tier economy` | All Haiku, including deep dive. Cheapest. Quality drops on complex multi-statement plans. |
| `--model-tier standard` | Default routing (the table above). Best cost/quality balance. |
| `--model-tier maximum` | Sonnet for triage; Opus for all reasoning phases (synthesis + adversarial + deep dive). Highest quality. |
| `--no-adversarial` | Skip the Opus adversarial pass. Saves ~6,000 Opus tokens at the cost of confirmation-bias resistance. |

## Cost profile

Typical mixed-artifact review (one `.sql` + one `.sqlplan` + STATISTICS output + wait-stats snapshot):

| Phase | Tokens (in/out) | Model | USD (approx) |
|-------|-----------------|-------|--------------|
| Triage | 2,500 | Haiku 4.5 | 0.002 |
| Parallel probes (4 sub-skill subagents) | 20,000 | Haiku 4.5 | 0.016 |
| Deep-dive sqlplan-review | 15,000 | Sonnet 4.6 | 0.045 |
| sqlplan-index-advisor | 8,000 | Sonnet 4.6 | 0.024 |
| Synthesis | 8,000 | Sonnet 4.6 | 0.024 |
| Adversarial | 6,000 | Opus 4.7 | 0.090 |
| Cost summary + rendering | 1,500 | Haiku 4.5 | 0.001 |
| Follow-up Q&A buffer | 5,000 | Haiku 4.5 | 0.004 |
| **Total** | **~66,000** | mixed | **~USD 0.21** |

Comparable all-Sonnet run: ~USD 0.20 in + ~USD 0.10 out = USD 0.30+. Standard tier saving is ~30%; economy tier (Haiku-only) saves ~70% but with quality risk on deep dives.

## When to choose each tier

| Situation | Recommended tier |
|-----------|------------------|
| Routine review of well-understood workload | economy (Haiku-only) |
| Production incident review with confidence-critical recommendations | standard or maximum |
| Compliance / audit review where the recommendation set will drive a change ticket | maximum + `--exhaustive` |
| Cost-sensitive scheduled review (daily batch across many servers) | economy |
| User reports "previous review missed the obvious problem" | maximum (adversarial already runs Opus on standard; this also escalates synthesis and deep dive to Opus) |

## How routing is enforced in subagent dispatch

When the orchestrator dispatches a sub-skill via the Agent tool, it explicitly sets the `model` parameter on the Agent call:

| Sub-skill | Default model | Override allowed |
|-----------|--------------|------------------|
| tsql-review | Haiku | yes |
| sqlwait-review | Haiku | yes |
| sqlstats-review | Haiku | yes |
| sqltrace-review | Haiku | yes |
| query-store-review | Haiku | yes |
| procstats-review | Haiku | yes |
| sqlplan-review | Sonnet | yes |
| sqlplan-batch | Sonnet | yes |
| sqlplan-compare | Sonnet | yes |
| sqlplan-index-advisor | Sonnet | yes |
| sqlplan-deadlock | Sonnet | yes |
| hadr-health-review | Haiku | yes |
| clusterlog-review | Sonnet | yes |
| errorlog-review | Haiku | yes |
| spn-review | Haiku | yes |

Override rules:
- `--model-tier economy` forces all sub-skills to Haiku
- `--model-tier maximum` forces all sub-skills to Sonnet, with adversarial and synthesis on Opus
- Adversarial pass is always Opus (Haiku and Sonnet miss counterfactuals reliably); cannot be downgraded by any tier flag — this is the most important quality guarantee

## Cost reporting in the output

The Summary section includes a one-line cost report:

```
Cost: ~USD 0.21 (Haiku 23k tokens, Sonnet 31k tokens, Opus 6k tokens). Override with --model-tier {economy|standard|maximum}.
```

Detailed per-phase breakdown appears as an optional collapsible section after the Findings:

```markdown
### Cost Breakdown (collapsed by default)
| Phase | Model | Tokens (in) | Tokens (out) | USD |
|-------|-------|-------------|--------------|-----|
| Triage | Haiku 4.5 | 2,100 | 400 | 0.002 |
| ...
```

## Quality safeguards

Multi-model routing can introduce subtle quality drops if the cheap-model phase makes a decision the expensive-model phase cannot reverse. Three safeguards:

1. **Classification is reversible.** If Haiku misclassifies an artifact (e.g., calls a `.trc` excerpt a `.sqlplan`), the subsequent sub-skill subagent will fail the input check and the orchestrator re-routes.

2. **Hypothesis generation is non-binding.** Hypotheses are ranked, not picked. The adversarial pass (always Opus or higher) can demote any hypothesis. Haiku's ranking is an opening bid.

3. **Adversarial pass cannot be downgraded.** Even on `--model-tier economy`, the adversarial check runs on Opus. The economy flag affects probe cost, not the disproof attempt. This is the most important quality guarantee.

## Why this exists

Token cost compounds. A team running 5 reviews per day across 20 servers is 36,500 reviews per year. USD 0.21 per review = USD 7,665/year. All-Sonnet would be ~USD 13,000/year. The 40% saving is real money for the same outcome.

The cost mostly accrues in phases that don't need a frontier model. The frontier model pays for itself on the adversarial pass, where shallow reasoning produces dangerous false-confidence reports.
