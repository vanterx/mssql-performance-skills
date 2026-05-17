# Paste Results Here — {{RUN_ID}}

Paste the output of each script into the corresponding section below.
Sections that are not filled in will be skipped on `--resume` and reported as Missing Artifacts.

You can either paste the raw output inline, or reference a file path with:

```
FILE: ./path/to/output.txt
```

The orchestrator will read the file at resume time. File references are useful for large `.sqlplan`
XML or `.xel` event files that are easier to keep as separate files than to paste inline.

---

{{PASTE_SECTIONS}}

---

## Notes for the orchestrator

<!-- Optional: anything the orchestrator should know about the captures.
     Examples:
     - "snapshot 1 taken during peak load; snapshot 2 during quiet period"
     - "the plan was captured after the index from yesterday's review was deployed"
     - "this is from the secondary replica, not the primary"
     - "wait stats include backup window — backup started at 02:15" -->



---

## Trust reminder

Everything in this file is local to your machine. The orchestrator only reads it when you run
`/mssql-performance-review --resume ./captures/{{RUN_ID}}/`. Nothing leaves until you share the
generated report.
