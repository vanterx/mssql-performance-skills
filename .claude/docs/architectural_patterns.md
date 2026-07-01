# Architectural Patterns

Patterns that appear across multiple files in this repository. Follow these when adding or modifying skills.

---

## 0. Skill Authoring Standard

All skills in this repo must follow the Anthropic skill-creator best practices:
→ [skill-creator-best-practices.md](skill-creator-best-practices.md)

Key criteria enforced by `scripts/verify-docs.sh` (Checks 21–31):
- SKILL.md > 900 lines → warn; > 1000 lines → fail (Check 21)
- `description:` field ≥ 30 words (Check 22)
- `description:` includes at least one trigger phrase ("Use this skill when…", "Trigger when…", "whenever a user…") (Check 23)
- `triggers:` field present in frontmatter (Check 24)
- No bare ALWAYS/NEVER/MUST in all-caps outside code blocks (Check 25 — warn — explain the why instead)
- Per-skill check count in PERFORMANCE_TUNING_GUIDE.md Skills at a Glance matches SKILL.md (Check 26)
- `references/README.md` present per skill (Check 27)
- `evals/evals.json` present per skill (Check 28)
- TOC header in `references/check-explanations.md` when > 300 lines (Check 29)
- `scripts/` directory non-empty per skill (Check 30 — `.gitkeep` is acceptable for dispatchers)
- `Analyzed by:` attribution footer in every SKILL.md Output Format block (Check 31)

---

## 1. Skill Frontmatter Block

**Where:** Every `SKILL.md` in `skills/*/`

Every `SKILL.md` opens with a YAML frontmatter block containing exactly three keys:

```yaml
---
name: skill-name
description: One sentence — what it analyzes and when to use it.
triggers:
  - /primary-trigger
  - /alias-trigger
---
```

**Convention:** `name` must be lowercase-hyphenated and match the directory name under `skills/`. `description` must be self-contained, multi-sentence, and include trigger phrases — see skill-creator best practices in [skill-creator-best-practices.md](skill-creator-best-practices.md). `triggers` lists all slash commands that invoke the skill, primary first.

**Current skills and their prefixes:**

| Directory | Trigger | Check prefix |
|-----------|---------|-------------|
| `skills/sqlplan-review/` | `/sqlplan-review` | S, N |
| `skills/sqlplan-compare/` | `/sqlplan-compare` | C |
| `skills/sqlindex-advisor/` | `/sqlindex-advisor` | D |
| `skills/sqldeadlock-review/` | `/sqldeadlock-review` | P |
| `skills/sqlplan-batch/` | `/sqlplan-batch` | (dispatcher — aggregates S/N) |
| `skills/tsql-review/` | `/tsql-review` | T |
| `skills/sqlstats-review/` | `/sqlstats-review` | I, W |
| `skills/sqltrace-review/` | `/sqltrace-review` | X |
| `skills/sqlwait-review/` | `/sqlwait-review` | V |
| `skills/sqlquerystore-review/` | `/sqlquerystore-review` | Q |
| `skills/sqlprocstats-review/` | `/sqlprocstats-review` | R |
| `skills/sqlhadr-review/` | `/sqlhadr-review` | H |
| `skills/sqlclusterlog-review/` | `/sqlclusterlog-review` | L |
| `skills/sqlerrorlog-review/` | `/sqlerrorlog-review` | E |
| `skills/sqlspn-review/` | `/sqlspn-review` | K |
| `skills/sqlmemory-review/` | `/sqlmemory-review` | O |
| `skills/sqldiskio-review/` | `/sqldiskio-review` | Z |
| `skills/sqlencryption-review/` | `/sqlencryption-review` | A |
| `skills/sqldbconfig-review/` | `/sqldbconfig-review` | B |
| `skills/ssrstracelog-review/` | `/ssrstracelog-review` | G |
| `skills/sqlag-review/` | `/sqlag-review` | F |
| `skills/sqlbootstraplog-review/` | `/sqlbootstraplog-review` | U |
| `skills/sqlmigration-review/` | `/sqlmigration-review` | Y (dispatcher with own checks) |
| `skills/sqlmigration-security-review/` | `/sqlmigration-security-review` | J |
| `skills/sqlmigration-objects-review/` | `/sqlmigration-objects-review` | M |
| `skills/mssql-performance-review/` | `/mssql-performance-review`, `/sql-triage` | (dispatcher — delegates to the 22 performance specialised skills; does not route to the 3 migration skills) |

---

## 2. Input Polymorphism

**Where:** `## Input` section in every `SKILL.md`

Every skill accepts three input forms:

1. **File path** — user provides a path to a `.sqlplan`, `.xdl`, `.xml`, `.sql`, `.txt`, or directory
2. **Inline content** — user pastes raw XML, SQL, statistics output, or trace data directly into chat
3. **Natural language description** — user describes operators, symptoms, or metrics in plain text

**Convention:** New skills must accept all three. Never require a specific format. The `## Input` section must list all three accepted forms explicitly. For skills with non-plan inputs (T-SQL source, STATISTICS output, trace grids), specify the exact column names and units expected (e.g., Duration in microseconds for `.trc` files).

---

## 3. Check ID Namespacing

**Where:** Check definitions in `SKILL.md` and corresponding `references/check-explanations.md`

Check IDs use a **single uppercase letter prefix + sequential number**. No prefix is reused across skills.

| Prefix | Skill | Scope | Count |
|--------|-------|-------|-------|
| `S` | `sqlplan-review` | Statement-level (once per query) | S1–S36 |
| `N` | `sqlplan-review` | Node-level (per operator) | N1–N72 |
| `C` | `sqlplan-compare` | Regression comparison checks | C1–C20 |
| `D` | `sqlindex-advisor` | Derived index rules (operator patterns) | D1–D10 |
| `P` | `sqldeadlock-review` | Deadlock patterns | P1–P16 |
| `T` | `tsql-review` | T-SQL static analysis checks | T1–T85 |
| `I` | `sqlstats-review` | IO metrics checks | I1–I18 |
| `W` | `sqlstats-review` | Time/wait metrics checks | W1–W9 |
| `X` | `sqltrace-review` | Trace event-level and workload checks | X1–X25 |
| `V` | `sqlwait-review` | Wait statistics checks + trend analysis | V1–V44 |
| `Q` | `sqlquerystore-review` | Query Store health and regression checks | Q1–Q32 |
| `R` | `sqlprocstats-review` | Procedure/trigger/function runtime stats | R1–R25 |
| `H` | `sqlhadr-review` | Always On AG health checks | H1–H28 (H21 retired) |
| `L` | `sqlclusterlog-review` | WSFC cluster log checks | L1–L30 |
| `E` | `sqlerrorlog-review` | SQL Server ERRORLOG checks | E1–E33 |
| `K` | `sqlspn-review` | SPN and Kerberos delegation checks | K1–K40 |
| `O` | `sqlmemory-review` | Memory pressure: PLE, plan cache, grants, clerks | O1–O20 |
| `Z` | `sqldiskio-review` | File I/O latency and auto-growth checks | Z1–Z15 |
| `A` | `sqlencryption-review` | Full encryption posture: TDE, AE, CLE, TLS, certs, key hierarchy, EKM, compliance | A1–A112 |
| `B` | `sqldbconfig-review` | Instance and database configuration drift | B1–B29 |
| `G` | `ssrstracelog-review` | SSRS report server trace log checks | G1–G24 |
| `F` | `sqlag-review` | Always On AG configuration audit | F1–F37 |
| `U` | `sqlbootstraplog-review` | SQL Server Setup Bootstrap log checks | U1–U24 |
| `Y` | `sqlmigration-review` | Migration version/edition/platform compatibility | Y1–Y15 |
| `J` | `sqlmigration-security-review` | Migration security-object portability | J1–J15 |
| `M` | `sqlmigration-objects-review` | Migration operational-object portability | M1–M16 |
| (none) | `sqlplan-batch` | Dispatcher — aggregates S/N from sqlplan-review | n/a |
| (none) | `mssql-performance-review` | Dispatcher — delegates to the 22 performance specialised skills (not the 3 migration skills — see `sqlmigration-review`'s Notes) | n/a |

**Available prefixes for new skills:** see `CLAUDE.md`'s "Check ID prefixes — currently taken" table for the canonical, up-to-date list — choose any unused single uppercase letter not in that table.

---

## 1.5. Skill Directory Layout

**Where:** Every skill directory under `skills/`.

The repository follows the Anthropic skill-creator anatomy adopted in the May-2026 restructure:

```
skills/<name>/
├── SKILL.md                       # required — runtime-loaded by the skill loader
├── references/                    # required — on-demand context, not auto-loaded
│   ├── README.md                  # required — load-when guidance per reference file
│   ├── check-explanations.md      # required — five-part check explanations + Quick Reference
│   └── <topic>.md                 # optional — additional progressive-disclosure references
├── evals/                         # required
│   └── evals.json                 # required — ≥ 2 realistic test prompts
├── scripts/                       # required — non-empty (.gitkeep acceptable for dispatchers)
│   └── *.sql                      # optional — capture / collection scripts the user runs
└── assets/                        # required — .gitkeep acceptable
    └── <template>.md              # optional — emitted artifacts (e.g. bundle templates)
```

**Convention:**

- Only `SKILL.md` is automatically loaded at runtime. `references/*.md` are progressive disclosure — Claude loads them when the situation matches the load-when guidance in `references/README.md`.
- `scripts/` holds **read-only capture scripts the user runs themselves** (the SQL/PowerShell that populates input artifacts for the skill). Dispatchers have no own scripts and use `.gitkeep`.
- `assets/` holds template files the skill emits as part of its output (e.g., the orchestrator's bundle README/paste-back templates). Use `.gitkeep` when no assets exist yet.
- `evals/evals.json` is mandatory (`scripts/verify-docs.sh` Check 28).
- This layout is enforced by Checks 3, 27, 28, 29, 30 in `verify-docs.sh`.

History note: prior to the restructure, every skill had a flat `CHECKS_EXPLAINED.md` at its root and there was a separate top-level `sql/` directory containing capture scripts. The restructure moved `CHECKS_EXPLAINED.md` into `references/check-explanations.md` and migrated `sql/<category>/` into the consuming skill's `scripts/` directory.

**Convention:** IDs are sequential and never reused within or across skills. When adding a check: assign the next available number, update the section header range (e.g., `N1–N66` → `N1–N67`), the frontmatter description count, and the Purpose section count. The same ID must appear in both `SKILL.md` and `references/check-explanations.md`.

---

## 4. Three-Part Check Structure (SKILL.md)

**Where:** Every check definition across all `SKILL.md` files

Each check has exactly three components, in this order:

```markdown
### X99 — Check Name
- **Trigger:** [condition that causes the check to fire — specific attribute, operator name, threshold]
- **Severity:** [Critical / Warning / Info] — [tier conditions if multiple]
- **Fix:** [Concrete action in one sentence or short list]
```

**Convention:** Trigger must be machine-readable. Severity must reference the central Thresholds Reference table for any numeric value — never hard-code a number in the check definition. Fix must be actionable — not "investigate further."

---

## 5. Five-Part Check Structure (references/check-explanations.md)

**Where:** Every check entry in every `skills/<name>/references/check-explanations.md`

Each check expands the `SKILL.md` entry into five parts:

1. **What it means** — plain-English explanation, no jargon assumed
2. **How to spot it** — specific XML attribute, SQL pattern, or trace column to look for, with a code block
3. **Example (problem + fix)** — before/after SQL or XML code blocks
4. **Fix options** — concrete steps ranked by impact (1 = highest)
5. **Related checks** — `**Related checks:** N21, S2` — IDs sharing a root cause or often co-triggered

**Convention:** "Related checks" must use check ID format (`N21`, not "bad row estimate"). Every entry must have at least one code block. Explanations must be written for someone unfamiliar with SQL Server internals. For skills with non-XML input (T-SQL source, trace grids), "How to spot it" shows the relevant source code or output line rather than XML.

---

## 6. Severity Tiers with Central Thresholds

**Where:** `## Thresholds Reference` table in every `SKILL.md`

Three severity levels; all numeric thresholds defined once in the skill's own Thresholds Reference table:

| Tier | Meaning | Action |
|------|---------|--------|
| **Critical** | Active bug, security risk, or data-loss scenario | Fix before anything else |
| **Warning** | Significant problem requiring attention | Fix in this session |
| **Info** | Noteworthy pattern; may be benign | Investigate and document intent |

**Convention:** Never hard-code a threshold number in a check definition. Use descriptive phrases (`≥ 1 GB`) and ensure the value appears in the skill's Thresholds Reference table. When a check has multiple tiers (Warning at X, Critical at Y), both values must be in the table.

---

## 7. Structured Output Template

**Where:** `## Output Format` section in every `SKILL.md`

All analysis skills share this base structure:

```
## [Skill Name] Analysis / Report

### Summary
- X Critical, Y Warnings, Z Info
- Primary bottleneck / Highest-risk: [check or query]

### Critical Issues   (labeled [C1], [C2], ...)
### Warnings          (labeled [W1], [W2], ...)
### Info              (labeled [I1], [I2], ...)
### [Skill-specific sections]
### Passed Checks     (what was explicitly verified clean)

---
*Analyzed by: [state the AI model and version you are running as, e.g. "Claude Sonnet 4.6", "DeepSeek R1", "GPT-4o"] · [current date and time in the user's local timezone, or UTC if timezone is unknown, e.g. "2026-05-16 20:15 NZST"]*
```

**Convention:** Output labels use `[C1]`, `[W1]`, `[I1]` — never raw check IDs. Check IDs (`S12`, `N41`) appear in parentheses after the issue name. Each finding must state: **Observed** (what's in the input) → **Impact** (why it matters) → **Fix** (what to do). The Passed Checks section explicitly lists verified-clean check IDs to signal analysis confidence.

---

## 8. Companion Skill Pipeline

**Where:** `## Companion Skills` section at the end of every `SKILL.md`; `PERFORMANCE_TUNING_GUIDE.md`; `README.md` workflow diagram

Skills compose into a pipeline ordered by diagnostic depth:

```
/tsql-review source.sql              — static: catch source-code anti-patterns before execution
    ↓
/sqlwait-review waits.txt            — server: identify dominant bottleneck (I/O, locks, CPU, memory)
/sqlstats-review                     — runtime I/O: measure reads, scans, timing per table
/sqltrace-review trace.txt           — workload: N+1 patterns, sniffing, top consumers
/sqlquerystore-review qs_output.txt    — QS: regressed queries, plan instability, top consumers
/sqlprocstats-review proc_stats.txt     — objects: top CPU/IO procedures, triggers, functions
    ↓
/sqlplan-review plan.sqlplan         — deep: operator choices, row estimates, memory, spills
/sqlindex-advisor plan.sqlplan  — indexes: ranked CREATE INDEX script
    ↓
/sqlplan-compare a.sqlplan b.sqlplan — regression: what changed and why
/sqldeadlock-review deadlock.xml       — deadlocks: lock cycle root cause and fix
    ↓
/sqlplan-batch folder/               — workload: aggregate dashboard across many plans
```

**Convention:** When a skill's output feeds another, document it explicitly in `## Companion Skills`. Aggregation skills (`sqlplan-batch`) must name their check source (`sqlplan-review`) rather than re-defining check logic. Cross-references must appear in both directions — if A lists B as a companion, B should list A.

---

## 9. Progressive Disclosure Layering

**Where:** Root-level `.md` files, `skills/*/SKILL.md`, `skills/*/references/check-explanations.md`, `CLAUDE.md`

The repository uses layered documentation for distinct audiences:

| Layer | File(s) | Audience | Depth |
|-------|---------|----------|-------|
| Navigation | `README.md` | Users — skill discovery and installation | Triggers, usage, output shape |
| Decision | `PERFORMANCE_TUNING_GUIDE.md` | Users — scenario-based skill selection | Which skill for which problem |
| Cost | `LLM_COST_ESTIMATION.md` | Users — token and dollar estimates | Skill sizes, worked examples |
| Rules | `skills/*/SKILL.md` | Claude (the model) | Precise triggers, thresholds, fix steps |
| Explanations | `skills/*/references/check-explanations.md` | Humans learning SQL Server | Conceptual, examples, alternatives |
| Contributor | `CLAUDE.md` | Developers adding skills | File map, conventions, update steps |
| Architecture | `.claude/docs/architectural_patterns.md` | Developers — this file | Cross-cutting patterns and conventions |

**Convention:** Do not duplicate content across layers. `README.md` links to other files but never duplicates check definitions. `SKILL.md` is the authoritative source for check logic — if a threshold changes, update `SKILL.md` first, then `references/check-explanations.md`. `PERFORMANCE_TUNING_GUIDE.md` and `LLM_COST_ESTIMATION.md` are user-facing reference docs, not skill instructions.

---

## 10. Dollar Sign Avoidance in Code Block Templates

**Where:** Any `## Output Format` or `## Cost Estimate` code block template in `SKILL.md`

The skill loader performs shell-style variable interpolation on `SKILL.md` content before passing it to the model. Dollar signs followed by digits (`$0`, `$3`, `$15`) or brackets (`$[...]`) are expanded as positional parameters or deprecated arithmetic expressions:

- `$0` → expands to the input file path argument
- `$3`, `$15` → expand to empty strings (unset positional parameters)
- `$[expr]` → deprecated bash arithmetic, may expand or error

**Convention:** Never use `$` in code block template placeholders or static cost amounts. Use `USD` prefix instead:
- `$0.012` → `USD 0.012`
- `$[input_tok × 0.000003]` → `[input_tok] × USD 3/M`
- `$3/M input` → `USD 3/M input`

This applies to any content inside fenced code blocks (` ``` `) as well as inline text in `SKILL.md`.

---

## 11. Example Folder Convention

**Where:** `skills/<name>/examples/` — co-located with each skill.

Each skill has an `examples/` subfolder containing:

| File pattern | Purpose |
|-------------|---------|
| `skills/<name>/examples/<input-file>` | Realistic input demonstrating multiple check triggers |
| `skills/<name>/examples/<input-file>-analysis.md` | Expected skill output — serves as a reference and regression baseline |

**Naming:**
- Input files use the natural extension for the skill: `.sql` (tsql-review), `.txt` (sqlstats-review, sqltrace-review), `.sqlplan` (plan skills), `.xml` / `.xdl` (deadlock)
- Analysis files append `-analysis.md` to the input file's stem

**Convention:** Input files must trigger a representative spread of severities (at least one Critical, multiple Warnings, at least one Info). Analysis files must follow the skill's `## Output Format` exactly — they serve as ground-truth examples for validating skill output quality.
