# SQL Server Encryption — Concepts Reference (19 Topics)

This document provides background knowledge for the `sqlencryption-review` skill across 19 topics — from symmetric vs. asymmetric encryption, key hierarchy, and algorithm selection through TDE, Always Encrypted, TLS, backup encryption, and compliance frameworks (PCI-DSS, HIPAA, GDPR, SOX, FedRAMP, ISO 27001) to TDE performance monitoring, disaster recovery, TLS cipher suites, AE performance, SQL Server Ledger, and additional compliance frameworks. Load it when a user asks "what is TDE?", "explain the difference between AE and CLE", "what TLS version should I use?", "what does GDPR require for encryption?", or any conceptual question about SQL Server cryptography.

---

## 1. Symmetric vs. Asymmetric Encryption

### Symmetric Encryption

A single shared secret key is used both to encrypt plaintext into ciphertext and to decrypt ciphertext back to plaintext. The same key must be known to both the encryptor and the decryptor.

**Properties:**
- Very fast — hardware AES acceleration (AES-NI) makes symmetric encryption essentially free in terms of CPU cost for modern workloads
- The core problem is *key distribution*: how do you securely share the key with the party who needs to decrypt without an attacker intercepting it?
- Used in SQL Server for: TDE Database Encryption Keys, Always Encrypted Column Encryption Keys (the data itself), Cell-Level Encryption symmetric keys, backup encryption

### Asymmetric Encryption (Public-Key Cryptography)

A mathematically linked key *pair*: a public key and a private key. Data encrypted with the public key can only be decrypted with the paired private key. Data signed with the private key can be verified with the public key.

**Properties:**
- Solves the key-distribution problem: the public key can be shared freely; only the private key holder can decrypt
- Much slower than symmetric encryption (thousands of times); impractical for bulk data encryption
- Used in SQL Server to *protect* symmetric keys: a symmetric key is encrypted by an asymmetric key; the asymmetric key's private key is stored securely (HSM, AKV, certificate store)
- Used for digital signatures: stored procedures signed with a certificate to grant elevated permissions; Service Broker / AG endpoint authentication

### Hybrid Encryption (How Real-World Systems Work)

SQL Server (and TLS, and PGP, and nearly every real-world system) uses a hybrid approach:

1. Asymmetric key (slow, strong security) wraps / protects a symmetric key
2. Symmetric key (fast) encrypts the actual data

Example with TDE:
```
Service Master Key (symmetric, protected by Windows DPAPI)
  → protects → Database Master Key (symmetric)
    → protects → TDE Certificate private key
      → protects → Database Encryption Key (symmetric, AES_256)
        → encrypts → Database pages on disk
```

The TDE DEK is an AES key (fast); it is protected by an asymmetric certificate key (slow, but only used when the DEK needs to be opened at startup).

---

## 2. Public Keys, Private Keys, and Certificates

### Public / Private Key Pair

- **Private key**: known only to the owner; must be kept secret; used to decrypt and to sign
- **Public key**: freely shareable; used to encrypt (so only the private key holder can read it) and to verify signatures

### What Is a Certificate?

A certificate is a public key *with a stamp of approval*. Specifically:
- Contains: the public key, the subject's identity (name, organization), the issuer's identity (who approved this), validity dates, intended use (key usage extensions)
- Signed by: a Certificate Authority (CA) using the CA's private key
- Verified by: anyone with the CA's public key (or a trusted root certificate)

Without a certificate, you cannot tell whether a public key belongs to who you think it does. A certificate binds an identity to a public key and has a third party (the CA) vouch for that binding.

### Self-Signed vs. CA-Issued Certificates

| Property | Self-Signed | CA-Issued |
|----------|-------------|-----------|
| Who signs it? | The certificate itself (issuer = subject) | A trusted Certificate Authority |
| Chain of trust | None — each party must individually trust it | Validates via root CA chain |
| Use case | Development, internal SQL objects (TDE, CLE) | Production TLS, Service Broker across untrusted networks |
| Risk | MITM attacks; must use TrustServerCertificate=True for TLS | None if CA is trusted; revocation supported |

### Certificate Expiry

Certificates have a `NotBefore` and `NotAfter` (expiry) date embedded in them. After the expiry date:
- A TLS certificate causes connection failures or TrustServerCertificate bypass
- A TDE certificate, if expired, does *not* prevent decryption of an already-open database; SQL Server reads the DEK once at startup and doesn't re-check cert expiry during operation — but restoring a backup to a new server requires the cert to be importable
- An Always Encrypted CMK expiry has no enforcement in SQL Server itself; but compliance policies and manual rotation schedules should use expiry as a rotation trigger

---

## 3. SQL Server Encryption Algorithm Reference

### Symmetric Algorithms (used for bulk data and key wrapping)

| Algorithm | Key size | Security status | Notes |
|-----------|----------|----------------|-------|
| AES_128 | 128 bit | Current — acceptable | Minimum for PCI-DSS v4; FIPS approved |
| AES_192 | 192 bit | Current — good | FIPS approved; rarely used in practice |
| AES_256 | 256 bit | Current — recommended | Strongest; required by many compliance frameworks |
| TRIPLE_DES (3DES) | 168 bit effective | Deprecated (NIST 2023) | NIST SP 800-131A prohibits 3DES after 2023; PCI-DSS v4 disallows |
| DES | 56 bit | Broken | Brute-forceable; do not use |
| DESX | 128 bit (with whitening) | Deprecated | Proprietary variant; not standardized |
| RC4 / RC4_128 | variable | Broken | WEP attacks, RC4-NOMORE; do not use for any purpose |
| RC2 | variable | Broken | Small-key differential cryptanalysis; do not use |

### Asymmetric Algorithms (used for key wrapping and signatures)

| Algorithm | Key size | Security status | Notes |
|-----------|----------|----------------|-------|
| RSA_512 | 512 bit | Broken | Factorable in hours with modest resources |
| RSA_1024 | 1024 bit | Deprecated | NIST prohibited after 2013; CAs stopped issuing 2013 |
| RSA_2048 | 2048 bit | Current minimum | NIST approved through 2030 |
| RSA_3072 | 3072 bit | Current — good | NIST approved through 2040 |
| RSA_4096 | 4096 bit | Current — strong | Performance overhead; use for long-lived CMKs |

### Hash / Signature Algorithms (used in certificates and HASHBYTES)

| Algorithm | Status | Notes |
|-----------|--------|-------|
| MD5 | Broken | Collision attacks demonstrated (Flame malware); never use for certificates or integrity checks |
| SHA1 | Deprecated | SHA1 collision demonstrated (SHAttered, 2017); Microsoft/CA Browser Forum deprecated 2016 |
| SHA256 | Current — recommended | Minimum for new certificate issuance; FIPS approved |
| SHA384 | Current — good | FIPS approved; used in Suite B / NSA Suite B |
| SHA512 | Current | FIPS approved; slight overhead vs SHA256 |

### Always Encrypted Column Algorithm

`AEAD_AES_256_CBC_HMAC_SHA_256` — the only algorithm used for column data in Always Encrypted. It combines:
- AES_256 in CBC mode for encryption
- HMAC-SHA-256 for authentication (prevents ciphertext manipulation)
- The "AEAD" stands for Authenticated Encryption with Associated Data

CEK values in `sys.column_encryption_key_values` are protected using `RSA_OAEP` asymmetric encryption under the Column Master Key.

---

## 4. SQL Server Key Hierarchy

The key hierarchy defines how keys protect each other. Understanding it is essential to understanding what breaks when a key is lost or compromised.

```
┌────────────────────────────────────────────────────────────┐
│  INSTANCE LEVEL                                            │
│                                                            │
│  Service Master Key (SMK)                                  │
│  ├── Protected by: Windows DPAPI + machine key             │
│  ├── Protects: Database Master Keys in all databases       │
│  └── Protects: Linked server passwords, proxy accounts     │
│                                                            │
└────────────────────────────────────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────────────────────┐
│  DATABASE LEVEL                                            │
│                                                            │
│  Database Master Key (DMK)                                 │
│  ├── Protected by: SMK (automatic) + optional password     │
│  ├── Protects: Certificates' private keys                  │
│  ├── Protects: Asymmetric keys' private keys               │
│  └── Protects: Symmetric keys (when encrypted by DMK)     │
│                                                            │
│  Certificates (public/private key pairs)                   │
│  ├── Protected by: DMK (most common)                       │
│  ├── Used for: TDE DEK encryption, Service Broker auth,   │
│  │             AG endpoint auth, backup encryption,        │
│  │             code signing (EXECUTE AS), CLE              │
│                                                            │
│  Asymmetric Keys                                           │
│  ├── Protected by: DMK or EKM provider                     │
│  └── Used for: CLE, Always Encrypted CMK (in-DB),         │
│               EKM-backed TDE                               │
│                                                            │
│  Symmetric Keys                                            │
│  ├── Protected by: certificate, asymmetric key, or         │
│  │                  password, or DMK directly              │
│  └── Used for: Cell-Level Encryption (ENCRYPTBYKEY)       │
│                                                            │
└────────────────────────────────────────────────────────────┘
               │ (TDE-specific path)
               ▼
┌────────────────────────────────────────────────────────────┐
│  DATABASE ENCRYPTION KEY (DEK)                             │
│  ├── Protected by: TDE certificate (asymmetric)            │
│  │                  OR EKM asymmetric key (AKV/HSM)        │
│  └── Encrypts: All database data files and log             │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  ALWAYS ENCRYPTED (CLIENT-SIDE HIERARCHY)                  │
│                                                            │
│  Column Master Key (CMK)                                   │
│  ├── Lives: Windows cert store, AKV, or HSM                │
│  ├── Never enters SQL Server                               │
│  └── Protects: Column Encryption Keys (CEKs)              │
│                                                            │
│  Column Encryption Key (CEK)                               │
│  ├── Stored encrypted in SQL Server                        │
│  │   (sys.column_encryption_key_values)                   │
│  ├── Decrypted client-side only                            │
│  └── Encrypts: Actual column values in transit             │
└────────────────────────────────────────────────────────────┘
```

**Key insight:** If the SMK is lost, the DMK cannot be automatically decrypted. If the DMK is lost, all certificates, asymmetric keys, and symmetric keys protected by it become inaccessible. This is why backups of the SMK (A47), DMK (A44), and TDE certificates (A3) are Critical findings.

---

## 5. TLS / Transport Encryption Versions

### TLS vs. SSL

SSL (Secure Sockets Layer) is the predecessor to TLS (Transport Layer Security). All SSL versions (2.0, 3.0) are broken and deprecated. When SQL Server documentation mentions "SSL", it means TLS in modern contexts.

### Version History and SQL Server Support

| Version | Year introduced | Security status | SQL Server support |
|---------|----------------|----------------|-------------------|
| SSL 2.0 | 1995 | Broken (DROWN, POODLE, BEAST) | Never properly supported; disabled by OS |
| SSL 3.0 | 1996 | Broken (POODLE attack 2014) | Must be disabled at OS level (registry) |
| TLS 1.0 | 1999 | Deprecated — prohibited by PCI-DSS v4 (2022) | Supported by all SQL Server versions; should be disabled |
| TLS 1.1 | 2006 | Deprecated — no protocol-level fixes for known weaknesses | Supported but should be disabled |
| TLS 1.2 | 2008 | Current minimum — widely supported | SQL 2012+ natively; SQL 2008/R2 requires patches; SQL 2014+ recommended |
| TLS 1.3 | 2018 | Preferred — improved handshake, forward secrecy mandatory | SQL Server 2022 on Windows Server 2022+ |

### How to Disable TLS 1.0 / 1.1 on Windows

SQL Server inherits the TLS settings from the Windows OS via the SChannel registry provider. To disable TLS 1.0:

```
HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server
  Enabled = 0 (DWORD)
  DisabledByDefault = 1 (DWORD)
```

Repeat for TLS 1.1. Requires server restart. Verify with Wireshark or `nmap --script ssl-enum-ciphers -p 1433 [host]`.

### PCI-DSS and TLS

PCI-DSS v3.2.1 required TLS 1.0 to be disabled for new implementations by June 2016 and for all cardholder data environments by June 2018. PCI-DSS v4.0 (effective March 2024) maintains this requirement and additionally specifies TLS 1.2 as the minimum version.

### Forward Secrecy

TLS 1.3 mandates Forward Secrecy (also called Perfect Forward Secrecy, PFS): each TLS session uses ephemeral key material, so compromising the server's long-term private key does not retroactively decrypt previously captured sessions. TLS 1.2 supports PFS via ECDHE cipher suites but does not mandate it.

---

## 6. SQL Server Encryption Type Comparison

Choosing the right encryption type for a given use case is one of the most important decisions in a SQL Server security design. The following table compares all major types:

| Property | TDE | Always Encrypted | Cell-Level (CLE) | Backup Encryption | Transport (TLS) |
|----------|-----|-----------------|-----------------|------------------|----------------|
| What is encrypted | Database files at rest | Specific column values | Specific cell values | Backup files | Data in transit |
| Granularity | Whole database | Per column | Per cell/row | Per backup | Per connection |
| Key lives where | SQL Server (master DB) | Client (AKV, HSM, Windows cert store) | SQL Server (key hierarchy) | SQL Server (master DB cert) | Windows cert store |
| SQL Server can read plaintext | Yes — DBA has key access | No — SQL Server never sees plaintext | Yes — key is in the DB | N/A (backup-only) | N/A (transport) |
| Protects against | Stolen disk/file, offline backup theft | DBA insider threat, cloud provider, backup theft | Targeted column access (limited DBA protection) | Stolen backup media | Network interception |
| Performance impact | Very low (hardware AES-NI) | Medium (client-side crypto, query restrictions) | Medium (T-SQL function overhead per row) | Low (backup-time only) | Very low (modern TLS) |
| Query capability | Full SQL | Limited: equality with deterministic, ranges with enclave | Full SQL (after decrypting client-side, or via key access) | N/A | N/A |
| SQL Server version | 2008+ | 2016+ (enclave: 2019+) | 2005+ | 2014+ | 2008+ |
| Azure SQL | Yes (default enabled) | Yes | Yes | Yes | Yes (enforced) |
| PCI-DSS relevance | Satisfies storage protection (with caveats) | Best for PAN/CVV protection | Acceptable for some PCI data | Required for off-site backups | Required for all cardholder data environments |

### When to Use Each

- **TDE**: Use as a baseline for all production databases. Protects against physical disk theft and backup file theft. Does not protect against a compromised DBA or an application-level SQL injection.
- **Always Encrypted**: Use when the application requires that even DBAs cannot read the data (GDPR, high-value PII). Requires application code changes. Use for SSN, credit card numbers, passwords, and similar fields.
- **CLE**: Use for legacy compatibility or when AE is not feasible (older SQL Server versions, complex stored procedure workflows). Weaker than AE because decryption happens server-side.
- **Backup Encryption**: Use on every backup to ensure backup media (tape, USB, cloud storage) cannot be read without the certificate. Layer on top of TDE, not instead of it.
- **TLS**: Enforce for all production SQL Server connections. Required for PCI-DSS. Prevents credential sniffing and data interception.

---

## 7. Certificate Authority (CA) Concepts

### Root CA, Intermediate CA, and End-Entity Certificates

```
Root CA (self-signed, stored in "Trusted Root Certification Authorities")
  └── Intermediate CA (signed by Root CA)
        └── End-entity certificate (signed by Intermediate CA)
              ├── SQL Server TLS certificate
              ├── Client authentication certificate
              └── Code-signing certificate
```

The chain of trust works as follows: a client trusts the Root CA (it is pre-installed in the OS or deployed via Group Policy). The client can verify the Intermediate CA's certificate because it is signed by the Root CA. The client can verify the end-entity certificate because it is signed by the Intermediate CA.

### CRL and OCSP (Certificate Revocation)

If a certificate is compromised before its expiry date, the CA can revoke it. Clients check whether a certificate has been revoked via:

- **CRL (Certificate Revocation List)**: a periodically published list of revoked serial numbers; clients download and cache the CRL
- **OCSP (Online Certificate Status Protocol)**: a real-time protocol to check a single certificate's revocation status; faster and more current than CRL

SQL Server does not perform CRL/OCSP checks on TDE or CLE certificates; this is a limitation for self-managed certificates.

### Internal CA vs. Public CA

| Property | Internal CA (AD CS) | Public CA (DigiCert, etc.) |
|----------|--------------------|-----------------------------|
| Cost | Low (Windows Server license) | Per-certificate fee |
| Browser/OS trust | Internal machines only (via Group Policy) | All mainstream OS/browsers |
| Use case | Internal SQL Server TLS, Service Broker | External-facing connections, strict compliance requirements |
| Revocation | Internal CRL/OCSP | Public CRL/OCSP infrastructure |
| Setup complexity | Moderate | Low (online purchase) |

---

## 8. FIPS 140-2 Compliance

FIPS 140-2 (Federal Information Processing Standard) is the US government standard for cryptographic module security. Levels 1–4 indicate increasing strength of physical and logical security.

### What FIPS Means for SQL Server

When Windows is configured in FIPS-compliant mode (`Computer Configuration → Windows Settings → Security Settings → Local Policies → Security Options → System cryptography: Use FIPS compliant algorithms for encryption, hashing, and signing = Enabled`):

- SQL Server will refuse to use non-FIPS algorithms
- RC4 and DES are immediately blocked
- MD5 may be blocked depending on how it is used
- AES_128, AES_192, AES_256, RSA_2048+, SHA256+ are FIPS approved

### Non-FIPS Algorithms to Remove

| Algorithm | FIPS approved? | Action |
|-----------|---------------|--------|
| AES_256 | Yes | Keep; preferred |
| AES_128 | Yes | Acceptable; upgrade to AES_256 for compliance |
| TRIPLE_DES_3KEY | No (deprecated) | Replace with AES_256 |
| DES / DESX | No (broken) | Replace immediately |
| RC4 | No (broken) | Replace immediately |
| RSA_2048 | Yes | Keep; preferred minimum |
| RSA_1024 | No (deprecated) | Replace with RSA_2048 |
| SHA256 | Yes | Keep; preferred |
| SHA1 | No (deprecated) | Replace with SHA256 |
| MD5 | No (broken) | Replace with SHA256 |

---

## 9. PCI-DSS Encryption Requirements

PCI-DSS (Payment Card Industry Data Security Standard) applies to any system that stores, processes, or transmits cardholder data (CHD): Primary Account Numbers (PAN), cardholder name when stored with PAN, expiration date when stored with PAN, service code when stored with PAN, and Sensitive Authentication Data (SAD): full magnetic-stripe data, CAV2/CVC2/CVV2/CID, PINs.

### Relevant SQL Server Requirements (PCI-DSS v4.0)

**Requirement 3 — Protect Stored Account Data**

| Sub-requirement | What it means | SQL Server mapping |
|----------------|--------------|-------------------|
| 3.3.1 | SAD (CVV, PIN, full mag stripe) must never be stored after authorization, even encrypted | Delete SAD columns entirely; verify with column search |
| 3.4.1 | PAN must be unreadable anywhere stored; acceptable methods: one-way hash, truncation, index tokens, strong cryptography | Always Encrypted (preferred for PAN) or TDE + additional column protection; TDE alone does NOT satisfy this if DBAs have full access |
| 3.5.1 | Key management procedures documented: key custodians, purpose, activation/expiry dates | Document in DBA runbook: all keys, certs, owners, rotation schedule |
| 3.7.1 | Key rotation: as required by associated vendor (minimum annually for PAN-protecting keys) | Annual `ALTER COLUMN ENCRYPTION KEY` rotation; SQL Agent job |
| 3.7.3 | Key retirement/replacement at end of cryptoperiod | Documented key retirement procedure; `DROP SYMMETRIC KEY` after re-encryption |
| 3.7.6 | Manual clear-text key operations use split knowledge / dual control | Two-person procedure for any manual key export; secrets management vault |

**Requirement 4 — Protect Cardholder Data in Transit**

| Sub-requirement | SQL Server mapping |
|----------------|-------------------|
| 4.2.1 — Strong cryptography for all CHD in transit | ForceEncryption = Yes; TLS 1.2 minimum; disable TLS 1.0/1.1; AES_128+ cipher suites |
| 4.2.1.1 — Inventory all trusted keys/certificates | Maintain certificate inventory: name, purpose, expiry, owner |
| 4.2.1.2 — Failure to detect invalid certificates = fail | Remove TrustServerCertificate=True from all connection strings |

**Requirement 10 — Log and Monitor**

| Sub-requirement | SQL Server mapping |
|----------------|-------------------|
| 10.2.2 — Log all access to audit logs | SQL Server Audit on `sys.fn_get_audit_file` access |
| 10.2.7 — Log creation/deletion of cryptographic objects | SQL Audit with `SCHEMA_OBJECT_ACCESS_GROUP` on key/cert objects |

**Algorithm Requirements (PCI-DSS v4.0)**

| Requirement | Minimum | Preferred |
|-------------|---------|-----------|
| Symmetric encryption | AES_128 | AES_256 |
| Asymmetric key length | RSA_2048 | RSA_2048 or higher |
| Hashing | SHA-256 | SHA-256 or higher |
| Transport protocol | TLS 1.2 | TLS 1.2 or 1.3 |
| Prohibited | RC4, DES, 3DES, SSL, TLS < 1.2, MD5, SHA1 for cert signatures | — |

---

## 10. HIPAA Encryption Requirements

HIPAA (Health Insurance Portability and Accountability Act) applies to Covered Entities (healthcare providers, health plans, healthcare clearinghouses) and their Business Associates handling Protected Health Information (PHI): any individually identifiable health information.

HIPAA Security Rule uses the concept of **addressable** vs **required** safeguards. "Addressable" means the safeguard must be implemented if it is reasonable and appropriate; if not, the organization must document why not and implement an equivalent alternative. In practice, encryption is expected for all PHI databases.

### Relevant SQL Server Safeguards

**45 CFR §164.312(a)(2)(iv) — Encryption and Decryption (Addressable)**

> "Implement a mechanism to encrypt and decrypt electronic protected health information."

Interpretation: Encrypt PHI at rest (TDE + column-level for sensitive fields) and in transit (TLS). Document the decision if a specific column is not encrypted and explain the compensating control.

**45 CFR §164.312(e)(2)(ii) — Encryption in Transit (Addressable)**

> "Implement a mechanism to encrypt electronic protected health information whenever deemed appropriate."

Interpretation: TLS for all SQL Server connections carrying PHI; ForceEncryption = Yes; disable legacy TLS versions.

**45 CFR §164.312(b) — Audit Controls (Required)**

> "Implement hardware, software, and/or procedural mechanisms that record and examine activity in information systems that contain or use electronic protected health information."

SQL Server mapping: SQL Server Audit on SELECT/INSERT/UPDATE/DELETE on PHI tables; log key access events; retain audit logs for 6 years (HIPAA retention).

**45 CFR §164.312(c)(1) — Integrity Controls (Required)**

Digital signatures and HASHBYTES can be used to verify that PHI has not been tampered with in transit; SIGNBYCERT / VERIFYSIGNEDBYCERT for stored procedure integrity.

### HIPAA Key Management Expectations

HIPAA does not mandate specific algorithms but expects a reasonable and appropriate level of protection consistent with industry standards. NIST SP 800-111 (Guide to Storage Encryption for End User Devices) and NIST SP 800-52 (TLS guidelines) are the referenced standards:

- AES_256 for data at rest
- TLS 1.2+ for data in transit
- Annual key rotation for encryption keys protecting PHI
- Documented key management procedures
- Key custodians identified and trained

### Business Associate Agreements (BAAs)

If PHI is stored in Azure SQL or another cloud SQL service, a Business Associate Agreement (BAA) with the cloud provider is required under HIPAA. Microsoft Azure has a standard BAA that covers Azure SQL. Using a service-managed TDE key (A51) is acceptable under the Azure BAA, but organizations with stricter interpretations use BYOK (customer-managed keys) for data sovereignty.

---

## 11. GDPR Encryption Requirements

GDPR (General Data Protection Regulation) applies to any organization processing personal data of EU/EEA residents, regardless of where the organization is located. Personal data includes any information relating to an identified or identifiable natural person: names, email addresses, IP addresses, location data, ID numbers, health data, financial data.

### Article 25 — Data Protection by Design and Default

> "the controller shall… implement appropriate technical and organisational measures… such as pseudonymisation, which are designed to implement data-protection principles… in an effective manner."

SQL Server mapping: encryption and pseudonymisation (replacing PII with tokens) should be designed into the data model from the start, not added later. Always Encrypted enforces data minimisation at the engine level.

### Article 32 — Security of Processing

> "Taking into account the state of the art… the controller and the processor shall implement appropriate technical and organisational measures to ensure a level of security appropriate to the risk, including as appropriate: (a) the pseudonymisation and encryption of personal data."

This is the primary GDPR basis for SQL Server encryption. "Appropriate to the risk" means the more sensitive the data (health data, financial data, special categories under Article 9) and the more people affected, the stronger the required measures.

### Article 5(1)(f) — Integrity and Confidentiality

> Personal data shall be "processed in a manner that ensures appropriate security of the personal data, including protection against unauthorised or unlawful processing and against accidental loss, destruction or damage, using appropriate technical or organisational measures."

SQL Server mapping: TDE (protection against physical loss), TLS (unauthorised access in transit), SQL Audit (detection of unlawful access), Always Encrypted (protection against insider threats).

### Article 33 / 34 — Breach Notification

Under GDPR, a data breach must be reported to the supervisory authority within 72 hours (Article 33). However, if the data was encrypted, the notification obligation to affected individuals (Article 34) may be waived:

> Article 34(3)(a): Notification to individuals is not required if "the controller has implemented appropriate technical and organisational protection measures, and those measures were applied to the personal data affected by the personal data breach, in particular those that render the personal data unintelligible to any person who is not authorised to access it, such as encryption."

This is the strongest business case for column-level encryption: a breach of encrypted data does not trigger individual notification if the keys were not also compromised.

### Article 17 — Right to Erasure ("Right to Be Forgotten")

GDPR gives data subjects the right to have their personal data erased. In distributed systems (data lakes, replicated SQL databases, backups), complete erasure is technically difficult. **Cryptographic erasure** (crypto-shredding) is an accepted approach:

1. Encrypt each data subject's records with a unique per-subject encryption key
2. When erasure is requested, delete the encryption key
3. The records still exist in storage but are permanently unreadable

SQL Server implementation: use CLE with a per-customer symmetric key; when a customer requests erasure, drop their key and its encrypted data becomes permanently inaccessible. Document this procedure in the privacy policy.

### Special Categories of Data (Article 9)

GDPR provides stronger protections for special categories of personal data, which require explicit consent and a higher security bar:
- Health and genetic data
- Biometric data
- Racial or ethnic origin
- Political opinions
- Religious or philosophical beliefs
- Trade union membership
- Sexual orientation

SQL Server mapping: columns containing any of these data types should be both encrypted (Always Encrypted or CLE) and classified (`sys.sensitivity_classifications`).

### Compliance Summary Table

| Requirement | PCI-DSS v4 | HIPAA | GDPR |
|-------------|-----------|-------|------|
| Encryption at rest (required) | Mandatory for PAN | Addressable (effectively required) | Required (proportional to risk) |
| Encryption in transit | Mandatory (TLS 1.2+) | Addressable (TLS 1.2 expected) | Required ("appropriate measures") |
| Algorithm minimum | AES_128+, no RC4/3DES/TLS<1.2 | AES recommended; no specific mandate | No specific mandate; AES_256 best practice |
| Key rotation | Annually for PAN keys (Req 3.7) | Documented procedures | Periodic review |
| Audit logging | Required (Req 10) | Required (§164.312(b)) | Required (Art. 5(1)(f) accountability) |
| Breach impact of encryption | Reduces scope (encrypted systems may be out of scope) | Reduces notification risk | May eliminate individual notification duty |
| Customer-managed keys | Not required | Not required | Supports data sovereignty / right to erasure |
| Data classification | Required (PAN inventory) | PHI inventory required | Personal data mapping required |
| Right to erasure support | N/A | N/A | Required — crypto-shredding is a valid approach |

---

## 12. TDE Performance and Monitoring

### Encryption Scan Performance

When TDE is enabled on a database, SQL Server reads every page, encrypts it, and writes it back. This is an online operation — the database remains available — but it generates significant I/O during the scan.

| Storage type | Typical scan rate | Notes |
|-------------|------------------|-------|
| Enterprise SSD (NVMe) | 150–200 MB/s | Limited by CPU or storage throughput |
| Enterprise SSD (SATA) | 80–130 MB/s | Storage throughput is usually the bottleneck |
| Premium SAN | 70–150 MB/s | Varies by LUN configuration and contention |
| Standard HDD | 30–60 MB/s | Long scans — schedule carefully |

The scan rate is constrained by the slower of storage throughput and the encryption CPU cost. On modern CPUs with AES-NI acceleration, encryption is rarely the bottleneck — storage I/O is.

### AES-NI Hardware Acceleration

AES-NI (Advanced Encryption Standard New Instructions) is a set of CPU instructions present on Intel Westmere (2010) and AMD Bulldozer (2011) processors onward. When SQL Server uses AES encryption for TDE, the cryptographic operations are offloaded to dedicated hardware circuits rather than computed in software.

In practice, AES-NI reduces the CPU overhead of AES-256 TDE to approximately **2–5%** of total CPU for typical OLTP workloads. Without AES-NI (very old hardware or VMs without passthrough), the overhead can be 15–30%.

To verify AES-NI support:

```sql
-- Check if AES-NI is available (via sys.dm_os_sys_info)
-- Not directly exposed; infer from CPU model
SELECT cpu_count, hyperthread_ratio, cpu_name
FROM sys.dm_os_sys_info;

-- On Windows, verify via PowerShell:
-- Get-WmiObject -Class Win32_Processor | Select-Object Name, *AES*
```

### Monitoring Scan Progress

The `sys.dm_database_encryption_keys` DMV exposes the `percent_complete` and `encryption_state` columns for each database:

```sql
SELECT
    DB_NAME(database_id) AS database_name,
    encryption_state,
    percent_complete,
    key_algorithm,
    key_length
FROM sys.dm_database_encryption_keys;
```

| encryption_state | Description |
|-----------------|-------------|
| 0 | No database encryption key present |
| 1 | Unencrypted |
| 2 | Encryption in progress |
| 3 | Encrypted |
| 4 | Key change in progress |
| 5 | Decryption in progress |
| 6 | Protection change in progress |

For large databases (1 TB+), encryption scans can take hours. The `percent_complete` value increments as the scan progresses; monitor it via a SQL Agent job that logs progress every 5 minutes during a planned encryption window.

### TempDB Encryption Overhead

Starting with SQL Server 2016, TempDB is automatically encrypted when **any** user database on the instance has TDE enabled. This has performance implications:

- All sort operations, hash joins, and spills that use TempDB now perform encryption and decryption on every TempDB page written and read
- The CPU overhead is small (~2–5% with AES-NI) but the additional I/O from encrypted TempDB pages can increase latency on already-contended TempDB data files
- TempDB log write volume increases because encrypted pages produce slightly larger log records
- If TDE is disabled on all user databases, TempDB encryption is removed after a restart

### Controlling the Scan (SQL 2019+)

SQL Server 2019 introduced the ability to suspend and resume the TDE encryption scan:

```sql
-- Pause the scan (e.g., during peak hours)
ALTER DATABASE MyDB SET ENCRYPTION SUSPEND;

-- Resume the scan (e.g., during maintenance window)
ALTER DATABASE MyDB SET ENCRYPTION RESUME;
```

This is useful when the initial scan generates enough I/O to affect production workloads. A common pattern: resume the scan at 8 PM, suspend at 6 AM, repeat until complete.

### Performance Monitor Counters

| Counter | What it measures | Significance |
|---------|-----------------|--------------|
| `SQLServer:Databases\Log Bytes Flushed/sec` | Log write throughput for each database | Spikes during TDE scan due to encryption log records |
| `SQLServer:Database Replica\Log Bytes Received/sec` | AG log transport throughput | Secondary replicas process encrypted log blocks; monitor for lag |
| `SQLServer:Buffer Manager\Page lookups/sec` | Buffer pool read activity | Increases during TDE scan as pages are read for re-encryption |
| `PhysicalDisk\Avg. Disk sec/Read` | I/O read latency | Should stay under 20ms; spikes may indicate scan contention |
| `PhysicalDisk\Avg. Disk sec/Write` | I/O write latency | Should stay under 20ms; write-heavy during scan |

### I/O Stall Metrics During Scan

The `sys.dm_io_virtual_file_stats` DMV shows cumulative I/O stall time for each database file. Before and during a TDE scan, capture snapshots to detect scan-induced I/O pressure:

```sql
SELECT
    DB_NAME(database_id) AS db_name,
    file_id,
    num_of_reads,
    num_of_writes,
    io_stall_read_ms,
    io_stall_write_ms,
    size_on_disk_bytes / 1024 / 1024 AS size_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL)
WHERE database_id > 4;
```

A sharp increase in `io_stall_write_ms` during the scan period indicates that the storage subsystem is bottlenecked by the write load. If write stalls exceed 50ms per operation, consider suspending the scan and investigating storage performance.

### Best Practices

1. **Schedule the scan** during a planned maintenance window, not during peak hours
2. **Baseline I/O** before the scan using `sys.dm_io_virtual_file_stats` snapshots and PerfMon
3. **Use `SUSPEND` / `RESUME`** (SQL 2019+) to control scan timing across multiple maintenance windows
4. **Monitor `percent_complete`** to estimate completion time
5. **Verify AES-NI** is available on the host; if not, budget additional CPU headroom
6. **Consider TempDB impact**: if TempDB is heavily used, the encryption overhead on TempDB operations may be more noticeable than the scan itself

---

## 13. Encryption and Disaster Recovery

### What Must Be Backed Up

Losing encryption keys during a disaster recovery event is unrecoverable — no SQL Server support ticket or third-party tool can decrypt data without the keys. The following must be included in every disaster recovery backup set:

| Component | Where stored | Backup command | Consequence if lost |
|-----------|-------------|----------------|-------------------|
| Service Master Key (SMK) | Instance-level (master DB) | `BACKUP SERVICE MASTER KEY TO FILE = 'path' ENCRYPTION BY PASSWORD = 'strong_pwd'` | All DMKs unreadable; entire key hierarchy broken |
| Database Master Key (DMK) | Per-database | `BACKUP MASTER KEY TO FILE = 'path' ENCRYPTION BY PASSWORD = 'strong_pwd'` | Certificates and symmetric keys in that database inaccessible |
| TDE Certificate | master DB (instance-level effect) | `BACKUP CERTIFICATE TdeCert TO FILE = 'path' WITH PRIVATE KEY (FILE = 'key_path', ENCRYPTION BY PASSWORD = 'strong_pwd')` | TDE databases on restored server will not start |
| Backup Encryption Certificate | master DB | Same as TDE cert backup | Encrypted backups cannot be restored |
| Always Encrypted Column Master Key | Windows cert store or AKV/HSM | Export from source; import to target | CEKs cannot be decrypted; AE columns unreadable |

### Restore Sequence

When rebuilding a server from backups (disaster recovery or migration), the order is critical:

1. **Import the SMK** from backup using `RESTORE SERVICE MASTER KEY FROM FILE = 'path' DECRYPTION BY PASSWORD = 'strong_pwd'`
2. **Restore the master database** (which contains the TDE certificate, DMK references, and logins)
3. **Restore the user database** — the TDE certificate in the restored master database automatically decrypts the DEK
4. **Restore encrypted backups** using the backup encryption certificate
5. **Re-import AE Column Master Keys** to the Windows certificate store or AKV on the new server

If the master database is lost and no master backup is available, a new master database must be rebuilt and the SMK and TDE certificate manually imported before any TDE-encrypted user database can be attached or restored.

### Always On Availability Group Considerations

In an AG, TDE certificates must be **identical** across all replicas — same certificate body, same private key, same thumbprint. The process:

1. Enable TDE on the primary replica (creates the DEK protected by the TDE certificate)
2. Back up the TDE certificate (with private key) from the primary
3. Restore the certificate on every secondary replica
4. The DEK is replicated to the secondaries as part of the database; the secondaries must have the cert to open it

When rotating a TDE certificate in an AG:

1. Back up the new certificate
2. Restore it on all secondary replicas *first*
3. Rotate the certificate on the primary last
4. Verify that all replicas show the new certificate in `sys.certificates`

If a secondary does not have the TDE certificate, the secondary database will show a "Recovery pending" state and will not start — the error log will contain "Please create a master key in the database or open the master key."

### Log Shipping

With TDE-enabled databases in a log shipping configuration:

- The TDE certificate must be present on the secondary server (imported from the primary)
- Log restores do **not** require the DMK to be open on the secondary — the TDE certificate protects the DEK, and the private key is needed at database recovery time (startup or restore WITH RECOVERY), not during log restores
- If the secondary is in STANDBY / READ-ONLY mode, the database is open and the DEK is decrypted; the certificate must be present and the DMK must be openable

### Replication

SQL Server replication interacts with encryption in specific ways:

- **Snapshot replication**: the snapshot agent reads the published articles in plaintext (SQL Server decrypts TDE-protected data automatically). The snapshot files on disk are **not** encrypted by TDE. Use backup encryption or file-level encryption for snapshot files.
- **Transactional replication**: data is decrypted at the publisher (by the Log Reader Agent), transmitted as plaintext through the distribution database, and applied as plaintext at the subscriber. TDE on the distributor/subscriber protects data at rest but not in the distribution pipeline.
- **Column-level encryption**: if a published column is encrypted with CLE, the encrypted ciphertext is replicated — the subscriber must have the same symmetric key to decrypt it. If you want the subscriber to read plaintext, you must decrypt before publishing or provide the key to the subscriber.

### Backup Compression and TDE

TDE-encrypted databases produce backups where the page data is already encrypted. Encrypted data has high entropy (it resembles random data), and compression algorithms rely on patterns and repetition to reduce size:

- **TDE enabled first, compression second**: backup compression is nearly useless (0–3% size reduction) because the encrypted pages are incompressible
- **Compression enabled first, TDE second**: the data on disk is still plaintext pages; compression works normally; TDE encrypts the compressed pages — this is the recommended order
- **SQL 2016+ backup compression with TDE**: `BACKUP DATABASE ... WITH COMPRESSION` and `MAXTRANSFERSIZE > 65536` enables a special algorithm that identifies uncompressed regions of TDE pages and applies compression; still less effective than compression-before-TDE but better than nothing

```sql
-- Recommended: enable backup compression before enabling TDE
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;
-- Then enable TDE
```

---

## 14. TLS Deep Dive — Cipher Suites and Forward Secrecy

### Cipher Suite Anatomy

A TLS cipher suite is a named set of algorithms that define how a TLS connection is secured. Each suite specifies four components:

| Component | Purpose | Examples |
|-----------|---------|----------|
| Key Exchange | How client and server agree on a shared session key | ECDHE, DHE, RSA |
| Authentication | How the server proves its identity | RSA, ECDSA |
| Encryption (bulk cipher) | Symmetric cipher used for the data stream | AES_256_GCM, AES_128_GCM, AES_256_CBC, CHACHA20_POLY1305 |
| MAC (Message Authentication Code) | Integrity check for each record | SHA384, SHA256 (GCM ciphers bundle this into the AEAD encryption) |

Example: `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384` means:
- **Key exchange**: ECDHE (Elliptic Curve Diffie-Hellman Ephemeral — forward secrecy)
- **Authentication**: RSA certificate
- **Bulk encryption**: AES-256 in GCM mode
- **Hash / PRF**: SHA-384

### ECDHE vs RSA Key Exchange

| Property | ECDHE | RSA |
|----------|-------|-----|
| Forward Secrecy | Yes — session key is ephemeral, not derivable from the certificate's private key | No — session key is encrypted with the certificate's public key; if the private key is later compromised, all past sessions can be decrypted |
| Performance | Slightly higher CPU cost (EC point multiplication) per handshake | Faster handshake (no ephemeral key generation) |
| TLS 1.3 support | Required (only ephemeral key exchanges allowed) | Not supported in TLS 1.3 |
| Recommendation | **Use ECDHE exclusively** for production SQL Server TLS | Avoid for any compliance-required environment |

Forward Secrecy (sometimes called Perfect Forward Secrecy, PFS) means that even if an attacker records all encrypted traffic today and later compromises the server's private key (e.g., via court order, theft, or backup breach), they cannot decrypt the recorded traffic. Each session uses a unique ephemeral key pair discarded after the session ends.

### Recommended Cipher Suite Ordering for SQL Server

Cipher suites are negotiated in the order configured on the server. SQL Server (via Windows SChannel) presents its cipher suite list, and the client selects the first mutually supported suite. Order matters:

1. `TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384` (ECDSA cert + ECDHE + AES-256-GCM)
2. `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384` (RSA cert + ECDHE + AES-256-GCM)
3. `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`
4. `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`
5. `TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384` (CBC fallback — no GCM)
6. `TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384`

Key rules:
- Always place GCM suites before CBC suites (GCM provides built-in authentication; CBC requires a separate HMAC step)
- Always place ECDHE suites before non-ECDHE suites (ensures forward secrecy when possible)
- AES-256 before AES-128 (stronger, negligible performance difference with AES-NI)

### TLS 1.3 Cipher Suites

TLS 1.3 (RFC 8446) radically simplifies cipher suites by removing the key exchange and authentication components from the suite definition. All TLS 1.3 suites use ephemeral key exchange (forward secrecy is mandatory) and AEAD ciphers only — no CBC, no static RSA.

The TLS 1.3 suite names:

- `TLS_AES_256_GCM_SHA384`
- `TLS_AES_128_GCM_SHA256`
- `TLS_CHACHA20_POLY1305_SHA256`

SQL Server 2022 on Windows Server 2022 (or Windows 11) supports TLS 1.3.

### Testing Cipher Suites

```bash
# Enumerate all cipher suites offered by the server
nmap --script ssl-enum-ciphers -p 1433 <host>

# Test a specific TLS version and cipher
openssl s_client -connect <host>:1433 -tls1_2 -cipher ECDHE-RSA-AES256-GCM-SHA384

# Check the certificate chain
openssl s_client -connect <host>:1433 -showcerts
```

### SChannel Registry Configuration

Windows uses the SChannel SSP (Security Support Provider) for TLS. Cipher suite order is configured in the registry:

```
HKLM\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002
  Functions (REG_MULTI_SZ) — ordered list of cipher suite strings
```

Example value:
```
TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
```

Cipher suite changes require a server restart to take effect.

### Group Policy vs Local Registry

| Method | Scope | Persistence | Recommendation |
|--------|-------|-------------|----------------|
| Group Policy (GPO) | Domain-wide; applies to all servers in the OU | Survives registry resets and OS reinstalls | **Preferred** for enterprise environments — consistent cipher policy across all SQL Servers |
| Local registry | Single server | Can be overwritten by GPO or OS updates | Use for standalone servers not domain-joined; document manually |

The Group Policy path for cipher suite order is:
```
Computer Configuration → Administrative Templates → Network → SSL Configuration Settings → SSL Cipher Suite Order
```

---

## 15. Always Encrypted Performance Impact

### Query Performance by Encryption Type

Always Encrypted offers two encryption types with very different query performance characteristics:

| Operation | Deterministic encryption | Randomized encryption |
|-----------|------------------------|----------------------|
| Equality search (`WHERE col = 'X'`) | Works — ciphertext is deterministic, same plaintext produces same ciphertext | **Fails** without enclave — every row has a different ciphertext due to random IV |
| Range search (`WHERE col > 'X'`) | Fails without enclave (ciphertext ordering != plaintext ordering) | Fails without enclave |
| LIKE / pattern matching | Fails without enclave | Fails without enclave |
| JOIN on encrypted column | Works (equality only, deterministic) | Fails without enclave |
| GROUP BY on encrypted column | Works (deterministic only) | Fails without enclave |
| Index seek on encrypted column | Works (deterministic only, on ciphertext) | Fails without enclave |

**CPU overhead**: deterministic encryption adds approximately 10–30% CPU overhead per query due to client-side encryption/decryption. The driver encrypts query parameters and decrypts result columns using the CEK. Network payload size may increase because encrypted values are larger than plaintext.

### Enclave Computation Overhead (SQL 2019+)

Secure enclaves (VBS on Windows, Intel SGX on Linux) allow SQL Server to perform computations on encrypted data without revealing plaintext to the database engine. This enables rich queries (ranges, LIKE, pattern matching) on randomized-encrypted columns.

| Resource | Overhead |
|----------|----------|
| Memory (VBS) | 128–512 MB reserved for the enclave; configured via `sp_configure 'column encryption enclave type'` |
| Per-query enclave call | 1–5 ms latency for the first enclave invocation in a batch; subsequent calls are faster due to caching |
| Throughput | 5–15% overhead vs deterministic AE for the same query pattern (enclave-side decryption replaces client-side) |

### CEK Caching Behavior

When a client application connects, the driver:

1. Retrieves the encrypted CEK value from `sys.column_encryption_key_values`
2. Decrypts the CEK using the Column Master Key (from Windows cert store, AKV, or HSM)
3. Caches the plaintext CEK in memory

| Cache parameter | Default | Notes |
|----------------|---------|-------|
| CEK cache TTL | 2 hours | Configurable via `Column Encryption Key Cache TTL` connection string property |
| Cache scope | Per process / AppDomain | Each application process maintains its own cache |
| Cache eviction | Time-based only | No size limit; CEK is small (256-bit key) |
| AKV calls per CEK | 1 per TTL window | Eliminates repeated AKV calls per logical session |

Without caching, every query would require an AKV round-trip (50–200 ms) to decrypt the CEK. The cache reduces this to once per 2-hour window per physical connection.

### Connection Pooling with Always Encrypted

In connection-pooled environments:

- The CEK is decrypted once per **physical connection** (SPID), not per logical session
- When a connection is returned to the pool (`SqlConnection.Close()` or `Dispose()`), the decrypted CEK remains cached in the driver
- The next logical session that borrows this physical connection does not re-decrypt the CEK
- If CMK rotation occurs during the pool lifetime, sessions using the old CEK will continue to work until the cache TTL expires (at which point they fetch the new CEK)
- Enclave sessions are bound to a specific physical connection and should not be pooled across different enclave-attested connections

### Batch INSERT / UPDATE Performance

Because each row must be encrypted client-side before insertion, batch operations on AE columns have significant throughput reduction:

| Operation type | Throughput vs plaintext | Bottleneck |
|---------------|------------------------|------------|
| Single-row INSERT | 30–50% of plaintext (3x slower) | Client-side CPU for encryption |
| Batch INSERT (1000 rows) | 20–50% of plaintext (2–5x slower) | Client-side CPU; parallelizable across application threads |
| UPDATE of AE column | 30–50% of plaintext | Client-side CPU |
| Bulk insert (SqlBulkCopy) | 40–60% of plaintext | Encrypts row-by-row; not fully parallelized |

Mitigation strategies:
- Increase application parallelism (more threads, each with its own connection) to saturate the database
- Batch sizes of 500–1000 rows balance throughput and transaction log overhead
- For ETL workloads, consider using a staging table without AE, then encrypting as a background process

### Index Considerations

Indexes on Always Encrypted columns behave differently from indexes on plaintext columns:

- **Indexes are built on ciphertext**, not plaintext
- An index on a deterministic-encrypted column supports **equality seeks only** — the optimizer can seek on `WHERE SSN = @ssn` because the driver encrypts `@ssn` to the same ciphertext every time
- An index on a randomized-encrypted column is effectively **useless for seeking** — every row has a unique ciphertext
- Composite indexes can include one deterministic AE column + plaintext columns; the AE column can be used for the index seek, and the plaintext columns for additional filtering
- Index statistics on ciphertext columns are less meaningful than on plaintext columns (the distribution of ciphertext does not reflect the distribution of plaintext)
- Enclave-enabled indexes (SQL 2019+) behave like plaintext indexes for query purposes but store encrypted data on disk

---

## 16. SQL Server Ledger Concepts

### What Is Ledger?

SQL Server Ledger (introduced in SQL Server 2022) provides cryptographic verification that data in a database has not been tampered with. It does not prevent tampering — it makes tampering provably detectable after the fact. Think of it as a blockchain-style integrity mechanism embedded in the database engine.

Use cases:
- Financial audit trails (every transaction permanently verifiable)
- Regulatory compliance (SOX, FDA 21 CFR Part 11, GxP — proof that records have not been altered)
- Supply chain records (chain of custody for sensitive inventory)
- Multi-party data sharing (each party can verify the other hasn't modified shared data)

### Hash Chain Architecture

Ledger tables maintain a Merkle-tree-style hash chain:

```
Row 1: data = {col1, col2, col3}
       hash = SHA-256(Genesis hash + row 1 data)

Row 2: data = {col1, col2, col3}
       hash = SHA-256(Row 1 hash + row 2 data + transaction metadata)

Row N: hash = SHA-256(Row N-1 hash + row N data + transaction metadata)
```

Each row's hash depends on the hash of the previous row. Tampering with any row in the chain changes its hash, which invalidates every subsequent row's hash. The hash chain is stored in the `ledger` schema within hidden system columns.

### Database Digests

A database digest is a periodic snapshot of the hash chain state, published to an external, immutable storage location. The digest contains:

- The hash of the last committed transaction in the ledger table
- A timestamp
- The database ID and table metadata

Digests are generated by `sys.sp_generate_database_ledger_digest` and should be stored in:

- Azure Blob Storage (immutable storage with legal hold)
- Azure Confidential Ledger (ACL — managed blockchain)
- A write-once, read-many (WORM) file system or third-party blockchain

### Append-Only vs Updatable Ledger Tables

| Property | Append-only ledger | Updatable ledger |
|----------|-------------------|-----------------|
| Allowed operations | INSERT only | INSERT, UPDATE, DELETE |
| UPDATE behavior | N/A | System-generated history row inserted into the history table; current row updated |
| DELETE behavior | N/A | Current row deleted; history row records the deletion |
| History table | None | Automatically created; mirrors the main table schema |
| Use case | Immutable event log (audit log, transactions, certificates issued) | Current state with verifiable history (account balances, inventory levels) |

```sql
-- Append-only ledger table
CREATE TABLE dbo.AuditLog (
    AuditID int IDENTITY PRIMARY KEY,
    EventType nvarchar(100),
    EventData nvarchar(max),
    EventTime datetime2 DEFAULT SYSUTCDATETIME()
) WITH (LEDGER = ON (APPEND_ONLY = ON));

-- Updatable ledger table
CREATE TABLE dbo.AccountBalance (
    AccountID int PRIMARY KEY,
    Balance decimal(18,2)
) WITH (LEDGER = ON (APPEND_ONLY = OFF));
```

### Verification Model

`sys.sp_verify_database_ledger` recomputes the entire hash chain from the current database state and compares it against the published digests:

```sql
EXEC sys.sp_verify_database_ledger;
```

- If the recomputed hashes match the published digests: the data has not been tampered with since the digest was generated
- If the recomputed hashes diverge: either the data was tampered with or a digest was generated for a different database state — forensic investigation required

Verification can be scoped to a specific table or a specific time range using the digest timestamps.

### Sysadmin Bypass Consideration

Ledger protects against tampering performed through the SQL Server engine (T-SQL, SSMS, application queries) — even a sysadmin cannot UPDATE or DELETE a row in an append-only ledger table without the change being recorded in the hash chain.

However, a sysadmin with **operating system access** to the database files (.mdf, .ldf) could theoretically modify pages on disk. This is mitigated by:

1. **External digest storage**: published digests are stored outside SQL Server; even if all database files are tampered with, `sp_verify_database_ledger` will detect the mismatch against the externally stored digest
2. **Digest signing**: digests can be cryptographically signed, requiring the attacker to compromise both the database files and the signing key
3. **Immutable storage**: if digests are stored in Azure Confidential Ledger or a public blockchain, they cannot be altered retroactively

### Platform Support

| Platform | Support status |
|----------|---------------|
| SQL Server 2022 (on-premises) | Fully supported |
| Azure SQL Database | Supported in specific regions; requires serverless or provisioned tier |
| Azure SQL Managed Instance | Supported |
| SQL Server 2019 and earlier | Not supported |

---

## 17. Additional Compliance Frameworks — SOX, FedRAMP, ISO 27001

### SOX (Sarbanes-Oxley Act)

The Sarbanes-Oxley Act of 2002 applies to all publicly traded companies in the United States. It mandates internal controls over financial reporting to prevent fraud and ensure the accuracy of financial statements.

#### Section 302 — Corporate Responsibility for Financial Reports

CEOs and CFOs must personally certify the accuracy of financial reports and the effectiveness of internal controls. For IT systems, this means the database systems generating financial data must have demonstrable integrity controls.

#### Section 404 — Management Assessment of Internal Controls

Requires management to document, test, and attest to the effectiveness of internal controls over financial reporting. External auditors independently test these controls.

#### Encryption Relevance to SOX

| Control area | SQL Server encryption mapping |
|-------------|------------------------------|
| Financial data integrity | Ledger tables for financial transaction logs; hash chain for tamper evidence |
| Data-at-rest protection | TDE on all databases containing financial data |
| Key access controls | SQL Audit on certificate/key access; documented key custodians |
| Separation of duties | DBA role separate from security administrator; CMK in HSM/AKV not accessible to DBA |
| Audit trails | SQL Server Audit on all financial tables; Ledger for immutable audit history |
| Backup integrity | Backup encryption + checksum verification on restore |

Key control requirements for SOX:
- **Documented key management**: who has access, how keys are generated, stored, backed up, and rotated
- **Access controls**: role-based access to encryption keys; no single person can both modify financial data and manage audit/encryption keys
- **Rotation policies**: annual key rotation for financial data encryption keys; documented process
- **Evidence retention**: audit trails retained for 7 years (SOX requirement)

### FedRAMP (Federal Risk and Authorization Management Program)

FedRAMP standardizes security assessment and authorization for cloud services used by US federal agencies. It maps to NIST SP 800-53 controls.

#### Data-at-Rest Encryption (SC-28)

> "The information system protects the confidentiality and integrity of [information at rest]."

| FedRAMP level | Encryption requirement | SQL Server mapping |
|--------------|----------------------|-------------------|
| FedRAMP Low | Encryption recommended but not required | TDE recommended as baseline |
| FedRAMP Moderate | FIPS 140-2 validated encryption for data at rest | TDE with AES-256; FIPS-compliant algorithm set |
| FedRAMP High | FIPS 140-2 validated encryption; customer-managed keys | TDE + BYOK (Azure Key Vault); HSM-backed CMK for Always Encrypted |

#### FIPS 140-2 Requirement

All cryptography used in FedRAMP environments must be FIPS 140-2 validated. For SQL Server, this means:
- Windows must be in FIPS-compliant mode
- AES-256 for symmetric encryption
- RSA-2048 or higher for asymmetric keys
- SHA-256 or higher for hashing
- TLS 1.2+ with FIPS-approved cipher suites

#### Customer-Managed Keys (FedRAMP High)

FedRAMP High requires that encryption keys be managed by the customer, not the cloud provider. In Azure SQL, this is achieved through:
- **TDE with BYOK**: the TDE protector is an asymmetric key in Azure Key Vault, controlled by the customer
- **Always Encrypted**: CMK stored in a customer-controlled AKV or on-premises HSM
- Key rotation, revocation, and access logging are under customer control

#### Azure SQL FedRAMP Compliance

| Azure service | FedRAMP level | Notes |
|--------------|--------------|-------|
| Azure SQL Database | High (in Azure Government) | Requires BYOK for High |
| Azure SQL Managed Instance | High (in Azure Government) | VNet isolation required |
| Azure Government SQL | High | Separate Azure region with US-personnel access only |

### ISO 27001 — Information Security Management

ISO 27001 is an international standard for information security management systems (ISMS). Annex A contains 114 controls across 14 domains. The following controls are directly relevant to SQL Server encryption:

#### A.10 — Cryptography

| Control | Title | Requirement | SQL Server mapping |
|---------|-------|-------------|-------------------|
| A.10.1.1 | Policy on the use of cryptographic controls | Documented encryption policy: what data, what algorithms, under what circumstances | Encryption inventory (A40 audit); algorithm versioning documented |
| A.10.1.2 | Key management | Key lifecycle: generation, distribution, storage, archival, destruction | SMK/DMK/cert backup procedures; key rotation schedules; documented decommissioning process (`DROP SYMMETRIC KEY`, cert archival) |

#### A.12 — Operations Security

| Control | Title | SQL Server mapping |
|---------|-------|-------------------|
| A.12.3.1 | Information backup | Backup encryption for all production databases; off-site backup storage with encrypted media |
| A.12.4.1 | Event logging | SQL Server Audit on key access, certificate operations, and encryption state changes; log retention per policy |

#### A.13 — Communications Security

| Control | Title | SQL Server mapping |
|---------|-------|-------------------|
| A.13.2.1 | Information transfer policies and procedures | TLS 1.2+ enforced on all SQL Server connections; ForceEncryption = Yes |
| A.13.2.3 | Electronic messaging | Encrypted endpoints for all database connectivity; self-signed certificates only for internal non-production environments |

#### A.14 — System Acquisition, Development, and Maintenance

| Control | Title | SQL Server mapping |
|---------|-------|-------------------|
| A.14.2.5 | Secure system engineering principles | Encryption designed into schema from start (Always Encrypted for PII columns); data classification (`ADD SENSITIVITY CLASSIFICATION`) at schema creation |

#### ISO 27001 to SQL Server Feature Mapping Summary

| ISO 27001 control | SQL Server feature | Implementation |
|------------------|-------------------|----------------|
| A.10.1.1 — Cryptographic controls policy | Encryption audit | `sys.certificates`, `sys.dm_database_encryption_keys`, CMK inventory |
| A.10.1.2 — Key management | SMK/DMK/cert backup | `BACKUP SERVICE MASTER KEY`, `BACKUP MASTER KEY`, `BACKUP CERTIFICATE` |
| A.12.3.1 — Information backup | Backup encryption | `BACKUP DATABASE ... WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = ...)` |
| A.12.4.1 — Event logging | SQL Server Audit | Audit on `SCHEMA_OBJECT_ACCESS_GROUP` for key/cert operations |
| A.13.2.1 — Information transfer | TLS | `ForceEncryption = Yes`, TLS 1.2+ cipher suites |
| A.13.2.3 — Electronic messaging | TLS + cert validation | Remove `TrustServerCertificate=True`; deploy CA-issued certificates |


---

## 18. DMK Password Auto-Open: sp_control_dbmasterkey_password

### The Two DMK Protection Models

A Database Master Key (DMK) must be decryptable before SQL Server can access any encrypted objects (certificates, symmetric keys, asymmetric keys) in that database. Two mechanisms provide automatic decryption:

**Model 1 — SMK protection (default, recommended)**
The DMK is encrypted by the Service Master Key: `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY`. At startup, SQL Server automatically decrypts the DMK using the SMK. Check: `SELECT is_master_key_encrypted_by_server FROM sys.databases` = 1.

**Model 2 — Registered password via sp_control_dbmasterkey_password**
Used when the DMK deliberately lacks SMK protection. `sp_control_dbmasterkey_password` stores the DMK password as a SQL Server credential in `sys.credentials` (encrypted by the SMK), linked to the database via `sys.master_key_passwords`. At startup, SQL Server:
1. Checks `is_master_key_encrypted_by_server` → 0 (cannot use SMK)
2. Looks up the database's `family_guid` in `sys.master_key_passwords`
3. Retrieves the linked credential from `sys.credentials` (decrypts it with the current SMK)
4. Uses the password to open the DMK

### sys.master_key_passwords Internals

| Column | Type | Meaning |
|--------|------|---------|
| `family_guid` | uniqueidentifier | **Stable database identity** — set at DB creation; persists across RESTORE, ATTACH, RENAME, and `ALTER MASTER KEY REGENERATE`; does NOT change with `CREATE MASTER KEY` after dropping the old one |
| `credential_id` | int | FK → `sys.credentials.credential_id`; the credential name follows the pattern `##DBMKEY_<family_guid>_<random_guid>##` |

### What Invalidates Registrations

- **DOES invalidate:** `RESTORE SERVICE MASTER KEY FROM FILE` using a backup from a DIFFERENT server instance. The stored credentials were encrypted with the source instance's SMK; the restored (foreign) SMK cannot decrypt them. Must re-run `sp_control_dbmasterkey_password @action = 'drop'` then `@action = 'add'` for each database.
- **Does NOT invalidate:** `ALTER SERVICE MASTER KEY REGENERATE` on the SAME instance — SQL Server re-encrypts all credentials with the new SMK automatically.
- **Does NOT invalidate:** `ALTER MASTER KEY REGENERATE` (database DMK regeneration) — `family_guid` stays the same.

### When sp_control_dbmasterkey_password Is Required

| Scenario | Why |
|----------|-----|
| SSISDB | SSISDB creates its DMK without SMK protection by design; the catalog creation password must be registered on every SQL Server instance hosting SSISDB |
| Database restored to new server | `sys.master_key_passwords` is instance-local; not transferred in RESTORE |
| AG secondaries | Seeding does not propagate `sys.master_key_passwords`; each replica needs independent registration |
| Deliberate SMK isolation | Security design where SA cannot auto-open the DMK; password registered separately |
| After cross-instance SMK restore | Foreign SMK invalidates existing credential registrations |
| Read-only databases | Must register BEFORE making database read-only (SQL Server cannot re-encrypt DMK in read-only mode) |

### Quick Reference

```sql
-- List all registered databases and their credential status
SELECT d.name, d.is_master_key_encrypted_by_server,
       c.name AS credential_name, c.create_date
FROM sys.databases d
LEFT JOIN master.sys.master_key_passwords mkp ON mkp.family_guid = d.family_guid
LEFT JOIN master.sys.credentials c ON mkp.credential_id = c.credential_id
WHERE d.database_id > 4;

-- Register a password
EXEC sp_control_dbmasterkey_password @db_name = N'SSISDB', @password = N'[password]', @action = N'add';

-- Remove a registration
EXEC sp_control_dbmasterkey_password @db_name = N'OldDB', @password = N'ignored', @action = N'drop';
```

See `howto-dmk-password-management.md` for full step-by-step scenarios.

---

## 19. Passphrase-Based Encryption and HASHBYTES Algorithm Selection

### ENCRYPTBYPASSPHRASE: PBKDF1 Weakness

`ENCRYPTBYPASSPHRASE(passphrase, plaintext)` derives an encryption key from the passphrase using PBKDF1 (Password-Based Key Derivation Function 1). PBKDF1 applies SHA-1 (or MD5) exactly once with no iteration count and no memory hardness — making it GPU-acceleratable for brute force. Modern password-hashing schemes (bcrypt, Argon2) use thousands to millions of iterations with memory cost, making GPU attacks impractical.

**PBKDF1 vs modern alternatives:**

| Scheme | Iterations | Memory cost | GPU attack resistance | SQL Server support |
|--------|-----------|-------------|----------------------|-------------------|
| PBKDF1 (ENCRYPTBYPASSPHRASE) | 1 | None | None | Yes — but avoid for secrets |
| PBKDF2 | Configurable (10,000+) | None | Low | .NET `Rfc2898DeriveBytes` in app |
| bcrypt | 2^cost factor | None | Medium | Application layer only |
| Argon2id | Configurable | Configurable | High | Application layer only |

**Migration path:** Replace `ENCRYPTBYPASSPHRASE` with AES_256 symmetric key protected by a certificate. Use `ENCRYPTBYKEY`/`DECRYPTBYKEY` instead.

### HASHBYTES Algorithm Reference

| Algorithm | SQL Server name | Status | Bit length | Use for |
|-----------|----------------|--------|-----------|---------|
| MD2 | `'MD2'` | Broken (1995) | 128 | Nothing — remove immediately |
| MD4 | `'MD4'` | Broken (1995) | 128 | Nothing — remove immediately |
| MD5 | `'MD5'` | Broken (2004) | 128 | Nothing security-sensitive |
| SHA-1 | `'SHA'` or `'SHA1'` | Deprecated (NIST 2030) | 160 | Non-security checksums only |
| SHA-256 | `'SHA2_256'` | Current | 256 | Data integrity, fingerprints |
| SHA-512 | `'SHA2_512'` | Current | 512 | Data integrity (larger output) |

**Key rule:** SQL Server `HASHBYTES` is intentionally FAST — it is a cryptographic hash function, not a password-hashing scheme. Do NOT use `HASHBYTES` for storing user passwords. Use application-layer bcrypt/Argon2.

**Safe use cases for HASHBYTES:**
- Row change detection (data fingerprinting)
- Deduplication of large text/binary values
- Generating deterministic lookup keys from composite fields
- Checksum for data integrity verification (SHA2_256 only)

**Unsafe uses (regardless of algorithm):**
- Storing user password hashes
- Authentication tokens or HMAC without a secret key
- Digital signatures (use certificates/asymmetric keys instead)

### Dynamic Data Masking vs Encryption: Mental Model

Dynamic Data Masking is a **presentation layer** control. It changes what you SEE, not what is STORED. Think of it as a column-level filter in query results:

- The data at rest is unchanged (no encryption)
- Any user with `UNMASK` permission sees the real data
- Privileged users (sysadmin) always see the real data
- Inference attacks work: `WHERE masked_col BETWEEN x AND y` returns accurate row counts

Encryption is a **data protection** control. The data at rest is transformed — even a storage-level attacker or privileged SQL user sees only ciphertext (for Always Encrypted) or cannot read without the key (for CLE).

**Combined use:** DDM + AE together is meaningful — application users see masked display values (DDM masks the ciphertext placeholder or companion display column), while sysadmins see only encrypted ciphertext (AE) even if UNMASK is granted. This is the strongest SQL Server column protection pattern.
