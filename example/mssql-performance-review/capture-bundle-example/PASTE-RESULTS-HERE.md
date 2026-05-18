# Paste Results Here — 20260517-0930-cpu-spike

Paste the output of each script into the corresponding section below.
Sections that are not filled in will be skipped on `--resume` and reported as Missing Artifacts.

You can either paste the raw output inline, or reference a file path with:

```
FILE: ./path/to/output.txt
```

The orchestrator will read the file at resume time. File references are useful for large `.sqlplan`
XML or `.xel` event files that are easier to keep as separate files than to paste inline.

---

## 01-wait-stats

<!-- Paste the output of 01-wait-stats.sql here. If you ran the differential
     query, paste both snapshots separated by `---SNAPSHOT 2---` -->

wait_type             waiting_tasks_count  wait_time_ms  signal_wait_time_ms  max_wait_time_ms  pct_total
SOS_SCHEDULER_YIELD   142,221              518,442       18,442               4                 41.34
CXPACKET              82,481               482,221       43,221               142               38.45
PAGEIOLATCH_SH        4,432                184,521       12,331               142               14.71
WRITELOG              9,281                42,118        2,442                21                3.36
LCK_M_S               241                  18,442        221                  1,422             1.47
RESOURCE_SEMAPHORE    18                   8,221         142                  892               0.66

Total wait_time_ms (actionable): 1,253,965
Window duration: ~15 minutes (since prior dbcc sqlperf clear or restart)


## 02-plan-from-cache

<!-- Paste the .sqlplan XML or the result grid here.
     If you have the .sqlplan as a file, you can reference its path instead:
     FILE: ./path/to/plan.sqlplan -->

FILE: ../mixed-artifacts/slow-proc.sqlplan


## 03-query-store-instability

<!-- Paste the result grid here -->

query_id  query_hash      plan_id  plan_hash       avg_duration_us  exec_count  first_execution         last_execution
4221      0xA1B2C3D4E5    8214     0xF0E1D2C3      234,221          1842        2026-04-12 09:00:00     2026-05-17 09:25:00
4221      0xA1B2C3D4E5    8512     0xC4D5E6F7      4,221,221        82          2026-05-15 14:22:00     2026-05-17 09:30:00
4221      0xA1B2C3D4E5    8589     0x12345678      1,442,221        311         2026-05-16 02:14:00     2026-05-17 08:55:00

Note: 3 distinct plans for query_hash 0xA1B2C3D4E5 over 36 days.
Latest plan (8589) shows mid-range duration; intermediate plan (8512) is 18x slower than baseline.


---

## Notes for the orchestrator

<!-- Optional: anything the orchestrator should know about the captures.
     Examples:
     - "snapshot 1 taken during peak load; snapshot 2 during quiet period"
     - "the plan was captured after the index from yesterday's review was deployed"
     - "this is from the secondary replica, not the primary"
     - "wait stats include backup window — backup started at 02:15" -->

Wait stats are cumulative since last server restart 6 days ago (2026-05-11 08:30). Not a 15-minute differential — adjust thresholds accordingly. CPU has been 95% only since 09:00 today; the bulk of the cumulative SOS_SCHEDULER_YIELD is from a known nightly batch.

---

## Trust reminder

Everything in this file is local to your machine. The orchestrator only reads it when you run
`/mssql-performance-review --resume ./captures/20260517-0930-cpu-spike/`. Nothing leaves until you share the
generated report.
