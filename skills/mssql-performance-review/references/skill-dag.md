# Skill-Graph DAG (V6)

Tier 1 dispatched in fixed phases (source → triage → deep-dive → targeted → availability). Tier 2 replaces fixed phases with a dynamic dependency DAG built from artifact types and probe findings. The DAG walks with maximal parallelism, follows edges that become available as findings accumulate, and stops on early termination.

## When to use the DAG vs fixed phases

| Situation | Use |
|-----------|-----|
| Single artifact type | Fixed phases (DAG has only one node) |
| Two or three artifact types with no expected cross-edges | Fixed phases |
| Mixed artifacts where one probe's finding routes to another probe | DAG |
| Symptom-only with capture bundle | DAG (initially empty, grows as bundle results return) |

The DAG is the default whenever the input has more than one artifact type. The user can force fixed phases with `--phases` for compatibility with tier-1 behavior.

## Constructing the DAG

### Step 1 — Add a node per artifact-skill pair

For each input artifact, look up its target skill from the classification table. Each (artifact, skill) pair is a DAG node. Multiple artifacts of the same type produce multiple nodes, all targeting the same skill (parallel sub-skill invocations).

```
artifacts: slow-proc.sql, slow-proc.sqlplan, wait-stats.txt, query-store-output.txt

initial nodes:
- (slow-proc.sql, tsql-review)
- (slow-proc.sqlplan, sqlplan-review)
- (wait-stats.txt, sqlwait-review)
- (query-store-output.txt, query-store-review)
```

### Step 2 — Add static edges from the dependency catalogue

Some skill outputs always inform another skill. These are static edges:

| Static edge | Reason |
|-------------|--------|
| sqlplan-review → sqlplan-index-advisor | Advisor consolidates plan findings |
| sqlplan-review → sqlplan-batch (only when multi-plan input) | Batch aggregates per-plan reviews |
| sqltrace-review → sqlplan-deadlock (when deadlock events in trace) | Extract XDLs from trace, route to deadlock |
| errorlog-review → clusterlog-review (when AG failover detected) | AG events in ERRORLOG correlate with WSFC events |
| clusterlog-review → hadr-health-review | WSFC state change implies AG state question |
| errorlog-review → spn-review (when Kerberos errors in ERRORLOG) | Login burst with NTLM fallback signals SPN issue |

These edges are deterministic from the input set.

### Step 3 — Add dynamic edges from findings

Some edges only appear when a probe's findings open them. The DAG walker adds these as probes return:

| Trigger | Dynamic edge added |
|---------|--------------------|
| sqlplan-review fires S9 (parameter sniffing) | sqlplan-review → query-store-review (for plan instability check) |
| query-store-review fires Q7 (multiple plans for same query_hash) | query-store-review → sqlplan-compare (for regression hunt — needs both plans) |
| sqlwait-review reports PAGEIOLATCH_SH dominant | sqlwait-review → sqlplan-review (for the top reader plan) |
| sqlstats-review fires I5 (single table dominates reads) | sqlstats-review → sqlplan-index-advisor (specifically for that table) |
| procstats-review fires R1 (proc CPU hotspot) | procstats-review → sqlplan-review (for the hot proc's plan) |

Dynamic edges are how the orchestrator adapts: a finding in one skill creates a follow-up edge to another skill that would not have run otherwise.

### Step 4 — Validation

Before walking, validate:

- No cycles (a DAG is acyclic by definition; cycles would indicate a bug in the catalogue)
- Every node has at most one outgoing edge per skill-pair (multiple findings firing the same dynamic edge don't duplicate the node)
- No orphan nodes (every node has a defined source artifact)

## Walking the DAG

Standard topological walk with parallelism:

```
ready = set of nodes with no incoming edges
in_progress = {}
completed = {}

while ready or in_progress:
    # Dispatch all ready nodes as subagents in parallel
    for node in ready:
        agent_id = dispatch_agent(node.artifact, node.skill, model=tier_routing(node.skill))
        in_progress[agent_id] = node
    ready = {}

    # Wait for any subagent to return
    completed_agent = wait_for_first_return(in_progress)
    node = in_progress.pop(completed_agent)
    completed[node] = collect_findings(completed_agent)

    # Add dynamic edges based on this node's findings
    new_edges = dynamic_edges_from(node, completed[node])
    add_edges_to_dag(new_edges)

    # Check early-termination criteria (tier 1 rule)
    if confidence_high_and_three_skills_converged() and not adversarial_contradiction():
        cancel_remaining_agents()
        break

    # Add newly-unblocked nodes to ready
    for n in dag.unblocked_by(node):
        ready.add(n)
```

Parallelism is implicit — any nodes in `ready` at the same time run as parallel subagents.

## Example walks

### Example 1 — Simple mixed input

Input: `.sql`, `.sqlplan`, wait stats.

Initial DAG:
```
(slow-proc.sql, tsql-review) ──► (sqlplan-index-advisor) [static]
(slow-proc.sqlplan, sqlplan-review) ──► (sqlplan-index-advisor) [static]
(wait-stats.txt, sqlwait-review)
```

Walk:
1. Round 1 (parallel): tsql-review, sqlplan-review, sqlwait-review
2. After sqlplan-review returns with S9 sniffing, dynamic edge sqlplan-review → query-store-review added — but no Query Store artifact, so the edge points to a missing-artifact request (handled by tier 3 bundle generator; in tier 2, recorded as Missing Artifact in report)
3. After all of round 1 return, sqlplan-index-advisor (parallel ready) runs
4. After advisor returns, synthesis + adversarial + report

Skills run: tsql-review (Haiku), sqlplan-review (Sonnet), sqlwait-review (Haiku), sqlplan-index-advisor (Sonnet). Synthesis (Sonnet), adversarial (Opus).

### Example 2 — Symptom-only with bundle return

Input: `--resume ./captures/cpu-spike/` with wait stats, plan-from-cache, query-store snapshot pasted back.

Initial DAG:
```
(wait-stats, sqlwait-review)
(plan, sqlplan-review) ──► (sqlplan-index-advisor)
(query-store, query-store-review)
```

Walk:
1. Round 1 (parallel): sqlwait-review, sqlplan-review, query-store-review
2. sqlwait-review reports CPU-dominant (SOS_SCHEDULER_YIELD). Dynamic edge sqlwait-review → sqlplan-review already exists (same plan), so no-op.
3. sqlplan-review fires S9. Dynamic edge sqlplan-review → query-store-review opens — but query-store is already running. The DAG walker checks "skill already in progress or completed" and skips adding a duplicate node.
4. query-store-review returns with Q7 (3 plans for same query_hash). Dynamic edge to sqlplan-compare — but no second plan available, so Missing Artifact recorded.
5. sqlplan-index-advisor runs after sqlplan-review completes.
6. Adversarial pass corroborates parameter sniffing (CPU-dominant from sqlwait + 3 plans from query-store = consistent). HIGH confidence, three skills agree, no contradiction. Early termination — synthesis + report.

Skills NOT run: sqlplan-compare (artifact missing), sqlplan-deadlock (no XDL), tsql-review (no `.sql`), sqltrace-review (no trace), procstats-review (no procstats), all AG/cluster/errorlog/spn (no signals).

10 skills skipped. 4 ran. Cost ~USD 0.12.

## Why this exists

Fixed phases waste cost and time. A senior DBA looks at the wait stats first, sees CPU-dominant, immediately pulls the plan for the top CPU consumer, sees parameter sniffing, checks Query Store, confirms. The DAG encodes that adaptive flow.

Fixed phases also produce wrong dispatch — they might run sqlplan-batch even when there's no batch (because the phase says to), or skip the dynamic edge to query-store-review (because the phase ordering doesn't have it).

## Catalogue of dynamic edges

This catalogue grows as new findings reveal cross-skill dependencies. Each entry: when this finding fires in source skill X, route to target skill Y.

| Source skill | Finding | Target skill | Purpose |
|--------------|---------|--------------|---------|
| sqlplan-review | S9 parameter sniffing | query-store-review | Confirm plan instability across time |
| sqlplan-review | N5 missing-index suggestion | sqlplan-index-advisor | Score and consolidate |
| sqlplan-review | N15/N16 spill | sqlwait-review | Check RESOURCE_SEMAPHORE / CMEMTHREAD waits |
| sqlplan-review | N20 large memory grant | sqlwait-review | Same as above |
| sqlplan-review | S12 implicit conversion | tsql-review | Find the source statement to fix |
| sqlstats-review | I5 single-table dominance | sqlplan-index-advisor | Targeted index recommendation |
| sqlstats-review | I6 Worktable / Workfile | sqlplan-review | Find the spilling operator |
| sqlwait-review | PAGEIOLATCH_SH dominant | sqlplan-review | Top reader plan |
| sqlwait-review | LCK_M_* dominant | sqlplan-deadlock | If XDLs available |
| sqlwait-review | CXPACKET dominant + low CTfP | (config recommendation — no probe) | |
| sqltrace-review | X14 parameter-sniffing signal | sqlplan-compare | Capture fast and slow plans |
| sqltrace-review | class 59 deadlock | sqlplan-deadlock | Extract XDLs |
| sqltrace-review | X20 ShowPlan XML present | sqlplan-batch | Bulk-analyze the extracted plans |
| query-store-review | Q7 plan instability | sqlplan-compare | Diff the plans |
| query-store-review | Q9 forced plan failure | sqlplan-review | Capture current and forced plans |
| procstats-review | R1 CPU hotspot | sqlplan-review | Hot proc plan |
| procstats-review | R10 spills | sqlwait-review | Memory grant waits |
| errorlog-review | E1 AG failover | clusterlog-review + hadr-health-review | Failover root cause chain |
| errorlog-review | E22 login burst with Kerberos | spn-review | SPN / delegation root cause |
| errorlog-review | E15 I/O slow warning | sqlwait-review | Confirm with file-level latency |
| clusterlog-review | L6 quorum loss | hadr-health-review | Confirm AG state |
| clusterlog-review | L1/L2 lease/health failure | sqlplan-review (top reader) | If scheduler starvation suspected |

## Edge case: artifact unavailable

When a dynamic edge points to a skill whose required artifact is not in the input:

- Tier 2: record as a Missing Artifact finding with the suggested capture script path
- Tier 3: also generate a follow-up capture bundle for those scripts

The DAG walk does not block on missing artifacts — it skips the node and records the gap.

## Why a DAG and not just "all parallel"

Pure parallelism would invoke every applicable skill on every input simultaneously. Two problems:

1. **Cost waste.** Tier-1 ordering (cheap source/breadth before expensive deep-dive) is preserved by the DAG via the static dependency catalogue. Pure parallelism would run sqlplan-review on every plan even when the source is clean enough to skip.

2. **Cross-skill validation loss.** Findings from skill A often reveal which probe in skill B is worth running. The dynamic edges encode this. Without them, the orchestrator would either run B always (waste) or never (miss findings).

A DAG is the right structure: parallelism where independent, sequence where dependent.
