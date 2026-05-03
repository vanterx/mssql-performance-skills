---
name: tsql-review
description: Analyze raw T-SQL source code for anti-patterns, security risks, and static performance smells. Applies 50 checks (T1–T50) across structural, correctness, security, deprecated syntax, and performance categories. No execution plan required.
triggers:
  - /tsql-review
  - /sql-review
---

# T-SQL Static Review Skill

## Purpose

Analyze T-SQL source code — stored procedures, ad-hoc queries, scripts, migration files — for anti-patterns that are detectable without running the query or capturing an execution plan. Covers 50 checks (T1–T50) across five categories: structural anti-patterns, correctness and logic, security and dynamic SQL, deprecated and non-idiomatic syntax, and performance smells.

This is the "shift-left" complement to `sqlplan-review`. Run it during code review to catch problems before they reach production. Run `sqlplan-review` on the resulting execution plan to catch what only surfaces at runtime.

## Input

Accept any of:
- Raw T-SQL source code (paste inline or provide a file path)
- A `.sql` file path
- A description of the query structure ("a stored proc with a cursor that builds a dynamic WHERE clause")

If the user provides a file path, read the file and analyze its content. If the input is inline SQL, analyze it directly. If the input is a description, apply the checks based on what is described and note which checks could not be verified from the description alone.

## How to Run

Walk T1–T50 in category order. Report every triggered finding — do not stop at the first match. For checks where the SQL construct is absent, note them as passing in the Passed Checks section. For checks where schema or parameter type information is unknown, state your assumption explicitly rather than skipping the check.

---

## Thresholds Reference

| Metric | Value |
|--------|-------|
| CTE chain depth warning | > 4 levels deep |
| Large IN list | > 20 discrete values in an IN() clause |
| Nested subquery depth | ≥ 3 levels of nested scalar subqueries |
| Excessive parameters | > 50 named parameters in a stored procedure |
| Wide index suggestion | > 4 key columns OR > 5 INCLUDE columns |

---

## Structural Anti-Patterns (T1–T15)

Run these checks for patterns that prevent index usage, expand data volumes unnecessarily, or indicate set-based logic replaced by row-by-row processing.

### T1 — SELECT * (No Explicit Column List)
- **Trigger:** `SELECT *` in any SELECT statement (including SELECT INTO, subqueries, CTEs, or views)
- **Severity:** Warning
- **Fix:** Replace `*` with an explicit column list. Eliminates surprise column additions when the schema changes, prevents over-fetching wide rows, and allows the optimizer to consider covering indexes.

### T2 — Missing WHERE on UPDATE or DELETE
- **Trigger:** An `UPDATE` or `DELETE` statement with no `WHERE` clause (including `TRUNCATE`-equivalent patterns using DELETE)
- **Severity:** Critical
- **Fix:** Add a `WHERE` clause or, if a full-table wipe is intended, use `TRUNCATE TABLE` (which is faster and fully logged). If the omission is intentional, add a comment explaining the intent.

### T3 — Missing WHERE on SELECT (Full-Table Read)
- **Trigger:** A `SELECT` or `SELECT INTO` with no `WHERE` clause on a named user table (not a system view or TVF with no filter parameter)
- **Severity:** Info
- **Fix:** Confirm the full-table read is intentional. Add `WHERE 1=1 -- intentional full scan` as documentation if it is. Otherwise add a predicate.

### T4 — Non-Sargable Predicate — Function Wrapping Indexed Column
- **Trigger:** A function call in a `WHERE`, `HAVING`, or `JOIN ON` clause wraps a column reference: `YEAR(col)`, `MONTH(col)`, `DAY(col)`, `CAST(col AS ...)`, `CONVERT(type, col)`, `UPPER(col)`, `LOWER(col)`, `LEFT(col, n)`, `SUBSTRING(col, 1, n)`, `ISNULL(col, default)`, `COALESCE(col, ...)`
- **Severity:** Warning
- **Fix:** Rewrite the predicate so the column is bare and the transformation is applied to the literal or parameter. Example: `WHERE YEAR(OrderDate) = 2024` → `WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'`. This allows an index seek instead of a full scan.

### T5 — Non-Sargable Predicate — Implicit Type Coercion
- **Trigger:** A comparison where the column type and the literal or parameter type differ and SQL Server would insert an implicit `CONVERT` on the column side (e.g., `INT` column compared to an `NVARCHAR` parameter, `VARCHAR` column compared to `NVARCHAR` literal `N'value'`, `DATE` column compared to a `DATETIME` parameter)
- **Severity:** Warning
- **Fix:** Align the parameter or literal type with the column type. Declare parameters with matching types. Use explicit `CAST` on the literal rather than relying on SQL Server to cast the column. Confirm in the execution plan using the `sqlplan-review` skill (check S12/N12 implicit conversion warnings).

### T6 — Leading Wildcard LIKE
- **Trigger:** A `LIKE` predicate whose pattern starts with `%`: `LIKE '%value'` or `LIKE '%value%'`
- **Severity:** Warning
- **Fix:** Leading wildcards prevent index seeks. If full-text search is needed, use SQL Server Full-Text Search (`CONTAINS`, `FREETEXT`) or consider a computed persisted column with a suffix-reversed value. If the pattern is `LIKE '%value%'` with high selectivity, evaluate Full-Text Search or an application-side filter.

### T7 — Explicit Cursor Usage
- **Trigger:** `DECLARE ... CURSOR`, `OPEN`, `FETCH`, `CLOSE`, `DEALLOCATE` pattern
- **Severity:** Warning
- **Fix:** Replace the cursor with a set-based equivalent. Most row-by-row cursor patterns can be rewritten as: a single UPDATE with a JOIN, a recursive CTE (for hierarchical traversal), a window function (for running totals, rankings), or `STRING_AGG` / `FOR XML PATH` (for string concatenation). Cursors that update the current row (`UPDATE ... WHERE CURRENT OF`) can be rewritten as `UPDATE ... FROM ... JOIN`. If a cursor is genuinely unavoidable (DDL iteration, dynamic per-row operations), document why.

### T8 — Scalar UDF in SELECT or WHERE
- **Trigger:** A call to a user-defined scalar function (not a system function) in the `SELECT` list, `WHERE` clause, `JOIN ON`, or `ORDER BY`. Identifiable by a `schema.FunctionName()` or `dbo.fn_*()` pattern.
- **Severity:** Warning
- **Fix:** Scalar UDFs execute once per row and prevent parallelism in SQL Server 2016 and earlier. In SQL Server 2019+, Scalar UDF Inlining may handle simple functions automatically. For complex UDFs: rewrite as an inline table-valued function (iTVF) and use `CROSS APPLY`, or embed the logic directly in the query. Check SQL Server version before recommending inlining as a fix.

### T9 — Correlated Subquery in SELECT List
- **Trigger:** A `SELECT` clause that contains a subquery referencing a column from the outer query: `SELECT col1, (SELECT TOP 1 x FROM T2 WHERE T2.id = outer.id) AS x`
- **Severity:** Warning
- **Fix:** A correlated subquery in the SELECT list executes once per outer row — equivalent to a cursor. Rewrite as a `LEFT JOIN` with aggregation or a window function (`FIRST_VALUE`, `MAX`). Use `OUTER APPLY` with `TOP 1` for per-row lookups when the join would change row count.

### T10 — CROSS JOIN Without Explanatory Comment
- **Trigger:** `CROSS JOIN` keyword (or a comma-separated `FROM` list with no `WHERE` join condition) with no adjacent comment explaining the intent
- **Severity:** Info
- **Fix:** If the CROSS JOIN is intentional (e.g., generating a Cartesian product for calendar rows × product rows), add a comment: `-- intentional: generates all date/product combinations`. If it is accidental (a forgotten JOIN condition), add the condition.

### T11 — OR Condition in JOIN Predicate
- **Trigger:** A `JOIN ... ON` clause that uses `OR` between join conditions: `ON a.id = b.id OR a.alt_id = b.id`
- **Severity:** Info
- **Fix:** OR in a JOIN predicate often prevents nested-loop seeks and forces a hash or merge join scanning both inputs. Rewrite as a `UNION ALL` of two separate joins, one for each condition. This allows independent seek paths.

### T12 — Function on Indexed Column in JOIN ON Clause
- **Trigger:** A function wrapping a column in a `JOIN ... ON` clause: `ON CAST(a.col AS INT) = b.col` or `ON YEAR(a.date) = b.year`
- **Severity:** Warning
- **Fix:** Same as T4 but in join context. Ensure the join column is bare and the function is applied to the other side, or store the pre-computed value as a persisted computed column.

### T13 — ISNULL or COALESCE on Indexed Column in WHERE
- **Trigger:** `ISNULL(col, substitute)` or `COALESCE(col, substitute)` in a `WHERE` clause where the first argument is a column reference
- **Severity:** Warning
- **Fix:** This pattern makes the predicate non-sargable. Rewrite as: `WHERE (col = @param OR (col IS NULL AND @param = substitute))`. This preserves seek ability and handles both cases explicitly.

### T14 — Missing TOP or FETCH NEXT (Unbounded Result Set)
- **Trigger:** A `SELECT` statement that returns rows to a caller or application (not used as a subquery, CTE, or INSERT source) with no `TOP`, `FETCH NEXT`, or explicit pagination
- **Severity:** Info
- **Fix:** If this is a reporting query with intentionally unbounded results, document it. For API-facing or application-facing queries, add `TOP (@n)` or `OFFSET 0 ROWS FETCH NEXT @pageSize ROWS ONLY` with a deterministic `ORDER BY`.

### T15 — DISTINCT Without Aggregation Intent
- **Trigger:** `SELECT DISTINCT` where no aggregation or deduplication is clearly needed — often masking a bad JOIN that inflates row count
- **Severity:** Info
- **Fix:** Investigate why rows are duplicated before adding DISTINCT. A JOIN producing duplicates usually indicates a missing aggregation or a one-to-many relationship that should use EXISTS/IN instead of a direct join. `SELECT DISTINCT` is a symptom, not a fix.

---

## Correctness and Logic (T16–T28)

Checks for logic errors that produce wrong results or unreliable behavior, often silently.

### T16 — NULL Comparison Using = NULL
- **Trigger:** A predicate of the form `col = NULL` or `col <> NULL` or `col != NULL` (instead of `IS NULL` / `IS NOT NULL`)
- **Severity:** Critical
- **Fix:** `= NULL` always evaluates to UNKNOWN in SQL Server (regardless of SET ANSI_NULLS setting in modern compatibility levels). Use `IS NULL` or `IS NOT NULL`. If comparing two nullable columns, use `col1 IS NOT DISTINCT FROM col2` (SQL Server 2022+) or `(col1 = col2 OR (col1 IS NULL AND col2 IS NULL))`.

### T17 — Outer Join Nullified by WHERE Filter on Right-Side Column
- **Trigger:** A `LEFT JOIN` or `RIGHT JOIN` where the `WHERE` clause filters on a non-NULLable column from the outer (optional) side of the join: `LEFT JOIN T2 ON ... WHERE T2.col = @val`
- **Severity:** Warning
- **Fix:** A WHERE filter on the right-side column of a LEFT JOIN eliminates the NULL rows produced by the outer join, effectively converting it to an INNER JOIN — often unintentionally. Move the filter into the JOIN ON condition if outer rows should be preserved: `LEFT JOIN T2 ON T2.id = T1.id AND T2.col = @val`. Use INNER JOIN explicitly if you truly mean to eliminate non-matching rows.

### T18 — Missing ORDER BY in Final SELECT
- **Trigger:** A `SELECT` statement intended for ordered display (returned to a caller, top-level statement, or `SELECT INTO`) with no `ORDER BY`
- **Severity:** Info
- **Fix:** Without `ORDER BY`, SQL Server may return rows in any order — including different orders on different executions depending on available parallelism and I/O patterns. Add an explicit `ORDER BY` on a deterministic key. Exception: queries used as subqueries or CTEs where order is irrelevant.

### T19 — Missing TRY/CATCH Around DML
- **Trigger:** An `INSERT`, `UPDATE`, `DELETE`, or `MERGE` statement in a stored procedure, trigger, or multi-statement batch with no enclosing `BEGIN TRY / BEGIN CATCH` block
- **Severity:** Warning
- **Fix:** Wrap DML in `BEGIN TRY ... END TRY BEGIN CATCH ... END CATCH`. Use `THROW` (SQL Server 2012+) in the CATCH block to re-raise the error. Log the error using `ERROR_NUMBER()`, `ERROR_MESSAGE()`, `ERROR_LINE()` before re-throwing. Without error handling, a failed DML may leave partial state.

### T20 — Multi-Statement DML Without Explicit Transaction
- **Trigger:** Two or more `INSERT`, `UPDATE`, `DELETE`, or `MERGE` statements in the same batch or procedure with no `BEGIN TRANSACTION / COMMIT / ROLLBACK` wrapping them
- **Severity:** Info
- **Fix:** If the statements must succeed or fail atomically, wrap in `BEGIN TRANSACTION ... COMMIT`. Include error handling with `ROLLBACK` in the CATCH block. If the statements are intentionally independent, document it with a comment.

### T21 — UNION Instead of UNION ALL
- **Trigger:** `UNION` keyword (not `UNION ALL`) combining result sets
- **Severity:** Info
- **Fix:** `UNION` sorts both result sets and eliminates duplicates — equivalent to `UNION ALL` plus `SELECT DISTINCT`. This is expensive and usually unnecessary. Use `UNION ALL` unless duplicate elimination is genuinely required. If duplicates are expected and unwanted, investigate the root cause rather than relying on UNION to hide them.

### T22 — CASE Branches With Mismatched Return Types
- **Trigger:** A `CASE` expression whose WHEN branches return values of different data types that require implicit conversion to unify (e.g., one branch returns `INT`, another returns `VARCHAR`)
- **Severity:** Warning
- **Fix:** SQL Server resolves CASE branch type mismatches by promoting to the highest-precedence type. This can cause implicit conversions or data truncation. Use explicit `CAST` or `CONVERT` in each branch to the desired final type.

### T23 — Missing ELSE in CASE Expression
- **Trigger:** A `CASE` expression with no `ELSE` clause
- **Severity:** Info
- **Fix:** Without ELSE, a CASE returns NULL when no WHEN matches. If NULL is the intended behavior for unmatched rows, document it with an explicit `ELSE NULL`. If a default value is needed, add `ELSE default_value`. This makes the behavior explicit and prevents accidental NULLs.

### T24 — CTE Referenced More Than Once
- **Trigger:** A Common Table Expression (CTE) whose name appears in more than one FROM clause or subquery within the same statement
- **Severity:** Info
- **Fix:** SQL Server does not materialize CTEs — each reference to the CTE re-executes its definition. A CTE referenced N times runs N times. For expensive or large CTEs: use a `#temp` table to force materialization, or a table variable for small result sets. In SQL Server 2019+ with `OPTION (USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE'))`, materialization behavior can vary.

### T25 — CTE Chain Depth Exceeds 4 Levels
- **Trigger:** A `WITH` clause containing more than 4 CTEs, or CTEs that reference other CTEs forming a chain deeper than 4 levels
- **Severity:** Warning
- **Fix:** Deep CTE chains increase optimizer complexity and compile time. They also reduce readability. Refactor into: temp tables (materialized at each step), views, or a shorter set of better-named CTEs. If the depth reflects genuine business logic complexity, add inline comments explaining each step.

### T26 — Scalar Aggregate Without Explicit GROUP BY
- **Trigger:** An aggregate function (`COUNT`, `SUM`, `MAX`, `MIN`, `AVG`) in a `SELECT` list with no `GROUP BY` clause, where non-aggregate columns are also present in the SELECT — which SQL Server would reject — or where the intent of a scalar aggregate across all rows may be unintentional
- **Severity:** Info
- **Fix:** If a scalar aggregate across all rows is intended (e.g., `SELECT COUNT(*) FROM Orders`), document it. If non-aggregate columns appear alongside aggregates without GROUP BY, this is a syntax error in standard SQL — ensure SQL Server compatibility level enforces it.

### T27 — SET ROWCOUNT Usage
- **Trigger:** `SET ROWCOUNT n` statement
- **Severity:** Warning
- **Fix:** `SET ROWCOUNT` is deprecated in all versions of SQL Server. For `SELECT`, use `TOP (@n)`. For `UPDATE` / `DELETE`, use `TOP (@n)` directly in the DML statement: `DELETE TOP (1000) FROM ...`. `SET ROWCOUNT 0` to disable is also unnecessary when using TOP.

### T28 — Missing OPTION (RECOMPILE) on High-Variance Dynamic Filter Query
- **Trigger:** A stored procedure or parameterized query that builds different effective predicates per call (e.g., optional filters using `@param IS NULL OR col = @param` patterns, or wide OR chains of nullable parameters)
- **Severity:** Info
- **Fix:** When a query's optimal plan varies significantly based on parameter values — especially with nullable "catch-all" parameters — add `OPTION (RECOMPILE)` to force per-execution plan compilation. Trade-off: recompile cost (~milliseconds) vs the cost of a bad cached plan. Evaluate with `sqlplan-review` to confirm plan sniffing symptoms (S9, N21).

---

## Security and Dynamic SQL (T29–T38)

Checks for SQL injection risk, privilege escalation, and dangerous server-level access.

### T29 — Dynamic SQL Built by String Concatenation
- **Trigger:** A string variable built by concatenating user-facing input (parameters, column values, or variables populated from external sources) using `+` operator, then passed to `EXEC` or `sp_executesql`: `SET @sql = 'SELECT * FROM ' + @tableName`
- **Severity:** Critical
- **Fix:** Parameterize the dynamic SQL. Values should be passed as parameters to `sp_executesql`, not concatenated. Object names (tables, columns) cannot be parameterized — validate them against `sys.tables`, `sys.columns`, or a whitelist before concatenation: `IF @tableName NOT IN ('AllowedTable1', 'AllowedTable2') RAISERROR('Invalid table', 16, 1)`. Never concatenate unvalidated strings into SQL.

### T30 — EXEC(@string) Without sp_executesql
- **Trigger:** `EXEC(@variable)` or `EXECUTE(@variable)` where `@variable` is a string — as opposed to `EXEC sp_executesql @variable, @params, @values`
- **Severity:** Critical
- **Fix:** `EXEC(@string)` cannot be parameterized. Switch to `sp_executesql` with a `@params` definition and `@values` binding. This eliminates injection risk for value-level substitutions. For object names, see T29.

### T31 — User-Controlled Input Baked Into Dynamic String
- **Trigger:** A procedure parameter (especially one typed `VARCHAR(MAX)` or `NVARCHAR(MAX)`, or named with terms like `@filter`, `@where`, `@condition`, `@sort`, `@orderby`, `@column`) used directly in string concatenation for dynamic SQL
- **Severity:** Critical
- **Fix:** If the parameter represents a value, pass it as a bound parameter to `sp_executesql`. If it represents an object name or clause fragment (ORDER BY column name, etc.), validate against an explicit whitelist or sys catalog before use. Never allow raw external strings to flow into a SQL statement.

### T32 — EXECUTE AS Without REVERT
- **Trigger:** `EXECUTE AS USER = '...'` or `EXECUTE AS LOGIN = '...'` without a corresponding `REVERT` in all exit paths (including CATCH blocks)
- **Severity:** Warning
- **Fix:** Always pair `EXECUTE AS` with `REVERT` in a `BEGIN TRY / BEGIN CATCH` structure. Failure to REVERT leaves the impersonated security context in place for the remainder of the session, potentially allowing privilege escalation.

### T33 — Hardcoded Credentials or Sensitive Literals
- **Trigger:** String literals that match patterns for passwords, connection strings, or API keys: `'password='`, `'pwd='`, `'Pass='`, `'secret='`, `'apikey='`, `'token='`, or Base64-encoded blobs longer than 64 characters used in string operations
- **Severity:** Critical
- **Fix:** Remove credentials from T-SQL source. Use Windows Authentication, Always Encrypted, or credential objects (`CREATE CREDENTIAL`). Store connection strings in application configuration, not in SQL code. Rotate any exposed credentials immediately.

### T34 — sp_executesql Called Without @params Argument
- **Trigger:** `sp_executesql @sql` called with only the `@stmt` argument and no `@params` / `@values` arguments
- **Severity:** Warning
- **Fix:** Calling `sp_executesql` without binding parameters means any values in the query are still concatenated, not parameterized. Add the `@params = N'@param1 TYPE, ...'` and the corresponding values. If no parameters are needed (fully static SQL), document why.

### T35 — OPENROWSET or OPENQUERY With Hardcoded Connection String
- **Trigger:** `OPENROWSET('provider', 'connection_string', ...)` or `OPENQUERY(linked_server, ...)` where the connection string contains credentials or server names that may be environment-specific
- **Severity:** Warning
- **Fix:** Connection strings in OPENROWSET hard-code credentials or infrastructure references into query text. Use a Linked Server object defined at the server level, or move the data access to application code where connection strings are managed via configuration.

### T36 — xp_cmdshell Reference
- **Trigger:** `xp_cmdshell` keyword anywhere in the batch
- **Severity:** Critical
- **Fix:** `xp_cmdshell` executes operating system commands from T-SQL with the SQL Server service account's privileges. This is a critical attack surface. Replace with: SQL Server Agent jobs (for scheduled OS tasks), SSIS packages (for ETL), CLR stored procedures (for file I/O with controlled permissions), or application-layer code. If `xp_cmdshell` is used in a migration or DBA script, document the specific justification and ensure `xp_cmdshell` is disabled at server level (`sp_configure 'xp_cmdshell', 0`) when not in use.

### T37 — Linked Server Query
- **Trigger:** Four-part object name: `server.database.schema.table` or `OPENQUERY(linked_server, ...)` in a DML or SELECT statement
- **Severity:** Info
- **Fix:** Linked server queries run across the network and bypass local query optimization. Ensure the linked server is needed (vs. replicating the data locally), that it uses a dedicated low-privilege login, and that the query is selective enough to minimize data transfer. Flag for security review of linked server credentials.

### T38 — Missing Schema Prefix on Object Name
- **Trigger:** A table, view, function, or procedure reference without a schema prefix: `FROM Orders` instead of `FROM dbo.Orders`, or `EXEC GetOrder` instead of `EXEC dbo.GetOrder`
- **Severity:** Info
- **Fix:** Unqualified names are resolved by SQL Server using the calling user's default schema first, then dbo. This causes plan cache pollution (different users → different plans for the same object), and can silently execute the wrong object if schema-shadowing occurs. Always use two-part names: `schema.ObjectName`.

---

## Deprecated and Non-Idiomatic Syntax (T39–T45)

Checks for syntax that is removed, deprecated, or diverges from SQL Server best practice.

### T39 — Deprecated Outer Join Syntax
- **Trigger:** `*=` or `=*` join operators in a `WHERE` clause (old Sybase-style outer join syntax)
- **Severity:** Critical
- **Fix:** This syntax was removed in SQL Server 2008 R2 and is invalid at compatibility level 90 (SQL Server 2005) and above. Rewrite using ANSI `LEFT JOIN` or `RIGHT JOIN` syntax. Example: `WHERE a.id *= b.id` → `FROM a LEFT JOIN b ON a.id = b.id`.

### T40 — Non-ANSI GROUP BY Behavior
- **Trigger:** A `SELECT` statement with a `GROUP BY` clause where columns in the SELECT list are neither in the GROUP BY nor wrapped in an aggregate function, and the query is running at a compatibility level that permits this (SQL Server 2000 compatibility / `GROUP BY ALL`)
- **Severity:** Warning
- **Fix:** Remove `GROUP BY ALL` and include all non-aggregated columns in the GROUP BY clause. `GROUP BY ALL` is deprecated and produces undefined behavior for non-participating groups (it includes them with NULL aggregate values). Rewrite to use ANSI-compliant GROUP BY or replace with a window function.

### T41 — RAISERROR Instead of THROW
- **Trigger:** `RAISERROR` statement
- **Severity:** Info
- **Fix:** `RAISERROR` is not deprecated but `THROW` (SQL Server 2012+) is the modern replacement. `THROW` re-raises the original error number and severity, works more intuitively with `BEGIN CATCH`, and does not require format string syntax. Replace `RAISERROR('msg', 16, 1)` with `THROW 50001, N'msg', 1` for new code. In CATCH blocks, use bare `THROW;` to re-raise the caught error with its original metadata.

### T42 — GETDATE() Where SYSDATETIME() Preferred
- **Trigger:** `GETDATE()` function call in a context where higher precision or UTC time is appropriate
- **Severity:** Info
- **Fix:** `GETDATE()` returns `DATETIME` (3.33ms precision, local server time). Prefer `SYSDATETIME()` for `DATETIME2(7)` precision, or `SYSUTCDATETIME()` for UTC time. For audit timestamps, always use UTC. For compatibility with legacy `DATETIME` columns, `GETDATE()` remains acceptable — flag only when a new timestamp column is being designed.

### T43 — INSERT Without Column List
- **Trigger:** `INSERT INTO table VALUES (...)` with no explicit column list
- **Severity:** Warning
- **Fix:** `INSERT ... VALUES` without a column list assumes values match the physical column order. A schema change (adding, removing, or reordering a column) silently breaks the INSERT or inserts values into the wrong columns. Always use `INSERT INTO table (col1, col2, ...) VALUES (...)`.

### T44 — SET ANSI_NULLS OFF or SET QUOTED_IDENTIFIER OFF
- **Trigger:** `SET ANSI_NULLS OFF` or `SET QUOTED_IDENTIFIER OFF` statement
- **Severity:** Warning
- **Fix:** Both settings are deprecated in modern compatibility levels. `SET ANSI_NULLS OFF` changes `= NULL` comparison semantics (T16). `SET QUOTED_IDENTIFIER OFF` changes double-quote string literal semantics. Both are required to be ON for: indexed views, computed columns with indexes, filtered indexes, and natively compiled objects. Remove these SET statements and fix any code that depended on them.

### T45 — Temporary Table Created Without Explicit Column Definition
- **Trigger:** `SELECT ... INTO #tempTable FROM ...` (implicit column definition) rather than `CREATE TABLE #tempTable (col1 TYPE, ...)` followed by `INSERT INTO`
- **Severity:** Info
- **Fix:** `SELECT INTO` infers column names and types from the source expression. This is fragile: a source column rename or type change silently changes the temp table schema. For temp tables that are accessed more than once or share structure with permanent tables, prefer an explicit `CREATE TABLE #name (...)` with defined types. `SELECT INTO` is acceptable for quick ad-hoc materializtion.

---

## Performance Smells (T46–T50)

Checks for patterns that are likely to degrade performance at scale, even when syntactically correct.

### T46 — Table Variable Used for Potentially Large Data
- **Trigger:** `DECLARE @table TABLE (...)` used in contexts suggesting large row counts: populated from a join across large tables, used as a parameter accumulator in a loop, referenced in a query without cardinality hints, or when the surrounding code suggests > 1,000 rows
- **Severity:** Warning
- **Fix:** Table variables have no statistics — the optimizer always estimates 1 row regardless of actual content. This causes bad join plans for large table variables. Use a `#temp` table instead: it has statistics (auto-updated after the INSERT), supports indexes, and can participate in parallel plans. Exception: table variables are appropriate for small lookup sets (< 100 rows) or when the variable is passed to a stored procedure as a TVP.

### T47 — String Functions on Potentially Large Rowsets
- **Trigger:** `STRING_SPLIT`, `CHARINDEX`, `SUBSTRING`, `PATINDEX`, `REPLACE`, or `STUFF` called in a `FROM` clause, `WHERE` clause, or `SELECT` list against a large table (inferred from table names or surrounding joins)
- **Severity:** Info
- **Fix:** String functions are CPU-intensive per row. For `STRING_SPLIT` as a JOIN source, ensure the split list is small. For `CHARINDEX`/`PATINDEX` in WHERE clauses, consider adding a computed persisted column with an index. For aggregation using `STRING_AGG` or `FOR XML PATH`, ensure the input rowset is pre-filtered.

### T48 — Deeply Nested Scalar Subqueries
- **Trigger:** A scalar subquery nested 3 or more levels deep: a subquery inside a subquery inside a subquery
- **Severity:** Warning
- **Fix:** Deep subquery nesting compounds execution cost — each level may execute once per row of its parent. Refactor using: CTEs to name each subquery level, window functions to replace per-row lookups, or a series of temp tables to materialize intermediate results. Deep nesting also reduces readability and increases maintenance risk.

### T49 — Pagination Without Deterministic Sort Key
- **Trigger:** `OFFSET n ROWS FETCH NEXT m ROWS ONLY` or `ROW_NUMBER() OVER (ORDER BY ...)` pagination where the `ORDER BY` does not include a unique key column (e.g., primary key or unique column)
- **Severity:** Warning
- **Fix:** Without a unique sort key, the ordering of rows with equal sort values is non-deterministic. A user paging through results may see the same row on two pages or skip rows entirely when the underlying data changes between pages. Always include a unique column (e.g., `ORDER BY CreatedDate DESC, OrderId ASC`) as a tiebreaker.

### T50 — Implicit Collation or Type Conversion in Comparison
- **Trigger:** A comparison or JOIN between columns with different collations (e.g., `Latin1_General_CI_AS` vs `SQL_Latin1_General_CP1_CI_AS`) or between string columns of different types (`VARCHAR` vs `NVARCHAR`) without explicit COLLATE or CAST
- **Severity:** Warning
- **Fix:** Collation mismatches prevent index usage and can cause errors at runtime if collation compatibility is not met. Resolve by: aligning column collations (ALTER TABLE ALTER COLUMN), adding an explicit `COLLATE` clause in the query, or casting both sides to the same type. Confirm no index seeks are blocked using `sqlplan-review` (check T5 / N12).

---

## Output Format

Structure your report as follows:

```
## T-SQL Review

### Summary
- X Critical issues, Y Warnings, Z Info items
- Highest-risk: [T<N>] [Issue Name]

### Critical Issues
**[C1] Issue Name** (T<N>)
- Observed: [exact code fragment from the source]
- Impact: [why this matters — data loss, security risk, performance cost]
- Fix: [concrete rewrite or action]

### Warnings
[same format as Critical Issues]

### Info
[same format as Critical Issues]

### Suggestions
[Non-check recommendations: schema ownership conventions, consider a specific query hint, refactor opportunity not covered by a check]

### Passed Checks
T1 ✓, T6 ✓, T16 ✓, T29 ✓ [explicitly list check IDs verified clean — signals confidence in analysis]
```

---

## Notes

- Do not invent warnings not triggered by the rules above. If nothing fires, say the code is clean.
- If the user provides a stored procedure with parameters, evaluate parameter types against their usage (T5, T50).
- If actual table schema (column types, indexes, collations) is unknown, state your assumptions explicitly rather than skipping schema-dependent checks (T5, T12, T46, T50).
- Do not flag patterns that are clearly benign by documented intent — e.g., a CROSS JOIN with an explanatory comment, or `GETDATE()` on a legacy `DATETIME` column (T42).
- When the code is a migration script or one-time DBA script, adjust severity for operational patterns (e.g., a deliberate `DELETE` without WHERE on a staging table) — note the context.
- For T29–T38 (security), always flag regardless of assumed context. Security checks are never suppressed by "this is internal code" reasoning.

## Companion Skills

- **sqlplan-review** — Analyze the execution plan of this same query at runtime to catch what only surfaces when SQL Server compiles and executes it (memory grants, spills, bad row estimates, join choices).
- **sqlplan-index-advisor** — Derive CREATE INDEX recommendations from the execution plan once `sqlplan-review` has identified scan or lookup patterns.
- **sqlplan-compare** — Diff two execution plans (baseline vs regression) if a query that passed `tsql-review` is still slow in production.
- **sqlplan-deadlock** — Analyze deadlock XML if the query participates in a locking conflict at runtime.
- **sqlplan-batch** — Batch-analyze a folder of `.sqlplan` files produced from queries that were first reviewed with `tsql-review`.
- **query-store-review** — Analyze Query Store data to find regressed queries, plan instability, and the top resource consumers across the whole workload. Use after running a workload capture to prioritize which queries to tune with /sqlplan-review.
