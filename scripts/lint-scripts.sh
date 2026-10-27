#!/usr/bin/env bash
# lint-scripts.sh — lint the executable parts of this repo.
#
# verify-docs.sh is the gate for documentation structure. This is the gate for
# code, and for the T-SQL readers copy out of the documentation:
#
#   *.py           ruff               rules: ruff.toml
#   *.ps1          PSScriptAnalyzer   rules: PSScriptAnalyzerSettings.psd1
#   *.sql + *.md   ScriptDom parse    every .sql file, and every ```sql block in
#                                     every .md file (scripts/lint-tsql.ps1);
#                                     known defects: scripts/lint-tsql-baseline.tsv
#
# Usage:
#   bash scripts/lint-scripts.sh            # a missing linter is a WARN and is skipped
#   bash scripts/lint-scripts.sh --strict   # a missing linter is a FAIL (CI uses this)
#
# Files come from git (tracked plus untracked-but-not-ignored), so backup/ and
# node_modules/ are never linted and a new file is linted before it is staged.
# Exits non-zero on any FAIL.

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

STRICT=0
case "${1:-}" in
    --strict) STRICT=1 ;;
    "") ;;
    *) echo "usage: bash scripts/lint-scripts.sh [--strict]" >&2; exit 2 ;;
esac

PASS=0; WARN=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
warn() { echo "  WARN  $1"; WARN=$((WARN+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

# A linter that is not installed: skipped locally, fatal under --strict.
missing() {
    if [ "$STRICT" -eq 1 ]; then fail "$1 not available — $2"; else warn "$1 not available, SKIPPED — $2"; fi
}

# File lists live in .lint-cache/ (gitignored) under relative paths, because
# pwsh on Windows cannot open a Git Bash /tmp path.
mkdir -p .lint-cache
# Writes the matching files to $1, one per line, and sets LIST_COUNT. A git
# failure (not a repo, dubious ownership, index lock) aborts the whole run: an
# empty list would otherwise read as "no files" and every gate would PASS.
# Called directly, never inside $(...), so that `exit` ends the script and not
# just a subshell. Files deleted in the working tree but still in the index are
# dropped, since there is nothing on disk to lint.
list_files() {  # $1 = output file, rest = pathspecs
    out="$1"; shift
    if ! git ls-files --cached --others --exclude-standard -- "$@" > "$out.raw"; then
        echo "  FAIL  git ls-files failed — cannot build the file list, refusing to report a pass"
        exit 1
    fi
    sort -u "$out.raw" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done > "$out"
    rm -f "$out.raw"
    LIST_COUNT=$(wc -l < "$out" | tr -d ' ')
}

echo ""
echo "mssql-performance-skills — Script Linting"
echo "========================================="

# ---------------------------------------------------------------------------
# Python — ruff
# ---------------------------------------------------------------------------
echo ""
echo "[ py ] ruff"
list_files .lint-cache/py-files.txt '*.py'; py_count=$LIST_COUNT
if [ "$py_count" -eq 0 ]; then
    pass "no Python files"
elif [ ! -f ruff.toml ]; then
    # Never fall back to ruff's defaults: a gate that silently runs a different
    # rule set than the one documented is worse than no gate.
    fail "ruff.toml is missing — refusing to lint with ruff's default rules"
else
    # Probe each candidate rather than trusting `command -v`. On Windows,
    # python3 usually resolves to the Microsoft Store App Execution Alias stub,
    # which is on PATH, is not Python, and exits 49 with an install prompt.
    RUFF=()
    if command -v ruff >/dev/null 2>&1 && ruff --version >/dev/null 2>&1; then
        RUFF=(ruff)
    else
        for candidate in python3 python py; do
            command -v "$candidate" >/dev/null 2>&1 || continue
            if "$candidate" -m ruff --version >/dev/null 2>&1; then
                RUFF=("$candidate" -m ruff); break
            fi
        done
    fi
    if [ "${#RUFF[@]}" -eq 0 ]; then
        missing "ruff" "pip install ruff"
    else
        mapfile -t PY_FILES < .lint-cache/py-files.txt
        if out=$("${RUFF[@]}" check --no-cache --config ruff.toml -- "${PY_FILES[@]}" 2>&1); then
            pass "$py_count file(s) clean ($("${RUFF[@]}" --version))"
        else
            printf '%s\n' "$out" | sed 's/^/        /'
            fail "ruff reported findings in the $py_count Python file(s) above"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# PowerShell and T-SQL both run under pwsh
# ---------------------------------------------------------------------------
PWSH=""
for candidate in pwsh powershell; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1; then
        PWSH="$candidate"; break
    fi
done

# Runs one of the pwsh gates and maps its exit code: 0 pass, 1 findings,
# 2 the gate could not run (tool missing, download or hash failure). Anything
# else is a crash and always fails -- it must never be mistaken for a missing
# tool, which is only a WARN without --strict.
run_pwsh_gate() {  # $1 = label, $2 = hint when the gate cannot run, rest = script + args
    label="$1"; hint="$2"; shift 2
    out=$("$PWSH" -NoProfile -NonInteractive -File "$@" 2>&1)
    rc=$?
    printf '%s\n' "$out" | sed 's/^/        /'
    case "$rc" in
        0) pass "$label clean" ;;
        1) fail "$label reported findings above" ;;
        2) missing "$label" "$hint" ;;
        *) fail "$label crashed (exit $rc) — see output above" ;;
    esac
}

echo ""
echo "[ ps1 ] PSScriptAnalyzer"
list_files .lint-cache/ps1-files.txt '*.ps1'; ps_count=$LIST_COUNT
if [ "$ps_count" -eq 0 ]; then
    pass "no PowerShell files"
elif [ -z "$PWSH" ]; then
    missing "pwsh" "install PowerShell 7"
else
    run_pwsh_gate "PSScriptAnalyzer ($ps_count files)" \
        "Install-PSResource PSScriptAnalyzer -Scope CurrentUser" \
        scripts/lint-powershell.ps1 -ListFile .lint-cache/ps1-files.txt
fi

echo ""
echo "[ sql ] T-SQL parse (.sql files and \`\`\`sql blocks in .md)"
list_files .lint-cache/sql-files.txt '*.sql' '*.md'; sql_count=$LIST_COUNT
if [ "$sql_count" -eq 0 ]; then
    pass "no T-SQL sources"
elif [ -z "$PWSH" ]; then
    missing "pwsh" "install PowerShell 7"
else
    run_pwsh_gate "T-SQL ($sql_count files)" \
        "ScriptDom could not be loaded — see the lint-tsql message above" \
        scripts/lint-tsql.ps1 -ListFile .lint-cache/sql-files.txt -Baseline scripts/lint-tsql-baseline.tsv
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
printf "  Results: %d passed  |  %d warnings  |  %d failed\n" "$PASS" "$WARN" "$FAIL"
echo "========================================="
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Lint FAILED — fix the FAILs above before committing."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo "Lint passed with linters skipped — install them, or rely on CI (which runs --strict)."
    exit 0
else
    echo "Lint passed."
    exit 0
fi
