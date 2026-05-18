# mssql-performance-review — Reference Index

## When to consult these references

The main `SKILL.md` contains the dispatch logic, hypothesis generation, evidence chain shape, output format, and confidence model that drive every review. These reference files provide deeper context when:

- You are emitting the `evidence.json` block and need the exact field schema
- You are grading a recommendation's risk class and need the rubric
- You are running the adversarial root cause check and need the disproof template for the active hypothesis class
- You are explaining the methodology to a user ("why does the orchestrator route in this order?")

Load a reference file when its situation applies. The orchestrator does not need any of them loaded by default — they are progressive disclosure.

## Reference files

### check-explanations.md

**When to load:** A user asks about methodology — "how does the dispatcher decide order?", "why is the adversarial pass mandatory?", "what counts as a conflict between recommendations?". Also when a recipient of a report asks how a finding was derived from the underlying skills.

**What it covers:** Dispatch heuristics in detail, the symptom → probe-sequence map, hypothesis class definitions, the conflict-detection catalogue between skill outputs, and the rationale for the standard analysis order.

### evidence-schema.md

**When to load:** Building or validating the evidence record that backs every consolidated finding. The orchestrator emits an `evidence.json` alongside the human-readable report so downstream tools (change tickets, post-mortem docs) can re-derive findings from the raw inputs.

**What it covers:** The full JSON schema for the evidence record, field-by-field validation rules, the human-readable rendering convention, and reproducibility guarantees (a recipient must be able to re-derive each finding by inspecting the cited artifact at the cited location).

### risk-rubric.md

**When to load:** Grading a recommended fix as Low / Medium / High risk. Each fix carries a risk class — this file is the source of truth for how to grade.

**What it covers:** Risk-class definitions, the catalogue of common recommendation types (add index, drop index, change MAXDOP, enable RCSI, add OPTION RECOMPILE, etc.) with their default risk class, the side-effect checklist per recommendation type, and the rules for when to escalate risk based on environmental signals (production, AG primary, large table, OLTP hot path).

### adversarial-prompts.md

**When to load:** Running the mandatory adversarial root cause check after a primary hypothesis is identified. This file holds the disproof template for each hypothesis class.

**What it covers:** A template per hypothesis class (parameter sniffing, missing index, stats stale, deadlock pattern, AG failover root cause, etc.) describing what evidence would refute the primary hypothesis, where to look for it, and how to grade the strength of the contradiction (weak / strong).

### model-routing.md

**When to load:** Determining which model to assign to a phase or subagent. Also when the user asks about cost or passes `--model-tier` / `--no-adversarial`.

**What it covers:** Full phase-to-model mapping for the three default tiers (economy / standard / maximum), the per-sub-skill default model assignments, cost profile worked example, quality safeguards (why adversarial always runs on at least Sonnet), and the per-phase cost breakdown format that appears in the Summary block.

### skill-dag.md

**When to load:** Constructing or walking the dependency DAG for a multi-artifact review. Also when a probe's findings might open a dynamic edge to a follow-up skill.

**What it covers:** DAG construction rules (static edges from the dependency catalogue, dynamic edges from findings), the walk algorithm with parallelism, two worked examples (simple mixed input and symptom-only-with-bundle-return), and the full catalogue of dynamic edges (when finding X in skill A opens an edge to skill B).

### domain-memory.md

**When to load:** A facts file is present at `~/.mssql-perf-review/instances/<server>.json`, or the user invokes `/sql-triage --capture-instance-facts`, or a recommendation might conflict with documented instance configuration.

**What it covers:** The facts.json schema, field-by-field validation rules, the rejection/escalation catalogue (which facts cause which recommendation adjustments), staleness handling (>90 days triggers warning), per-database fact handling, multi-instance reviews, and the catalogue of facts the orchestrator currently consumes.

### followup-qa.md

**When to load:** The user asks a follow-up question after the report. Use to classify the question type and decide whether to answer from context (free) or dispatch a new probe (cheap).

**What it covers:** The five-category question taxonomy, when-to-probe vs answer-from-context rules, refusal patterns (live SQL, out of scope), the structured answer format with evidence citation, session memory rules, cost-guard warnings, and a catalogue of common question patterns ("why is X recommended?", "show me only Critical findings", "re-rank by effort") with the orchestrator's expected response shape.

### capture-bundle-spec.md

**When to load:** Artifacts are missing and the orchestrator needs to emit a capture bundle to `./captures/<run-id>/`. Also when the user passes `--resume <bundle-dir>` and the orchestrator needs to parse the paste-back.

**What it covers:** Bundle directory layout, curation rules per hypothesis class, README and PASTE-RESULTS-HERE.md templates, the manifest.json schema with all field rules, the resume flow (validate, parse paste-back, route to sub-skills), capture-instance-facts variant for V9 domain memory population, bundle history and re-bundling rules, and the design decisions behind self-contained bundles.

### verification-checklist.md

**When to load:** Generating the Verification — After Deploying Fixes section of the report, or running the baseline-diff feedback loop when the user passes `--baseline`. Also when a recommendation needs a re-capture instruction or tagging logic.

**What it covers:** The Verification output structure, suggested timing rules per recommendation type (24h for indexes, 1h for stats, etc.), the five-tag baseline-diff catalogue with conditions (verified-effective / partial / no-change / regressed-elsewhere / cannot-evaluate), the feedback.jsonl schema (append-only), edge cases (rollbacks, multi-recommendation findings, artifact drift), the verification quality metric, and the user-local-by-default learning loop with optional team-shared `--feedback-file` override.
