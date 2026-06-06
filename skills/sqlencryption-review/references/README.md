# sqlencryption-review — Reference Files

Reference materials for the `sqlencryption-review` skill. These files are **not** loaded at runtime by the skill loader — they are on-demand context for deeper explanations or human reading.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| [check-explanations.md](check-explanations.md) | ~1800 | Full 5-part explanations (What / How to spot / Example / Fix / Related checks) for all 56 A-checks, plus Quick Reference table |
| [concepts.md](concepts.md) | ~450 | Background concepts: symmetric vs asymmetric encryption, public/private keys, algorithm reference table, SQL Server key hierarchy, TLS version history, encryption type comparison, CA trust concepts, FIPS 140-2, PCI-DSS, HIPAA, GDPR |

## When to Load These

- **check-explanations.md** — Load when a user asks "explain check A5" or "how do I fix the TDE certificate rotation?" or wants deeper context on a specific finding. Read the relevant check section, not the whole file.
- **concepts.md** — Load when a user asks background questions like "what is TDE?", "what's the difference between AES_128 and AES_256?", "what does PCI-DSS require for SQL Server encryption?", or when a finding needs regulatory context explained.

## Check Categories (A1–A56)

| Range | Category | Count |
|-------|----------|-------|
| A1–A8 | TDE (Transparent Data Encryption) | 8 |
| A9–A16 | Always Encrypted | 8 |
| A17–A21 | Cell-Level Encryption (CLE) | 5 |
| A22–A25 | Backup Encryption | 4 |
| A26–A30 | Transport / Connection Encryption | 5 |
| A31–A38 | Certificate Management | 8 |
| A39–A43 | Asymmetric & Symmetric Key Management | 5 |
| A44–A48 | Key Hierarchy (DMK / SMK) | 5 |
| A49–A52 | EKM / Azure Key Vault | 4 |
| A53–A56 | Compliance & Coverage | 4 |
| **Total** | | **56** |
