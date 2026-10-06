<#
.SYNOPSIS
Captures the Windows Performance Monitor counters that sqlperfmon-review analyses, or converts an
existing .blg binary log to the CSV the skill reads.

.DESCRIPTION
Two modes.

  -Mode Collect   Creates a counter log with logman, runs it for -DurationMinutes, stops it, and
                  converts the resulting .blg to CSV with relog. Needs Administrator.

  -Mode Convert   Converts an existing .blg (from an already-running collector, a PSSDIAG or SQL
                  LogScout capture, or a colleague) to CSV. No Administrator needed, and nothing
                  is created on the server.

Both modes emit the counter set the 14 PM checks read, including the per-volume LogicalDisk
instances. The _Total instance alone is not sufficient: PM8 exists because a single hot volume
disappears into the average, so the wildcard instance is deliberate.

Collection is read-only with respect to SQL Server. logman writes a counter log to -OutputPath and
touches nothing inside the instance.

.PARAMETER Mode
Collect (default) or Convert.

.PARAMETER DurationMinutes
How long to collect. Default 15. Values below 5 are rejected: PM1, PM3 and PM7 are defined on
sustained behaviour, and a shorter window cannot support them (this is what PM14 reports).

.PARAMETER IntervalSeconds
Sample interval. Default 15. Use 5 when hunting short stalls, and remember that a rate counter is
an average across the interval, so an interval longer than the event being hunted hides it.

.PARAMETER InstanceName
SQL Server instance name for a named instance. Default instance uses the SQLServer:* objects; a
named instance uses MSSQL$<InstanceName>:* instead.

.PARAMETER OutputPath
Directory for the .blg and .csv. Default C:\PerfLogs\sqlperfmon.

.PARAMETER BlgPath
Convert mode only: the existing .blg to convert.

.EXAMPLE
.\capture-perfmon.ps1 -Mode Collect -DurationMinutes 20

.EXAMPLE
.\capture-perfmon.ps1 -Mode Collect -DurationMinutes 15 -IntervalSeconds 5 -InstanceName SQL2019

.EXAMPLE
.\capture-perfmon.ps1 -Mode Convert -BlgPath C:\PSSDIAG\output\sqlhost.blg

.NOTES
Paste the resulting CSV (or attach it) to /sqlperfmon-review. Also supply cpu_count and physical
RAM, which the counters do not carry:

    SELECT cpu_count, scheduler_count, affinity_type_desc, virtual_machine_type_desc
    FROM sys.dm_os_sys_info;

Without cpu_count, PM1-PM3 are NOT ASSESSED: Process\% Processor Time runs from 0 to 100 x the
number of logical processors, so it is uninterpretable as an absolute number.
#>
[CmdletBinding()]
param(
    [ValidateSet('Collect', 'Convert')]
    [string]$Mode = 'Collect',

    [ValidateRange(5, 1440)]
    [int]$DurationMinutes = 15,

    [ValidateRange(1, 300)]
    [int]$IntervalSeconds = 15,

    [string]$InstanceName = '',

    [string]$OutputPath = 'C:\PerfLogs\sqlperfmon',

    [string]$BlgPath = ''
)

$ErrorActionPreference = 'Stop'

# SQL Server performance objects are named SQLServer:* for a default instance and
# MSSQL$<InstanceName>:* for a named one.
$sqlObject = if ([string]::IsNullOrWhiteSpace($InstanceName)) {
    'SQLServer'
} else {
    'MSSQL' + [char]36 + $InstanceName
}

$counters = @(
    # Host CPU - PM1, PM2, PM3. Not available from sys.dm_os_performance_counters.
    '\Processor(_Total)\% Processor Time'
    '\Processor(_Total)\% Privileged Time'
    '\Process(sqlservr)\% Processor Time'
    # Host memory - PM5, PM6.
    '\Process(sqlservr)\Virtual Bytes'
    '\Process(sqlservr)\Private Bytes'
    '\Process(sqlservr)\Working Set'
    '\Memory\Available MBytes'
    # Per-volume storage - PM7, PM8. The wildcard instance is required: _Total alone hides a
    # single hot volume, which is exactly what PM8 reports.
    '\LogicalDisk(*)\Avg. Disk sec/Read'
    '\LogicalDisk(*)\Avg. Disk sec/Write'
    '\LogicalDisk(*)\Avg. Disk sec/Transfer'
    '\LogicalDisk(*)\Disk Transfers/sec'
    # Engine counters - PM4, PM9-PM13. Also reachable via sys.dm_os_performance_counters.
    "\${sqlObject}:Buffer Manager\Page life expectancy"
    "\${sqlObject}:SQL Statistics\Batch Requests/sec"
    "\${sqlObject}:SQL Statistics\SQL Compilations/sec"
    "\${sqlObject}:SQL Statistics\SQL Re-Compilations/sec"
    "\${sqlObject}:SQL Statistics\SQL Attention rate"
    "\${sqlObject}:Plan Cache(*)\Cache Object Counts"
)

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Collect mode creates a counter log and requires an elevated session. Re-run as Administrator, or use -Mode Convert on an existing .blg.'
    }
}

function Convert-BlgToCsv {
    param([string]$Source)

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Binary log not found: $Source"
    }

    $csv = [IO.Path]::ChangeExtension($Source, 'csv')

    Write-Output ''
    Write-Output '--- Counters and time range in the log (relog -q) ---'
    & relog.exe $Source -q
    if ($LASTEXITCODE -ne 0) { throw "relog -q failed with exit code $LASTEXITCODE" }

    Write-Output ''
    Write-Output "--- Converting to CSV: $csv ---"
    & relog.exe $Source -f csv -o $csv -y
    if ($LASTEXITCODE -ne 0) { throw "relog conversion failed with exit code $LASTEXITCODE" }

    return $csv
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

if ($Mode -eq 'Convert') {
    if ([string]::IsNullOrWhiteSpace($BlgPath)) {
        throw 'Convert mode requires -BlgPath.'
    }
    $csvPath = Convert-BlgToCsv -Source $BlgPath
    Write-Output ''
    Write-Output "Done. Paste or attach this file to /sqlperfmon-review:"
    Write-Output "  $csvPath"
    Write-Output ''
    Write-Output 'Also supply cpu_count and physical RAM - see the .NOTES section of this script.'
    return
}

Assert-Administrator

$stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$collectorName = "sqlperfmon-$stamp"
$blgFile      = Join-Path $OutputPath "$collectorName.blg"
$counterFile  = Join-Path $OutputPath "$collectorName-counters.txt"

Set-Content -LiteralPath $counterFile -Value $counters -Encoding ASCII

Write-Output "Collector     : $collectorName"
Write-Output "Counters      : $($counters.Count) paths (see $counterFile)"
Write-Output "Interval      : $IntervalSeconds s"
Write-Output "Duration      : $DurationMinutes min"
Write-Output "Output        : $blgFile"
Write-Output ''

& logman.exe create counter $collectorName -cf $counterFile -si $IntervalSeconds -f bincirc -max 512 -o $blgFile
if ($LASTEXITCODE -ne 0) { throw "logman create failed with exit code $LASTEXITCODE" }

try {
    & logman.exe start $collectorName
    if ($LASTEXITCODE -ne 0) { throw "logman start failed with exit code $LASTEXITCODE" }

    Write-Output "Collecting until $((Get-Date).AddMinutes($DurationMinutes).ToString('HH:mm:ss')) ..."
    Write-Output 'Reproduce the problem now if it is reproducible on demand.'
    Start-Sleep -Seconds ($DurationMinutes * 60)
}
finally {
    & logman.exe stop $collectorName  2>&1 | Out-Null
    & logman.exe delete $collectorName 2>&1 | Out-Null
    Write-Output 'Collector stopped and removed.'
}

# bincirc writes the counter log with a generated suffix; take the newest match.
$produced = Get-ChildItem -Path $OutputPath -Filter "$collectorName*.blg" -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

if (-not $produced) { throw "No .blg was produced in $OutputPath." }

$csvPath = Convert-BlgToCsv -Source $produced.FullName

Write-Output ''
Write-Output 'Done. Paste or attach this file to /sqlperfmon-review:'
Write-Output "  $csvPath"
Write-Output ''
Write-Output 'Also supply cpu_count and physical RAM - see the .NOTES section of this script.'
