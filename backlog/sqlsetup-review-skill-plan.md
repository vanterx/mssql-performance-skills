# Backlog: New Skill — sqlsetup-review (SQL Server Setup Log Analysis)

> Status: **implemented** 2026-06-11 as `sqlbootstraplog-review` (renamed from the planned
> `sqlsetup-review` to match the Setup Bootstrap\Log folder and the repo's `*log-review` naming).
> Created 2026-06-11.
> Source of truth: [View and read SQL Server Setup log files](https://learn.microsoft.com/sql/database-engine/install-windows/view-and-read-sql-server-setup-log-files)
> plus related MS Learn pages (configuration file install, setup error troubleshooting).

## Why

The library covers runtime diagnostics end to end but has nothing for the
*installation* layer: failed setups, failed CU/SP patches, failed cluster/AG
node preparation, and setup-time configuration drift (service accounts, IFI,
TempDB layout chosen at install). Setup failures are a common DBA escalation
and the log layout is fully documented by Microsoft, making every check
verifiable against MS Learn (mandatory per `.claude/docs/ms-learn-validation.md`).

## Skill identity

| Property | Value |
|----------|-------|
| Name | `sqlbootstraplog-review` (planned as `sqlsetup-review`) |
| Check prefix | **U** (setUp/Upgrade — unused; taken: S,N,C,D,P,T,I,W,X,V,Q,R,H,L,E,K,O,Z,A,B) |
| Check count | 24 (U1–U24) |
| Triggers | `/sqlbootstraplog-review`, `/bootstrap-log`, `/setup-log` |
| Companion skills | `sqlerrorlog-review` (post-install ERRORLOG), `sqldbconfig-review` (post-install config drift), `sqlclusterlog-review` (cluster setup failures) |

## Input (polymorphic, per repo convention)

- **Summary.txt** / `Summary_<MachineName>_<yyyyMMdd_HHmmss>.txt` — overall result,
  detected components, rule outcomes, exit code
- **Detail.txt** — action-by-action execution log; errors/exceptions at end of file
- **MSI/MSP logs** (`<Feature>_<Architecture>_<Interaction>.log`) — msiexec package logs
- **ConfigurationFile.ini** — unattended-install input settings
- **SystemConfigurationCheck_Report.htm** (pasted text) — rule descriptions + status
- **`%temp%\sqlsetup*.log`** — unattended-mode logs
- Natural-language description ("setup failed with 0x851A0019 adding node")

Path knowledge baked into the skill: `%programfiles%\Microsoft SQL Server\<nnn>\Setup
Bootstrap\Log\<yyyyMMdd_HHmmss>\`, `<nnn>` = 130/140/150/160 per version; per-instance
subfolders when patching; `Log*.cab` archive; `Datastore\` XML state snapshots.

## Checks (U1–U24)

**Summary and outcome (U1–U6)**
- U1 — Final result Failed/Cancelled in Summary.txt (extract exit code + failing feature list)
- U2 — Exit error code decode (0x84xxxxxx setup codes; map common codes; cross-reference "Requested action" section)
- U3 — Failed rules listed in Summary (rules report section) — name each rule + documented remediation
- U4 — Setup completed with features in "Failed" state while others succeeded (partial install)
- U5 — Patch/upgrade run detected (per-instance subfolders) with one instance failed (mixed-version risk)
- U6 — Component update phase failure (phase 2: media update download blocked — offline/proxy)

**Rule-failure patterns (U7–U13)**
- U7 — Reboot required pending (RebootRequiredCheck / PendingFileRenameOperations) — companion script already exists: `scripts/check-pending-reboot.ps1`
- U8 — Insufficient disk space / drive rule failures
- U9 — Account or permission rule failures (service account validation, sysadmin check on add-node)
- U10 — Prerequisite failures (.NET, PowerShell, OS version rules)
- U11 — Cluster rules failures (cluster validation, shared disk, AddNode rules)
- U12 — Security/policy blockers (Group Policy, blocked MSI, mark-of-the-web on media)
- U13 — Global Rules phase failure (phase 1 — environment fundamentally unsupported)

**Detail.txt / MSI forensics (U14–U18)**
- U14 — Exception block at end of Detail.txt ("error"/"exception" search per the doc's documented method)
- U15 — MSI "Return value 3" pattern in MSI logs (doc-documented search string), with surrounding-context extraction
- U16 — Watson bucket / crash during setup action
- U17 — Action dependency failure chain (first failing action vs cascading failures — root-cause ordering)
- U18 — Datastore XML referenced for configuration-object state when Summary/Detail are inconclusive

**ConfigurationFile.ini review (U19–U24)**
- U19 — Service accounts: built-in accounts for production engine service / missing managed service account
- U20 — `/SQLSVCINSTANTFILEINIT` absent (IFI not granted at setup, SQL 2016+)
- U21 — TempDB setup parameters (SQLTEMPDBFILECOUNT/SIZE/FILEGROWTH, SQL 2016+) vs core count
- U22 — Security surface: TCP/NP protocol flags, `/SECURITYMODE=SQL` (mixed auth) without justification, SA password policy flags
- U23 — Feature sprawl: FEATURES list installs unused components (DQ, AS, RS on an engine-only box)
- U24 — Directories: system DBs / user DB / log / backup dirs all on the same volume or on the system drive

Each check follows the repo's three-part Trigger → Severity → Fix structure, and every
factual claim (file paths, search strings like "value 3", phase model, INI parameter
names) gets validated against MS Learn before the skill is marked complete.

## Version compatibility

- Applies to **SQL Server on Windows only** (the documented log layout). SQL on Linux
  and Azure SQL DB/MI: ✗ (no user-visible Setup Bootstrap logs).
- Log layout stable SQL 2008 R2 → 2022+ (path `<nnn>` varies). U20/U21 are SQL 2016+
  (setup-time IFI/TempDB parameters). Matrix row: ✓ for 2008 R2–2022 on-prem, ✗ Azure both.

## Implementation checklist (repo's "Adding a New Skill" + extras found in practice)

1. `skills/sqlsetup-review/SKILL.md` (~450 lines, ≤ 900 guideline) + frontmatter
   description ≥ 30 words with trigger phrases + `triggers:` field
2. `skills/sqlsetup-review/references/check-explanations.md` (five-part structure per
   check + Quick Reference table) + `references/README.md`
3. Move `scripts/check-pending-reboot.ps1` to `skills/sqlsetup-review/scripts/` (with a
   scripts/README.md, following the sqlencryption-review scripts pattern) and update the
   CLAUDE.md Scripts table row
4. Examples: synthetic failed-install `Summary.txt` (failed rule + 0x84B40000-style code,
   MSI value-3 excerpt) + expected `setup-analysis.md`
5. CLAUDE.md: Key Files tables (skill + reference rows), prefix table (add U), Purpose
   ("twenty" → "twenty-one"; orchestrator routes to 20 specialised skills)
6. README.md: install line + Skills table + full `## sqlsetup-review` section
7. PERFORMANCE_TUNING_GUIDE.md: Skills at a Glance, Skill Scope Comparison, scenario
   routing ("setup failed", "patch failed"), Check ID Reference (+24 → **Total: 721**)
8. LLM_COST_ESTIMATION.md: file-size row
9. skills/VERSION_COMPATIBILITY.md: matrix row, notes, totals (697 → 721; universal
   count +22, U20/U21 gated SQL 2016+), Quick Reference rows (21 skills)
10. `.claude-plugin/plugin.json` + `marketplace.json` descriptions: 21 skills / 721 checks
   (verify-docs Checks 42–43 enforce this)
11. mcp-server: add `setuplog` artifact type to `ARTIFACT_SKILL_MAP` in `tools.ts`,
    add skill to `routing.test.ts` ALL_SKILL_NAMES, `npm run bundle`, `npm test`
12. Orchestrator (`mssql-performance-review/SKILL.md`): add artifact classification row
    for setup logs + dispatch heuristic
13. MS Learn validation pass on the finished skill (mandatory policy) + record in
    `backlog/ms-learn-validation-2026-06.md` (or successor report)
14. `bash scripts/verify-docs.sh` green; commit per repo conventions

## Effort estimate

~1 session: skill authoring (largest part), 6 doc touch points, MCP server updates,
validation pass. No new infrastructure needed — pure Markdown + one TS map entry.
