# AGENTS.md — mssql-performance-skills

## What this is
A library of Markdown skills for SQL Server performance tuning. No build system, no tests, no dependencies.

All skill details, check counts, prefix map, contributor workflows, and conventions — see `CLAUDE.md`.

## Verify before commit
```
bash scripts/verify-docs.sh
```
Runs documentation consistency checks. Fails block commit; warnings are advisory.
A `.claude/settings.json` PostToolUse hook auto-runs this after every Write/Edit — check output after file edits.

## Critical gotchas

**Dollar signs in SKILL.md break at runtime.** The Claude skill loader does shell variable expansion on SKILL.md content. Never write `$0.012` or `$[expr]` — use `USD 0.012`. verify-docs.sh catches this.

**references/check-explanations.md is NOT loaded at runtime by default.** Only SKILL.md is read automatically by the skill loader. All thresholds and triggers must live in SKILL.md. The reference file is on-demand context — Claude may load it when a user asks "explain check X" or for deeper fix-option detail.

**Dispatcher-style skills are exempt from check-count matching.** Skills with no own checks have references/check-explanations.md files that describe methodology, not per-check entries.

## Full contributor guide
`CLAUDE.md` — file map, conventions, all skills listed, install instructions, development constraints, and step-by-step workflows for adding checks and skills.

## Autonomous agent workflow
This repo also runs [AgentWorks](https://github.com/vanterx/agentworks): agents can claim `status: available` GitHub issues and work through `scripts/start_work.sh`. If you were invoked by that loop (or `review_work.sh`), see `AGENT_CONTRACT.md` for the claim/work/review/merge contract — it's separate from this file, which covers the skills-library conventions above.
