# sqlblocking-review — Scripts

## capture-blocking.sql

Read-only capture script that collects every artifact `/sqlblocking-review`
analyzes, in one batch.

**Sections collected**

| # | Content | Feeds checks |
|---|---------|--------------|
| 1 | Blocking chain with head blocker, wait, state, and statement text | BL1–BL8, BL12–BL15 |
| 2 | Open transactions with age, isolation level, and idle time | BL9, BL10, BL24–BL27 |
| 3 | Waiting tasks joined to the lock each waits for | BL2, BL18–BL22 |
| 4 | Lock footprint grouped per session, resource type, and mode | BL16, BL17, BL22, BL23 |
| 5 | Blocked process threshold, database concurrency options, blocking XE sessions, escalation trace flags | BL29–BL34, BL36 |

**How to run**

1. Run it on the instance **while the blocking is happening** — sections 1–4
   read live lock manager state and show nothing once the chain has cleared.
2. Run it **twice, 30–60 seconds apart**, when you can. A falling `wait_time`
   on a changing `wait_resource` means progress; the same values twice mean a
   stalled head blocker. Two captures are also what BL7 compares.
3. Save the output (SSMS: Results to Text, or `sqlcmd -o`) and paste it into
   `/sqlblocking-review`.

```
sqlcmd -S <server> -E -i capture-blocking.sql -o blocking_capture_1.txt
```

**Prerequisites**

- `VIEW SERVER STATE` (SQL Server 2019 and earlier) or
  `VIEW SERVER PERFORMANCE STATE` (SQL Server 2022 and later).
- `sys.dm_tran_locks` can return a large result set on a busy instance;
  section 4 aggregates rather than listing every lock for that reason.
- On Azure SQL Database, sections 1–4 work with `VIEW DATABASE STATE`;
  section 5a (`sys.configurations`) does not apply, since the blocked process
  threshold is not user-configurable there.

**Safety**

The script only reads. It changes no configuration, starts no Extended Events
session, and kills nothing. Any `KILL` remains a decision for the DBA, made
after reading the analysis — see BL9/BL10 for when it is the right call and
BL11 for when waiting is.
