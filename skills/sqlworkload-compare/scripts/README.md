# sqlworkload-compare — Scripts

## capture-workload-windows.sql

Read-only T-SQL that produces the input `/sqlworkload-compare` reads, from one
database's Query Store and the instance's configuration views.

| Part | Returns | Feeds |
|------|---------|-------|
| 1 | One row per `query_hash` that ran in either window: presence (`both`, `baseline only`, `current only`), executions, execution-weighted average and maximum duration, average CPU and logical reads, totals, executions per minute, aborted executions, and a sample of the text | WC1–WC10 |
| 1 | Window lengths and Query Store state (`actual_state_desc`, `query_capture_mode_desc`, `interval_length_minutes`) | WC1, WC5 |
| 2 | Server properties (version, level, update level, edition), `cpu_count`, `physical_memory_kb`, `sys.configurations` `value_in_use`, database options, database-scoped configurations | WC11–WC13 |
| 3 | A timestamped `sys.dm_os_wait_stats` snapshot | WC14 |

### Usage

1. Open the script in the database being compared.
2. Set `@baseline_start`, `@baseline_end`, `@current_start`, `@current_end` (`datetimeoffset`, so include the offset). Align them to the Query Store interval length — an interval that only partly overlaps a window is excluded.
3. Run it and paste all result sets into `/sqlworkload-compare`.

### What it cannot do

- **Configuration history.** Parts 2 and 3 describe the instance now. For a before-and-after change, run them before the change too and paste both.
- **Past wait statistics.** `sys.dm_os_wait_stats` is cumulative since startup. Run Part 3 at the start and end of a live window on each side.
- **Queries Query Store did not capture.** With `query_capture_mode_desc = AUTO`, infrequent or cheap queries can be absent from one side.

### Requires

`VIEW DATABASE STATE` (SQL Server 2019 and earlier) or `VIEW DATABASE PERFORMANCE
STATE` (SQL Server 2022 and later) in the target database, and `VIEW SERVER STATE`
or `VIEW SERVER PERFORMANCE STATE` for `sys.dm_os_sys_info` and
`sys.dm_os_wait_stats`. Part 1 needs SQL Server 2016 or later with Query Store on.
Run it under a dedicated least-privilege login rather than `sa`.
