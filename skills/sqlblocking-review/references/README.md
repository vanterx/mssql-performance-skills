# sqlblocking-review — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed
to perform the analysis. These reference files provide deeper context when
you need:

- A detailed explanation of a specific check including DMV output examples and
  multiple fix options ranked by impact
- The head-blocker state table that maps `status` / `wait_type` /
  `open_transaction_count` to "does this resolve on its own?"
- Background on lock modes, lock duration, and how to read a `wait_resource`
  string
- The full Quick Reference table for all 36 checks at a glance

Load a reference file when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- You need multiple fix options ranked by impact, not just the primary fix
- You need DMV output examples to verify a finding against the source artifact
- The user asks how blocking differs from deadlocking, or what a lock mode means

## Reference files

### check-explanations.md

**When to load:** When a check fires and you need deeper context, multiple fix
options, or DMV output examples. Also when the user asks "explain check BLx",
"what does this finding mean?", or asks for the T-SQL that implements a fix
(batched delete loop, `sp_getapplock` pattern, RCSI enablement, Extended Events
session for the blocked process report).

**What it covers:** The full five-part explanation (What it means / How to spot
it / Example / Fix options / Related checks) for all 36 checks, the
head-blocker state classification table, a background section on lock modes,
lock duration, blocking versus deadlock, and `wait_resource` formats, plus the
Quick Reference table.
