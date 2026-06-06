# sqlencryption-review — Reference Files

Reference materials for the `sqlencryption-review` skill. These files are **not** loaded at runtime by the skill loader — they are on-demand context for deeper explanations or human reading.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| [check-explanations.md](check-explanations.md) | ~2100 | Full 5-part explanations (What / How to spot / Example / Fix / Related checks) for all 80 A-checks, plus Quick Reference table |
| [concepts.md](concepts.md) | ~600 | Background concepts: symmetric vs asymmetric encryption, public/private keys, algorithm reference table, SQL Server key hierarchy, TLS version/cipher suite deep dive, encryption type comparison, CA trust concepts, FIPS 140-2, PCI-DSS, HIPAA, GDPR, SOX, FedRAMP, ISO 27001, TDE performance, DR with encryption, SQL Ledger concepts |
| [howto-tde-setup.md](howto-tde-setup.md) | ~150 | Step-by-step: TDE deployment from scratch — cert creation, DEK, enabling encryption, monitoring scan, cert backup, restore procedure |
| [howto-always-encrypted.md](howto-always-encrypted.md) | ~200 | Step-by-step: AE setup — CMK creation (AKV/Windows), CEK, column encryption, application changes, enclave setup and attestation |
| [howto-tls-config.md](howto-tls-config.md) | ~150 | Step-by-step: TLS 1.2/1.3 config — certificate request from CA, binding, ForceEncryption, cipher suite ordering, verification with OpenSSL/nmap |
| [howto-key-rotation.md](howto-key-rotation.md) | ~150 | Step-by-step: certificate, CEK, CMK, DMK, and SMK rotation procedures with zero-downtime patterns |
| [howto-crypto-shredding.md](howto-crypto-shredding.md) | ~120 | Step-by-step: GDPR right-to-erasure via per-customer encryption keys, implementation pattern, verification |
| [howto-disaster-recovery.md](howto-disaster-recovery.md) | ~150 | Step-by-step: restoring encrypted databases to new servers, certificate portability, cross-server restore scenarios |
| [error-reference.md](error-reference.md) | ~100 | Common encryption error messages (Msg 33111, 33104, etc.) with resolution steps |

## When to Load These

- **check-explanations.md** — Load when a user asks "explain check A5" or "how do I fix the TDE certificate rotation?" or wants deeper context on a specific finding. Read the relevant check section, not the whole file.
- **concepts.md** — Load when a user asks background questions like "what is TDE?", "what's the difference between AES_128 and AES_256?", "what does PCI-DSS require for SQL Server encryption?", or when a finding needs regulatory context explained.
- **howto-*.md** — Load when a user asks for step-by-step operational procedures: "how do I set up TDE?", "how do I configure TLS 1.2?", "how do I rotate keys?", "how do I implement crypto-shredding for GDPR?"
- **error-reference.md** — Load when a user reports a specific encryption error message and needs resolution steps.

## Check Categories (A1–A80)

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
| A57–A62 | TLS & Network Encryption Hardening | 6 |
| A63–A67 | Always Encrypted Advanced | 5 |
| A68–A72 | Operational Key Lifecycle | 5 |
| A73–A76 | SQL Server Ledger | 4 |
| A77–A80 | Azure-Specific Encryption | 4 |
| **Total** | | **80** |
