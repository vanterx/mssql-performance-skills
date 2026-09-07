<#
.SYNOPSIS
    Captures SQL Server SPN, Kerberos delegation, and Kerberos environment state
    for analysis by the /sqlspn-review skill.

.DESCRIPTION
    Collects, in one pass, every artifact the sqlspn-review checks need:

      Section 1  SPN registration      - setspn -L / -Q / -X for the service
                                         account and the MSSQLSvc namespace
                                         (K1-K16, K28, K35, K36, K40)
      Section 2  Service account       - delegation and encryption attributes
                                         from Get-ADUser / Get-ADServiceAccount
                                         (K11, K19, K21-K25, K30, K34, K37, K38, K47)
      Section 3  Computer account      - delegation attributes and SPNs on the
                                         host object (K9, K28, K29)
      Section 4  Delegation targets    - resolves every msDS-AllowedToDelegateTo
                                         entry to confirm it exists (K22)
      Section 5  Kerberos environment  - clock offset against a domain controller,
                                         cached tickets, and a direct service
                                         ticket request (K45, K38, K47)
      Section 6  Instance state        - TCP port configuration and the live
                                         auth_scheme, when -ServerInstance is given
                                         (K5, K13, K20, K44, K52)

    Read-only. Every command queries state; nothing is registered, modified, or
    deleted. `klist purge` is deliberately NOT run, because it would discard the
    cached tickets that are themselves evidence.

    Microsoft also ships two purpose-built tools that overlap this script and are
    worth running alongside it:
      Kerberos Configuration Manager for SQL Server (KCM)
        https://www.microsoft.com/download/details.aspx?id=39046
      SQLCHECK
        https://github.com/microsoft/CSS_SQL_Networking_Tools/wiki/SQLCHECK

.PARAMETER ServiceAccount
    The SQL Server service account, as DOMAIN\samAccountName. For a gMSA or MSA,
    include the trailing dollar sign. Defaults to reading the account from the
    local SQL Server service when omitted.

.PARAMETER ComputerName
    The SQL Server host computer name. Defaults to the local machine.

.PARAMETER ServerInstance
    Optional. When supplied, connects to this SQL Server instance to capture the
    TCP port and the auth_scheme of the connection. Requires the SqlServer module.

.PARAMETER DomainController
    Optional. Domain controller to measure clock offset against. Defaults to the
    logon server.

.PARAMETER OutputPath
    Directory for the timestamped output file. Defaults to the current directory.

.EXAMPLE
    .\capture-spn-config.ps1 -ServiceAccount CONTOSO\sqlsvc
    Captures SPN and delegation state for a domain service account.

.EXAMPLE
    .\capture-spn-config.ps1 -ServiceAccount CONTOSO\sqlgmsa$ -ServerInstance SQLNODE1
    Captures gMSA state plus live instance port and auth_scheme.

.NOTES
    Requires: PowerShell 5.1+ or 7+, the ActiveDirectory module (RSAT), and
    setspn.exe (built into Windows). Domain-joined host, running as a domain user
    with read access to AD. No elevation required for the read-only queries.

    For SQL Server on Linux (K49-K51) this script does not apply - capture instead:
      /opt/mssql/bin/mssql-conf validate-ad-config /var/opt/mssql/secrets/mssql.keytab
      klist -kte /var/opt/mssql/secrets/mssql.keytab
      ls -l /var/opt/mssql/secrets/mssql.keytab

    Reference: Register a Service Principal Name for Kerberos connections -
    https://learn.microsoft.com/sql/database-engine/configure-windows/register-a-service-principal-name-for-kerberos-connections
#>

[CmdletBinding()]
param(
    [string] $ServiceAccount,
    [string] $ComputerName = $env:COMPUTERNAME,
    [string] $ServerInstance,
    [string] $DomainController = $env:LOGONSERVER -replace '^\\\\', '',
    [string] $OutputPath = '.'
)

$ErrorActionPreference = 'Continue'

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputFile = Join-Path $OutputPath "spn-capture-$ComputerName-$timestamp.txt"
$output     = [System.Collections.Generic.List[string]]::new()

function Add-Section {
    param([string] $Title)
    $output.Add('')
    $output.Add('=' * 78)
    $output.Add($Title)
    $output.Add('=' * 78)
}

function Add-Item {
    param([string] $Label, [object] $Value)
    $output.Add('')
    $output.Add("--- $Label ---")
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
        $output.Add('(no data returned)')
    }
    else {
        $output.AddRange([string[]]@($Value | Out-String -Width 200 -Stream))
    }
}

$output.Add("SQL Server SPN and Kerberos Delegation Capture")
$output.Add("Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
$output.Add("Host      : $ComputerName")
$output.Add("Collected by: $env:USERDOMAIN\$env:USERNAME")

# ---------------------------------------------------------------------------
# Resolve the service account when not supplied
# ---------------------------------------------------------------------------
if (-not $ServiceAccount) {
    $svc = Get-CimInstance Win32_Service -Filter "Name LIKE 'MSSQL%'" -ErrorAction SilentlyContinue |
           Where-Object { $_.PathName -match 'sqlservr\.exe' } |
           Select-Object -First 1
    if ($svc) {
        $ServiceAccount = $svc.StartName
        $output.Add("Service account discovered from $($svc.Name): $ServiceAccount")
    }
    else {
        $output.Add('WARNING: No local SQL Server service found and -ServiceAccount not supplied.')
        $output.Add('         Sections 2 and 4 will be skipped.')
    }
}
else {
    $output.Add("Service account : $ServiceAccount")
}

$samAccountName = if ($ServiceAccount) { ($ServiceAccount -split '\\')[-1] } else { $null }
$isManagedAccount = $samAccountName -and $samAccountName.EndsWith('$')

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    $output.Add('')
    $output.Add('WARNING: ActiveDirectory module not available. Install RSAT to capture')
    $output.Add('         delegation and encryption attributes (sections 2, 3, 4).')
}
else {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Section 1 - SPN registration
# ---------------------------------------------------------------------------
Add-Section 'SECTION 1 - SPN REGISTRATION (K1-K16, K28, K35, K36, K40)'

Add-Item 'setspn -Q MSSQLSvc/* (all MSSQLSvc SPNs in the domain)' (& setspn.exe -Q 'MSSQLSvc/*' 2>&1)
Add-Item 'setspn -X (duplicate SPN report across all accounts)'    (& setspn.exe -X 2>&1)
Add-Item "setspn -L $ComputerName (computer account SPNs)"          (& setspn.exe -L $ComputerName 2>&1)

if ($ServiceAccount) {
    Add-Item "setspn -L $ServiceAccount (service account SPNs)" (& setspn.exe -L $ServiceAccount 2>&1)
}

Add-Item 'setspn -Q HTTP/* (HTTP SPNs - SSRS delegation targets, K17)' (& setspn.exe -Q 'HTTP/*' 2>&1)

# ---------------------------------------------------------------------------
# Section 2 - Service account attributes
# ---------------------------------------------------------------------------
Add-Section 'SECTION 2 - SERVICE ACCOUNT (K11, K19, K21-K25, K30, K34, K37, K38, K47)'

$delegationProps = @(
    'TrustedForDelegation',
    'TrustedToAuthForDelegation',
    'msDS-AllowedToDelegateTo',
    'msDS-AllowedToActOnBehalfOfOtherIdentity',
    'msDS-SupportedEncryptionTypes',
    'ServicePrincipalNames',
    'MemberOf',
    'AccountNotDelegated',
    'PasswordLastSet',
    'adminCount',
    'LockedOut'
)

$serviceAccountObject = $null
if ($samAccountName) {
    if ($isManagedAccount) {
        $serviceAccountObject = Get-ADServiceAccount -Identity $samAccountName.TrimEnd('$') `
            -Properties $delegationProps -ErrorAction SilentlyContinue
        Add-Item "Get-ADServiceAccount $samAccountName (gMSA/MSA)" ($serviceAccountObject | Format-List $delegationProps)

        $output.Add('')
        $output.Add('--- Test-ADServiceAccount (K34) ---')
        $output.Add((Test-ADServiceAccount -Identity $samAccountName.TrimEnd('$') -ErrorAction SilentlyContinue | Out-String))
    }
    else {
        $serviceAccountObject = Get-ADUser -Identity $samAccountName `
            -Properties $delegationProps -ErrorAction SilentlyContinue
        Add-Item "Get-ADUser $samAccountName" ($serviceAccountObject | Format-List $delegationProps)
    }

    # Protected Users membership (K30) - resolved explicitly because MemberOf
    # only shows direct membership.
    $output.Add('')
    $output.Add('--- Protected Users membership (K30) ---')
    $inProtectedUsers = $serviceAccountObject.MemberOf | Where-Object { $_ -match 'CN=Protected Users' }
    if ($inProtectedUsers) {
        $output.Add('CRITICAL: service account IS a member of Protected Users.')
        $output.Add('Microsoft: service and computer accounts must not be members - authentication will fail.')
    }
    else {
        $output.Add('Not a member of Protected Users (expected).')
    }
}

# ---------------------------------------------------------------------------
# Section 3 - Computer account attributes
# ---------------------------------------------------------------------------
Add-Section 'SECTION 3 - COMPUTER ACCOUNT (K9, K28, K29)'

$computerObject = Get-ADComputer -Identity $ComputerName -Properties @(
    'TrustedForDelegation',
    'msDS-AllowedToActOnBehalfOfOtherIdentity',
    'msDS-SupportedEncryptionTypes',
    'ServicePrincipalNames',
    'PrincipalsAllowedToDelegateToAccount',
    'operatingSystem',
    'operatingSystemVersion'
) -ErrorAction SilentlyContinue

Add-Item "Get-ADComputer $ComputerName" ($computerObject | Format-List *)

# ---------------------------------------------------------------------------
# Section 4 - Delegation target resolution (K22)
# ---------------------------------------------------------------------------
Add-Section 'SECTION 4 - DELEGATION TARGET RESOLUTION (K22)'

$delegationTargets = @($serviceAccountObject.'msDS-AllowedToDelegateTo')
if ($delegationTargets.Count -eq 0) {
    $output.Add('')
    $output.Add('msDS-AllowedToDelegateTo is empty - constrained delegation is not configured.')
    $output.Add('Expected when the instance is not a double-hop middle tier (K21 SKIP).')
}
else {
    $output.Add('')
    $output.Add("Resolving $($delegationTargets.Count) delegation target SPN(s) - each must exist on some AD account:")
    foreach ($target in $delegationTargets) {
        $resolved = & setspn.exe -Q $target 2>&1 | Out-String
        $exists   = $resolved -notmatch 'No such SPN found'
        $status   = if ($exists) { 'EXISTS' } else { 'MISSING -> K22 Critical' }
        $output.Add('')
        $output.Add("  [$status] $target")
        $output.AddRange([string[]]@(($resolved -split "`n" | ForEach-Object { "      $_" })))
    }
}

# ---------------------------------------------------------------------------
# Section 5 - Kerberos environment (K45, K38, K47)
# ---------------------------------------------------------------------------
Add-Section 'SECTION 5 - KERBEROS ENVIRONMENT (K38, K45, K47)'

Add-Item 'Cached Kerberos tickets (klist)' (& klist.exe 2>&1)

if ($DomainController) {
    Add-Item "Clock offset against $DomainController (K45 - tolerance is 5 minutes)" `
        (& w32tm.exe /stripchart /computer:$DomainController /samples:3 /dataonly 2>&1)
}
Add-Item 'Time source (K45)' (& w32tm.exe /query /source 2>&1)

# Direct service ticket request - surfaces KDC_ERR_ETYPE_NOTSUPP (K38, K47)
$fqdn = ([System.Net.Dns]::GetHostEntry($ComputerName)).HostName
Add-Item "klist get MSSQLSvc/${fqdn}:1433 (direct ticket request - K38, K47)" `
    (& klist.exe get "MSSQLSvc/${fqdn}:1433" 2>&1)

$output.Add('')
$output.Add('--- msDS-SupportedEncryptionTypes decode (K38, K47) ---')
$output.Add('Bitmask: 1=DES-CBC-CRC  2=DES-CBC-MD5  4=RC4-HMAC  8=AES128  16=AES256')
$output.Add('Common:  24 (0x18) = AES only (hardened)   28 (0x1C) = RC4+AES (transitional)')
$output.Add('         0 / unset = KDC falls back to DefaultDomainSupportedEncTypes')
foreach ($pair in @(
        @{ Label = 'Service account '; Value = $serviceAccountObject.'msDS-SupportedEncryptionTypes' },
        @{ Label = 'Computer account'; Value = $computerObject.'msDS-SupportedEncryptionTypes' })) {
    $v = $pair.Value
    $decoded = if ($null -eq $v) { 'unset (domain default applies)' }
               elseif ($v -eq 4) { '4 = RC4 ONLY -> K47 Critical if the domain enforces AES' }
               else { "$v" }
    $output.Add("  $($pair.Label): $decoded")
}

Add-Item 'KDC DefaultDomainSupportedEncTypes (K47 - read from this host)' `
    (Get-ItemProperty 'HKLM:\System\CurrentControlSet\services\KDC' `
        -Name DefaultDomainSupportedEncTypes -ErrorAction SilentlyContinue |
        Select-Object DefaultDomainSupportedEncTypes)

# ---------------------------------------------------------------------------
# Section 6 - Instance state (K5, K13, K20, K44, K52)
# ---------------------------------------------------------------------------
Add-Section 'SECTION 6 - INSTANCE STATE (K5, K13, K20, K44, K52)'

if ($ServerInstance) {
    $authQuery = @'
SELECT
    c.session_id,
    c.net_transport,
    c.auth_scheme,
    c.local_tcp_port,
    s.client_interface_name,
    s.program_name
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions AS s
    ON s.session_id = c.session_id
WHERE c.session_id = @@SPID;
'@
    if (Get-Module -ListAvailable -Name SqlServer) {
        Import-Module SqlServer -ErrorAction SilentlyContinue
        Add-Item "auth_scheme and port on $ServerInstance (K20, K44)" `
            (Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $authQuery -ErrorAction SilentlyContinue |
                Format-List *)
    }
    else {
        $output.Add('')
        $output.Add('SqlServer module not available. Run this manually against the instance:')
        $output.Add($authQuery)
    }
}
else {
    $output.Add('')
    $output.Add('-ServerInstance not supplied. Run this manually against the instance to')
    $output.Add('capture the live authentication scheme (K20) and listening port (K44):')
    $output.Add('')
    $output.Add('  SELECT net_transport, auth_scheme, local_tcp_port')
    $output.Add('  FROM sys.dm_exec_connections WHERE session_id = @@SPID;')
}

$output.Add('')
$output.Add('--- TCP port configuration (K44 - dynamic port prevents Kerberos) ---')
$output.Add('Check in SQL Server Configuration Manager:')
$output.Add('  SQL Server Network Configuration -> Protocols for <instance> -> TCP/IP')
$output.Add('  -> IP Addresses tab -> IPAll')
$output.Add('A populated "TCP Dynamic Ports" with an empty "TCP Port" means the port')
$output.Add('changes on restart and no stable SPN can be registered -> K44 Critical.')

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
$output.Add('')
$output.Add('=' * 78)
$output.Add('END OF CAPTURE')
$output.Add('=' * 78)

$output | Set-Content -Path $outputFile -Encoding UTF8

Write-Host ""
Write-Host "Capture written to: $outputFile"
Write-Host ""
Write-Host "Next step: pass this file to the sqlspn-review skill:"
Write-Host "  /sqlspn-review $outputFile"
Write-Host ""
