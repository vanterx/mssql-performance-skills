# mssql-performance-skills

A Claude Code skills library for SQL Server performance tuning — T-SQL static analysis, execution plan review, I/O statistics, workload traces, index recommendations, deadlock diagnosis, regression detection, and batch workload analysis.

## Purpose

Provides sixteen slash-command skills — fifteen specialised review skills plus one agentic orchestrator (`mssql-performance-review`) that dispatches the right specialised skill(s) to mixed artifact inputs. Specialised skills cover T-SQL source code, `.sqlplan` XML files, STATISTICS IO/TIME output, Profiler/XE trace data, deadlock graphs, index recommendations, wait statistics, Query Store data, procedure/trigger/function runtime stats collected from `sys.dm_exec_procedure_stats`, Always On AG health from `sys.dm_hadr_*` DMVs, Windows Server Failover Cluster log files, SQL Server ERRORLOG files, and SQL Server SPN and Kerberos delegation configuration. No application code — content is Markdown only.

## Tech Stack

- **Format:** Markdown + YAML frontmatter
- **Runtime:** Claude Code skill loader (reads `SKILL.md` files from `~/.claude/skills/`)
- **No build system, no tests, no dependencies**

## Key Files

### Skills (SKILL.md — loaded at runtime)

| File | Purpose |
|------|---------|
| [skills/mssql-performance-review/SKILL.md](skills/mssql-performance-review/SKILL.md) | Agentic offline orchestrator: `mssql-performance-review`. No checks of its own (dispatcher, like `sqlplan-batch`). Routes mixed artifacts to the 15 specialised skills, runs adversarial root-cause check, emits evidence chain + risk-rated fixes + rollback. |
| [skills/tsql-review/SKILL.md](skills/tsql-review/SKILL.md) | Static T-SQL source analysis: `tsql-review`. 78 checks (T1–T78) — structural, correctness, security, deprecated syntax, performance smells |
| [skills/sqlstats-review/SKILL.md](skills/sqlstats-review/SKILL.md) | STATISTICS IO/TIME parser + analysis: `sqlstats-review`. 22 checks (I1–I15 IO, W1–W7 time), per-statement tables, grand totals |
| [skills/sqltrace-review/SKILL.md](skills/sqltrace-review/SKILL.md) | Profiler / XE trace analysis: `sqltrace-review`. 20 checks (X1–X12 event-level, X13–X20 workload aggregate), top-consumer tables |
| [skills/sqlwait-review/SKILL.md](skills/sqlwait-review/SKILL.md) | Wait statistics analysis: `sqlwait-review`. 40 checks (V1–V40) — I/O, lock, parallelism, memory, CPU, latch, log space, poison/throttle waits, backup I/O, insert hotspots, cumulative skew, trend analysis, modern feature waits, memory grants, file I/O latency |
| [skills/sqlplan-review/SKILL.md](skills/sqlplan-review/SKILL.md) | Runtime plan analysis: `sqlplan-review`. 99 checks (S1–S33, N1–N66), thresholds, output format |
| [skills/sqlplan-compare/SKILL.md](skills/sqlplan-compare/SKILL.md) | Regression detection: `sqlplan-compare`. Diff two plans (C1–C10) |
| [skills/sqlplan-index-advisor/SKILL.md](skills/sqlplan-index-advisor/SKILL.md) | Index recommendations: `sqlplan-index-advisor`. Derive indexes from operator patterns (D1–D8) + optimizer suggestions |
| [skills/sqlplan-deadlock/SKILL.md](skills/sqlplan-deadlock/SKILL.md) | Deadlock analysis: `sqlplan-deadlock`. 8 patterns (P1–P8), lock cycle extraction, remediation |
| [skills/sqlplan-batch/SKILL.md](skills/sqlplan-batch/SKILL.md) | Batch workload: `sqlplan-batch`. Aggregate dashboard across many `.sqlplan` files |
| [skills/query-store-review/SKILL.md](skills/query-store-review/SKILL.md) | Query Store analysis: `query-store-review`. 25 checks (Q1–Q25) — regressed queries, plan instability, resource hotspots, query waits, operational health |
| [skills/procstats-review/SKILL.md](skills/procstats-review/SKILL.md) | Procedure/trigger/function runtime stats analysis: `procstats-review`. 20 checks (R1–R20) — top consumers, per-execution efficiency, pattern detection, trend analysis |
| [skills/clusterlog-review/SKILL.md](skills/clusterlog-review/SKILL.md) | WSFC cluster log analysis: `clusterlog-review`. 25 checks (L1–L25) — lease timeouts, health check failures, quorum loss, node eviction, network partition, RHS crashes, AG resource transitions |
| [skills/hadr-health-review/SKILL.md](skills/hadr-health-review/SKILL.md) | Always On AG health analysis: `hadr-health-review`. 22 checks (H1–H22) — replica connectivity, data loss risk, recovery time, throughput, and configuration |
| [skills/errorlog-review/SKILL.md](skills/errorlog-review/SKILL.md) | SQL Server ERRORLOG analysis: `errorlog-review`. 28 checks (E1–E28) — AG failover events, lease expiry, memory pressure, I/O slow, corruption warnings, login failure bursts, startup/shutdown, and configuration signals |
| [skills/spn-review/SKILL.md](skills/spn-review/SKILL.md) | SPN and Kerberos delegation analysis: `spn-review`. 30 checks (K1–K30) — MSSQLSvc SPN presence, service account binding, AG listener and alias, permissions, Kerberos delegation, AD account sensitivity |

### Human Reference (references/check-explanations.md — not loaded at runtime by default)

| File | Purpose |
|------|---------|
| [skills/mssql-performance-review/references/check-explanations.md](skills/mssql-performance-review/references/check-explanations.md) | Methodology reference for the orchestrator: dispatch heuristics, symptom-to-probe-sequence map, hypothesis classes, recommendation conflict catalogue, and rationale for the standard analysis order |
| [skills/tsql-review/references/check-explanations.md](skills/tsql-review/references/check-explanations.md) | Plain-English explanation of all 78 T-checks with SQL examples, fix recipes, and Quick Reference table |
| [skills/sqlstats-review/references/check-explanations.md](skills/sqlstats-review/references/check-explanations.md) | Plain-English explanation of all 22 I/W checks with IO output examples and fix recipes |
| [skills/sqltrace-review/references/check-explanations.md](skills/sqltrace-review/references/check-explanations.md) | Plain-English explanation of all 20 X-checks with trace output examples, capture how-tos, and quick reference |
| [skills/sqlwait-review/references/check-explanations.md](skills/sqlwait-review/references/check-explanations.md) | Plain-English explanation of all 29 V-checks with wait type descriptions, capture queries, and category quick reference |
| [skills/sqlplan-review/references/check-explanations.md](skills/sqlplan-review/references/check-explanations.md) | Plain-English explanation of all 99 S/N checks with XML examples and fix recipes |
| [skills/sqlplan-compare/references/check-explanations.md](skills/sqlplan-compare/references/check-explanations.md) | C1–C10 regression checks explained — what each change means and why it causes a slowdown |
| [skills/sqlplan-index-advisor/references/check-explanations.md](skills/sqlplan-index-advisor/references/check-explanations.md) | Merge rules, Impact score, ranking formula, width check, and output guide |
| [skills/sqlplan-deadlock/references/check-explanations.md](skills/sqlplan-deadlock/references/check-explanations.md) | P1–P8 deadlock patterns, lock concepts, how to capture XML |
| [skills/sqlplan-batch/references/check-explanations.md](skills/sqlplan-batch/references/check-explanations.md) | How to read each dashboard section, prioritisation guide, next-step workflow |
| [skills/query-store-review/references/check-explanations.md](skills/query-store-review/references/check-explanations.md) | Plain-English explanation of all 25 Q-checks with Query Store DMV examples and fix recipes |
| [skills/procstats-review/references/check-explanations.md](skills/procstats-review/references/check-explanations.md) | Plain-English explanation of all 20 R-checks with collection table examples and fix recipes |
| [skills/clusterlog-review/references/check-explanations.md](skills/clusterlog-review/references/check-explanations.md) | Plain-English explanation of all 25 L-checks with CLUSTER.LOG examples, fix recipes, and Quick Reference table |
| [skills/hadr-health-review/references/check-explanations.md](skills/hadr-health-review/references/check-explanations.md) | Plain-English explanation of all 22 H-checks with DMV examples, fix recipes, and Quick Reference table |
| [skills/errorlog-review/references/check-explanations.md](skills/errorlog-review/references/check-explanations.md) | Plain-English explanation of all 28 E-checks with ERRORLOG examples, fix recipes, and Quick Reference table |
| [skills/spn-review/references/check-explanations.md](skills/spn-review/references/check-explanations.md) | Plain-English explanation of all 30 K-checks with setspn/AD attribute examples, delegation model tables, and Quick Reference table |

### Root Documentation

| File | Purpose |
|------|---------|
| [README.md](README.md) | User-facing guide: triggers, input formats, output samples for all 16 skills |
| [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) | Decision guide: which skill to use for which scenario, symptom-based routing, artifact capture how-tos, 231-check ID reference |
| [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) | Token and dollar cost breakdown per skill — worked examples, cost control strategies, prompt caching guide |
| [.claude/docs/architectural_patterns.md](.claude/docs/architectural_patterns.md) | Cross-cutting conventions: check ID namespacing, input polymorphism, output format, companion pipeline, dollar-sign avoidance |
| [.claude-plugin/marketplace.json](.claude-plugin/marketplace.json) | Claude Code plugin marketplace manifest — registers this repo as a marketplace with one plugin entry pointing to `./` |
| [.claude-plugin/plugin.json](.claude-plugin/plugin.json) | Plugin manifest — declares `"skills": "./skills"` so all 16 SKILL.md files are discovered by the plugin system |
| [mcp-server/src/index.ts](mcp-server/src/index.ts) | MCP server entry point — CORS preflight, `GET /health`, error handling, then Cloudflare Workers fetch handler using `WebStandardStreamableHTTPServerTransport` (stateless, one server per request) |
| [mcp-server/src/skill-loader.ts](mcp-server/src/skill-loader.ts) | `SkillMeta` interface — no fs access; all skill data pre-bundled into `skills-data.ts` at deploy time |
| [mcp-server/src/skills-data.ts](mcp-server/src/skills-data.ts) | Generated file — run `npm run bundle` to regenerate from `skills/*/SKILL.md`. Do not edit manually |
| [mcp-server/scripts/bundle-skills.ts](mcp-server/scripts/bundle-skills.ts) | Build-time codegen: reads all SKILL.md files + PERFORMANCE_TUNING_GUIDE.md → writes `skills-data.ts` |
| [mcp-server/wrangler.toml](mcp-server/wrangler.toml) | Cloudflare Workers config — worker name `mssql-mcp`, live at `https://mssql-mcp.tsx113.workers.dev` |
| [mcp-server/src/tools.ts](mcp-server/src/tools.ts) | MCP tools: `list_skills`, `get_skill`, `route_artifact` (13 artifact types including `mixed` → orchestrator) |
| [mcp-server/src/resources.ts](mcp-server/src/resources.ts) | MCP resources: `mssql://skills`, `mssql://skills/{name}` (×16), `mssql://guide` |
| [mcp-server/src/prompts.ts](mcp-server/src/prompts.ts) | MCP prompts: one per skill, accepts `{ input }` and returns analysis prompt via shared `buildAnalysisPrompt` |
| [mcp-server/src/prompt-builder.ts](mcp-server/src/prompt-builder.ts) | Shared `buildAnalysisPrompt(skillName, skillContent, input)` helper used by both `tools.ts` and `prompts.ts` |
| [.github/workflows/deploy-mcp.yml](.github/workflows/deploy-mcp.yml) | GitHub Actions CD — auto-deploys to Cloudflare Workers on push when `mcp-server/`, `skills/`, or `PERFORMANCE_TUNING_GUIDE.md` changes |

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
| [example/clusterlog-review/](example/clusterlog-review/) | CLUSTER.LOG with lease timeout, heartbeat loss, AG offline transition, VerboseLogging=0 + analysis |
| [example/hadr-health-review/](example/hadr-health-review/) | 3-replica AG with disconnected secondary, 620 MB redo queue, secondary lag 85 sec + analysis |
| [example/errorlog-review/](example/errorlog-review/) | ERRORLOG with I/O slow → AG lease expiry → failover sequence, login failure burst, trace flags + analysis |
| [example/spn-review/](example/spn-review/) | setspn + AD attribute output: duplicate SPN, unconstrained delegation, missing delegation target SPN, end-user in Protected Users + analysis |

## Installing Skills

**Option 1: Plugin Marketplace (recommended)**
```bash
/plugin marketplace add vanterx/mssql-performance-skills
/plugin install mssql-performance-skills@mssql-performance-skills
```

**Option 2: `npx` one-liner** — requires [Node.js](https://nodejs.org) (>= 18)
```bash
npx skills add vanterx/mssql-performance-skills          # user scope
npx skills add vanterx/mssql-performance-skills -g       # global
```

**Option 3: Manual fallback:**
```bash
cp -r skills/* ~/.claude/skills/          # global (all 16 skills)
cp -r skills/* .claude/skills/            # project-scoped
```

## Adding a New Check to an Existing Skill

These steps apply to any skill. Replace `<skill>` with the skill directory name and `<PREFIX>` with its check letter(s).

1. Add the check to `skills/<skill>/SKILL.md` under the correct section, following the **Trigger → Severity → Fix** three-part structure
2. Add a full explanation entry to `skills/<skill>/references/check-explanations.md`, following the **five-part structure** (What it means / How to spot it / Example / Fix options / Related checks)
3. Update the check count in the skill's frontmatter `description` field and in its `## Purpose` section
4. Update the section header range (e.g., `T1–T50` → `T1–T51`) in both files
5. Update the Quick Reference table at the bottom of `references/check-explanations.md` if the skill has one
6. Update the check count in [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) (Check ID Reference table) and [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) (total checks line)

## Adding a New Skill

1. Create `skills/<skill-name>/SKILL.md` and `skills/<skill-name>/references/check-explanations.md` following the patterns in [.claude/docs/architectural_patterns.md](.claude/docs/architectural_patterns.md)
2. Choose an unused single-letter check prefix (current: S, N, C, D, P, T, I, W, X, V are taken)
3. Add the skill to the Key Files tables above
4. Add install line to [README.md](README.md) Installation section and `## Skills` table
5. Add a full `## <skill-name>` section to [README.md](README.md) with triggers, usage, and output sample
6. Add the skill to [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) Skills at a Glance, Skill Scope Comparison, and relevant scenario sections
7. Add the skill file size row to [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md)
8. Add example input + analysis files to `example/<skill-name>/`
9. Add `tsql-review` as companion in `sqlplan-review/SKILL.md` (or the relevant existing companion)

## Git Hooks

Run once after cloning to install the pre-commit hook:

```bash
bash scripts/install-hooks.sh
```

The hook watches for staged `skills/*/SKILL.md` changes and automatically runs `npm run bundle` + re-stages `mcp-server/src/skills-data.ts` before the commit lands. Without it, you must run `cd mcp-server && npm run bundle` manually before every commit that touches a skill.

## Development Scratch Log

`changes.log` is a local, uncommitted development scratch log. It is `.gitignore`d and tracks work-in-progress notes during active development sessions. It is not part of the canonical project history — use `git log` for that.

## Development Constraints

Rules discovered during development that must be respected in every session.

### Skill authoring standard
All new and modified skills must conform to the Anthropic skill-creator best practices. Reference: [`.claude/docs/skill-creator-best-practices.md`](.claude/docs/skill-creator-best-practices.md). Automated checks run in `scripts/verify-docs.sh` (Checks 21–25): line count ≤ 900 guideline (hard fail at 1000), description ≥ 30 words with trigger phrases, `triggers:` field present, no bare ALWAYS/NEVER/MUST in body.

### Before committing
Always run `bash scripts/verify-docs.sh` — it checks documentation invariants and exits non-zero on any failure. The PostToolUse hook in `.claude/settings.json` runs it automatically after Write/Edit, but run it manually before `git commit` too.

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
| `H` | `hadr-health-review` |
| `L` | `clusterlog-review` |
| `E` | `errorlog-review` |
| `K` | `spn-review` |
| (none) | `mssql-performance-review` — dispatcher; delegates checks to other skills, like `sqlplan-batch` |

New skills must choose an unused single uppercase letter, or document why they are dispatcher-style (no prefix) like the orchestrator and `sqlplan-batch`.

### references/check-explanations.md is not loaded at runtime by default
Only `SKILL.md` is loaded automatically by the Claude Code skill loader. The `references/check-explanations.md` file is human reference and on-demand context — Claude may load it when a user asks "explain check X" or for deeper fix-option detail. Do not put trigger conditions or thresholds there that Claude needs to act on without prompting.

### Updating check counts — all 6 touch points
When adding or removing a check from any skill, update all of:
1. Skill frontmatter `description` field (count in the one-liner)
2. Skill `## Purpose` section (count in the narrative)
3. Section header range in `SKILL.md` (e.g., `T1–T50` → `T1–T51`)
4. Section header range in `references/check-explanations.md`
5. `references/check-explanations.md` Quick Reference table (if the skill has one)
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
| Plain-English check explanations with examples | Each skill's `references/check-explanations.md` — see Key Files table above |
