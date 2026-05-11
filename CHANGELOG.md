# Changelog

All notable changes to mssql-performance-skills are documented here. Follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) conventions.

---

## [Unreleased]

### Fixed
- sqlwait-review check count corrected to 40 (V1–V40) in PERFORMANCE_TUNING_GUIDE.md and CLAUDE.md — was stale at 36 and 29
- Added sqltrace-review and sqlwait-review to LLM_COST_ESTIMATION.md Skill file size table — both were missing from the per-skill cost section

### Added
- `verify-docs.sh` Check 26: asserts per-skill check count in PERFORMANCE_TUNING_GUIDE.md Skills at a Glance matches the actual SKILL.md count (catches future count drift)
- PERFORMANCE_TUNING_GUIDE.md: new "I want to find my worst stored procedures" scenario and "I don't know which procedure to tune" symptom path for procstats-review
- README.md: Quick Start section with 5-minute path to first analysis
- CLAUDE.md: documented `changes.log` as a local-only development scratch log
- Query Store example elevated to gold standard: investigation SQL for forced plan failures, execution time variance ratio, improved Passed Checks table
- Clean sqlplan example demonstrating a well-tuned query that passes most checks

---

## [302 checks — 11 skills] — 2026-04

### Added
- `sqlplan-review`: 12 new checks S28–S33 and N61–N66 (87 → 99 checks) — multi-statement plan support, additional node-level patterns
- `sqlwait-review`: checks V37–V40 — forced memory grants, grant timeouts, stolen memory, file-level I/O latency
- `sqlwait-review`: checks V30–V36 — modern feature wait types (In-Memory OLTP, Columnstore, Query Store, Transaction/DTC, Service Broker, Full Text Search, Parallel Redo)
- `query-store-review`: new skill — 25 checks (Q1–Q25) across regressed queries, plan instability, resource hotspots, query waits, operational health
- `procstats-review`: new skill — 20 checks (R1–R20) with full DMV collection framework and data capture scripts
- `verify-docs.sh` Checks 21–25: skill-creator compliance (line count, description word count, trigger phrases, frontmatter fields, ALWAYS/NEVER/MUST style)

### Changed
- All skills updated for skill-creator compliance: descriptions ≥ 30 words with trigger phrases, `triggers:` field required in frontmatter
- Schema-qualified object names (`dbo.TableName`) consistently used in skill output and examples
- sqlplan-review examples moved to `example/sqlplan-review/` subfolder (consistent with other skills)
- npx install method added to README and CLAUDE.md

---

## [234 checks — 9 skills] — Initial release

### Added
- `tsql-review`: 50 checks (T1–T50) — structural, security, correctness, deprecated syntax, performance smells
- `sqlstats-review`: 22 checks (I1–I15 IO, W1–W7 time) — STATISTICS IO/TIME parser
- `sqltrace-review`: 20 checks (X1–X20) — Profiler / Extended Events workload analysis
- `sqlwait-review`: 29 checks (V1–V29) — wait statistics analysis
- `sqlplan-review`: 87 checks (S1–S27, N1–N60) — execution plan deep analysis
- `sqlplan-compare`: 10 checks (C1–C10) — plan regression detection
- `sqlplan-index-advisor`: derivation rules D1–D8 — ranked CREATE INDEX script
- `sqlplan-deadlock`: 8 patterns (P1–P8) — deadlock root-cause analysis
- `sqlplan-batch`: aggregator — batch dashboard across many plans
- `PERFORMANCE_TUNING_GUIDE.md`: scenario-based routing, symptom lookup, artifact guide, 234-check ID reference
- `LLM_COST_ESTIMATION.md`: token and dollar cost breakdown per skill
- Example inputs and reference analyses for all 9 skills
