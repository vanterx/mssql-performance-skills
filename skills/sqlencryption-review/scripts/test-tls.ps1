[CmdletBinding()]
param(
    [string]$ComputerName = "localhost",
    [int]$Port = 1433
)

$ErrorActionPreference = "Stop"

Write-Host "=== SQL Server TLS Configuration Test ===" -ForegroundColor Cyan
Write-Host "  Target: ${ComputerName}:${Port}"
Write-Host "  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$findings = @()
$warnings = @()

function Write-Finding {
    param([string]$Text, [string]$Severity = "INFO")
    switch ($Severity) {
        "PASS"  { Write-Host "  [PASS]  $Text" -ForegroundColor Green }
        "WARN"  { Write-Host "  [WARN]  $Text" -ForegroundColor Yellow; $script:warnings += $Text }
        "FAIL"  { Write-Host "  [FAIL]  $Text" -ForegroundColor Red; $script:warnings += $Text }
        "RECOMMEND" { Write-Host "         > $Text" -ForegroundColor DarkGray }
        default { Write-Host "  [INFO]  $Text" -ForegroundColor Gray }
    }
    $script:findings += "$Severity`: $Text"
}

Write-Host "--- SChannel Protocol Registry ---" -ForegroundColor Yellow

$schannelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
$tlsVersions = @("TLS 1.0", "TLS 1.1", "TLS 1.2", "TLS 1.3")

try {
    $protocolKeys = Get-ChildItem -Path $schannelPath -ErrorAction Stop | Where-Object { $_.PSChildName -match "^TLS " }
} catch {
    Write-Finding -Text "Cannot read SCHANNEL registry: $($_.Exception.Message)" -Severity "FAIL"
    $protocolKeys = @()
}

foreach ($version in $tlsVersions) {
    $serverKey = "$schannelPath\$version\Server"
    $clientKey = "$schannelPath\$version\Client"
    $serverEnabled = $null
    $serverDisabled = $null
    $clientEnabled = $null
    $clientDisabled = $null

    if (Test-Path $serverKey) {
        $serverEnabled = (Get-ItemProperty -Path $serverKey -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
        $serverDisabled = (Get-ItemProperty -Path $serverKey -Name "DisabledByDefault" -ErrorAction SilentlyContinue).DisabledByDefault
    }
    if (Test-Path $clientKey) {
        $clientEnabled = (Get-ItemProperty -Path $clientKey -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
        $clientDisabled = (Get-ItemProperty -Path $clientKey -Name "DisabledByDefault" -ErrorAction SilentlyContinue).DisabledByDefault
    }

    $serverStatus = if ($serverEnabled -eq $null) { "not configured" } elseif ($serverEnabled -eq 1 -and $serverDisabled -eq 0) { "ENABLED" } elseif ($serverEnabled -eq 0 -and $serverDisabled -eq 1) { "disabled" } else { "Enabled=$serverEnabled, DisabledByDefault=$serverDisabled" }
    $clientStatus = if ($clientEnabled -eq $null) { "not configured" } elseif ($clientEnabled -eq 1 -and $clientDisabled -eq 0) { "ENABLED" } elseif ($clientEnabled -eq 0 -and $clientDisabled -eq 1) { "disabled" } else { "Enabled=$clientEnabled, DisabledByDefault=$clientDisabled" }

    $severity = "INFO"
    if ($version -in @("TLS 1.0", "TLS 1.1")) {
        if ($serverStatus -match "ENABLED" -or $serverStatus -match "not configured") {
            $severity = "WARN"
        } else {
            $severity = "PASS"
        }
    } elseif ($version -eq "TLS 1.2") {
        if ($serverStatus -match "ENABLED") {
            $severity = "PASS"
        } elseif ($serverStatus -match "disabled") {
            $severity = "FAIL"
        } else {
            $severity = "WARN"
        }
    } elseif ($version -eq "TLS 1.3") {
        if ($serverStatus -match "ENABLED") {
            $severity = "PASS"
        } elseif ($serverStatus -match "not configured") {
            $severity = "INFO"
        } else {
            $severity = "WARN"
        }
    }

    Write-Finding -Text "$version Server: $serverStatus | Client: $clientStatus" -Severity $severity
}

Write-Host ""
Write-Host "--- Cipher Suite Configuration ---" -ForegroundColor Yellow

$cipherPath = "HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002"
try {
    if (Test-Path $cipherPath) {
        $cipherFunctions = (Get-ItemProperty -Path $cipherPath -Name "Functions" -ErrorAction Stop).Functions
        $cipherList = $cipherFunctions -split ","
        Write-Finding -Text "Custom cipher suite order configured ($($cipherList.Count) suites)" -Severity "INFO"
        $weakCiphers = $cipherList | Where-Object { $_ -match "RC4|DES|3DES|NULL|EXPORT|MD5|anon" }
        if ($weakCiphers) {
            Write-Finding -Text "Weak cipher suites detected: $($weakCiphers -join ', ')" -Severity "FAIL"
        } else {
            Write-Finding -Text "No weak cipher suites in order" -Severity "PASS"
        }
        $prefersForwardSecrecy = $cipherList | Where-Object { $_ -match "ECDHE|DHE" }
        if (-not $prefersForwardSecrecy) {
            Write-Finding -Text "No forward-secrecy (ECDHE/DHE) ciphers configured" -Severity "WARN"
        }
    } else {
        Write-Finding -Text "Cipher suite order not configured (OS defaults used)" -Severity "INFO"
        Write-Finding -Text "Review OS defaults for legacy cipher suite inclusion" -Severity "RECOMMEND"
    }
} catch {
    Write-Finding -Text "Cannot read cipher suite policy: $($_.Exception.Message)" -Severity "WARN"
}

Write-Host ""
Write-Host "--- SQL Server ForceEncryption (via DMV) ---" -ForegroundColor Yellow

$sqlCheck = @"
SELECT value_name, value_data
FROM sys.dm_server_registry
WHERE registry_key LIKE N'%SuperSocketNetLib%'
  AND value_name IN (N'ForceEncryption', N'Encrypt', N'Security')
ORDER BY value_name;
"@

try {
    if (Get-Command -Name Invoke-SqlCmd -ErrorAction SilentlyContinue) {
        $regRows = Invoke-SqlCmd -ServerInstance $ComputerName -Database "master" -Query $sqlCheck -ConnectionTimeout 10 -QueryTimeout 30 -ErrorAction Stop
        $forceEncrypt = ($regRows | Where-Object { $_.value_name -like "*ForceEncrypt*" -or $_.value_name -like "*Encrypt*" })
        if ($forceEncrypt) {
            if ($forceEncrypt.value_data -eq "1" -or $forceEncrypt.value_data -eq 1) {
                Write-Finding -Text "ForceEncryption: ENABLED at server level" -Severity "PASS"
            } else {
                Write-Finding -Text "ForceEncryption: DISABLED at server level (value_data=$($forceEncrypt.value_data))" -Severity "WARN"
            }
        } else {
            Write-Finding -Text "ForceEncryption: registry key not found" -Severity "WARN"
        }
    } else {
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$ComputerName;Database=master;Integrated Security=True;Connection Timeout=10")
        $cmd = New-Object System.Data.SqlClient.SqlCommand($sqlCheck, $conn)
        $cmd.CommandTimeout = 30
        $conn.Open()
        $reader = $cmd.ExecuteReader()
        $dt = New-Object System.Data.DataTable
        $dt.Load($reader)
        $reader.Close()
        $conn.Close()
        $conn.Dispose()
        $forceEncrypt = $dt | Where-Object { $_.value_name -like "*ForceEncrypt*" -or $_.value_name -like "*Encrypt*" }
        if ($forceEncrypt) {
            if ($forceEncrypt.value_data -eq "1" -or $forceEncrypt.value_data -eq 1) {
                Write-Finding -Text "ForceEncryption: ENABLED at server level" -Severity "PASS"
            } else {
                Write-Finding -Text "ForceEncryption: DISABLED at server level (value_data=$($forceEncrypt.value_data))" -Severity "WARN"
            }
        } else {
            Write-Finding -Text "ForceEncryption: registry key not found" -Severity "WARN"
        }
    }
} catch {
    if ($_.Exception.Message -match "network-related|Login failed|Cannot open server|Timeout") {
        Write-Finding -Text "Cannot query SQL Server for ForceEncryption ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" -Severity "INFO"
        Write-Finding -Text "ForceEncryption check requires SQL Server connectivity" -Severity "RECOMMEND"
    } else {
        Write-Finding -Text "Cannot query SQL Server for ForceEncryption: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Severity "WARN"
    }
}

Write-Host ""
Write-Host "--- TLS Connectivity Test ---" -ForegroundColor Yellow

try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $tcpClient.Connect($ComputerName, $Port)
    $stream = $tcpClient.GetStream()
    Write-Finding -Text "TCP connection to ${ComputerName}:${Port} succeeded" -Severity "INFO"

    $tcpClient.Close()
    $tcpClient.Dispose()
} catch {
    Write-Finding -Text "TCP connection to ${ComputerName}:${Port} failed: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Severity "FAIL"
}

Write-Host ""
Write-Host "--- External Tool Suggestions ---" -ForegroundColor Yellow

$opensslFound = $false
$nmapFound = $false

try {
    $null = Get-Command openssl.exe -ErrorAction Stop
    $opensslFound = $true
} catch {}

try {
    $null = Get-Command nmap.exe -ErrorAction Stop
    $nmapFound = $true
} catch {}

if ($opensslFound) {
    Write-Finding -Text "openssl.exe found on PATH — verify with:" -Severity "RECOMMEND"
    Write-Host "         openssl s_client -connect ${ComputerName}:${Port} -tls1_2" -ForegroundColor DarkCyan
    Write-Host "         openssl s_client -connect ${ComputerName}:${Port} -tls1_3" -ForegroundColor DarkCyan
} else {
    Write-Finding -Text "openssl.exe not on PATH — install OpenSSL for external TLS verification" -Severity "RECOMMEND"
}

if ($nmapFound) {
    Write-Finding -Text "nmap.exe found on PATH — verify with:" -Severity "RECOMMEND"
    Write-Host "         nmap --script ssl-enum-ciphers -p ${Port} ${ComputerName}" -ForegroundColor DarkCyan
} else {
    Write-Finding -Text "nmap.exe not on PATH — install Nmap for cipher suite enumeration" -Severity "RECOMMEND"
}

Write-Host ""
Write-Host "=== TLS Test Complete ===" -ForegroundColor Green

if ($warnings.Count -gt 0) {
    Write-Host "  $($warnings.Count) warning(s)/failure(s) found" -ForegroundColor Yellow
} else {
    Write-Host "  All checks passed" -ForegroundColor Green
}

exit 0
