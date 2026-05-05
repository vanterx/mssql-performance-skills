<#
.SYNOPSIS
    Deploys the DMV Collection Framework to a SQL Server instance.

.DESCRIPTION
    Uses Invoke-Sqlcmd to deploy individual collectors or the full collection
    framework (schema, tables, stored procedures, optional Agent job).
    Always runs 00_bootstrap.sql first to create the shared prerequisites.

.PARAMETER ServerInstance
    SQL Server instance name. Examples: 'SQL01', 'SQL01\PROD', '.\SQLEXPRESS', '.'

.PARAMETER Database
    Target database for the collect schema. Created if it does not exist.
    Default: DBAMonitor

.PARAMETER JobName
    Display name for the SQL Agent job.
    Default: 'DBAMonitor - Collect DMV Stats'

.PARAMETER Collectors
    One or more collectors to deploy. Use 'All' to deploy everything.
    Valid values: All, ProcStats, WaitStats, QueryStats, FileIo, Memory, PerfCounters
    Default: All

.PARAMETER IncludeAgentJob
    When specified, deploys the SQL Agent job (05_create_agent_job.sql).
    Requires SQL Server Agent to be running on the target instance.

.PARAMETER AgentJobIntervalMinutes
    Collection interval for the Agent job schedule. Default: 5

.PARAMETER Credential
    PSCredential for SQL Server authentication. Omit for Windows auth.

.PARAMETER TrustServerCertificate
    Passes -TrustServerCertificate to Invoke-Sqlcmd. Required when the SQL Server
    uses a self-signed certificate (common on developer instances and Azure SQL MI).

.PARAMETER WhatIf
    Prints which files would be deployed without executing any SQL.

.EXAMPLE
    # Deploy everything with Windows auth
    .\Deploy-DmvCollection.ps1 -ServerInstance 'SQL01\PROD' -Collectors All -IncludeAgentJob

.EXAMPLE
    # Deploy to a custom database
    .\Deploy-DmvCollection.ps1 -ServerInstance 'SQL02' -Database 'Monitoring' -Collectors All

.EXAMPLE
    # Deploy only wait stats collector
    .\Deploy-DmvCollection.ps1 -ServerInstance '.' -Collectors WaitStats

.EXAMPLE
    # Deploy multiple collectors
    .\Deploy-DmvCollection.ps1 -ServerInstance 'SQL03' -Collectors ProcStats, QueryStats, WaitStats

.EXAMPLE
    # Deploy with SQL auth
    $cred = Get-Credential
    .\Deploy-DmvCollection.ps1 -ServerInstance 'SQL01' -Credential $cred -Collectors All -IncludeAgentJob

.EXAMPLE
    # Preview without executing
    .\Deploy-DmvCollection.ps1 -ServerInstance 'SQL01' -Collectors All -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, HelpMessage = 'SQL Server instance (e.g. SQL01\PROD or .)')]
    [string] $ServerInstance,

    [string] $Database                = 'DBAMonitor',

    [string] $JobName                 = 'DBAMonitor - Collect DMV Stats',

    [ValidateSet('All', 'ProcStats', 'WaitStats', 'QueryStats', 'FileIo', 'Memory', 'PerfCounters')]
    [string[]] $Collectors            = @('All'),

    [switch] $IncludeAgentJob,

    [ValidateRange(1, 1440)]
    [int]    $AgentJobIntervalMinutes = 5,

    [System.Management.Automation.PSCredential] $Credential,

    [switch] $TrustServerCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve script directory ──────────────────────────────────────────────────
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path $MyInvocation.MyCommand.Path }

# ── Collector → file mapping ─────────────────────────────────────────────────
$collectorFiles = [ordered]@{
    ProcStats    = @('01_create_tables.sql', '02_usp_collect_procstats.sql', '03_usp_calculate_deltas.sql')
    WaitStats    = @('06_usp_collect_wait_stats.sql')
    QueryStats   = @('07_usp_collect_query_stats.sql')
    FileIo       = @('08_usp_collect_file_io.sql')
    Memory       = @('09_usp_collect_memory.sql')
    PerfCounters = @('10_usp_collect_perf_counters.sql')
}

# ── Build Invoke-Sqlcmd base parameters ──────────────────────────────────────
$sqlBase = @{
    ServerInstance  = $ServerInstance
    Database        = $Database
    OutputSqlErrors = $true
    AbortOnError    = $true
    ConnectionTimeout = 30
    QueryTimeout    = 300
    Variable        = @("Database=$Database", "JobName=$JobName")
}
if ($Credential)             { $sqlBase.Credential             = $Credential }
if ($TrustServerCertificate) { $sqlBase.TrustServerCertificate = $true }

# ── Helper: run one .sql file ─────────────────────────────────────────────────
function Invoke-SqlFile {
    param(
        [string]    $FileName,
        [hashtable] $ParamOverrides = @{}
    )

    $filePath = Join-Path $scriptDir $FileName
    if (-not (Test-Path $filePath)) {
        Write-Warning "File not found — skipping: $filePath"
        return
    }

    $merged = $sqlBase.Clone()
    foreach ($k in $ParamOverrides.Keys) { $merged[$k] = $ParamOverrides[$k] }

    if ($WhatIfPreference -or $WhatIf) {
        Write-Host "  [WhatIf] $FileName" -ForegroundColor Yellow
        return
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-Sqlcmd @merged -InputFile $filePath
        $sw.Stop()
        Write-Host ('  {0,-48} {1,6} ms' -f "OK  $FileName", $sw.ElapsedMilliseconds) -ForegroundColor Green
    }
    catch {
        $sw.Stop()
        Write-Host ('  {0,-48} FAILED' -f "ERR $FileName") -ForegroundColor Red
        throw
    }
}

# ── Determine which collectors to deploy ──────────────────────────────────────
$deployAll = 'All' -in $Collectors

$selectedCollectors = if ($deployAll) {
    $collectorFiles.Keys   # all in defined order
} else {
    # Preserve the defined order for selected collectors
    $collectorFiles.Keys | Where-Object { $_ -in $Collectors }
}

# ── Header ────────────────────────────────────────────────────────────────────
$collectorLabel = if ($deployAll) { 'All collectors' } else { $Collectors -join ', ' }
$whatIfLabel    = if ($WhatIfPreference -or $WhatIf) { ' [WhatIf]' } else { '' }

Write-Host ''
Write-Host "DMV Collection Framework Deployment$whatIfLabel" -ForegroundColor Cyan
Write-Host "  Server     : $ServerInstance"
Write-Host "  Database   : $Database"
Write-Host "  Collectors : $collectorLabel"
if ($IncludeAgentJob) {
    Write-Host "  Agent job  : $JobName (every $AgentJobIntervalMinutes min)"
}
Write-Host ''

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$fileCount = 0

# ── Step 1: Bootstrap (always) ───────────────────────────────────────────────
Write-Host 'Step 1/3  Bootstrap prerequisites' -ForegroundColor White
Invoke-SqlFile '00_bootstrap.sql'
$fileCount++

# ── Step 2: Deploy selected collectors ───────────────────────────────────────
Write-Host "Step 2/3  Collectors ($collectorLabel)" -ForegroundColor White

foreach ($collector in $selectedCollectors) {
    Write-Host "  [$collector]" -ForegroundColor DarkCyan
    foreach ($file in $collectorFiles[$collector]) {
        Invoke-SqlFile $file
        $fileCount++
    }
}

# Deploy usp_CollectAll only when all collectors are selected
if ($deployAll) {
    Write-Host '  [CollectAll]' -ForegroundColor DarkCyan
    Invoke-SqlFile '11_usp_collect_all.sql'
    $fileCount++
}

# ── Step 3: Agent job (optional) ─────────────────────────────────────────────
Write-Host "Step 3/3  Agent job" -ForegroundColor White

if ($IncludeAgentJob) {
    # Agent job script targets msdb — override Database and add AgentJobIntervalMinutes variable
    $agentOverrides = @{
        Database = 'msdb'
        Variable = @(
            "Database=$Database",
            "JobName=$JobName",
            "IntervalMinutes=$AgentJobIntervalMinutes"
        )
    }
    Invoke-SqlFile '05_create_agent_job.sql' -ParamOverrides $agentOverrides
    $fileCount++
} else {
    Write-Host '  (skipped — use -IncludeAgentJob to deploy the Agent job)' -ForegroundColor DarkGray
}

# ── Summary ───────────────────────────────────────────────────────────────────
$totalSw.Stop()
Write-Host ''
Write-Host ('Done. {0} file(s) deployed in {1} ms.' -f $fileCount, $totalSw.ElapsedMilliseconds) -ForegroundColor Cyan

if (-not ($WhatIfPreference -or $WhatIf)) {
    Write-Host ''
    Write-Host 'Verify deployment:' -ForegroundColor White
    Write-Host "  Invoke-Sqlcmd -ServerInstance '$ServerInstance' -Database '$Database' -Query ``"
    Write-Host "    SELECT TOP 5 * FROM collect.collection_log ORDER BY log_id DESC``"
    Write-Host ''
    Write-Host 'Run a manual collection:'
    Write-Host "  Invoke-Sqlcmd -ServerInstance '$ServerInstance' -Database '$Database' -Query ``"
    Write-Host "    EXECUTE collect.usp_CollectAll @debug = 1``"
}
