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
| `sqlplan-review` | ~18,400 |
| `tsql-review` | ~15,000 |
| `sqlwait-review` | ~22,600 |
| `sqltrace-review` | ~7,100 |
| `sqlstats-review` | ~6,700 |
| `query-store-review` | ~8,900 |
| `sqlplan-index-advisor` | ~4,800 |
| `procstats-review` | ~7,300 |
| `sqlplan-deadlock` | ~5,200 |
| `sqlplan-compare` | ~4,200 |
| `sqlplan-batch` | ~3,100 |
| `clusterlog-review` | ~8,800 |
| `hadr-health-review` | ~7,800 |
| `errorlog-review` | ~8,800 |
| `spn-review` | ~7,400 |
| `mssql-performance-review` | ~7,900 |

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
SKILL.md:          18,400  tokens in
.sqlplan input:    12,000  tokens in
────────────────────────────────────
Total input:       34,400  tokens

Output report:      2,000  tokens out

Cost (Sonnet 4.6):
  input:  34,400 × $3/M  =  $0.103
  output:  2,000 × $15/M =  $0.030
  ──────────────────────────────────
  Total per call:           $0.133
```

### `/tsql-review` on a 300-line stored procedure

```
System context:    4,000  tokens in
SKILL.md:         15,000  tokens in
T-SQL source:      2,400  tokens in
───────────────────────────────────
Total input:      21,400  tokens

Output report:     1,500  tokens out

Cost (Sonnet 4.6):
  input:  21,400 × $3/M  =  $0.064
  output:  1,500 × $15/M =  $0.023
  ──────────────────────────────────
  Total per call:           $0.087
```

### `/sqlstats-review` on 10 statements, 30 tables

```
System context:    4,000  tokens in
SKILL.md:          6,700  tokens in
STATISTICS text:   1,000  tokens in
───────────────────────────────────
Total input:      11,700  tokens

Output report:     1,800  tokens out

Cost (Sonnet 4.6):
  input:  11,700 × $3/M  =  $0.035
  output:  1,800 × $15/M =  $0.027
  ──────────────────────────────────
  Total per call:           $0.062
```

### `/sqlplan-batch` on a folder of 20 medium plans

```
System context:       4,000  tokens in
SKILL.md:             3,100  tokens in
20 plans × 12,000:  240,000  tokens in
──────────────────────────────────────
Total input:        247,100  tokens

Output dashboard:     5,000  tokens out

Cost (Sonnet 4.6):
  input:  247,100 × $3/M  =  $0.741
  output:   5,000 × $15/M =  $0.075
  ──────────────────────────────────
  Total per call:            $0.816
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
| `sqlplan-deadlock` | ~5,200 tok | 10,000–13,000 | **$0.04–$0.06** |
| `sqlplan-compare` | ~4,200 tok | 12,000–38,000 | **$0.05–$0.13** |
| `sqlstats-review` | ~6,700 tok | 12,000–18,000 | **$0.05–$0.07** |
| `spn-review` (setspn + AD attributes) | ~7,400 tok | 13,000–16,000 | **$0.05–$0.07** |
| `sqltrace-review` (small trace, ~500 events) | ~7,100 tok | 15,000–24,000 | **$0.06–$0.10** |
| `query-store-review` (top 20 queries) | ~8,900 tok | 16,000–22,000 | **$0.06–$0.09** |
| `errorlog-review` | ~8,800 tok | 16,000–25,000 | **$0.06–$0.10** |
| `clusterlog-review` | ~8,800 tok | 15,000–26,000 | **$0.06–$0.10** |
| `hadr-health-review` | ~7,800 tok | 14,000–22,000 | **$0.05–$0.09** |
| `procstats-review` | ~7,300 tok | 14,000–22,000 | **$0.05–$0.09** |
| `tsql-review` | ~15,000 tok | 21,000–30,000 | **$0.08–$0.12** |
| `sqlwait-review` (single snapshot) | ~22,600 tok | 27,000–30,000 | **$0.10–$0.12** |
| `sqlwait-review` (trend, 4+ snapshots) | ~22,600 tok | 31,000–38,000 | **$0.12–$0.16** |
| `sqlplan-review` (medium plan) | ~18,400 tok | 30,000–80,000 | **$0.12–$0.29** |
| `sqlplan-review` (large plan) | ~18,400 tok | 80,000–160,000 | **$0.29–$0.55** |
| `sqltrace-review` (large trace, ~10,000 events) | ~7,100 tok | 55,000–160,000 | **$0.19–$0.51** |
| `sqlplan-batch` (10 plans) | ~3,100 tok | 127,000–173,000 | **$0.40–$0.57** |

Output tokens ($15/M on Sonnet 4.6) are significant — a detailed 3,000-token report adds ~$0.045 regardless of which skill ran. Asking for a summary instead of a full report cuts output cost 50–70%.

---

## Cost Control Strategies

### 1. Use the cheapest skill that answers the question

`/sqlstats-review` (input ~12K tokens, ~$0.06) often identifies the problem table and whether the issue is I/O or waits. Only then pull out `/sqlplan-review` (~34K tokens, ~$0.13) for operator-level detail.

**Order of cost (cheapest first):**
```
/sqlplan-deadlock ≈ /sqlplan-compare ≈ /sqlstats-review ≈ /spn-review
  < /sqltrace-review (small) ≈ /query-store-review ≈ /errorlog-review
  ≈ /clusterlog-review ≈ /hadr-health-review ≈ /procstats-review
  < /tsql-review < /sqlwait-review < /sqlplan-review (small)
  < /sqlplan-review (large) ≈ /sqltrace-review (large) < /sqlplan-batch
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

Once you confirm the plan is worth analyzing, paste the full XML for the complete 107-check review.

### 4. Filter before running sqlplan-batch

`/sqlplan-batch` has a linear cost curve — 20 plans cost ~20× one plan. Use Query Store or Extended Events to pre-filter to the top 10 queries by CPU or duration before running batch analysis.

### 5. Leverage prompt caching

Claude caches the skill file (SKILL.md) after the first call in a session. Subsequent calls that reuse the same skill do not re-pay for those tokens. A multi-step session — `/tsql-review` → `/sqlstats-review` → `/sqlplan-review` — is cheaper than three independent conversations because the system context and earlier skill files stay cached.

### 6. Ask for summaries on large outputs

For `/sqlplan-batch` across many plans, ask for the executive summary and top 5 findings rather than the full per-plan detail. This reduces output tokens from ~5,000 to ~1,500 — saving ~$0.05 per batch run.

---

## Prompt Caching — How It Reduces Repeat Costs

Claude's prompt cache has a **5-minute TTL**. If you run `/sqlplan-review` on plan A, then immediately run `/sqlplan-index-advisor` on the same plan, the 18,400-token SKILL.md for `sqlplan-review` is still cached — but `sqlplan-index-advisor`'s SKILL.md is new. Within one tuning session, skills called multiple times on similar inputs benefit the most from caching.

Cache write cost: **$3.75/M tokens** (one-time on first call).  
Cache read cost: **$0.30/M tokens** (on subsequent hits within TTL).

For a session that calls `/sqlplan-review` three times on different plans:
- First call: $3.75/M write + $3/M read for uncached portions
- Second and third call (within 5 min): $0.30/M for the cached SKILL.md portion

On the 18,400-token `sqlplan-review` SKILL.md, that saves ~$0.050 per cached call — meaningful across a full workload review session.

---

## Orchestrator Session Cost

When `/mssql-performance-review` receives a mixed-artifact incident (wait stats + two execution plans + trace + ERRORLOG + AG health DMVs), it dispatches five or six specialised skill calls. Here is a worked example:

```
Call 1 — /sqlwait-review (wait stats snapshot):
  System context:  4,000 tokens in
  SKILL.md:       22,600 tokens in
  Wait stats:      2,000 tokens in
  ─────────────────────────────────
  Input:          28,600    Output: 2,500

Call 2 — /sqlplan-review (plan A):
  System context:  4,000 tokens in
  SKILL.md:       18,400 tokens in   ← new; not yet cached
  Plan XML:       12,000 tokens in
  ─────────────────────────────────
  Input:          34,400    Output: 2,500

Call 3 — /sqlplan-review (plan B):
  SKILL.md:       18,400 tokens in   ← cached ($0.30/M instead of $3/M)
  Plan XML:       12,000 tokens in   ← uncached
  ─────────────────────────────────
  Input:          34,400    Output: 2,500

Call 4 — /sqltrace-review (small XE trace):
  SKILL.md:        7,100 tokens in
  Trace events:    8,000 tokens in
  ─────────────────────────────────
  Input:          19,100    Output: 2,000

Call 5 — /errorlog-review:
  SKILL.md:        8,800 tokens in
  ERRORLOG text:   3,000 tokens in
  ─────────────────────────────────
  Input:          15,800    Output: 2,000

Call 6 — /hadr-health-review:
  SKILL.md:        7,800 tokens in
  DMV output:      2,000 tokens in
  ─────────────────────────────────
  Input:          13,800    Output: 2,000

─────────────────────────────────────────────────────────────────
Total input:   ~146,100 tokens   Total output: ~13,500 tokens

Cost without caching (Sonnet 4.6):
  input:  146,100 × $3/M  =  $0.438
  output:  13,500 × $15/M =  $0.203
  ──────────────────────────────────
  Total:                     $0.641

Cost with prompt caching on call 3 (sqlplan-review SKILL.md):
  Cache write (call 2 SKILL.md): 18,400 × $3.75/M = $0.069  (one-time)
  Cache read  (call 3 SKILL.md): 18,400 × $0.30/M = $0.006  (saves ~$0.049)
  ──────────────────────────────────────────────────────────
  Effective total:                                   ~$0.59
```

**Rule of thumb:** A full six-skill incident review session on Sonnet 4.6 costs **USD 0.55–0.70** without caching, **USD 0.50–0.65** with caching. Haiku 4.5 at ~5× lower rates brings this to **USD 0.11–0.14** for high-volume automation.

---

## Token Count Reference

These files are loaded by the skill loader and contribute to every call's input cost:

| File | Characters | ~Tokens |
|------|-----------|--------|
| `skills/sqlwait-review/SKILL.md` | 85,792 | 22,577 |
| `skills/sqlplan-review/SKILL.md` | 69,993 | 18,419 |
| `skills/tsql-review/SKILL.md` | 56,773 | 14,940 |
| `skills/mssql-performance-review/SKILL.md` | 30,128 | 7,928 |
| `skills/hadr-health-review/SKILL.md` | 29,755 | 7,830 |
| `skills/spn-review/SKILL.md` | 27,960 | 7,358 |
| `skills/procstats-review/SKILL.md` | 27,612 | 7,266 |
| `skills/sqltrace-review/SKILL.md` | 26,862 | 7,069 |
| `skills/sqlstats-review/SKILL.md` | 25,389 | 6,681 |
| `skills/clusterlog-review/SKILL.md` | 33,533 | 8,824 |
| `skills/errorlog-review/SKILL.md` | 33,598 | 8,841 |
| `skills/query-store-review/SKILL.md` | 33,876 | 8,915 |
| `skills/sqlplan-index-advisor/SKILL.md` | 18,126 | 4,770 |
| `skills/sqlplan-deadlock/SKILL.md` | 19,780 | 5,205 |
| `skills/sqlplan-compare/SKILL.md` | 16,037 | 4,220 |
| `skills/sqlplan-batch/SKILL.md` | 11,646 | 3,065 |

`references/check-explanations.md` files are progressive-disclosure reference material — they are **not** loaded into the LLM context automatically. Only `SKILL.md` is loaded by the skill loader. Claude may load `references/check-explanations.md` on demand (e.g., when a user asks "explain check X" or wants deeper fix-option detail).

If a user asks "explain check X" — for example, "explain S21" or "explain N44" — Claude loads the corresponding `references/check-explanations.md` on demand. This adds **3,000–42,000 tokens** to that call depending on which skill the check belongs to.

| File | Characters | ~Tokens | Used at runtime? |
|------|-----------|--------|-----------------|
| `skills/sqlplan-review/references/check-explanations.md` | 161,371 | 42,466 | On demand |
| `skills/tsql-review/references/check-explanations.md` | 120,038 | 31,589 | On demand |
| `skills/sqlwait-review/references/check-explanations.md` | 94,164 | 24,780 | On demand |
| `skills/spn-review/references/check-explanations.md` | 62,181 | 16,363 | On demand |
| `skills/clusterlog-review/references/check-explanations.md` | 61,286 | 16,128 | On demand |
| `skills/sqltrace-review/references/check-explanations.md` | 43,529 | 11,455 | On demand |
| `skills/sqlstats-review/references/check-explanations.md` | 43,103 | 11,343 | On demand |
| `skills/query-store-review/references/check-explanations.md` | 42,067 | 11,070 | On demand |
| `skills/errorlog-review/references/check-explanations.md` | 49,198 | 12,947 | On demand |
| `skills/hadr-health-review/references/check-explanations.md` | 39,737 | 10,457 | On demand |
| `skills/procstats-review/references/check-explanations.md` | 33,982 | 8,943 | On demand |
| `skills/sqlplan-deadlock/references/check-explanations.md` | 24,632 | 6,482 | On demand |
| `skills/sqlplan-compare/references/check-explanations.md` | 24,014 | 6,320 | On demand |
| `skills/sqlplan-index-advisor/references/check-explanations.md` | 9,952 | 2,619 | On demand |
| `skills/sqlplan-batch/references/check-explanations.md` | 10,878 | 2,863 | On demand |
| `skills/mssql-performance-review/references/check-explanations.md` | 10,481 | 2,758 | On demand |
