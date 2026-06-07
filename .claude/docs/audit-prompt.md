# MS Learn Accuracy Audit — Reusable Prompt

Copy the block below and paste it as a user message to run a full repository audit.
Run this periodically (e.g., after adding new skills, after a SQL Server version release, or before cutting a release branch).

---

## Prompt

```
# Comprehensive Validation and Accuracy Audit

Use Microsoft Learn MCP as the authoritative source for validation.

Audit the entire mssql-performance-skills repository against current Microsoft documentation.
Every skill, script, query, configuration, reference file, and supporting document must be reviewed.

## Scope

- All 19 skills: every SKILL.md, references/check-explanations.md, scripts/, examples/
- Root documentation: CLAUDE.md, README.md, PERFORMANCE_TUNING_GUIDE.md, LLM_COST_ESTIMATION.md, skills/VERSION_COMPATIBILITY.md
- .claude/docs/ files

## What to Validate

For every claim in every file:

1. **DMV / catalog view columns** — verify the column exists on that view in the stated SQL Server version
2. **Enum / integer values** — verify all valid values and their meanings (e.g., execution_type, encryption_state)
3. **T-SQL syntax and built-in functions** — verify supported arguments, return types, version availability
4. **PowerShell cmdlets and parameters** — verify parameter names and syntax
5. **Registry key names and value names** — verify exact names
6. **Feature version gates** — verify the SQL Server / Windows Server version where each feature was introduced
7. **Deprecated / removed features** — flag anything deprecated or removed in recent versions
8. **Script logic** — verify that queries would actually execute without error (correct joins, column references, syntax)

## Issue Report Format

For every issue found, report:

| Field | Value |
|---|---|
| File | path/to/file.md |
| Line | line number |
| Severity | Critical / High / Medium / Low |
| Current content | exact text as written |
| Validation result | what MS Learn says |
| MS source URL | the Learn article or DMV reference page used |
| Recommended correction | the exact fix |

Severity guide:
- **Critical** — query would fail at runtime, wrong enum value, non-existent column
- **High** — incorrect behavior, wrong version gate, deprecated feature used as current
- **Medium** — misleading description, inaccurate threshold, missing qualifier
- **Low** — stale range reference, minor wording inaccuracy

## Process

1. Generate a fresh skill inventory first: `bash scripts/generate-inventory.sh`
   This gives a flat list of every DMV, version claim, and function reference with file:line citations.

2. Use `microsoft_docs_search` for a quick first pass on each item.
   Use `microsoft_docs_fetch` when you need the full column list or parameter table.

3. Work through sections in this priority order:
   a. DMV column references (highest risk — silent wrong results)
   b. Enum / integer values
   c. Version gates
   d. T-SQL syntax / function arguments
   e. PowerShell / registry / configuration
   f. Deprecated feature usage

4. Apply all fixes directly. Run `bash scripts/verify-docs.sh` after each skill.

5. Commit with: `fix(audit): correct N technical inaccuracies validated against MS Learn`

## Completion Criteria

- Every item in the generated inventory has been validated or marked "Unverified"
- `bash scripts/verify-docs.sh` exits 0
- All Critical and High issues resolved
- Commit created
```

---

## Last Run

**Date:** 2026-06-06 / 2026-06-07
**Issues found:** 25
**Issues resolved:** 25 (all Critical and High)

### Summary of fixes (2026-06-06/07 audit)

| Skill | Fix | Severity |
|---|---|---|
| sqlquerystore-review | `execution_type` 1/2 → 3/4 (aborted=3, exception=4) | Critical |
| sqlquerystore-review | `sys.query_store_plan_feedback` columns: `feedback_type` → `feature_desc` (Q26–Q29) | Critical |
| sqlquerystore-review | `sys.query_store_query_hints` failure columns corrected (Q31) | Critical |
| sqlquerystore-review | PSP detection via `plan_type_desc` not `plan_feedback` (Q26) | Critical |
| sqlencryption-review | `CERTPROPERTY('Algorithm')` always returns NULL — removed all references | Critical |
| sqlencryption-review | `sys.symmetric_keys.pvt_key_encryption_type_desc` does not exist — rewrote capture query via `sys.key_encryptions` OUTER APPLY | Critical |
| sqlencryption-review | `ForceEncryption` registry `value_name`: was `'Encrypt'` | High |
| sqlencryption-review | `crypt_type_desc` values use spaces not underscores (A19) | High |
| sqlencryption-review | `algorithm_desc` casing: `'Triple_DES'` not `'TRIPLE_DES'` (A17, A55) | High |
| sqlencryption-review | `encryption_state` = 6 (encryptor change) was missing from A2 | High |
| sqlencryption-review | SQLNCLI11 deprecated → MSOLEDBSQL, Encrypt=Mandatory (A48) | High |
| sqlspn-review | K1: portless SPN form `MSSQLSvc/<FQDN>` was not documented | Medium |
| sqlspn-review | K27: Protected Users protections require WS2012R2+ domain functional level | Medium |
| sqlspn-review | K30: service account in Protected Users *will* cause auth failure (not "may") | Medium |
| sqlwait-review | CXCONSUMER version label: "SQL 2016 SP2 CU3+" → "SQL 2016 SP2+ / SQL 2017 CU3+" | Medium |
| sqltrace-review | ring_buffer `max_memory`: 100 MB → 4 MB + `max_events_limit = 1000` | Medium |
| sqlindex-advisor | Impact formula: added `user_scans`, removed incorrect `/100.0` divisor | Medium |
| sqlhadr-review | `secondary_lag_seconds`: SQL Server 2016+ only, version gate added | Medium |
| sqldeadlock-review | `xml_deadlock_report` in `system_health`: SQL 2012+, not 2008+ | Medium |
| sqlerrorlog-review | E16: added Msg 823 (Critical) / 824 (Critical) / 825 (Warning) | Medium |
| sqlclusterlog-review | CLUSTER.LOG path: live vs Get-ClusterLog output path distinction | Low |
| sqlclusterlog-review | `Get-ClusterLog -Node *` invalid — omit `-Node` to collect all nodes | Low |
| sqlplan-review | Stale check ranges: S1–S33/N1–N66 → S1–S36/N1–N72 | Low |
| tsql-review | Stale check range: T1–T50 → T1–T85 | Low |
| sqlplan-compare | Stale check count: "99-check" → "108-check" | Low |
