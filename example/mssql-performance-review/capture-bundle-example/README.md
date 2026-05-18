# Capture Bundle — 20260517-0930-cpu-spike

Generated: 2026-05-17T09:30:14+12:00
Instance: PROD-SQL01
Symptom: CPU pegged at 95% on PROD-SQL01 since 09:00, no recent deploy

Hypotheses being probed:
1. Runaway query (MEDIUM confidence) — one workload consuming most CPU
2. Parameter sniffing (MEDIUM confidence) — plan-cache flush exposed dormant sniffing
3. Compile pressure (LOW confidence) — many distinct queries recompiling

---

## What this is

This bundle is a self-contained set of read-only SQL scripts and a paste-back template. The orchestrator generated it because the original input did not contain enough information to confirm or refute the hypotheses above.

**The orchestrator will not contact your SQL Server.** You run these scripts yourself (SSMS, sqlcmd, your tool of choice) and paste the results back into `PASTE-RESULTS-HERE.md`.

## Security notes

- All scripts are SELECT-only against system DMVs.
- No script modifies state, alters configuration, or writes to user data.
- Output files may contain query text and DMV data — review for sensitive content before sharing.
- Scripts are copies of files in this repository at `skills/<name>/scripts/` (paths cited in `manifest.json`). Diff if you want to verify equivalence.

## Run order

1. **`01-wait-stats.sql`** (estimated 1 sec, ~800 tokens of output)
   - Purpose: confirm bottleneck class (CPU vs I/O vs lock vs memory vs compilation).
   - Run once now. Optionally run again in 15 minutes for a differential window; paste both outputs with `---SNAPSHOT 2---` separator.
   - Paste section: `## 01-wait-stats` in PASTE-RESULTS-HERE.md
   - Depends on: nothing

2. **`02-plan-from-cache.sql`** (estimated 5 sec, ~8,000 tokens of output)
   - Purpose: get the execution plan for the top CPU consumer.
   - **Edit the WHERE clause** to filter to the top consumer's object_name from step 1 (look for the procedure or query_hash with highest CPU in the wait-stats output's adjoining `sys.dm_exec_requests` section).
   - Paste section: `## 02-plan-from-cache`
   - Depends on: 01-wait-stats (need the top consumer's name)

3. **`03-query-store-instability.sql`** (estimated 2 sec, ~2,000 tokens of output)
   - Purpose: confirm whether the query has multiple plans (parameter sniffing signal).
   - **Edit the WHERE clause** to filter to the query_hash of the top consumer from step 1.
   - Paste section: `## 03-query-store-instability`
   - Depends on: 01-wait-stats (need the query_hash)

## Resume

Once results are pasted into `PASTE-RESULTS-HERE.md`:

```
/mssql-performance-review --resume ./captures/20260517-0930-cpu-spike/
```

The orchestrator will route each section to the right specialised skill and produce the full report.

## If you can only run some scripts now

That is fine. Re-invoke `--resume` after running any subset — the orchestrator will give you a partial report and tell you which remaining scripts will most improve confidence.

For this bundle, the minimal useful set is **just 01-wait-stats.sql**. That alone tells the orchestrator whether the bottleneck is CPU (confirming hypothesis 1), I/O (refuting and re-routing), or compilation (confirming hypothesis 3).

## Estimated paste-back size

Total estimated output: ~10,800 tokens (~41 KB).
Estimated orchestrator cost on resume: ~USD 0.04 (Haiku triage + Sonnet plan deep-dive + Opus adversarial).

## Trust model

| Action | Orchestrator | You |
|--------|--------------|-----|
| Generate this bundle | Yes | No |
| Write scripts and README into this directory | Yes | No |
| Connect to SQL Server | **Never** | Yes |
| Execute the scripts | **Never** | Yes |
| Paste results into PASTE-RESULTS-HERE.md | No | Yes |
| Read PASTE-RESULTS-HERE.md on `--resume` | Yes | No |

Everything in this directory is local to your machine. Nothing leaves until you choose to share the report.
