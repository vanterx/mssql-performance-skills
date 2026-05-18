# Capture Bundle — {{RUN_ID}}

Generated: {{TIMESTAMP}}
Instance: {{INSTANCE_OR_UNKNOWN}}
Symptom: {{SYMPTOM_OR_ARTIFACT_DRIVEN}}

Hypotheses being probed:
{{HYPOTHESIS_LIST}}

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

{{SCRIPT_LIST_WITH_PURPOSE_AND_PASTE_SECTION}}

## Resume

Once results are pasted into `PASTE-RESULTS-HERE.md`:

```
/mssql-performance-review --resume ./captures/{{RUN_ID}}/
```

The orchestrator will route each section to the right specialised skill and produce the full report.

## If you can only run some scripts now

That is fine. Re-invoke `--resume` after running any subset — the orchestrator will give you a partial report and tell you which remaining scripts will most improve confidence.

## Estimated paste-back size

Total estimated output: ~{{TOTAL_OUTPUT_TOKENS}} tokens (~{{TOTAL_OUTPUT_KB}} KB).
Estimated orchestrator cost on resume: ~USD {{ESTIMATED_RESUME_COST}}.

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
