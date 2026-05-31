# Baseline Analysis — main branch (pre-improvement)
# Generated: 2026-05-27 UTC
# Skill version: skills/sqlplan-review/SKILL.md @ main (681 lines)
# Input: skills/sqlplan-review/examples/horrible.sqlplan

## Execution Plan Analysis

### Summary
- **3 Critical** issues, **10 Warnings**, **2 Info** items
- Primary bottleneck: Pervasive 1-row cardinality collapse driven by parameter sniffing (`@StartDate` compiled for `'1900-01-01'`, runtime `'2025-01-01'`) causes undersized memory grants, confirmed Sort and Hash spills to TempDB, and a 5-second memory grant wait — all 7 operators are underestimated by 2,000×–10,000,000×.

---

## Critical Issues

### [C1 — S4] Memory Grant Wait — 5,000 ms
- **Observed:** `GrantWaitTime="5000"` ms; `GrantedMemory=1,048,576 KB` (1 GB)
- **Impact:** The query waited 5 seconds before execution began, queuing for a memory grant slot. At high concurrency, every execution blocks the memory grant queue.
- **Fix:** Fix parameter sniffing (I1) to reduce grant size. Interim: Resource Governor pool cap.

### [C2 — N41] Confirmed Sort Spill to TempDB — SpillLevel 2, 8 Threads
- **Observed:** NodeId=5 (Sort), `SpillToTempDb SpillLevel="2"`, `SpilledThreadCount="8"`
- **Impact:** Multi-pass spill across all 8 threads; TempDB I/O saturation likely.
- **Fix:** Fix parameter sniffing (I1); add pre-ordering index.

### [C3 — N41] Confirmed Hash Aggregate Spill — SpillLevel 3
- **Observed:** NodeId=6 (Hash Aggregate), `HashSpillDetails SpillLevel="3"`
- **Impact:** 3-pass spill, compounds with C2 to drive TempDB contention.
- **Fix:** Fix parameter sniffing (I1).

---

## Warnings

### [W1 — N21] Pervasive Cardinality Collapse — 7 Operators

| NodeId | Operator | Estimated | Actual | Ratio |
|--------|----------|-----------|--------|-------|
| 1 | Hash Match (Inner Join) | 1 | 9,999,999 | 9,999,999× |
| 2 | Nested Loops (Inner Join) | 1 | 5,000,000 | 5,000,000× |
| 3 | Clustered Index Scan (Users) | 1 | 2,000,000 | 2,000,000× |
| 4 | Key Lookup (Orders) | 1 | 5,000,000 | 5,000,000× |
| 5 | Sort | 1 | 9,999,999 | 9,999,999× |
| 6 | Hash Aggregate | 1 | 9,999,999 | 9,999,999× |
| 8 | Index Scan (Orders) | 1,000 | 9,999,999 | 9,999× |

### [W2 — S18] Insufficient Memory Grant — Used 2,048 MB > Granted 1,024 MB
### [W3 — S3] Large Memory Grant — 1,024 MB
### [W4 — N9] Leading Wildcard LIKE — Users.Email LIKE '%gmail.com'
### [W5 — N8] Implicit Conversion on Orders.CreatedDate — CONVERT_IMPLICIT
### [W6 — N3] Function in Scan Predicate — CONVERT on Index Scan (NodeId=8)
### [W7 — N5] Key Lookup Explosion — 5,000,000 executions (NodeId=4)
### [W8 — N6] Sort Spill Risk — actualRows 9,999,999 vs estimateRows 1
### [W9 — N38] Operator-Level Warnings — Sort (NodeId=5), Hash Aggregate (NodeId=6)
### [W10 — N27] Parallel Thread Skew — Thread 0: 1 row, Thread 1: 9,999,999 rows

---

## Info Items

### [I1] Parameter Sniffing — @StartDate compiled '1900-01-01', runtime '2025-01-01'
### [I2 — S28] Large Cached Plan — 2,048 KB

---

## Fired check IDs (for regression comparison)
- Critical: S4, N41 (×2)
- Warnings: N21, S18, S3, N9, N8, N3, N5, N6, N38, N27
- Info: (parameter sniffing), S28
