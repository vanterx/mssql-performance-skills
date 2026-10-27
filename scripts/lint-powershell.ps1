<#
.SYNOPSIS
    PowerShell lint gate. Runs PSScriptAnalyzer over each given .ps1 file with
    the repo's PSScriptAnalyzerSettings.psd1 and fails on any finding.

.DESCRIPTION
    A thin wrapper so CI and a local run apply exactly the same rules: the
    settings file at the repo root is the single place rules are excluded, each
    with its reason. Every severity is reported, ParseError included -- a parse
    error means a committed script cannot run at all.

.PARAMETER ListFile
    UTF-8 text file, one .ps1 path per line. Blank lines are ignored.

.PARAMETER Path
    .ps1 paths passed directly, as an alternative to -ListFile.

.PARAMETER SettingsPath
    PSScriptAnalyzer settings file. Defaults to PSScriptAnalyzerSettings.psd1
    at the repo root.

.NOTES
    Requires the PSScriptAnalyzer module:
        Install-PSResource PSScriptAnalyzer -Scope CurrentUser
    (or Install-Module on PowerShellGet v2). Exit codes: 0 = clean,
    1 = findings, 2 = the gate itself could not run.
#>
[CmdletBinding(DefaultParameterSetName = 'ListFile')]
param(
    [Parameter(ParameterSetName = 'ListFile', Mandatory)]
    [string] $ListFile,

    [Parameter(ParameterSetName = 'Path', Mandatory)]
    [string[]] $Path,

    [string] $SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Any unexpected terminating error is the gate failing to run (exit 2), never
# "findings" (exit 1) -- otherwise a crash is reported as lint errors in files.
trap {
    [Console]::Error.WriteLine("  lint-powershell: internal error -- $($_.Exception.Message)")
    exit 2
}

if ($PSCmdlet.ParameterSetName -eq 'ListFile') {
    if (-not (Test-Path -LiteralPath $ListFile)) {
        Write-Host "  lint-powershell: list file not found: $ListFile" -ForegroundColor Red
        exit 2
    }
    # @() because a one-line list yields a scalar, and StrictMode throws on .Count.
    $files = @(Get-Content -LiteralPath $ListFile |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ -ne '' })
} else {
    $files = $Path
}

if ($files.Count -eq 0) {
    Write-Host "  lint-powershell: nothing to check" -ForegroundColor DarkGray
    exit 0
}

if (-not $SettingsPath) {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
    $SettingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
}
if (-not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Host "  lint-powershell: settings file not found: $SettingsPath" -ForegroundColor Red
    exit 2
}

try {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
} catch {
    Write-Host "  lint-powershell: PSScriptAnalyzer is not installed -- Install-PSResource PSScriptAnalyzer -Scope CurrentUser" -ForegroundColor Red
    exit 2
}

# A listed file that does not exist is a finding (exit 1), like lint-tsql.ps1 --
# not "the gate could not run" (exit 2), which the driver reports as a missing
# tool and, outside --strict, skips the whole PowerShell gate for.
$missingFiles = @($files | Where-Object { -not (Test-Path -LiteralPath $_) })
foreach ($m in $missingFiles) {
    Write-Host "  lint-powershell: file not found: $m" -ForegroundColor Red
}

$findings = @(foreach ($file in $files) {
    if (Test-Path -LiteralPath $file) { Invoke-ScriptAnalyzer -Path $file -Settings $SettingsPath }
})

foreach ($f in $findings) {
    $rel = Resolve-Path -LiteralPath $f.ScriptPath -Relative
    Write-Host ("  {0}:{1}  [{2}] {3}" -f $rel, $f.Line, $f.Severity, $f.RuleName) -ForegroundColor Red
    Write-Host "      $($f.Message)"
}

$version = (Get-Module PSScriptAnalyzer).Version
$problems = $findings.Count + $missingFiles.Count
if ($problems -gt 0) {
    Write-Host ""
    Write-Host "  lint-powershell: $problems finding(s) across $($files.Count) file(s) (PSScriptAnalyzer $version)" -ForegroundColor Red
    exit 1
}

Write-Host "  lint-powershell: $($files.Count) file(s) clean (PSScriptAnalyzer $version)" -ForegroundColor Green
exit 0
