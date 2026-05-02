#!/usr/bin/env bash
# verify-docs.sh — Documentation consistency checks for mssql-performance-skills
# Run manually: bash scripts/verify-docs.sh
# Runs automatically via .claude/settings.json PostToolUse hook after Write/Edit

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PASS=0; WARN=0; FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
warn() { echo "  WARN  $1"; WARN=$((WARN+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo ""
echo "mssql-performance-skills — Documentation Verification"
echo "==================================================="

# ---------------------------------------------------------------------------
# Check 1: Total check count matches PERFORMANCE_TUNING_GUIDE.md
# ---------------------------------------------------------------------------
echo ""
echo "[ 1 ] Total check count"
actual=$(grep -h "^### [A-Z][0-9]" skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')
expected=$(grep "Total:.*checks across all skills" PERFORMANCE_TUNING_GUIDE.md 2>/dev/null \
           | grep -o '[0-9]*' | head -1)
if [ -z "$expected" ]; then
    fail "Cannot find 'Total: N checks across all skills' in PERFORMANCE_TUNING_GUIDE.md"
elif [ "$actual" = "$expected" ]; then
    pass "$actual checks in SKILL.md files = $expected in PERFORMANCE_TUNING_GUIDE.md"
else
    fail "$actual checks found in SKILL.md files, but PERFORMANCE_TUNING_GUIDE.md says $expected — update the Check ID Reference table"
fi

# ---------------------------------------------------------------------------
# Check 2: Skill directory count matches CLAUDE.md declared count
# ---------------------------------------------------------------------------
echo ""
echo "[ 2 ] Skill count"
skill_dirs=$(ls -d skills/*/ 2>/dev/null | wc -l | tr -d ' ')
claude_word=$(grep -o '[a-z]* slash-command skills' CLAUDE.md 2>/dev/null | grep -o '^[a-z]*' | head -1)
case "$claude_word" in
    one)   claude_num=1 ;; two)   claude_num=2 ;; three) claude_num=3 ;;
    four)  claude_num=4 ;; five)  claude_num=5 ;; six)   claude_num=6 ;;
    seven) claude_num=7 ;; eight) claude_num=8 ;; nine)  claude_num=9 ;;
    ten)   claude_num=10 ;; *)    claude_num=0 ;;
esac
if [ "$claude_num" -eq 0 ]; then
    warn "Could not parse skill count word from CLAUDE.md (found: '$claude_word')"
elif [ "$skill_dirs" -eq "$claude_num" ]; then
    pass "$skill_dirs skills/ directories = '$claude_word' in CLAUDE.md"
else
    fail "$skill_dirs skills/ directories but CLAUDE.md says '$claude_word' ($claude_num) — update CLAUDE.md Purpose section"
fi

# ---------------------------------------------------------------------------
# Check 3: Every skill has SKILL.md and CHECKS_EXPLAINED.md
# ---------------------------------------------------------------------------
echo ""
echo "[ 3 ] Required files per skill"
check3_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if [ ! -f "$skill_dir/SKILL.md" ]; then
        fail "$name is missing SKILL.md"; check3_ok=0
    fi
    if [ ! -f "$skill_dir/CHECKS_EXPLAINED.md" ]; then
        fail "$name is missing CHECKS_EXPLAINED.md"; check3_ok=0
    fi
done
[ "$check3_ok" -eq 1 ] && pass "All skill directories have SKILL.md and CHECKS_EXPLAINED.md"

# ---------------------------------------------------------------------------
# Check 4: Every SKILL.md has a Companion Skills section
# ---------------------------------------------------------------------------
echo ""
echo "[ 4 ] Companion Skills section"
check4_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    if ! grep -q "^## Companion Skills" "$skill_file" 2>/dev/null; then
        warn "$name/SKILL.md is missing '## Companion Skills' section"
        check4_ok=0
    fi
done
[ "$check4_ok" -eq 1 ] && pass "All skills have a Companion Skills section"

# ---------------------------------------------------------------------------
# Check 5: No dollar signs that cause shell interpolation in SKILL.md files
# ---------------------------------------------------------------------------
echo ""
echo "[ 5 ] No shell-interpolatable dollar signs in SKILL.md files"
matches=$(grep -rn '\$[0-9\[]' skills/*/SKILL.md 2>/dev/null || true)
if [ -n "$matches" ]; then
    fail "Dollar signs found that cause skill loader interpolation:"
    echo "$matches" | sed 's/^/    /'
    echo "    Fix: replace \$0.012 with USD 0.012, \$[expr] with [expr] x USD rate"
else
    pass "No interpolatable dollar signs in SKILL.md files"
fi

# ---------------------------------------------------------------------------
# Check 6: Every skill (except sqlplan-review) has an example/ subfolder
# ---------------------------------------------------------------------------
echo ""
echo "[ 6 ] Example folders"
check6_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    [ "$name" = "sqlplan-review" ] && continue   # uses root-level horrible.sqlplan
    if [ ! -d "example/$name" ]; then
        warn "example/$name/ is missing — add an input file and -analysis.md"
        check6_ok=0
    fi
done
[ "$check6_ok" -eq 1 ] && pass "All skills (except sqlplan-review) have example/ subfolders"

# ---------------------------------------------------------------------------
# Check 7: Check prefix uniqueness — no letter used by two different skills
# ---------------------------------------------------------------------------
echo ""
echo "[ 7 ] Check prefix uniqueness"
# Emit "LETTER skill-name" for every prefix letter found in each SKILL.md,
# then look for any LETTER that appears with more than one skill name.
prefix_map=$(for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    grep "^### [A-Z][0-9]" "$skill_file" 2>/dev/null \
        | grep -o "^### [A-Z]" | grep -o "[A-Z]" | sort -u \
        | while read -r letter; do echo "$letter $name"; done
done)

duplicates=$(echo "$prefix_map" | sort | awk '{
    if (prefix[$1] != "" && prefix[$1] != $2)
        print "prefix " $1 " used by both " prefix[$1] " and " $2
    prefix[$1] = $2
}')

if [ -n "$duplicates" ]; then
    fail "Duplicate check prefixes found:"
    echo "$duplicates" | sed 's/^/    /'
else
    pass "All check prefixes are unique across skills"
fi

# ---------------------------------------------------------------------------
# Check 8: README Skills table has one row per skill directory
# ---------------------------------------------------------------------------
echo ""
echo "[ 8 ] README Skills table row count"
readme_rows=$(awk '/^## Skills/,/^---/' README.md 2>/dev/null \
    | grep "^|" | grep -v "^| Skill\|^|---" | wc -l | tr -d ' ')
if [ "$readme_rows" = "$skill_dirs" ]; then
    pass "README Skills table has $readme_rows rows = $skill_dirs skill directories"
else
    fail "README Skills table has $readme_rows rows but there are $skill_dirs skill directories — add/remove the missing skill row"
fi

# ---------------------------------------------------------------------------
# Check 9: CLAUDE.md install comment reflects actual skill count
# ---------------------------------------------------------------------------
echo ""
echo "[ 9 ] CLAUDE.md install comment"
if grep -q "all $skill_dirs skills" CLAUDE.md 2>/dev/null; then
    pass "CLAUDE.md install comment says 'all $skill_dirs skills'"
else
    warn "CLAUDE.md install comment may not say 'all $skill_dirs skills' — check the Installing Skills section"
fi

# ---------------------------------------------------------------------------
# Check 10: Frontmatter name: field matches directory name
# ---------------------------------------------------------------------------
echo ""
echo "[10 ] Frontmatter name matches directory"
check10_ok=1
for skill_file in skills/*/SKILL.md; do
    dir=$(basename "$(dirname "$skill_file")")
    name=$(grep "^name:" "$skill_file" 2>/dev/null | head -1 | sed 's/name:[[:space:]]*//')
    if [ -z "$name" ]; then
        fail "$dir/SKILL.md has no 'name:' field in frontmatter"; check10_ok=0
    elif [ "$dir" != "$name" ]; then
        fail "$dir/SKILL.md: name '$name' does not match directory '$dir'"; check10_ok=0
    fi
done
[ "$check10_ok" -eq 1 ] && pass "All frontmatter name: fields match their directory names"

# ---------------------------------------------------------------------------
# Check 11: Check count in SKILL.md matches CHECKS_EXPLAINED.md per skill
# ---------------------------------------------------------------------------
echo ""
echo "[11 ] SKILL.md vs CHECKS_EXPLAINED.md check count per skill"
check11_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    skill_count=$(grep -c "^### [A-Z][0-9]" "$skill_dir/SKILL.md" 2>/dev/null || echo 0)
    expl_count=$(grep -c "^### [A-Z][0-9]" "$skill_dir/CHECKS_EXPLAINED.md" 2>/dev/null || echo 0)
    # sqlplan-batch: aggregates sqlplan-review checks, no checks of its own
    [ "$name" = "sqlplan-batch" ] && continue
    # sqlplan-index-advisor: CHECKS_EXPLAINED.md explains the merge/ranking pipeline,
    # not individual D-checks — structured differently by design
    [ "$name" = "sqlplan-index-advisor" ] && continue
    if [ "$skill_count" != "$expl_count" ]; then
        fail "$name: SKILL.md has $skill_count checks but CHECKS_EXPLAINED.md has $expl_count — they must match"
        check11_ok=0
    fi
done
[ "$check11_ok" -eq 1 ] && pass "SKILL.md and CHECKS_EXPLAINED.md check counts match for all skills"

# ---------------------------------------------------------------------------
# Check 12: Every skill appears in PERFORMANCE_TUNING_GUIDE.md
# ---------------------------------------------------------------------------
echo ""
echo "[12 ] Skills referenced in PERFORMANCE_TUNING_GUIDE.md"
check12_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if ! grep -q "$name" PERFORMANCE_TUNING_GUIDE.md 2>/dev/null; then
        fail "$name not found in PERFORMANCE_TUNING_GUIDE.md — add it to the Skills at a Glance table and relevant scenarios"
        check12_ok=0
    fi
done
[ "$check12_ok" -eq 1 ] && pass "All skills referenced in PERFORMANCE_TUNING_GUIDE.md"

# ---------------------------------------------------------------------------
# Check 13: Every skill appears in LLM_COST_ESTIMATION.md
# ---------------------------------------------------------------------------
echo ""
echo "[13 ] Skills referenced in LLM_COST_ESTIMATION.md"
check13_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if ! grep -q "$name" LLM_COST_ESTIMATION.md 2>/dev/null; then
        fail "$name not found in LLM_COST_ESTIMATION.md — add a row to the skill file size table"
        check13_ok=0
    fi
done
[ "$check13_ok" -eq 1 ] && pass "All skills referenced in LLM_COST_ESTIMATION.md"

# ---------------------------------------------------------------------------
# Check 14: Frontmatter description stated check count matches actual
#           (only for skills that explicitly state "N checks" in description)
# ---------------------------------------------------------------------------
echo ""
echo "[14 ] Frontmatter description check count (where declared)"
check14_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    described=$(grep "^description:" "$skill_file" 2>/dev/null \
                | grep -o '[0-9]* checks' | grep -o '^[0-9]*')
    [ -z "$described" ] && continue   # skill doesn't state a count — skip
    actual=$(grep -c "^### [A-Z][0-9]" "$skill_file" 2>/dev/null || echo 0)
    if [ "$described" != "$actual" ]; then
        warn "$name: frontmatter description says '$described checks' but SKILL.md has $actual — update the description"
        check14_ok=0
    fi
done
[ "$check14_ok" -eq 1 ] && pass "Frontmatter description check counts match actual (for skills that declare them)"

# ---------------------------------------------------------------------------
# Check 15: Each example subfolder has at least one *-analysis.md
# ---------------------------------------------------------------------------
echo ""
echo "[15 ] Example subfolders contain an analysis file"
check15_ok=1
for d in example/*/; do
    [ ! -d "$d" ] && continue
    analysis_count=$(ls "$d"*-analysis.md 2>/dev/null | wc -l | tr -d ' ')
    if [ "$analysis_count" -eq 0 ]; then
        warn "$d has no *-analysis.md — add an expected skill output file"
        check15_ok=0
    fi
done
[ "$check15_ok" -eq 1 ] && pass "All example subfolders contain at least one *-analysis.md"

# ---------------------------------------------------------------------------
# Check 16: No TODO, FIXME, or [TBD] markers in SKILL.md files
# ---------------------------------------------------------------------------
echo ""
echo "[16 ] No placeholder markers in SKILL.md files"
todo_matches=$(grep -rni "TODO\|FIXME\|\[TBD\]\|\[placeholder\]" skills/*/SKILL.md 2>/dev/null || true)
if [ -n "$todo_matches" ]; then
    warn "Placeholder markers found in SKILL.md files:"
    echo "$todo_matches" | sed 's/^/    /'
else
    pass "No TODO/FIXME/[TBD] markers in SKILL.md files"
fi

# ---------------------------------------------------------------------------
# Check 17: README Skill Details section check counts match SKILL.md
# ---------------------------------------------------------------------------
echo ""
echo "[17 ] README Skill Details check counts match SKILL.md"
check17_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    actual=$(grep -c "^### [A-Z][0-9]" "$skill_dir/SKILL.md" 2>/dev/null || echo 0)
    # Extract first "N checks" mention in the README's ## skill-name section
    readme_count=$(awk "/^## $name\$/{found=1; next} found && /^## /{exit} \
        found && /[0-9]+ checks/{print; exit}" README.md 2>/dev/null \
        | grep -o '[0-9]* checks' | head -1 | grep -o '^[0-9]*')
    # sqlplan-batch aggregates sqlplan-review's checks — its README "87 checks" refers to sqlplan-review
    [ "$name" = "sqlplan-batch" ] && continue
    [ -z "$readme_count" ] && continue   # skill has no README section with count — skip
    if [ "$readme_count" != "$actual" ]; then
        fail "README.md '## $name' says '$readme_count checks' but SKILL.md has $actual — update README Skill Details"
        check17_ok=0
    fi
done
[ "$check17_ok" -eq 1 ] && pass "README Skill Details check counts match SKILL.md"

# ---------------------------------------------------------------------------
# Check 18: README Recommended Workflow diagram counts match actual skill counts
# ---------------------------------------------------------------------------
echo ""
echo "[18 ] README Recommended Workflow counts match actual skill counts"
check18_ok=1
# Collect the set of actual per-skill check counts
skill_counts=$(for f in skills/*/SKILL.md; do grep -c "^### [A-Z][0-9]" "$f" 2>/dev/null; done | sort -u)
# Extract all "N checks" values from the Recommended Workflow section
wf_counts=$(awk '/^## Recommended Workflow/{f=1;next} f && /^---/{exit} f{print}' \
    README.md 2>/dev/null | grep -o '[0-9]* checks' | grep -o '^[0-9]*')
while IFS= read -r count; do
    [ -z "$count" ] && continue
    if ! echo "$skill_counts" | grep -qx "$count"; then
        fail "README Recommended Workflow mentions '$count checks' but no skill has exactly $count checks — update the diagram"
        check18_ok=0
    fi
done <<< "$wf_counts"
[ "$check18_ok" -eq 1 ] && pass "README Recommended Workflow counts match actual skill counts"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================================="
printf "  Results: %d passed  |  %d warnings  |  %d failed\n" "$PASS" "$WARN" "$FAIL"
echo "==================================================="
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Documentation is INCONSISTENT — fix the FAILs above before committing."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo "Documentation is consistent with warnings — review the WARNs above."
    exit 0
else
    echo "Documentation is consistent."
    exit 0
fi
