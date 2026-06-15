# ssrstracelog-review — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed to perform
the analysis. This reference file provides deeper context when you need:

- A detailed explanation of a specific check including trace log / config / `ExecutionLog3`
  excerpts and multiple fix options ranked by impact
- The full Quick Reference table for all 24 checks at a glance

Load it when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- You need to see multiple fix options ranked by impact, not just the primary fix
- You need trace log / `RSReportServer.config` / `ExecutionLog3` excerpt examples to
  verify a finding against the source artifact

## Reference files

### check-explanations.md

**When to load:** When a check fires and you need deeper context, multiple fix options,
or excerpt examples. Also when the user asks "explain check GX" or "what does this
finding mean?"

**What it covers:** The full five-part explanation (What it means / How to spot it /
Example / Fix options / Related checks) for all 24 checks plus the Quick Reference table.

## Scripts

### ../scripts/collect-ssrs-diagnostics.ps1

**When to point the user at it:** When the user has shell access to the report server
and wants a single capture of trace config, server config, recent trace log errors, and
related Event Log entries to paste into this skill. See `../scripts/README.md` for
parameters and output.
