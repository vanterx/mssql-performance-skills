# PowerShell lint configuration — applied by scripts/lint-scripts.sh and
# .github/workflows/lint.yml to the capture and helper scripts under
# skills/*/scripts/.
#
# No Severity key is set on purpose. Filtering by severity drops ParseError
# findings, and ParseError is the single most valuable result this gate
# produces: it means a committed script cannot run at all. capture-spn-config.ps1
# shipped in that state until this gate was added.
@{
    ExcludeRules = @(
        # Every script here is an operator-facing capture tool: a DBA runs it in a
        # console and reads the sectioned, coloured report it prints. Write-Host is
        # the right cmdlet for that — the console output IS the deliverable, not
        # pipeline data a caller would collect. 100 hits, all intentional.
        'PSAvoidUsingWriteHost',

        # Fires on `Join-Path $OutputPath $name` and similar. Idiomatic PowerShell;
        # spelling out -Path/-ChildPath at every call site costs more readability
        # than the ambiguity it removes.
        'PSAvoidUsingPositionalParameters',

        # Flags plural nouns in function names. Renaming internal helpers to
        # singular nouns is churn with no defect behind it.
        'PSUseSingularNouns',

        # Fires on Remove-Brackets and New-Op in Extract-SqlPlan.ps1. Both are pure
        # in-process string and object helpers that change nothing outside the
        # session, so -WhatIf/-Confirm would advertise a safety story that does not
        # apply. Extract-SqlPlan.ps1 must also stay byte-identical in output to
        # extract_plan.py, so its signatures are effectively frozen.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
