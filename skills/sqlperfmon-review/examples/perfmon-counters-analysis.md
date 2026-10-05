# SQL Server Perfmon Counter Review

## Summary
- **3 Critical, 8 Warnings, 1 Info**
- **Attribution verdict:** SQL Server is the consumer. At peak it accounts for 90.5% of the machine against a host total of 94.4%, leaving a residual of under 4% for every other process.
- **Highest-risk finding:** [C2] the `G:` data volume reaches 52 ms read latency while its throughput rises only 1.6× — high latency at low throughput, which is a sick I/O path rather than a saturated one. Kernel time rising with it ([W1]) points at the same path.
- **Capture window:** 10/06/2026 09:00:00 – 09:05:45 (5 min 45 s), nominal 15-second interval, 16 samples. **One gap of 2 min 15 s** between 09:02:15 and 09:04:30 — see [W8], which bounds the confidence of everything else.
- **Supplied context:** `cpu_count` = 16, physical RAM = 32 GB (32,768 MB), stated baseline ≈ 620 batch requests/sec.

---

### Capture Quality (PM14)

| Property | Value |
|----------|-------|
| Window | 09:00:00 – 09:05:45 (5 min 45 s) — long enough to support sustained-value judgements |
| Nominal interval | 15 s |
| Samples | 16 |
| Gaps | **1** — 09:02:15 → 09:04:30 is 135 s, nine times the nominal interval |

The gap falls on the steepest part of every rising curve. Values on either side of it should be read as a **floor** on severity, not as measurements: CPU, kernel time and `G:` latency were all climbing into the gap and were already at their maxima when sampling resumed, so the true peak is unobserved and is at least what the 09:04:30 sample shows.

---

### CPU Attribution (PM1–PM3)

Arithmetic shown, because a process counter is not comparable to `Processor(_Total)` until it is divided by `cpu_count`:

| Quantity | Peak value | Reading |
|----------|-----------|---------|
| `cpu_count` | 16 | Ceiling for the process counter is 1,600 |
| `Process(sqlservr)\% Processor Time` | 1,448.204 | 1448 / 16 = **90.5% of the machine** |
| `Processor(_Total)\% Processor Time` | 94.447 | Host total 94.4% |
| **Residual to other processes** | ~3.9% | PM2 does not fire — this is SQL Server's own consumption |

---

### Critical Issues

**[C1] SQL Server Process CPU Saturated (PM1)**
- **Observed:** `Process(sqlservr)\% Processor Time` rises from 702 to 1,448 on a 16-processor host. 11 of 16 samples (69%) are at or above the 960 Warning line (60 × 16); **9 of 16 (56%) are at or above the 1,280 Critical line** (80 × 16).
- **Impact:** The host is CPU-saturated and SQL Server is the cause. Sustained, not a spike — the elevated state covers the majority of the window and had not recovered by the final sample.
- **Fix:** This finding settles attribution; the work is now inside the engine. Run `/sqlwait-review` for the signal wait ratio (V10) and `SOS_SCHEDULER_YIELD` (V7), then `/sqlquerystore-review` or `/sqlplan-review` for the statements. Before accepting that the workload needs more processors, rule out two things: a scheduler count below 16 from an edition cap or affinity mask (`/sqldbconfig-review` B34), and spinlock contention, whose CPU never appears as a wait type (`/sqlwait-review` V45). Note that the compilation findings below ([C3], [W5]) are themselves a CPU consumer — compilation is not free, and at 35% of batches it is a plausible share of this curve.

**[C2] Logical Disk Latency Critical on `G:` (PM7)**
- **Observed:** `LogicalDisk(G:)\Avg. Disk sec/Read` rises from 0.004562 s to **0.052447 s (52 ms)**. Three samples are at or above the 0.050 s Critical line for a data volume; seven are at or above the 0.020 s Warning line. Over the same window `LogicalDisk(G:)\Disk Transfers/sec` rises only from 188 to 305.
- **Impact:** Latency rose roughly 11× while throughput rose 1.6×. That is the high-latency/low-throughput quadrant — a sick path, not a volume saturated by honest work. `E:` (data, peak 7.2 ms) and `F:` (log, peak 5.9 ms) are both healthy, so this is specific to `G:`.
- **Fix:** Correlate with [W1]: kernel time climbing in step with this curve points at the I/O path rather than the array, and a filter driver scanning database files is the first candidate — test an antivirus exclusion for the data, log and backup directories and the `sqlservr.exe` process. In parallel, map `G:` to its database files via `sys.master_files` so the finding names a database, and cross-check with `/sqldiskio-review`, which applies these same thresholds per file. Do not escalate to storage before checking the queries driving the reads (`/sqlstats-review`, `/sqlindex-advisor`) — an eliminated scan removes more latency than a faster disk.

**[C3] Compilations at 35% of Batch Requests (PM9)**
- **Observed:** `SQL Compilations/sec` rises from 41.1 to 188.2 while `Batch Requests/sec` falls from 612 to 479. The share moves from **6.7% to 34.7%**, against a 10% Warning and 25% Critical line.
- **Impact:** At peak, better than one batch in three requires a compile. Plan reuse has collapsed. Compilation consumes CPU, so this is a contributor to [C1], not an independent problem — and the direction matters: compiles rose while throughput fell, so the server is doing more compiling and less work.
- **Fix:** The cache-side measurement agrees ([W6]: the `SQL Plans` cache object count more than doubled while `Object Plans` stayed flat), which confirms unparameterized ad hoc SQL rather than a procedure problem. Parameterize in the application — `sp_executesql` or parameterized commands instead of concatenated literals — and use `/tsql-review` to find the generating code. As interim mitigation enable Optimize for Ad Hoc Workloads (`/sqldbconfig-review` B4). Quantify the memory cost with `/sqlmemory-review` O6 and O10.

---

### Warnings

**[W1] Privileged (Kernel) Time Disproportionate (PM3)**
- **Observed:** `Processor(_Total)\% Privileged Time` as a share of `% Processor Time` rises from **21.9%** (9.204 / 42.118) to **39.0%** (36.881 / 94.447), against a 30% Warning line.
- **Impact:** By the end of the window, nearly two-fifths of all consumed processor time is in kernel mode. A database workload spends real time there on I/O, but this share, rising in lockstep with the `G:` latency in [C2], localises the cost to the I/O path.
- **Fix:** Test an antivirus exclusion first — cheapest and reversible. Then check storage driver and HBA firmware levels with the hardware vendor. `/sqldbconfig-review` B37 covers the in-process counterpart: a module that consumes kernel time on the I/O path frequently also loads a DLL into the SQL Server address space.

**[W2] Page Life Expectancy Declining (PM4)**
- **Observed:** `Page life expectancy` falls monotonically from **4,821 s to 1,688 s** — a 65% drop over 5 minutes 45 seconds with no recovery.
- **Impact:** The shape is a steady decline, not a sawtooth, so this is not a periodic report flushing the pool and recovering. Pages are being evicted faster than they are being re-referenced, and every eviction becomes a physical read — which lands on the volume already flagged in [C2].
- **Fix:** This skill does not set a PLE threshold; `/sqlmemory-review` O1 owns it, so take the severity grade from there. On this host, read the decline together with [W4]: OS available memory is also falling, and a host under memory pressure forces the engine to shrink its caches with no workload change at all. If `max server memory (MB)` is unset, that is the likely root cause (`/sqldbconfig-review` B6).

**[W3] Virtual Address Space Growth Outpacing Committed Memory (PM5)**
- **Observed:** `Virtual Bytes` grows from **38.37 GB to 39.74 GB** (+1.37 GB) while `Private Bytes` moves from 17.96 GB to 17.97 GB (+0.007 GB). The ratio reaches **2.21×**, above the 2× trigger, and is rising steadily rather than stepping.
- **Impact:** Address space is being reserved without being committed. On a 64-bit instance this is easy to dismiss, but a fragmented address space can produce allocation failures while physical memory is still plentiful — an out-of-memory error that makes no sense next to the free RAM on the box. A steady slope rather than a step points at a leak rather than a one-time load.
- **Fix:** Enumerate non-Microsoft modules in the process with `/sqldbconfig-review` B37 — the usual consumers are third-party agents, in-process OLE DB providers from linked servers, CLR and extended stored procedures. Move linked-server providers out of process by turning off the provider's `AllowInProcess` option. Capture `sys.dm_os_memory_clerks` and route to `/sqlmemory-review` for the holder, and check `/sqlerrorlog-review` for failed allocation messages pre-dating this window.

**[W4] OS Available Memory Declining (PM6 — below trigger, reported for the trend)**
- **Observed:** `Available MBytes` falls from **6,412 to 5,144** — 19.6% to **15.7%** of the 32,768 MB installed. The 10%-of-RAM Warning line is 3,277 MB, so the check does not fire.
- **Impact:** Not yet a finding on its own, but the direction matters because it supports [W2]: PLE falling while host memory falls is consistent with OS pressure forcing cache eviction rather than with a workload change. Extrapolating the observed slope, the Warning line is some hours away, not minutes.
- **Fix:** Confirm `max server memory (MB)` is set and leaves the OS a genuine reserve (`/sqldbconfig-review` B6). Identify the holder of the remaining memory with `Process(*)\Private Bytes` before assuming it is SQL Server. Re-capture over a longer window to establish whether the decline continues or plateaus.

**[W5] Recompilations at 9% of Batch Requests (PM10)**
- **Observed:** `SQL Re-Compilations/sec` rises from 9.2 to 48.9; as a share of batch requests, **1.5% to 9.0%**, against a 5% Warning and 10% Critical line.
- **Impact:** Approaching Critical. Recompiles differ in cause from the compiles in [C3]: the candidates are schema changes, statistics changes from significant row movement, and session `SET` option differences between connections. The third is worth ruling out explicitly because it is invisible from the database side — identical statement text, different connection options.
- **Fix:** `/sqltrace-review` X16 captures the recompile events with their reason subclass, which distinguishes the three causes. Where the reason is a `SET` option mismatch, normalise connection options across the application's connection strings and drivers. Read this alongside [C3] rather than adding the two — `SQL Compilations/sec` already includes statement-level recompiles.

**[W6] Plan Cache Growth Concentrated in `SQL Plans` (PM11)**
- **Observed:** `Plan Cache(SQL Plans)\Cache Object Counts` grows from **14,207 to 34,588** (+143%) while `Plan Cache(Object Plans)\Cache Object Counts` moves from 1,982 to 1,987 (+0.25%).
- **Impact:** The textbook signature of literal-concatenated SQL: every variant compiles once, is cached, and is never reused. Flat `Object Plans` rules out a stored-procedure problem. This is the same workload [C3] measures from the compilation side, and the two agreeing is what makes the diagnosis safe.
- **Fix:** Nothing is fixed in the cache itself. Parameterize in the application; `/sqldbconfig-review` B4 (Optimize for Ad Hoc Workloads) stores a stub on first use as mitigation while that is arranged. `/sqlmemory-review` O6 and O10 convert the object count into memory and churn.

**[W7] Client Cancellation (Attention) Rate Elevated (PM13)**
- **Observed:** `SQL Attention rate` is 0.000 for the first six samples, then rises to **0.402/sec** at 09:04:30 before decaying to 0.067. Non-zero for 10 of 16 samples.
- **Impact:** Clients began cancelling requests as `G:` latency and CPU climbed — a direct measurement of users giving up, and the onset at 09:01:30 dates the point at which the incident became user-visible. It is also a cause of further damage: a cancel ends the batch but does not roll back the transaction, so each one can leave a transaction open holding its locks.
- **Fix:** Check for orphaned transactions now with `/sqlblocking-review` BL10 — at this rate the window has likely produced some. The durable fix is in the client: roll back in the error handler (`IF @@TRANCOUNT > 0 ROLLBACK TRAN`) or `SET XACT_ABORT ON`. Capture the `attention` extended event to tie individual cancellations to statements.

**[W8] Counter Collection Gap (PM14)**
- **Observed:** The interval between 09:02:15 and 09:04:30 is **135 seconds against a nominal 15** — nine times the sample interval. All other intervals are exactly 15 s.
- **Impact:** A gap in an otherwise regular series means the collector was starved: the host was too busy to run a sampling thread on schedule, which is itself evidence about the host. It coincides with the steepest part of every curve, so the true peaks of [C1], [C2] and [W1] are unobserved.
- **Fix:** Treat the values bracketing the gap as a floor on severity rather than a measurement. Re-capture with a window that brackets the incident; if the collector is starved again, run it at a lower priority or from a remote machine. Thin a long log with `relog ... -t <n>` rather than shortening the window.

---

### Info

**[I1] Batch Request Throughput Down 23% Against Baseline (PM12 — below trigger)**
- **Observed:** `Batch Requests/sec` peaks at 671.9 early in the window, then falls to **478.9** — 23% below the stated baseline of ~620/sec. The ±50% trigger does not fire.
- **Impact:** Reported despite not firing, because the *direction* is the serious pattern: throughput falling while CPU rises is the server doing less work for the same cost. That is the signature of a resource bottleneck beginning to throttle the workload, and here the bottleneck is visible — `G:` latency ([C2]) and compilation overhead ([C3]).
- **Action:** No separate action. This is corroboration that [C1], [C2] and [C3] are affecting the workload rather than being incidental, and it is the number to watch after remediation: if throughput returns to ~620/sec at lower CPU, the fixes worked.

---

### Passed Checks

**PM2** — residual host CPU outside `sqlservr` peaks at ~3.9% against a 30% Warning line. SQL Server is unambiguously the consumer; no other process is competing. **PM6** — `Available MBytes` stays at 15.7% of installed RAM against a 10% trigger (the declining trend is reported above as [W4]). **PM7 for `E:` and `F:`** — `E:` (data) peaks at 7.2 ms against a 20 ms line, `F:` (log) at 5.9 ms against a 10 ms line; only `G:` is affected. **PM12** — within the ±50% band (direction reported as [I1]).

**NOT ASSESSED:** none. The capture contains both Windows and `SQLServer:*` counter families, so all 14 checks could be evaluated.

---

### Counter Summary Table

| Counter | Instance | Min | Avg | Max | Threshold | Check |
|---------|----------|-----|-----|-----|-----------|-------|
| `% Processor Time` | `Processor(_Total)` | 42.1 | 75.1 | 94.4 | — | PM2 ✓ |
| `% Privileged Time` (share of total) | `Processor(_Total)` | 21.9% | 32.0% | 39.0% | 30% | PM3 ⚠️ |
| `% Processor Time` | `Process(sqlservr)` | 702 | 1,142 | 1,448 | 960 / 1,280 | PM1 ⛔ |
| `Virtual Bytes` ÷ `Private Bytes` | `Process(sqlservr)` | 2.14× | 2.17× | 2.21× | 2× | PM5 ⚠️ |
| `Available MBytes` | `Memory` | 5,144 | 5,834 | 6,412 | 3,277 | PM6 ✓ |
| `Avg. Disk sec/Read` | `LogicalDisk(_Total)` | 0.0034 | 0.0110 | 0.0166 | 0.020 | PM8 ⚠️ |
| `Avg. Disk sec/Read` | `LogicalDisk(E:)` | 0.0040 | 0.0053 | 0.0072 | 0.020 | PM7 ✓ |
| `Avg. Disk sec/Write` | `LogicalDisk(F:)` | 0.0021 | 0.0041 | 0.0059 | 0.010 | PM7 ✓ |
| `Avg. Disk sec/Read` | `LogicalDisk(G:)` | 0.0046 | 0.0304 | 0.0524 | 0.020 / 0.050 | PM7 ⛔ |
| `Disk Transfers/sec` | `LogicalDisk(G:)` | 188 | 272 | 305 | — | PM7 context |
| `Page life expectancy` | `Buffer Manager` | 1,688 | 3,225 | 4,821 | per O1 | PM4 ⚠️ |
| `Batch Requests/sec` | `SQL Statistics` | 479 | 589 | 672 | ±50% of 620 | PM12 ℹ️ |
| `SQL Compilations/sec` (share) | `SQL Statistics` | 6.7% | 21.5% | 34.7% | 10% / 25% | PM9 ⛔ |
| `SQL Re-Compilations/sec` (share) | `SQL Statistics` | 1.5% | 5.6% | 9.1% | 5% / 10% | PM10 ⚠️ |
| `SQL Attention rate` | `SQL Statistics` | 0.000 | 0.142 | 0.402 | > 0 sustained | PM13 ⚠️ |
| `Cache Object Counts` | `Plan Cache(SQL Plans)` | 14,207 | 22,936 | 34,588 | rising | PM11 ⚠️ |
| `Cache Object Counts` | `Plan Cache(Object Plans)` | 1,982 | 1,984 | 1,987 | — | PM11 context |

---

### Recommended Order

1. **Test an antivirus exclusion** for the data, log and backup directories and `sqlservr.exe`, then re-capture. One change addresses the two findings with the strongest mutual corroboration ([C2] and [W1]) and is reversible.
2. **Check for orphaned transactions** left by the cancellations in [W7] — `/sqlblocking-review` BL10. This is the only finding that may still be causing harm after the capture ended.
3. **Parameterize the ad hoc workload** ([C3], [W6]). Highest-effort item, and the one that reduces CPU, compilation and plan cache pressure together.
4. **Confirm memory configuration** — `max server memory (MB)` set with an OS reserve ([W2], [W4]).
5. **Re-capture with no gap** ([W8]) before grading severity precisely; current peaks are floors, not measurements.

---

*Analyzed by: Claude Opus 5 · 2026-10-06 UTC*
