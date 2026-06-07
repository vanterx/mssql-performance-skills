# HOW-TO: Dynamic Data Masking — Decision Guide and Setup

Dynamic Data Masking (DDM) controls what data users see in query results. It is NOT encryption. This guide explains when to use DDM, when to use encryption, and how they interact.

---

## DDM vs Encryption: What Each Protects

| Property | Dynamic Data Masking | Column-Level Encryption (AE/CLE) |
|----------|---------------------|-----------------------------------|
| Protects data at rest (storage) | No | Yes |
| Protects against sysadmin access | No | AE only (CLE: no) |
| Protects against SQL injection reading data | No | Yes (AE: plaintext never on server) |
| Bypass by UNMASK permission | Yes | No (AE: key required) |
| Bypass by SELECT INTO temp table | Yes | No |
| Bypass by inference attacks (BETWEEN, COUNT) | Yes | No |
| Satisfies PCI-DSS Req 3.5 for PAN | No | AE/CLE: Yes |
| Satisfies HIPAA encryption safeguard | No | Yes |
| Requires application changes | No | AE: Yes; CLE: Maybe |
| Performance impact | Negligible | AE: Medium; CLE: Low-Medium |

**Bottom line:** DDM is an access-control display filter. Encryption is data protection. For regulated data (PCI, HIPAA, GDPR), use encryption. DDM can complement encryption as a secondary control for application layer visibility.

---

## Decision Tree

```
Is the data regulated (PCI PAN, HIPAA PHI, GDPR PII)?
├── Yes → Use encryption (AE or CLE); optionally ADD DDM as secondary
└── No → Is it sensitive internal data (salaries, HR data)?
           ├── Do application users need to see masked values (e.g., last 4 digits)?
           │    ├── Yes → DDM is appropriate; no encryption needed unless compliance requires it
           │    └── No → Use encryption or access-based views (RLS)
           └── Is the goal to audit who accesses it?
                └── Yes → Use SQL Server Audit + RLS, not DDM
```

---

## Setting Up DDM

### Add a Mask

```sql
-- Default mask: shows 0/empty string/1900-01-01 depending on data type
ALTER TABLE dbo.Customer
ALTER COLUMN SSN ADD MASKED WITH (FUNCTION = 'default()');

-- Partial mask: show first 0 chars, mask middle, show last 4
ALTER TABLE dbo.Customer
ALTER COLUMN CreditCard ADD MASKED WITH (FUNCTION = 'partial(0,"XXXX-XXXX-XXXX-",4)');

-- Email mask: aXXX@XXXX.com
ALTER TABLE dbo.Customer
ALTER COLUMN EmailAddress ADD MASKED WITH (FUNCTION = 'email()');

-- Random number mask (good for amounts that shouldn't be zero)
ALTER TABLE dbo.Orders
ALTER COLUMN OrderAmount ADD MASKED WITH (FUNCTION = 'random(1, 999)');
```

### Verify Masking is Active

```sql
-- List all masked columns
SELECT SCHEMA_NAME(t.schema_id) AS schema_name, t.name AS table_name,
       c.name AS column_name, c.masking_function
FROM sys.masked_columns c
JOIN sys.tables t ON c.object_id = t.object_id
ORDER BY schema_name, table_name;
```

### Test the Mask

```sql
-- Test as a low-privilege user
EXECUTE AS USER = 'AppReadUser';
SELECT SSN, CreditCard, EmailAddress FROM dbo.Customer;
-- Should see masked values
REVERT;

-- Verify privileged user sees unmasked data
SELECT SSN, CreditCard, EmailAddress FROM dbo.Customer;
-- Sysadmin sees real values (no mask applied)
```

---

## UNMASK Permission

The `UNMASK` permission allows a principal to bypass all DDM masks in the database.

```sql
-- Grant UNMASK to a specific user (not a role)
GRANT UNMASK TO [specific_user];

-- Revoke UNMASK from a role
REVOKE UNMASK FROM [db_role_name];

-- Audit who has UNMASK
SELECT dp.name AS principal, dp.type_desc
FROM sys.database_permissions p
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
WHERE p.permission_name = 'UNMASK';
```

**Best practices:**
- Grant UNMASK to named individuals only, never to roles
- Review UNMASK grants quarterly
- Log UNMASK grants via SQL Server Audit (`DATABASE_PRINCIPAL_CHANGE_GROUP`)
- Document the business reason for each UNMASK grant

### Granular UNMASK (SQL Server 2022+)

SQL Server 2022 introduces granular UNMASK per schema or table:

```sql
-- Grant UNMASK only on a specific table
GRANT UNMASK ON SCHEMA::HumanResources TO [HRManager];
GRANT UNMASK ON dbo.SensitiveTable TO [AuditUser];
```

---

## DDM Interaction with Always Encrypted

Always Encrypted encrypts data client-side before it reaches the server. DDM is evaluated server-side. Result: DDM masks are NEVER applied to AE-encrypted columns — the server sees ciphertext, not plaintext, so masking functions have nothing to mask.

```sql
-- AE-encrypted column with DDM mask (the mask has no effect)
ALTER TABLE dbo.Customer
ALTER COLUMN SSN_Encrypted ADD MASKED WITH (FUNCTION = 'default()');
-- A user without the AE column key still receives ciphertext, not a masked value
-- The DDM mask is silently ignored
```

**Recommended pattern:** Apply DDM only to non-AE columns. For AE columns, the ciphertext IS the "masked" value — add a companion plaintext masked column if application users need to see a display value (e.g., `SSN_Display NVARCHAR(11) MASKED WITH (FUNCTION = 'partial(0,"XXX-XX-",4)')`).

---

## DDM Interaction with CLE

CLE-encrypted columns store `varbinary` cipher text. DDM `default()` on a `varbinary` column returns `0x` (empty binary). This is better than returning the full cipher text.

```sql
-- Add default mask to CLE-encrypted column to hide cipher text from reporting users
ALTER TABLE dbo.CustomerPayment
ALTER COLUMN EncryptedSSN ADD MASKED WITH (FUNCTION = 'default()');
-- Users without open symmetric key see 0x instead of cipher text
-- Users with open symmetric key AND UNMASK see cipher text (then call DECRYPTBYKEY in app)
```

---

## DDM Bypass Patterns to Know

1. **SELECT INTO temporary table:** `SELECT SSN INTO #tmp FROM dbo.Customer` — the mask is bypassed, `#tmp` contains real values
2. **Dynamic SQL:** Masking applies to the connection's user context, not the EXECUTE AS context in some configurations
3. **Inference attacks:** `SELECT COUNT(*) FROM Customer WHERE SSN LIKE '123%'` — returns accurate count even if SSN is masked in SELECT
4. **EXECUTE AS OWNER:** Procedures running under owner context may bypass DDM if the owner is privileged
5. **Database backups:** DDM metadata is restored, but the underlying data in the backup is unmasked — protect backups separately

---

## Removing DDM

```sql
-- Remove mask from a single column
ALTER TABLE dbo.Customer
ALTER COLUMN SSN DROP MASKED;

-- Remove all masks from a table (iterate per column)
-- No DROP ALL MASKED shortcut exists — must drop per column
```

---

## DDM + RLS: Defense-in-Depth

Use Row-Level Security to hide rows and DDM to obscure column values:

```sql
-- RLS: hide rows for other managers' employees
CREATE FUNCTION dbo.fn_EmployeeFilter(@ManagerId INT)
RETURNS TABLE WITH SCHEMABINDING AS
RETURN SELECT 1 AS fn_result
WHERE @ManagerId = USER_ID() OR IS_MEMBER('HRAdmin') = 1;

CREATE SECURITY POLICY dbo.EmployeePolicy
ADD FILTER PREDICATE dbo.fn_EmployeeFilter(ManagerId) ON dbo.Employee
WITH (STATE = ON);

-- DDM: mask salary for non-HR viewers
ALTER TABLE dbo.Employee
ALTER COLUMN Salary ADD MASKED WITH (FUNCTION = 'default()');
GRANT UNMASK TO [HRAdmin];
-- Result: regular managers see their own employees' rows but salary is masked
--         HR admin sees all rows and real salary values
```

**Important:** Do NOT create RLS predicates on Always Encrypted columns — they don't work (see A90).
