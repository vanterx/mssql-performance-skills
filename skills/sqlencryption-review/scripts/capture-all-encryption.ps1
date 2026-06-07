[CmdletBinding()]
param(
    [string]$ServerInstance = "localhost",
    [string]$Database = "master",
    [string]$OutputDir = ".\encryption-audit",
    [switch]$IncludeSource
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runId = "$ServerInstance-$timestamp"

try {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "Output directory: $(Resolve-Path $OutputDir)"
} catch {
    throw "Cannot create output directory '$OutputDir': $($_.Exception.Message)"
}

function Write-TimestampedFile {
    param([string]$FileName, [string]$Content)
    $path = Join-Path $OutputDir $FileName
    Set-Content -Path $path -Value $Content -Encoding UTF8
    Write-Host "  [+] $FileName"
    return $path
}

function Invoke-CaptureQuery {
    param([string]$Query, [string]$Label)
    try {
        if (Get-Command -Name Invoke-SqlCmd -ErrorAction SilentlyContinue) {
            $result = Invoke-SqlCmd -ServerInstance $ServerInstance -Database $Database -Query $Query -ErrorAction Stop -ConnectionTimeout 15 -QueryTimeout 120 | Out-String
        } else {
            $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$ServerInstance;Database=$Database;Integrated Security=True;Connection Timeout=15")
            $cmd = New-Object System.Data.SqlClient.SqlCommand($Query, $conn)
            $cmd.CommandTimeout = 120
            $conn.Open()
            $reader = $cmd.ExecuteReader()
            $dt = New-Object System.Data.DataTable
            $dt.Load($reader)
            $result = $dt | Out-String
            $reader.Close()
            $conn.Close()
            $conn.Dispose()
        }
        return $result
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

Write-Host "=== SQL Server Encryption Audit Capture ===" -ForegroundColor Cyan
Write-Host "  Server:   $ServerInstance"
Write-Host "  Database: $Database"
Write-Host "  Run ID:   $runId"
Write-Host "  Started:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$captured = @()
$errors = @()

$queries = @(
    @{
        File = "01-tde-status.txt"
        Label = "TDE status across all databases"
        SQL = @"
SELECT
    d.name                          AS database_name,
    d.is_encrypted,
    dek.encryption_state,
    dek.encryption_state_desc,
    dek.percent_complete,
    dek.encryptor_type,
    dek.key_algorithm,
    dek.key_length,
    c.name                          AS certificate_name,
    c.expiry_date                   AS cert_expiry,
    c.pvt_key_encryption_type_desc
FROM sys.databases d
LEFT JOIN sys.dm_database_encryption_keys dek ON d.database_id = dek.database_id
LEFT JOIN master.sys.certificates c ON dek.encryptor_thumbprint = c.thumbprint
ORDER BY d.name;
"@
    },
    @{
        File = "02-always-encrypted-columns.txt"
        Label = "Always Encrypted column inventory"
        SQL = @"
SELECT
    SCHEMA_NAME(t.schema_id)        AS schema_name,
    t.name                          AS table_name,
    c.name                          AS column_name,
    c.encryption_type,
    c.encryption_type_desc,
    c.encryption_algorithm_name,
    cek.name                        AS cek_name,
    cmk.name                        AS cmk_name,
    cmk.key_store_provider_name,
    cmk.key_path
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.column_encryption_keys cek ON c.column_encryption_key_id = cek.column_encryption_key_id
JOIN sys.column_master_keys cmk ON cek.column_master_key_id = cmk.column_master_key_id
WHERE c.column_encryption_key_id IS NOT NULL;
"@
    },
    @{
        File = "03-cek-version-history.txt"
        Label = "CEK rotation history"
        SQL = @"
SELECT
    cek.name                        AS cek_name,
    cek.create_date,
    cekv.column_master_key_id,
    cmk.name                        AS cmk_name,
    cekv.create_date                AS version_created
FROM sys.column_encryption_keys cek
JOIN sys.column_encryption_key_values cekv ON cek.column_encryption_key_id = cekv.column_encryption_key_id
JOIN sys.column_master_keys cmk ON cekv.column_master_key_id = cmk.column_master_key_id;
"@
    },
    @{
        File = "04-symmetric-asymmetric-keys.txt"
        Label = "All user keys"
        SQL = @"
SELECT
    name,
    symmetric_key_id                AS key_id,
    'SYMMETRIC'                     AS key_type,
    algorithm_desc,
    CAST(key_length AS VARCHAR(10)) AS key_length,
    create_date,
    modify_date,
    pvt_key_encryption_type_desc
FROM sys.symmetric_keys
WHERE name NOT LIKE '##%'
UNION ALL
SELECT
    name,
    asymmetric_key_id,
    'ASYMMETRIC',
    algorithm_desc,
    CAST(key_length AS VARCHAR(10)),
    create_date,
    modify_date,
    pvt_key_encryption_type_desc
FROM sys.asymmetric_keys
WHERE name NOT LIKE '##%';
"@
    },
    @{
        File = "05-certificates.txt"
        Label = "All certificates"
        SQL = @"
SELECT
    name,
    certificate_id,
    pvt_key_encryption_type_desc,
    issuer_name,
    subject,
    start_date,
    expiry_date,
    DATEDIFF(DAY, GETDATE(), expiry_date) AS days_until_expiry,
    CERTPROPERTY(name, 'Algorithm')       AS sig_algorithm
FROM sys.certificates
WHERE name NOT LIKE '##%'
ORDER BY expiry_date;
"@
    },
    @{
        File = "06-backup-encryption.txt"
        Label = "Recent 30-day backup encryption"
        SQL = @"
SELECT TOP 30
    database_name,
    backup_start_date,
    backup_finish_date,
    type                            AS backup_type,
    key_algorithm,
    encryptor_type,
    encryptor_thumbprint
FROM msdb.dbo.backupset
WHERE backup_start_date > DATEADD(DAY, -30, GETDATE())
ORDER BY backup_start_date DESC;
"@
    },
    @{
        File = "07-connection-encryption.txt"
        Label = "Connection encryption status"
        SQL = @"
SELECT
    encrypt_option,
    auth_scheme,
    COUNT(*)                        AS connection_count,
    SUM(CASE WHEN client_net_address NOT IN ('<local machine>', '127.0.0.1', '::1')
             THEN 1 ELSE 0 END)     AS remote_connections
FROM sys.dm_exec_connections
GROUP BY encrypt_option, auth_scheme;
"@
    },
    @{
        File = "08-dmk-status.txt"
        Label = "DMK protection status per database"
        SQL = @"
SELECT
    d.name                          AS database_name,
    d.is_master_key_encrypted_by_server,
    sk.name                         AS dmk_name,
    sk.create_date,
    sk.modify_date
FROM sys.databases d
LEFT JOIN sys.symmetric_keys sk ON sk.name = N'##MS_DatabaseMasterKey##'
WHERE d.database_id = DB_ID();
"@
    },
    @{
        File = "09-ekm-providers.txt"
        Label = "EKM providers"
        SQL = @"
SELECT
    provider_id,
    name,
    dll_path,
    is_enabled,
    provider_version,
    sqlcrypt_version
FROM sys.cryptographic_providers;
"@
    },
    @{
        File = "10-sensitivity-classifications.txt"
        Label = "Sensitivity classifications"
        SQL = @"
SELECT
    SCHEMA_NAME(t.schema_id)        AS schema_name,
    t.name                          AS table_name,
    c.name                          AS column_name,
    sc.information_type,
    sc.label,
    sc.rank_desc,
    c.column_encryption_key_id      AS ae_key_id
FROM sys.sensitivity_classifications sc
JOIN sys.objects t ON sc.major_id = t.object_id
JOIN sys.columns c ON sc.major_id = c.object_id AND sc.minor_id = c.column_id;
"@
    },
    @{
        File = "11-endpoints.txt"
        Label = "Endpoints using certificate authentication"
        SQL = @"
SELECT
    e.name                          AS endpoint_name,
    e.type_desc,
    e.connection_auth_desc,
    c.name                          AS certificate_name,
    c.expiry_date,
    DATEDIFF(DAY, GETDATE(), c.expiry_date) AS days_until_expiry
FROM sys.endpoints e
LEFT JOIN sys.certificates c ON e.certificate_id = c.certificate_id
WHERE e.connection_auth_desc LIKE '%CERTIFICATE%';
"@
    }
)

if ($IncludeSource) {
    $queries += @(
        @{
            File = "12-module-source.txt"
            Label = "T-SQL module source metadata"
            SQL = @"
SELECT
    DB_NAME()           AS database_name,
    SCHEMA_NAME(o.schema_id) AS schema_name,
    o.name              AS object_name,
    o.type_desc,
    o.create_date,
    o.modify_date,
    m.uses_native_compilation,
    LEN(m.definition)   AS source_length
FROM sys.sql_modules m
JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'TR', 'V')
ORDER BY o.type_desc, SCHEMA_NAME(o.schema_id), o.name;
"@
        }
    )
}

Write-Host "Running capture queries..." -ForegroundColor Yellow
Write-Host ""

foreach ($q in $queries) {
    $label = $q.Label
    Write-Host "  $label"
    $content = Invoke-CaptureQuery -Query $q.SQL -Label $label
    $filePath = Write-TimestampedFile -FileName $q.File -Content $content
    if ($content -match "^ERROR:") {
        $errors += $label
    } else {
        $captured += $label
    }
}

$summaryLines = @(
    "=== SQL Server Encryption Audit Capture Summary ===",
    "  Run ID:       $runId",
    "  Server:       $ServerInstance",
    "  Database:     $Database",
    "  Started:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "  Output:       $(Resolve-Path $OutputDir)",
    "  Source included: $($IncludeSource.IsPresent)",
    "",
    "  Files written:"
) + ($captured | ForEach-Object { "    [OK]  $_" })

if ($errors.Count -gt 0) {
    $summaryLines += @(
        "",
        "  FAILED ($($errors.Count)):"
    ) + ($errors | ForEach-Object { "    [ERR] $_" })
}

$summaryLines += @(
    "",
    "  Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
)

$summaryContent = $summaryLines -join "`r`n"
Write-TimestampedFile -FileName "_summary.txt" -Content $summaryContent

Write-Host ""
Write-Host "=== Capture complete ===" -ForegroundColor Green
Write-Host "  $($captured.Count) succeeded, $($errors.Count) failed"
Write-Host "  Summary: $(Join-Path (Resolve-Path $OutputDir) '_summary.txt')"

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: Some queries failed. Check the output files for ERROR: lines." -ForegroundColor Red
    exit 1
}

exit 0
