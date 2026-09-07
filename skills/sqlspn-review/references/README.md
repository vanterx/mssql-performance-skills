# sqlspn-review — Reference Index

## When to consult these references

The main `SKILL.md` contains all check triggers, severities, and fixes needed
to perform the analysis. These reference files provide deeper context when
you need:

- A detailed explanation of a specific check including code examples and
  multiple fix options ranked by impact
- The full Quick Reference table for the skill's checks at a glance

Load a reference file when:

- A check fires and the user asks "what does this mean?" or "how do I fix it?"
- You need to see multiple fix options ranked by impact, not just the primary fix
- You need XML/SQL/log examples to verify a finding against the source artifact

## Reference files

| File | Purpose |
|------|---------|
| `check-explanations.md` | Five-part (What it means / How to spot it / Example / Fix options / Related checks) plain-English explanation for all 54 K-checks (K1–K54) with `setspn` and AD attribute examples, delegation model tables, Kerberos encryption type bitmask reference, and Quick Reference table |

### check-explanations.md

**When to load:** When a check fires and you need deeper context, multiple
fix options, or code examples. Also when the user asks "explain check KXX"
or "what does this finding mean?"

**What it covers:** The full five-part explanation for all 54 checks
(K1–K54) plus the Quick Reference table. Background sections cover the
Kerberos ticket flow and double-hop problem, the AD objects involved in SPN
and delegation, the three delegation models, Kerberos encryption types,
reading `klist` output, Windows security event IDs for Kerberos failures,
SQL Server ERRORLOG SPN signals, `setspn -A` versus `-S`, and loopback
connections.
