# Deadlock Analysis — `deadlock.xml`

> **Input:** `skills/sqldeadlock-review/examples/deadlock.xml`
> Run with: `/sqldeadlock-review skills/sqldeadlock-review/examples/deadlock.xml`
>
> Source: `system_health` Extended Events session — captured automatically by SQL Server

## Deadlock Summary

| | Victim | Winner |
|--|--------|--------|
| **SPID** | 54 | 61 |
| **Host** | APPSERVER01 | APPSERVER02 |
| **Procedure** | `dbo.UpdateOrderStatus` | `dbo.FulfillOrder` |
| **Started** | 10:32:14.820 | 10:32:14.715 |
| **Log used** | 4 KB | 8 KB |
| **Killed as victim** | Yes | No |

---

## Lock Cycle

```
SPID 54 (UpdateOrderStatus)
  Holds  → U lock on PK_Orders row (OrderId 1001)
  Waits  → X lock on IX_OrderLines_OrderId row (OrderId 1001)
                ↑ held by SPID 61

SPID 61 (FulfillOrder)
  Holds  → X lock on IX_OrderLines_OrderId row (OrderId 1001)
  Waits  → X lock on PK_Orders row (OrderId 1001)
                ↑ held (U) by SPID 54
```

Circular wait → deadlock. SQL Server chose SPID 54 as the victim (lower log used = 4 KB vs 8 KB).

---

## Pattern Match

**P1 — Classic Forward/Reverse Access Order**

Both sessions modify `Orders` and `OrderLines` for the same `OrderId`, but in opposite sequences:

| Session | Step 1 | Step 2 |
|---------|--------|--------|
| `dbo.UpdateOrderStatus` (SPID 54) | U-lock `Orders` (PK) | Needs X-lock `OrderLines` |
| `dbo.FulfillOrder` (SPID 61) | X-lock `OrderLines` | Needs X-lock `Orders` (PK) |

SPID 54 locks Orders first, then needs OrderLines.
SPID 61 locks OrderLines first, then needs Orders.
Classic deadlock from inconsistent lock acquisition order.

---

## Queries Involved

**Victim — `dbo.UpdateOrderStatus` (SPID 54)**
```sql
UPDATE dbo.Orders
SET Status = 'Shipped', ShippedAt = GETDATE()
WHERE OrderId = 1001 AND Status = 'Processing'
```
Acquires U-lock on the `Orders` row for `OrderId = 1001`.

**Winner — `dbo.FulfillOrder` (SPID 61)**
```sql
UPDATE dbo.OrderLines SET PickedAt = GETDATE() WHERE OrderId = 1001;
UPDATE dbo.Orders    SET Status = 'Processing'  WHERE OrderId = 1001;
```
Step 1 acquires X-lock on `OrderLines` for `OrderId = 1001`.
Step 2 attempts to upgrade to X-lock on `Orders` for `OrderId = 1001` — blocked by SPID 54.

---

## Root Cause

Both procedures operate on the same two tables (`Orders`, `OrderLines`) for the same `OrderId`, but touch them in opposite order. Under concurrent execution the cycle is deterministic — it will occur every time both procedures run simultaneously on the same order.

---

## Remediation Plan

### Fix 1 (Recommended) — Enforce Consistent Lock Acquisition Order

Rewrite both procedures to always lock `Orders` before `OrderLines`:

**`dbo.FulfillOrder` — swap the UPDATE order:**
```sql
-- Access Orders FIRST (consistent with UpdateOrderStatus)
BEGIN TRANSACTION;
  UPDATE dbo.Orders    SET Status = 'Processing'  WHERE OrderId = @orderId;
  UPDATE dbo.OrderLines SET PickedAt = GETDATE()  WHERE OrderId = @orderId;
COMMIT;
```

With both procedures locking `Orders` first, the second session blocks on `Orders` before it can hold `OrderLines` — no cycle forms.

### Fix 2 (Complementary) — Reduce Lock Duration

Wrap each procedure in a short, explicit transaction. The shorter the lock is held, the narrower the window for a deadlock:

```sql
-- dbo.UpdateOrderStatus
BEGIN TRANSACTION;
  UPDATE dbo.Orders SET Status = 'Shipped', ShippedAt = GETDATE()
  WHERE OrderId = @orderId AND Status = 'Processing';
COMMIT;  -- release locks immediately
```

### Fix 3 (If Fix 1 Is Not Feasible) — Use Application-Level Serialization

If the lock order cannot be made consistent (e.g., procedures are owned by different teams), use an application-level mutex or a SQL Server `sp_getapplock` to serialize concurrent access to the same `OrderId`:

```sql
EXEC sp_getapplock @Resource = CAST(@orderId AS NVARCHAR(20)),
                   @LockMode = 'Exclusive',
                   @LockOwner = 'Transaction',
                   @LockTimeout = 5000;
```

### Fix 4 (Detection) — Add Retry Logic in the Application

Deadlocks (error 1205) should always be retried. Add a retry loop in the application code with a short random backoff (50–200 ms) for up to 3 attempts before surfacing the error to the user.

---

## Priority

| Fix | Effort | Effectiveness |
|-----|--------|--------------|
| Fix 1 — consistent lock order | Low — 2-line SQL change | **Eliminates** the deadlock |
| Fix 2 — short transactions | Low | Reduces frequency; does not eliminate |
| Fix 3 — app lock | Medium | Eliminates, but adds serialization overhead |
| Fix 4 — retry logic | Low | Hides the symptom; implement regardless |

**Recommended:** Apply Fix 1 immediately (reorder the UPDATEs in `dbo.FulfillOrder`), add Fix 4 as defensive coding.
