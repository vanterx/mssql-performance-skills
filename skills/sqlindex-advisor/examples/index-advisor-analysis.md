# Index Advisor Report — `horrible.sqlplan`

> **Input:** `skills/sqlplan-review/examples/horrible.sqlplan`
>
> Run with: `/sqlindex-advisor skills/sqlplan-review/examples/horrible.sqlplan`
>
> *(For full output see [skills/sqlindex-advisor/examples/index-advisor-analysis.md](index-advisor-analysis.md) — this demonstrates the standard output format)*

## Input Summary
- Plans analyzed: 1
- Operator-derived candidates (Source A): 4 (D1, D2 × 2, D5)
- Optimizer suggestions (Source B): 1 (Users.Email, Impact 99.999)
- After unified merge: 3 recommendations
- Tables affected: 2 (`dbo.Orders`, `dbo.Users`)

---

## Recommended Indexes (Ranked)

### [I1] dbo.Orders — Score: 94.0 `[derived: D1 + D2 combined]`

```sql
CREATE NONCLUSTERED INDEX [IX_Orders_UserId_CreatedDate]
ON [dbo].[Orders] ([UserId], [CreatedDate])
INCLUDE ([Id], [Status], [TotalAmount])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

- **Source:** Key Lookup elimination (D1, 5,000,000 executions) + implicit conversion scan (D2)
- **Covers:** Eliminates 5M Key Lookup executions; enables range seek on `CreatedDate` once implicit conversion is resolved
- **Prerequisite:** Fix `@StartDate` parameter type (see I2)
- **Warnings:** Extend `INCLUDE` to cover all columns referenced in `SELECT o.*`

### [I2] dbo.Orders — Implicit Conversion Fix (schema/query change) `[derived: D2]`

```sql
-- Fix the @StartDate parameter type to match the Orders.CreatedDate column type
-- If CreatedDate is DATE:
DECLARE @StartDate date;
-- If CreatedDate is DATETIME2:
DECLARE @StartDate datetime2(7);

-- Or cast on the literal side instead of converting the column:
WHERE CreatedDate >= CAST(@StartDate AS date)
```

- **Source:** `CONVERT_IMPLICIT(datetime, [Orders].[CreatedDate])` — non-sargable predicate (D2)
- **Impact:** Restores range seek on `CreatedDate`; fixes the 1-vs-9.9M row estimate that causes Sort Level 2 and Hash Level 3 spills

### [I3] dbo.Users — Email Domain Filter `[optimizer: Source B, Impact 99.999 — partial]`

```sql
-- Standard NC index NOT recommended — LIKE '%gmail.com' (leading wildcard) cannot use it.
-- Use a computed persisted column for exact domain matching instead:
ALTER TABLE [dbo].[Users]
    ADD [EmailDomain] AS REVERSE(LEFT(REVERSE([Email]), CHARINDEX('@', REVERSE([Email])) - 1)) PERSISTED;

CREATE NONCLUSTERED INDEX [IX_Users_EmailDomain]
ON [dbo].[Users] ([EmailDomain])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

- **Source:** Optimizer `MissingIndexGroup` (Impact 99.999) — adjusted for leading-wildcard limitation
- **Rewrite required:** Change `WHERE u.Email LIKE '%gmail.com'` → `WHERE u.EmailDomain = 'gmail.com'`
- **Warnings:** Optimizer impact score of 99.999 assumes an equality seek; actual benefit depends on the query rewrite being applied

---

## Skipped / Flagged

| Table | Check | Reason | Action |
|-------|-------|--------|--------|
| Sort (Node 5) | D5 | Spill is a symptom of bad cardinality from implicit conversion — not a missing sort-order index | Apply I2 first; re-evaluate |
| Payments | — | No operator-level index opportunity visible | Verify `IX_Payments_OrderId` exists |

---

## Deployment Script

```sql
-- ============================================================
-- Deploy in order:
-- ============================================================

-- STEP 1: Fix implicit conversion (prerequisite for I1 range seek)
-- Adjust @StartDate parameter type in calling code / stored procedure.

-- STEP 2: Orders covering index
CREATE NONCLUSTERED INDEX [IX_Orders_UserId_CreatedDate]
ON [dbo].[Orders] ([UserId], [CreatedDate])
INCLUDE ([Id], [Status], [TotalAmount])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);

-- STEP 3: Users email domain index + query rewrite
ALTER TABLE [dbo].[Users]
    ADD [EmailDomain] AS REVERSE(LEFT(REVERSE([Email]), CHARINDEX('@', REVERSE([Email])) - 1)) PERSISTED;

CREATE NONCLUSTERED INDEX [IX_Users_EmailDomain]
ON [dbo].[Users] ([EmailDomain])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);

-- Rewrite query: WHERE u.Email LIKE '%gmail.com'
--            → WHERE u.EmailDomain = 'gmail.com'
```

## Summary

| Source | Count |
|--------|-------|
| Operator-derived only (Source A) | 1 (sort spill — resolved by type fix) |
| Optimizer-suggested only (Source B) | 0 (Users.Email adjusted to domain approach) |
| Combined (both sources) | 1 (IX_Orders_UserId_CreatedDate) |
| Schema/query changes (not indexes) | 2 (type fix + EmailDomain column) |
