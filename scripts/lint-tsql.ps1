<#
.SYNOPSIS
    T-SQL syntax gate. Parses every .sql file, and every ```sql fenced block in
    every .md file, with Microsoft's T-SQL parser and fails if one does not parse.

.DESCRIPTION
    Uses Microsoft.SqlServer.TransactSql.ScriptDom, Microsoft's T-SQL parser
    library (the one DacFx and SqlPackage build on). It is used rather than a
    third-party SQL linter for coverage: this repo leans on the advanced corners
    of T-SQL, and sqlfluff 4.4.0's tsql dialect rejects even
    `DROP EVENT SESSION [x] ON SERVER`, so a sqlfluff gate would have to exclude
    exactly the most intricate capture scripts to stay green.

    ScriptDom is not the database engine's parser, though, and it has gaps of
    its own. It rejects some syntax Microsoft Learn documents -- several
    ALTER AVAILABILITY GROUP replica and listener options, ALTER ENDPOINT
    without ROLE, ALTER DATABASE SET ENCRYPTION SUSPEND. Blocks that hit one
    carry a `parser-gap` skip marker naming the construct (see below), so each
    exemption is visible and was checked against the docs, not assumed.

    This is a SYNTAX gate, not a style gate. It answers one question -- does
    Microsoft's T-SQL grammar accept this batch? -- which is the class of defect
    commit bff84c5 ("correct invalid columns, syntax and runtime bugs in SQL
    capture scripts") had to find by hand. It does not resolve object names, so
    a wrong column name still parses; only MS Learn validation and a live
    instance catch that. Nor does it check that an option is valid for the
    statement it appears in beyond what the grammar encodes.

    The assembly is not vendored. It is fetched once from nuget.org, pinned to
    an exact version, and verified against a known SHA-256 before it is loaded.
    A hash mismatch is a hard failure -- the script will not load an assembly it
    cannot vouch for. Cached under .lint-cache/ (gitignored) so later runs are
    offline. Point -ScriptDomPath at a local DLL on an air-gapped host.

.PARAMETER ListFile
    UTF-8 text file, one .sql or .md path per line. Blank lines are ignored.
    Paths are resolved relative to the current directory, and should be
    repo-relative (as `git ls-files` prints them) for -Baseline to match.

.PARAMETER Path
    .sql or .md paths passed directly, as an alternative to -ListFile.

.PARAMETER ScriptDomPath
    Full path to an existing Microsoft.SqlServer.TransactSql.ScriptDom.dll.
    Skips the download and hash check entirely.

.PARAMETER ParserVersion
    ScriptDom parser generation. Default 170 = SQL Server 2025, a superset of
    every earlier grammar. The docs reference SQL Server 2025 and Azure SQL
    syntax (ALTER DATABASE ... SET OPTIMIZED_LOCKING, for one), which TSql160
    rejects; a gate that fails valid documented syntax would just teach people
    to add skip markers. Pass 160 to check that a script stays 2022-compatible.

.PARAMETER CacheDir
    Where to keep the downloaded assembly. Defaults to .lint-cache/ at the repo
    root.

.PARAMETER Baseline
    Tab-separated file of known-broken Markdown blocks: <hash> <path> <note>.
    A failing block whose content hash is listed is reported as "known" rather
    than failing the gate. The hash covers the block's text, so editing the
    block -- which is what fixing it means -- drops it out of the baseline and
    it must then parse. An entry matching no failing block (fixed, moved to
    another file, or deleted) fails the gate until it is removed, so the file
    only ever shrinks. It is for real defects awaiting a fix; deliberate
    fragments use the in-document skip marker instead.

.PARAMETER EmitBaseline
    Print baseline lines for every failing block not already baselined, then
    exit 0. Paste the output into the baseline file by hand, with a note per
    line -- the point is that each entry is a decision, not a bulk mute.

.EXAMPLE
    pwsh -NoProfile -File scripts/lint-tsql.ps1 -Path skills/sqlag-review/scripts/capture-ag-config.sql

.EXAMPLE
    git ls-files '*.sql' > list.txt
    pwsh -NoProfile -File scripts/lint-tsql.ps1 -ListFile list.txt

.NOTES
    Runs on PowerShell 5.1 (net472 assembly) and PowerShell 7+ (net8.0).
    Exit codes: 0 = every file parsed, 1 = at least one did not, 2 = the gate
    itself could not run (no assembly, hash mismatch, bad arguments).
#>
[CmdletBinding(DefaultParameterSetName = 'ListFile')]
param(
    [Parameter(ParameterSetName = 'ListFile', Mandatory)]
    [string] $ListFile,

    [Parameter(ParameterSetName = 'Path', Mandatory)]
    [string[]] $Path,

    [string] $ScriptDomPath,

    [ValidateSet('150', '160', '170')]
    [string] $ParserVersion = '170',

    [string] $CacheDir,

    [string] $Baseline,

    [switch] $EmitBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Any unexpected terminating error is the gate failing to run (exit 2), never
# "findings" (exit 1) -- otherwise a crash is reported as lint errors in files.
trap {
    [Console]::Error.WriteLine("  lint-tsql: internal error -- $($_.Exception.Message)")
    exit 2
}

# Pinned package. Bump all four values together, and only after re-verifying
# them against a fresh nuget.org download -- these hashes are the only thing
# standing between this gate and loading an arbitrary assembly. The DLL hashes
# are checked on EVERY run, cached or not, so a tampered or half-extracted
# .lint-cache/ is refused rather than trusted.
$PackageId      = 'microsoft.sqlserver.transactsql.scriptdom'
$PackageVersion = '180.140.0'
$PackageSha256  = 'E41DBE9238694C68D3A165C11880F9332905B4BB9759A604B1797BB3F282D217'
$DllSha256      = @{
    'net8.0' = '1F95F522E68D6232430FB2C00280F16F248BEF46B50CB4FBC1FFD555EDBF1604'
    'net472' = '5285A719B034730847284C514D454614BAE137F4AEF79868A1455ABFDC6BAF0B'
}

# Diagnostics. In -EmitBaseline mode stdout carries only baseline TSV, so every
# human-readable line goes to stderr instead.
function Write-Diag {
    param([string] $Text, [string] $Color = 'Gray')
    if ($EmitBaseline) { [Console]::Error.WriteLine($Text) } else { Write-Host $Text -ForegroundColor $Color }
}

function Write-GateError {
    param([string] $Message)
    Write-Diag "  lint-tsql: $Message" 'Red'
}

# Repo-relative, forward slashes, no leading ./ -- the form git prints and the
# baseline uses, so a path matches whichever way it was passed in.
function ConvertTo-RepoPath {
    param([string] $Value)
    return (($Value -replace '\\', '/') -replace '^\./', '')
}

# Returns the path to a ScriptDom assembly, downloading and verifying it on
# first use. Throws if it cannot produce one it trusts.
function Resolve-ScriptDomAssembly {
    param([string] $Version, [string] $Cache)

    # The package ships a build per runtime; load the one matching this edition.
    $tfm = if ($PSVersionTable.PSEdition -eq 'Core') { 'net8.0' } else { 'net472' }

    $versionDir = Join-Path $Cache "scriptdom-$Version"
    $dll        = Join-Path (Join-Path $versionDir $tfm) 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'
    if (Test-Path -LiteralPath $dll) {
        if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -eq $DllSha256[$tfm]) { return $dll }
        # Tampered, corrupt, or left half-copied by an interrupted run: discard
        # the whole cached version and rebuild it from a verified download.
        Write-Diag "  lint-tsql: cached ScriptDom failed its hash check -- discarding and re-fetching" 'Yellow'
        Remove-Item -LiteralPath $versionDir -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
    $nupkg = Join-Path $versionDir "$PackageId.$Version.nupkg"

    if (-not (Test-Path -LiteralPath $nupkg)) {
        $uri = "https://api.nuget.org/v3-flatcontainer/$PackageId/$Version/$PackageId.$Version.nupkg"
        Write-Diag "  lint-tsql: fetching ScriptDom $Version from nuget.org (one time, then cached)" 'DarkGray'
        try {
            $previous = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $uri -OutFile $nupkg -UseBasicParsing
        } catch {
            throw "could not download ScriptDom $Version from nuget.org: $($_.Exception.Message)"
        } finally {
            $ProgressPreference = $previous
        }
    }

    $actual = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash
    if ($actual -ne $PackageSha256) {
        Remove-Item -LiteralPath $nupkg -Force -ErrorAction SilentlyContinue
        throw ("ScriptDom $Version SHA-256 mismatch -- refusing to load it.`n" +
               "           expected $PackageSha256`n" +
               "           actual   $actual`n" +
               "           The cached copy has been deleted. If the pinned version was " +
               "bumped without updating PackageSha256, fix that; otherwise treat this as a " +
               "supply-chain failure and do not re-run until it is explained.")
    }

    # A .nupkg is a zip. Expand-Archive wants the extension to say so.
    $zip = [System.IO.Path]::ChangeExtension($nupkg, '.zip')
    Copy-Item -LiteralPath $nupkg -Destination $zip -Force
    $staging = Join-Path $versionDir 'staging'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
    Remove-Item -LiteralPath $zip -Force

    $libDir = Join-Path (Join-Path $staging 'lib') $tfm
    if (-not (Test-Path -LiteralPath $libDir)) {
        throw "ScriptDom $Version package has no lib/$tfm -- cannot support this PowerShell edition."
    }
    Copy-Item -LiteralPath $libDir -Destination (Join-Path $versionDir $tfm) -Recurse -Force
    Remove-Item -LiteralPath $staging -Recurse -Force

    if (-not (Test-Path -LiteralPath $dll)) {
        throw "ScriptDom $Version extracted but $dll is missing."
    }
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $DllSha256[$tfm]) {
        Remove-Item -LiteralPath $versionDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "ScriptDom $Version $tfm DLL does not match its pinned SHA-256 -- refusing to load it."
    }
    return $dll
}

# --- resolve the file list ---------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'ListFile') {
    if (-not (Test-Path -LiteralPath $ListFile)) {
        Write-GateError "list file not found: $ListFile"
        exit 2
    }
    # @() because a one-line list yields a scalar string, and StrictMode Latest
    # throws on .Count against a scalar.
    $files = @(Get-Content -LiteralPath $ListFile |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ -ne '' })
} else {
    $files = $Path
}

if (-not $files -or $files.Count -eq 0) {
    Write-Host "  lint-tsql: nothing to check" -ForegroundColor DarkGray
    exit 0
}

# --- load the parser ---------------------------------------------------------

if (-not $CacheDir) {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
    $CacheDir = Join-Path $repoRoot '.lint-cache'
}

try {
    $dll = if ($ScriptDomPath) {
        if (-not (Test-Path -LiteralPath $ScriptDomPath)) {
            throw "-ScriptDomPath does not exist: $ScriptDomPath"
        }
        $ScriptDomPath
    } else {
        Resolve-ScriptDomAssembly -Version $PackageVersion -Cache $CacheDir
    }
    Add-Type -LiteralPath $dll
} catch {
    Write-GateError $_.Exception.Message
    exit 2
}

$parserType = "Microsoft.SqlServer.TransactSql.ScriptDom.TSql${ParserVersion}Parser" -as [type]
if (-not $parserType) {
    Write-GateError "ScriptDom $PackageVersion exposes no TSql${ParserVersion}Parser."
    exit 2
}

# $true = QUOTED_IDENTIFIER ON, which is what SSMS, sqlcmd and the drivers all
# default to, so it is the setting these scripts will actually run under.
$parser = $parserType::new($true)

# --- collect parse units -----------------------------------------------------

# A .sql file is one unit. A .md file yields one unit per ```sql fenced block,
# carrying the fence's line number so errors report against the Markdown line
# a reader would open, not a line inside an extracted temp file.
#
# Opt-out: put  <!-- lint-tsql: skip <kind>: <reason> -->  as the whole line
# directly before the fence. It is for blocks that are correct as documentation
# but are not a runnable batch, and <kind> must be one of:
#   fragment:       a WHERE/CASE/OPTION clause, `...` elisions, <placeholders>
#   parser-gap:     syntax Microsoft Learn documents but ScriptDom rejects
#                   (Always On replica options, ALTER ENDPOINT without ROLE)
#   removed-syntax: deliberately shows syntax SQL Server no longer accepts (*=)
# A missing or unrecognised kind fails the gate: a marker nobody can justify
# later is indistinguishable from a muted bug. Real defects do not get a marker;
# they go in the -Baseline file, which shrinks. The marker must be the entire
# line, so prose that merely quotes the syntax above a fence exempts nothing.
#
# Fences: ``` or ~~~ (three or more), language sql / tsql / t-sql in any case,
# optionally followed by an info string. A block closes only on the same fence
# character repeated at least as many times, per CommonMark.
$fenceOpen   = '^\s*(?<fence>`{3,}|~{3,})\s*(?:t-?sql|sql)\b[^`]*$'
$skipMarker  = '^\s*<!--\s*lint-tsql:\s*skip\b(?<reason>.*?)-->\s*$'
$reasonKind  = '^(fragment|parser-gap|removed-syntax):\s*\S'

function Get-SqlUnit {
    param([string] $File)

    if ([System.IO.Path]::GetExtension($File) -ne '.md') {
        return [pscustomobject]@{ Kind = 'unit'; Offset = 0; Text = [System.IO.File]::ReadAllText($File) }
    }

    $lines = [System.IO.File]::ReadAllLines($File)
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -notmatch $fenceOpen) { $i++; continue }

        $fence      = $Matches['fence']
        $fenceClose = '^\s*' + [regex]::Escape($fence[0]) + '{' + $fence.Length + ',}\s*$'
        $fenceLine  = $i + 1           # 1-based line of the opening fence
        $marker = if ($i -gt 0 -and $lines[$i - 1] -match $skipMarker) { $Matches['reason'].Trim() } else { $null }

        $body = [System.Collections.Generic.List[string]]::new()
        $i++
        while ($i -lt $lines.Count -and $lines[$i] -notmatch $fenceClose) {
            $body.Add($lines[$i]); $i++
        }
        if ($i -ge $lines.Count) {
            # Never closed: everything after the fence would otherwise be read
            # as one block (or, under a skip marker, silently exempted).
            [pscustomobject]@{ Kind = 'unterminated'; Offset = $fenceLine; Text = '' }
            return
        }
        $i++                           # step past the closing fence

        if ($null -ne $marker) {
            $kind = if ($marker -eq '') { 'bare-skip' } elseif ($marker -notmatch $reasonKind) { 'bad-skip' } else { 'skipped' }
            [pscustomobject]@{ Kind = $kind; Offset = $fenceLine; Text = $marker }
            continue
        }
        if (($body -join '').Trim() -ne '') {
            [pscustomobject]@{ Kind = 'unit'; Offset = $fenceLine; Text = $body -join "`n" }
        }
    }
}

# Content hash for baseline matching: line endings normalised so a CRLF
# checkout and an LF CI runner agree, then the first 12 hex digits of SHA-256.
function Get-UnitHash {
    param([string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Text -replace "`r", ''))
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (-join ($hash[0..5] | ForEach-Object { $_.ToString('x2') }))
}

# --- load the baseline -------------------------------------------------------

$known = @{}                           # "hash`tpath" -> note
if ($Baseline) {
    if (-not (Test-Path -LiteralPath $Baseline)) {
        Write-GateError "baseline file not found: $Baseline"
        exit 2
    }
    foreach ($line in Get-Content -LiteralPath $Baseline) {
        if ($line -match '^\s*(#|$)') { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3 -or $parts[0] -notmatch '^[0-9a-f]{12}$' -or $parts[2].Trim() -eq '') {
            Write-GateError "malformed baseline line (want: hash<TAB>path<TAB>note): $line"
            exit 2
        }
        $known["$($parts[0])`t$($parts[1])"] = $parts[2]
    }
}

# --- parse -------------------------------------------------------------------

$badUnits   = 0
$unitCount  = 0
$knownHits  = 0
$skipCount  = 0
$matchedKey = @{}
$emitted    = [System.Collections.Generic.List[string]]::new()

$markerProblem = @{
    'bare-skip'    = 'skip marker has no reason -- write "<kind>: <why this block is exempt>"'
    'bad-skip'     = 'skip reason must start with fragment:, parser-gap:, or removed-syntax:'
    'unterminated' = 'sql fence is never closed -- the rest of the file would be swallowed'
}

foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file)) {
        Write-GateError "file not found: $file"
        $badUnits++
        continue
    }
    $relPath = ConvertTo-RepoPath $file

    foreach ($unit in Get-SqlUnit -File (Resolve-Path -LiteralPath $file).Path) {
        if ($unit.Kind -eq 'skipped') { $skipCount++; continue }
        if ($markerProblem.ContainsKey($unit.Kind)) {
            $badUnits++
            Write-Diag "  ${file}:$($unit.Offset)" 'Red'
            Write-Diag "      lint-tsql: $($markerProblem[$unit.Kind])"
            continue
        }

        $unitCount++
        $errors = $null
        $reader = [System.IO.StringReader]::new($unit.Text)
        try {
            $null = $parser.Parse($reader, [ref] $errors)
        } finally {
            $reader.Dispose()
        }
        if ($errors.Count -eq 0) { continue }

        $key = if ($unit.Offset -gt 0) { "$(Get-UnitHash $unit.Text)`t$relPath" } else { $null }
        if ($key -and $known.ContainsKey($key)) {
            $knownHits++
            $matchedKey[$key] = $true
            continue
        }
        if ($EmitBaseline -and $key) {
            $first = $errors[0]
            $emitted.Add("$key`tTODO line $($first.Line + $unit.Offset): $($first.Message)")
            continue
        }

        $badUnits++
        $where = if ($unit.Offset -gt 0) { "${file}:$($unit.Offset)" } else { $file }
        Write-Diag "  $where" 'Red'
        foreach ($e in $errors) {
            Write-Diag ("      line {0}, col {1}  [{2}] {3}" -f ($e.Line + $unit.Offset), $e.Column, $e.Number, $e.Message)
        }
    }
}

if ($EmitBaseline) {
    $emitted | ForEach-Object { Write-Output $_ }
    # Failures that cannot be baselined (a .sql file, a bad marker, a missing
    # file) were reported on stderr; they still fail the run.
    if ($badUnits -gt 0) { exit 1 }
    exit 0
}

# Stale entries: listed, in a file this run covered, but no longer failing.
# Only files in this run count, so linting a subset never reports the rest stale.
$linted = @{}
foreach ($f in $files) { $linted[(ConvertTo-RepoPath $f)] = $true }
foreach ($key in $known.Keys) {
    # Not $path: variable names are case-insensitive, so that would assign to the
    # [string[]] $Path parameter and coerce the string into a one-element array,
    # and ContainsKey(<array>) is never true -- stale detection would silently die.
    $entryPath = ($key -split "`t", 2)[1]
    if ($linted.ContainsKey($entryPath) -and -not $matchedKey.ContainsKey($key)) {
        $badUnits++
        Write-Diag "  $Baseline" 'Red'
        Write-Diag "      stale entry $($key -replace "`t", '  ') -- that block now parses or no longer exists; delete the line"
    }
}

$knownNote = if ($knownHits -gt 0) { ", $knownHits known-broken (baselined)" } else { '' }
$skipNote  = if ($skipCount -gt 0) { ", $skipCount skipped by marker" } else { '' }
if ($badUnits -gt 0) {
    Write-Diag ""
    Write-GateError "$badUnits failing unit(s) of $unitCount across $($files.Count) file(s)$knownNote$skipNote"
    exit 1
}

Write-Diag "  lint-tsql: $($unitCount - $knownHits) of $unitCount T-SQL unit(s) across $($files.Count) file(s) parse clean$knownNote$skipNote (ScriptDom $PackageVersion, TSql$ParserVersion)" 'Green'
exit 0
