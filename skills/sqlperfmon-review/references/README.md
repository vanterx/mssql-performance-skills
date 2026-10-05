# sqlperfmon-review — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed
to perform the analysis. These reference files provide deeper context when
you need:

- A detailed explanation of a specific check including counter paths, worked
  arithmetic, and multiple fix options ranked by impact
- The counter-reading fundamentals that change conclusions: the per-core scale
  of `Process\% Processor Time`, why rate counters cannot show short spikes,
  how `_Total` hides an outlier, and which counters the DMV cannot supply
- The full Quick Reference table for all 14 checks at a glance

Load a reference file when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- You need to see multiple fix options ranked by impact, not just the primary fix
- A finding depends on arithmetic the user should be shown — any comparison
  between a `Process` counter and a `Processor(_Total)` counter does
- You need to explain why a threshold is a ratio or a deferral rather than a
  published number

## Reference files

### check-explanations.md

**When to load:** When a check fires and you need deeper context, multiple
fix options, or worked counter arithmetic. Also when the user asks "explain
check PM7" or "what does this finding mean?"

**What it covers:** A "Before You Start: How to Read a Counter" section
covering the four facts that most often cause a Perfmon capture to be
misread, then the full five-part explanation (What it means / How to spot it /
Why it's a problem / Fix options / Related checks) for all 14 checks plus the
Quick Reference table.
