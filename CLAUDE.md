# mssql-performance-skills

A Claude Code skills library for SQL Server performance tuning — T-SQL static analysis, execution plan review, I/O statistics, workload traces, index recommendations, deadlock diagnosis, regression detection, and batch workload analysis.

## Purpose

Provides twenty-six slash-command skills — twenty-two specialised review skills, three SQL Server migration-readiness skills, plus one agentic orchestrator (`mssql-performance-review`) that dispatches the right specialised skill(s) to mixed artifact inputs. Specialised skills cover T-SQL source code, `.sqlplan` XML files, STATISTICS IO/TIME output, Profiler/XE trace data, deadlock graphs, index recommendations, wait statistics, Query Store data, procedure/trigger/function runtime stats collected from `sys.dm_exec_procedure_stats`, Always On AG health from `sys.dm_hadr_*` DMVs, Always On AG configuration correctness (prerequisites, replica design, listener architecture, backup strategy, endpoint security, distributed AG topology, Basic and Contained AG constraints), Windows Server Failover Cluster log files, SQL Server ERRORLOG files, SQL Server SPN and Kerberos delegation configuration, server memory pressure analysis, file-level I/O latency analysis, full encryption infrastructure (TDE, Always Encrypted, CLE, backup encryption, TLS, certificate/key lifecycle, key hierarchy, EKM, compliance), instance/database configuration drift (MAXDOP, Max Server Memory, auto-shrink, compatibility level, RCSI, VLF count, IFI, TempDB sizing, surface area), SQL Server Setup Bootstrap log analysis (failed installs/patches, setup rules, ConfigurationFile.ini review), SQL Server Reporting Services (SSRS) report server trace log analysis (trace configuration, database connectivity, memory/AppDomain recycling, report processing performance, subscription delivery, scale-out encryption keys), and SQL Server migration readiness (version/edition/platform compatibility, security-object portability, operational-object portability) for moves between on-prem instances and to/from Azure SQL. No application code — content is Markdown only.

## Tech Stack

- **Format:** Markdown + YAML frontmatter
- **Runtime:** Claude Code skill loader (reads `SKILL.md` files from `~/.claude/skills/`)
- **No build system, no tests, no dependencies**

## Key Files

### Skills (SKILL.md — loaded at runtime)

| File | Purpose |
|------|---------|
| [skills/mssql-performance-review/SKILL.md](skills/mssql-performance-review/SKILL.md) | Agentic offline orchestrator: `mssql-performance-review`. No checks of its own (dispatcher, like `sqlplan-batch`). Routes mixed artifacts to the 22 specialised skills, runs adversarial root-cause check, emits evidence chain + risk-rated fixes + rollback. |
| [skills/tsql-review/SKILL.md](skills/tsql-review/SKILL.md) | Static T-SQL source analysis: `tsql-review`. 85 checks (T1–T85) — structural, correctness, security, deprecated syntax, performance smells, SQL 2017–2022 modern syntax |
| [skills/sqlstats-review/SKILL.md](skills/sqlstats-review/SKILL.md) | STATISTICS IO/TIME parser + analysis: `sqlstats-review`. 27 checks (I1–I18 IO, W1–W9 time), per-statement tables, grand totals |
| [skills/sqltrace-review/SKILL.md](skills/sqltrace-review/SKILL.md) | Profiler / XE trace analysis: `sqltrace-review`. 25 checks (X1–X12 event-level, X13–X25 workload aggregate), top-consumer tables |
| [skills/sqlwait-review/SKILL.md](skills/sqlwait-review/SKILL.md) | Wait statistics analysis: `sqlwait-review`. 44 checks (V1–V44) — I/O, lock, parallelism, memory, CPU, latch, log space, poison/throttle waits, backup I/O, insert hotspots, cumulative skew, trend analysis, modern feature waits, memory grants, file I/O latency, IQP/PSP/ADR waits, TempDB metadata |
| [skills/sqlplan-review/SKILL.md](skills/sqlplan-review/SKILL.md) | Runtime plan analysis: `sqlplan-review`. 108 checks (S1–S36, N1–N72), thresholds, output format |
| [skills/sqlplan-compare/SKILL.md](skills/sqlplan-compare/SKILL.md) | Regression detection: `sqlplan-compare`. Diff two plans (C1–C20) |
| [skills/sqlindex-advisor/SKILL.md](skills/sqlindex-advisor/SKILL.md) | Index recommendations: `sqlindex-advisor`. Derive indexes from operator patterns (D1–D10) + optimizer suggestions + missing index DMVs |
| [skills/sqldeadlock-review/SKILL.md](skills/sqldeadlock-review/SKILL.md) | Deadlock analysis: `sqldeadlock-review`. 16 patterns (P1–P16), lock cycle extraction, remediation |
| [skills/sqlplan-batch/SKILL.md](skills/sqlplan-batch/SKILL.md) | Batch workload: `sqlplan-batch`. Aggregate dashboard across many `.sqlplan` files |
| [skills/sqlquerystore-review/SKILL.md](skills/sqlquerystore-review/SKILL.md) | Query Store analysis: `sqlquerystore-review`. 32 checks (Q1–Q32) — regressed queries, plan instability, resource hotspots, query waits, operational health, IQP/PSP/DOP/CE feedback, QS hints, auto-tuning |
| [skills/sqlprocstats-review/SKILL.md](skills/sqlprocstats-review/SKILL.md) | Procedure/trigger/function runtime stats analysis: `sqlprocstats-review`. 25 checks (R1–R25) — top consumers, per-execution efficiency, pattern detection, trend analysis |
| [skills/sqlclusterlog-review/SKILL.md](skills/sqlclusterlog-review/SKILL.md) | WSFC cluster log analysis: `sqlclusterlog-review`. 30 checks (L1–L30) — lease timeouts, health check failures, quorum loss, node eviction, network partition, RHS crashes, AG resource transitions |
| [skills/sqlhadr-review/SKILL.md](skills/sqlhadr-review/SKILL.md) | Always On AG health analysis: `sqlhadr-review`. 27 checks (H1–H28, H21 retired — merged into sqlag-review F15) — replica connectivity, data loss risk, recovery time, throughput, configuration, and seeding/initialization integrity |
| [skills/sqlag-review/SKILL.md](skills/sqlag-review/SKILL.md) | Always On AG configuration audit: `sqlag-review`. 37 checks (F1–F37) — prerequisites, replica design, listener architecture, backup strategy, endpoint security, distributed AG topology, Basic and Contained AG constraints, operational monitoring |
| [skills/sqlerrorlog-review/SKILL.md](skills/sqlerrorlog-review/SKILL.md) | SQL Server ERRORLOG analysis: `sqlerrorlog-review`. 33 checks (E1–E33) — AG failover events, lease expiry, memory pressure, I/O slow, corruption warnings, login failure bursts, startup/shutdown, and configuration signals |
| [skills/sqlspn-review/SKILL.md](skills/sqlspn-review/SKILL.md) | SPN and Kerberos delegation analysis: `sqlspn-review`. 40 checks (K1–K40) — MSSQLSvc SPN presence, service account binding, AG listener and alias, permissions, Kerberos delegation, AD account sensitivity |
| [skills/sqlmemory-review/SKILL.md](skills/sqlmemory-review/SKILL.md) | Memory pressure analysis: `sqlmemory-review`. 20 checks (O1–O20) — PLE, plan cache bloat, memory grants, memory clerks, ColumnStore/XTP footprint, OS pressure, LPIM, Max Server Memory |
| [skills/sqldiskio-review/SKILL.md](skills/sqldiskio-review/SKILL.md) | File-level I/O latency and auto-growth analysis: `sqldiskio-review`. 15 checks (Z1–Z15) — data/log latency, hot files, stall ratio, storage placement, auto-growth events and sizing |
| [skills/sqlencryption-review/SKILL.md](skills/sqlencryption-review/SKILL.md) | Full SQL Server encryption infrastructure analysis: `sqlencryption-review`. 112 checks (A1–A112) — TDE, Always Encrypted, CLE symmetric keys, backup encryption, transport/TLS, certificate lifecycle, asymmetric/symmetric key management, DMK/SMK key hierarchy (including sp_control_dbmasterkey_password and SSISDB), EKM/AKV, TLS/network hardening, Always Encrypted advanced (enclave attestation, driver compatibility), operational key lifecycle, SQL Server 2022 Ledger, Azure-specific encryption, dynamic data masking patterns, compliance explicit checks (PCI-DSS v4, HIPAA, GDPR, FedRAMP, CMMC, NY-DFS), operational validation (job step passwords, plan cache exposure, AKV soft-delete), advanced cryptographic patterns (ENCRYPTBYPASSPHRASE, HASHBYTES, Service Broker certs, NTLM) |
| [skills/sqldbconfig-review/SKILL.md](skills/sqldbconfig-review/SKILL.md) | Instance and database configuration drift analysis: `sqldbconfig-review`. 29 checks (B1–B29) — MAXDOP/NUMA alignment, Cost Threshold for Parallelism, Optimize for Ad Hoc Workloads, Max Server Memory, LPIM, auto-shrink, auto-close, compatibility level, RCSI, page verification, auto-statistics, Trustworthy, cross-DB chaining, VLF count, percent auto-growth, Instant File Initialization, TempDB file count, surface area exposure, service-SID sysadmin membership |
| [skills/sqlbootstraplog-review/SKILL.md](skills/sqlbootstraplog-review/SKILL.md) | SQL Server Setup Bootstrap log analysis: `sqlbootstraplog-review`. 24 checks (U1–U24) — failed install/patch outcome and exit codes, failed setup rules (pending reboot, disk space, accounts, prerequisites, cluster), Detail.txt/MSI forensics, ConfigurationFile.ini review (service accounts, IFI, TempDB, security surface, directories) |
| [skills/ssrstracelog-review/SKILL.md](skills/ssrstracelog-review/SKILL.md) | SQL Server Reporting Services trace log analysis: `ssrstracelog-review`. 24 checks (G1–G24) — trace configuration drift, report server database connectivity, memory thresholds and AppDomain recycling, report processing/data retrieval/rendering performance, subscription delivery failures, scale-out and encryption key health |
| [skills/sqlmigration-review/SKILL.md](skills/sqlmigration-review/SKILL.md) | SQL Server migration compatibility audit: `sqlmigration-review`. 15 checks (Y1–Y15) — edition-gated features, version/compatibility-level ceiling, collation, discontinued features, In-Memory OLTP, Azure SQL platform limits, backup/log-chain readiness, AG seeding edition limits, source lifecycle urgency. Dispatcher with own checks — routes to `sqlmigration-security-review`, `sqlmigration-objects-review`, and overlapping specialised skills |
| [skills/sqlmigration-security-review/SKILL.md](skills/sqlmigration-security-review/SKILL.md) | SQL Server migration security-object portability audit: `sqlmigration-security-review`. 15 checks (J1–J15) — login portability (orphaned users, SID mismatch, login type, password policy), permission fidelity (server/DB role membership, GRANT/DENY, ownership chains), credentials/proxies, certificates/keys, CMS registrations |
| [skills/sqlmigration-objects-review/SKILL.md](skills/sqlmigration-objects-review/SKILL.md) | SQL Server migration operational-object portability audit: `sqlmigration-objects-review`. 16 checks (M1–M16) — SQL Agent jobs/operators/alerts/proxies, linked servers, Database Mail, backup devices, custom error messages, server triggers, XE sessions, endpoints |

### Human Reference (references/check-explanations.md — not loaded at runtime by default)

| File | Purpose |
|------|---------|
| [skills/mssql-performance-review/references/check-explanations.md](skills/mssql-performance-review/references/check-explanations.md) | Methodology reference for the orchestrator: dispatch heuristics, symptom-to-probe-sequence map, hypothesis classes, recommendation conflict catalogue, and rationale for the standard analysis order |
| [skills/tsql-review/references/check-explanations.md](skills/tsql-review/references/check-explanations.md) | Plain-English explanation of all 85 T-checks with SQL examples, fix recipes, and Quick Reference table |
| [skills/sqlstats-review/references/check-explanations.md](skills/sqlstats-review/references/check-explanations.md) | Plain-English explanation of all 27 I/W checks with IO output examples and fix recipes |
| [skills/sqltrace-review/references/check-explanations.md](skills/sqltrace-review/references/check-explanations.md) | Plain-English explanation of all 25 X-checks with trace output examples, capture how-tos, and quick reference |
| [skills/sqlwait-review/references/check-explanations.md](skills/sqlwait-review/references/check-explanations.md) | Plain-English explanation of all 44 V-checks with wait type descriptions, capture queries, and category quick reference |
| [skills/sqlplan-review/references/check-explanations.md](skills/sqlplan-review/references/check-explanations.md) | Plain-English explanation of all 108 S/N checks with XML examples and fix recipes |
| [skills/sqlplan-compare/references/check-explanations.md](skills/sqlplan-compare/references/check-explanations.md) | C1–C20 regression checks explained — what each change means and why it causes a slowdown |
| [skills/sqlindex-advisor/references/check-explanations.md](skills/sqlindex-advisor/references/check-explanations.md) | Plain-English explanation of all 10 D-checks (D1–D10) with XML examples, fix recipes, filtered index and hash match guidance, and Quick Reference table |
| [skills/sqldeadlock-review/references/check-explanations.md](skills/sqldeadlock-review/references/check-explanations.md) | P1–P16 deadlock patterns, lock concepts, how to capture XML |
| [skills/sqlplan-batch/references/check-explanations.md](skills/sqlplan-batch/references/check-explanations.md) | How to read each dashboard section, prioritisation guide, next-step workflow |
| [skills/sqlquerystore-review/references/check-explanations.md](skills/sqlquerystore-review/references/check-explanations.md) | Plain-English explanation of all 32 Q-checks with Query Store DMV examples and fix recipes |
| [skills/sqlprocstats-review/references/check-explanations.md](skills/sqlprocstats-review/references/check-explanations.md) | Plain-English explanation of all 25 R-checks with collection table examples and fix recipes |
| [skills/sqlclusterlog-review/references/check-explanations.md](skills/sqlclusterlog-review/references/check-explanations.md) | Plain-English explanation of all 30 L-checks with CLUSTER.LOG examples, fix recipes, and Quick Reference table |
| [skills/sqlhadr-review/references/check-explanations.md](skills/sqlhadr-review/references/check-explanations.md) | Plain-English explanation of all 27 H-checks with DMV examples, fix recipes, and Quick Reference table |
| [skills/sqlag-review/references/check-explanations.md](skills/sqlag-review/references/check-explanations.md) | Plain-English explanation of all 37 F-checks with catalog view examples, T-SQL fix recipes, and Quick Reference table |
| [skills/sqlerrorlog-review/references/check-explanations.md](skills/sqlerrorlog-review/references/check-explanations.md) | Plain-English explanation of all 33 E-checks with ERRORLOG examples, fix recipes, and Quick Reference table |
| [skills/sqlspn-review/references/check-explanations.md](skills/sqlspn-review/references/check-explanations.md) | Plain-English explanation of all 40 K-checks with setspn/AD attribute examples, delegation model tables, and Quick Reference table |
| [skills/sqlmemory-review/references/check-explanations.md](skills/sqlmemory-review/references/check-explanations.md) | Plain-English explanation of all 20 O-checks with DMV examples, fix recipes, and Quick Reference table |
| [skills/sqldiskio-review/references/check-explanations.md](skills/sqldiskio-review/references/check-explanations.md) | Plain-English explanation of all 15 Z-checks with sys.dm_io_virtual_file_stats examples, fix recipes, and Quick Reference table |
| [skills/sqlencryption-review/references/check-explanations.md](skills/sqlencryption-review/references/check-explanations.md) | Plain-English explanation of all 112 A-checks with DMV examples, T-SQL fix code, and Quick Reference table covering all 20 categories |
| [skills/sqlencryption-review/references/concepts.md](skills/sqlencryption-review/references/concepts.md) | Background concepts (19 topics): symmetric vs asymmetric encryption, public/private keys, SQL Server algorithm reference, key hierarchy, TLS deep dive, FIPS 140-2, PCI-DSS, HIPAA, GDPR, SOX, FedRAMP, ISO 27001, TDE performance, DR with encryption, AE performance, SQL Ledger, DMK password auto-open (sp_control_dbmasterkey_password), passphrase-based encryption (PBKDF1 vs PBKDF2), DDM vs encryption |
| [skills/sqlencryption-review/references/howto-tde-setup.md](skills/sqlencryption-review/references/howto-tde-setup.md) | Step-by-step TDE deployment guide: cert creation, DEK, enabling encryption, monitoring scan, cert backup, restore procedure |
| [skills/sqlencryption-review/references/howto-always-encrypted.md](skills/sqlencryption-review/references/howto-always-encrypted.md) | Step-by-step Always Encrypted setup: CMK (AKV/Windows), CEK, column encryption, app changes, enclave config, CLE migration |
| [skills/sqlencryption-review/references/howto-tls-config.md](skills/sqlencryption-review/references/howto-tls-config.md) | Step-by-step TLS 1.2/1.3 config: certificate request from CA, binding, ForceEncryption, cipher suite ordering, verification |
| [skills/sqlencryption-review/references/howto-key-rotation.md](skills/sqlencryption-review/references/howto-key-rotation.md) | Step-by-step key rotation: TDE cert, backup cert, SB/AG endpoint certs, CLE symmetric keys, AE CMK/CEK, DMK/SMK regeneration |
| [skills/sqlencryption-review/references/howto-crypto-shredding.md](skills/sqlencryption-review/references/howto-crypto-shredding.md) | Step-by-step cryptographic erasure for GDPR right-to-erasure via per-customer encryption keys |
| [skills/sqlencryption-review/references/howto-disaster-recovery.md](skills/sqlencryption-review/references/howto-disaster-recovery.md) | Step-by-step DR for encrypted databases: TDE restore, encrypted backup restore, cross-version, AG failover, CMK migration, SMK regeneration |
| [skills/sqlencryption-review/references/howto-dmk-password-management.md](skills/sqlencryption-review/references/howto-dmk-password-management.md) | Step-by-step sp_control_dbmasterkey_password guide: SSISDB setup, cross-server restore, AG replica registration, SMK restore invalidation, sys.master_key_passwords internals |
| [skills/sqlencryption-review/references/howto-dynamic-data-masking.md](skills/sqlencryption-review/references/howto-dynamic-data-masking.md) | DDM decision guide: masking vs encryption, UNMASK permission management, DDM interaction with AE/CLE, DDM + RLS patterns |
| [skills/sqlencryption-review/references/howto-agent-jobs.md](skills/sqlencryption-review/references/howto-agent-jobs.md) | Secure SQL Agent job patterns: certificate-based key opens, proxy credentials, TRY/CATCH cleanup, alerts for encryption errors, job step audit queries |
| [skills/sqlencryption-review/references/error-reference.md](skills/sqlencryption-review/references/error-reference.md) | Common encryption errors reference: Msg 33111, 33104, 15581, 33081, 15318, self-signed cert, audit failures, EKM errors, enclave attestation, TLS handshake errors |
| [skills/sqldbconfig-review/references/check-explanations.md](skills/sqldbconfig-review/references/check-explanations.md) | Plain-English explanation of all 28 B-checks with T-SQL examples, fix recipes, and Quick Reference table |
| [skills/sqlbootstraplog-review/references/check-explanations.md](skills/sqlbootstraplog-review/references/check-explanations.md) | Plain-English explanation of all 24 U-checks with Summary.txt/Detail.txt/MSI log excerpts, fix recipes, and Quick Reference table |
| [skills/ssrstracelog-review/references/check-explanations.md](skills/ssrstracelog-review/references/check-explanations.md) | Plain-English explanation of all 24 G-checks with trace log/config excerpts, fix recipes, and Quick Reference table |
| [skills/sqlmigration-review/references/check-explanations.md](skills/sqlmigration-review/references/check-explanations.md) | Plain-English explanation of all 15 Y-checks with T-SQL examples, fix recipes, and Quick Reference table |
| [skills/sqlmigration-security-review/references/check-explanations.md](skills/sqlmigration-security-review/references/check-explanations.md) | Plain-English explanation of all 15 J-checks with T-SQL examples, fix recipes, and Quick Reference table |
| [skills/sqlmigration-objects-review/references/check-explanations.md](skills/sqlmigration-objects-review/references/check-explanations.md) | Plain-English explanation of all 16 M-checks with T-SQL examples, fix recipes, and Quick Reference table |

### Root Documentation

| File | Purpose |
|------|---------|
| [README.md](README.md) | User-facing guide: triggers, input formats, output samples for all 26 skills |
| [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) | Decision guide: which skill to use for which scenario, symptom-based routing, artifact capture how-tos, 829-check ID reference |
| [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) | Token and dollar cost breakdown per skill — worked examples, cost control strategies, prompt caching guide |
| [skills/VERSION_COMPATIBILITY.md](skills/VERSION_COMPATIBILITY.md) | SQL Server version compatibility matrix — which of the 829 checks apply to SQL 2008 R2 through SQL 2022 and Azure SQL; skill-level support matrix; cumulative active check counts per version |
| [.claude/docs/architectural_patterns.md](.claude/docs/architectural_patterns.md) | Cross-cutting conventions: check ID namespacing, input polymorphism, output format, companion pipeline, dollar-sign avoidance |
| [.claude-plugin/marketplace.json](.claude-plugin/marketplace.json) | Claude Code plugin marketplace manifest — registers this repo as a marketplace with one plugin entry pointing to `./` |
| [.claude-plugin/plugin.json](.claude-plugin/plugin.json) | Plugin manifest — declares `"skills": "./skills"` so all 26 SKILL.md files are discovered by the plugin system |
| [mcp-server/src/index.ts](mcp-server/src/index.ts) | MCP server entry point — CORS preflight, `GET /health`, error handling, then Cloudflare Workers fetch handler using `WebStandardStreamableHTTPServerTransport` (stateless, one server per request) |
| [mcp-server/src/skill-loader.ts](mcp-server/src/skill-loader.ts) | `SkillMeta` interface — no fs access; all skill data pre-bundled into `skills-data.ts` at deploy time |
| [mcp-server/src/skills-data.ts](mcp-server/src/skills-data.ts) | Generated file — run `npm run bundle` to regenerate from `skills/*/SKILL.md`. Do not edit manually |
| [mcp-server/scripts/bundle-skills.ts](mcp-server/scripts/bundle-skills.ts) | Build-time codegen: reads all SKILL.md files + PERFORMANCE_TUNING_GUIDE.md → writes `skills-data.ts` |
| [mcp-server/wrangler.toml](mcp-server/wrangler.toml) | Cloudflare Workers config — worker name `mssql-mcp`, live at `https://mssql-mcp.tsx113.workers.dev` |
| [mcp-server/src/tools.ts](mcp-server/src/tools.ts) | MCP tools: `list_skills`, `get_skill`, `route_artifact` (13 artifact types including `mixed` → orchestrator) |
| [mcp-server/src/resources.ts](mcp-server/src/resources.ts) | MCP resources: `mssql://skills`, `mssql://skills/{name}` (×18), `mssql://guide` |
| [mcp-server/src/prompts.ts](mcp-server/src/prompts.ts) | MCP prompts: one per skill, accepts `{ input }` and returns analysis prompt via shared `buildAnalysisPrompt` |
| [mcp-server/src/prompt-builder.ts](mcp-server/src/prompt-builder.ts) | Shared `buildAnalysisPrompt(skillName, skillContent, input)` helper used by both `tools.ts` and `prompts.ts` |
| [.github/workflows/deploy-mcp.yml](.github/workflows/deploy-mcp.yml) | GitHub Actions CD — auto-deploys to Cloudflare Workers on push when `mcp-server/`, `skills/`, or `PERFORMANCE_TUNING_GUIDE.md` changes |
| [.mcp.json](.mcp.json) | Project-scoped MCP server config — registers the `microsoft-learn` HTTP server (`https://learn.microsoft.com/api/mcp`) so every contributor gets Microsoft Learn validation tools without per-machine setup; see [.claude/docs/ms-learn-validation.md](.claude/docs/ms-learn-validation.md) |

### AgentWorks Orchestration (autonomous issue-driven workflow)

Adopted from [vanterx/agentworks](https://github.com/vanterx/agentworks): lets an AI coding agent claim a GitHub issue, do the work in an isolated git worktree, open a PR, and pass adversarial review before merge — with bash scripts (never the agent) owning every label change and merge decision. Solo review mode; `AW_AGENT=claude` by default, `opencode` also supported.

| File | Purpose |
|------|---------|
| [AGENT_CONTRACT.md](AGENT_CONTRACT.md) | Operating contract for the claim/work/review/merge loop — separate from [AGENTS.md](AGENTS.md), which covers this repo's own conventions |
| [aw.conf](aw.conf) | Committed team-wide defaults (`AW_AGENT`, timeouts, TDD enforcement — off, no test suite here) |
| [scripts/start_work.sh](scripts/start_work.sh) | Worker loop: claims available work, runs the agent, opens a PR |
| [scripts/review_work.sh](scripts/review_work.sh) | Adversarial reviewer loop: reviews open PRs, sets the merge-gate check |
| [scripts/reap.sh](scripts/reap.sh) | Garbage collector: frees stale claims and reworks |
| [scripts/merge_ready.sh](scripts/merge_ready.sh) | Evaluates trust-model approval and merges READY PRs |
| [scripts/doctor.sh](scripts/doctor.sh) | Read-only deployment health check — run after setup and whenever the loop misbehaves |
| [scripts/render_prompt.sh](scripts/render_prompt.sh) | Previews the exact prompt a loop would send, without running the agent |
| [scripts/metrics.sh](scripts/metrics.sh) | Reports queue/throughput metrics from the audit log |
| [scripts/lib/common.sh](scripts/lib/common.sh) | Shared library: agent dispatch (claude/codex/hermes/opencode), trust config, worktree isolation, audit logging |
| [prompts/work.md](prompts/work.md), [prompts/rework.md](prompts/rework.md), [prompts/review.md](prompts/review.md) | Prompt templates rendered by the loop scripts |
| [.github/labels.yml](.github/labels.yml) | Reference label taxonomy for the status-lifecycle state machine |
| [.github/trusted-reviewers.json](.github/trusted-reviewers.json) | Whitelist + required-approval count read by `merge_ready.sh` |
| [.github/workflows/issue-status.yml](.github/workflows/issue-status.yml), [reap.yml](.github/workflows/reap.yml) | Scheduled/triggered automation for the issue-status state machine |
| [.github/workflows/ci.yml](.github/workflows/ci.yml) | Lints the orchestration scripts themselves (`bash -n`, shellcheck, YAML, `tests/run.sh`) |
| [.github/workflows/validate.yml](.github/workflows/validate.yml) | Runs `scripts/verify-docs.sh` against `skills/` on every PR, from the base branch's trusted copy |
| [tests/run.sh](tests/run.sh) | Zero-dependency test harness for `scripts/lib/common.sh` |
| [.claude/docs/aw/AUTOMATION.md](.claude/docs/aw/AUTOMATION.md) | Status-label state machine reference |
| [.claude/docs/aw/OPERATIONS.md](.claude/docs/aw/OPERATIONS.md) | Day-to-day operations: monitoring, troubleshooting, recipes |
| [.claude/docs/aw/GETTING_STARTED.md](.claude/docs/aw/GETTING_STARTED.md) | Manual (non-agent-driven) setup walkthrough, kept for reference |
| [.claude/docs/aw/SETUP.md](.claude/docs/aw/SETUP.md) | End-to-end trial-run walkthrough against `example/NOTES.md` |
| [.claude/skills/onboard-contributor/SKILL.md](.claude/skills/onboard-contributor/SKILL.md), [.claude/skills/triage-task/SKILL.md](.claude/skills/triage-task/SKILL.md) | Contributor-facing skills for getting started and advisory issue triage |
| [example/NOTES.md](example/NOTES.md) | Toolchain-free target for validating the loop end-to-end; delete once confirmed working |

### Examples

| Path | What it demonstrates |
|------|---------------------|
| [skills/sqlplan-review/examples/horrible.sqlplan](skills/sqlplan-review/examples/horrible.sqlplan) | Reference bad plan: parameter sniffing, spills, implicit conversion, key lookups |
| [skills/sqlplan-review/examples/horrible-analysis.md](skills/sqlplan-review/examples/horrible-analysis.md) | Reference output of `/sqlplan-review` on the above plan |
| [skills/tsql-review/examples/](skills/tsql-review/examples/) | `slow_proc.sql` with 12 anti-patterns + expected analysis |
| [skills/sqlstats-review/examples/](skills/sqlstats-review/examples/) | SSMS STATISTICS IO/TIME output + expected analysis |
| [skills/sqlplan-compare/examples/](skills/sqlplan-compare/examples/) | Baseline + regression `.sqlplan` pair + diff analysis |
| [skills/sqldeadlock-review/examples/](skills/sqldeadlock-review/examples/) | P1 lock-order deadlock XML + analysis |
| [skills/sqltrace-review/examples/](skills/sqltrace-review/examples/) | `fn_trace_gettable` output with N+1, sniffing, spills + analysis |
| [skills/sqlwait-review/examples/](skills/sqlwait-review/examples/) | `sys.dm_os_wait_stats` output with I/O, lock, memory, CXPACKET + analysis |
| [skills/sqlindex-advisor/examples/](skills/sqlindex-advisor/examples/) | Index advisor output for `horrible.sqlplan` |
| [skills/sqlplan-batch/examples/](skills/sqlplan-batch/examples/) | Aggregate dashboard for a 3-plan batch |
| [skills/sqlquerystore-review/examples/](skills/sqlquerystore-review/examples/) | Query Store DMV output with plan instability, forced plan failure, N+1 + analysis |
| [skills/sqlprocstats-review/examples/](skills/sqlprocstats-review/examples/) | Q1 report output with CPU hotspot, parameter sniffing, N+1 caller, blocking signal + analysis |
| [skills/sqlclusterlog-review/examples/](skills/sqlclusterlog-review/examples/) | CLUSTER.LOG with lease timeout, heartbeat loss, AG offline transition, VerboseLogging=0 + analysis |
| [skills/sqlhadr-review/examples/](skills/sqlhadr-review/examples/) | 3-replica AG with disconnected secondary, 620 MB redo queue, secondary lag 85 sec + analysis |
| [skills/sqlag-review/examples/](skills/sqlag-review/examples/) | 3-replica AG catalog output: failure_condition_level=1, SIMPLE recovery database, SUPPORTED endpoint encryption, session_timeout=10 on WAN replica, backup priority ties, no read-only routing URL + analysis |
| [skills/sqlerrorlog-review/examples/](skills/sqlerrorlog-review/examples/) | ERRORLOG with I/O slow → AG lease expiry → failover sequence, login failure burst, trace flags + analysis |
| [skills/sqlspn-review/examples/](skills/sqlspn-review/examples/) | setspn + AD attribute output: duplicate SPN, unconstrained delegation, missing delegation target SPN, end-user in Protected Users + analysis |
| [skills/sqlmemory-review/examples/](skills/sqlmemory-review/examples/) | Memory clerk + PLE + grant queue output: ColumnStore pressure, single-use plan bloat, oversized grant blocking 4 sessions + analysis |
| [skills/sqldiskio-review/examples/](skills/sqldiskio-review/examples/) | sys.dm_io_virtual_file_stats + auto-growth trace: 47 ms data reads, 31 ms log writes, 3 auto-grow events on same volume + analysis |
| [skills/sqlencryption-review/examples/](skills/sqlencryption-review/examples/) | Multi-database encryption audit DMV output: TDE off on HRPayroll/ArchiveDB, expired TDE cert, RC4/3DES CLE keys, unencrypted backups, plaintext remote sessions, no SMK/DMK backup, self-signed TLS + analysis |
| [skills/sqldbconfig-review/examples/](skills/sqldbconfig-review/examples/) | sp_configure + sys.databases + sys.master_files + VLF count output: MAXDOP=0 on 4-NUMA, Max Server Memory unset, auto-shrink on SalesDB, ReportDB at compat 100 with auto-close + percent growth + analysis |
| [skills/ssrstracelog-review/examples/](skills/ssrstracelog-review/examples/) | SSRS trace config + LogFiles listing + Event Log + ExecutionLog3 output: report server database connectivity outage, verbose trace switch, processing timeout, file share subscription impersonation failure + analysis |

### Scripts

| File | Purpose |
|------|---------|
| [skills/sqlencryption-review/scripts/capture-all-encryption.ps1](skills/sqlencryption-review/scripts/capture-all-encryption.ps1) | PowerShell: captures all encryption DMVs to timestamped output files |
| [skills/sqlencryption-review/scripts/test-tls.ps1](skills/sqlencryption-review/scripts/test-tls.ps1) | PowerShell: verifies TLS configuration via SChannel registry + connection test |
| [skills/sqlencryption-review/scripts/README.md](skills/sqlencryption-review/scripts/README.md) | Script usage guide with prerequisites and examples |
| [skills/sqlbootstraplog-review/scripts/check-pending-reboot.ps1](skills/sqlbootstraplog-review/scripts/check-pending-reboot.ps1) | PowerShell: detects pending-reboot conditions (CBS, Windows Update, PendingFileRenameOperations, pending rename, SCCM) that fail SQL Server Setup's "Restart computer" rule — companion to `sqlbootstraplog-review` U7 |
| [skills/sqlbootstraplog-review/scripts/README.md](skills/sqlbootstraplog-review/scripts/README.md) | Script usage guide: signals checked, parameters, exit codes, automation pattern |
| [skills/ssrstracelog-review/scripts/collect-ssrs-diagnostics.ps1](skills/ssrstracelog-review/scripts/collect-ssrs-diagnostics.ps1) | PowerShell: collects RStrace config, Service config, trace log rollover counts, recent ERROR/Exception lines, and Application Event Log entries for the Report Server Windows Service |
| [skills/ssrstracelog-review/scripts/README.md](skills/ssrstracelog-review/scripts/README.md) | Script usage guide: sections collected, parameters, prerequisites, ExecutionLog3 query handoff |
| [skills/sqlag-review/scripts/capture-ag-config.sql](skills/sqlag-review/scripts/capture-ag-config.sql) | T-SQL: collects sys.availability_groups, sys.availability_replicas, sys.availability_group_listeners, sys.availability_group_listener_ip_addresses, sys.database_mirroring_endpoints, AG database recovery models, certificates, and XE sessions in one batch |

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
cp -r skills/* ~/.claude/skills/          # global (all 26 skills)
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
2. Choose an unused single-letter check prefix (current: S, N, C, D, P, T, I, W, X, V, Q, R, H, L, E, K, O, Z, A, B, U, G, F, Y, J, M are taken)
3. Add the skill to the Key Files tables above
4. Add install line to [README.md](README.md) Installation section and `## Skills` table
5. Add a full `## <skill-name>` section to [README.md](README.md) with triggers, usage, and output sample
6. Add the skill to [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) Skills at a Glance, Skill Scope Comparison, and relevant scenario sections
7. Add the skill file size row to [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md)
8. Add example input + analysis files to `skills/<skill-name>/examples/`
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

### Branch policy
Every change must be made on a new branch — never commit directly to `main`. Before starting work, create a branch (e.g. `git checkout -b <type>/<short-description>`), commit there, and open a PR to merge into `main`. This keeps `main` clean and ensures all changes go through review. Branch names follow the commit `<type>` vocabulary (`feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`).

### Before committing
Always run `bash scripts/verify-docs.sh` — it checks documentation invariants and exits non-zero on any failure. The PostToolUse hook in `.claude/settings.json` runs it automatically after Write/Edit, but run it manually before `git commit` too.

### Dollar signs in SKILL.md code block templates
Never use `$0`, `$3`, `$15`, or `$[...]` inside SKILL.md files. The skill loader performs shell-style variable expansion on the entire file content, so `$0` expands to the input file path argument and `$3`/`$15` expand to empty strings. Use `USD` prefix instead: `USD 0.012`, `[tokens] × USD 3/M`.

### Check ID prefixes — currently taken
| Prefix | Skill |
|--------|-------|
| `S`, `N` | `sqlplan-review` |
| `C` | `sqlplan-compare` |
| `D` | `sqlindex-advisor` |
| `P` | `sqldeadlock-review` |
| `T` | `tsql-review` |
| `I`, `W` | `sqlstats-review` |
| `X` | `sqltrace-review` |
| `V` | `sqlwait-review` |
| `Q` | `sqlquerystore-review` |
| `R` | `sqlprocstats-review` |
| `H` | `sqlhadr-review` |
| `L` | `sqlclusterlog-review` |
| `E` | `sqlerrorlog-review` |
| `K` | `sqlspn-review` |
| `O` | `sqlmemory-review` |
| `Z` | `sqldiskio-review` |
| `A` | `sqlencryption-review` |
| `B` | `sqldbconfig-review` |
| `U` | `sqlbootstraplog-review` |
| `G` | `ssrstracelog-review` |
| `F` | `sqlag-review` |
| `Y` | `sqlmigration-review` — dispatcher with own checks; routes overlap to `sqlmigration-security-review`/`sqlmigration-objects-review` and other specialised skills |
| `J` | `sqlmigration-security-review` |
| `M` | `sqlmigration-objects-review` |
| (none) | `mssql-performance-review` — dispatcher; delegates checks to other skills, like `sqlplan-batch` |

New skills must choose an unused single uppercase letter, or document why they are dispatcher-style (no prefix) like the orchestrator and `sqlplan-batch`.

### references/check-explanations.md is not loaded at runtime by default
Only `SKILL.md` is loaded automatically by the Claude Code skill loader. The `references/check-explanations.md` file is human reference and on-demand context — Claude may load it when a user asks "explain check X" or for deeper fix-option detail. Do not put trigger conditions or thresholds there that Claude needs to act on without prompting.

### Microsoft Learn validation (mandatory)
All new and modified skills, checks, scripts, and reference content must be validated against current Microsoft Learn documentation before being considered complete. Use the Microsoft Learn MCP tools (`microsoft_docs_search`, `microsoft_docs_fetch`) to verify every DMV column name, T-SQL syntax, PowerShell cmdlet, configuration setting, and version compatibility claim. If documentation cannot be found, mark the content as "Unverified" rather than assuming correctness. Full policy: [`.claude/docs/ms-learn-validation.md`](.claude/docs/ms-learn-validation.md)

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
| Microsoft Learn MCP validation policy (mandatory) | [.claude/docs/ms-learn-validation.md](.claude/docs/ms-learn-validation.md) |
| Scenario-based skill selection, symptom routing | [PERFORMANCE_TUNING_GUIDE.md](PERFORMANCE_TUNING_GUIDE.md) |
| Token costs and cost control strategies | [LLM_COST_ESTIMATION.md](LLM_COST_ESTIMATION.md) |
| SQL Server version compatibility matrix | [skills/VERSION_COMPATIBILITY.md](skills/VERSION_COMPATIBILITY.md) |
| Skill usage, triggers, input/output examples | [README.md](README.md) |
| All check triggers, thresholds, fix logic | Each skill's `SKILL.md` — see Key Files table above |
| Plain-English check explanations with examples | Each skill's `references/check-explanations.md` — see Key Files table above |
