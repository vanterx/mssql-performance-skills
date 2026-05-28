# Output Format Reference — sqlplan-review

Detailed templates for sections that are structurally consistent across all analyses.
Load this file when producing the Prioritized Fix Sequence, Passed Checks table,
or the parameter-sniffing fix options block.

---

## Parameter Sniffing Fix Options Template

When `[I1] Parameter Sniffing` fires, use this template for the fix block:

```
### [I1] Parameter Sniffing — @ParamName compiled 'X', runtime 'Y'
- **Observed:** ParameterCompiledValue="X" vs ParameterRuntimeValue="Y"
- **Impact:** [how this explains the N21 estimate errors above — reference the
  specific cardinality collapse ratios from the W1 table]
- **Fix options:**
```sql
-- Option 1: Recompile per execution (best for infrequently-called queries)
OPTION (RECOMPILE)

-- Option 2: Optimize for a representative runtime value
OPTION (OPTIMIZE FOR (@Param = 'value'))

-- Option 3: Local variable (uses average density, prevents sniffing entirely)
DECLARE @Local <type> = @Param;
-- use @Local in the query body

-- Option 4: Filtered statistics for the common range
CREATE STATISTICS stat_col ON table (col) WHERE col >= 'value';
```
```

---

## Prioritized Fix Sequence Table Template

Order: (a) fixes that unblock other fixes first, (b) highest severity, (c) lowest effort.
Reference finding IDs (C1, W4, I1, etc.) in the Resolves column.

```
### Prioritized Fix Sequence

| Step | Action | Resolves |
|------|--------|----------|
| 1    | [action — be specific: index DDL, hint, config change] | C1, W4 |
| 2    | [action]                                              | I1, W7 |
| 3    | [action]                                              | W2, W3 |
```

**Ordering rules:**
- Root-cause fixes (parameter sniffing, stale statistics, type mismatches) go first — they unblock all downstream findings
- Index creations that depend on a predicate fix go after the predicate fix (e.g., index on a column must come after fixing CONVERT_IMPLICIT on that column)
- Informational findings (I-prefixed) go last unless they are root causes of W/C findings

---

## Passed Checks Table Template

Include every check explicitly evaluated and not triggered.
A complete PASS table signals the full ruleset was applied — omitting it signals an incomplete review.

Format:
```
### Passed Checks

| Check | Result |
|-------|--------|
| S1 — Serial Plan | PASS — DOP=8, plan is parallel |
| S2 — Excessive Memory Grant | PASS — grant is under-sized, not over-sized (S18 fired instead) |
| S8 — Ineffective Parallelism | NOT ASSESSED — elapsedTimeMs not present in this plan |
| ...   | ...    |
```

**Result conventions:**
- `PASS — [brief evidence]` for checks that were evaluated and cleanly passed
- `NOT ASSESSED — [reason]` when required attributes are absent from the XML (e.g., `actualRows` missing from an estimated-only plan, `elapsedTimeMs` not recorded)
- Never leave a row blank — every check needs an explicit disposition

**Common NOT ASSESSED reasons:**
- `NOT ASSESSED — estimated plan only; check requires actual runtime stats`
- `NOT ASSESSED — ActualElapsedms not present in RunTimeCountersPerThread`
- `NOT ASSESSED — actualRowsRead attribute not separately recorded in XML`
- `NOT ASSESSED — per-side probe/build row counts not individually specified`

---

## Attribution Footer

End every Passed Checks table with:

```
---
*Analyzed by: [AI model and version, e.g. "Claude Sonnet 4.6"] · [date/time in user's local timezone, or UTC if unknown, e.g. "2026-05-27 UTC"]*
```
