# Execution Plan Comparison — `baseline.sqlplan` vs `regression.sqlplan`

> **Input:** `skills/sqlplan-compare/examples/baseline.sqlplan` vs `skills/sqlplan-compare/examples/regression.sqlplan`
> Run with: `/sqlplan-compare skills/sqlplan-compare/examples/baseline.sqlplan skills/sqlplan-compare/examples/regression.sqlplan`
>
> Source: `dbo.GetOrdersByStatus` — same query, two plan captures before and after schema change

**Query:** `SELECT o.OrderId, o.Total, c.Name FROM dbo.Orders o JOIN dbo.Customers c ON c.Id = o.CustomerId WHERE o.Status = @status`

## Side-by-Side Metrics

| Metric | Baseline | Regression | Change |
|--------|---------|-----------|--------|
| Statement cost | 0.824 | 142.683 | **+17,217%** |
| Join strategy | Nested Loops | Hash Match | **Changed** |
| Orders access | Index Seek | Clustered Index Scan | **Degraded** |
| Customers access | Clustered Index Seek | Clustered Index Scan | **Degraded** |
| Memory grant | 512 KB | 2,048 MB (2 GB) | **+4,095×** |
| Grant wait time | 0 ms | 3,200 ms | **New wait** |
| Est. rows (Orders) | 1,240 | 1 | **Collapsed** |
| Act. rows (Orders) | ~1,240 | 4,800,000 | **3,870× more** |
| Implicit conversion | None | `CONVERT_IMPLICIT(nvarchar, [Orders].[Status])` | **New** |
| Parallelism | Serial (DOP 1) | Serial (DOP 1) | No change |

---

## Regression Findings

### [C1] Seek Degraded to Full Scan — Root Cause: Implicit Conversion (C2)
- **Baseline:** `Index Seek` on `IX_Orders_Status` — 1,240 rows estimated and delivered in 48 ms
- **Regression:** `Clustered Index Scan` on `Orders` — 1 row estimated, 4,800,000 rows actual, 84,210 ms
- **Why:** The implicit conversion (C2) applied to `[Orders].[Status]` made the predicate non-sargable. The optimizer could not use the index on `Status` when it must evaluate `CONVERT_IMPLICIT(nvarchar, Status)` for every row
- **Fix:** Align the `@status` parameter type with the `Status` column type. If `Status` is `VARCHAR`, declare `@status VARCHAR(50)` (remove any `N` prefix from literal callers)

### [C2] Implicit Conversion Affecting Seek Plan — New in Regression
- **Baseline:** No conversion warnings
- **Regression:** `PlanAffectingConvert ConvertIssue="Seek Plan"` on `[Orders].[Status]` — `CONVERT_IMPLICIT(nvarchar, [Orders].[Status])` applied column-side
- **Why introduced:** A schema change or calling-code change altered the `@status` parameter type from `VARCHAR` to `NVARCHAR` after the baseline plan was captured. SQL Server now converts the `VARCHAR` column to `NVARCHAR` for each row comparison instead of converting the parameter once
- **Fix:** Match parameter type to column type, or explicitly cast the parameter: `CAST(@status AS VARCHAR(50))`

### [C3] Join Strategy Changed: Nested Loops → Hash Match
- **Baseline:** Nested Loops with 1,240 outer rows and a cheap inner seek — correct for small outer input
- **Regression:** Hash Match scanning both entire tables — appropriate for millions of rows, catastrophic for 1,240
- **Why:** The row estimate collapsed from 1,240 to 1 (stale statistics + implicit conversion blocking histogram use). The optimizer chose Hash Match based on the absurdly low 1-row estimate
- **Fix:** Update statistics (`UPDATE STATISTICS dbo.Orders WITH FULLSCAN`) and fix the implicit conversion (C2) to restore accurate estimates

### [C4] Memory Grant Explosion — 512 KB → 2,048 MB
- **Baseline:** 512 KB grant, 480 KB used (accurate, no wait)
- **Regression:** 2 GB grant, 2 GB used, 3,200 ms wait before query starts
- **Why:** Hash Match requires memory proportional to the build-side row count. With 1,200,000 Customers rows estimated at 1, the optimizer requested 2 GB as a worst-case safety margin
- **Fix:** Resolved by fixing C2 and C3 — accurate estimates produce an accurate memory grant

### [W1] Customers Access: Clustered Index Seek → Clustered Index Scan
- **Baseline:** Seek into Customers by `CustomerId` — one seek per Nested Loops outer row
- **Regression:** Full scan of Customers as the Hash Match probe side
- **Why:** Hash Match does not use the join condition as a seek — it scans both inputs and probes the hash table. This is a consequence of C3, not an independent issue
- **Fix:** Resolved by restoring Nested Loops (fix C2/C3)

---

## Root Cause Summary

A single change caused the entire regression: **the `@status` parameter type changed from `VARCHAR` to `NVARCHAR`**, introducing an implicit conversion on the `Status` column. This:
1. Made the `Status` index non-sargable → scan instead of seek
2. Destroyed cardinality estimates → plan switched from Nested Loops to Hash Match
3. Hash Match required a 2 GB memory grant → 3.2 second wait before execution even begins

## Recommended Fix

```sql
-- Step 1: Confirm the Status column type
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'Orders' AND COLUMN_NAME = 'Status';

-- Step 2: Fix the parameter declaration in the stored procedure / calling code
-- If Status is VARCHAR(20):
ALTER PROCEDURE dbo.GetOrdersByStatus @status VARCHAR(20) AS ...
-- Remove N'' prefix from any literal callers: N'Open' → 'Open'

-- Step 3: Update statistics to restore accurate estimates
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
UPDATE STATISTICS dbo.Customers WITH FULLSCAN;

-- Step 4: Force plan recompilation
EXEC sp_recompile 'dbo.GetOrdersByStatus';
```

---

### Confirmed Stable (Unchanged Between Plans)
- Query text — identical
- DOP — both serial (DOP 1)
- Cardinality Estimation model — both CE160
- CompileTime — both 8 ms (no compile regression)
- Customers table structure — same access method once join strategy is corrected
