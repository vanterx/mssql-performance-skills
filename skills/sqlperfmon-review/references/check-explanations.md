# sqlperfmon-review — Check Explanations (PM1–PM14)

Plain-English explanation of every check in `sqlperfmon-review`, with counter paths, worked arithmetic, and fix recipes. `SKILL.md` carries the triggers and thresholds this skill acts on; this file is background and on-demand detail.

## Contents

- [Before You Start: How to Read a Counter](#before-you-start-how-to-read-a-counter)
- [PM1–PM3 — CPU Attribution](#pm1pm3--cpu-attribution)
- [PM4–PM6 — Memory](#pm4pm6--memory)
- [PM7–PM8 — Storage](#pm7pm8--storage)
- [PM9–PM12 — Compilation and Workload](#pm9pm12--compilation-and-workload)
- [PM13–PM14 — Client Behaviour and Collection Integrity](#pm13pm14--client-behaviour-and-collection-integrity)
- [Quick Reference Table](#quick-reference-table)

---

## Before You Start: How to Read a Counter

Four facts cause most misreadings of a Perfmon capture, and all four change conclusions.

**1. `Process\% Processor Time` is not a percentage of the machine.** It is the sum of processor time across logical processors, so its ceiling is 100 × the number of logical processors. On a 24-core host, `Process(sqlservr)\% Processor Time` of 1800 means 75% of the machine. `Processor(_Total)\% Processor Time`, by contrast, *is* 0–100. Comparing the two without dividing the process counter by `cpu_count` is the single most common error in this kind of review, and it produces findings that are wrong by a factor of the core count.

**2. Rate counters are averages over the sample interval.** `Batch Requests/sec` collected at a 15-second interval cannot show a 2-second spike — the spike is averaged into the surrounding quiet. A capture interval has to be matched to the duration of the thing being hunted, and when it is not, the honest answer is that the capture cannot support the finding (PM14).

**3. `_Total` hides outliers.** For `LogicalDisk`, an average across four volumes where one is sick and three are healthy looks acceptable. PM8 exists because this is how real storage problems get dismissed.

**4. The DMV and Perfmon are not the same source.** `sys.dm_os_performance_counters` exposes the `SQLServer:*` objects and nothing else — no `Process`, no `Processor`, no `LogicalDisk`, no `Memory`. Half the checks in this skill are therefore unavailable from the DMV, and in that case they are NOT ASSESSED rather than inferred. In the DMV, `cntr_type` 272696576 marks a cumulative counter: two samples and the elapsed time between them are required to derive a rate.

**On thresholds.** Microsoft documents what each counter measures. For most of them it publishes no numeric threshold — `Page life expectancy` is defined as "the number of seconds a page will stay in the buffer pool without references" with no target, and `SQL Re-Compilations/sec` carries only "generally, you want the recompiles to be low". This skill does not invent numbers to fill those gaps. Where a threshold already exists elsewhere in this library it is reused (PM7 from `/sqldiskio-review`, PM4 from `/sqlmemory-review` O1); where none exists, the check is expressed as a **ratio the capture can compute** (PM9, PM10) or as a **deviation from a baseline the user supplies** (PM12). A baseline from the same server beats every threshold in this document.

---

## PM1–PM3 — CPU Attribution

### PM1 — SQL Server Process CPU Saturated

**What it means:** The SQL Server process is consuming most of the host's processor capacity, sustained rather than in bursts.

**How to spot it:**

```
\Process(sqlservr)\% Processor Time
\Processor(_Total)\% Processor Time
```

Worked arithmetic on a 24-logical-processor host:

| Observation | Value | Reading |
|-------------|-------|---------|
| `cpu_count` | 24 | Ceiling for the process counter is 2400 |
| `Process(sqlservr)\% Processor Time` average | 1,840 | 1840 / 24 = **76.7% of the machine** |
| `Processor(_Total)\% Processor Time` average | 81 | Total host load 81%, so SQL Server accounts for nearly all of it |
| Samples above 60 × 24 = 1,440 | 92% of window | Sustained, not a spike |

**Why it's a problem:** Not inherently — a database server using its processors is a database server doing its job. The finding is diagnostic rather than remedial: it settles the attribution question, and it stops the next hour being spent on the wrong layer. The value is in what it rules out, which is that something other than SQL Server is eating the machine.

**Fix options:**
1. **Hand off inside the engine.** `/sqlwait-review` V10 (signal wait ratio — threads ready but no processor) and V7 (`SOS_SCHEDULER_YIELD`), then `/sqlplan-review` or `/sqlquerystore-review` for the statements.
2. **Rule out a capped scheduler count** before accepting that more CPU is needed. `/sqldbconfig-review` B34: an edition compute-capacity limit or a `MANUAL` affinity mask means the engine cannot use processors the counter says exist, so the machine looks busier than the engine's own view of it.
3. **Rule out spinlock contention.** `/sqlwait-review` V45 — spinning threads burn processor time that never registers as a wait, so a CPU-bound instance with no wait type to explain it is the signature.
4. **Check whether it is one window.** Backups, index maintenance and statistics updates legitimately saturate a host; correlate against the schedule before calling it a defect.

**Related checks:** PM2, PM3, PM14, `/sqlwait-review` V7/V10/V45, `/sqldbconfig-review` B34

---

### PM2 — Non-SQL Process CPU Competing for the Host

**What it means:** The host is busy and SQL Server is not the one making it busy.

**How to spot it:** Compute the residual, having normalised the scales:

```
residual % = Processor(_Total)\% Processor Time
           − ( Process(sqlservr)\% Processor Time ÷ cpu_count )
```

| Observation | Value |
|-------------|-------|
| `Processor(_Total)\% Processor Time` | 88 |
| `Process(sqlservr)\% Processor Time` | 720 |
| `cpu_count` | 24 |
| SQL Server's share | 720 / 24 = 30% |
| **Residual** | 88 − 30 = **58% to other processes** |

**Why it's a problem:** Because every remediation applied inside the database will fail to move the symptom. A 58% residual means more than half the machine is being consumed by something the DBA may not even know is installed. On a database host the recurring answers are antivirus scans, backup agents, monitoring agents, log shippers, and a second SQL Server instance sharing the box.

**Fix options:**
1. **Name the consumer.** Re-capture with `\Process(*)\% Processor Time` and rank the instances. Without this, the finding is a dead end.
2. **Check for an in-process counterpart.** An agent consuming processor time outside SQL Server often also injects a module into it: `/sqldbconfig-review` B37 enumerates non-Microsoft modules in the SQL Server address space.
3. **Reschedule or exclude.** Agent scans and backups moved out of the business window cost nothing to try.
4. **On a virtual machine, remember the counter's horizon.** It sees this guest only. Host oversubscription appears as time missing from the guest's accounting — a guest that looks idle while queries run slowly is a hypervisor question, and no Windows counter inside the guest will show it.

**Related checks:** PM1, PM3, `/sqldbconfig-review` B37

---

### PM3 — Privileged (Kernel) Time Disproportionate

**What it means:** An unusual share of processor time is being spent in kernel mode — drivers, filter drivers, the storage and network stacks — rather than in application code.

**How to spot it:**

```
\Processor(_Total)\% Privileged Time
\Processor(_Total)\% Processor Time
```

Expressed as a share: `% Privileged Time ÷ % Processor Time`. At 81% total with 38% privileged, kernel mode is 47% of all consumed processor time, which is high for a database workload.

**Why it's a problem:** A database workload spends real time in kernel mode, mostly completing I/O, so some share is expected. A dominant share says the cost is in code neither SQL Server nor the application controls, and that no amount of query tuning will reach it. The usual causes are enumerable:

| Cause | Corroborating evidence |
|-------|------------------------|
| Filter driver in the I/O path — antivirus real-time scanning of data, log or backup files is the classic | PM7 latency rising together with kernel time; `/sqldbconfig-review` B37 for the in-process half |
| Outdated or faulty storage driver / HBA firmware | PM7 high latency at *low* throughput |
| Heavy network interrupt load | `ASYNC_NETWORK_IO` in `/sqlwait-review`; high `Network Interface` counters |
| Excessive context switching from fiber mode | `/sqldbconfig-review` B31 (lightweight pooling) |

**Fix options:**
1. **Test an antivirus exclusion.** Exclude the data, log and backup directories and the `sqlservr.exe` process, then re-measure the same counters over a comparable window. Cheapest experiment available, and reversible.
2. **Check driver and firmware levels** for the storage path with the hardware vendor.
3. **Correlate with PM7.** Kernel time and disk latency rising together localises the problem to storage; kernel time alone with healthy disks points at network or another driver.
4. **Express it as a share, never an absolute.** A kernel-time number means nothing without the total it is part of.

**Related checks:** PM1, PM2, PM7, `/sqldbconfig-review` B31/B37

---

## PM4–PM6 — Memory

### PM4 — Page Life Expectancy Low or Declining

**What it means:** Pages are not staying in the buffer pool long. Microsoft's definition is exact and carries no target: the counter "indicates the number of seconds a page will stay in the buffer pool without references".

**How to spot it:**

```
\SQLServer:Buffer Manager\Page life expectancy
```

On a NUMA host, read the per-node instances of the Buffer Node object rather than the aggregate, since a starved node hides behind a healthy average.

**Why it's a problem:** Deliberately, this skill sets no threshold — `/sqlmemory-review` O1 owns it, so the two skills cannot disagree about the same server. What a Perfmon capture adds over the DMV snapshot O1 reads is **shape over time**, and shape separates two diagnoses that share a single low value:

| Shape | Reading |
|-------|---------|
| Sawtooth — collapses then recovers | A periodic workload is flushing the pool: a report, a large scan, index maintenance, or a statistics update |
| Flat and low | The buffer pool is simply too small for the working set |
| Step down, then flat | Something changed: a new query, a dropped index, a memory setting, or another consumer arriving on the host |

A single DMV reading cannot distinguish these, which is the argument for the capture.

**Fix options:**
1. **Defer the threshold** to `/sqlmemory-review` O1 and report the shape.
2. **Correlate with PM6.** A falling line with no workload change and a starved host is OS memory pressure forcing the engine to shrink its caches — the pair is far stronger evidence than either alone.
3. **Correlate with PM7 and PM11.** Evicted pages have to be re-read, so the cost lands on storage.
4. **Find the flushing workload** where the shape is a sawtooth: align the troughs against the job schedule, then `/sqlstats-review` and `/sqlindex-advisor` for the scans driving it.

**Related checks:** PM6, PM7, PM11, `/sqlmemory-review` O1/O3

---

### PM5 — Virtual Address Space Growth Outpacing Committed Memory

**What it means:** Reserved address space is growing faster than committed memory.

**How to spot it:**

```
\Process(sqlservr)\Virtual Bytes     — reserved address space
\Process(sqlservr)\Private Bytes     — committed, non-shareable
\Process(sqlservr)\Working Set       — resident in physical memory
```

The signature is `Working Set` tracking `Private Bytes` while `Virtual Bytes` diverges upward from both.

**Why it's a problem:** On a 64-bit instance the address space is vast, so this is often dismissed. It should not be: reservation is not free, and a fragmented address space can produce allocation failures while physical memory is still plentiful. The symptom is an out-of-memory error that makes no sense next to the amount of free RAM on the box. The consumers that produce it are a short list — a third-party module loaded into the process, in-process OLE DB providers brought in by linked servers, CLR, and extended stored procedures.

**Fix options:**
1. **Enumerate the modules.** `/sqldbconfig-review` B37 — non-Microsoft DLLs in the SQL Server address space are the first candidate.
2. **Move linked-server providers out of process** by turning off the provider's `AllowInProcess` option, accepting a throughput cost.
3. **Read the clerks.** Capture `sys.dm_os_memory_clerks` and route to `/sqlmemory-review` to see which component holds the reservation.
4. **Check the ERRORLOG for precedent.** `/sqlerrorlog-review` — failed allocation messages often pre-date the counter symptom by days.
5. **Distinguish a step from a slope.** A step at a fixed time points at something being loaded; a steady slope points at a leak.

**Related checks:** PM6, `/sqldbconfig-review` B37, `/sqlmemory-review`, `/sqlerrorlog-review`

---

### PM6 — OS Available Memory Exhausted

**What it means:** The operating system has little physical memory left to hand out.

**How to spot it:**

```
\Memory\Available MBytes
\Process(*)\Private Bytes
\Process(*)\Working Set
```

**Why it's a problem:** This is the counter that separates "SQL Server is using a lot of memory", which is its design, from "the host has none left", which is a stability problem affecting everything on the machine. The engine reacts to OS memory pressure by shrinking its own caches, so a starved host produces a declining page life expectancy (PM4) with no workload change at all — a conclusion that is easy to misattribute to the database.

**Fix options:**
1. **Set `max server memory (MB)` deliberately.** `/sqldbconfig-review` B6 flags it being unset, which is the common root cause, and leaves the OS a genuine reserve rather than a token one.
2. **Name the consumer first.** `Process(*)\Private Bytes` and `Working Set` identify the holder. On a shared host the answer is often not the engine, and capping SQL Server would then be the wrong fix.
3. **Check for a pinned floor.** `/sqldbconfig-review` B32 — `min server memory (MB)` set near the maximum prevents the engine returning memory under pressure even when it otherwise would.
4. **Check Lock Pages in Memory.** `/sqlmemory-review` O19 and `/sqldbconfig-review` B8 — with LPIM active the buffer pool cannot be paged, which changes how host pressure manifests.

**Related checks:** PM4, PM5, `/sqldbconfig-review` B6/B8/B32, `/sqlmemory-review` O18/O19

---

## PM7–PM8 — Storage

### PM7 — Logical Disk Latency Above Threshold

**What it means:** A volume is answering reads or writes more slowly than the workload can absorb.

**How to spot it:**

```
\LogicalDisk(<volume>)\Avg. Disk sec/Read
\LogicalDisk(<volume>)\Avg. Disk sec/Write
\LogicalDisk(<volume>)\Disk Transfers/sec
```

Thresholds are the ones `/sqldiskio-review` already applies to `sys.dm_io_virtual_file_stats`, in Perfmon's units:

| Volume role | Warning | Critical |
|-------------|---------|----------|
| Data | 0.020 s (20 ms) | 0.050 s (50 ms) |
| Log | 0.010 s (10 ms) | 0.025 s (25 ms) |

**Why it's a problem:** The reading depends entirely on throughput, and this is where reviews go wrong:

| Latency | Throughput | Reading |
|---------|-----------|---------|
| High | High | A saturated volume doing real work — a capacity question |
| High | Low | A sick path: failing device, misconfigured queue depth, or a filter driver (PM3) |
| Low | High | Healthy |

**Fix options:**
1. **Find the queries first.** The remediation order is not storage-first: an eliminated scan removes more latency than a faster disk. `/sqlstats-review` for logical reads, `/sqlindex-advisor` for the indexes that remove them.
2. **Cross-check the file view.** `/sqldiskio-review` attributes the same latency to database files, which names a database rather than a drive letter.
3. **Check placement.** Data, log and TempDB sharing a volume turns sequential log writes into random I/O.
4. **Rule out the kernel path.** PM3 — latency and privileged time rising together points at a filter driver rather than the array.
5. **Exclude `_Total`** from this check and use PM8 for it.

**Related checks:** PM3, PM8, `/sqldiskio-review`, `/sqlwait-review` V1

---

### PM8 — Hot Volume Masked by the `_Total` Instance

**What it means:** The `_Total` instance averages across volumes, so a single bad volume can sit inside an acceptable-looking aggregate.

**How to spot it:** Rank the per-volume instances and compare each against `_Total`:

```
LogicalDisk instance   Avg. Disk sec/Read   Reading
--------------------   ------------------   -------------------------------
_Total                 0.014                Within the data threshold
C:                     0.003                Healthy
E: (data)              0.009                Healthy
F: (log)               0.011                Marginal for a log volume
G: (data)              0.048                Nearly Critical, hidden by _Total
```

**Why it's a problem:** This is the most common way a genuine storage problem is dismissed from a Perfmon review. The aggregate passes, the reviewer moves on, and the one volume carrying the hot database is never examined.

**Fix options:**
1. **Always enumerate instances.** Where the capture holds only `_Total`, say so and request a re-capture with `\LogicalDisk(*)\...` rather than drawing a conclusion from the average.
2. **Map volume to database.** `sys.master_files` turns a drive letter into a file and a database name, which is what makes the finding actionable.
3. **Then apply PM7** to the hot volume on its own terms, with its own role-appropriate threshold.

**Related checks:** PM7, `/sqldiskio-review`

---

## PM9–PM12 — Compilation and Workload

### PM9 — Compilations High as a Share of Batch Requests

**What it means:** A large fraction of the batches arriving at the server require a compile, so plans are not being reused.

**How to spot it:**

```
\SQLServer:SQL Statistics\SQL Compilations/sec
\SQLServer:SQL Statistics\Batch Requests/sec
```

Ratio: `SQL Compilations/sec ÷ Batch Requests/sec`.

| Batch Requests/sec | SQL Compilations/sec | Share | Reading |
|--------------------|----------------------|-------|---------|
| 28,400 | 310 | 1.1% | Healthy |
| 820 | 310 | 37.8% | Critical — almost every batch compiles |

**Why it's a problem:** The same absolute rate is healthy on one server and pathological on another, which is exactly why this check is a ratio. Microsoft says only that compilations reach "a steady state" once user activity stabilises and publishes no rate, so an absolute threshold here would be an invented number. A high share means compilation CPU is being spent on work that caching should have eliminated, and the cause is nearly always unparameterized ad hoc SQL — the same workload PM11 sees from the cache side, so the two findings should agree.

**Fix options:**
1. **Parameterize in the application** — `sp_executesql` or parameterized commands instead of concatenated literals. `/tsql-review` finds the generating code.
2. **Mitigate while that is arranged.** `/sqldbconfig-review` B4 (Optimize for Ad Hoc Workloads) stores a stub on first use instead of a full plan.
3. **Quantify from the cache side.** `/sqlmemory-review` O6 and O10 give the single-use share and the churn.
4. **Read PM9 and PM10 together, not added.** `SQL Compilations/sec` includes statement-level recompiles, so the two overlap by construction.

**Related checks:** PM10, PM11, `/sqlmemory-review` O6/O7/O10, `/sqldbconfig-review` B4, `/tsql-review`

---

### PM10 — Recompilations High as a Share of Batch Requests

**What it means:** Statements already in cache are being recompiled rather than reused.

**How to spot it:**

```
\SQLServer:SQL Statistics\SQL Re-Compilations/sec
\SQLServer:SQL Statistics\Batch Requests/sec
```

**Why it's a problem:** Microsoft's guidance is qualitative — "generally, you want the recompiles to be low" — so the honest formulation is again a share. Recompiles differ from compiles in *cause*, and Microsoft enumerates them:

| Cause | Note |
|-------|------|
| Schema changes, including adding columns or indexes to a table | Expected, usually a burst after a deployment |
| Statistics changes — a significant number of rows inserted or deleted | Expected after maintenance; a sustained share is not |
| Environment (`SET` statement) changes, such as `ANSI_PADDING` or `ANSI_NULLS` differing between connections | Produces a recompile storm that looks inexplicable from the database side, because the statement text is identical and only the connection's options differ |

That third cause is the one worth knowing. It is invisible to anyone reading query text.

**Fix options:**
1. **Identify the statements and the reason.** `/sqltrace-review` X16 captures the recompile events with their subclass, which names which of the three causes applies.
2. **Normalise connection options** across the application's connection strings and drivers where the cause is `SET` option mismatch.
3. **Check Query Store** where it is enabled: `/sqlquerystore-review` shows the plan history over the same window.
4. **Expect a burst after maintenance** and look for a sustained share instead.

**Related checks:** PM9, `/sqltrace-review` X16, `/sqlquerystore-review`

---

### PM11 — Plan Cache Object Count Growth Concentrated in `SQL Plans`

**What it means:** The number of cached plan objects is growing, and the growth is in the ad hoc cache rather than the stored-procedure cache.

**How to spot it:** Read the *instance*, not `_Total`. Microsoft documents the counter as the number of cache objects in the cache, exposed per cache type:

| Instance | Holds |
|----------|-------|
| `SQL Plans` | Plans from ad hoc and prepared Transact-SQL, including auto-parameterized queries |
| `Object Plans` | Plans from stored procedures, functions and triggers |
| `Bound Trees` | Normalized trees for views, rules, computed columns, check constraints |
| `Temporary Tables & Table Variables` | Temp object cache information |
| `Extended Stored Procedures` | Catalog information for extended procedures |
| `_Total` | All cache types together |

```
\SQLServer:Plan Cache(SQL Plans)\Cache Object Counts
\SQLServer:Plan Cache(Object Plans)\Cache Object Counts
```

**Why it's a problem:** The instance *is* the diagnosis, which is why `_Total` is the wrong thing to read:

| Pattern | Reading |
|---------|---------|
| `SQL Plans` rising, `Object Plans` flat | Application sending literal-concatenated SQL — each variant compiles once and is never reused |
| `Object Plans` rising | New procedures being deployed, or procedure cache churn |
| `Temporary Tables & Table Variables` rising | Temp object churn, not a parameterization problem |

**Fix options:**
1. **Nothing is fixed in the cache.** The fix is parameterization in the application; `/sqldbconfig-review` B4 is mitigation, not a cure.
2. **Quantify the waste.** `/sqlmemory-review` O6 (single-use share of cache size) and O10 (churn) turn the count into memory.
3. **Cross-check PM9.** Both measure the same workload from different sides; disagreement between them means one of the two captures is unrepresentative.

**Related checks:** PM9, `/sqlmemory-review` O6/O8/O10, `/sqldbconfig-review` B4

---

### PM12 — Batch Request Baseline Shift

**What it means:** Throughput has moved materially against a baseline the user supplies.

**How to spot it:**

```
\SQLServer:SQL Statistics\Batch Requests/sec
```

**Why it's a problem:** This check exists to stop every other finding being misread, and the direction is what matters:

| Throughput | Resource use | Reading |
|-----------|--------------|---------|
| Up | Up | The server is being asked to do more — a capacity finding, not a defect |
| Down | Flat or up | **The serious case.** Less work for the same cost: blocking, a plan regression, or a bottleneck throttling the workload |
| Down | Down | The clients stopped asking. Check the application and PM13 before investigating the database at all |

Microsoft's only characterisation of the counter is that "high batch requests mean good throughput", which is true and not actionable, so this check needs a baseline rather than a threshold.

**Fix options:**
1. **Insist on comparable windows.** A busy hour against a quiet one is not a regression.
2. **Throughput down, cost flat:** `/sqlblocking-review` for blocking, `/sqlplan-compare` and `/sqlquerystore-review` Q-checks for plan regression.
3. **Throughput down, cost down:** look outside the database — PM13 for cancellations, then the application and network.
4. **Record the baseline** so the next capture has something to compare against.

**Related checks:** PM13, `/sqlblocking-review`, `/sqlplan-compare`, `/sqlquerystore-review`

---

## PM13–PM14 — Client Behaviour and Collection Integrity

### PM13 — Client Cancellation (Attention) Rate Elevated

**What it means:** Clients are asking the server to abandon running requests. Microsoft defines an attention as "a request by the client to end the currently running request" — a cancel or a client-side command timeout.

**How to spot it:**

```
\SQLServer:SQL Statistics\SQL Attention rate
```

**Why it's a problem:** It is a direct measurement of users giving up, which makes it unusually valuable: most counters measure cost, this one measures dissatisfaction. It is also a *cause* of further damage. A cancel ends the batch but does not roll back the transaction, so each cancellation can leave a transaction open holding every lock it acquired — which is precisely the orphaned transaction `/sqlblocking-review` BL10 diagnoses. PM13 and BL10 together close the loop between "users report timeouts" and "sessions are blocked behind an idle session".

**Fix options:**
1. **Fix the client's error handling.** `IF @@TRANCOUNT > 0 ROLLBACK TRAN` in the handler, or `SET XACT_ABORT ON`. Without this, every timeout becomes a blocking incident.
2. **Fix what made the statement slow** enough to be cancelled — correlate the rate against PM7, PM12 and the wait findings to see what the clients were waiting on.
3. **Tie cancellations to statements.** Capture the `attention` extended event; `/sqlblocking-review` BL33 covers the session design.
4. **Check the command timeout** is deliberate rather than a driver default that happens to be shorter than the workload.

**Related checks:** PM12, `/sqlblocking-review` BL10/BL33

---

### PM14 — Counter Collection Gaps or Insufficient Sample Window

**What it means:** The capture itself cannot support the analysis — either it is too short, or samples are missing from it.

**How to spot it:** Difference consecutive timestamps and compare against the nominal interval. `relog <file>.blg -q` reports the counters and the time range without converting anything.

**Why it's a problem:** Run this first and report it first, because it decides whether everything else is trustworthy. Two distinct problems share the symptom:

| Problem | Consequence |
|---------|-------------|
| **Window too short** | PM1, PM3 and PM7 are all defined on *sustained* behaviour. A 90-second capture can only show a moment, and grading a spike against a sustained threshold produces a confident wrong answer |
| **Gaps in a regular series** | The collector was starved — the machine was too busy to run a sampling thread on schedule. This is itself a finding about the host, and it tends to coincide with the worst part of the incident, so the capture is missing exactly the period of interest |

The second is easy to miss and changes the conclusion: where gaps cluster, the surrounding values are a *floor* on severity, not a measurement.

**Fix options:**
1. **Say what the capture cannot support** rather than grading it anyway. NOT ASSESSED is a valid finding.
2. **Re-capture bracketing the problem**, with an interval matched to what is being measured — a 15-second interval cannot show a 2-second stall.
3. **Treat clustered gaps as evidence** of host saturation in their own right, and correlate against PM1 and PM2 on either side of the gap.
4. **Thin a long log rather than shortening it.** `relog ... -t 4` keeps the window and reduces the sample count, which is the right trade; truncating the window is the wrong one.

**Related checks:** All — PM14 gates the confidence of every other check in this skill

---

## Quick Reference Table

| Check | Category | Trigger | Severity |
|-------|----------|---------|----------|
| PM1 | CPU | `Process(sqlservr)\% Processor Time` sustained ≥ 60 × cpu_count | Warning / Critical at 80× |
| PM2 | CPU | Residual host CPU outside sqlservr ≥ 30% | Warning / Critical at 50% |
| PM3 | CPU | `% Privileged Time` ≥ 30% of `% Processor Time` | Warning / Critical at 50% |
| PM4 | Memory | Page life expectancy low or declining | per `/sqlmemory-review` O1 |
| PM5 | Memory | `Virtual Bytes` ≥ 2 × `Private Bytes` and rising | Warning |
| PM6 | Memory | `Available MBytes` < 10% of RAM | Warning / Critical < 5% or < 512 |
| PM7 | Storage | Data ≥ 0.020 s or log ≥ 0.010 s sustained | Warning / Critical at 0.050 / 0.025 |
| PM8 | Storage | A volume ≥ 2 × the `_Total` value | Warning |
| PM9 | Compilation | Compiles ≥ 10% of batch requests | Warning / Critical at 25% |
| PM10 | Compilation | Recompiles ≥ 5% of batch requests | Warning / Critical at 10% |
| PM11 | Compilation | `SQL Plans` count rising with `Object Plans` flat | Warning |
| PM12 | Workload | Batch requests ±50% against the stated baseline | Warning |
| PM13 | Client | `SQL Attention rate` sustained above zero | Warning |
| PM14 | Capture | Gap > 3 × interval, or window < 5 minutes | Warning / Critical |
