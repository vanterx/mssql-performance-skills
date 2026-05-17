/*
================================================================================
  skills/sqlstats-review/scripts/01_capture_statistics.sql
  STATISTICS IO / TIME Capture Template for /sqlstats-review
================================================================================
  Replace the placeholder SELECT statement with the query you want to analyze.
  Run the script, then copy the Messages tab output from SSMS and paste it
  into Claude. Run: /sqlstats-review

  The Messages tab output will look like:
    Table 'Orders'. Scan count 1, logical reads 42, physical reads 0, ...
    SQL Server Execution Times: CPU time = 15 ms, elapsed time = 18 ms.

  Tips:
    - Run the query twice: first execution primes the plan cache and I/O cache.
      The second execution shows steady-state reads.
    - If you want to test cold cache (physical reads), run:
        DBCC DROPCLEANBUFFERS;  -- only on non-production!
    - Include all JOIN'd tables' stats — the output shows each table separately.
================================================================================
*/

SET STATISTICS IO  ON;
SET STATISTICS TIME ON;
GO

/* ── Replace this block with your query ──────────────────────────────────── */

SELECT TOP 100
    o.OrderId,
    o.CustomerId,
    o.CreatedDate,
    o.TotalAmount,
    c.Email,
    c.Name
FROM dbo.Orders o
JOIN dbo.Customers c ON c.CustomerId = o.CustomerId
WHERE o.CreatedDate >= '2025-01-01'
ORDER BY o.CreatedDate DESC;

/* ─────────────────────────────────────────────────────────────────────────── */

SET STATISTICS IO  OFF;
SET STATISTICS TIME OFF;
GO

/*
  After running, switch to the Messages tab in SSMS.
  You will see output like this — copy and paste it into /sqlstats-review:

  SQL Server parse and compile time:
     CPU time = 0 ms, elapsed time = 1 ms.

  Table 'Customers'. Scan count 0, logical reads 3, physical reads 0,
      page server reads 0, read-ahead reads 0, page server read-ahead reads 0,
      lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.
  Table 'Orders'. Scan count 1, logical reads 842, physical reads 0,
      page server reads 0, read-ahead reads 842, page server read-ahead reads 0,
      lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.

  SQL Server Execution Times:
     CPU time = 47 ms,  elapsed time = 52 ms.
*/
