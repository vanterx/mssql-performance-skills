<#
.SYNOPSIS
    Collects SSRS trace config, server config, recent trace log errors, and
    related Event Log entries for ssrstracelog-review.

.DESCRIPTION
    Gathers the artifacts ssrstracelog-review (G1-G24) needs in one pass:
      - ReportingServicesService.exe.config <RStrace> settings
        (DefaultTraceSwitch, FileSizeLimitMb, KeepFilesForDays, component overrides) - G1, G2, G4
      - RSReportServer.config <Service> settings
        (MemorySafetyMargin, MemoryThreshold, WorkingSetMaximum, WorkingSetMinimum,
        RecycleTime, MaxAppDomainUnloadTime) - G10, G11, G13
      - Count of ReportServerService_<timestamp>.log files created in the lookback
        window (frequent rollover signal) - G3
      - ERROR/Exception lines from the most recent trace log(s) - G5-G9, G19, G20
      - Windows Application Event Log entries for source "Report Server Windows
        Service" in the lookback window - G5, G8

    Auto-detects SQL Server 2016 (MSRS13.<instance>) and SSRS 2017+ / Power BI
    Report Server (standalone "SSRS" path) layouts. Run on the report server host.

.PARAMETER InstanceName
    SSRS instance name for the 2016-style path (MSRS13.<InstanceName>). Default
    'MSSQLSERVER'. Ignored if only the 2017+ standalone path is found.

.PARAMETER Days
    How many days back to scan trace logs and the Event Log. Default 1.

.PARAMETER MaxErrorLines
    Maximum number of ERROR/Exception trace log lines to print. Default 50.

.EXAMPLE
    .\collect-ssrs-diagnostics.ps1
    Scans the last day of logs for the default instance and prints a summary.

.EXAMPLE
    .\collect-ssrs-diagnostics.ps1 -InstanceName MSSQLSERVER -Days 3 -MaxErrorLines 100
    Scans the last 3 days, printing up to 100 error lines.

.NOTES
    Requires: Windows PowerShell 5.1+ or PowerShell 7+, read access to the
    Reporting Services program files and the Application event log.
    Reference: Report server service trace log -
    https://learn.microsoft.com/sql/reporting-services/report-server/report-server-service-trace-log
    RsReportServer.config configuration file -
    https://learn.microsoft.com/sql/reporting-services/report-server/rsreportserver-config-configuration-file
#>
[CmdletBinding()]
param(
    [string]$InstanceName = 'MSSQLSERVER',
    [int]$Days = 1,
    [int]$MaxErrorLines = 50
)

$ErrorActionPreference = 'Stop'

function Resolve-SsrsRoot {
    param([string]$InstanceName)

    $candidates = @(
        "C:\Program Files\Microsoft SQL Server Reporting Services\SSRS",
        "C:\Program Files\Microsoft SQL Server\MSRS13.$InstanceName\Reporting Services",
        "C:\Program Files\Microsoft SQL Server\MSRS14.$InstanceName\Reporting Services",
        "C:\Program Files\Microsoft SQL Server\MSRS15.$InstanceName\Reporting Services",
        "C:\Program Files\Microsoft SQL Server\MSRS16.$InstanceName\Reporting Services"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

$root = Resolve-SsrsRoot -InstanceName $InstanceName
if (-not $root) {
    Write-Error "Could not find a Reporting Services install path. Checked standard SQL 2016-2022 and standalone SSRS locations."
    exit 1
}

Write-Host "=== SSRS root: $root ===" -ForegroundColor Cyan

$binPath    = Join-Path $root 'ReportServer\bin'
$rsConfig   = Join-Path $root 'ReportServer\RSReportServer.config'
$traceCfg   = Join-Path $binPath 'ReportingServicesService.exe.config'
$logDir     = Join-Path $root 'LogFiles'

# --- RStrace settings (G1, G2, G4) -----------------------------------------
Write-Host "`n--- ReportingServicesService.exe.config <RStrace> (G1, G2, G4) ---" -ForegroundColor Yellow
if (Test-Path $traceCfg) {
    try {
        [xml]$traceXml = Get-Content $traceCfg
        $rstrace = $traceXml.configuration.SelectNodes("//RStrace/add")
        if ($rstrace) {
            foreach ($add in $rstrace) {
                Write-Host ("{0,-28} = {1}" -f $add.name, $add.value)
            }
        } else {
            Write-Host "No <RStrace> <add> entries found (defaults apply: DefaultTraceSwitch=3, FileSizeLimitMb=32, KeepFilesForDays=14)."
        }
    } catch {
        Write-Warning "Failed to parse $traceCfg : $_"
    }
} else {
    Write-Warning "Not found: $traceCfg"
}

# --- RSReportServer.config <Service> settings (G10, G11, G13) --------------
Write-Host "`n--- RSReportServer.config <Service> (G10, G11, G13) ---" -ForegroundColor Yellow
if (Test-Path $rsConfig) {
    try {
        [xml]$rsXml = Get-Content $rsConfig
        $serviceNode = $rsXml.Configuration.Service
        if ($serviceNode) {
            $watched = 'MemorySafetyMargin','MemoryThreshold','WorkingSetMaximum',
                       'WorkingSetMinimum','RecycleTime','MaxAppDomainUnloadTime',
                       'PollingInterval','MaxQueueThreads','UrlRoot'
            foreach ($name in $watched) {
                $value = $serviceNode.$name
                if ($null -ne $value -and $value -ne '') {
                    Write-Host ("{0,-24} = {1}" -f $name, $value)
                } else {
                    Write-Host ("{0,-24} = (not set / default)" -f $name)
                }
            }
        } else {
            Write-Warning "No <Service> section found in $rsConfig"
        }
    } catch {
        Write-Warning "Failed to parse $rsConfig : $_"
    }
} else {
    Write-Warning "Not found: $rsConfig"
}

# --- Trace log rollover frequency (G3) --------------------------------------
Write-Host "`n--- Trace log files in the last $Days day(s) (G3) ---" -ForegroundColor Yellow
if (Test-Path $logDir) {
    $cutoff = (Get-Date).AddDays(-$Days)
    $recentLogs = Get-ChildItem -Path $logDir -Filter 'ReportServerService_*.log' |
        Where-Object { $_.LastWriteTime -ge $cutoff } |
        Sort-Object LastWriteTime
    Write-Host "Found $($recentLogs.Count) ReportServerService_*.log file(s)."
    foreach ($f in $recentLogs) {
        Write-Host ("  {0}  {1,10:N0} KB  {2}" -f $f.LastWriteTime, [math]::Round($f.Length/1KB), $f.Name)
    }
    if ($recentLogs.Count -gt 3) {
        Write-Host "Multiple trace log files in a short window can indicate repeated service restarts - see G3." -ForegroundColor Magenta
    }
} else {
    Write-Warning "Not found: $logDir"
}

# --- ERROR lines from the most recent trace log (G5-G9, G19, G20) -----------
Write-Host "`n--- Recent ERROR/Exception lines (G5-G9, G19, G20) ---" -ForegroundColor Yellow
if (Test-Path $logDir) {
    $latest = Get-ChildItem -Path $logDir -Filter 'ReportServerService_*.log' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Write-Host "Scanning $($latest.Name) ..."
        $errors = Select-String -Path $latest.FullName -Pattern 'ERROR|Exception' |
            Select-Object -Last $MaxErrorLines
        if ($errors) {
            $errors | ForEach-Object { Write-Host $_.Line }
        } else {
            Write-Host "No ERROR/Exception lines found in $($latest.Name)."
        }
    } else {
        Write-Warning "No ReportServerService_*.log files found in $logDir"
    }
}

# --- Event Log entries (G5, G8) ---------------------------------------------
Write-Host "`n--- Application Event Log: 'Report Server Windows Service' (G5, G8) ---" -ForegroundColor Yellow
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        StartTime = (Get-Date).AddDays(-$Days)
    } -ErrorAction Stop | Where-Object { $_.ProviderName -like '*Report Server*' }

    if ($events) {
        $events | Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Format-Table -Wrap -AutoSize | Out-String -Width 200 | Write-Host
    } else {
        Write-Host "No 'Report Server Windows Service' events in the last $Days day(s)."
    }
} catch {
    Write-Warning "Failed to query Application event log: $_"
}

Write-Host "`n=== Done. Paste the relevant sections above into ssrstracelog-review. ===" -ForegroundColor Cyan
