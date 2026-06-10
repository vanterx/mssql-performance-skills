# Microsoft Learn Validation Report — June 2026

Repo-wide validation of all 20 skills (697 checks) against current Microsoft Learn
documentation, per the mandatory policy in `.claude/docs/ms-learn-validation.md`.
Plan and progress tracker: `docs/backlog/ms-learn-validation-plan.md`.

Method: for each skill, every Microsoft-attributable factual claim in `SKILL.md` and
`references/check-explanations.md` was extracted and verified against pages fetched
from learn.microsoft.com via the Microsoft Learn MCP tools (`microsoft_docs_search`,
`microsoft_docs_fetch`). Inaccuracies were corrected inline; claims that could not be
confirmed in official documentation were marked `[Unverified]`. The repo's own
heuristic thresholds were not treated as Microsoft claims.

Claim categories verified per skill:

1. DMV / catalog view names and column names
2. Wait type names
3. `sp_configure` option names and default values
4. Trace flags and version applicability
5. Version / compatibility-level gates
6. Error numbers and message text
7. T-SQL syntax in capture queries and fix recipes
8. Deprecated-feature claims

---

## Batch 1 — sqldbconfig-review, sqlmemory-review, sqldiskio-review

_Pending._

## Batch 2 — sqlwait-review, sqlquerystore-review, sqlprocstats-review

_Pending._

## Batch 3 — sqlplan-review, sqlencryption-review

_Pending._

## Batch 4 — tsql-review, sqlplan-compare, sqlindex-advisor, sqlstats-review

_Pending._

## Batch 5 — sqlhadr-review, sqlclusterlog-review, sqlerrorlog-review, sqlspn-review, sqldeadlock-review, sqltrace-review

_Pending._

## Batch 6 — mssql-performance-review, sqlplan-batch, VERSION_COMPATIBILITY.md

_Pending._
