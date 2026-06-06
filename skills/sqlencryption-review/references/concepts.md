# SQL Server Encryption — Concepts Reference

This document provides background knowledge for the `sqlencryption-review` skill. Load it when a user asks "what is TDE?", "explain the difference between AE and CLE", "what TLS version should I use?", "what does GDPR require for encryption?", or any conceptual question about SQL Server cryptography.

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
