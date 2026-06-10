# Backlog: Repo Improvement + Microsoft Learn Validation Pass

> Status: **in progress** — started 2026-06-10 on branch `claude/repo-improvements-validation-f1z3ks`.
> This document is the durable plan + progress tracker for the repo-wide Microsoft Learn
> validation pass. Update the Progress tracker table in the same commit as each batch's fixes.

## Context

The repo's validation policy (`.claude/docs/ms-learn-validation.md`) mandates that every
check, skill, script, and reference be validated against current Microsoft Learn
documentation. The last recorded audit (June 2026, ~25 corrections) predates recent
additions (`sqldbconfig-review`, sqlencryption extensions, new version-gated checks).
This pass validates **every check and skill** against the Microsoft Learn MCP and official
Microsoft documents.

Confirmed scope:

- **Depth:** all 20 `SKILL.md` files (697 checks) **and** every
  `references/check-explanations.md`. The sqlencryption howto/scripts files get
  spot-checks only.
- **Deliverable:** fix inaccuracies inline, mark undocumentable claims `[Unverified]`,
  and commit a per-skill validation report (`docs/ms-learn-validation-2026-06.md`).

## Phase A — Fix known documentation discrepancies

Stale counts found during exploration (actual: **20 skills, 697 checks**):

| File | Stale text | Fix |
|------|-----------|-----|
| `CLAUDE.md` | orchestrator row: "Routes mixed artifacts to the 15 specialised skills" | use the actual routed-skill count from `skills/mssql-performance-review/SKILL.md` |
| `CLAUDE.md` | plugin.json row: "all 18 SKILL.md files" | 20 |
| `CLAUDE.md` | "613-check ID reference" (PERFORMANCE_TUNING_GUIDE row) | 697 |
| `CLAUDE.md` | VERSION_COMPATIBILITY row: "which of the 669 checks" | 697 |
| `skills/VERSION_COMPATIBILITY.md` | "460 of 669 checks" | re-derive both figures |
| `.claude-plugin/plugin.json` | "16 SQL Server performance tuning skills" | 20 skills / 697 checks |
| `.claude-plugin/marketplace.json` | "520 checks across 16 skills" | 697 / 20 |

Improvement: add checks to `scripts/verify-docs.sh` asserting that skill/check counts in
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` match actuals.

## Phase B — Microsoft Learn validation of all 20 skills

### Claim categories to verify (in both SKILL.md and references/check-explanations.md)

1. DMV / catalog view names and **column names** (~157 distinct `sys.*` objects repo-wide)
2. Wait type names (esp. version-gated: CXCONSUMER, CXSYNC_*, LOG_RATE_GOVERNOR, ...)
3. `sp_configure` option names and default values
4. Trace flags and their version applicability (TF 1118, TF 3468, ...)
5. Version / compat-level gates ("SQL 2019+", "compat 160", BPE removed in 2022, ...)
6. Error numbers and message text (Msg 701, 33111, 15581, ...)
7. T-SQL syntax in fix recipes; PowerShell cmdlets in sqlencryption scripts (spot-check)
8. Deprecated-feature claims

Microsoft-attributed thresholds get verified; the repo's own heuristic thresholds
(e.g., "PLE < 300") are treated as heuristics, not flagged as errors.

### Rules for fixes

- Fixes go in **both** SKILL.md and check-explanations.md when both state the claim.
- Do **not** add/remove checks — counts stay at 697 so verify-docs.sh stays green.
  If a check is fundamentally wrong, correct its trigger/fix content; escalate to the
  user only if a check would need removal.
- Anything not findable in Microsoft Learn gets marked `[Unverified]`.
- Never introduce `$0`/`$3`-style dollar patterns in SKILL.md.
- No bare ALWAYS/NEVER/MUST in SKILL.md body.
- If a version gate changes, update `skills/VERSION_COMPATIBILITY.md` in the same commit.

### Progress tracker

Statuses: `pending` → `in progress` → `validated` → `committed`

| Batch | Skills (check count) | Status |
|-------|----------------------|--------|
| Phase A | metadata count fixes + verify-docs.sh manifest checks | committed |
| B1 — newest/least-audited | sqldbconfig-review (28), sqlmemory-review (20), sqldiskio-review (15) | committed |
| B2 — high claim density | sqlwait-review (44), sqlquerystore-review (32), sqlprocstats-review (25) | pending |
| B3 — largest | sqlplan-review (108), sqlencryption-review (112, incl. howto/scripts spot-check) | pending |
| B4 — T-SQL/plan | tsql-review (85), sqlplan-compare (20), sqlindex-advisor (10), sqlstats-review (27) | pending |
| B5 — infra/HA | sqlhadr-review (27), sqlclusterlog-review (30), sqlerrorlog-review (33), sqlspn-review (40), sqldeadlock-review (16), sqltrace-review (25) | pending |
| B6 — dispatchers + cross-file | mssql-performance-review, sqlplan-batch (methodology only), VERSION_COMPATIBILITY.md version-gate rows | pending |

### Validation report

`docs/ms-learn-validation-2026-06.md` — one section per skill: claims checked (by
category, with counts), MS Learn source URLs used, corrections made (before → after),
`[Unverified]` items, date. Also update the audit history in
`.claude/docs/ms-learn-validation.md`.

## Phase C — Wrap-up

1. `bash scripts/verify-docs.sh` must exit 0.
2. Regenerate the MCP bundle (`cd mcp-server && npm run bundle`) — never hand-edit
   `skills-data.ts`.
3. Commit per batch with descriptive messages; push to
   `claude/repo-improvements-validation-f1z3ks`. No PR unless requested.

## Verification

- verify-docs.sh green after every batch.
- Per batch: re-fetch one cited MS Learn page and confirm corrected text matches it.
- `git diff --stat` before each commit; check-ID counts per skill unchanged.
- `npm run bundle` produces no further diff after the final commit.
