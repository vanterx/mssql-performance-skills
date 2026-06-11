# sqlbootstraplog-review — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed
to perform the analysis. These reference files provide deeper context when
you need:

- A detailed explanation of a specific check including log excerpts and
  multiple fix options ranked by impact
- The full Quick Reference table for all 24 checks at a glance

Load a reference file when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- You need to see multiple fix options ranked by impact, not just the primary fix
- You need Summary.txt / Detail.txt / MSI log excerpts to verify a finding
  against the source artifact

## Reference files

### check-explanations.md

**When to load:** When a check fires and you need deeper context, multiple
fix options, or log excerpt examples. Also when the user asks "explain check UX"
or "what does this finding mean?"

**What it covers:** The full five-part explanation (What it means / How to
spot it / Example / Fix options / Related checks) for all 24 checks plus the
Quick Reference table.

## Scripts

### ../scripts/check-pending-reboot.ps1

**When to point the user at it:** Before any install/patch (pre-flight), or
when U7 fires (Restart computer rule failed) and the user needs to find which
pending-reboot signal is set. See `../scripts/README.md` for parameters,
output, and exit codes.
