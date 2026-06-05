# sqlmemory-review Analysis — Memory Pressure Example

**Input:** `memory_pressure_input.txt` — memory clerks, PLE counter, plan cache, memory grants, OS memory state

---

## Memory Pressure Summary

The server is under **Critical memory pressure**: PLE is 47 seconds (threshold: 300 s), 4 sessions are queued for memory grants, OS reports "Available physical memory is low", and Max Server Memory is not configured — SQL Server has consumed all but 2.5 GB of 128 GB RAM. ColumnStore and XTP clerks together hold 30 GB of stolen memory beyond the buffer pool.

---

## Findings

| Check | Severity | Metric | Finding | Fix |
|-------|----------|--------|---------|-----|
| O1 | **Critical** | PLE = 47 s | Buffer pool recycling every 47 seconds; pages cannot stay cached | Investigate O4, O16 first; set Max Server Memory (O20) |
| O6 | **Critical** | Single-use = 86% of plan cache | 48,312 single-use plans consuming 2.18 GB of plan cache | Enable `optimize for ad hoc workloads` |
| O7 | **Critical** | 1,248 compilations/sec | SQL Server compiling over 1,000 queries per second | Parameterize application SQL; review for plan reuse |
| O9 | **Warning** | LOCK clerk = 427 MB | Lock memory above 100 MB threshold | Investigate long-running transactions |
| O11 | **Critical** | 4 sessions waiting | 4 queries queued for memory grants | Session 82 holds 4 GB grant; investigate grant oversize |
| O13 | **Warning** | Session 82 used 7.6% of grant | Granted 4 GB, used 311 MB (7.6%) — blocking 4 sessions | Run /sqlplan-review on session 82 query; update statistics |
| O16 | **Critical** | ColumnStore = 23.5% of target | ColumnStore pool at 24 GB — 23.5% of 107 GB target | Review ColumnStore index coverage; schedule analytics off-peak |
| O17 | **Warning** | XTP = 7.8% of target | In-Memory OLTP at 8 GB | Monitor growth; check sys.dm_db_xtp_memory_consumers |
| O18 | **Critical** | OS reports low memory | available_physical = 2.5 GB; system_memory_state_desc = low | Reduce Max Server Memory immediately |
| O20 | **Critical** | Max Server Memory = 2147483647 | Default (unlimited) — SQL Server consuming all 128 GB | Set Max Server Memory to ~110 GB |

---

## Root Cause Hypothesis

**Primary:** Max Server Memory is not set (O20), allowing SQL Server to consume all 128 GB of RAM. ColumnStore pools (24 GB) and XTP (8 GB) steal memory from the buffer pool, which has shrunk to the point where PLE is 47 seconds.

**Secondary:** Single-use plan cache bloat (2.18 GB / 48K single-use plans) is burning additional stolen memory that compounds the buffer pool pressure.

**Contributing:** An oversized memory grant (session 82: 4 GB requested, 311 MB used) is blocking 4 sessions from running, indicating a stale statistics problem on a high-frequency query.

---

## Recommended Next Steps

1. **Immediate:** `sp_configure 'max server memory (MB)', 112640; RECONFIGURE;` (128 GB × 88% ≈ 113 GB, leaving 15 GB for OS + overhead)
2. **Immediate:** `sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;` — stops plan cache from filling with single-use stubs
3. **Short-term:** Run `/sqlplan-review` on session 82's query — N21 (cardinality mismatch) likely explains the 4 GB grant overestimate
4. **Short-term:** `UPDATE STATISTICS` with `FULLSCAN` on the tables in session 82's query
5. **Medium-term:** Review ColumnStore index coverage with `/tsql-review` — identify tables with ColumnStore indexes that are not benefiting analytical workloads
6. **Monitor:** Re-capture PLE 30 minutes after setting Max Server Memory; expect recovery to > 1,000 s within 1 hour as the buffer pool stabilizes

> Analyzed by: `sqlmemory-review` (O1–O20)
