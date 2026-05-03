# LLM Cost Estimation for SqlPlanClaudeSkills

How to estimate what each skill invocation costs in tokens and dollars.

---

## How LLM Pricing Works

You pay for **input tokens + output tokens**. Current Claude rates:

| Model | Input | Output |
|-------|-------|--------|
| Sonnet 4.6 | $3 / M tokens | $15 / M tokens |
| Haiku 4.5 | $0.80 / M tokens | $4 / M tokens |
| Opus 4.7 | $15 / M tokens | $75 / M tokens |

**Token rule of thumb:** 1 token ≈ 3.8 characters of English/code text.

---

## What Goes Into Input Tokens

Every skill call has three components:

```
Input tokens = System context + Skill (SKILL.md) + Your input (plan / SQL / stats)
```

### System context

Claude Code's own instructions, tool definitions, CLAUDE.md, and conversation history. Approximately **2,000–6,000 tokens** at session start, growing as the conversation continues.

### Skill file size (SKILL.md loaded per invocation)

| Skill | SKILL.md tokens |
|-------|----------------|
| `sqlplan-review` | ~11,300 |
| `tsql-review` | ~8,500 |
| `sqlstats-review` | ~4,800 |
| `sqlplan-index-advisor` | ~3,700 |
| `sqlplan-deadlock` | ~2,400 |
| `sqlplan-compare` | ~1,750 |
| `sqlplan-batch` | ~1,500 |
| `query-store-review` | ~3,400 |

### Your input artifact

| Input | Typical tokens |
|-------|---------------|
| Small `.sqlplan` (~20 operators) | 1,500–4,000 |
| Medium `.sqlplan` (~60 operators) | 8,000–16,000 |
| Large `.sqlplan` (~150 operators, multi-statement) | 30,000–55,000 |
| STATISTICS output — 1 statement, 5 tables | ~100 |
| STATISTICS output — 10 statements, 30 tables | ~1,000 |
| T-SQL stored proc, 50 lines | ~400 |
| T-SQL stored proc, 300 lines | ~2,400 |
| Deadlock XML, 2-process graph | ~800 |
| Folder of 20 plans (`sqlplan-batch`) | 20 × plan size |

---

## Cost Per Invocation — Worked Examples

### `/sqlplan-review` on a medium plan (60 operators)

```
System context:     4,000  tokens in
SKILL.md:          11,300  tokens in
.sqlplan input:    12,000  tokens in
────────────────────────────────────
Total input:       27,300  tokens

Output report:      2,000  tokens out

Cost (Sonnet 4.6):
  input:  27,300 × $3/M  =  $0.082
  output:  2,000 × $15/M =  $0.030
  ──────────────────────────────────
  Total per call:           $0.112
```

### `/tsql-review` on a 300-line stored procedure

```
System context:    4,000  tokens in
SKILL.md:          8,500  tokens in
T-SQL source:      2,400  tokens in
───────────────────────────────────
Total input:      14,900  tokens

Output report:     1,500  tokens out

Cost (Sonnet 4.6):
  input:  14,900 × $3/M  =  $0.045
  output:  1,500 × $15/M =  $0.023
  ──────────────────────────────────
  Total per call:           $0.068
```

### `/sqlstats-review` on 10 statements, 30 tables

```
System context:    4,000  tokens in
SKILL.md:          4,800  tokens in
STATISTICS text:   1,000  tokens in
───────────────────────────────────
Total input:       9,800  tokens

Output report:     1,800  tokens out

Cost (Sonnet 4.6):
  input:   9,800 × $3/M  =  $0.029
  output:  1,800 × $15/M =  $0.027
  ──────────────────────────────────
  Total per call:           $0.056
```

### `/sqlplan-batch` on a folder of 20 medium plans

```
System context:       4,000  tokens in
SKILL.md:             1,500  tokens in
20 plans × 12,000:  240,000  tokens in
──────────────────────────────────────
Total input:        245,500  tokens

Output dashboard:     5,000  tokens out

Cost (Sonnet 4.6):
  input:  245,500 × $3/M  =  $0.737
  output:   5,000 × $15/M =  $0.075
  ──────────────────────────────────
  Total per call:            $0.812
```

### Full tuning session (tsql-review → sqlstats-review → sqlplan-review → sqlplan-index-advisor)

```
4 skill invocations × ~$0.07–$0.11 each
+ conversation history grows ~5,000–10,000 tokens by the last call
─────────────────────────────────────────────────────────────────
Estimated total:  $0.30–$0.45 for the full session
```

---

## The Dominant Cost Driver: Plan Size

`.sqlplan` XML is verbose. A multi-statement plan with 150 operators can be 200,000+ characters (~53,000 tokens) — easily dwarfing the skill file itself.

### Real-world plan sizes

| Query type | Typical plan size | Approx tokens |
|-----------|-----------------|--------------|
| Single-table lookup | 3,000–8,000 chars | 800–2,100 |
| 5-table OLTP query | 15,000–40,000 chars | 4,000–10,500 |
| Complex reporting query | 60,000–150,000 chars | 16,000–39,500 |
| Multi-statement stored proc | 100,000–500,000 chars | 26,000–130,000 |

For plans above ~100,000 characters, Sonnet 4.6 input cost alone exceeds **$0.30 per invocation**.

---

## Summary Table

| Skill | Skill overhead | Typical total input | Cost per call (Sonnet 4.6) |
|-------|--------------|---------------------|---------------------------|
| `sqlwait-review` (single snapshot) | ~7,000 tok | 8,000–12,000 | **$0.03–$0.05** |
| `sqlwait-review` (trend, 4+ snapshots) | ~7,000 tok | 14,000–22,000 | **$0.05–$0.08** |
| `sqlstats-review` | ~4,800 tok | 6,000–12,000 | **$0.02–$0.05** |
| `sqltrace-review` (small trace, ~500 events) | ~5,200 tok | 10,000–20,000 | **$0.04–$0.09** |
| `sqltrace-review` (large trace, ~10,000 events) | ~5,200 tok | 50,000–150,000 | **$0.18–$0.47** |
| `sqlplan-compare` | ~1,750 tok | 8,000–35,000 | **$0.03–$0.12** |
| `sqlplan-deadlock` | ~2,400 tok | 7,000–10,000 | **$0.03–$0.05** |
| `tsql-review` | ~8,500 tok | 13,000–20,000 | **$0.05–$0.09** |
| `sqlplan-review` (medium plan) | ~11,300 tok | 17,000–70,000 | **$0.07–$0.25** |
| `sqlplan-review` (large plan) | ~11,300 tok | 70,000–160,000 | **$0.25–$0.55** |
| `sqlplan-batch` (10 plans) | ~1,500 tok | 85,000–165,000 | **$0.27–$0.53** |
| `query-store-review` (top 20 queries) | ~3,400 tok | 8,000–12,000 | **$0.04–$0.07** |

Output tokens ($15/M on Sonnet 4.6) are significant — a detailed 3,000-token report adds ~$0.045 regardless of which skill ran. Asking for a summary instead of a full report cuts output cost 50–70%.

---

## Cost Control Strategies

### 1. Use the cheapest skill that answers the question

`/sqlstats-review` (input ~10K tokens, ~$0.05) often identifies the problem table and whether the issue is I/O or waits. Only then pull out `/sqlplan-review` (~30K tokens, ~$0.12) for operator-level detail.

**Order of cost (cheapest first):**
```
/sqlstats-review < /sqlplan-deadlock < /sqlplan-compare
  < /tsql-review < /sqlplan-review (small) < /sqlplan-review (large)
  < /sqlplan-batch
```

### 2. Trim large plans before pasting

If a stored proc has 8 statements and statement 3 is slow, export only that statement's plan from SSMS. The SSMS plan viewer lets you select a subtree — right-click an operator → **Show Execution Plan for Selected Node**.

### 3. Describe instead of paste for initial exploration

All skills accept natural-language descriptions. This costs ~50 tokens instead of 12,000 for raw XML — useful when exploring whether a plan is worth deep analysis:

```
/sqlplan-review
The plan has a Key Lookup on Orders executing 48,000 times at 78% cost,
and a Hash Match join with estimated 500 rows but actual 4.2M rows.
```

Once you confirm the plan is worth analyzing, paste the full XML for the complete 87-check review.

### 4. Filter before running sqlplan-batch

`/sqlplan-batch` has a linear cost curve — 20 plans cost ~20× one plan. Use Query Store or Extended Events to pre-filter to the top 10 queries by CPU or duration before running batch analysis.

### 5. Leverage prompt caching

Claude caches the skill file (SKILL.md) after the first call in a session. Subsequent calls that reuse the same skill do not re-pay for those tokens. A multi-step session — `/tsql-review` → `/sqlstats-review` → `/sqlplan-review` — is cheaper than three independent conversations because the system context and earlier skill files stay cached.

### 6. Ask for summaries on large outputs

For `/sqlplan-batch` across many plans, ask for the executive summary and top 5 findings rather than the full per-plan detail. This reduces output tokens from ~5,000 to ~1,500 — saving ~$0.05 per batch run.

---

## Prompt Caching — How It Reduces Repeat Costs

Claude's prompt cache has a **5-minute TTL**. If you run `/sqlplan-review` on plan A, then immediately run `/sqlplan-index-advisor` on the same plan, the 11,300-token SKILL.md for `sqlplan-review` is still cached — but `sqlplan-index-advisor`'s SKILL.md is new. Within one tuning session, skills called multiple times on similar inputs benefit the most from caching.

Cache write cost: **$3.75/M tokens** (one-time on first call).  
Cache read cost: **$0.30/M tokens** (on subsequent hits within TTL).

For a session that calls `/sqlplan-review` three times on different plans:
- First call: $3.75/M write + $3/M read for uncached portions
- Second and third call (within 5 min): $0.30/M for the cached SKILL.md portion

On the 11,300-token `sqlplan-review` SKILL.md, that saves ~$0.031 per cached call — meaningful across a full workload review session.

---

## Token Count Reference

These files are loaded by the skill loader and contribute to every call's input cost:

| File | Characters | ~Tokens |
|------|-----------|--------|
| `skills/sqlplan-review/SKILL.md` | 42,933 | 11,298 |
| `skills/tsql-review/SKILL.md` | 32,452 | 8,540 |
| `skills/sqlstats-review/SKILL.md` | 18,198 | 4,788 |
| `skills/sqltrace-review/SKILL.md` | ~19,800 | ~5,200 |
| `skills/sqlplan-index-advisor/SKILL.md` | 13,876 | 3,651 |
| `skills/sqlplan-deadlock/SKILL.md` | 9,210 | 2,423 |
| `skills/sqlplan-compare/SKILL.md` | 6,645 | 1,748 |
| `skills/sqlplan-batch/SKILL.md` | 5,595 | 1,472 |
| `skills/query-store-review/SKILL.md` | ~12,800 | ~3,400 |

`CHECKS_EXPLAINED.md` files are reference material for humans — they are **not** loaded into the LLM context during skill execution. Only `SKILL.md` is loaded.

| File | Characters | ~Tokens | Used at runtime? |
|------|-----------|--------|-----------------|
| `skills/sqlplan-review/CHECKS_EXPLAINED.md` | 136,730 | 35,981 | No |
| `skills/tsql-review/CHECKS_EXPLAINED.md` | 67,148 | 17,670 | No |
| `skills/sqlstats-review/CHECKS_EXPLAINED.md` | 34,134 | 8,982 | No |
| `skills/sqlplan-deadlock/CHECKS_EXPLAINED.md` | 16,084 | 4,232 | No |
| `skills/sqlplan-compare/CHECKS_EXPLAINED.md` | 12,950 | 3,407 | No |
| `skills/sqlplan-batch/CHECKS_EXPLAINED.md` | 10,542 | 2,774 | No |
| `skills/sqlplan-index-advisor/CHECKS_EXPLAINED.md` | 9,612 | 2,529 | No |
