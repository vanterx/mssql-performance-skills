# Follow-Up Q&A (V10)

After the report is delivered, the orchestrator stays in the session to answer follow-up questions. Most questions are answered from the in-context evidence chain and recommendations without new tool calls — making follow-ups effectively free.

## Why this exists

Reports are dense. A reasonable user wants to ask:

- "Why this index ordering and not (OrderDate, CustomerId)?"
- "Was the adversarial check really thorough? Did you consider X?"
- "Why was MAXDOP not recommended despite the CXPACKET signal?"
- "Show me only the Critical findings."
- "Re-rank the fixes by effort, not impact."

Re-running the entire orchestrator for each of these is wasteful. Follow-up Q&A turns the report into an interactive artifact instead of a static document.

## Question taxonomy

The orchestrator classifies each follow-up question into one of five categories and responds accordingly:

| Category | Source | Cost | Example |
|----------|--------|------|---------|
| 1. Explanation of an existing finding | Evidence chain (in context) | Free | "Why did you flag C1?" |
| 2. Tradeoff between recommended fix and an alternative | Risk rubric + evidence + domain memory (in context) | Free | "Why not use an indexed view instead?" |
| 3. Detail about a specialised skill's raw output | Per-Skill Section (in context) | Free | "What did sqlwait-review actually show for WRITELOG?" |
| 4. New data the user is providing | New probe (cheap dispatch) | ~USD 0.02-0.05 | "Here are the wait stats from after the fix. Did it work?" |
| 5. Out-of-scope question | Direct answer, no probe | Free | "What version of SQL Server should I upgrade to?" |

Most questions fall in categories 1-3 (free). Categories 4 and 5 are clearly distinguished by the orchestrator before responding.

## When NOT to dispatch a new probe

The orchestrator answers from the in-context evidence chain (no new probes) when:

- The question is about a finding, recommendation, or per-skill detail already in the report
- The answer can be derived from the cited check IDs, observed values, and thresholds
- No new artifact has been provided

The orchestrator must NOT silently re-run a sub-skill to confirm something already in the report. That's wasteful and may produce inconsistent results if the artifact has not changed.

## When to dispatch a new probe

The orchestrator dispatches a new probe (cheap subagent) only when:

- The user provides a new artifact (paste, file path, follow-up capture bundle)
- The user asks for a metric or finding that requires a check not previously run
- The question references a hypothetical change ("what if we set MAXDOP to 4?") that needs new analysis

Dispatch is always single-skill (the most relevant one) and on the cheapest applicable model tier.

## When to refuse

The orchestrator refuses to dispatch when:

- The question is out of scope (SQL Server upgrade strategy, license cost, vendor selection)
- The question implies live execution against a SQL Server (the orchestrator is strictly offline)
- The question conflicts with the trust model (writing to facts.json without user confirmation)

Refusal is explicit and brief. The user can rephrase or provide the missing artifact and re-ask.

## Answer format

Follow-up answers cite the evidence chain explicitly. Example:

```
User: Why this index ordering? Why not (OrderDate, CustomerId)?

Orchestrator: The predicate is `WHERE CustomerId = @CustomerId AND OrderDate >= @StartDate`.
  CustomerId is the equality predicate (most selective), OrderDate is the inequality range.
  Index seek requires the equality column first, then the range column. Reversing
  the order would force a range scan over all CustomerIds matching the date range,
  which is far less selective.

  Evidence:
  - sqlplan-review N5 cited the missing-index suggestion with EQUALITY=[CustomerId],
    INEQUALITY=[OrderDate] (Impact 93.2). Source: slow-proc.sqlplan, Stmt 1, NodeId 1.
  - The optimizer's own suggestion uses this ordering for the same reason.

  If you reverse the ordering, the index does not eliminate the Clustered Index Scan
  in this plan — the predicate cannot seek. You would have a larger non-clustered
  index that's never used, increasing write cost without read benefit.
```

The answer is structured:

1. Direct answer to the question
2. Evidence references with check IDs, source artifacts, locations, observed values
3. Counterfactual or tradeoff context if relevant ("if you reverse it ...")

## Session memory

Within a single session, the orchestrator remembers:

- The evidence chain (every finding's evidence records)
- The hypothesis trace (initial and final confidence, probes run)
- The adversarial check result
- The consolidated fix priority table
- The domain memory facts file (if loaded)
- All previous follow-up questions and answers

Across sessions, the orchestrator does not auto-remember. The user can resume a prior review with `--baseline ./state/<run-id>/state.json`, which loads the prior context.

## Cost guard

To prevent runaway costs from a long Q&A session, the orchestrator tracks token usage and warns at thresholds:

```
Note: this Q&A session has consumed ~12,000 tokens beyond the original report.
Total session cost: ~USD 0.18 (within budget). Continuing.
```

```
Warning: this Q&A session has consumed ~50,000 tokens beyond the original report.
Total session cost: ~USD 0.42. Consider summarising and starting a new session
to reset context, or running `--exhaustive` from the start if you need this much
depth.
```

The user can override the warning and continue. The orchestrator does not enforce a hard cap.

## Question patterns the orchestrator should handle well

### "Why is X recommended?"

Cite the finding that drove X, the evidence supporting the finding, the risk rubric entry that classified X's risk, and any domain memory escalators that adjusted X.

### "Why is Y NOT recommended?"

Either:
- Y was rejected by an explicit rule (e.g., domain memory said the change was already in place) — cite the rejection rule and the facts.json line.
- Y was considered and dropped because its evidence was weaker than the recommended alternative — cite the comparative analysis.
- Y was not considered because no signal pointed to it — explain why the signal was absent.

### "Show me only the Critical findings"

Filter the in-context report to Critical-severity entries. No new probe.

### "Re-rank by effort, not impact"

Re-sort the Consolidated Fix Priority table by effort field. Note the original ranking is impact-based. No new probe.

### "What about [pattern not in the report]?"

Check whether the pattern was evaluated and passed (cite the Passed Checks section), or not evaluated because the required artifact was missing (cite the Skills Skipped section), or genuinely out of scope. Be explicit which.

### "Here are new artifacts — re-run the analysis"

This is a fresh review with the new artifacts (plus the prior context as baseline). Dispatch normally; the prior evidence chain becomes the baseline-diff source.

### "What would refute your primary hypothesis?"

Cite the adversarial check section. If the user wants more, dispatch a targeted adversarial probe with `--model-tier maximum --no-adversarial=false`. Always show the disproof template that was applied.

## Cost profile

Typical Q&A session:

| Questions | Categories | Tokens (Haiku) | USD |
|-----------|-----------|----------------|-----|
| 1-5 follow-ups | Categories 1-3 only | ~3,000 | ~0.003 |
| 5-15 follow-ups | Mostly 1-3, one 4 | ~10,000 | ~0.012 |
| Extended Q&A with multiple artifact additions | Mix of 1-4 | ~30,000+ | ~0.10+ |

For routine review + 5 follow-ups: total session cost ~USD 0.23 (USD 0.21 review + USD 0.02 Q&A).

## Trust model

Same as the rest of the orchestrator. Follow-up Q&A:

- Reads in-context evidence (already established)
- Reads files the user provides
- Generates new capture suggestions but never executes them
- Never modifies the user's tooling or SQL Server

The user can end the session at any time; nothing persists unless they ask for `--save-session`.
