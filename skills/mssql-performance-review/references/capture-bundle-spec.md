# Capture Bundle Specification (V1')

When the orchestrator detects missing artifacts (or the user invokes `/sql-triage` with no artifacts), it generates a self-contained **capture bundle** — a directory of read-only `.sql` scripts plus a README, paste-back template, and manifest. The user runs the scripts against their SQL Server (the orchestrator never contacts the server). Results paste back into the template. The orchestrator resumes when invoked with `--resume`.

## Trust model

| Action | Orchestrator | User |
|--------|--------------|------|
| Generate `./captures/<run-id>/` directory | Yes | No |
| Copy capture scripts from `skills/<name>/scripts/` into the bundle | Yes | No |
| Write README, manifest.json, PASTE-RESULTS-HERE.md | Yes | No |
| Execute the `.sql` scripts | **Never** | Yes |
| Write paste-back content into PASTE-RESULTS-HERE.md | No | Yes |
| Read PASTE-RESULTS-HERE.md on `--resume` | Yes | No |

The orchestrator's writes are confined to `./captures/<run-id>/` (the bundle directory) and `./state/<run-id>/` (the analysis state). It does not modify the user's tooling, SQL Server, or paste-back content.

## Bundle directory layout

```
./captures/<run-id>/
├── README.md                       # Run order, paste-back instructions, security notes, time estimates
├── 01-wait-stats.sql               # Copy of skills/sqlwait-review/scripts/01_capture_wait_stats.sql
├── 02-plan-from-cache.sql          # Copy of skills/sqlplan-review/scripts/01_capture_from_cache.sql
├── 03-query-store-instability.sql  # Copy of skills/query-store-review/scripts/01_capture_queries.sql
├── PASTE-RESULTS-HERE.md           # Template with section per script
└── manifest.json                   # Machine-readable bundle metadata
```

`<run-id>` follows the format `YYYYMMDD-HHMM-<short-symptom>` (e.g., `20260517-0930-cpu-spike`). The user can rename the directory; `--resume` works on directory path, not the run-id.

## Curation rules (per hypothesis class)

Not all 27 available capture scripts every time — the orchestrator curates 3–5 scripts that target the active hypotheses.

| Hypothesis | Curated scripts |
|------------|-----------------|
| Parameter sniffing | wait stats, plan-from-cache for top consumer, query-store plan history |
| Missing index | plan-from-cache, sqlstats output template, sys.dm_db_missing_index_* extract |
| Server-wide I/O | wait stats, sys.dm_io_virtual_file_stats, top reader plan |
| Lock / blocking | sys.dm_exec_requests, sys.dm_tran_locks, blocked process report |
| Deadlock loop | system_health XE reader, dedicated XE session setup (optional) |
| AG / failover | ERRORLOG read query, Get-ClusterLog command, hadr DMV query set |
| Kerberos auth | setspn -L command, Get-ADUser/Get-ADComputer commands, ERRORLOG login filter |
| Mystery slowness | wait stats only (cheapest), then re-route based on results |
| Workload regression | query-store top regressed queries, plan-from-cache for top, plan-from-query-store baseline |

The curation runs after hypothesis generation in tier 1 — the same hypothesis ranking that informs probe dispatch also drives bundle composition. Low-ranked hypotheses get one confirmation script; high-ranked hypotheses get the full probe sequence.

Budget guard: if total estimated paste-back size would exceed ~50,000 tokens, the orchestrator emits a smaller bundle and warns the user that follow-up bundles may be needed.

## README template

`assets/bundle-readme-template.md` is the source template. The orchestrator fills in placeholders. The emitted README structure:

```markdown
# Capture Bundle — <run-id>

Generated: <ISO timestamp>
Symptom: <user's symptom description, if any>
Hypotheses being probed:
1. <hypothesis 1 — initial confidence>
2. <hypothesis 2 — initial confidence>
3. <hypothesis 3 — initial confidence>

## What this is

This bundle is a self-contained set of read-only SQL scripts and a paste-back template. The orchestrator generated it because the original input did not contain enough information to confirm or refute the hypotheses above.

**The orchestrator will not contact your SQL Server.** You run these scripts yourself (SSMS, sqlcmd, your tool of choice) and paste the results back.

## Security notes

- All scripts are SELECT-only against system DMVs and (optionally) the default trace.
- No script modifies state, alters configuration, or writes to user data.
- Output files may contain query text and DMV data — review for sensitive content before sharing.
- Scripts are copies of the same files in this repository at `skills/<name>/scripts/` (cited in manifest.json) — diff if you want to verify equivalence.

## Run order

1. **`01-wait-stats.sql`** (estimated 1 sec, ~800 tokens of output)
   - Purpose: confirm bottleneck class (CPU vs I/O vs lock vs memory vs compilation).
   - Run twice with 15 minutes between for a differential window. Paste both outputs.
   - Paste section: `## 01-wait-stats` in PASTE-RESULTS-HERE.md

2. **`02-plan-from-cache.sql`** (estimated 5 sec, ~8,000 tokens of output)
   - Purpose: get the execution plan for the top CPU consumer (after step 1 identifies it).
   - Edit the WHERE clause to filter to the top consumer's object_name.
   - Paste section: `## 02-plan-from-cache`

3. **`03-query-store-instability.sql`** (estimated 2 sec, ~2,000 tokens of output)
   - Purpose: confirm whether the query has multiple plans (parameter sniffing signal).
   - Edit the WHERE clause to filter to the query_hash of the top consumer.
   - Paste section: `## 03-query-store-instability`

## Resume

Once results are pasted into PASTE-RESULTS-HERE.md:

    /mssql-performance-review --resume ./captures/<run-id>/

The orchestrator will route each section to the right specialised skill and produce the full report.

## If you can only run step 1 now

That's fine. Re-invoke `--resume` after step 1 only — the orchestrator will give you a partial report and tell you which next scripts will most improve confidence.
```

## PASTE-RESULTS-HERE.md template

`assets/paste-results-template.md`. Emitted structure:

```markdown
# Paste Results Here — <run-id>

Paste the output of each script into the corresponding section below.
Sections that are not filled in will be skipped on `--resume`.

## 01-wait-stats

<!-- Paste the output of 01-wait-stats.sql here. If you ran the differential
     query, paste both snapshots separated by `---SNAPSHOT 2---` -->



## 02-plan-from-cache

<!-- Paste the .sqlplan XML or the result grid here.
     If you have the .sqlplan as a file, you can reference its path instead:
     FILE: ./path/to/plan.sqlplan -->



## 03-query-store-instability

<!-- Paste the result grid here -->



---

## Notes for the orchestrator

<!-- Optional: anything the orchestrator should know about the captures.
     For example: "snapshot 1 taken during peak load; snapshot 2 during quiet period" -->
```

## manifest.json schema

```json
{
  "run_id": "20260517-0930-cpu-spike",
  "generated_at": "2026-05-17T09:30:00+12:00",
  "orchestrator_version": "v4-tier3",
  "symptom": "CPU pegged at 95% on PROD-SQL01 since 09:00, no recent deploy",
  "instance": "PROD-SQL01",
  "hypotheses": [
    {"rank": 1, "class": "runaway_query", "confidence_initial": "MEDIUM"},
    {"rank": 2, "class": "parameter_sniffing", "confidence_initial": "MEDIUM"},
    {"rank": 3, "class": "compile_pressure", "confidence_initial": "LOW"}
  ],
  "scripts": [
    {
      "filename": "01-wait-stats.sql",
      "source": "skills/sqlwait-review/scripts/01_capture_wait_stats.sql",
      "target_skill": "sqlwait-review",
      "paste_section": "01-wait-stats",
      "estimated_run_time_sec": 1,
      "estimated_output_tokens": 800,
      "purpose": "Confirm bottleneck class",
      "depends_on": null
    },
    {
      "filename": "02-plan-from-cache.sql",
      "source": "skills/sqlplan-review/scripts/01_capture_from_cache.sql",
      "target_skill": "sqlplan-review",
      "paste_section": "02-plan-from-cache",
      "estimated_run_time_sec": 5,
      "estimated_output_tokens": 8000,
      "purpose": "Plan for top CPU consumer",
      "depends_on": "01-wait-stats"
    },
    {
      "filename": "03-query-store-instability.sql",
      "source": "skills/query-store-review/scripts/01_capture_queries.sql",
      "target_skill": "query-store-review",
      "paste_section": "03-query-store-instability",
      "estimated_run_time_sec": 2,
      "estimated_output_tokens": 2000,
      "purpose": "Confirm plan instability for top consumer",
      "depends_on": "01-wait-stats"
    }
  ],
  "trust_notes": [
    "Orchestrator does not contact the SQL Server.",
    "All scripts are SELECT-only against system DMVs.",
    "Output files contain query text and DMV data — review for sensitive content before sharing."
  ],
  "estimated_total_output_tokens": 10800,
  "estimated_resume_cost_usd": 0.04
}
```

### Field rules

| Field | Required | Validation |
|-------|----------|-----------|
| `run_id` | Yes | Matches directory name |
| `generated_at` | Yes | ISO 8601 timestamp |
| `orchestrator_version` | Yes | Used by `--resume` to handle backward compatibility |
| `symptom` | Optional | Verbatim user description; null for artifact-driven bundles |
| `instance` | Optional | Loaded from domain memory or detected from artifacts |
| `hypotheses[]` | Yes | At least 1 hypothesis with rank, class, confidence_initial |
| `scripts[]` | Yes | At least 1 script; each must have filename, source, target_skill, paste_section |
| `scripts[].source` | Yes | Path relative to repo root; orchestrator copies from this path |
| `scripts[].target_skill` | Yes | Skill name that will consume this output |
| `scripts[].paste_section` | Yes | Section heading in PASTE-RESULTS-HERE.md (without `## ` prefix) |
| `scripts[].depends_on` | Optional | Filename of script whose output is needed to edit this one (e.g., filtering by top consumer) |
| `trust_notes[]` | Yes | At least one note stating orchestrator does not contact SQL Server |

## Resume flow

When the user invokes `/mssql-performance-review --resume ./captures/<run-id>/`:

1. **Validate bundle integrity**
   - manifest.json exists and parses
   - Every script in manifest exists in the directory
   - PASTE-RESULTS-HERE.md exists
2. **Parse paste-back content**
   - Extract each section's content (between `## <paste_section>` headers)
   - Validate that every section in manifest has content; warn about empty sections
   - Extract `FILE: <path>` references — load those files as the content
3. **Route to sub-skills**
   - For each section with content, dispatch the target_skill subagent with the content as input
   - Sections without content are skipped; entered as Missing Artifacts in the report
4. **Continue normal flow**
   - Hypothesis loop with updated confidence
   - Adversarial check
   - Synthesis + report

If `manifest.orchestrator_version` differs from current, the orchestrator handles backward compatibility — adding default fields for newer versions. If a future version drops fields, the orchestrator warns and asks for re-bundling.

## Capture-instance-facts variant

A specialised bundle for V9 domain memory population:

```
/sql-triage --capture-instance-facts
```

Emits a single bundle (`./captures/instance-facts-<run-id>/`) containing one SQL script that surveys instance configuration (sys.configurations, sys.dm_os_sys_info, sys.availability_groups, sys.partition_functions, etc.) and a paste-back template structured for parsing into the facts.json schema.

The orchestrator on resume parses the paste-back into a draft facts.json and shows it to the user for review before suggesting save path (`~/.mssql-perf-review/instances/<server>.json`). The user copies the JSON manually — the orchestrator never writes to that location.

## Bundle history and re-bundling

Each `--resume` writes `./state/<run-id>/` with the analysis report and evidence chain. The capture bundle remains in `./captures/<run-id>/` unchanged for reproducibility.

If the user re-runs the analysis with the same bundle, the orchestrator detects the existing state directory and asks whether to re-analyse or load the prior state. Re-bundling for the same incident generates a new `<run-id>` so prior bundles are preserved.

Bundles older than 30 days emit a warning on resume — the captured data may be stale relative to current symptoms.

## Why this design

| Decision | Rationale |
|----------|-----------|
| Bundle is self-contained (scripts copied, not symlinked) | User can move/email it; no external dependencies |
| `manifest.json` required | Resume needs machine-readable mapping; without it, the bundle is illegible to the orchestrator |
| Trust notes in every bundle | Reinforces the offline guarantee at the user's point of decision (when running the scripts) |
| Per-hypothesis curation, not all-scripts | Cost-aware; reduces paste-back token volume; user is more likely to run a focused set |
| `depends_on` field in manifest | Some scripts need filtering edits based on prior script output; the orchestrator surfaces this dependency to the user in the README |
| Sections in paste-back optional | Partial captures are acceptable; the orchestrator reports what was missing rather than refusing to proceed |
| Bundles outside the repo | `./captures/` is gitignored; user-specific data |
