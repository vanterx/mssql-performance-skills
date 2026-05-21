# T-SQL Static Review Checks — Explained for All

## Contents

- [Before You Start: Key Concepts](#before-you-start-key-concepts)
- [Structural Anti-Patterns (T1–T15, T51–T55)](#structural-anti-patterns-t1t15-t51t55)
- [Correctness and Logic (T16–T28, T56–T64)](#correctness-and-logic-t16t28-t56t64)
- [Security and Dynamic SQL (T29–T38, T65–T67)](#security-and-dynamic-sql-t29t38-t65t67)
- [Deprecated and Non-Idiomatic Syntax (T39–T45, T68–T73)](#deprecated-and-non-idiomatic-syntax-t39t45-t68t73)
- [Performance Smells (T46–T50, T74–T78)](#performance-smells-t46t50-t74t78)
- [Quick Reference: Checks by Severity](#quick-reference-checks-by-severity)

---


A detailed guide to every check the analyser performs.
Each entry explains what the check means, why it matters, how to spot it in source code, real-world examples, and multiple fix options ranked by impact.

---

## Before You Start: Key Concepts

### What is static T-SQL analysis?

Unlike `sqlplan-review`, which needs a compiled execution plan, `tsql-review` works directly on the source code you write. It catches patterns that are provably wrong or risky — a `= NULL` comparison is always a bug, a `CROSS JOIN` without a WHERE condition is always suspicious — before you run anything.

Think of it as a linter for T-SQL, similar to ESLint for JavaScript or ReSharper for C#.

### Why not just look at the execution plan?

Execution plans catch *runtime* problems — bad join choices, spills, parameter sniffing. Static analysis catches *source-code* problems:

- Security vulnerabilities (SQL injection, hardcoded credentials)
- Logic bugs (NULL comparison, outer-join-nullified-by-WHERE)
- Deprecated syntax that may break on the next SQL Server upgrade
- Structural patterns that will always be slow regardless of indexes

The two analyses are complementary. Run `tsql-review` during code review. Run `sqlplan-review` on the execution plan in test or production.

### Severity levels used

| Level | Meaning |
|-------|---------|
| **Critical** | Almost certainly a bug, security risk, or data-loss scenario. Fix before merging. |
| **Warning** | Likely problem that degrades performance, correctness, or maintainability. Should fix. |
| **Info** | Pattern worth knowing about. May be benign. Investigate and document intent if benign. |

---

## Structural Anti-Patterns (T1–T15, T51–T55)

These checks fire on patterns that prevent index usage, expand data volumes unnecessarily, or replace set-based logic with row-by-row processing.

---

### T1 — SELECT * (No Explicit Column List)

**What it means**
`SELECT *` returns every column in the table at the time the query executes. If the table schema changes — a column is added, removed, or reordered — the query result changes silently.

**Why it matters**
- **Fragility:** Adding a column to the table changes what your query returns without any code change.
- **Performance:** Fetching all columns prevents covering index optimizations. A query needing only 2 columns that uses `SELECT *` on a 40-column table reads 38 unnecessary columns from disk.
- **Network cost:** All columns are transmitted to the client even if only 2 are used.

**How to spot it**
```sql
-- Triggers T1
SELECT * FROM dbo.Orders WHERE CustomerId = 42;

-- Also triggers (subquery)
SELECT o.*, c.Name FROM dbo.Orders o JOIN dbo.Customers c ON o.CustomerId = c.Id;
```

**Example — problem**
```sql
-- Returns all 40 columns of Orders; breaks if a column is dropped or renamed
SELECT * FROM dbo.Orders WHERE Status = 'Pending';
```

**Example — fix**
```sql
SELECT OrderId, CustomerId, OrderDate, TotalAmount, Status
FROM dbo.Orders
WHERE Status = 'Pending';
```

**Fix options**
1. Replace `*` with the explicit columns needed by the caller.
2. In views, use `SELECT *` only at the innermost level and explicitly name columns in the outer SELECT.

**Related checks:** T14 (unbounded result), T3 (missing WHERE)

---

### T2 — Missing WHERE on UPDATE or DELETE

**What it means**
An `UPDATE` or `DELETE` statement with no `WHERE` clause modifies or deletes every row in the table.

**Why it matters**
This is a data-loss scenario. A missing WHERE on a `DELETE FROM dbo.Orders` with 10 million rows deletes all 10 million rows. Recovery requires a backup restore or transaction log replay.

**How to spot it**
```sql
-- Triggers T2 — deletes all rows
DELETE FROM dbo.Orders;

-- Triggers T2 — updates all rows
UPDATE dbo.Products SET Price = Price * 1.10;
```

**Example — problem**
```sql
-- Intended to remove old draft orders; WHERE clause forgotten
DELETE FROM dbo.Orders;
```

**Example — fix**
```sql
DELETE FROM dbo.Orders WHERE Status = 'Draft' AND CreatedDate < DATEADD(DAY, -30, GETDATE());
```

**Fix options**
1. Add a WHERE clause with the intended filter.
2. If intentional full-table delete, use `TRUNCATE TABLE` — it's faster, minimally logged, and its name makes intent obvious.
3. If intentional full-table update (e.g., reseed a column), document with a comment: `-- intentional: full-table update for schema migration`.

**Related checks:** T19 (missing TRY/CATCH), T20 (missing transaction)

---

### T3 — Missing WHERE on SELECT (Full-Table Read)

**What it means**
A `SELECT` against a user table has no `WHERE` clause, returning all rows.

**Why it matters**
On a large table, a full-table read is expensive regardless of indexes. It's usually a sign of an oversight rather than intent. On small tables it's often benign.

**How to spot it**
```sql
-- Triggers T3
SELECT OrderId, CustomerId FROM dbo.Orders;
```

**Example — problem**
```sql
-- Reads all 10M orders to find a few
SELECT * FROM dbo.Orders;
```

**Example — fix**
```sql
-- If intentional, document it
SELECT OrderId, CustomerId, Status FROM dbo.Orders; -- intentional: full export for ETL

-- If not intentional, add a filter
SELECT OrderId, CustomerId, Status FROM dbo.Orders WHERE Status = 'Pending';
```

**Fix options**
1. Add a WHERE clause.
2. If a full scan is intentional (ETL export, reporting), document it with a comment.
3. Add `TOP (@n)` for exploratory queries that should not fetch unlimited rows.

**Related checks:** T1 (SELECT *), T14 (missing TOP)

---

### T4 — Non-Sargable Predicate — Function Wrapping Indexed Column

**What it means**
"Sargable" (Search ARGument ABLE) means SQL Server can use an index to satisfy the predicate without scanning every row. When a function wraps a column in a WHERE clause, SQL Server cannot seek into the index — it must evaluate the function for every row first.

**Why it matters**
A non-sargable predicate converts an index seek (fast, O(log n)) into an index or table scan (slow, O(n)). On a table with 10M rows and a good index, this is the difference between 1 ms and 30 seconds.

**How to spot it**
```sql
-- All trigger T4 — function wraps the column
WHERE YEAR(OrderDate) = 2024
WHERE MONTH(ShippedDate) = 3
WHERE CAST(CustomerId AS VARCHAR) = '42'
WHERE UPPER(LastName) = 'SMITH'
WHERE LEFT(ProductCode, 3) = 'ABC'
WHERE ISNULL(Status, 'UNKNOWN') = 'PENDING'  -- see also T13
WHERE DATEPART(dw, EventDate) = 2            -- Monday filter
```

**Example — problem**
```sql
-- Cannot use index on OrderDate
SELECT OrderId FROM dbo.Orders WHERE YEAR(OrderDate) = 2024;
```

**Example — fix**
```sql
-- Range predicate on the bare column — index seek possible
SELECT OrderId FROM dbo.Orders
WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01';
```

**Fix options (ranked by impact)**
1. Rewrite the predicate as a range on the bare column (most effective).
2. Add a computed persisted column (e.g., `OrderYear AS YEAR(OrderDate) PERSISTED`) and index it — allows function-based queries without rewriting every caller.
3. For collation issues (`UPPER`/`LOWER`), fix the collation or use a case-insensitive collation on the column instead.

**Related checks:** T5 (implicit type coercion), T12 (function in JOIN), T13 (ISNULL/COALESCE in WHERE)

---

### T5 — Non-Sargable Predicate — Implicit Type Coercion

**What it means**
SQL Server applies an implicit `CONVERT` to the *column* side of a comparison when the parameter and column types differ. This makes the predicate non-sargable in the same way as T4 — SQL Server cannot seek into the index.

The most common case: comparing a `VARCHAR` column to an `NVARCHAR` parameter (or literal `N'...'`). SQL Server promotes `VARCHAR` to `NVARCHAR`, converting every value in the column before comparing.

**Why it matters**
Same as T4: index seeks become scans. This is also flagged at runtime by `sqlplan-review` (S12 — implicit conversion affects seek plan) — but static analysis catches it before execution.

**How to spot it**
```sql
-- Triggers T5
-- If CustomerId is INT and @param is NVARCHAR
WHERE CustomerId = @param    -- @param declared as NVARCHAR

-- If Email is VARCHAR and the literal is NVARCHAR
WHERE Email = N'user@example.com'

-- If OrderDate is DATE and @date is DATETIME
WHERE OrderDate = @date      -- DATE vs DATETIME comparison
```

**Example — problem**
```sql
-- Email column is VARCHAR(255); literal N'' forces conversion
SELECT * FROM dbo.Customers WHERE Email = N'user@example.com';
```

**Example — fix**
```sql
-- Remove the N prefix — match the column type
SELECT * FROM dbo.Customers WHERE Email = 'user@example.com';
```

**Fix options**
1. Align the parameter/literal type with the column type.
2. Declare stored procedure parameters to match the column types they filter on.
3. For legacy code where changing the column type is not feasible, add an explicit CAST on the literal side: `WHERE Email = CAST(@param AS VARCHAR(255))`.

**Related checks:** T4 (non-sargable function), T50 (collation mismatch)

---

### T6 — Leading Wildcard LIKE

**What it means**
A LIKE predicate with a `%` at the start of the pattern (`LIKE '%value'` or `LIKE '%value%'`) requires SQL Server to scan every row in the index or table to check whether each value ends with or contains the pattern. The optimizer cannot seek to the matching rows.

**Why it matters**
Leading wildcard LIKE is O(n) — every row is evaluated. On a table with 50M rows and a 1 ms per-row evaluation, this is 50 seconds per query. It also prevents using an index seek even if an index exists on the column.

**How to spot it**
```sql
-- Triggers T6
WHERE LastName LIKE '%son'          -- ends with 'son'
WHERE Description LIKE '%widget%'   -- contains 'widget'
WHERE Code LIKE '%ABC%'
```

**Example — problem**
```sql
SELECT ProductId, Name FROM dbo.Products WHERE Name LIKE '%bearing%';
```

**Example — fix (Full-Text Search)**
```sql
-- Requires Full-Text index on dbo.Products(Name)
SELECT ProductId, Name FROM dbo.Products
WHERE CONTAINS(Name, 'bearing');
```

**Fix options (ranked by impact)**
1. **Full-Text Search (`CONTAINS`, `FREETEXT`)** — for natural-language substring search. Requires creating a Full-Text index on the column.
2. **Trailing-only wildcard** — if the actual requirement is a prefix match, rewrite as `LIKE 'value%'` (no leading %). This is sargable.
3. **Computed reversed column** — for suffix-only searches (`LIKE '%son'`), store a persisted computed column `REVERSE(LastName)` and search `LIKE REVERSE('%son')`.
4. **Application-side filtering** — if the table is small enough, fetch a pre-filtered set and apply the LIKE in application code.

**Related checks:** T4 (non-sargable predicate)

---

### T7 — Explicit Cursor Usage

**What it means**
A `DECLARE ... CURSOR` loop processes rows one at a time in a `FETCH` loop. SQL Server is optimized for set-based operations — processing thousands of rows at once. Cursor processing of N rows typically takes N times longer than the equivalent set-based query.

**Why it matters**
A cursor that processes 1M rows with 1 ms per iteration runs for ~17 minutes. A set-based equivalent might run in under 1 second. Cursors also hold locks longer, increasing blocking for concurrent queries.

**How to spot it**
```sql
DECLARE @id INT;
DECLARE order_cursor CURSOR FOR SELECT OrderId FROM dbo.Orders WHERE Status = 'Pending';
OPEN order_cursor;
FETCH NEXT FROM order_cursor INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.ProcessOrder @id;
    FETCH NEXT FROM order_cursor INTO @id;
END;
CLOSE order_cursor;
DEALLOCATE order_cursor;
```

**Example — problem**
```sql
-- Updates each order's total one row at a time
DECLARE @id INT, @total DECIMAL(18,2);
DECLARE cur CURSOR FOR SELECT OrderId FROM dbo.Orders WHERE NeedsRecalc = 1;
OPEN cur;
FETCH NEXT FROM cur INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @total = SUM(LineTotal) FROM dbo.OrderLines WHERE OrderId = @id;
    UPDATE dbo.Orders SET Total = @total WHERE OrderId = @id;
    FETCH NEXT FROM cur INTO @id;
END;
CLOSE cur; DEALLOCATE cur;
```

**Example — fix**
```sql
-- Set-based: updates all matching orders in one statement
UPDATE o
SET o.Total = agg.Total
FROM dbo.Orders o
INNER JOIN (
    SELECT OrderId, SUM(LineTotal) AS Total
    FROM dbo.OrderLines
    GROUP BY OrderId
) agg ON o.OrderId = agg.OrderId
WHERE o.NeedsRecalc = 1;
```

**Fix options (ranked by impact)**
1. **Set-based UPDATE/DELETE with JOIN** — eliminates the cursor for most row-processing patterns.
2. **Window functions** — for running totals, rankings, and sequential calculations.
3. **Recursive CTE** — for hierarchical traversal.
4. **STRING_AGG / FOR XML PATH** — for string aggregation (replaces string-concatenation cursors).
5. **WHILE loop** — if true iterative processing is unavoidable, a WHILE loop with batch size control (e.g., `TOP 1000` per iteration with a loop checkpoint) is faster than a cursor and holds shorter locks.

**Related checks:** T9 (correlated subquery in SELECT), T8 (scalar UDF)

---

### T8 — Scalar UDF in SELECT or WHERE

**What it means**
A user-defined scalar function (`CREATE FUNCTION ... RETURNS scalar_type`) in the SELECT list, WHERE clause, or JOIN ON clause executes once per row. Unlike inline table-valued functions, scalar UDFs are a black box to the query optimizer — it cannot inline or parallelize them.

**Why it matters**
- **No parallelism:** In SQL Server 2016 and earlier, a scalar UDF in the SELECT list forces the entire query to run single-threaded (serial).
- **Row-by-row execution:** On 1M rows, a scalar UDF that takes 0.1 ms runs for 100 seconds per query.
- **No statistics flow:** The optimizer cannot estimate the output of a scalar UDF, leading to bad cardinality estimates for predicates that use its result.

**How to spot it**
```sql
-- Triggers T8 — UDF in SELECT list
SELECT dbo.fn_FormatPhone(PhoneNumber) AS FormattedPhone FROM dbo.Customers;

-- Triggers T8 — UDF in WHERE
SELECT * FROM dbo.Orders WHERE dbo.fn_GetStatus(OrderId) = 'Pending';
```

**Example — problem**
```sql
-- dbo.fn_GetOrderTotal runs once per row
SELECT OrderId, dbo.fn_GetOrderTotal(OrderId) AS Total
FROM dbo.Orders WHERE Status = 'Open';
```

**Example — fix (inline TVF with CROSS APPLY)**
```sql
-- Convert scalar UDF to an inline TVF
CREATE OR ALTER FUNCTION dbo.fn_GetOrderTotal_TVF (@orderId INT)
RETURNS TABLE AS RETURN (
    SELECT SUM(LineTotal) AS Total FROM dbo.OrderLines WHERE OrderId = @orderId
);

-- Use with CROSS APPLY
SELECT o.OrderId, t.Total
FROM dbo.Orders o
CROSS APPLY dbo.fn_GetOrderTotal_TVF(o.OrderId) t
WHERE o.Status = 'Open';
```

**Fix options (ranked by impact)**
1. **Rewrite as inline TVF + CROSS APPLY** — the optimizer can inline the logic, parallelize, and push predicates inside.
2. **Embed logic directly in the query** — if the function is simple, eliminate the function call entirely.
3. **SQL Server 2019+ Scalar UDF Inlining** — simple scalar UDFs may be automatically inlined. Check `sys.sql_modules.is_inlineable` for your function. Complex UDFs (side effects, recursive calls) are not eligible.

**Related checks:** T7 (cursor), T9 (correlated subquery)

---

### T9 — Correlated Subquery in SELECT List

**What it means**
A subquery in the SELECT clause that references a column from the outer query. SQL Server executes this subquery once for each row in the outer result set — identical to cursor row-by-row processing.

**Why it matters**
On 1M outer rows, a correlated SELECT subquery that runs in 0.01 ms each runs for ~10 seconds total — and holds resources proportionally. The optimizer often has limited ability to convert this to a join.

**How to spot it**
```sql
-- Triggers T9
SELECT
    c.CustomerId,
    c.Name,
    (SELECT MAX(OrderDate) FROM dbo.Orders o WHERE o.CustomerId = c.CustomerId) AS LastOrderDate
FROM dbo.Customers c;
```

**Example — problem**
```sql
SELECT
    p.ProductId,
    p.Name,
    (SELECT TOP 1 SalePrice FROM dbo.PriceHistory ph WHERE ph.ProductId = p.ProductId ORDER BY EffectiveDate DESC) AS CurrentPrice
FROM dbo.Products p;
```

**Example — fix (OUTER APPLY)**
```sql
SELECT
    p.ProductId,
    p.Name,
    ph.SalePrice AS CurrentPrice
FROM dbo.Products p
OUTER APPLY (
    SELECT TOP 1 SalePrice FROM dbo.PriceHistory ph
    WHERE ph.ProductId = p.ProductId
    ORDER BY EffectiveDate DESC
) ph;
```

**Example — fix (window function)**
```sql
SELECT
    c.CustomerId,
    c.Name,
    MAX(o.OrderDate) OVER (PARTITION BY c.CustomerId) AS LastOrderDate
FROM dbo.Customers c
LEFT JOIN dbo.Orders o ON o.CustomerId = c.CustomerId;
```

**Fix options (ranked by impact)**
1. **OUTER APPLY / CROSS APPLY** — for TOP 1 lookups; joins and allows seek.
2. **Window function** (`MAX() OVER`, `FIRST_VALUE() OVER`) — for aggregations across a partition.
3. **LEFT JOIN with GROUP BY** — for simple aggregates (MAX, COUNT, SUM).

**Related checks:** T8 (scalar UDF), T7 (cursor), T48 (deeply nested subqueries)

---

### T10 — CROSS JOIN Without Explanatory Comment

**What it means**
A CROSS JOIN produces the Cartesian product of two tables: every row from the left combined with every row from the right. If the left table has 1,000 rows and the right has 1,000 rows, the result is 1,000,000 rows.

**Why it matters**
CROSS JOINs are occasionally correct (generating date grids, multiplying product×region combinations). They are more often accidental — a forgotten JOIN condition that produces massively inflated row counts with no error message.

**How to spot it**
```sql
-- Explicit CROSS JOIN
SELECT a.ProductId, b.RegionId FROM dbo.Products a CROSS JOIN dbo.Regions b;

-- Implicit CROSS JOIN (comma-separated FROM)
SELECT a.ProductId, b.RegionId FROM dbo.Products a, dbo.Regions b;
```

**Example — problem**
```sql
-- Accidental CROSS JOIN — WHERE condition was forgotten
SELECT o.OrderId, i.ItemName
FROM dbo.Orders o, dbo.OrderItems i;  -- should be: WHERE i.OrderId = o.OrderId
```

**Example — fix**
```sql
-- Add the missing join condition
SELECT o.OrderId, i.ItemName
FROM dbo.Orders o
INNER JOIN dbo.OrderItems i ON i.OrderId = o.OrderId;
```

**Example — intentional (documented)**
```sql
-- intentional: generates all date/product combinations for the reporting grid
SELECT d.DateKey, p.ProductId
FROM dbo.DimDate d
CROSS JOIN dbo.DimProduct p;
```

**Fix options**
1. Add the missing JOIN condition if the CROSS JOIN is accidental.
2. Add an explanatory comment if the CROSS JOIN is intentional.
3. Rewrite implicit `FROM a, b` syntax as explicit `CROSS JOIN` or `INNER JOIN ... ON`.

**Related checks:** T11 (OR in JOIN), T3 (missing WHERE)

---

### T11 — OR Condition in JOIN Predicate

**What it means**
A JOIN condition that uses `OR` between two predicates: `ON a.id = b.id OR a.alt_id = b.id`. SQL Server cannot use a standard B-tree index seek for OR-based join conditions — it typically falls back to a hash or merge join that scans both inputs.

**Why it matters**
OR join conditions prevent independent seek paths for each condition. This is often much slower than the equivalent UNION ALL of two separate joins, each of which can use its own index.

**How to spot it**
```sql
-- Triggers T11
FROM dbo.Orders o
JOIN dbo.Contacts c ON c.ContactId = o.BillToContactId OR c.ContactId = o.ShipToContactId
```

**Example — problem**
```sql
SELECT o.OrderId, c.Name
FROM dbo.Orders o
JOIN dbo.Contacts c ON c.ContactId = o.BillToContactId OR c.ContactId = o.ShipToContactId;
```

**Example — fix**
```sql
SELECT o.OrderId, c.Name
FROM dbo.Orders o
JOIN dbo.Contacts c ON c.ContactId = o.BillToContactId
UNION ALL
SELECT o.OrderId, c.Name
FROM dbo.Orders o
JOIN dbo.Contacts c ON c.ContactId = o.ShipToContactId
  AND c.ContactId <> o.BillToContactId;  -- avoid duplicates if BillTo = ShipTo
```

**Fix options**
1. Rewrite as `UNION ALL` of two separate joins (most effective).
2. Use `CROSS APPLY` with a `VALUES` constructor to unpivot the two join columns before joining.

**Related checks:** T10 (CROSS JOIN), T21 (UNION vs UNION ALL)

---

### T12 — Function on Indexed Column in JOIN ON Clause

**What it means**
Same root cause as T4, but in a JOIN condition instead of a WHERE clause. A function call wrapping a column in the ON clause prevents index seeks on that column for the join.

**How to spot it**
```sql
-- Triggers T12
FROM dbo.Orders o
JOIN dbo.DateDim d ON CAST(o.OrderDate AS DATE) = d.DateKey

FROM dbo.Logs l
JOIN dbo.Events e ON YEAR(l.EventTime) = e.EventYear AND MONTH(l.EventTime) = e.EventMonth
```

**Example — problem**
```sql
FROM dbo.Sales s
JOIN dbo.Regions r ON LEFT(s.RegionCode, 2) = r.CountryCode
```

**Example — fix**
```sql
-- Store the pre-computed value as a persisted computed column
ALTER TABLE dbo.Sales ADD CountryCode AS LEFT(RegionCode, 2) PERSISTED;
CREATE INDEX IX_Sales_CountryCode ON dbo.Sales (CountryCode);

FROM dbo.Sales s
JOIN dbo.Regions r ON s.CountryCode = r.CountryCode
```

**Fix options**
1. Add a persisted computed column and index it.
2. Rewrite the join condition to apply the transformation to the non-indexed side.
3. Redesign the schema to store the join-key value explicitly.

**Related checks:** T4 (non-sargable in WHERE), T5 (implicit coercion)

---

### T13 — ISNULL or COALESCE on Indexed Column in WHERE

**What it means**
`ISNULL(col, substitute)` or `COALESCE(col, substitute, ...)` in a WHERE clause wraps the column in a function, making the predicate non-sargable (same root cause as T4). SQL Server cannot seek into the index on `col` because it must evaluate ISNULL/COALESCE for every row.

**How to spot it**
```sql
-- Triggers T13
WHERE ISNULL(Status, 'UNKNOWN') = 'PENDING'
WHERE COALESCE(ShippedDate, '1900-01-01') >= @startDate
```

**Example — problem**
```sql
SELECT * FROM dbo.Orders WHERE ISNULL(Status, 'UNKNOWN') = 'PENDING';
```

**Example — fix**
```sql
-- Explicit NULL handling — both conditions can use the index
SELECT * FROM dbo.Orders WHERE Status = 'PENDING';  -- NULLs naturally excluded
-- Or if NULLs should be included as 'PENDING':
SELECT * FROM dbo.Orders WHERE Status = 'PENDING' OR Status IS NULL;
```

**Fix options**
1. Replace with explicit `col = value OR col IS NULL` for the common case.
2. Store a default value in the column (NOT NULL with a DEFAULT constraint) so ISNULL is never needed.
3. For nullable date ranges: use `WHERE col >= @start OR col IS NULL` instead of `WHERE ISNULL(col, '1900-01-01') >= @start`.

**Related checks:** T4 (non-sargable predicate), T23 (missing ELSE in CASE)

---

### T14 — Missing TOP or FETCH NEXT (Unbounded Result Set)

**What it means**
A SELECT statement returned to a caller (not used as a subquery or INSERT source) has no `TOP`, `FETCH NEXT`, or explicit row limit. The query may return millions of rows depending on the data.

**Why it matters**
Unbounded result sets consume network bandwidth, application memory, and SQL Server I/O resources proportional to the data size. In production, a query that returns 10M rows to a web server can cause OOM conditions in the application.

**How to spot it**
```sql
-- Triggers T14 (top-level SELECT, no pagination)
SELECT OrderId, CustomerId, OrderDate FROM dbo.Orders;
```

**Example — problem**
```sql
-- API endpoint that should return one page but fetches all data
SELECT OrderId, CustomerId, Status FROM dbo.Orders WHERE Status = 'Open';
```

**Example — fix**
```sql
SELECT OrderId, CustomerId, Status
FROM dbo.Orders
WHERE Status = 'Open'
ORDER BY OrderDate DESC
OFFSET @offset ROWS FETCH NEXT @pageSize ROWS ONLY;
```

**Fix options**
1. Add `OFFSET / FETCH NEXT` pagination with a deterministic ORDER BY (also add T49 check).
2. Add `TOP (@n)` for queries with a natural hard limit (e.g., dashboards showing Top 10).
3. For reporting/export queries where full data is genuinely needed, document the expected row count and add monitoring.

**Related checks:** T49 (non-deterministic pagination), T1 (SELECT *)

---

### T15 — DISTINCT Without Aggregation Intent

**What it means**
`SELECT DISTINCT` is used to eliminate duplicates that should not have existed in the first place — typically because a JOIN is producing extra rows from a one-to-many relationship.

**Why it matters**
DISTINCT sorts or hashes all rows to remove duplicates. This is an O(n log n) operation. More importantly, it hides a JOIN design problem — the duplicates are a symptom of a missing aggregation or a wrong join type.

**How to spot it**
```sql
-- Triggers T15 — DISTINCT masking a bad join
SELECT DISTINCT c.CustomerId, c.Name
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.CustomerId;
-- Returns one row per customer, but only because DISTINCT hides the 1:many duplicates
```

**Example — problem**
```sql
SELECT DISTINCT c.CustomerId, c.Name, p.ProductName
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.CustomerId
JOIN dbo.OrderLines ol ON ol.OrderId = o.OrderId
JOIN dbo.Products p ON p.ProductId = ol.ProductId;
-- Duplicates appear because of the joins; DISTINCT masks them
```

**Example — fix**
```sql
-- If you need one row per customer-product combination:
SELECT c.CustomerId, c.Name, p.ProductName, COUNT(*) AS OrderCount
FROM dbo.Customers c
JOIN dbo.Orders o ON o.CustomerId = c.CustomerId
JOIN dbo.OrderLines ol ON ol.OrderId = o.OrderId
JOIN dbo.Products p ON p.ProductId = ol.ProductId
GROUP BY c.CustomerId, c.Name, p.ProductName;

-- If you need to check membership (does customer have any orders?):
SELECT c.CustomerId, c.Name
FROM dbo.Customers c
WHERE EXISTS (SELECT 1 FROM dbo.Orders o WHERE o.CustomerId = c.CustomerId);
```

**Fix options**
1. Replace `DISTINCT` + JOIN with `EXISTS` / `IN` when you only need to check membership.
2. Replace with an aggregating query (GROUP BY) when you need metrics.
3. Fix the JOIN to not produce duplicates in the first place (correct the cardinality relationship).

**Related checks:** T21 (UNION vs UNION ALL), T26 (aggregate without GROUP BY)

---

## Correctness and Logic (T16–T28, T56–T64)

---

### T16 — NULL Comparison Using = NULL

**What it means**
In SQL, NULL represents an unknown value. Comparing anything to NULL using `=`, `<>`, or `!=` always returns UNKNOWN — not TRUE or FALSE. This means `WHERE col = NULL` never matches any row, and `WHERE col <> NULL` also never matches any row.

**Why it matters**
This is a silent logic bug. A WHERE clause like `WHERE DeletedAt = NULL` intended to find undeleted records returns zero rows instead of all undeleted records, with no error message.

**How to spot it**
```sql
-- Triggers T16 — always returns zero rows
WHERE DeletedAt = NULL
WHERE ParentId != NULL
WHERE Status <> NULL

-- Correct form:
WHERE DeletedAt IS NULL
WHERE ParentId IS NOT NULL
```

**Example — problem**
```sql
-- Intended to find active (non-deleted) records; returns NOTHING
SELECT * FROM dbo.Users WHERE DeletedAt = NULL;
```

**Example — fix**
```sql
SELECT * FROM dbo.Users WHERE DeletedAt IS NULL;
```

**Fix options**
1. Replace `= NULL` with `IS NULL`.
2. Replace `<> NULL` or `!= NULL` with `IS NOT NULL`.
3. For comparing two nullable columns for equality: use `(col1 = col2 OR (col1 IS NULL AND col2 IS NULL))` or SQL Server 2022's `col1 IS NOT DISTINCT FROM col2`.

**Related checks:** T23 (missing ELSE in CASE), T44 (SET ANSI_NULLS OFF)

---

### T17 — Outer Join Nullified by WHERE Filter on Right-Side Column

**What it means**
A `LEFT JOIN` includes all rows from the left table, even if there is no matching row on the right. When there is no match, the right-side columns are NULL. But if the WHERE clause then filters on a right-side column (e.g., `WHERE T2.col = @val`), all the NULL rows are eliminated — effectively converting the LEFT JOIN into an INNER JOIN.

**Why it matters**
The query silently returns fewer rows than expected. This is especially dangerous when the LEFT JOIN is intentional (e.g., "show all customers, even those with no orders").

**How to spot it**
```sql
-- Triggers T17 — the WHERE on o.Status converts LEFT JOIN to INNER JOIN
SELECT c.CustomerId, c.Name, o.OrderId
FROM dbo.Customers c
LEFT JOIN dbo.Orders o ON o.CustomerId = c.CustomerId
WHERE o.Status = 'Open';  -- eliminates the NULL rows for customers with no orders
```

**Example — problem**
```sql
-- Intended: all customers, with their open order count (or 0 if none)
-- Actual: only customers who HAVE an open order
SELECT c.Name, COUNT(o.OrderId) AS OpenOrders
FROM dbo.Customers c
LEFT JOIN dbo.Orders o ON o.CustomerId = c.CustomerId
WHERE o.Status = 'Open'
GROUP BY c.Name;
```

**Example — fix**
```sql
-- Move the filter into the JOIN ON clause to preserve non-matching rows
SELECT c.Name, COUNT(o.OrderId) AS OpenOrders
FROM dbo.Customers c
LEFT JOIN dbo.Orders o ON o.CustomerId = c.CustomerId AND o.Status = 'Open'
GROUP BY c.Name;
```

**Fix options**
1. Move the right-side filter from WHERE into the JOIN ON clause.
2. If an INNER JOIN is genuinely intended, change `LEFT JOIN` to `INNER JOIN` to document the intent.

**Related checks:** T16 (NULL comparison), T23 (missing ELSE)

---

### T18 — Missing ORDER BY in Final SELECT

**What it means**
SQL Server does not guarantee any particular row order for a SELECT without ORDER BY. The order depends on the execution plan chosen — which can change between executions as statistics update, indexes are added, or server load changes.

**Why it matters**
Applications that depend on row order without an ORDER BY will produce inconsistent results. Users may see data in different orders on different page loads. This is particularly noticeable with pagination (T49).

**How to spot it**
```sql
-- Triggers T18 — top-level SELECT returned to caller, no ORDER BY
SELECT OrderId, CustomerId, Status FROM dbo.Orders WHERE Status = 'Open';
```

**Example — fix**
```sql
SELECT OrderId, CustomerId, Status FROM dbo.Orders
WHERE Status = 'Open'
ORDER BY OrderDate DESC, OrderId ASC;  -- OrderId ensures deterministic order within same date
```

**Fix options**
1. Add an `ORDER BY` with a deterministic sort key (must include a unique column to be fully deterministic).
2. If the query feeds a further aggregation or subquery where order is irrelevant, document with a comment: `-- no ORDER BY intentional: result feeds aggregation`.

**Related checks:** T49 (non-deterministic pagination)

---

### T19 — Missing TRY/CATCH Around DML

**What it means**
DML statements (`INSERT`, `UPDATE`, `DELETE`, `MERGE`) can fail due to constraint violations, deadlocks, or data errors. Without error handling, a failure may leave partial state — some rows updated, others not — with no notification.

**Why it matters**
Silent failures leave data in an inconsistent state. In a multi-statement batch, a failure in statement 3 may leave statements 1 and 2 committed but statement 3 incomplete.

**How to spot it**
```sql
-- Triggers T19 — DML without TRY/CATCH
INSERT INTO dbo.Orders (CustomerId, OrderDate) VALUES (@customerId, @date);
UPDATE dbo.Inventory SET Stock = Stock - @qty WHERE ProductId = @productId;
```

**Example — fix**
```sql
BEGIN TRY
    INSERT INTO dbo.Orders (CustomerId, OrderDate) VALUES (@customerId, @date);
    UPDATE dbo.Inventory SET Stock = Stock - @qty WHERE ProductId = @productId;
END TRY
BEGIN CATCH
    -- Log error details
    INSERT INTO dbo.ErrorLog (ErrorNumber, ErrorMessage, ErrorTime)
    VALUES (ERROR_NUMBER(), ERROR_MESSAGE(), SYSDATETIME());
    THROW;  -- re-raise to caller
END CATCH
```

**Fix options**
1. Wrap in `BEGIN TRY / END TRY BEGIN CATCH / END CATCH`.
2. Use `THROW` (SQL Server 2012+) in the CATCH block to re-raise with original error metadata.
3. Log the error before re-throwing using `ERROR_NUMBER()`, `ERROR_MESSAGE()`, `ERROR_LINE()`.

**Related checks:** T20 (missing transaction), T41 (RAISERROR vs THROW)

---

### T20 — Multi-Statement DML Without Explicit Transaction

**What it means**
Two or more DML statements in the same batch have no enclosing `BEGIN TRANSACTION`. Each statement auto-commits independently. If the second statement fails, the first is already committed — leaving a partial state.

**Why it matters**
Without a transaction, there is no atomic unit of work. A network failure, constraint violation, or deadlock between two related DML statements leaves data in a half-updated state.

**How to spot it**
```sql
-- Triggers T20 — two DMLs with no wrapping transaction
UPDATE dbo.Orders SET Status = 'Shipped' WHERE OrderId = @id;
INSERT INTO dbo.ShipmentLog (OrderId, ShippedAt) VALUES (@id, SYSDATETIME());
```

**Example — fix**
```sql
BEGIN TRANSACTION;
BEGIN TRY
    UPDATE dbo.Orders SET Status = 'Shipped' WHERE OrderId = @id;
    INSERT INTO dbo.ShipmentLog (OrderId, ShippedAt) VALUES (@id, SYSDATETIME());
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH
```

**Fix options**
1. Wrap related DML in `BEGIN TRANSACTION / COMMIT` with ROLLBACK in CATCH.
2. If the two statements are intentionally independent (fire-and-forget logging), document with a comment.

**Related checks:** T19 (missing TRY/CATCH), T32 (EXECUTE AS without REVERT)

---

### T21 — UNION Instead of UNION ALL

**What it means**
`UNION` combines two result sets and eliminates duplicate rows. Eliminating duplicates requires SQL Server to sort or hash both result sets — O(n log n). `UNION ALL` combines the result sets without deduplication — O(n).

**Why it matters**
When duplicates either cannot exist (the two queries are guaranteed to produce disjoint rows) or don't matter, `UNION` does unnecessary work. For large result sets this can be a significant performance difference.

**How to spot it**
```sql
-- Triggers T21
SELECT CustomerId FROM dbo.GoldCustomers
UNION
SELECT CustomerId FROM dbo.SilverCustomers;
```

**Example — fix**
```sql
-- If GoldCustomers and SilverCustomers are disjoint:
SELECT CustomerId FROM dbo.GoldCustomers
UNION ALL
SELECT CustomerId FROM dbo.SilverCustomers;
```

**Fix options**
1. Replace `UNION` with `UNION ALL` when the two result sets are guaranteed disjoint.
2. Keep `UNION` if deduplication is genuinely required — and add a comment explaining why.
3. Replace with `SELECT DISTINCT FROM (... UNION ALL ...)` when you want explicit control over where deduplication happens.

**Related checks:** T15 (DISTINCT abuse), T11 (OR in JOIN)

---

### T22 — CASE Branches With Mismatched Return Types

**What it means**
A CASE expression where different WHEN branches return values of different data types. SQL Server resolves the mismatch by converting all branches to the highest-precedence type — which may truncate values or cause runtime conversion errors.

**How to spot it**
```sql
-- Triggers T22 — INT branch and VARCHAR branch
CASE WHEN Status = 'Open' THEN 1 ELSE 'None' END

-- Triggers T22 — DATE and DATETIME2 mixed
CASE WHEN UseOverride = 1 THEN @overrideDate ELSE SYSDATETIME() END
-- (if @overrideDate is DATE and SYSDATETIME() is DATETIME2)
```

**Example — fix**
```sql
-- Explicit CAST to the desired output type in every branch
CASE WHEN Status = 'Open' THEN CAST(1 AS VARCHAR(10)) ELSE 'None' END

CASE WHEN UseOverride = 1 THEN CAST(@overrideDate AS DATETIME2) ELSE SYSDATETIME() END
```

**Fix options**
1. Add explicit CAST/CONVERT to the desired type in every branch.
2. Redesign the CASE to return a consistent type from the outset.

**Related checks:** T5 (implicit type coercion), T50 (collation mismatch)

---

### T23 — Missing ELSE in CASE Expression

**What it means**
A CASE expression with no ELSE clause implicitly returns NULL when no WHEN condition matches. This is often unintentional.

**How to spot it**
```sql
-- Triggers T23 — no ELSE; returns NULL for Status = 'Cancelled'
CASE
    WHEN Status = 'Open' THEN 'Active'
    WHEN Status = 'Shipped' THEN 'Complete'
END AS StatusLabel
```

**Example — fix**
```sql
CASE
    WHEN Status = 'Open' THEN 'Active'
    WHEN Status = 'Shipped' THEN 'Complete'
    ELSE 'Other'  -- explicit fallback
END AS StatusLabel

-- Or if NULL is intentional:
CASE
    WHEN Status = 'Open' THEN 'Active'
    WHEN Status = 'Shipped' THEN 'Complete'
    ELSE NULL  -- intentional: other statuses not mapped
END AS StatusLabel
```

**Fix options**
1. Add `ELSE default_value` with a sensible default.
2. Add `ELSE NULL` explicitly to document the intent.

**Related checks:** T16 (NULL comparison), T22 (type mismatch in CASE)

---

### T24 — CTE Referenced More Than Once

**What it means**
CTEs are not materialized in SQL Server. Each reference to a CTE in the same query re-executes the CTE's definition. If the CTE is expensive, referencing it twice doubles the cost.

**How to spot it**
```sql
-- Triggers T24 — CTE used twice
WITH ExpensiveCTE AS (
    SELECT * FROM dbo.BigTable WHERE ...
)
SELECT * FROM ExpensiveCTE e1
JOIN ExpensiveCTE e2 ON e1.Id = e2.ParentId;  -- runs twice
```

**Example — fix**
```sql
-- Materialize into a temp table
SELECT * INTO #ExpensiveResult FROM dbo.BigTable WHERE ...;
SELECT * FROM #ExpensiveResult e1
JOIN #ExpensiveResult e2 ON e1.Id = e2.ParentId;
DROP TABLE #ExpensiveResult;
```

**Fix options**
1. Materialize into a `#temp` table for repeated access.
2. Use a table variable if the result set is small (< 100 rows).
3. Restructure the query to reference the CTE only once.

**Related checks:** T25 (CTE chain depth), T46 (table variable for large data)

---

### T25 — CTE Chain Depth Exceeds 4 Levels

**What it means**
A `WITH` clause with more than 4 CTEs, or CTEs referencing each other in a chain deeper than 4 levels. Deep CTE chains increase compile time and reduce query readability.

**How to spot it**
```sql
-- Triggers T25 — 5-level chain
WITH
  A AS (SELECT ...),
  B AS (SELECT ... FROM A),
  C AS (SELECT ... FROM B),
  D AS (SELECT ... FROM C),
  E AS (SELECT ... FROM D)
SELECT * FROM E;
```

**Example — fix**
```sql
-- Break into named temp tables with clear intermediate checkpoints
SELECT ... INTO #A FROM ...;
SELECT ... INTO #B FROM #A;
SELECT ... INTO #C FROM #B ...;
-- Fewer than 4 CTEs in the final query
WITH D AS (SELECT ... FROM #C)
SELECT * FROM D;
```

**Fix options**
1. Materialize intermediate steps into temp tables.
2. Extract complex sub-chains into views.
3. Refactor with window functions or aggregations to reduce the number of intermediate steps.

**Related checks:** T24 (CTE referenced more than once), T48 (deeply nested subqueries)

---

### T26 — Scalar Aggregate Without Explicit GROUP BY

**What it means**
A SELECT with aggregate functions (`COUNT`, `SUM`, `MAX`, `MIN`, `AVG`) but no GROUP BY. This is a "scalar aggregate" — it returns one row with the aggregate across all input rows. Flagged as Info when it may be unintentional.

**How to spot it**
```sql
-- This is valid T-SQL and returns 1 row; often intentional
SELECT COUNT(*) AS Total FROM dbo.Orders WHERE Status = 'Open';

-- This is intentional if the report needs one row:
SELECT MIN(OrderDate) AS Earliest, MAX(OrderDate) AS Latest FROM dbo.Orders;
```

**Example — fix**
```sql
-- If per-customer count was intended but GROUP BY was forgotten:
SELECT CustomerId, COUNT(*) AS OrderCount FROM dbo.Orders GROUP BY CustomerId;
```

**Fix options**
1. Add `GROUP BY` if per-group aggregation is intended.
2. If a scalar aggregate is correct, document it with a comment.

**Related checks:** T15 (DISTINCT without aggregation), T40 (non-ANSI GROUP BY)

---

### T27 — SET ROWCOUNT Usage

**What it means**
`SET ROWCOUNT n` limits the number of rows processed by subsequent DML statements. It is deprecated in SQL Server 2005 and above.

**How to spot it**
```sql
SET ROWCOUNT 1000;
DELETE FROM dbo.OldData WHERE ...;
SET ROWCOUNT 0;  -- re-enable
```

**Example — fix**
```sql
-- Modern equivalent using TOP in the DML statement
DELETE TOP (1000) FROM dbo.OldData WHERE ...;
```

**Fix options**
1. Use `TOP (n)` in the SELECT/DELETE/UPDATE statement directly.
2. For batching loops: use a WHILE loop with `TOP (batchSize)` on each iteration.

**Related checks:** T39 (deprecated syntax), T41 (RAISERROR)

---

### T28 — Missing OPTION (RECOMPILE) on High-Variance Query

**What it means**
A query with "catch-all" parameters — parameters that are NULL to mean "any value" — generates one cached plan that may be badly wrong for certain parameter values.

**Why it matters**
A plan compiled for `@status = NULL` (return all) is usually a full scan — which is terrible for `@status = 'Open'` (return 1%). SQL Server caches whichever plan it compiled first and reuses it for all calls.

**How to spot it**
```sql
-- Classic catch-all parameter pattern:
WHERE (@status IS NULL OR Status = @status)
  AND (@customerId IS NULL OR CustomerId = @customerId)
  AND (@startDate IS NULL OR OrderDate >= @startDate)
```

**Example — fix**
```sql
-- Add OPTION (RECOMPILE) to force per-execution compilation
SELECT OrderId FROM dbo.Orders
WHERE (@status IS NULL OR Status = @status)
  AND (@customerId IS NULL OR CustomerId = @customerId)
  AND (@startDate IS NULL OR OrderDate >= @startDate)
OPTION (RECOMPILE);
```

**Fix options**
1. Add `OPTION (RECOMPILE)` — eliminates plan caching for this query. Acceptable when compile time (< 5 ms) is much less than the savings from a correct plan.
2. Rewrite as dynamic SQL with only the active parameters — generates a specific plan per active filter combination (see T29 for injection risk).
3. Use `OPTION (OPTIMIZE FOR (@param = value))` for a specific representative value.

**Related checks:** T29 (dynamic SQL injection), T5 (implicit type coercion)

---

## Security and Dynamic SQL (T29–T38, T65–T67)

---

### T29 — Dynamic SQL Built by String Concatenation

**What it means**
The query string is built by concatenating untrusted input — parameters, column values, or external strings — using the `+` operator before execution with EXEC or sp_executesql.

**Why it matters**
SQL injection. An attacker controlling `@tableName` can inject `'Orders; DROP TABLE Orders; --'`. This is the most critical vulnerability in T-SQL development.

**How to spot it**
```sql
-- Triggers T29 — value concatenated into SQL string
SET @sql = 'SELECT * FROM dbo.Orders WHERE Status = ''' + @status + '''';
EXEC(@sql);

-- Also triggers — table name from user input
SET @sql = 'SELECT * FROM dbo.' + @tableName;
EXEC sp_executesql @sql;  -- still injected even with sp_executesql if @tableName is in the string
```

**Example — problem**
```sql
CREATE PROCEDURE dbo.GetOrders @status NVARCHAR(50)
AS
    DECLARE @sql NVARCHAR(500);
    SET @sql = N'SELECT * FROM dbo.Orders WHERE Status = ''' + @status + N'''';
    EXEC(@sql);
```

**Example — fix**
```sql
CREATE PROCEDURE dbo.GetOrders @status NVARCHAR(50)
AS
    DECLARE @sql NVARCHAR(500);
    SET @sql = N'SELECT * FROM dbo.Orders WHERE Status = @p_status';
    EXEC sp_executesql @sql, N'@p_status NVARCHAR(50)', @p_status = @status;
```

**Fix options (ranked by impact)**
1. **Parameterize via sp_executesql** — for value substitutions.
2. **Whitelist object names** — for table/column names: validate against `sys.tables` / `sys.columns` or an explicit allow-list before concatenation. Never concatenate user input directly.
3. **Static query with all filter options** — eliminate dynamic SQL entirely using catch-all patterns (see T28).

**Related checks:** T30 (EXEC string), T31 (user input in dynamic string), T33 (hardcoded credentials)

---

### T30 — EXEC(@string) Without sp_executesql

**What it means**
`EXEC(@variable)` executes a SQL string but cannot bind parameters — any values must be concatenated (injection risk). It also generates a new plan for every distinct string, filling the plan cache with one-time plans.

**How to spot it**
```sql
-- Triggers T30
EXEC(@sql);
EXECUTE(@dynamicSql);
```

**Example — fix**
```sql
-- Replace EXEC(@string) with sp_executesql and bind all values as parameters
EXEC sp_executesql @sql, N'@p1 INT, @p2 NVARCHAR(50)', @p1 = @id, @p2 = @status;
```

**Fix options**
1. Switch to `sp_executesql` with `@params` and `@values` binding.
2. Eliminate the dynamic SQL entirely if the query structure doesn't vary (T28, T29).

**Related checks:** T29 (string concatenation), T34 (sp_executesql without @params)

---

### T31 — User-Controlled Input Baked Into Dynamic SQL String

**What it means**
A procedure parameter named with user-facing semantics (`@filter`, `@where`, `@orderBy`, `@column`, `@tableName`, `@condition`) or typed as `VARCHAR(MAX)` / `NVARCHAR(MAX)` is concatenated into a SQL string without validation or binding.

**How to spot it**
```sql
-- Triggers T31 — @sortColumn is user-supplied
SET @sql = N'SELECT * FROM dbo.Orders ORDER BY ' + @sortColumn;

-- Triggers T31 — @whereClause is a raw SQL fragment
SET @sql = N'SELECT * FROM dbo.Orders WHERE ' + @whereClause;
```

**Example — fix**
```sql
-- Whitelist the allowed sort columns
IF @sortColumn NOT IN ('OrderDate', 'CustomerId', 'Total')
    RAISERROR('Invalid sort column', 16, 1);

SET @sql = N'SELECT * FROM dbo.Orders ORDER BY ' + QUOTENAME(@sortColumn);
EXEC sp_executesql @sql;
```

**Fix options**
1. Validate object names against an explicit whitelist.
2. Use `QUOTENAME()` around validated identifier substitutions to prevent injection via brackets.
3. Redesign the API to accept a sort column *index* (1, 2, 3) rather than a raw name, and map server-side.

**Related checks:** T29 (string concatenation), T30 (EXEC string)

---

### T32 — EXECUTE AS Without REVERT

**What it means**
`EXECUTE AS` changes the security context to another user for the remainder of the session. Without `REVERT`, the impersonated context persists after the procedure exits, potentially allowing the next caller to run under elevated privileges.

**How to spot it**
```sql
-- Triggers T32 — no REVERT in all code paths
EXECUTE AS USER = 'dbo';
-- ... some operations ...
-- No REVERT; if an error occurs, the elevated context remains
```

**Example — fix**
```sql
EXECUTE AS USER = 'dbo';
BEGIN TRY
    -- ... privileged operations ...
    REVERT;
END TRY
BEGIN CATCH
    REVERT;  -- always REVERT, even on error
    THROW;
END CATCH
```

**Fix options**
1. Always pair `EXECUTE AS` with `REVERT` in all exit paths including CATCH blocks.
2. Use `EXECUTE AS` only within modules that have `WITH EXECUTE AS` clause at the CREATE time — the context is automatically reverted when the module exits.

**Related checks:** T19 (missing TRY/CATCH), T20 (missing transaction)

---

### T33 — Hardcoded Credentials or Sensitive Literals

**What it means**
Connection strings, passwords, API keys, or other secrets are embedded as string literals in the T-SQL source.

**How to spot it**
```sql
-- Triggers T33
EXEC sp_addlinkedserver @server = 'RemoteServer',
    @srvproduct = '',
    @provider = 'SQLNCLI',
    @datasrc = 'remote.db.internal',
    @catalog = 'MyDB';

EXEC sp_addlinkedsrvlogin 'RemoteServer', 'false', NULL, 'sa', 'Password123!';

-- Also triggers:
SET @connStr = 'Server=prod;Database=Finance;User Id=admin;Password=secret42;';
```

**Example — fix**
1. Remove the credential from source. Use Windows Authentication for linked servers.
2. Store connection strings in SQL Server Credential objects (`CREATE CREDENTIAL`).
3. Rotate any credentials that have been committed to source control immediately.

**Related checks:** T29 (dynamic SQL injection), T35 (OPENROWSET with hardcoded connection)

---

### T34 — sp_executesql Called Without @params Argument

**What it means**
`sp_executesql` is called with only the SQL string, and no `@params` / `@values` arguments. This means any values in the query are either hardcoded or were concatenated — the parameterization benefit of `sp_executesql` is not being used.

**How to spot it**
```sql
-- Triggers T34 — no parameters bound
EXEC sp_executesql @sql;
```

**Example — fix**
```sql
-- Bind all variable values as parameters
EXEC sp_executesql @sql,
    N'@customerId INT, @status NVARCHAR(20)',
    @customerId = @customerId,
    @status = @status;
```

**Related checks:** T29 (string concatenation), T30 (EXEC string), T31 (user input in dynamic SQL)

---

### T35 — OPENROWSET or OPENQUERY With Hardcoded Connection String

**What it means**
`OPENROWSET` with a connection string embedded in the query text couples infrastructure details (server names, credentials) to the query source code.

**How to spot it**
```sql
-- Triggers T35
SELECT * FROM OPENROWSET('SQLNCLI', 'Server=prod-db;Trusted_Connection=yes;',
    'SELECT * FROM Finance.dbo.Transactions');
```

**Example — fix**
```sql
-- Use a Linked Server defined at the server level
SELECT * FROM [prod-db].Finance.dbo.Transactions;
```

**Fix options**
1. Replace with a Linked Server defined via `sp_addlinkedserver`.
2. Replace with a SQL Server Agent job or SSIS package for ETL scenarios.
3. Move the cross-server data access to application code with managed connection strings.

**Related checks:** T33 (hardcoded credentials), T37 (linked server)

---

### T36 — xp_cmdshell Reference

**What it means**
`xp_cmdshell` runs an operating-system shell command from within T-SQL, using the SQL Server service account's OS privileges. This is one of the highest-risk features in SQL Server.

**Why it matters**
If SQL Server is compromised via SQL injection (T29) or a misconfigured login, `xp_cmdshell` gives an attacker full OS command execution. It should be disabled at server level and absent from all application T-SQL.

**How to spot it**
```sql
EXEC xp_cmdshell 'net user hacker P@ssw0rd /add';
EXEC xp_cmdshell @command;
```

**Fix options**
1. Remove the `xp_cmdshell` usage and replace with: SQL Server Agent jobs (scheduled OS tasks), SSIS (file I/O, ETL), or application-layer code.
2. Verify `xp_cmdshell` is disabled at server level: `EXEC sp_configure 'xp_cmdshell'; -- should be 0`.
3. If `xp_cmdshell` is required for a DBA script, scope it to a privileged admin-only procedure and document the justification.

**Related checks:** T29 (SQL injection), T33 (hardcoded credentials)

---

### T37 — Linked Server Query

**What it means**
A four-part object name (`server.database.schema.table`) or `OPENQUERY` queries a remote SQL Server or other data source via a Linked Server. The query runs across the network and is not optimized by the local SQL Server engine.

**Why it matters**
- **Performance:** The full remote rowset may be fetched to the local server before filtering, depending on the query structure.
- **Security:** Linked Server credentials must be audited. A broadly-permissioned Linked Server login is a lateral movement risk.
- **Availability:** If the remote server is unavailable, the local query fails.

**How to spot it**
```sql
SELECT * FROM [RemoteServer].Finance.dbo.Transactions WHERE Amount > 1000;
SELECT * FROM OPENQUERY([RemoteServer], 'SELECT * FROM Finance.dbo.Transactions WHERE Amount > 1000');
```

**Fix options**
1. Replicate the data locally (SQL Server replication, SSIS, Azure Data Factory) and query locally.
2. If Linked Server is required, use `OPENQUERY` with the full filter pushed to the remote side.
3. Audit the Linked Server login: ensure it uses a dedicated low-privilege account.

**Related checks:** T35 (OPENROWSET), T33 (hardcoded credentials)

---

### T38 — Missing Schema Prefix on Object Name

**What it means**
An object referenced without a schema prefix (`FROM Orders` instead of `FROM dbo.Orders`). SQL Server resolves the name by checking the calling user's default schema first, then `dbo`. This causes plan cache pollution and can cause the wrong object to be accessed.

**How to spot it**
```sql
-- Triggers T38
SELECT * FROM Orders;          -- should be FROM dbo.Orders
EXEC GetOrderStatus @id;       -- should be EXEC dbo.GetOrderStatus @id
```

**Example — fix**
```sql
SELECT * FROM dbo.Orders;
EXEC dbo.GetOrderStatus @id;
```

**Fix options**
1. Add the schema prefix to all object references.
2. Set the default schema for application logins to `dbo` to reduce ambiguity — but still prefer explicit prefixes.

**Related checks:** T43 (INSERT without column list)

---

## Deprecated and Non-Idiomatic Syntax (T39–T45, T68–T73)

---

### T39 — Deprecated Outer Join Syntax

**What it means**
The `*=` and `=*` operators are the old Sybase-style outer join syntax. They were removed from SQL Server at compatibility level 90 (SQL Server 2005) and are invalid in all modern databases.

**How to spot it**
```sql
-- Triggers T39 — old-style outer join
SELECT c.Name, o.OrderId
FROM dbo.Customers c, dbo.Orders o
WHERE c.CustomerId *= o.CustomerId;  -- old LEFT OUTER JOIN
```

**Example — fix**
```sql
SELECT c.Name, o.OrderId
FROM dbo.Customers c
LEFT OUTER JOIN dbo.Orders o ON c.CustomerId = o.CustomerId;
```

**Related checks:** T17 (outer join nullified by WHERE)

---

### T40 — Non-ANSI GROUP BY Behavior

**What it means**
`GROUP BY ALL` includes groups that don't match the WHERE clause (with NULL aggregate values). It was deprecated in SQL Server 2008 and is no longer supported in current versions.

**How to spot it**
```sql
-- Triggers T40
SELECT Status, COUNT(*) FROM dbo.Orders WHERE Status <> 'Cancelled' GROUP BY ALL Status;
```

**Example — fix**
```sql
-- Standard ANSI GROUP BY — only groups matching the WHERE clause
SELECT Status, COUNT(*) FROM dbo.Orders WHERE Status <> 'Cancelled' GROUP BY Status;
```

**Related checks:** T26 (aggregate without GROUP BY), T27 (SET ROWCOUNT)

---

### T41 — RAISERROR Instead of THROW

**What it means**
`RAISERROR` generates an error but has quirks: it uses `printf`-style format strings (injection risk if the message is user-supplied), does not automatically re-raise the original error in a CATCH block, and is less readable than `THROW`.

**How to spot it**
```sql
RAISERROR('Something went wrong: %s', 16, 1, @errorMsg);
```

**Example — fix**
```sql
-- Modern: simple, no format string risk
THROW 50001, N'Something went wrong', 1;

-- In a CATCH block to re-raise with original error context:
THROW;  -- re-raises the caught error unchanged
```

**Fix options**
1. Replace `RAISERROR` with `THROW` in new code (SQL Server 2012+).
2. In CATCH blocks, use bare `THROW;` to re-raise with full original metadata.
3. If supporting SQL Server 2008 or earlier, keep `RAISERROR` but document the constraint.

**Related checks:** T19 (missing TRY/CATCH), T20 (missing transaction)

---

### T42 — GETDATE() Where Higher-Precision or UTC Function Preferred

**What it means**
`GETDATE()` returns the current local server time as `DATETIME` (3.33 ms precision). For audit timestamps, financial records, or distributed systems, UTC time and higher precision are usually required.

**How to spot it**
```sql
INSERT INTO dbo.AuditLog (EventTime) VALUES (GETDATE());
```

**Example — fix**
```sql
-- UTC, DATETIME2(7) precision
INSERT INTO dbo.AuditLog (EventTime) VALUES (SYSUTCDATETIME());
```

**Fix options**
1. `SYSUTCDATETIME()` — UTC, DATETIME2(7) precision. Preferred for new columns.
2. `SYSDATETIME()` — local time, DATETIME2(7) precision.
3. `GETUTCDATE()` — UTC, DATETIME precision. Better than GETDATE(), worse than SYSUTCDATETIME.
4. `GETDATE()` remains acceptable on legacy `DATETIME` columns where the type cannot be changed.

**Related checks:** T43 (INSERT without column list)

---

### T43 — INSERT Without Column List

**What it means**
`INSERT INTO table VALUES (...)` assumes values match the physical column order. A schema change (adding a NOT NULL column, reordering columns) silently inserts values into the wrong columns or causes a runtime error.

**How to spot it**
```sql
-- Triggers T43 — no column list
INSERT INTO dbo.Orders VALUES (42, '2024-01-15', 'Open', 250.00);
```

**Example — fix**
```sql
INSERT INTO dbo.Orders (CustomerId, OrderDate, Status, TotalAmount)
VALUES (42, '2024-01-15', 'Open', 250.00);
```

**Related checks:** T1 (SELECT *), T38 (missing schema prefix)

---

### T44 — SET ANSI_NULLS OFF or SET QUOTED_IDENTIFIER OFF

**What it means**
These settings change fundamental T-SQL semantics. `SET ANSI_NULLS OFF` makes `= NULL` work (compare T16). `SET QUOTED_IDENTIFIER OFF` makes double-quotes behave as string delimiters instead of identifier quotes. Both are required to be ON for indexes on views, filtered indexes, and natively compiled objects.

**How to spot it**
```sql
SET ANSI_NULLS OFF;
SET QUOTED_IDENTIFIER OFF;
```

**Fix options**
1. Remove both SET statements.
2. Fix any code that depended on `= NULL` behavior by replacing with `IS NULL` (T16).
3. Replace double-quoted string literals with single-quoted strings.

**Related checks:** T16 (NULL comparison), T27 (deprecated settings)

---

### T45 — Temporary Table Without Explicit Column Definition

**What it means**
`SELECT ... INTO #temp FROM ...` infers column names and types from the source expression. If the source changes (column renamed, type widened, computed expression altered), the temp table schema changes silently.

**How to spot it**
```sql
-- Triggers T45
SELECT OrderId, CustomerId, Status INTO #WorkingSet FROM dbo.Orders WHERE Status = 'Open';
```

**Example — fix**
```sql
-- Explicit schema — survives source column changes
CREATE TABLE #WorkingSet (
    OrderId    INT         NOT NULL,
    CustomerId INT         NOT NULL,
    Status     VARCHAR(20) NOT NULL
);
INSERT INTO #WorkingSet (OrderId, CustomerId, Status)
SELECT OrderId, CustomerId, Status FROM dbo.Orders WHERE Status = 'Open';
```

**Fix options**
1. Use `CREATE TABLE #name (...)` with explicit column definitions.
2. For quick intermediate materializtion where schema changes are low risk, `SELECT INTO` is acceptable — document with a comment.

**Related checks:** T46 (table variable for large data), T43 (INSERT without column list)

---

## Performance Smells (T46–T50, T74–T78)

---

### T46 — Table Variable Used for Potentially Large Data

**What it means**
A `DECLARE @table TABLE (...)` has no statistics. The optimizer always estimates exactly 1 row from a table variable, regardless of how many rows are actually inserted. When a table variable with 100,000 rows is joined to another table, the optimizer picks a join strategy optimized for 1 row — usually Nested Loops — which is catastrophically wrong.

**Why it matters**
A Nested Loops join with 100,000 rows on the inner side (instead of the estimated 1) causes 100,000× more work than planned. This is a classic parameter sniffing look-alike but for table variables.

**How to spot it**
```sql
-- Triggers T46 — table variable populated from large tables
DECLARE @orders TABLE (OrderId INT, CustomerId INT);
INSERT INTO @orders SELECT OrderId, CustomerId FROM dbo.Orders WHERE OrderDate >= @start;
-- (could be millions of rows — optimizer still estimates 1)
SELECT c.Name, o.OrderId FROM dbo.Customers c JOIN @orders o ON o.CustomerId = c.CustomerId;
```

**Example — fix**
```sql
-- Temp table: has statistics, supports indexes, participates in parallel plans
CREATE TABLE #orders (OrderId INT, CustomerId INT);
INSERT INTO #orders SELECT OrderId, CustomerId FROM dbo.Orders WHERE OrderDate >= @start;
CREATE INDEX IX_orders_CustomerId ON #orders (CustomerId);
SELECT c.Name, o.OrderId FROM dbo.Customers c JOIN #orders o ON o.CustomerId = c.CustomerId;
DROP TABLE #orders;
```

**Fix options**
1. Replace `@table TABLE` with `#temp` table — gets statistics, supports indexes, allows parallel plans.
2. Use `OPTION (RECOMPILE)` on the query joining to the table variable — forces a re-estimate of table variable size at compile time (SQL Server 2019+ also supports trace flag 2453 for automatic re-estimation).
3. Keep table variables for small sets (< ~100 rows) where statistics are irrelevant.

**Related checks:** T24 (CTE referenced more than once), T45 (temp table without column definition)

---

### T47 — String Functions on Potentially Large Rowsets

**What it means**
String manipulation functions (`STRING_SPLIT`, `CHARINDEX`, `SUBSTRING`, `PATINDEX`, `REPLACE`, `STUFF`) called in a WHERE, FROM, or SELECT context against large tables. These functions are CPU-intensive per row and cannot use index seeks.

**How to spot it**
```sql
-- Triggers T47 — STRING_SPLIT as a join source on a large input
SELECT p.ProductId FROM dbo.Products p
JOIN STRING_SPLIT(@productList, ',') s ON s.value = CAST(p.ProductId AS VARCHAR);

-- Triggers T47 — CHARINDEX in WHERE on a large table
SELECT * FROM dbo.Descriptions WHERE CHARINDEX('urgent', Description) > 0;
```

**Fix options**
1. For `CHARINDEX` / `PATINDEX` in WHERE: consider Full-Text Search (CONTAINS), a computed persisted column, or an application-side filter on a pre-filtered set.
2. For `STRING_SPLIT` as a join source: keep the split list small (< 1,000 values); for larger lists, pass data as a TVP (Table-Valued Parameter) instead.
3. For `REPLACE`/`STUFF` in SELECT on large tables: batch the processing or move it to the application layer.

**Related checks:** T6 (leading wildcard LIKE), T8 (scalar UDF)

---

### T48 — Deeply Nested Scalar Subqueries

**What it means**
A subquery inside a subquery inside a subquery (3+ levels). Each level of scalar subquery can execute once per row of its parent, compounding the row-by-row cost.

**How to spot it**
```sql
-- Triggers T48 — 3-level nesting
SELECT
    (SELECT MAX(Amount) FROM dbo.Payments WHERE OrderId =
        (SELECT TOP 1 OrderId FROM dbo.Orders WHERE CustomerId = c.CustomerId ORDER BY OrderDate DESC)
    ) AS LatestPayment
FROM dbo.Customers c;
```

**Example — fix**
```sql
WITH LatestOrders AS (
    SELECT CustomerId, MAX(OrderDate) AS LatestDate
    FROM dbo.Orders GROUP BY CustomerId
),
LatestOrderIds AS (
    SELECT o.CustomerId, o.OrderId
    FROM dbo.Orders o
    JOIN LatestOrders lo ON o.CustomerId = lo.CustomerId AND o.OrderDate = lo.LatestDate
)
SELECT c.CustomerId, MAX(p.Amount) AS LatestPayment
FROM dbo.Customers c
LEFT JOIN LatestOrderIds lo ON lo.CustomerId = c.CustomerId
LEFT JOIN dbo.Payments p ON p.OrderId = lo.OrderId
GROUP BY c.CustomerId;
```

**Fix options**
1. Refactor with CTEs to flatten the nesting.
2. Use window functions to compute per-row aggregates without nesting.
3. Materialize intermediate results into temp tables.

**Related checks:** T9 (correlated subquery), T25 (deep CTE chain), T46 (table variable)

---

### T49 — Pagination Without Deterministic Sort Key

**What it means**
`OFFSET / FETCH NEXT` or `ROW_NUMBER() OVER (ORDER BY col)` pagination where `col` is not unique. If two rows have the same sort value, their relative order is non-deterministic — a user may see the same row on page 1 and page 2, or skip rows between pages.

**How to spot it**
```sql
-- Triggers T49 — non-deterministic ORDER BY (OrderDate is not unique)
SELECT OrderId, CustomerId FROM dbo.Orders
ORDER BY OrderDate
OFFSET @offset ROWS FETCH NEXT @pageSize ROWS ONLY;
```

**Example — fix**
```sql
-- Add a unique tiebreaker (OrderId is the primary key)
SELECT OrderId, CustomerId FROM dbo.Orders
ORDER BY OrderDate DESC, OrderId ASC
OFFSET @offset ROWS FETCH NEXT @pageSize ROWS ONLY;
```

**Fix options**
1. Add the primary key (or any unique column) as a tiebreaker in the ORDER BY.
2. Use keyset pagination (WHERE id > @lastSeenId ORDER BY id) — avoids OFFSET's O(offset) scan cost and is always deterministic.

**Related checks:** T18 (missing ORDER BY), T14 (unbounded result set)

---

### T50 — Implicit Collation or Type Conversion in Comparison

**What it means**
Two columns or a column and a parameter with different collations (e.g., `Latin1_General_CI_AS` vs `SQL_Latin1_General_CP1_CI_AS`) or different character types (`VARCHAR` vs `NVARCHAR`) are compared without explicit alignment. SQL Server must convert one side implicitly, which may block index seeks or cause runtime collation errors.

**How to spot it**
```sql
-- Triggers T50 — VARCHAR column joined to NVARCHAR column (or literal N'')
FROM dbo.Customers c
JOIN dbo.Contacts ct ON ct.Email = c.EmailAddress  -- different collations on the two tables

-- Also triggers T50 — mixed collations in WHERE
WHERE dbo.Users.Username = @username  -- @username is NVARCHAR, column is VARCHAR COLLATE Latin1...
```

**Example — fix**
```sql
-- Option 1: COLLATE clause to align
WHERE dbo.Users.Username COLLATE DATABASE_DEFAULT = @username COLLATE DATABASE_DEFAULT;

-- Option 2: CAST to align types
WHERE dbo.Users.Username = CAST(@username AS VARCHAR(100));

-- Best option: fix the schema — align column types and collations at definition time
ALTER TABLE dbo.Contacts ALTER COLUMN Email NVARCHAR(255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL;
```

**Fix options**
1. Fix column types and collations at the schema level (permanent fix).
2. Add explicit `COLLATE` in the query to align at query time.
3. Cast the literal or parameter to match the column type (see T5).

**Related checks:** T5 (implicit type coercion), T22 (CASE type mismatch)

---

### T51 — NOT IN With Nullable Subquery

**What it means**
Three-valued logic. If the subquery `SELECT col FROM T` returns even one NULL row, then every comparison `outer.col NOT IN (subquery)` evaluates to UNKNOWN — not FALSE — causing the entire `NOT IN` predicate to return zero rows with no error.

**Why it matters**
This is a completely silent data correctness bug. A query like `SELECT ... FROM Orders WHERE CustomerId NOT IN (SELECT CustomerId FROM Exceptions)` returns no rows the moment a single row in Exceptions has a NULL CustomerId, regardless of how many Orders exist.

**How to spot it**
```sql
-- Triggers T51 — CustomerId in Exceptions is nullable
SELECT OrderId FROM dbo.Orders
WHERE CustomerId NOT IN (SELECT CustomerId FROM dbo.Exceptions);
-- Returns zero rows if ANY Exceptions.CustomerId is NULL
```

**Example — fix**
```sql
-- Safe: NOT EXISTS handles NULLs correctly
SELECT OrderId FROM dbo.Orders o
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Exceptions e WHERE e.CustomerId = o.CustomerId
);

-- Also safe: filter NULLs inside the subquery
SELECT OrderId FROM dbo.Orders
WHERE CustomerId NOT IN (
    SELECT CustomerId FROM dbo.Exceptions WHERE CustomerId IS NOT NULL
);
```

**Fix options**
1. Replace `NOT IN (subquery)` with `NOT EXISTS (SELECT 1 FROM T WHERE T.col = outer.col)`.
2. Add `WHERE col IS NOT NULL` inside the subquery if `NOT IN` must be kept.
3. If the column is defined NOT NULL in the schema, document it and note that T51 does not apply.

**Related checks:** T16 (NULL comparison using = NULL), T17 (LEFT JOIN nullified by WHERE)

---

### T52 — Division by Zero Without NULLIF Guard

**What it means**
A division expression where the denominator could be zero. SQL Server raises error 8134 ("Divide by zero error encountered") and aborts the batch.

**Why it matters**
Division by zero is a runtime failure that surfaces in production when edge-case data arrives — e.g., `OrderLines` table with zero `Quantity`, or a reporting query calculating averages on a partition that has no rows.

**How to spot it**
```sql
-- Triggers T52 — Qty could be 0
SELECT TotalCost / Qty AS CostPerUnit FROM dbo.OrderLines;

-- Also triggers
SELECT Hits * 100.0 / Impressions AS CTR FROM dbo.AdStats;
```

**Example — fix**
```sql
-- NULLIF returns NULL when denominator is 0, avoiding the error
SELECT TotalCost / NULLIF(Qty, 0) AS CostPerUnit FROM dbo.OrderLines;

SELECT Hits * 100.0 / NULLIF(Impressions, 0) AS CTR FROM dbo.AdStats;
```

**Fix options**
1. `NULLIF(denominator, 0)` — returns NULL on zero, propagating NULL through the expression.
2. `CASE WHEN denominator = 0 THEN NULL ELSE numerator / denominator END` — for more explicit control.
3. Add a WHERE filter to exclude rows with zero denominator if those rows are always invalid.

**Related checks:** T23 (missing ELSE in CASE), T52

---

### T53 — TOP Without ORDER BY

**What it means**
`SELECT TOP (n) ...` without an `ORDER BY` clause returns a non-deterministic set — SQL Server picks whichever N rows it reads first, which can change between executions depending on parallelism, I/O state, and plan choice.

**Why it matters**
Applications expecting consistent "top N" results — dashboards, feeds, paginated APIs — can receive different rows on different calls with no error, making bugs impossible to reproduce.

**How to spot it**
```sql
-- Triggers T53 — no ORDER BY; result varies per execution
SELECT TOP (10) OrderId, CustomerId FROM dbo.Orders;
```

**Example — fix**
```sql
-- Deterministic: always returns 10 most recent orders
SELECT TOP (10) OrderId, CustomerId
FROM dbo.Orders
ORDER BY OrderDate DESC, OrderId ASC;

-- Random sampling (intentional): documented
SELECT TOP (100) OrderId FROM dbo.Orders ORDER BY NEWID(); -- intentional random sample
```

**Fix options**
1. Add an `ORDER BY` matching the business intent (most recent, highest value, etc.).
2. For random sampling, add `ORDER BY NEWID()` with a comment.
3. If the query is used as a subquery or EXISTS source where TOP serves as a row limiter, the lack of ORDER BY may be acceptable — document it.

**Related checks:** T18 (missing ORDER BY in final SELECT), T49 (pagination without deterministic sort)

---

### T54 — COUNT(\*) > 0 Instead of EXISTS

**What it means**
Using `COUNT(*) > 0` solely to check whether any rows exist forces SQL Server to count all matching rows before determining existence. `EXISTS` stops at the first match.

**Why it matters**
On a large table where the matching row is near the end, `COUNT(*) > 0` reads the entire matching set. `EXISTS` reads exactly one row. The difference can be milliseconds vs. seconds.

**How to spot it**
```sql
-- Triggers T54 — counts all matches just to check existence
IF (SELECT COUNT(*) FROM dbo.Orders WHERE Status = 'Pending') > 0
    PRINT 'Has pending orders';

-- Also triggers in WHERE
SELECT * FROM dbo.Customers c
WHERE (SELECT COUNT(*) FROM dbo.Orders o WHERE o.CustomerId = c.CustomerId) > 0;
```

**Example — fix**
```sql
IF EXISTS (SELECT 1 FROM dbo.Orders WHERE Status = 'Pending')
    PRINT 'Has pending orders';

SELECT * FROM dbo.Customers c
WHERE EXISTS (SELECT 1 FROM dbo.Orders o WHERE o.CustomerId = c.CustomerId);
```

**Fix options**
1. Replace `(SELECT COUNT(*) FROM T WHERE ...) > 0` with `EXISTS (SELECT 1 FROM T WHERE ...)`.
2. If the actual count value is also needed, keep `COUNT(*)` and reuse the variable — don't run both.

**Related checks:** T15 (DISTINCT without aggregation), T9 (correlated subquery in SELECT)

---

### T55 — VARCHAR/NVARCHAR Implicit Promotion in String Concatenation

**What it means**
When `VARCHAR` and `NVARCHAR` values are concatenated with `+`, SQL Server implicitly promotes the `VARCHAR` operand to `NVARCHAR`. This doubles the memory allocated for the VARCHAR portion and can silently corrupt characters outside the ASCII range.

**Why it matters**
Dynamic SQL procedures building `NVARCHAR` strings often mix `N''` and `''` prefixes inconsistently. The implicit promotion goes unnoticed until a non-ASCII character in a `VARCHAR` value is truncated or corrupted during the conversion.

**How to spot it**
```sql
-- Triggers T55 — mixing VARCHAR variable with NVARCHAR literals
DECLARE @sql VARCHAR(500);
SET @sql = N'SELECT * FROM dbo.' + @tableName + N' WHERE Status = @s';
-- @sql is VARCHAR; N'' literals make the expression NVARCHAR but @sql loses the promotion
```

**Example — fix**
```sql
-- Consistent: all NVARCHAR
DECLARE @sql NVARCHAR(500);
SET @sql = N'SELECT * FROM dbo.' + @tableName + N' WHERE Status = @s';
```

**Fix options**
1. Declare all dynamic SQL string variables as `NVARCHAR` — the standard for dynamic SQL in SQL Server.
2. Use `N''` prefix consistently on all string literals in the concatenation.
3. Add explicit `CAST(@varcharVar AS NVARCHAR(n))` when mixing types is unavoidable.

**Related checks:** T5 (implicit type coercion), T29 (dynamic SQL concatenation), T50 (collation/type mismatch)

---

### T56 — @@IDENTITY Instead of SCOPE\_IDENTITY()

**What it means**
`@@IDENTITY` returns the last identity value generated anywhere in the current session — including identity values generated by triggers fired as a result of the INSERT. `SCOPE_IDENTITY()` returns only the value generated in the current scope.

**Why it matters**
If the target table has a trigger that inserts into another table with an identity column (common in replication and audit setups), `@@IDENTITY` returns the trigger's identity value instead of the original row's. This causes the calling code to store the wrong ID — silently, with no error.

**How to spot it**
```sql
-- Triggers T56
INSERT INTO dbo.Orders (CustomerId, OrderDate) VALUES (@cid, @date);
SET @newOrderId = @@IDENTITY;  -- may return trigger's identity, not Orders.OrderId
```

**Example — fix**
```sql
INSERT INTO dbo.Orders (CustomerId, OrderDate) VALUES (@cid, @date);
SET @newOrderId = SCOPE_IDENTITY();  -- always returns the Orders.OrderId value

-- For multiple rows, use OUTPUT:
INSERT INTO dbo.Orders (CustomerId, OrderDate)
OUTPUT INSERTED.OrderId INTO @insertedIds
SELECT CustomerId, @date FROM @customers;
```

**Fix options**
1. Replace `@@IDENTITY` with `SCOPE_IDENTITY()` everywhere.
2. For multi-row inserts, use the `OUTPUT INSERTED.id INTO @table` clause.
3. For cross-scope identity retrieval, use `IDENT_CURRENT('TableName')` — but note it is not session-scoped.

**Related checks:** T57 (@@ROWCOUNT invalidation), T19 (missing TRY/CATCH)

---

### T57 — @@ROWCOUNT Read After Statement That Resets It

**What it means**
`@@ROWCOUNT` is reset to reflect the row count of the most recently executed statement — every statement, including `IF`, `SET @var = val`, `PRINT`, `SELECT @var = col`, and `DECLARE`. A single intervening statement between the DML and the `@@ROWCOUNT` read returns the wrong count.

**Why it matters**
Developers commonly write: `UPDATE ...; IF @something ... ; IF @@ROWCOUNT = 0 ...` — the `IF @something` already reset `@@ROWCOUNT` to 0. The `UPDATE` may have affected rows, but the check reads 0 and incorrectly treats it as "no rows updated".

**How to spot it**
```sql
-- Triggers T57 — IF statement resets @@ROWCOUNT before the check
UPDATE dbo.Orders SET Status = 'Shipped' WHERE OrderId = @id;
IF @logEnabled = 1  -- this IF resets @@ROWCOUNT!
    INSERT INTO dbo.Log ...;
IF @@ROWCOUNT = 0  -- reads the INSERT's rowcount, not the UPDATE's
    RAISERROR('Order not found', 16, 1);
```

**Example — fix**
```sql
UPDATE dbo.Orders SET Status = 'Shipped' WHERE OrderId = @id;
SET @rowsUpdated = @@ROWCOUNT;  -- capture immediately

IF @logEnabled = 1
    INSERT INTO dbo.Log ...;
IF @rowsUpdated = 0
    RAISERROR('Order not found', 16, 1);
```

**Fix options**
1. Capture `SET @rows = @@ROWCOUNT` as the very next statement after every DML.
2. Use the `OUTPUT` clause to capture affected rows into a table variable for more complex scenarios.

**Related checks:** T56 (@@IDENTITY), T19 (missing TRY/CATCH), T20 (missing transaction)

---

### T58 — Recursive CTE Without MAXRECURSION

**What it means**
A recursive CTE processes levels of a hierarchy iteratively. The default maximum recursion depth is 100. A hierarchy deeper than 100 levels causes error 530 at runtime. Conversely, `OPTION (MAXRECURSION 0)` removes the limit entirely, allowing infinite loops on bad data.

**Why it matters**
The 100-level default works fine in development with shallow test data but fails in production when deeper hierarchies appear. `MAXRECURSION 0` silently allows runaway recursion if the anchor/recursive members have a logic error (e.g., a cycle in the data).

**How to spot it**
```sql
-- Triggers T58 — no MAXRECURSION option
WITH OrgHierarchy AS (
    SELECT EmployeeId, ManagerId, 1 AS Level
    FROM dbo.Employees WHERE ManagerId IS NULL
    UNION ALL
    SELECT e.EmployeeId, e.ManagerId, h.Level + 1
    FROM dbo.Employees e
    JOIN OrgHierarchy h ON e.ManagerId = h.EmployeeId
)
SELECT * FROM OrgHierarchy;  -- fails with error 530 if org has > 100 levels
```

**Example — fix**
```sql
WITH OrgHierarchy AS (
    SELECT EmployeeId, ManagerId, 1 AS Level
    FROM dbo.Employees WHERE ManagerId IS NULL
    UNION ALL
    SELECT e.EmployeeId, e.ManagerId, h.Level + 1
    FROM dbo.Employees e
    JOIN OrgHierarchy h ON e.ManagerId = h.EmployeeId
    WHERE h.Level < 500  -- guard against cycles
)
SELECT * FROM OrgHierarchy
OPTION (MAXRECURSION 500);
```

**Fix options**
1. Add `OPTION (MAXRECURSION n)` where `n` matches the realistic maximum depth.
2. For unbounded hierarchies: use `OPTION (MAXRECURSION 0)` with a depth-counter column in the recursive member (`WHERE h.Level < 1000`) to prevent runaway recursion.
3. For cycle detection: add a path string (concatenating IDs) and check for repeated IDs in the anchor or recursive member.

**Related checks:** T25 (CTE chain depth), T48 (deeply nested subqueries)

---

### T59 — MERGE Without HOLDLOCK (Race Condition)

**What it means**
The MERGE statement performs a read (to determine MATCHED / NOT MATCHED) and then a write (INSERT / UPDATE / DELETE). Under concurrent workloads, two sessions can both read "NOT MATCHED" before either completes the INSERT — causing a duplicate key violation or duplicate row.

**Why it matters**
This is a well-documented SQL Server behavior (not a bug). MERGE is frequently used for upsert patterns in high-concurrency environments. Without HOLDLOCK, occasional primary key violations (error 2627) appear under load, are hard to reproduce in testing, and surface as mysterious "intermittent failures".

**How to spot it**
```sql
-- Triggers T59 — no HOLDLOCK; race condition under concurrent inserts
MERGE dbo.Products AS t
USING (SELECT @productId AS ProductId, @price AS Price) AS s
ON t.ProductId = s.ProductId
WHEN NOT MATCHED THEN INSERT (ProductId, Price) VALUES (s.ProductId, s.Price)
WHEN MATCHED THEN UPDATE SET t.Price = s.Price;
```

**Example — fix**
```sql
-- HOLDLOCK acquires and holds a range lock, preventing the race
MERGE dbo.Products WITH (HOLDLOCK) AS t
USING (SELECT @productId AS ProductId, @price AS Price) AS s
ON t.ProductId = s.ProductId
WHEN NOT MATCHED THEN INSERT (ProductId, Price) VALUES (s.ProductId, s.Price)
WHEN MATCHED THEN UPDATE SET t.Price = s.Price;
```

**Fix options**
1. Add `WITH (HOLDLOCK)` to the MERGE target table — the simplest and most effective fix.
2. Wrap the MERGE in a `SERIALIZABLE` transaction.
3. Replace MERGE with explicit `IF EXISTS ... UPDATE ELSE INSERT` inside a `BEGIN TRANSACTION` with `UPDLOCK, SERIALIZABLE` hints on the check read.

**Related checks:** T20 (missing transaction), T29 (dynamic SQL injection in MERGE)

---

### T60 — DATEDIFF as Non-Sargable Date Range Filter

**What it means**
`DATEDIFF(part, column, expression)` wraps the column side of the comparison, making it non-sargable — the same root cause as T4. SQL Server cannot use an index seek on the date column; it must evaluate `DATEDIFF` for every row.

**Why it matters**
A query like `WHERE DATEDIFF(DAY, OrderDate, GETDATE()) <= 30` on a 50M-row table forces a full scan of the `OrderDate` index instead of a range seek. Rewriting as a range predicate is O(log n) vs O(n).

**How to spot it**
```sql
-- Triggers T60 — DATEDIFF wraps the column
WHERE DATEDIFF(DAY, OrderDate, GETDATE()) <= 30
WHERE DATEDIFF(MONTH, CreatedDate, GETDATE()) = 0
WHERE DATEDIFF(HOUR, LastSeen, SYSDATETIME()) < 24
```

**Example — fix**
```sql
-- Range predicate on the bare column — allows index seek
WHERE OrderDate >= DATEADD(DAY, -30, CAST(GETDATE() AS DATE))

WHERE CreatedDate >= DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()), 0)
  AND CreatedDate <  DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE()) + 1, 0)

WHERE LastSeen >= DATEADD(HOUR, -24, SYSDATETIME())
```

**Fix options**
1. Rewrite as `WHERE col >= DATEADD(part, -n, reference_point)` — puts the arithmetic on the constant side only.
2. For "current month" or "current year" filters, pre-compute the boundary dates into variables.

**Related checks:** T4 (function wrapping column), T61 (BETWEEN datetime boundary)

---

### T61 — BETWEEN on DATETIME With Date-Only Boundaries

**What it means**
`BETWEEN '2024-01-01' AND '2024-01-31'` on a `DATETIME` or `DATETIME2` column is inclusive on both ends — but `'2024-01-31'` is interpreted as `'2024-01-31 00:00:00.000'`. All rows with a time component after midnight on the last day are silently excluded.

**Why it matters**
"Find all orders in January 2024" with `BETWEEN '2024-01-01' AND '2024-01-31'` will miss orders placed on January 31st at 9am, 2pm, or any time after midnight. This is a silent logic bug producing wrong financial totals, missing records, and reconciliation failures.

**How to spot it**
```sql
-- Triggers T61 — misses Jan 31 times after midnight
SELECT * FROM dbo.Orders WHERE OrderDate BETWEEN '2024-01-01' AND '2024-01-31';

-- Also triggers
SELECT * FROM dbo.Events WHERE EventDate BETWEEN @startDate AND @endDate;
-- if @startDate/@endDate are DATE parameters used against a DATETIME column
```

**Example — fix**
```sql
-- Half-open range: captures the entire last day
SELECT * FROM dbo.Orders
WHERE OrderDate >= '2024-01-01' AND OrderDate < '2024-02-01';
```

**Fix options**
1. Use half-open range: `WHERE col >= @start AND col < DATEADD(DAY, 1, @end)`.
2. For DATE-typed columns (no time component), `BETWEEN` is safe — only flag for DATETIME/DATETIME2.
3. Use `CAST(col AS DATE) BETWEEN @startDate AND @endDate` if time components should be ignored — but note this is non-sargable (T4).

**Related checks:** T60 (DATEDIFF non-sargable), T42 (GETDATE/UTC precision)

---

### T62 — SELECT Variable Assignment — Silent Prior-Value Retention

**What it means**
`SELECT @var = col FROM T WHERE ...` does not set `@var = NULL` when no rows match — it leaves `@var` at whatever value it held before the SELECT. This is the opposite of `SET @var = (SELECT ...)`, which returns NULL when the subquery returns no rows.

**Why it matters**
A procedure that checks `IF @var IS NULL` after `SELECT @var = col FROM T WHERE ID = @id` will not detect the "not found" case if `@var` was initialized to a value before the SELECT. Callers receive stale data and act on it silently.

**How to spot it**
```sql
-- Triggers T62 — if no row matches, @status retains its previous value
DECLARE @status NVARCHAR(20) = N'Unknown';
SELECT @status = Status FROM dbo.Orders WHERE OrderId = @orderId;
IF @status = N'Unknown'
    RAISERROR('Order not found', 16, 1);  -- WRONG: 'Unknown' may be the stale init value
```

**Example — fix**
```sql
-- SET form returns NULL when no rows found
DECLARE @status NVARCHAR(20);
SET @status = (SELECT Status FROM dbo.Orders WHERE OrderId = @orderId);
IF @status IS NULL
    RAISERROR('Order not found', 16, 1);  -- Correct: NULL means no row found
```

**Fix options**
1. Use `SET @var = (SELECT col FROM T WHERE ...)` — NULL on no rows, error if multiple rows.
2. Initialize `@var = NULL` before the SELECT and test with `IS NULL` after.
3. Check `@@ROWCOUNT` immediately after the SELECT to detect the no-rows case.

**Related checks:** T57 (@@ROWCOUNT invalidation), T16 (NULL comparison)

---

### T63 — ISNUMERIC() for Numeric Type Validation

**What it means**
`ISNUMERIC()` returns 1 for any string that can be interpreted as a number — including single characters like `'+'`, `'-'`, `'.'`, `','`, `'$'`, and `'E'` that are not valid for `CAST(... AS INT)` or `CAST(... AS DECIMAL)`.

**Why it matters**
Code that uses `IF ISNUMERIC(@val) = 1 THEN CAST(@val AS INT)` will still throw a conversion error in production when these edge-case inputs arrive. The validation is incomplete.

**How to spot it**
```sql
-- Triggers T63
IF ISNUMERIC(@input) = 1
    SET @amount = CAST(@input AS DECIMAL(18,2));

-- ISNUMERIC returns 1 for '$', '.', '+', 'E', ',' — none of which cast to DECIMAL
```

**Example — fix**
```sql
-- TRY_CAST returns NULL on failure; no conversion error thrown
SET @amount = TRY_CAST(@input AS DECIMAL(18,2));
IF @amount IS NULL
    RAISERROR('Invalid amount', 16, 1);
```

**Fix options**
1. Replace `ISNUMERIC(expr) = 1` with `TRY_CAST(expr AS target_type) IS NOT NULL` (SQL Server 2012+).
2. Replace with `TRY_CONVERT(target_type, expr) IS NOT NULL` — equivalent but useful when a style code is needed.
3. For INTEGER validation specifically, also test `FLOOR(TRY_CAST(expr AS FLOAT)) = TRY_CAST(expr AS FLOAT)` to exclude decimal values.

**Related checks:** T22 (CASE type mismatch), T5 (implicit type coercion)

---

### T64 — Output Parameter Not Initialized in All Code Paths

**What it means**
A stored procedure or function declares an `OUTPUT` parameter but does not assign a value to it in every possible execution path through the body. The caller receives the parameter's pre-call value or an undefined value on paths where no assignment occurs.

**Why it matters**
If the caller does not initialize the output variable before the EXEC and relies on a non-NULL value from the procedure, it may silently receive garbage. This is especially dangerous in error paths where an OUTPUT parameter is the mechanism for returning error codes.

**How to spot it**
```sql
-- Triggers T64 — @result is only set inside the IF branch
CREATE PROCEDURE dbo.GetOrderStatus
    @orderId INT,
    @result NVARCHAR(20) OUTPUT
AS
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderId = @orderId)
        SELECT @result = Status FROM dbo.Orders WHERE OrderId = @orderId;
    -- If order doesn't exist, @result is never set
END
```

**Example — fix**
```sql
CREATE PROCEDURE dbo.GetOrderStatus
    @orderId INT,
    @result NVARCHAR(20) OUTPUT
AS
BEGIN
    SET @result = NULL;  -- initialize at top of body
    IF EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderId = @orderId)
        SELECT @result = Status FROM dbo.Orders WHERE OrderId = @orderId;
END
```

**Fix options**
1. Set all `OUTPUT` parameters to a default at the top of the procedure body: `SET @outParam = NULL` or `SET @outParam = 0`.
2. Ensure every code path (including CATCH blocks) assigns a value.
3. Note: declaring a default in the signature (`@outParam INT = 0 OUTPUT`) does not satisfy this — the default applies to callers who omit the parameter, not to uninitialized paths within the body.

**Related checks:** T13 (ISNULL/COALESCE in WHERE), T19 (missing TRY/CATCH)

---

### T65 — Dangerous OLE Automation and Registry Extended Procedures

**What it means**
OLE Automation procedures (`sp_OA*`) execute COM objects from within SQL Server, allowing file I/O, network calls, and arbitrary code execution. Registry procedures (`xp_reg*`) provide direct read/write access to the Windows registry. `xp_servicecontrol` can start and stop Windows services.

**Why it matters**
These are the same attack surface as `xp_cmdshell` (T36). If SQL Server is compromised via SQL injection (T29) and these procedures are enabled, an attacker gains full OS and registry control under the SQL Server service account. They should be disabled at server level and absent from all application T-SQL.

**How to spot it**
```sql
-- Triggers T65
EXEC sp_OACreate 'Scripting.FileSystemObject', @obj OUTPUT;
EXEC sp_OAMethod @obj, 'CreateTextFile', @file OUTPUT, 'C:\output.txt';

EXEC xp_regread 'HKEY_LOCAL_MACHINE', 'SOFTWARE\...', 'Value', @result OUTPUT;
EXEC xp_servicecontrol 'STOP', 'W3SVC';
```

**Fix options**
1. Remove entirely. Replace with SQL Server Agent jobs (scheduled tasks), SSIS packages (file I/O, ETL), PowerShell scripts executed via Agent, or application-layer code.
2. Verify disabled server-wide: `EXEC sp_configure 'Ole Automation Procedures'` — should return `run_value = 0`.
3. If required in a DBA-only maintenance script, scope to a privileged admin-only procedure, document the justification, and ensure the feature is disabled immediately after use.

**Related checks:** T36 (xp_cmdshell), T29 (SQL injection), T33 (hardcoded credentials)

---

### T66 — QUOTENAME Misapplied to Values Instead of Identifiers

**What it means**
`QUOTENAME(string)` wraps its argument in square brackets: `QUOTENAME('Orders')` → `[Orders]`. It is designed to prevent identifier injection by escaping identifiers. It does not sanitize data values — a value containing `]` followed by SQL can still inject.

**Why it matters**
A common misconception: developers use `QUOTENAME(@userInput)` thinking it "escapes" the input for safe dynamic SQL. A value like `x]; DROP TABLE dbo.Orders; --` wrapped in QUOTENAME becomes `[x]; DROP TABLE dbo.Orders; --]` — the `]` in the value closes the bracket, and the following SQL is still executed.

**How to spot it**
```sql
-- Triggers T66 — QUOTENAME applied to a value, not an identifier
SET @sql = N'SELECT * FROM dbo.Orders WHERE Status = ' + QUOTENAME(@statusFilter);
-- @statusFilter is a STATUS value, not an object name; QUOTENAME does not protect it
```

**Example — fix**
```sql
-- Values must be passed as bound parameters — never via QUOTENAME
SET @sql = N'SELECT * FROM dbo.Orders WHERE Status = @p_status';
EXEC sp_executesql @sql, N'@p_status NVARCHAR(20)', @p_status = @statusFilter;

-- QUOTENAME is correct only for validated identifiers:
IF @tableName NOT IN (SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('dbo'))
    RAISERROR('Invalid table', 16, 1);
SET @sql = N'SELECT * FROM dbo.' + QUOTENAME(@tableName);
```

**Fix options**
1. Pass all value parameters via `sp_executesql @params` binding — never via string concatenation or QUOTENAME.
2. Use `QUOTENAME` only for object-name tokens (table, column, schema names) that have been validated against `sys.tables`/`sys.columns` or an explicit whitelist.

**Related checks:** T29 (dynamic SQL concatenation), T31 (user input in dynamic SQL), T34 (sp_executesql without @params)

---

### T67 — Dynamic SQL Built and Executed Inside WHILE Loop

**What it means**
Dynamic SQL construction and execution inside a loop body means N compilations for N iterations. Each compilation takes time, pollutes the plan cache, and multiplies the injection surface area if the SQL string changes per iteration.

**Why it matters**
A loop processing 1,000 objects that builds and executes a query per iteration generates 1,000 plan compilations and 1,000 cache entries. The set-based alternative generates one.

**How to spot it**
```sql
-- Triggers T67
DECLARE @tableName NVARCHAR(128);
DECLARE cur CURSOR FOR SELECT name FROM sys.tables WHERE is_ms_shipped = 0;
OPEN cur; FETCH NEXT FROM cur INTO @tableName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'UPDATE ' + QUOTENAME(@tableName) + N' SET ModifiedAt = SYSDATETIME()';
    EXEC sp_executesql @sql;  -- one compile per table
    FETCH NEXT FROM cur INTO @tableName;
END
```

**Example — fix**
```sql
-- Build a single batch string outside the loop; execute once
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += N'UPDATE ' + QUOTENAME(name) + N' SET ModifiedAt = SYSDATETIME();' + CHAR(10)
FROM sys.tables WHERE is_ms_shipped = 0;
EXEC sp_executesql @sql;  -- one compile, one execution
```

**Fix options**
1. Move dynamic SQL construction outside the loop, concatenate a batch, execute once.
2. Reformulate as a single set-based statement using a staged temp table or TVP.
3. If per-object DDL is genuinely required, ensure the dynamic string uses only validated whitelist identifiers — never loop-variable content derived from data.

**Related checks:** T29 (dynamic SQL injection), T7 (cursor usage), T77 (O(n²) string concatenation)

---

### T68 — Deprecated Large Object Types (text, ntext, image)

**What it means**
`text`, `ntext`, and `image` are the old SQL Server large object types. They are deprecated since SQL Server 2005 and have been announced for removal in a future version. They carry significant limitations compared to their `(MAX)` successors.

**Why it matters**
`text`/`ntext`/`image` columns cannot be used with: `LIKE`, `REPLACE`, `CHARINDEX`, `LEN`, `SUBSTRING` directly, `DISTINCT`, `ORDER BY` without casting, indexed views, or most modern SQL Server features. Code using these types will break on future SQL Server versions.

**How to spot it**
```sql
-- Triggers T68
DECLARE @doc TEXT;
SET @doc = 'Some long text value';

SELECT DATALENGTH(NoteText) FROM dbo.Notes;  -- NoteText is ntext
UPDATE dbo.Documents SET Content = TEXTPTR(Content);  -- deprecated TEXTPTR
```

**Example — fix**
```sql
-- Modern equivalents
DECLARE @doc NVARCHAR(MAX);
SET @doc = N'Some long text value';

SELECT LEN(NoteText) FROM dbo.Notes;  -- after ALTER COLUMN to NVARCHAR(MAX)
```

**Fix options**
1. `text` → `VARCHAR(MAX)`, `ntext` → `NVARCHAR(MAX)`, `image` → `VARBINARY(MAX)`.
2. Remove `TEXTPTR`, `READTEXT`, `WRITETEXT`, `UPDATETEXT` — use standard `UPDATE`, `SELECT` on the `(MAX)` column.
3. Schema changes to existing tables: `ALTER TABLE dbo.T ALTER COLUMN col NVARCHAR(MAX)`.

**Related checks:** T73 (variable-length type size 1–2), T44 (SET ANSI_NULLS OFF)

---

### T69 — Old System Catalog Table References

**What it means**
`sysobjects`, `syscolumns`, `sysindexes`, and similar names are SQL Server 2000 compatibility views. They expose a subset of metadata and are not updated for features added after SQL Server 2000.

**Why it matters**
These views are absent or reduced in Azure SQL Database, may be removed in future SQL Server versions, and do not include metadata for features like filtered indexes, columnstore indexes, In-Memory OLTP tables, or XML columns. Code using them may silently miss objects.

**How to spot it**
```sql
-- Triggers T69
SELECT name FROM sysobjects WHERE xtype = 'U';         -- user tables
SELECT name FROM syscolumns WHERE id = OBJECT_ID('T'); -- columns
SELECT * FROM sysindexes WHERE id = OBJECT_ID('T');    -- indexes
```

**Example — fix**
```sql
SELECT name FROM sys.tables WHERE is_ms_shipped = 0;
SELECT name, column_id FROM sys.columns WHERE object_id = OBJECT_ID('dbo.T');
SELECT name, type_desc FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.T');
```

**Fix options**
1. `sysobjects` → `sys.objects`, `sys.tables`, `sys.views`, `sys.procedures`
2. `syscolumns` → `sys.columns`
3. `sysindexes` → `sys.indexes` + `sys.index_columns`
4. `sysdatabases` → `sys.databases`
5. `syslogins` → `sys.server_principals`

**Related checks:** T38 (missing schema prefix), T68 (deprecated LOB types)

---

### T70 — STUFF + FOR XML PATH String Aggregation (Pre-2017 Pattern)

**What it means**
`STUFF((SELECT ',' + col FROM T FOR XML PATH('')), 1, 1, '')` is the SQL Server 2005–2016 workaround for string aggregation. It uses XML generation as a side effect to concatenate rows into a single string.

**Why it matters**
The pattern has two failure modes: XML special characters (`<`, `>`, `&`, `"`, `'`) in the data are XML-escaped by `FOR XML`, corrupting the result silently. It is also verbose, hard to maintain, and slower than the native `STRING_AGG` on large rowsets.

**How to spot it**
```sql
-- Triggers T70
SELECT STUFF((
    SELECT ',' + ProductName
    FROM dbo.Products
    FOR XML PATH('')
), 1, 1, '') AS ProductList;
-- If ProductName contains '&', it becomes '&amp;' in the result
```

**Example — fix (SQL Server 2017+)**
```sql
SELECT STRING_AGG(ProductName, ',') WITHIN GROUP (ORDER BY ProductName) AS ProductList
FROM dbo.Products;
```

**Example — fix (pre-2017, entity-safe)**
```sql
SELECT STUFF((
    SELECT ',' + ProductName
    FROM dbo.Products
    FOR XML PATH(''), TYPE
).value('.', 'NVARCHAR(MAX)'), 1, 1, '') AS ProductList;
-- The .value() call decodes XML entities back to their original characters
```

**Fix options**
1. SQL Server 2017+: use `STRING_AGG(col, separator) WITHIN GROUP (ORDER BY ...)`.
2. Pre-2017 with XML special characters: add `TYPE).value('.', 'NVARCHAR(MAX)')` to decode entities.
3. Pre-2017 for purely ASCII data: the plain `FOR XML PATH('')` pattern is acceptable — document it.

**Related checks:** T77 (O(n²) string concatenation in loop), T47 (string functions on large rowsets)

---

### T71 — Locale-Dependent Date String Literal Format

**What it means**
Date string literals like `'01/15/2024'` are interpreted based on the server's `SET DATEFORMAT` and `SET LANGUAGE` settings. On a US-English server `'01/15/2024'` is January 15; on a British-English server it is interpreted as day 1, month 15 and fails.

**Why it matters**
A procedure that works correctly on a developer's workstation (US English) may return wrong dates or throw error 241 ("Conversion failed when converting date and/or time from character string") on a production server with a different language setting. This is a common source of environment-dependent bugs.

**How to spot it**
```sql
-- Triggers T71 — locale-dependent
WHERE OrderDate >= '01/15/2024'
SET @endDate = '31/12/2024'
INSERT INTO dbo.Events (EventDate) VALUES ('January 15, 2024')
```

**Example — fix**
```sql
-- ISO 8601 — language-independent
WHERE OrderDate >= '2024-01-15'
SET @endDate = '2024-12-31'
INSERT INTO dbo.Events (EventDate) VALUES ('2024-01-15')

-- Or the unseparated format (also unambiguous for DATETIME):
WHERE OrderDate >= '20240115'
```

**Fix options**
1. Use `'YYYY-MM-DD'` for DATE and `DATETIME2`; `'YYYYMMDD'` for DATETIME.
2. Use `'YYYY-MM-DDTHH:MM:SS'` (ISO 8601 with T separator) for DATETIME2 with time.
3. For procedure parameters: declare them as DATE, DATETIME2, or DATETIME rather than VARCHAR, pushing the conversion to the client.

**Related checks:** T42 (GETDATE/UTC precision), T61 (BETWEEN datetime boundary)

---

### T72 — Missing SET NOCOUNT ON in Stored Procedure or Trigger

**What it means**
Without `SET NOCOUNT ON`, SQL Server sends a DONE_IN_PROC message to the client after every DML statement, reporting the number of rows affected. For procedures executing DML in loops or batches, this produces a stream of row-count messages.

**Why it matters**
Some ADO and ODBC client libraries misinterpret these DONE_IN_PROC messages as empty result sets, causing "there is already an open DataReader" errors or unexpected result-set handling. For very high-frequency procedures the accumulated network traffic of row-count messages is measurable.

**How to spot it**
```sql
-- Triggers T72 — no SET NOCOUNT ON
CREATE PROCEDURE dbo.ProcessOrders
AS
BEGIN
    UPDATE dbo.Orders SET Status = 'Processing' WHERE Status = 'Queued';
    -- Sends a row-count DONE_IN_PROC message to client after the UPDATE
END
```

**Example — fix**
```sql
CREATE PROCEDURE dbo.ProcessOrders
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Orders SET Status = 'Processing' WHERE Status = 'Queued';
END
```

**Fix options**
1. Add `SET NOCOUNT ON;` as the first statement in every procedure and trigger body.
2. Exception: if the calling application explicitly relies on receiving row counts from the procedure (rare), document it and suppress the check.

**Related checks:** T57 (@@ROWCOUNT), T71 (locale date literal)

---

### T73 — Variable-Length Type of Size 1 or 2

**What it means**
`VARCHAR(1)`, `NVARCHAR(2)`, and similar tiny variable-length declarations carry a 2-byte length prefix overhead in storage. For sizes 1 or 2, the overhead equals or exceeds the data size. `VARCHAR` or `NVARCHAR` with no length specified silently defaults to 1.

**Why it matters**
Fixed-length types (`CHAR`, `NCHAR`, `BINARY`) have no length prefix and use exactly their declared size. For size 1–2 columns this gives a 33–100% storage saving. The no-length-specified default-to-1 is also almost always a developer mistake — the intent is usually `VARCHAR(MAX)` or a specific business-meaningful size.

**How to spot it**
```sql
-- Triggers T73
DECLARE @flag VARCHAR(1);
CREATE TABLE dbo.Codes (TypeCode VARCHAR(2), CategoryFlag NVARCHAR(1));
CREATE PROCEDURE dbo.Proc1 (@indicator VARCHAR) AS ...  -- defaults to VARCHAR(1)!
```

**Example — fix**
```sql
DECLARE @flag CHAR(1);
CREATE TABLE dbo.Codes (TypeCode CHAR(2), CategoryFlag NCHAR(1));
CREATE PROCEDURE dbo.Proc1 (@indicator CHAR(1)) AS ...
```

**Fix options**
1. Replace `VARCHAR(1)`/`VARCHAR(2)` → `CHAR(1)`/`CHAR(2)`.
2. Replace `NVARCHAR(1)`/`NVARCHAR(2)` → `NCHAR(1)`/`NCHAR(2)`.
3. Replace `VARBINARY(1)`/`VARBINARY(2)` → `BINARY(1)`/`BINARY(2)`.
4. For bare `VARCHAR`/`NVARCHAR` with no length: determine the intended maximum and specify it explicitly.

**Related checks:** T68 (deprecated LOB types), T43 (INSERT without column list)

---

### T74 — LEN() or DATALENGTH() as Non-Sargable Filter Predicate

**What it means**
`LEN(col)` and `DATALENGTH(col)` wrap the column in a function call, making the predicate non-sargable — the same root cause as T4. SQL Server cannot seek into an index on `col` when it is wrapped.

**Why it matters**
`WHERE LEN(Email) > 0` is the most common form — checking for a non-empty string. But this forces SQL Server to evaluate `LEN()` for every row before filtering. `WHERE Email <> ''` is identical in semantics and allows an index seek.

**How to spot it**
```sql
-- Triggers T74
WHERE LEN(PhoneNumber) > 0          -- non-empty check (use <> '' instead)
WHERE DATALENGTH(Description) > 0   -- non-empty check on MAX column
WHERE LEN(PostalCode) = 5           -- length filter (use a computed column + index)
```

**Example — fix**
```sql
-- Sargable equivalents
WHERE PhoneNumber <> ''
WHERE Description <> ''           -- works for NVARCHAR(MAX) too
WHERE LEN(PostalCode) = 5         -- if selectivity is high, add computed column:
-- ALTER TABLE dbo.T ADD PostalCodeLen AS LEN(PostalCode) PERSISTED;
-- CREATE INDEX IX_T_PostalCodeLen ON dbo.T (PostalCodeLen);
```

**Fix options**
1. Replace `LEN(col) > 0` with `col <> ''`; `DATALENGTH(col) > 0` with `col <> ''`.
2. For nullable columns: `WHERE col IS NOT NULL AND col <> ''`.
3. For length-specific predicates (`LEN(col) = n`): add a persisted computed column and index.

**Related checks:** T4 (function wrapping column), T13 (ISNULL/COALESCE in WHERE)

---

### T75 — Unbatched Large DML Without TOP Batch Control

**What it means**
A single `DELETE` or `UPDATE` affecting a large number of rows is one atomic transaction. SQL Server holds all acquired locks until commit, the transaction log grows proportionally to rows affected, and lock escalation to a table lock blocks all other queries for the duration.

**Why it matters**
A single `DELETE FROM dbo.AuditLog WHERE LogDate < DATEADD(YEAR, -1, GETDATE())` against a table with 50M old rows: holds a table-level lock for minutes, grows the transaction log by gigabytes, and blocks all reads and writes on the table.

**How to spot it**
```sql
-- Triggers T75 — one transaction for potentially millions of rows
DELETE FROM dbo.AuditLog WHERE LogDate < DATEADD(YEAR, -1, GETDATE());
UPDATE dbo.Orders SET IsArchived = 1 WHERE OrderDate < '2020-01-01';
```

**Example — fix**
```sql
-- Batched: each iteration is a short transaction; locks released between batches
WHILE 1 = 1
BEGIN
    DELETE TOP (5000) FROM dbo.AuditLog WHERE LogDate < DATEADD(YEAR, -1, GETDATE());
    IF @@ROWCOUNT < 5000 BREAK;
    WAITFOR DELAY '00:00:00.050';  -- optional: yield to other workloads
END
```

**Fix options**
1. Wrap in a WHILE loop with `DELETE TOP (n) FROM T WHERE ...`; break when `@@ROWCOUNT < n`.
2. Batch size of 1,000–10,000 rows per iteration is typical; tune based on log growth and blocking tolerance.
3. Consider partitioned tables or archival patterns for recurring large-scale deletes.

**Related checks:** T20 (missing transaction), T73 (unbatched DELETE/UPDATE)

---

### T76 — WITH (NOLOCK) Overuse Across All Tables

**What it means**
`WITH (NOLOCK)` is READ UNCOMMITTED isolation per table — it reads uncommitted rows (dirty reads), can read a row twice during a page split, or skip a row entirely. When applied to three or more tables in the same query (or every table in a procedure), it is usually cargo-cult practice added indiscriminately.

**Why it matters**
NOLOCK does not prevent all locking (it still takes a schema stability lock), yet it trades correctness for an uncertain performance benefit. Queries joining several NOLOCK tables can return logically inconsistent result sets — e.g., an order header with no matching order lines from the same transaction, or financial totals that don't balance.

**How to spot it**
```sql
-- Triggers T76 — NOLOCK on every table in the join
SELECT o.OrderId, c.Name, ol.Qty
FROM dbo.Orders o WITH (NOLOCK)
JOIN dbo.Customers c WITH (NOLOCK) ON c.CustomerId = o.CustomerId
JOIN dbo.OrderLines ol WITH (NOLOCK) ON ol.OrderId = o.OrderId
WHERE o.Status = 'Open';
```

**Fix options**
1. Remove NOLOCK from tables where inconsistent reads would produce incorrect results (financial summaries, joined transactions).
2. Enable `READ_COMMITTED_SNAPSHOT` (RCSI) at the database level: readers no longer block writers and vice versa — no dirty reads.
3. Keep NOLOCK only on tables where approximate/stale reads are explicitly acceptable and documented (e.g., `-- intentional: approximate dashboard count`).

**Related checks:** T20 (missing transaction), T59 (MERGE race condition)

---

### T77 — O(n²) String Concatenation in Loop

**What it means**
Each `SET @result = @result + item` in a loop allocates a new string of total length `LEN(@result) + LEN(item)` and copies both halves. For N iterations producing a final string of length L, total work is proportional to L² — quadratic in the output size.

**Why it matters**
Building a comma-separated list of 10,000 items averaging 20 characters (200 KB final string) via loop concatenation performs roughly 20 billion character copies. The equivalent `STRING_AGG` or `FOR XML PATH` approach performs a single linear pass.

**How to spot it**
```sql
-- Triggers T77
DECLARE @list NVARCHAR(MAX) = N'';
DECLARE cur CURSOR FOR SELECT Name FROM dbo.Products;
OPEN cur; FETCH NEXT FROM cur INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @list = @list + @name + N',';  -- O(n^2) total copies
    FETCH NEXT FROM cur INTO @name;
END
```

**Example — fix**
```sql
-- Single set-based pass — O(n) total work
SELECT @list = STRING_AGG(Name, N',') FROM dbo.Products;

-- Or pre-2017:
SELECT @list = STUFF((SELECT N',' + Name FROM dbo.Products FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'');
```

**Fix options**
1. SQL Server 2017+: use `STRING_AGG(col, separator) WITHIN GROUP (ORDER BY ...)`.
2. Pre-2017: use `STUFF + FOR XML PATH` with the `TYPE` directive to preserve non-ASCII characters (T70).
3. If the loop is required for other processing, collect values into a `@table TABLE (item NVARCHAR(n))` and aggregate at the end.

**Related checks:** T70 (STUFF + FOR XML PATH), T7 (cursor), T47 (string functions on large rowsets)

---

### T78 — Deterministic Function Call on Value Side of WHERE Predicate

**What it means**
A function call in a WHERE clause where the argument is a variable or literal (not a column reference) produces the same result for every row in the query. SQL Server evaluates it once per row instead of pre-computing it once for the whole query.

**Why it matters**
`WHERE col > ABS(@param)` evaluates `ABS(@param)` once per row. `WHERE col > DATEADD(DAY, -@n, GETDATE())` evaluates `DATEADD(...)` once per row. On a 10M-row scan this adds 10M redundant function calls. Pre-computing to a variable eliminates them and gives the optimizer a stable literal to work with, potentially improving plan quality.

**How to spot it**
```sql
-- Triggers T78 — function on the value (parameter) side
WHERE c2 > ABS(@param)                         -- ABS of a parameter
WHERE EventDate > DATEADD(DAY, -@daysBack, GETDATE())  -- constant date expression
WHERE Amount BETWEEN @low AND ROUND(@high, 2)  -- ROUND of a parameter
WHERE LEN(@prefix) > 0 AND Name LIKE @prefix + N'%'    -- LEN of a parameter in predicate
```

**Example — fix**
```sql
DECLARE @threshold INT = ABS(@param);
DECLARE @since DATETIME2 = DATEADD(DAY, -@daysBack, GETDATE());
DECLARE @roundedHigh DECIMAL(18,2) = ROUND(@high, 2);

SELECT * FROM dbo.Events
WHERE c2 > @threshold AND EventDate > @since AND Amount <= @roundedHigh;
```

**Fix options**
1. Assign the result of the deterministic expression to a variable before the query.
2. For complex multi-predicate queries, pre-compute all constant expressions at the top of the procedure.
3. Note: SQL Server sometimes optimizes simple constant expressions automatically. Flag only when the function is non-trivial or appears inside a subquery that runs per outer row.

**Related checks:** T4 (function wrapping column), T60 (DATEDIFF non-sargable), T28 (OPTION RECOMPILE for high-variance)

---

## Quick Reference: Checks by Severity

### Critical (fix before merge)
| Check | Issue |
|-------|-------|
| T2 | Missing WHERE on UPDATE/DELETE |
| T16 | NULL comparison using = NULL |
| T29 | Dynamic SQL string concatenation (injection) |
| T30 | EXEC(@string) without sp_executesql |
| T31 | User input in dynamic SQL |
| T33 | Hardcoded credentials |
| T36 | xp_cmdshell reference |
| T39 | Deprecated outer join syntax |
| T51 | NOT IN with nullable subquery |
| T59 | MERGE without HOLDLOCK (race condition) |
| T65 | OLE Automation / registry extended procedures |
| T66 | QUOTENAME misapplied to values |

### Warning (should fix)
| Check | Issue |
|-------|-------|
| T1 | SELECT * |
| T4 | Non-sargable: function/arithmetic on column |
| T5 | Non-sargable: implicit type coercion |
| T6 | Leading wildcard LIKE |
| T7 | Cursor usage |
| T8 | Scalar UDF |
| T9 | Correlated subquery in SELECT |
| T12 | Function in JOIN ON |
| T13 | ISNULL/COALESCE in WHERE |
| T17 | LEFT JOIN nullified by WHERE |
| T19 | Missing TRY/CATCH |
| T22 | CASE type mismatch |
| T25 | CTE chain > 4 levels |
| T27 | SET ROWCOUNT deprecated |
| T32 | EXECUTE AS without REVERT |
| T34 | sp_executesql without @params |
| T35 | OPENROWSET with connection string |
| T40 | Non-ANSI GROUP BY |
| T43 | INSERT without column list |
| T44 | SET ANSI_NULLS/QUOTED_IDENTIFIER OFF |
| T46 | Table variable for large data |
| T48 | Deeply nested subqueries |
| T49 | Pagination without deterministic sort |
| T50 | Collation/type mismatch |
| T52 | Division by zero without NULLIF guard |
| T53 | TOP without ORDER BY |
| T55 | VARCHAR/NVARCHAR implicit promotion in concat |
| T56 | @@IDENTITY instead of SCOPE_IDENTITY() |
| T57 | @@ROWCOUNT after statement that resets it |
| T58 | Recursive CTE without MAXRECURSION |
| T60 | DATEDIFF as non-sargable date filter |
| T61 | BETWEEN on DATETIME with date-only boundary |
| T63 | ISNUMERIC() for type validation |
| T64 | Output parameter not initialized in all paths |
| T67 | Dynamic SQL executed inside WHILE loop |
| T68 | Deprecated text/ntext/image types |
| T71 | Locale-dependent date string literal |
| T74 | LEN()/DATALENGTH() as filter predicate |
| T75 | Unbatched large DML without TOP batch control |
| T76 | WITH (NOLOCK) overuse across all tables |
| T77 | O(n²) string concatenation in loop |

### Info (investigate and document)
| Check | Issue |
|-------|-------|
| T3 | Missing WHERE on SELECT |
| T10 | CROSS JOIN without comment |
| T11 | OR in JOIN predicate |
| T14 | Missing TOP / FETCH |
| T15 | DISTINCT without aggregation intent |
| T18 | Missing ORDER BY |
| T20 | Multi-statement DML without transaction |
| T21 | UNION instead of UNION ALL |
| T23 | Missing ELSE in CASE |
| T24 | CTE referenced more than once |
| T26 | Scalar aggregate without GROUP BY |
| T28 | Missing OPTION (RECOMPILE) |
| T37 | Linked server query |
| T38 | Missing schema prefix |
| T41 | RAISERROR instead of THROW |
| T42 | GETDATE() where UTC preferred |
| T45 | Temp table without explicit columns |
| T47 | String functions on large rowsets |
| T54 | COUNT(*) > 0 instead of EXISTS |
| T62 | SELECT variable assignment silent retention |
| T69 | Old system catalog table references |
| T70 | STUFF + FOR XML PATH (pre-2017 pattern) |
| T72 | Missing SET NOCOUNT ON |
| T73 | Variable-length type of size 1 or 2 |
| T78 | Deterministic function call on value side of WHERE |
