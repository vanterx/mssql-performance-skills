# SQL Server Performance Review — Symptom-Driven Triage

**User request:** "CPU is pegged at 95% on PROD-SQL01 since 09:00. No recent deploy. Users complaining about slowness. I have no artifacts captured yet."

This example shows the orchestrator's response when the user supplies only a symptom and no artifacts. The orchestrator does not contact the SQL Server — it tells the user what to capture and why.

---

## Summary

- Files analyzed: 0
- Symptom-only triage — no specialised skill has been run yet
- Hypotheses generated: 3 (ranked by signal match)
- Action required: user to run the capture sequence below, then re-invoke with the resulting artifacts

The orchestrator will not contact your SQL Server. The captures below are read-only T-SQL — run them yourself in SSMS, sqlcmd, or your tool of choice.

## Hypothesis Trace (pre-capture)

| Rank | Hypothesis | Initial confidence | Why ranked here | Probe sequence to confirm |
|------|-----------|-------------------|----------------|---------------------------|
| 1 | Runaway query (single workload consuming most CPU) | MEDIUM | "Suddenly slow without a deploy" usually means a specific query crossed a data-size threshold or got a bad plan. Most common cause of acute CPU spikes on an otherwise-healthy instance. | sqlwait-review (confirm CPU-bound profile) → procstats-review (find the offender) → sqlplan-review (drill on top consumer) |
| 2 | Parameter sniffing on a hot procedure | MEDIUM | Plan-cache flush events (memory pressure, AG failover, agent recompile) often expose sniffing problems that lay dormant. | sqlwait-review → query-store-review (plan instability) → sqlplan-compare (before/after) |
| 3 | Compilation pressure / cache flush | LOW | If many distinct queries are recompiling, SIGNAL waits dominate and CPU is consumed by optimizer work. Less likely without a recent deploy, but possible after a memory event. | sqlwait-review (RESOURCE_SEMAPHORE_QUERY_COMPILE signal) → sqlplan-review (look for short total / high compile CPU) |

## Recommended Capture Sequence

Run these in order. Each output is small (kilobytes) — paste into a follow-up `/mssql-performance-review --resume` with the captured artifacts.

### Step 1 — Wait stats (confirms CPU-bound vs other class)

Script: `skills/sqlwait-review/scripts/01_capture_wait_stats.sql`

This is a single SELECT against `sys.dm_os_wait_stats` with the benign-idle exclusion list already applied. Capture once now and once again in 15 minutes for a differential window. Paste both outputs.

**What this tells the orchestrator:**

- If SOS_SCHEDULER_YIELD or signal wait ratio dominant → confirms hypothesis 1 (CPU-bound work).
- If CXPACKET dominant → parallelism overhead, possibly from large scans.
- If PAGEIOLATCH_SH dominant → re-rank: this is I/O, not CPU-bound, despite the perf counter reading.
- If RESOURCE_SEMAPHORE_QUERY_COMPILE dominant → confirms hypothesis 3 (compilation pressure).

### Step 2 — Top procedures by CPU (finds the offender)

Script: `skills/procstats-review/scripts/collection/04_report_queries.sql` (Query 1 — Top CPU)

This identifies the procedure (or trigger, or function) consuming the most CPU in the current cache window. Returns about 20 rows.

**What this tells the orchestrator:**

- A single procedure consuming > 30% of total CPU → confirms hypothesis 1 (one runaway query).
- CPU spread across many procedures → re-rank: server-wide issue, not a single query.

### Step 3 — Top plans by CPU (gets the actual plan)

Script: `skills/sqlplan-review/scripts/01_capture_from_cache.sql` — modify the WHERE clause to filter to the top procedure identified in Step 2. Save the `.sqlplan` output.

**What this tells the orchestrator:**

The execution plan for the top CPU consumer. sqlplan-review will then identify whether the issue is parameter sniffing, missing index, stats stale, or something else.

### Optional Step 4 — Query Store plan history (if confirming hypothesis 2)

Script: `skills/query-store-review/scripts/01_capture_queries.sql` — modify to filter to the `query_hash` of the top consumer.

**What this tells the orchestrator:**

If multiple plans exist for the same query_hash in the last 24 hours → confirms hypothesis 2 (parameter sniffing or other instability). If one plan, the issue is something else.

## When you return with the captures

Run:

```
/mssql-performance-review ./captures/prod-cpu-spike-20260517-0900/
```

The orchestrator will:

1. Classify the captured files
2. Apply the relevant skills (sqlwait-review → procstats-review → sqlplan-review, plus query-store-review if Step 4 was run)
3. Generate a full unified report with findings, fix priority, and verification checklist
4. Run the adversarial pass to confirm the root cause is not actually one of the alternatives

## What the orchestrator will NOT do

- Contact your SQL Server. Every script above is something you run in your own tool. The orchestrator only reads the output you paste back.
- Recommend disruptive actions without a complete risk and rollback profile. Every fix that lands in the report has explicit Low/Medium/High risk, side effects, and an exact rollback step.
- Skip the adversarial check. Even if hypothesis 1 looks obvious from the wait stats alone, the orchestrator will deliberately probe for I/O-bound and compilation-pressure signals before declaring "runaway query" as the root cause.

## If you can only run Step 1 right now

That is the cheapest capture and still useful. Wait stats alone tell us:

- Whether CPU is real (high signal wait ratio, SOS_SCHEDULER_YIELD dominant) or a measurement artifact
- Whether the bottleneck class is CPU, I/O, lock, parallelism, memory, or compilation

Once you paste Step 1, the orchestrator will tell you whether to proceed with Steps 2-4 or re-route to a different probe sequence (for example, if Step 1 says PAGEIOLATCH_SH dominant, the next probe is file-IO stats, not procstats).

---
*Analyzed by: Claude Sonnet 4.6 · 2026-05-17 09:45 NZST*
