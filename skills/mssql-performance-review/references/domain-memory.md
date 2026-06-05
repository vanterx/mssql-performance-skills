# Domain Memory (V9)

Per-instance and per-database facts the orchestrator uses to grade recommendations. Stored in a user-managed JSON file outside the repo. The orchestrator only reads — never writes silently.

## Why this exists

Generic recommendations are wrong in specific environments. A senior DBA brings tribal knowledge to every review:

- "We already tried MAXDOP 4 on this server; tanked OLAP queries — don't suggest it again."
- "Orders is partitioned monthly; index recommendations must align with the partition scheme."
- "ContractsDB is on an AG primary; any ALTER DATABASE replicates and affects the sync secondary's commit latency."
- "We use Standard edition on this instance — no online index rebuild for LOB tables."

Without that context, the orchestrator's recommendations are correct in the abstract but wrong in the actual environment. Domain memory makes the tribal knowledge first-class.

## File location

Default: `~/.mssql-perf-review/instances/<server-name>.json`

The orchestrator reads this path when invoked with `--instance <server-name>` (matches the file name) or auto-detects from the artifacts (uses `@@SERVERNAME` if present in any DMV output).

Override via `--instance-facts <path>` for non-default locations.

The orchestrator does not create the directory or file. If absent, it proceeds without domain context and notes in the report:

```
Note: no domain memory found at ~/.mssql-perf-review/instances/PROD-SQL01.json.
Recommendations are generic. Run `/sql-triage --capture-instance-facts` to generate
a DMV survey for the user to run, then populate the file with the results.
```

## Schema

```json
{
  "instance": "PROD-SQL01",
  "captured_at": "2026-05-17T08:30:00+12:00",
  "captured_by": "user",
  "facts": {
    "physical_cores": 96,
    "logical_cores": 192,
    "numa_nodes": 4,
    "maxdop": 8,
    "cost_threshold_for_parallelism": 50,
    "max_server_memory_mb": 384000,
    "min_server_memory_mb": 0,
    "edition": "Enterprise",
    "version": "SQL Server 2022 CU8 (16.0.4135.4)",
    "compatibility_level_default": 160,
    "is_ag_primary": true,
    "ag_name": "ProdAG",
    "ag_replicas": [
      {"name": "PROD-SQL01", "role": "primary", "commit_mode": "synchronous"},
      {"name": "PROD-SQL02", "role": "secondary", "commit_mode": "synchronous"},
      {"name": "PROD-SQL03", "role": "secondary", "commit_mode": "asynchronous"}
    ],
    "rcsi_enabled_dbs": ["OrdersDB", "ContractsDB"],
    "compatibility_level_per_db": {
      "OrdersDB": 150,
      "ContractsDB": 160,
      "ReportingDB": 140
    },
    "partitioned_tables": [
      {"schema": "dbo", "table": "OrdersHeader", "partition_function": "PF_OrdersByMonth"},
      {"schema": "dbo", "table": "OrderLines", "partition_function": "PF_OrdersByMonth"}
    ],
    "instant_file_initialization_enabled": true,
    "trace_flags_global": [4199, 3226],
    "trace_flags_session_default": [],
    "user_notes": [
      "OrdersHeader is partitioned monthly; index recommendations must include the partition column.",
      "Q4-end load is 2x normal; do not recommend changing MAXDOP without DBA approval.",
      "ReportingDB compatibility level held at 140 deliberately due to a known regression in CE 150 on a specific aggregation pattern.",
      "PROD-SQL03 is offsite — async commit; expected lag 5-30 seconds."
    ]
  }
}
```

### Field rules

| Field | Required | Validation |
|-------|----------|-----------|
| `instance` | Yes | Must match `@@SERVERNAME` or `--instance` flag |
| `captured_at` | Yes | ISO 8601 timestamp; orchestrator warns if older than 90 days |
| `captured_by` | Yes | `user` / `dba-team` / `script` — provenance hint |
| `facts.physical_cores`, `logical_cores` | Recommended | Used for MAXDOP and CTfP rationality checks |
| `facts.maxdop`, `cost_threshold_for_parallelism` | Recommended | Compared against recommendations |
| `facts.max_server_memory_mb` | Recommended | Compared against memory-grant recommendations |
| `facts.edition` | Recommended | Drives online-rebuild availability check |
| `facts.is_ag_primary`, `ag_replicas` | Recommended | Drives AG side-effect escalation |
| `facts.rcsi_enabled_dbs` | Recommended | Prevents redundant "enable RCSI" recommendations |
| `facts.partitioned_tables` | Recommended | Drives partition-alignment escalation on index recommendations |
| `facts.compatibility_level_per_db` | Recommended | Compared against compatibility-level recommendations |
| `facts.trace_flags_global` | Optional | Surfaces in reports as configuration context |
| `facts.user_notes` | Optional | Free-form; the orchestrator quotes relevant notes when generating recommendations |

## How facts shape recommendations

Each recommendation is checked against the facts via the rejection/escalation catalogue:

### Rejection (recommendation removed before reaching the report)

| Recommendation | Rejection condition | Cited fact |
|---------------|--------------------|-----------|
| Change MAXDOP to N | `facts.maxdop == N` | "MAXDOP already at N" |
| Enable RCSI on DB | `DB in facts.rcsi_enabled_dbs` | "RCSI already enabled on DB" |
| Enable instant file initialization | `facts.instant_file_initialization_enabled == true` | "IFI already enabled" |
| Set Cost Threshold for Parallelism to N | `facts.cost_threshold_for_parallelism == N` | "CTfP already at N" |

### Escalation (risk class increased one step, with explicit citation)

| Recommendation | Escalation condition | Side effect added |
|---------------|---------------------|-------------------|
| ALTER DATABASE / ALTER TABLE on a DB | `facts.is_ag_primary == true` | "Replicates to all secondaries; expect sync-commit latency hit during change" |
| CREATE INDEX on a table | Table in `facts.partitioned_tables` | "Must include partition column; output DDL aligned" |
| Online index rebuild | `facts.edition != "Enterprise"` and the table has LOB columns | "Standard edition forces offline rebuild; consider Enterprise upgrade or schedule a maintenance window" |
| Change compatibility level | DB has explicit `compatibility_level_per_db` setting different from default | "DB compatibility level held intentionally; cite reason in user_notes before changing" |

### Output integration

When a recommendation is rejected or escalated, the report shows:

```
Rank 1 — Change MAXDOP to 8 on PROD-SQL01
- REJECTED: facts.json says maxdop already = 8
- Cite: ~/.mssql-perf-review/instances/PROD-SQL01.json
- Replacement recommendation: [next-best from the analysis, or "no MAXDOP action needed"]
```

or

```
Rank 1 — CREATE INDEX IX_Orders_CustomerId_OrderDate ON OrdersDB.dbo.OrdersHeader (CustomerId, OrderDate) INCLUDE (Status, TotalAmount)
- ESCALATED: facts.json says OrdersHeader is partitioned by PF_OrdersByMonth
- Original risk: Low → Adjusted risk: Medium
- Side effect added: Index recommendation must include the partition column.
- Corrected DDL:
  CREATE NONCLUSTERED INDEX IX_Orders_CustomerId_OrderDate
  ON OrdersDB.dbo.OrdersHeader (CustomerId, OrderDate)
  INCLUDE (Status, TotalAmount)
  ON PF_OrdersByMonth (OrderDate);
```

## Populating facts.json

The orchestrator provides a one-shot DMV survey via `/sql-triage --capture-instance-facts`:

```
/sql-triage --capture-instance-facts
```

Emits a single SQL script (`./captures/instance-facts-<run-id>.sql`) the user runs once. Output pastes back into a `facts-input.txt` template; the orchestrator parses it into the JSON schema and tells the user where to save the result.

Trust model unchanged: the orchestrator generates the script and parses the user-provided output. It never executes the script itself.

## When facts are stale

The orchestrator warns if `captured_at` is older than 90 days:

```
Warning: domain memory at ~/.mssql-perf-review/instances/PROD-SQL01.json was captured
2026-02-15 (97 days ago). MAXDOP, AG topology, and edition may have changed.
Re-run `/sql-triage --capture-instance-facts` to refresh.
```

The orchestrator still uses the facts but downgrades any rejection/escalation that depends on a fact older than 90 days to a softer "review and confirm" suggestion in the report.

## Per-database facts

For multi-database servers, the orchestrator inspects `facts.compatibility_level_per_db`, `facts.rcsi_enabled_dbs`, `facts.partitioned_tables` to apply per-DB rules. A recommendation for one database does not pick up an escalator that applies only to another.

## Multi-instance reviews

When reviewing artifacts from multiple instances (e.g., diffing prod vs staging), the orchestrator loads multiple facts files and applies them per-instance. The recommendation set is tagged with the instance it applies to.

## Privacy and sensitive data

`facts.json` contains environmental metadata, not PII. User notes may contain database names, project codes, or change-management references that are sensitive — store the file outside the repo (`~/.mssql-perf-review/` is the default user-home location).

The orchestrator does not transmit facts.json anywhere — it reads from disk and uses the data inline for the current review only.

## Why per-user, not per-repo

Different DBAs may have different views of the same instance (different escalation thresholds, different "do not recommend X" notes). Per-user facts files let each user customise without affecting teammates.

For teams wanting shared facts, copy the file into a team-managed location and use `--instance-facts <path>` to point to it.

## Catalogue of facts the orchestrator currently consumes

Living list — extend as new recommendation types are added.

| Fact | Consumed by | Effect |
|------|-------------|--------|
| `maxdop`, `cost_threshold_for_parallelism` | MAXDOP/CTfP recommendations | Reject if matches; escalate if change is recommended on busy OLTP |
| `max_server_memory_mb` | Memory grant recommendations | Side effect: changes affect all workloads on instance |
| `edition` | Index recommendations | Reject online rebuild if Standard + LOB |
| `is_ag_primary`, `ag_replicas` | Any DDL recommendation | Escalate; note replication side effect |
| `rcsi_enabled_dbs` | RCSI recommendations | Reject if already enabled |
| `partitioned_tables` | Index recommendations | Escalate; require partition alignment |
| `compatibility_level_per_db` | Compatibility level recommendations | Surface user_notes; require explicit reason |
| `trace_flags_global` | Trace flag recommendations | Reject if already enabled |
| `user_notes` | Any recommendation matching note context | Quote relevant note; downgrade or escalate per note content |
| `version` | Version-gated check suppression | Suppress `NOT ASSESSED` rows for checks that require a later SQL Server version |

## Version-Aware Suppression

When `facts.version` is set (e.g., `"SQL Server 2016 SP3 (13.0.6435.1)"`), the orchestrator can suppress `NOT ASSESSED` findings for checks that require a later SQL Server version. This prevents noise in reports for environments where a check is structurally inapplicable rather than unevaluated.

**Source of version gates:** `VERSION_COMPATIBILITY.md` in the repository root is the authoritative mapping of which checks require which minimum SQL Server version. The orchestrator reads it on demand (not loaded at skill invocation) when version-aware suppression is needed.

**Practical example:** on SQL Server 2016, suppress `NOT ASSESSED` rows for:
- V41–V44 (`sqlwait-review`): PSP selector wait, DOP Feedback wait, ADR PVS, TempDB metadata — all SQL 2019+/2022+
- S34–S36, N67–N70 (`sqlplan-review`): PSP dispatcher, CE Feedback, ADR, DOP feedback nodes — all SQL 2019+/2022+
- Q26–Q32 (`sqlquerystore-review`): IQP/PSP/DOP/CE feedback, QS hints, auto-tuning — SQL 2017–2022
- E29–E32 (`sqlerrorlog-review`): ADR PVS, DOP feedback, Ledger verification, CE feedback — SQL 2019+/2022+
- H23 (`sqlhadr-review`): Contained AG — SQL 2022+
- L28 (`sqlclusterlog-review`): Contained AG system DB offline — SQL 2022+

**Suppression behaviour:** change the row status from `NOT ASSESSED` to `SKIP (version)` in the Check Evaluation Log when `--verbose` is requested. Omit suppressed rows entirely from the standard (non-verbose) report. Do not suppress `NOT ASSESSED` rows caused by missing input data — only suppress when the check version gate exceeds `facts.version`.

**Parsing `facts.version`:** extract the build number (e.g., `13.0.6435.1`) or the version string prefix (`SQL Server 2016`) to determine the major version. The version integer thresholds are: 2008 R2 = 10.5, 2012 = 11, 2014 = 12, 2016 = 13, 2017 = 14, 2019 = 15, 2022 = 16.
