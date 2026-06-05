# sqlmemory-review — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed
to perform the analysis. These reference files provide deeper context when
you need:

- A detailed explanation of a specific check including DMV examples and
  multiple fix options ranked by impact
- The full Quick Reference table for all 20 checks at a glance

Load a reference file when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- You need to see multiple fix options ranked by impact, not just the primary fix
- You need DMV output examples to verify a finding against the source artifact

## Reference files

### check-explanations.md

**When to load:** When a check fires and you need deeper context, multiple
fix options, or DMV output examples. Also when the user asks "explain check OX"
or "what does this finding mean?"

**What it covers:** The full five-part explanation (What it means / How to
spot it / Example / Fix options / Related checks) for all 20 checks plus the
Quick Reference table.
