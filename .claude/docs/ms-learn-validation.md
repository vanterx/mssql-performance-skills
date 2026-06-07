# Microsoft Learn MCP Validation Requirement

## Mandatory Documentation Validation

When creating, modifying, reviewing, or validating any skill, check, script, query, runbook, architectural pattern, troubleshooting guide, automation, or reference documentation, Microsoft Learn MCP must be used as the primary source of truth.

---

## Requirements

### 1. Documentation First

- Validate all Microsoft technologies against current Microsoft Learn documentation before implementation.
- Do not rely solely on memory, assumptions, previous examples, blog posts, forum discussions, or AI-generated content.

### 2. New Skills

- Every new skill must be verified against Microsoft Learn MCP.
- All commands, parameters, APIs, PowerShell cmdlets, T-SQL syntax, configuration settings, and recommended practices must be validated.
- Include links or references to the Microsoft Learn articles used during validation.

### 3. Checks and Validation Scripts

- Every check must confirm that referenced objects, columns, tables, views, DMVs, catalog views, APIs, and configuration settings are supported and documented.
- Verify version compatibility for SQL Server, Azure SQL, Windows Server, Azure, and related Microsoft products.
- Confirm that no deprecated or unsupported features are being used.

### 4. Architectural Patterns

- All architectural guidance must align with current Microsoft reference architectures, best practices, and supportability guidance from Microsoft Learn.
- Any deviation from Microsoft recommendations must be explicitly documented and justified.

### 5. Repository Reviews

- When reviewing existing content, validate every file against Microsoft Learn MCP.
- Identify outdated guidance, deprecated features, unsupported syntax, broken references, and version-specific issues.

### 6. Accuracy Standard

- Microsoft Learn MCP is the authoritative validation source.
- If documentation cannot be found, the content must be flagged as "Unverified" rather than assumed correct.
- Accuracy takes precedence over speed.

---

## Completion Criteria

A skill, check, script, query, or architectural pattern is not considered complete until:

- [ ] Microsoft Learn MCP validation has been performed
- [ ] All Microsoft-specific content has been verified
- [ ] Version compatibility has been confirmed
- [ ] Documentation references have been reviewed
- [ ] No unsupported assumptions remain

---

## How to Use the MS Learn MCP Tools

Three tools are available (already whitelisted in `.claude/settings.json`):

| Tool | Use When |
|------|----------|
| `microsoft_docs_search` | First pass — search for a topic and get up to 10 content chunks (max 500 tokens each). Use this to quickly verify a claim or find the right article. |
| `microsoft_code_sample_search` | Need a concrete code example — returns up to 20 official code samples. Use when verifying T-SQL syntax, PowerShell patterns, or API usage. |
| `microsoft_docs_fetch` | Need the full page — use after search when you need complete details (all parameters, full version tables, prerequisites). Required for detailed troubleshooting or when search results are incomplete. |

**Workflow:** Search gives breadth → Code samples give practical examples → Fetch gives depth.

### Common Validation Targets

| Claim type | What to validate |
|------------|-----------------|
| DMV column name (e.g., `sys.dm_hadr_database_replica_states.secondary_lag_seconds`) | Column exists and version it was added |
| T-SQL syntax / built-in function (e.g., `CERTPROPERTY`, `STRING_SPLIT`) | Supported property names, argument types, return values |
| Enum / integer value (e.g., `encryption_state`, `execution_type`) | All valid values and their meanings |
| Registry key / config value | Exact key name, value type, default |
| PowerShell cmdlet / parameter | Parameter name, syntax, supported OS/version |
| Deprecated feature | Whether still supported, since when deprecated, recommended replacement |

---

## Background: Why This Policy Exists

During a June 2026 audit of all 19 skills against Microsoft Learn MCP, ~25 inaccuracies were found and corrected, including:

- `CERTPROPERTY('Algorithm')` — always returns NULL; property name not supported
- `sys.symmetric_keys.pvt_key_encryption_type_desc` — column does not exist (belongs to `sys.certificates`)
- `sys.query_store_runtime_stats.execution_type` values — 1/2 are not valid; correct values are 3 (aborted) and 4 (exception)
- `sys.query_store_plan_feedback.feedback_type` — column does not exist; correct columns are `feature_id` / `feature_desc`
- `ForceEncryption` registry `value_name` — was coded as `'Encrypt'`
- `CXCONSUMER` version gate — "SQL 2016 SP2 CU3+" is a common misquote; correct threshold is SQL 2016 SP2 (any CU) / SQL 2017 CU3
- `xml_deadlock_report` in `system_health` — available from SQL 2012+, not 2008+

These errors were all catchable by a single `microsoft_docs_search` call. The policy prevents this class of regression from re-entering the repo.
