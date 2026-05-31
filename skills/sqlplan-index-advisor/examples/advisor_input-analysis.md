# Index Advisor Report — `advisor_input.sqlplan`

> **Input:** `skills/sqlplan-index-advisor/examples/advisor_input.sqlplan`
> Run with: `/sqlplan-index-advisor skills/sqlplan-index-advisor/examples/advisor_input.sqlplan`
>
> Source: Two-statement plan (`ProdDB`) — Orders+OrderLines join and Customers+Orders aggregate

## Input Summary

- Plans analyzed: 1 (2 statements)
- Operator-derived candidates (Source A): 4 (D1, D3, D5, D6)
- Optimizer suggestions (Source B): 2 (Orders Impact 91.2, Customers Impact 84.7)
- After unified merge: 3 recommendations
- Tables affected: 2 (`dbo.Orders`, `dbo.Customers`)

---

## Source A — Operator-Derived Candidates

### D1 — Key Lookup on `dbo.Orders` (Statement 1)

- **Node:** NodeId=2, `Key Lookup` on `[PK_Orders]`
- **Executions:** 8,420 — one lookup per row returned by the outer Index Seek
- **Columns fetched:** `TotalAmount`, `ShippedDate` (not in `IX_Orders_Status`)
- **Derived impact:** min(90, 59% × 2) = **90** (Key Lookup rows represent ~59% of Statement 1 cost)
- **Action:** Extend the index being seeked with the lookup columns as INCLUDE

### D3 — Residual Predicate on `dbo.Orders` (Statement 1)

- **Node:** NodeId=1, `Index Seek` on `[IX_Orders_Status]`
- **Seek predicate:** `Status = @status` (equality)
- **Residual predicate:** `CreatedDate >= @startDate` (post-seek filter — not in index key)
- **Signal:** All rows matching `Status` are fetched from the leaf, then `CreatedDate` is applied. With date-range queries this discards a large fraction of rows.
- **Derived impact:** **70** (range filter on non-keyed column in a high-volume seek)
- **Action:** Add `CreatedDate` as a key column after `Status` so the B-tree traversal narrows by date

### D5 — Sort Operator 37.5% Cost (Statement 2) — *No index action; see Skipped*

- **Node:** NodeId=10, `Sort` on `OrderCount DESC`
- **Cost share:** 37.5% of Statement 2 (EstimatedTotalSubtreeCostPercent=37.5 — above D5 threshold of 10%)
- **Blocked:** `OrderCount` is a `COUNT(OrderId)` aggregate — a computed value with no underlying column. No index key order can satisfy `ORDER BY COUNT(...)`. Flag in Skipped.

### D6 — Nested Loops Inner Scan on `dbo.Orders` (Statement 2)

- **Node:** NodeId=14, `Clustered Index Scan` on `[PK_Orders]`
- **Executions:** 48,200 (ActualExecutions) — the outer Customers scan passes each row to the inner loop, which scans all Orders for that customer
- **Join column (outer reference):** `CustomerId` (passed from the Customers outer side)
- **Derived impact:** min(85, 48200/100) = **85**
- **Action:** NC index on `Orders(CustomerId)` converts each inner-side scan to a seek

---

## Source B — Optimizer Explicit Suggestions

### Suggestion 1 — `dbo.Orders` (Impact 91.2)

```xml
<MissingIndexGroup Impact="91.2">
  EQUALITY:   Status
  INEQUALITY: CreatedDate
  INCLUDE:    OrderId, CustomerId, TotalAmount, ShippedDate
</MissingIndexGroup>
```

### Suggestion 2 — `dbo.Customers` (Impact 84.7)

```xml
<MissingIndexGroup Impact="84.7">
  EQUALITY: Region
  INCLUDE:  CustomerId, Name, Email
</MissingIndexGroup>
```

---

## Unified Merge

### `dbo.Orders` — Three candidates converge

| Source | Key Columns | INCLUDE | Impact |
|--------|-------------|---------|--------|
| D1 (Key Lookup) | extend `IX_Orders_Status` | TotalAmount, ShippedDate | 90 |
| D3 (Residual) | Status + **CreatedDate** | — | 70 |
| Optimizer B | (Status, CreatedDate) | OrderId, CustomerId, TotalAmount, ShippedDate | 91.2 |

Merge rule: optimizer impact (91.2) takes precedence; all three agree on `(Status, CreatedDate)` as key; INCLUDE is union of all three. SourceCount = 3.

**Score = 91.2 × ln(1 + 3) = 91.2 × 1.386 = 126.4**

### `dbo.Orders` — D6 (inner-side scan, different key)

Key `(CustomerId)` does not overlap with `(Status, CreatedDate)`. No merge — separate index. SourceCount = 1.

**Score = 85 × ln(1 + 1) = 85 × 0.693 = 58.9**

### `dbo.Customers` — Optimizer B only

D2 did not fire (Customers scan cost 14.7% < 25% threshold). Optimizer suggestion stands alone. SourceCount = 1.

**Score = 84.7 × ln(1 + 1) = 84.7 × 0.693 = 58.7**

---

## Recommended Indexes (Ranked)

### [I1] dbo.Orders — Score: 126.4 `[both: D1 + D3 + optimizer]`

```sql
CREATE NONCLUSTERED INDEX [IX_Orders_Status_CreatedDate]
ON [dbo].[Orders] ([Status], [CreatedDate])
INCLUDE ([OrderId], [CustomerId], [TotalAmount], [ShippedDate])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

- **Source:** Key Lookup elimination (D1) + residual predicate promotion (D3) + optimizer suggestion (Impact 91.2)
- **Effect on Statement 1:**
  - Seek on `(Status, CreatedDate)` replaces the two-step seek + residual filter — rows are narrowed in the B-tree, not post-fetch
  - Key Lookup eliminated — all 5 SELECT columns (`OrderId`, `CustomerId`, `Status`, `TotalAmount`, `ShippedDate`) are now at the leaf
  - 8,420 Key Lookup round-trips → 0
- **Covers:** Statement 1 (primary), Statement 2 partially (if `CustomerId` is added to INCLUDE — see Warning)
- **Width check:** 2 key + 4 INCLUDE = 6 columns. Within limits.
- **Warning:** Current INCLUDE does not cover `Status` (it is in the key — OK) but `CustomerId` is in INCLUDE. If Statement 2 also queries Orders by `CustomerId`, consider whether D6's separate index (I2) can be deferred.

### [I2] dbo.Orders — Score: 58.9 `[derived: D6]`

```sql
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId]
ON [dbo].[Orders] ([CustomerId])
INCLUDE ([OrderId], [TotalAmount])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

- **Source:** Nested Loops inner-side scan — 48,200 executions in Statement 2
- **Effect:** Converts each inner-side full-table scan to a single NC index seek. At 48,200 executions, the savings are large even though the per-scan cost is modest.
- **Covers:** Statement 2 LEFT JOIN `Orders ON CustomerId`
- **Width check:** 1 key + 2 INCLUDE = 3 columns. No issues.
- **Note:** After deploying I1, verify whether `IX_Orders_Status_CreatedDate` with `CustomerId` in INCLUDE already benefits Statement 2 enough. If so, I2 may be lower priority.

### [I3] dbo.Customers — Score: 58.7 `[optimizer]`

```sql
CREATE NONCLUSTERED INDEX [IX_Customers_Region]
ON [dbo].[Customers] ([Region])
INCLUDE ([CustomerId], [Name], [Email])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
```

- **Source:** Optimizer suggestion (Impact 84.7) — Statement 2 scans 48,200 Customers rows to filter on `Region`
- **Effect:** Converts the 48,200-row Clustered Index Scan to an NC seek that returns only customers matching `@region`. The Nested Loops iteration count drops from 48,200 to however many customers are in the region.
- **Covers:** Statement 2 `WHERE c.Region = @region`
- **Width check:** 1 key + 3 INCLUDE = 4 columns. No issues.
- **Combined effect with I2:** After I3 narrows the Customers outer set, fewer Orders inner-side iterations occur — I2's benefit scales proportionally.

---

## Skipped / Flagged

| Node | Check | Reason | Recommended Action |
|------|-------|--------|--------------------|
| Sort (Node 10, 37.5%) | D5 | `ORDER BY COUNT(OrderId) DESC` — computed aggregate has no indexable column | Consider replacing with `TOP (@n)` if full sort is not needed; or pre-aggregate into a temp table sorted by count |
| Orders inner-side scan | D6 | After I3 narrows Customers, may resolve naturally — monitor actual executions | Deploy I3 first; re-evaluate I2 post-deployment with actual plan |

---

## Width Check Summary

| Index | Key Cols | INCLUDE Cols | Total | Status |
|-------|----------|--------------|-------|--------|
| IX_Orders_Status_CreatedDate | 2 | 4 | 6 | ✓ |
| IX_Orders_CustomerId | 1 | 2 | 3 | ✓ |
| IX_Customers_Region | 1 | 3 | 4 | ✓ |

---

## Deployment Script

```sql
-- ================================================================
-- Index Advisor Deployment Script
-- Source: advisor_input.sqlplan — 2 statements, ProdDB
-- Deploy in order: I1 → I3 → I2 (I2 may be redundant after I3)
-- ================================================================

-- STEP 1 [I1]: Covering index on Orders — eliminates Key Lookup + residual predicate
-- Highest impact (Score 126.4). Deploy first; recapture plan to verify lookup elimination.
CREATE NONCLUSTERED INDEX [IX_Orders_Status_CreatedDate]
ON [dbo].[Orders] ([Status], [CreatedDate])
INCLUDE ([OrderId], [CustomerId], [TotalAmount], [ShippedDate])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);

-- STEP 2 [I3]: Region seek on Customers — reduces Statement 2 outer input
-- Deploy second; reduces iterations of the inner Orders scan, lowering I2 priority.
CREATE NONCLUSTERED INDEX [IX_Customers_Region]
ON [dbo].[Customers] ([Region])
INCLUDE ([CustomerId], [Name], [Email])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);

-- STEP 3 [I2]: CustomerId seek on Orders — inner-side Nested Loops (conditional)
-- Re-evaluate after I3. If Statement 2 execution time drops to acceptable levels, skip.
CREATE NONCLUSTERED INDEX [IX_Orders_CustomerId]
ON [dbo].[Orders] ([CustomerId])
INCLUDE ([OrderId], [TotalAmount])
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);

-- POST-DEPLOYMENT: Run /sqlplan-compare to diff before/after plans and confirm:
--   1. Key Lookup on PK_Orders eliminated (Statement 1)
--   2. Clustered Index Scan on Customers replaced by NC seek (Statement 2)
--   3. Statement 2 Nested Loops iteration count reduced
```

---

## Summary

| Source | Count |
|--------|-------|
| Operator-derived only (Source A) | 1 (IX_Orders_CustomerId — D6) |
| Optimizer-suggested only (Source B) | 1 (IX_Customers_Region) |
| Combined (both sources agreed) | 1 (IX_Orders_Status_CreatedDate — D1 + D3 + optimizer) |
| Operator-derived — no index action | 1 (D5 Sort on computed aggregate — skipped) |
| Estimated statements improved | 2 of 2 |
