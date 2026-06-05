# Adversarial Disproof Templates

After a primary root cause hypothesis is identified, the orchestrator runs a deliberate disproof attempt. This document is the catalogue of templates — one per hypothesis class.

## How to use

When a hypothesis has been promoted to HIGH confidence, look up its class in the catalogue, run the disproof procedure, and record the result in the finding's `adversarial` block (see `evidence-schema.md`).

Three possible results:

| Result | Meaning | Effect on report |
|--------|---------|------------------|
| `no_contradiction` | The disproof attempt found no refuting evidence. | Hypothesis stands; finding remains HIGH confidence. |
| `weak_contradiction` | Some signal pointed elsewhere but was inconclusive (e.g., a single check fired one notch from the threshold; one corroborating skill could not run for lack of data). | Hypothesis stands; finding downgraded to MEDIUM; the caveat is recorded in the report. |
| `strong_contradiction_alternative_escalated` | A coherent alternative root cause exists with at least one corroborating skill. | The alternative is added as a competing finding at equal or higher priority; both are surfaced to the user with their respective evidence. |

The adversarial pass is mandatory for every Critical finding and every HIGH-confidence Warning. It is not skipped by early termination.

---

## Templates

### Parameter sniffing

**Hypothesis statement.** A procedure / query compiled a plan optimal for one parameter value, then re-used that plan for very different values, causing runtime to diverge.

**Disproof procedure.**

1. Check whether the wait profile is consistent with parameter sniffing.
   - Expected if sniffing: CPU-dominant on the slow plan, SOS_SCHEDULER_YIELD or signal waits prominent.
   - Refuting: PAGEIOLATCH_SH > 25% of wait time (suggests I/O-bound, not sniffing — the plan may be appropriate but the underlying data is too large to scan efficiently).

2. Check Query Store for the actual plan stability claim.
   - Expected if sniffing: two or more distinct plans for the same `query_hash` in the capture window.
   - Refuting: single `plan_id` for the entire window — there is no "fast plan" and "slow plan" to alternate between.

3. Check the cardinality mismatch ratio.
   - Expected if sniffing: actual rows vary by >= 100x across executions of the same plan.
   - Refuting: actual rows are stable across executions; the bottleneck is something else.

**Refutation strength.**

- Strong: at least two of (1), (2), (3) refute. Alternative hypotheses to consider: missing index (if (3) refutes), server-wide I/O (if (1) refutes), data growth (if (2) refutes).
- Weak: only one refutes inconclusively.

---

### Missing index

**Hypothesis statement.** A query is slow because no index supports its access pattern; adding the missing index will resolve.

**Disproof procedure.**

1. Check whether the recommended index would have been useful historically.
   - Expected if missing index: Query Store shows the query was fast before a data-size threshold was reached, and the recommended index has high optimizer Impact.
   - Refuting: Query Store shows the query was always slow at this row count — the access pattern itself is the problem.

2. Check whether a similar index already exists.
   - Expected if missing index: no existing index on the leading column(s) of the recommendation.
   - Refuting: an existing index has the same leading column but is unused — investigate why before recommending a new one (statistics? predicate type mismatch? trace flag?).

3. Check whether the parent query is the actual hot path.
   - Expected if missing index: sqlprocstats-review or sqltrace-review confirms the calling procedure is in the top consumers.
   - Refuting: the query is rarely called; the slow path is elsewhere — the new index has carrying cost but no benefit.

**Refutation strength.**

- Strong: (2) is refuting — there is already an index that should work. Alternative: stats stale on the existing index, or the predicate is wrapped in a function preventing seek.
- Weak: only (1) or (3) refute.

---

### Stats stale

**Hypothesis statement.** The optimizer has outdated row-count and distribution information; updating stats will produce a better plan.

**Disproof procedure.**

1. Check `sys.dm_db_stats_properties` last_updated.
   - Expected if stale: > 1 day for hot tables, or modification_counter > 20% of row count.
   - Refuting: stats updated recently and modification_counter is small — the mismatch is not from staleness.

2. Check whether the cardinality mismatch is on a column with stats at all.
   - Expected: yes, with the predicate's column matching a stats key.
   - Refuting: the predicate is on a column with no stats (rare; auto_create_statistics off?), or uses a function preventing histogram use.

**Refutation strength.**

- Strong: (1) and (2) both refute. Alternative: parameter sniffing, predicate complexity, table variable being treated as one row.
- Weak: stats are old but auto-update fired recently (recheck after a synthetic UPDATE STATISTICS).

---

### Deadlock pattern

**Hypothesis statement.** A specific deadlock pattern (lock order, page-level, escalation, bookmark lookup, etc.) explains the deadlock graph.

**Disproof procedure.**

1. Check the pattern's signature against the deadlock XML.
   - Expected: the lock types, isolation levels, and resource hierarchy match the pattern.
   - Refuting: the resource graph has more participants than the pattern requires, or the lock types don't match.

2. Check whether the deadlock recurs with the same signature.
   - Expected if pattern: multiple deadlock graphs over time share the signature.
   - Refuting: this is a one-off with novel resources — investigate as an isolated incident.

**Refutation strength.**

- Strong: a different pattern matches better.
- Weak: pattern partially matches; the orchestrator surfaces both candidates.

---

### Server-wide I/O bottleneck

**Hypothesis statement.** Disk subsystem cannot keep up with read demand; PAGEIOLATCH waits dominate; the fix is at the storage layer (or by reducing read demand via indexes).

**Disproof procedure.**

1. Check whether reads are concentrated or distributed.
   - Expected if server-wide: many tables contribute to logical reads; no single query dominates.
   - Refuting: one query accounts for > 50% of reads — it's a query problem, not a server problem.

2. Check `sys.dm_io_virtual_file_stats` per file latency.
   - Expected if server-wide: latency > 20ms across multiple files.
   - Refuting: latency normal on most files except one (storage problem localized to that volume).

**Refutation strength.**

- Strong: (1) refutes (single hot query) — re-route to per-query analysis.
- Weak: latency uneven but not dramatically so.

---

### AG / failover root cause

**Hypothesis statement.** An identified event sequence (lease expiry → health check fail → role change) explains the AG failover.

**Disproof procedure.**

1. Check temporal correlation.
   - Expected: ERRORLOG event, CLUSTER.LOG event, and AG state change within seconds of each other.
   - Refuting: events are minutes apart — they may be independent.

2. Check whether the AG state change is consistent with the supposed cause.
   - Expected: automatic failover follows lease expiry / health check failure.
   - Refuting: planned failover (manual / WSFC role change) — different root cause.

**Refutation strength.**

- Strong: temporal correlation absent.
- Weak: events correlated but the cause-effect direction is unclear.

---

### Kerberos auth failure

**Hypothesis statement.** Missing or duplicate SPN, or unconstrained delegation, prevents Kerberos and clients fall back to NTLM or fail.

**Disproof procedure.**

1. Check whether the auth failure is Kerberos-specific.
   - Expected: ERRORLOG shows 17806/17807 (Kerberos failure) or "Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'".
   - Refuting: failure is for a specific SQL login (auth-mode problem, not Kerberos).

2. Check whether setspn output supports the SPN cause.
   - Expected: SPN is missing on the expected service account, or duplicated, or registered on a wrong account.
   - Refuting: SPNs are correct — the problem is delegation config (different K-check) or an AD trust issue.

**Refutation strength.**

- Strong: SPNs are correct — re-investigate delegation or trust.
- Weak: SPN slightly wrong but the burst time does not match the SPN issue's creation date.

---

## Adding a new hypothesis class

If you identify a recurring root cause class not in this catalogue, add a template here following the structure: hypothesis statement → 2–3 numbered disproof procedures with expected/refuting signals → refutation strength rules with named alternatives.

Templates that are vague enough to never refute anything are worse than nothing — they create the illusion of an adversarial check without performing one. Keep the disproof procedures concrete and signal-driven.
