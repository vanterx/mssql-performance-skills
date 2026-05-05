/*
================================================================================
  sql/deadlock/01_read_system_health_deadlocks.sql
  Deadlock Graph Capture for /sqlplan-deadlock
================================================================================
  The system_health Extended Events session captures deadlock graphs
  automatically on every SQL Server instance (2008+). No setup required.

  Run Query A to retrieve recent deadlock graphs, then either:
    a) Paste the XML directly into Claude and run /sqlplan-deadlock
    b) Save as .xdl file and open in SSMS to view the visual graph

  Queries:
    A — Recent deadlocks from system_health ring buffer (last 24 hours)
    B — Deadlock count by hour (to identify frequency patterns)
    C — Read from file target if ring buffer was overwritten (requires
        configuring system_health to write to file — see notes)
================================================================================
*/

/* ============================================================================
   QUERY A — Read Deadlock XML from system_health Ring Buffer
   Run this, then paste the XML column value into /sqlplan-deadlock
   ============================================================================ */

SELECT
    deadlock_time  = xdr.value('@timestamp', 'datetime2(3)'),
    deadlock_xml   = CAST(xdr.query('.') AS xml)   /* paste this XML into /sqlplan-deadlock */
FROM (
    SELECT CAST(target_data AS xml) AS target_data
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t
      ON s.address = t.event_session_address
    WHERE s.name        = 'system_health'
      AND t.target_name = 'ring_buffer'
) AS raw_data
CROSS APPLY
    target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS events(xdr)
WHERE xdr.value('@timestamp', 'datetime2(3)') >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY deadlock_time DESC;

/* Tip: if multiple deadlocks appear, analyze the most recent one first.
   To filter to a specific deadlock, add:
     AND xdr.value('@timestamp', 'datetime2(3)') > '2025-05-04 10:00:00' */

/* ============================================================================
   QUERY B — Deadlock Frequency Summary
   Tells you how often deadlocks occur and when they peak
   ============================================================================ */

SELECT
    deadlock_hour  = DATEADD(HOUR, DATEDIFF(HOUR, 0, xdr.value('@timestamp', 'datetime2(3)')), 0),
    deadlock_count = COUNT(*)
FROM (
    SELECT CAST(target_data AS xml) AS target_data
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t
      ON s.address = t.event_session_address
    WHERE s.name        = 'system_health'
      AND t.target_name = 'ring_buffer'
) AS raw_data
CROSS APPLY
    target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS events(xdr)
GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, xdr.value('@timestamp', 'datetime2(3)')), 0)
ORDER BY deadlock_hour DESC;

/* ============================================================================
   QUERY C — Read from system_health File Target
   Use this if the ring buffer has been overwritten (high deadlock frequency).
   Requires that system_health is configured to write to a file target.
   On most SQL Server instances, files are at:
     C:\Program Files\Microsoft SQL Server\MSSQL<version>.<instance>\MSSQL\Log\
     Named: system_health_*.xel

   Adjust the file path below to match your instance.
   ============================================================================ */
/*
SELECT
    deadlock_time = xdr.value('@timestamp', 'datetime2(3)'),
    deadlock_xml  = CAST(xdr.query('.') AS xml)
FROM (
    SELECT CAST(event_data AS xml) AS event_xml
    FROM sys.fn_xe_file_target_read_file(
        N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\system_health*.xel',
        NULL, NULL, NULL)
    WHERE object_name = 'xml_deadlock_report'
) AS raw_data
CROSS APPLY event_xml.nodes('//event') AS events(xdr)
ORDER BY deadlock_time DESC;
*/
