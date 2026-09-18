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
- The full Quick Reference table for all 54 checks at a glance
- The reasoning behind a recommendation, or which community tool to run

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
it / Example / Fix options / Related checks) for all 54 checks, the
head-blocker state classification table, a background section on lock modes,
lock duration, blocking versus deadlock, and `wait_resource` formats, plus the
Quick Reference table.

### community-practices.md

**When to load:** When the user asks why a check exists or what the reasoning
behind a recommendation is; when they are working from `sp_WhoIsActive`, First
Responder Kit, or `sp_HumanEvents` output and need the columns mapped onto these
checks; when they ask which tool to run for live versus historical blocking; or
when a widely repeated piece of advice ("just add NOLOCK", "just turn on RCSI",
"set the blocked process threshold to 1 second") needs qualifying.

**What it covers:** A digest of field practice from Brent Ozar, Pinal Dave, Erik
Darling, Paul Randal, Michael J. Swart, Kendra Little, Adam Machanic, and Ola
Hallengren, mapped to the check IDs it produced; a tooling map for live versus
historical capture; the places where popular advice needs qualifying; and the
source list. Community sources are cited for method — thresholds and syntax in
`SKILL.md` follow Microsoft Learn.
