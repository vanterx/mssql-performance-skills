# sqlencryption-review — Reference Files

Reference materials for the `sqlencryption-review` skill. These files are **not** loaded at runtime by the skill loader — they are on-demand context for deeper explanations or human reading.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| [check-explanations.md](check-explanations.md) | ~2800 | Full 5-part explanations (What / How to spot / Example / Fix / Related checks) for all 112 A-checks, plus Quick Reference table |
| [concepts.md](concepts.md) | ~1200 | Background concepts: symmetric vs asymmetric encryption, public/private keys, algorithm reference table, SQL Server key hierarchy, TLS version/cipher suite deep dive, encryption type comparison, CA trust concepts, FIPS 140-2, PCI-DSS, HIPAA, GDPR, SOX, FedRAMP, ISO 27001, TDE performance, DR with encryption, AE performance, SQL Ledger concepts, DMK password auto-open (sp_control_dbmasterkey_password), passphrase-based encryption (PBKDF1 vs PBKDF2), DDM vs encryption |
| [howto-tde-setup.md](howto-tde-setup.md) | ~200 | Step-by-step: TDE deployment from scratch — cert creation, DEK, enabling encryption, monitoring scan, cert backup, restore procedure |
| [howto-always-encrypted.md](howto-always-encrypted.md) | ~350 | Step-by-step: AE setup — CMK creation (AKV/Windows), CEK, column encryption, application changes, enclave setup and attestation |
| [howto-tls-config.md](howto-tls-config.md) | ~180 | Step-by-step: TLS 1.2/1.3 config — certificate request from CA, binding, ForceEncryption, cipher suite ordering, verification |
| [howto-key-rotation.md](howto-key-rotation.md) | ~190 | Step-by-step: certificate, CEK, CMK, DMK, and SMK rotation procedures with zero-downtime patterns |
| [howto-crypto-shredding.md](howto-crypto-shredding.md) | ~120 | Step-by-step: GDPR right-to-erasure via per-customer encryption keys, implementation pattern, verification |
| [howto-disaster-recovery.md](howto-disaster-recovery.md) | ~170 | Step-by-step: restoring encrypted databases to new servers, certificate portability, cross-server restore scenarios |
| [howto-dmk-password-management.md](howto-dmk-password-management.md) | ~200 | Step-by-step: sp_control_dbmasterkey_password — SSISDB setup, cross-server restore, AG replica registration, SMK restore invalidation, monitoring |
| [howto-dynamic-data-masking.md](howto-dynamic-data-masking.md) | ~160 | Decision guide: DDM vs encryption, mask types, UNMASK permission, interaction with AE/CLE, DDM + RLS patterns |
| [howto-agent-jobs.md](howto-agent-jobs.md) | ~200 | Secure SQL Agent job patterns: certificate-based key opens, proxy credentials, TRY/CATCH key cleanup, alerts, job audit queries |
| [error-reference.md](error-reference.md) | ~230 | Common encryption error messages (Msg 33111, 33104, 15581, 33081, TLS, EKM, enclave) with resolution steps |

## When to Load These

- **check-explanations.md** — Load when a user asks "explain check A-N" or wants T-SQL examples for a specific finding. Read the relevant section, not the whole file.
- **concepts.md** — Load for background questions: "what is TDE?", "how does sp_control_dbmasterkey_password work?", "what does PCI-DSS require?", "what is PBKDF1?", "when should I use DDM vs encryption?"
- **howto-dmk-password-management.md** — Load when SSISDB or non-SMK DMK issues arise (A81–A86), or for cross-server restore / AG failover DMK scenarios.
- **howto-dynamic-data-masking.md** — Load when A87/A88/A90/A91 fire, or when the user asks about DDM setup, UNMASK permission, or the difference between masking and encryption.
- **howto-agent-jobs.md** — Load when A99/A100 fire (job step passwords), or when the user asks about secure patterns for SQL Agent jobs that use encryption.
- Other howto files — Load when the user asks for step-by-step operational procedures matching that topic.

## Check Categories (A1–A112)

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
| A81–A86 | DMK Password Auto-Open | 6 |
| A87–A91 | Dynamic Data Masking & Permission Patterns | 5 |
| A92–A98 | Compliance Explicit Checks | 7 |
| A99–A104 | Operational Validation | 6 |
| A105–A112 | Advanced Cryptographic Patterns | 8 |
| **Total** | | **112** |
