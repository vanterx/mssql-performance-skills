# sqlplan-review — Scripts

Two kinds of script live here: **capture** scripts that pull a plan out of a live
instance, and **extractors** that flatten a `.sqlplan` file into the digest
`SKILL.md` analyses.

## Extractors

| File | Runtime | Use when |
|------|---------|----------|
| [extract_plan.py](extract_plan.py) | Python 3.8+, standard library only | Default |
| [Extract-SqlPlan.ps1](Extract-SqlPlan.ps1) | PowerShell 5.1 or 7+, no modules | No Python on the host |

Both produce **byte-identical output**. Pick whichever the host has.

```bash
python extract_plan.py plan.sqlplan              # the digest
python extract_plan.py plan.sqlplan --top 20     # widen ranked sections
python extract_plan.py plan.sqlplan --node 16    # one operator, full detail
python extract_plan.py plan.sqlplan --sql        # untruncated statement text
```

```powershell
pwsh -File Extract-SqlPlan.ps1 -Path plan.sqlplan
pwsh -File Extract-SqlPlan.ps1 -Path plan.sqlplan -Top 20
pwsh -File Extract-SqlPlan.ps1 -Path plan.sqlplan -Node 16
pwsh -File Extract-SqlPlan.ps1 -Path plan.sqlplan -Sql
pwsh -File Extract-SqlPlan.ps1 -Path plan.sqlplan -Sql -Statement 1
```

A `[string]` parameter cannot be passed bare in PowerShell, so `-Sql` is a
switch and `-Statement` scopes it to one `StatementId`. That is the only
command-line difference between the two.

### Why a tool rather than reading the XML

- **Encoding.** SSMS writes `.sqlplan` as UTF-16. `grep`, `rg` and `findstr`
  match nothing on it and report no error, so a negative text search on a plan
  file proves nothing. A plan that has been opened and re-saved is frequently
  UTF-8 bytes still declaring `encoding="utf-16"`, which strict XML parsers
  reject. Both tools detect the encoding from the bytes and ignore the prolog.
- **Size.** A trivial two-table join is ~120 KB; production plans reach
  megabytes. Reading one into an agent's context crowds out the analysis and
  still misses attributes scattered over thousands of lines.
- **Arithmetic.** Row-mode `ActualElapsedms` and `ActualCPUms` are cumulative —
  they include the operator's whole subtree — while batch-mode operators report
  standalone times, exchange operators accumulate downstream wait time, and
  pass-through operators such as Compute Scalar carry no counters at all.
  Subtraction must happen *within* a thread, and the coordinator (thread 0) must
  be excluded because its elapsed time is the whole parallel branch's wall
  clock. Approximating any of this yields answers that are confident, precise,
  and inverted.

### Digest sections

Ordered to match `SKILL.md`'s check sequence:

| Section | Feeds |
|---------|-------|
| PLAN TYPE | S5, S6, S7, S10, S31, S33, S37 — and gates every actual-only check |
| WARNINGS | Spills, implicit conversions, missing statistics, grant warnings |
| MEMORY GRANT | S2, S3, S4 |
| PARAMETERS | S9 parameter sniffing, plus the four-pattern sniffing table |
| TOP OPERATORS BY SELF ELAPSED | N62 (actual plans) |
| TOP OPERATORS BY ESTIMATED SELF COST | N24 (estimated plans only) |
| SAME OBJECT ACCESSED MORE THAN ONCE | CTE / view / inline TVF re-expansion |
| CARDINALITY SKEW (per execution) | N13, N21, N35 |
| PARALLEL THREAD SKEW | N63 |
| TOP WAITS | S38 |
| PREDICATES ON CITED OPERATORS | N4, N10, N73, eager index spools |
| OPERATOR TREE | Plan shape — the only signal on an estimated plan |
| MISSING INDEX REQUESTS | S27, N2 |

### Safety

A `.sqlplan` is a file someone else hands you, and `SKILL.md` requires its
strings be treated as data. Both extractors:

- refuse a file over **64 MB** before reading it, because parsed size runs
  several times the byte size;
- strip C0, DEL and C1 control characters from every plan-derived string, so a
  crafted object name cannot inject newlines and forge the digest's own section
  headers (XML attribute normalisation preserves character references);
- bound operator-tree depth and fail with a readable message instead of a stack
  trace;
- never resolve external XML entities;
- write errors to stderr and exit non-zero, printing no partial digest.

## Capture scripts

| File | Purpose |
|------|---------|
| [01_capture_from_cache.sql](01_capture_from_cache.sql) | Pull a cached plan from `sys.dm_exec_query_plan` |
| [02_capture_running_query.sql](02_capture_running_query.sql) | Grab the plan of a query executing right now |
| [03_capture_query_store_plan.sql](03_capture_query_store_plan.sql) | Retrieve a plan from Query Store by `query_id` |

Save the `query_plan` column to a `.sqlplan` file, then run an extractor over it.
A plan captured from the cache or Query Store frequently carries **no statement
text**, and `StatementText` can be truncated by SQL Server — reason from the
plan, and use the text only to confirm what the plan already showed.
