# AGENTS.md — mssql-performance-skills

## What this is
A library of 16 Markdown skills for SQL Server performance tuning — 15 specialised review skills plus one agentic orchestrator (`mssql-performance-review`). No build system, no tests, no dependencies. The only executable is `bash scripts/verify-docs.sh`.

## Verify before commit
```
bash scripts/verify-docs.sh
```
Runs 31 documentation consistency checks. Fails block commit; warnings are advisory.
A `.claude/settings.json` PostToolUse hook auto-runs this after every Write/Edit — check output after file edits.

## Critical gotchas

**Dollar signs in SKILL.md break at runtime.** The Claude skill loader does shell variable expansion on SKILL.md content. Never write `$0.012` or `$[expr]` — use `USD 0.012`. verify-docs.sh check 5 catches this.

**references/check-explanations.md is NOT loaded at runtime by default.** Only SKILL.md is read automatically by the skill loader. All thresholds and triggers must live in SKILL.md. The reference file is on-demand context — Claude may load it when a user asks "explain check X" or for deeper fix-option detail.

**Dispatchers are exempt from check-count matching** (verify-docs.sh check 11). Skills with no own checks — `sqlplan-batch`, `sqlplan-index-advisor`, `mssql-performance-review` — have references/check-explanations.md files that describe methodology, not per-check entries.

## Adding a check → update 6 locations
`skills/<skill>/SKILL.md` (check + section header + frontmatter count + Purpose count),
`skills/<skill>/references/check-explanations.md` (explanation + header + Quick Reference table),
`PERFORMANCE_TUNING_GUIDE.md` (Check ID Reference total),
`LLM_COST_ESTIMATION.md` (total checks line).

## Adding a skill → 9 steps
See `CLAUDE.md` "Adding a New Skill" section for the full checklist (files, tables, references, examples).

## Check prefix map
```
T  = tsql-review              I/W = sqlstats-review       X  = sqltrace-review
V  = sqlwait-review (40)      S/N = sqlplan-review        C  = sqlplan-compare
D  = sqlplan-index-advisor    P   = sqlplan-deadlock      Q  = query-store-review
R  = procstats-review         H   = hadr-health-review    L  = clusterlog-review
E  = errorlog-review          K   = spn-review
```
Dispatchers (no own prefix): `sqlplan-batch` (aggregates S/N), `mssql-performance-review` (delegates to all 15).

Available prefixes: A, B, F, G, J, M, O, U, Y, Z

## Full contributor guide
`CLAUDE.md` — file map, conventions, all 16 skills listed, install instructions, development constraints, and step-by-step workflows for adding checks and skills.
