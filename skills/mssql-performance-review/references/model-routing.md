# Multi-Model Routing (V5)

The orchestrator dispatches each phase of the review to the model best suited to the reasoning that phase requires.

## Default routing

| Phase | Model | Why this model |
|-------|-------|----------------|
| File classification | Haiku 4.5 | Pattern match against the artifact-signal table. No multi-step reasoning. |
| Hypothesis generation | Haiku 4.5 | Map artifacts to known hypothesis classes (catalogue in check-explanations.md). |
| Triage subagents (each calls a specialised skill) | Haiku 4.5 | The specialised skill loader does the deep work. The orchestrator subagent just dispatches and formats. |
| Deep-dive sqlplan-review per plan | Sonnet 5 | Operator-level XML reasoning, cardinality math, parameter sniffing detection. Quality-sensitive. |
| Cross-skill synthesis + conflict detection | Sonnet 5 | Build the evidence chain, detect cross-skill conflicts, derive the consolidated fix priority. |
| Adversarial root-cause check | Opus 5 | Counterfactual reasoning. Opus is best at "what would refute this hypothesis?" — the highest-leverage phase to protect against confirmation bias. |
| Recommendation rendering | Haiku 4.5 | Templating. |
| Follow-up Q&A | Haiku 4.5 | In-context lookup against the evidence chain — no new tool calls. |

## How routing is enforced in subagent dispatch

When the orchestrator dispatches a sub-skill via the Agent tool, it explicitly sets the `model` parameter on the Agent call:

| Sub-skill | Default model |
|-----------|--------------|
| tsql-review | Haiku |
| sqlwait-review | Haiku |
| sqlstats-review | Haiku |
| sqltrace-review | Haiku |
| sqlquerystore-review | Haiku |
| sqlprocstats-review | Haiku |
| sqlplan-review | Sonnet |
| sqlplan-batch | Sonnet |
| sqlplan-compare | Sonnet |
| sqlindex-advisor | Sonnet |
| sqldeadlock-review | Sonnet |
| sqlhadr-review | Haiku |
| sqlclusterlog-review | Sonnet |
| sqlerrorlog-review | Haiku |
| sqlspn-review | Haiku |

The adversarial pass always runs on Opus — Haiku and Sonnet miss counterfactuals reliably. This is the most important quality guarantee in the routing table and is never downgraded.

## Quality safeguards

Multi-model routing can introduce subtle quality drops if the cheap-model phase makes a decision the expensive-model phase cannot reverse. Three safeguards:

1. **Classification is reversible.** If Haiku misclassifies an artifact (e.g., calls a `.trc` excerpt a `.sqlplan`), the subsequent sub-skill subagent will fail the input check and the orchestrator re-routes.

2. **Hypothesis generation is non-binding.** Hypotheses are ranked, not picked. The adversarial pass (always Opus) can demote any hypothesis. Haiku's ranking is an opening bid.

3. **Adversarial pass cannot be downgraded.** The disproof attempt always runs on Opus regardless of how the probe phases were routed.

## Why this exists

The reasoning demands of the phases differ by more than an order of magnitude. Classification is a pattern match; the adversarial pass is counterfactual reasoning where shallow analysis produces dangerous false-confidence reports. Routing each phase to the model that matches its demands keeps the frontier model focused where it changes the outcome.
