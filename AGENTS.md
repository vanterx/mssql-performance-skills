# AGENTS.md — mssql-performance-skills

## What this is
A library of 10 Markdown skills for SQL Server performance tuning. No build system, no tests, no dependencies. The only executable is `bash scripts/verify-docs.sh`.

## Verify before commit
```
bash scripts/verify-docs.sh
```
Runs 18 documentation consistency checks. Fails block commit; warnings are advisory.
A `.claude/settings.json` PostToolUse hook auto-runs this after every Write/Edit — check output after file edits.

## Critical gotchas

**Dollar signs in SKILL.md break at runtime.** The Claude skill loader does shell variable expansion on SKILL.md content. Never write `$0.012` or `$[expr]` — use `USD 0.012`. verify-docs.sh check 5 catches this.

**CHECKS_EXPLAINED.md is NOT loaded at runtime.** Only SKILL.md is read by the skill loader. All thresholds and triggers must live in SKILL.md. CHECKS_EXPLAINED.md is human reference only.

**sqlplan-review has no `example/sqlplan-review/` folder.** It uses root-level `example/horrible.sqlplan` instead. All other 8 skills require `example/<skill-name>/`.

**sqlplan-batch and sqlplan-index-advisor are exempt from check count matching** (verify-docs.sh check 11). Their CHECKS_EXPLAINED.md files don't mirror per-check entries by design.

## Adding a check → update 6 locations
`skills/<skill>/SKILL.md` (check + section header + frontmatter count + Purpose count),
`skills/<skill>/CHECKS_EXPLAINED.md` (explanation + header + Quick Reference table),
`PERFORMANCE_TUNING_GUIDE.md` (Check ID Reference total),
`LLM_COST_ESTIMATION.md` (total checks line).

## Adding a skill → 9 steps
See `CLAUDE.md` "Adding a New Skill" section for the full checklist (files, tables, references, examples).

## Check prefix map
```
T  = tsql-review              I/W = sqlstats-review       X  = sqltrace-review
V  = sqlwait-review           S/N = sqlplan-review        C  = sqlplan-compare
D  = sqlplan-index-advisor    P   = sqlplan-deadlock       Q  = query-store-review
```
sqlplan-batch has no own prefix (aggregates S/N).

## Full contributor guide
`CLAUDE.md` — file map, conventions, all 9 skills listed, install instructions, development constraints, and step-by-step workflows for adding checks and skills.
