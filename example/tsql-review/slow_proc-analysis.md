# T-SQL Review — `slow_proc.sql`

> **Input:** `example/tsql-review/slow_proc.sql`
> Run with: `/tsql-review example/tsql-review/slow_proc.sql`

## Summary
- **5 Critical** issues, **8 Warnings**, **4 Info** items
- Highest-risk: [C1] Dynamic SQL String Concatenation — SQL injection (T29/T31)

---

## Critical Issues

**[C1] Dynamic SQL Built by String Concatenation** (T29)
- Observed: `SET @sql = @sql + N' AND Status = ''' + @status + N''''` — the parameters `@status`, `@startDate`, and `@email` are concatenated directly into the SQL string before execution
- Impact: SQL injection — a caller passing `@status = N"'; DROP TABLE dbo.Orders; --"` executes arbitrary SQL with the procedure's permissions. This is the most critical vulnerability in the codebase.
- Fix: Parameterize via `sp_executesql`: `EXEC sp_executesql @sql, N'@p_status NVARCHAR(50), @p_startDate DATE', @p_status = @status, @p_startDate = @startDate`

**[C2] EXEC(@string) Without sp_executesql** (T30)
- Observed: `EXEC(@sql)` — executes the concatenated string without parameter binding
- Impact: Every distinct parameter combination generates a unique plan cache entry (cache pollution). Cannot use parameterization even if the string is safe.
- Fix: Replace with `EXEC sp_executesql @sql, @params, @values`

**[C3] User-Controlled Input in Dynamic SQL** (T31)
- Observed: `@sortColumn NVARCHAR(50)` concatenated directly into `ORDER BY ' + @sortColumn` — an identifier (column name) cannot be bound as a parameter
- Impact: `@sortColumn = N'1; DROP TABLE dbo.Orders--'` is valid SQL when placed after ORDER BY
- Fix: Validate against an explicit whitelist before concatenation: `IF @sortColumn NOT IN ('OrderDate','CustomerId','Total') RAISERROR('Invalid sort column',16,1)`. Wrap with `QUOTENAME()` after validation.

**[C4] NULL Comparison Using = NULL** (T16)
- Observed: `WHERE DeletedAt = NULL` — this predicate always returns zero rows regardless of data because `= NULL` evaluates to UNKNOWN
- Impact: Silent data bug — the query intended to find undeleted records returns nothing, with no error message. All active customers are silently excluded.
- Fix: `WHERE DeletedAt IS NULL`

**[C5] Missing TRY/CATCH Around DML** (T19)
- Observed: `UPDATE dbo.Orders SET ProcessedAt = GETDATE() WHERE OrderId = @orderId` and `EXEC dbo.ProcessOrder @orderId` inside the cursor loop with no error handling
- Impact: A constraint violation, deadlock, or error in `dbo.ProcessOrder` aborts the current iteration; the cursor continues, leaving a partial update applied to some orders but not others — with no notification.
- Fix: Wrap the cursor loop body in `BEGIN TRY / END TRY BEGIN CATCH THROW; END CATCH`

---

## Warnings

**[W1] Explicit Cursor Usage** (T7)
- Observed: `DECLARE order_cur CURSOR FOR SELECT OrderId FROM dbo.Orders WHERE Status = 'Pending'` — processes each Pending order one row at a time
- Impact: Row-by-row processing. With 10,000 pending orders, this issues 10,000 individual UPDATE + EXEC round-trips. A set-based rewrite completes in one statement.
- Fix: `UPDATE dbo.Orders SET ProcessedAt = GETDATE() WHERE Status = 'Pending'` — if per-row processing in `dbo.ProcessOrder` is unavoidable, replace cursor with a `WHILE TOP(1)` batch pattern

**[W2] Non-Sargable Predicate — Function on Indexed Column** (T4)
- Observed: `WHERE YEAR(OrderDate) = 2024` — `YEAR()` wraps the `OrderDate` column, making the predicate non-sargable
- Impact: Forces a full index scan instead of a range seek. On a 5M-row Orders table this is the difference between 1 ms and 30 seconds.
- Fix: `WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'`

**[W3] Non-Sargable Predicate — Implicit Type Coercion** (T5)
- Observed: `@startDate NVARCHAR(20)` compared against `OrderDate` (a DATE column). SQL Server applies `CONVERT_IMPLICIT` to the column side, making the predicate non-sargable.
- Impact: Same as T4 — full scan on every call despite an index on OrderDate
- Fix: Declare `@startDate DATE` to match the column type. Explicit parameter typing eliminates the conversion.

**[W4] Leading Wildcard LIKE** (T6)
- Observed: `LIKE ''%' + @email + '%''` — leading `%` prevents any B-tree index seek on the Email column
- Impact: Full table scan on every email search. On a 1M-row Customers table this is O(n) for each call.
- Fix: For domain-based filtering, add a computed persisted column: `EmailDomain AS REVERSE(LEFT(REVERSE(Email), CHARINDEX('@', REVERSE(Email))-1)) PERSISTED` with an index. Query `WHERE EmailDomain = 'gmail.com'`.

**[W5] SELECT * — No Explicit Column List** (T1)
- Observed: Three occurrences: `SELECT *` in dynamic SQL on Orders, static `SELECT *` on Orders, and `SELECT * FROM Customers` — all without explicit column lists
- Impact: Fetches all columns including wide ones; breaks callers silently when schema changes; prevents covering index optimizations
- Fix: Replace with explicit column lists matching what callers actually consume

**[W6] Missing Schema Prefix on Object Names** (T38)
- Observed: `FROM Customers`, `FROM Orders` (both static queries lack schema prefix)
- Impact: Causes plan cache pollution (different default schemas = different plans for same object); may silently resolve to the wrong object
- Fix: `FROM dbo.Customers`, `FROM dbo.Orders`

**[W7] INSERT Without Column List** (T43)
- Observed: `INSERT INTO AuditLog VALUES (@orderId, GETDATE(), 'processed')` — no column list specified
- Impact: A schema change (column added, removed, or reordered) silently inserts values into wrong columns or raises a runtime error
- Fix: `INSERT INTO dbo.AuditLog (OrderId, EventTime, EventType) VALUES (@orderId, GETDATE(), 'processed')`

**[W8] Multi-Statement DML Without Explicit Transaction** (T20)
- Observed: `UPDATE dbo.Orders` followed by `EXEC dbo.ProcessOrder` inside the cursor with no `BEGIN TRANSACTION`
- Impact: If `dbo.ProcessOrder` fails after the UPDATE commits, the order is marked `ProcessedAt` but not actually processed — partial state with no rollback
- Fix: Wrap both statements in `BEGIN TRANSACTION / COMMIT` with `ROLLBACK` in the CATCH block

---

## Info

**[I1] GETDATE() Where UTC Preferred** (T42)
- Observed: `ProcessedAt = GETDATE()` and `INSERT INTO AuditLog VALUES (..., GETDATE(), ...)` — local server time stored in audit columns
- Fix: Use `SYSUTCDATETIME()` for audit timestamps to avoid timezone ambiguity across datacenter boundaries

**[I2] Missing OPTION (RECOMPILE) on Catch-All Parameter Query** (T28)
- Observed: The dynamic SQL handles optional `@status`, `@startDate`, `@email` parameters — a classic catch-all pattern that generates different effective predicates per call. Without RECOMPILE, the plan cached for one combination is reused for all others.
- Fix: Add `OPTION (RECOMPILE)` at the end of `@sql` before executing — trade-off: ~2 ms compile cost per call vs potentially catastrophic plan reuse

**[I3] Missing TOP on Unbounded SELECT** (T14)
- Observed: `SELECT * FROM dbo.Customers` — no WHERE, no TOP; returns all customers to the caller
- Fix: If full-table read is intentional (e.g., ETL), document with a comment. Otherwise add `WHERE` or `TOP (@n)`.

**[I4] Missing ELSE in Dynamic Sort Column Validation** (T23)
- Observed: After adding the whitelist validation recommended in C3, ensure the ELSE branch raises an error: `ELSE RAISERROR('Invalid sort column: %s', 16, 1, @sortColumn)`. Without an ELSE, an unmatched column silently falls through.

---

### Passed Checks
T2 ✓ (no UPDATE/DELETE without WHERE in static queries), T8 ✓ (no scalar UDF in SELECT/WHERE), T9 ✓ (no correlated subquery in SELECT list), T10 ✓ (no unexplained CROSS JOIN), T11 ✓ (no OR in JOIN predicate), T15 ✓ (no DISTINCT masking bad join), T17 ✓ (no LEFT JOIN nullified by WHERE), T21 ✓ (no UNION vs UNION ALL issue), T22 ✓ (no CASE type mismatch), T25 ✓ (no deep CTE chain), T27 ✓ (no SET ROWCOUNT), T33 ✓ (no hardcoded credentials), T36 ✓ (no xp_cmdshell), T39 ✓ (no deprecated outer join syntax), T44 ✓ (no SET ANSI_NULLS OFF), T46 ✓ (no table variable for large data), T49 ✓ (no non-deterministic pagination)
