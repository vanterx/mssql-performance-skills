# mssql-performance-skills

A Claude Code skills library for SQL Server performance tuning — T-SQL static analysis, execution plan review, I/O statistics, workload traces, index recommendations, deadlock diagnosis, regression detection, and batch workload analysis.

## Purpose

Provides eleven slash-command skills that Claude uses when asked to review T-SQL source code, `.sqlplan` XML files, STATISTICS IO/TIME output, Profiler/XE trace data, deadlock graphs, index recommendations, wait statistics, Query Store data, or procedure/trigger/function runtime stats collected from `sys.dm_exec_procedure_stats`. No application code — content is Markdown only.

## Tech Stack

- **Format:** Markdown + YAML frontmatter
- **Runtime:** Claude Code skill loader (reads `SKILL.md` files from `~/.claude/skills/`)
- **No build system, no tests, no dependencies**

## Key Files

### Skills (SKILL.md — loaded at runtime)

| File | Purpose |
|------|---------|
| [skills/tsql-review/SKILL.md](skills/tsql-review/SKILL.md) | Static T-SQL source analysis: `tsql-review`. 50 checks (T1–T50) — structural, correctness, security, deprecated syntax, performance smells |
| [skills/sqlstats-review/SKILL.md](skills/sqlstats-review/SKILL.md) | STATISTICS IO/TIME parser + analysis: `sqlstats-review`. 22 checks (I1–I15 IO, W1–W7 time), per-statement tables, grand totals |
| [skills/sqltrace-review/SKILL.md](skills/sqltrace-review/SKILL.md) | Profiler / XE trace analysis: `sqltrace-review`. 20 checks (X1–X12 event-level, X13–X20 workload aggregate), top-consumer tables |
| [skills/sqlwait-review/SKILL.md](skills/sqlwait-review/SKILL.md) | Wait statistics analysis: `sqlwait-review`. 29 checks (V1–V29) — I/O, lock, parallelism, memory, CPU, latch, log space, poison/throttle waits, backup I/O, insert hotspots, cumulative skew, trend analysis |
| [skills/sqlplan-review/SKILL.md](skills/sqlplan-review/SKILL.md) | Runtime plan analysis: `sqlplan-review`. 99 checks (S1–S33, N1–N66), thresholds, output format |
| [skills/sqlplan-compare/SKILL.md](skills/sqlplan-compare/SKILL.md) | Regression detection: `sqlplan-compare`. Diff two plans (C1–C10) |
| [skills/sqlplan-index-advisor/SKILL.md](skills/sqlplan-index-advisor/SKILL.md) | Index recommendations: `sqlplan-index-advisor`. Derive indexes from operator patterns (D1–D8) + optimizer suggestions |
| [skills/sqlplan-deadlock/SKILL.md](skills/sqlplan-deadlock/SKILL.md) | Deadlock analysis: `sqlplan-deadlock`. 8 patterns (P1–P8), lock cycle extraction, remediation |
| [skills/sqlplan-batch/SKILL.md](skills/sqlplan-batch/SKILL.md) | Batch workload: `sqlplan-batch`. Aggregate dashboard across many `.sqlplan` files |
| [skills/query-store-review/SKILL.md](skills/query-store-review/SKILL.md) | Query Store analysis: `query-store-review`. 25 checks (Q1–Q25) — regressed queries, plan instability, resource hotspots, query waits, operational health |
| [skills/procstats-review/SKILL.md](skills/procstats-review/SKILL.md) | Procedure/trigger/function runtime stats analysis: `procstats-review`. 20 checks (R1–R20) — top consumers, per-execution efficiency, pattern detection, trend analysis |

### Human Reference (CHECKS_EXPLAINED.md — not loaded at runtime)

| File | Purpose |
|------|---------|
| [skills/tsql-review/CHECKS_EXPLAINED.md](skills/tsql-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 50 T-checks with SQL examples, fix recipes, and Quick Reference table |
| [skills/sqlstats-review/CHECKS_EXPLAINED.md](skills/sqlstats-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 22 I/W checks with IO output examples and fix recipes |
| [skills/sqltrace-review/CHECKS_EXPLAINED.md](skills/sqltrace-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 20 X-checks with trace output examples, capture how-tos, and quick reference |
| [skills/sqlwait-review/CHECKS_EXPLAINED.md](skills/sqlwait-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 29 V-checks with wait type descriptions, capture queries, and category quick reference |
| [skills/sqlplan-review/CHECKS_EXPLAINED.md](skills/sqlplan-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 99 S/N checks with XML examples and fix recipes |
| [skills/sqlplan-compare/CHECKS_EXPLAINED.md](skills/sqlplan-compare/CHECKS_EXPLAINED.md) | C1–C10 regression checks explained — what each change means and why it causes a slowdown |
| [skills/sqlplan-index-advisor/CHECKS_EXPLAINED.md](skills/sqlplan-index-advisor/CHECKS_EXPLAINED.md) | Merge rules, Impact score, ranking formula, width check, and output guide |
| [skills/sqlplan-deadlock/CHECKS_EXPLAINED.md](skills/sqlplan-deadlock/CHECKS_EXPLAINED.md) | P1–P8 deadlock patterns, lock concepts, how to capture XML |
| [skills/sqlplan-batch/CHECKS_EXPLAINED.md](skills/sqlplan-batch/CHECKS_EXPLAINED.md) | How to read each dashboard section, prioritisation guide, next-step workflow |
| [skills/query-store-review/CHECKS_EXPLAINED.md](skills/query-store-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 25 Q-checks with Query Store DMV examples and fix recipes |
| [skills/procstats-review/CHECKS_EXPLAINED.md](skills/procstats-review/CHECKS_EXPLAINED.md) | Plain-English explanation of all 20 R-checks with collection table examples and fix recipes |

### Root Documentation

| File | Purpose |
|------|---------|
| [README.md](README.md) | User-facing guide: triggers, input formats, output samples for all 9 skills |
| [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) | Decision guide: which skill to use for which scenario, symptom-based routing, artifact capture how-tos, 231-check ID reference |
| [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) | Token and dollar cost breakdown per skill — worked examples, cost control strategies, prompt caching guide |
| [.claude/docs/architectural_patterns.md](.claude/docs/architectural_patterns.md) | Cross-cutting conventions: check ID namespacing, input polymorphism, output format, companion pipeline, dollar-sign avoidance |

### Examples

| Path | What it demonstrates |
|------|---------------------|
| [example/sqlplan-review/horrible.sqlplan](example/sqlplan-review/horrible.sqlplan) | Reference bad plan: parameter sniffing, spills, implicit conversion, key lookups |
| [example/sqlplan-review/horrible-analysis.md](example/sqlplan-review/horrible-analysis.md) | Reference output of `/sqlplan-review` on the above plan |
| [example/tsql-review/](example/tsql-review/) | `slow_proc.sql` with 12 anti-patterns + expected analysis |
| [example/sqlstats-review/](example/sqlstats-review/) | SSMS STATISTICS IO/TIME output + expected analysis |
| [example/sqlplan-compare/](example/sqlplan-compare/) | Baseline + regression `.sqlplan` pair + diff analysis |
| [example/sqlplan-deadlock/](example/sqlplan-deadlock/) | P1 lock-order deadlock XML + analysis |
| [example/sqltrace-review/](example/sqltrace-review/) | `fn_trace_gettable` output with N+1, sniffing, spills + analysis |
| [example/sqlwait-review/](example/sqlwait-review/) | `sys.dm_os_wait_stats` output with I/O, lock, memory, CXPACKET + analysis |
| [example/sqlplan-index-advisor/](example/sqlplan-index-advisor/) | Index advisor output for `horrible.sqlplan` |
| [example/sqlplan-batch/](example/sqlplan-batch/) | Aggregate dashboard for a 3-plan batch |
| [example/query-store-review/](example/query-store-review/) | Query Store DMV output with plan instability, forced plan failure, N+1 + analysis |
| [example/procstats-review/](example/procstats-review/) | Q1 report output with CPU hotspot, parameter sniffing, N+1 caller, blocking signal + analysis |

## Installing Skills

```bash
cp -r skills/* ~/.claude/skills/          # global (all 11 skills)
cp -r skills/* .claude/skills/            # project-scoped
```

## Adding a New Check to an Existing Skill

These steps apply to any skill. Replace `<skill>` with the skill directory name and `<PREFIX>` with its check letter(s).

1. Add the check to `skills/<skill>/SKILL.md` under the correct section, following the **Trigger → Severity → Fix** three-part structure
2. Add a full explanation entry to `skills/<skill>/CHECKS_EXPLAINED.md`, following the **five-part structure** (What it means / How to spot it / Example / Fix options / Related checks)
3. Update the check count in the skill's frontmatter `description` field and in its `## Purpose` section
4. Update the section header range (e.g., `T1–T50` → `T1–T51`) in both files
5. Update the Quick Reference table at the bottom of `CHECKS_EXPLAINED.md` if the skill has one
6. Update the check count in [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) (Check ID Reference table) and [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) (total checks line)

## Adding a New Skill

1. Create `skills/<skill-name>/SKILL.md` and `skills/<skill-name>/CHECKS_EXPLAINED.md` following the patterns in [.claude/docs/architectural_patterns.md](.claude/docs/architectural_patterns.md)
2. Choose an unused single-letter check prefix (current: S, N, C, D, P, T, I, W, X, V are taken)
3. Add the skill to the Key Files tables above
4. Add install line to [README.md](README.md) Installation section and `## Skills` table
5. Add a full `## <skill-name>` section to [README.md](README.md) with triggers, usage, and output sample
6. Add the skill to [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) Skills at a Glance, Skill Scope Comparison, and relevant scenario sections
7. Add the skill file size row to [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md)
8. Add example input + analysis files to `example/<skill-name>/`
9. Add `tsql-review` as companion in `sqlplan-review/SKILL.md` (or the relevant existing companion)

## Development Constraints

Rules discovered during development that must be respected in every session.

### Before committing
Always run `bash scripts/verify-docs.sh` — it checks 9 documentation invariants and exits non-zero on any failure. The PostToolUse hook in `.claude/settings.json` runs it automatically after Write/Edit, but run it manually before `git commit` too.

### Dollar signs in SKILL.md code block templates
Never use `$0`, `$3`, `$15`, or `$[...]` inside SKILL.md files. The skill loader performs shell-style variable expansion on the entire file content, so `$0` expands to the input file path argument and `$3`/`$15` expand to empty strings. Use `USD` prefix instead: `USD 0.012`, `[tokens] × USD 3/M`.

### Check ID prefixes — currently taken
| Prefix | Skill |
|--------|-------|
| `S`, `N` | `sqlplan-review` |
| `C` | `sqlplan-compare` |
| `D` | `sqlplan-index-advisor` |
| `P` | `sqlplan-deadlock` |
| `T` | `tsql-review` |
| `I`, `W` | `sqlstats-review` |
| `X` | `sqltrace-review` |
| `V` | `sqlwait-review` |
| `Q` | `query-store-review` |
| `R` | `procstats-review` |

New skills must choose an unused single uppercase letter.

### CHECKS_EXPLAINED.md is not loaded at runtime
Only `SKILL.md` is loaded by the Claude Code skill loader. `CHECKS_EXPLAINED.md` is human reference only — do not put trigger conditions or thresholds there that Claude needs to act on.

### Updating check counts — all 6 touch points
When adding or removing a check from any skill, update all of:
1. Skill frontmatter `description` field (count in the one-liner)
2. Skill `## Purpose` section (count in the narrative)
3. Section header range in `SKILL.md` (e.g., `T1–T50` → `T1–T51`)
4. Section header range in `CHECKS_EXPLAINED.md`
5. `CHECKS_EXPLAINED.md` Quick Reference table (if the skill has one)
6. `PERFORMANCE_TUNING_GUIDE.md` Check ID Reference table total (`**Total: N checks**`)

Then run `bash scripts/verify-docs.sh` to confirm Check 1 passes.

---

## Additional Documentation

| Topic | File |
|-------|------|
| Architectural patterns, conventions, design decisions | [.claude/docs/architectural_patterns.md](.claude/docs/architectural_patterns.md) |
| Scenario-based skill selection, symptom routing | [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) |
| Token costs and cost control strategies | [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) |
| Skill usage, triggers, input/output examples | [README.md](README.md) |
| All check triggers, thresholds, fix logic | Each skill's `SKILL.md` — see Key Files table above |
| Plain-English check explanations with examples | Each skill's `CHECKS_EXPLAINED.md` — see Key Files table above |
