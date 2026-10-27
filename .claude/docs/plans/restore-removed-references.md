# Plan — Restore References Removed from the Repository

Status: **Implemented** on branch `ccr-642c296e-io8aa4`.

| Item | Landed as |
|------|-----------|
| B, C | Audit report and plan restored to `.claude/docs/audits/` as historical snapshots; `ms-learn-validation.md` link repointed; README stale line fixed; 13 further pre-existing broken links fixed (`MCP_SERVER_DETAILS.md`, README, `horrible-analysis.md`); new Check 56 (relative Markdown links resolve) in `verify-claims.py` |
| A1 | All `sqlwait-review` credits restored after checking each against its source (SQLskills wait library, `sp_Blitz` / `sp_BlitzFirst` source). The ASYNC_NETWORK_IO "always client-side" claim contradicted MS Learn and is now qualified. New `references/community-practices.md`. The optional V11 named-monitor item was skipped (naming products there adds no evidence) |
| A2 | sp_QuickieStore credit and tip restored. Its parameter names could not be checked (source unreachable from the session), so they carry the Unverified label. The DMV line now names `sys.query_store_query`, the view that holds `query_hash` (verified on MS Learn) |
| A3 | Plan Explorer credit restored; the PR #65 Erik Darling source is credited for S37, S38, N73 and the N2/N10/N35 refinements |
| A4 | Check 51 entries for the sp_Blitz threshold and the sp_QuickieStore parameters; Check 53 sentinel against "always client-side" |

## How this list was built

Every commit on `main` (#1–#75) was checked for three kinds of loss:

1. Deleted or renamed files under `references/`
2. Removed lines that name a person, a community tool or a source site (Paul Randal, Brent Ozar, Erik Darling, SentryOne / Plan Explorer, sp_Blitz, sp_QuickieStore, sqlskills.com and about twenty others)
3. URLs removed by a commit and not added back somewhere else in the same commit

Closed-but-unmerged PRs (#6, #7, #53, #54) were also checked. #6 and #7 have the same head commits as the merged #8 and #9, and #53 and #54 only touched the AgentWorks `example/` folder that #57 removed later. None of them dropped a reference.

### What turned up

| Finding | Commit / PR | Restore? |
|---------|-------------|----------|
| All `references/*.md` files | — | Nothing to restore. Every file that was renamed still exists under its `sql`-prefixed name (#20), and none was deleted |
| 17 person and tool attributions replaced with neutral wording (wait stats, Query Store, plan review) | `c2a906c` (#15) | **Yes**, see A |
| The June 2026 MS Learn audit report (43 cited Learn URLs) stopped being tracked, but `.claude/docs/ms-learn-validation.md:97` still links to it | `321a668` (#48) | **Yes**, see B |
| `LLM_COST_ESTIMATION.md` deleted, but the README still promises "cost management" and a "989-line" `HOW_TO_USE.md` (the file is now 962 lines with no cost section) | `062120c` (#66) | **No.** Fix the stale README sentence (C) |
| AgentWorks docs and URLs (`cli.github.com`, `vanterx/agentworks`) | `012214c` (#64), `3371521` (#57) | No. Removed on purpose along with the feature |

The repo's own policy has changed since #15: #71 added `sqlblocking-review/references/community-practices.md`, which credits Brent Ozar, Paul Randal, Erik Darling, Adam Machanic and others by name, with links. Restoring the #15 credits matches that newer convention. Its rule also applies here: community sources are credited for method and emphasis, and thresholds, DMV columns and syntax follow Microsoft Learn.

---

## A. Restore the attributions removed in #15

**Approach.** Don't put names back into trigger text. Follow the `sqlblocking-review` pattern instead:

- Add one `references/community-practices.md` per affected skill, with a source list.
- Add a short "Based on …" credit line in the `SKILL.md` Purpose section.
- Restore the specific in-line credits where #15 removed a direct quote or a named formula, because there the credit is part of the evidence.

### A1. `sqlwait-review` (14 of the 17 removals)

| Current location | Today | Restore |
|------------------|-------|---------|
| `SKILL.md:3` description, `SKILL.md:14` Purpose | "community wait statistics methodology" | "the Waits and Queues methodology (Tom Davidson's Microsoft whitepaper; Paul Randal, SQLskills; Brent Ozar's First Responder Kit)". Check that the description still passes Checks 22–25 |
| `SKILL.md:54` exclusion-list comment | "based on community wait statistics methodology" | "based on the SQLskills benign-wait list (sqlskills.com/help/waits/)" |
| `SKILL.md:130` heading | "Two-snapshot differential query (recommended approach)" | add "(Paul Randal's recommended approach)" |
| `SKILL.md:393` V18 threshold row and `SKILL.md:797` Limitations | "threshold formula" / "Poison wait threshold" | "Brent Ozar sp_Blitz proportional formula" |
| `SKILL.md:436` V6 ASYNC_NETWORK_IO and `references/check-explanations.md:257-258` | unattributed quote | restore the attributed quote *"ASYNC_NETWORK_IO is never indicative of a problem with SQL Server"* (Paul Randal). Also qualify "always client-side": network latency between the hosts can cause it too. Verify that wording against MS Learn |
| `SKILL.md:457` V11 OLEDB | "third-party monitors" | named examples may come back (SentryOne/SolarWinds SQL Sentry). Optional, low value |
| `SKILL.md:477` LOGMGR_RESERVE_APPEND | "this is very unusual …" | "Paul Randal notes this is very unusual …"; same in `check-explanations.md:557` |
| `SKILL.md:486` V18 severity, `check-explanations.md:613` | "SQL Server community terminology" | "Brent Ozar First Responder Kit (sp_Blitz) terminology" |
| `SKILL.md:784` Limitations | "No universal thresholds exist" | add "(Paul Randal, SQLskills)" |
| `check-explanations.md:140` CXPACKET | "the broader community" | "Paul Randal (SQLskills) and the SQL Server team" |
| `check-explanations.md:293` heading | "Two common misconceptions" | add "(Paul Randal, SQLskills)" |
| `check-explanations.md:633` | "Threshold" | "Threshold (Brent Ozar methodology)" |
| `check-explanations.md:25` | "pioneered by Microsoft's SQL Server team" | keep, but name the 2006 Waits and Queues whitepaper (Tom Davidson) and credit SQLskills for the modern practice |
| `evals/evals.json:13` | "proportional formula" | "Brent Ozar proportional formula" (match the restored SKILL.md text) |
| `scripts/01_capture_wait_stats.sql` | the exclusion-list comment no longer exists (the script was rewritten in #71 and #72) | add a one-line header crediting the SQLskills list |
| `sqlprocstats-review/scripts/collection/06_usp_collect_wait_stats.sql:82` | "Community benign exclusion list" | "Paul Randal / SQLskills benign exclusion list" |
| `README.md:347`, `PERFORMANCE_TUNING_GUIDE.md:227` | "Waits and Queues methodology" | add the same credit as the description |

New file `skills/sqlwait-review/references/community-practices.md` should have these sections:

1. Method summary
2. Tooling map (sp_BlitzFirst `@SinceStartup` and `@Seconds`, sp_Blitz poison waits, the SQLskills waits library, `sys.dm_os_wait_stats` differential)
3. Practitioner rules each V-check encodes
4. Where the advice needs qualifying (CXPACKET vs CXCONSUMER after SQL 2016 SP2 / 2017 CU3, ASYNC_NETWORK_IO network cases)
5. Sources

Add it to `references/README.md` and to the CLAUDE.md Human Reference table.

### A2. `sqlquerystore-review`

- `SKILL.md:18`: "SQL Server community best practices" becomes "patterns from Erik Darling's sp_QuickieStore and the Microsoft Query Store DMV documentation".
- `SKILL.md:152`: keep the native DMV guidance, and add the sp_QuickieStore alternative back as a second option (`@regression_baseline_start_date` / `@regression_baseline_end_date`). Check the parameter names against the current sp_QuickieStore README. sp_QuickieStore is not Microsoft documentation, so the claim takes the `Unverified against Microsoft Learn` label.
- Optional: `references/community-practices.md` (sp_QuickieStore, sp_BlitzQueryStore, Query Store best-practices article on MS Learn).

### A3. `sqlplan-review`

- `SKILL.md:13`: "commercial SQL Server execution plan tools" becomes "the ruleset used by SentryOne Plan Explorer (now SolarWinds Plan Explorer) and similar tools".
- #65 also took rules from an Erik Darling skill review without crediting them. Add that credit to the same Purpose line, or to `references/community-practices.md`.

### A4. Guards

- Add each restored, MS Learn-undocumented community claim (the sp_Blitz poison formula, the sp_QuickieStore parameters) to `UNVERIFIED_CLAIMS` in `scripts/verify-claims.py`, so Check 51 enforces the label.
- If the restored ASYNC_NETWORK_IO wording becomes a duplicated literal across SKILL.md and check-explanations, register it in `DUPLICATED_LISTS`.

---

## B. Restore the MS Learn audit trail removed in #48

`backlog/` is local-only by design (enforced by `.claude/hooks/ensure-gitignore.js`), so the file cannot go back to that path.

- Recover it with `git show 321a668^:backlog/ms-learn-validation-2026-06.md` and commit it to `.claude/docs/audits/ms-learn-validation-2026-06.md`.
- Fix the internal pointer on line 5 (`docs/backlog/ms-learn-validation-plan.md`), either by restoring the plan alongside the report or by dropping the line.
- Repoint the link at `.claude/docs/ms-learn-validation.md:97`.
- Smaller alternative: keep the report untracked and change the link to a permalink of the last commit that had it (`blob/321a668^/backlog/ms-learn-validation-2026-06.md`). That needs no new file, and the 43 source URLs stay reachable.
- Either way, add a verify-docs check that fails on relative Markdown links to files that do not exist. That check would have caught this dangling link.

## C. Stale cost-management claim (fallout from #66)

`README.md:1841` still describes `HOW_TO_USE.md` as "a 989-line guide covering … cost management". Drop "cost management" and the hard-coded line count, which drifts with every edit. Nothing is restored here.

---

## Validation (before merge)

- MS Learn check (mandatory): any restored sentence that makes a technical claim, not only a credit, has to be checked against MS Learn again or carry the label.
- Re-check every external URL (brentozar.com, sqlskills.com, erikdarling.com) resolves.
- `bash scripts/verify-docs.sh` passes. No check counts change, because no checks are added or removed.
- Run `cd mcp-server && npm run bundle` (or rely on the pre-commit hook) so `skills-data.ts` picks up the SKILL.md edits.

## Order

1. B and C: small, mechanical, no policy decision needed.
2. A1 and A4: the bulk of the work, and it sets the pattern.
3. A2 and A3.

Ship as one PR per letter, or one PR overall.
