# sqlworkload-compare — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed
to perform the analysis. These reference files provide deeper context when
you need:

- A detailed explanation of a specific check, with side-by-side example
  output and multiple fix options
- The four comparison rules that decide whether a two-capture comparison finds
  the change or invents one: match everything before ranking, normalise by what
  is being compared, weight averages by executions, and treat filters as data
- The full Quick Reference table for all 14 checks at a glance

Load a reference file when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- The user asks why a regression ranking differs from a ratio ranking
- You need to explain why two captures are not comparable as supplied (WC1)

## Reference files

### check-explanations.md

**When to load:** When a check fires and you need deeper context, the worked
arithmetic behind added time or per-second-per-CPU waits, or the user asks
"explain check WC8".

**What it covers:** A "Before You Start: Comparing Two Captures Honestly"
section, then the five-part explanation (What it means / How to spot it /
Example / Fix options / Related checks) for all 14 checks plus the Quick
Reference table.
