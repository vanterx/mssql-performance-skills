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
total_checks="$actual"
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
    ten)      claude_num=10 ;; eleven)   claude_num=11 ;; twelve)   claude_num=12 ;;
    thirteen) claude_num=13 ;; fourteen) claude_num=14 ;; fifteen)  claude_num=15 ;;
    sixteen)  claude_num=16 ;; seventeen) claude_num=17 ;; eighteen) claude_num=18 ;;
    nineteen) claude_num=19 ;; twenty)   claude_num=20 ;; *)         claude_num=0 ;;
esac
if [ "$claude_num" -eq 0 ]; then
    warn "Could not parse skill count word from CLAUDE.md (found: '$claude_word')"
elif [ "$skill_dirs" -eq "$claude_num" ]; then
    pass "$skill_dirs skills/ directories = '$claude_word' in CLAUDE.md"
else
    fail "$skill_dirs skills/ directories but CLAUDE.md says '$claude_word' ($claude_num) — update CLAUDE.md Purpose section"
fi

# ---------------------------------------------------------------------------
# Check 3: Every skill has SKILL.md, references/check-explanations.md, and references/README.md
# ---------------------------------------------------------------------------
echo ""
echo "[ 3 ] Required files per skill"
check3_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if [ ! -f "$skill_dir/SKILL.md" ]; then
        fail "$name is missing SKILL.md"; check3_ok=0
    fi
    if [ ! -f "$skill_dir/references/check-explanations.md" ]; then
        fail "$name is missing references/check-explanations.md"; check3_ok=0
    fi
    if [ ! -f "$skill_dir/references/README.md" ]; then
        fail "$name is missing references/README.md"; check3_ok=0
    fi
done
[ "$check3_ok" -eq 1 ] && pass "All skill directories have SKILL.md, references/check-explanations.md, and references/README.md"

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
# Check 6: Every skill has an examples/ subfolder
# ---------------------------------------------------------------------------
echo ""
echo "[ 6 ] Example folders"
check6_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if [ ! -d "skills/$name/examples" ]; then
        warn "skills/$name/examples/ is missing — add an input file and -analysis.md"
        check6_ok=0
    fi
done
[ "$check6_ok" -eq 1 ] && pass "All skills have examples/ subfolders"

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
# Check 11: Check count in SKILL.md matches references/check-explanations.md per skill
# ---------------------------------------------------------------------------
echo ""
echo "[11 ] SKILL.md vs references/check-explanations.md check count per skill"
check11_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    skill_count=$(grep -c "^### [A-Z][0-9]" "$skill_dir/SKILL.md" 2>/dev/null || echo 0)
    expl_count=$(grep -c "^### [A-Z][0-9]" "$skill_dir/references/check-explanations.md" 2>/dev/null || echo 0)
    # sqlplan-batch: aggregates sqlplan-review checks, no checks of its own
    [ "$name" = "sqlplan-batch" ] && continue
    # sqlindex-advisor: check-explanations.md explains the merge/ranking pipeline,
    # not individual D-checks — structured differently by design
    [ "$name" = "sqlindex-advisor" ] && continue
    if [ "$skill_count" != "$expl_count" ]; then
        fail "$name: SKILL.md has $skill_count checks but references/check-explanations.md has $expl_count — they must match"
        check11_ok=0
    fi
done
[ "$check11_ok" -eq 1 ] && pass "SKILL.md and references/check-explanations.md check counts match for all skills"

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
# Check 15: Each skill's examples/ subfolder has at least one *-analysis.md
# ---------------------------------------------------------------------------
echo ""
echo "[15 ] Example subfolders contain an analysis file"
check15_ok=1
for skill_dir in skills/*/; do
    d="${skill_dir}examples/"
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
# Check 19: Every SKILL.md has an ## Output Format section
# ---------------------------------------------------------------------------
echo ""
echo "[19 ] Output Format section present in all SKILL.md files"
check19_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    if ! grep -q "^## Output Format" "$skill_file" 2>/dev/null; then
        fail "$name/SKILL.md is missing '## Output Format' section"
        check19_ok=0
    fi
done
[ "$check19_ok" -eq 1 ] && pass "All SKILL.md files have an '## Output Format' section"

# ---------------------------------------------------------------------------
# Check 20: Output Format sections contain required structural markers
#   - Analysis skills must have a Passed Checks mandate
#   - Priority-table skills must have a fix-sequence/action-order mandate
#   - sqlplan-compare must mandate Root Cause Summary
#   - sqldeadlock-review must mandate Deadlock Summary table + Pattern Match
#   - sqlplan-batch must mandate Memory Grant Summary + Cardinality Accuracy Report
#   - sqlplan-review must mandate check ID suffix in finding labels
# ---------------------------------------------------------------------------
echo ""
echo "[20 ] Output Format structural markers (regression guard)"
check20_ok=1

# Skills that must mandate Passed Checks
for name in tsql-review sqlstats-review sqltrace-review sqlwait-review sqlplan-review sqlquerystore-review; do
    skill_file="skills/$name/SKILL.md"
    [ ! -f "$skill_file" ] && continue
    if ! grep -q "Passed Checks" "$skill_file" 2>/dev/null; then
        fail "$name/SKILL.md: Output Format lost 'Passed Checks' mandate — restore from reference analysis"
        check20_ok=0
    fi
done

# Skills that must mandate a priority/fix table
for name in sqlplan-review sqlwait-review sqlquerystore-review sqldeadlock-review; do
    skill_file="skills/$name/SKILL.md"
    [ ! -f "$skill_file" ] && continue
    if ! grep -qE "Prioritized Fix Sequence|Recommended Action Order|Remediation Priority" "$skill_file" 2>/dev/null; then
        fail "$name/SKILL.md: Output Format lost priority/fix table mandate — restore from reference analysis"
        check20_ok=0
    fi
done

# sqlplan-compare: must mandate Root Cause Summary
if ! grep -q "Root Cause Summary" "skills/sqlplan-compare/SKILL.md" 2>/dev/null; then
    fail "sqlplan-compare/SKILL.md: Output Format lost 'Root Cause Summary' mandate"
    check20_ok=0
fi

# sqldeadlock-review: must mandate Deadlock Summary table and Pattern Match section
if ! grep -q "Deadlock Summary" "skills/sqldeadlock-review/SKILL.md" 2>/dev/null; then
    fail "sqldeadlock-review/SKILL.md: Output Format lost 'Deadlock Summary' table mandate"
    check20_ok=0
fi
if ! grep -q "Pattern Match" "skills/sqldeadlock-review/SKILL.md" 2>/dev/null; then
    fail "sqldeadlock-review/SKILL.md: Output Format lost 'Pattern Match' section mandate"
    check20_ok=0
fi

# sqlplan-batch: must mandate Memory Grant Summary and Cardinality Accuracy Report
if ! grep -q "Memory Grant Summary" "skills/sqlplan-batch/SKILL.md" 2>/dev/null; then
    fail "sqlplan-batch/SKILL.md: Output Format lost 'Memory Grant Summary' section mandate"
    check20_ok=0
fi
if ! grep -q "Cardinality Accuracy Report" "skills/sqlplan-batch/SKILL.md" 2>/dev/null; then
    fail "sqlplan-batch/SKILL.md: Output Format lost 'Cardinality Accuracy Report' section mandate"
    check20_ok=0
fi

# sqlplan-review: must mandate check ID suffix in finding labels
if ! grep -q "check ID" "skills/sqlplan-review/SKILL.md" 2>/dev/null; then
    fail "sqlplan-review/SKILL.md: Output Format lost check ID suffix instruction in finding labels"
    check20_ok=0
fi

[ "$check20_ok" -eq 1 ] && pass "All Output Format sections have required structural markers"

# ---------------------------------------------------------------------------
# Check 21: SKILL.md line count (skill-creator guideline: ≤500 lines)
# ---------------------------------------------------------------------------
echo ""
echo "[21 ] SKILL.md line count (skill-creator guideline: ≤500 lines)"
check21_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    lines=$(wc -l < "$skill_file" | tr -d ' ')
    if [ "$lines" -gt 1000 ]; then
        fail "$name/SKILL.md is $lines lines — exceeds 1000. Compress check definitions or extract to references/."
        check21_ok=0
    elif [ "$lines" -gt 900 ]; then
        warn "$name/SKILL.md is $lines lines — exceeds 900-line guideline. Consider removing blank lines or compressing check definitions."
        check21_ok=0
    fi
done
[ "$check21_ok" -eq 1 ] && pass "All SKILL.md files are within 900-line guideline"

# ---------------------------------------------------------------------------
# Check 22: description: field minimum word count (skill-creator: be "pushy")
# ---------------------------------------------------------------------------
echo ""
echo "[22 ] Description field word count (min 30 words)"
check22_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    desc=$(grep "^description:" "$skill_file" 2>/dev/null | head -1 | sed 's/^description:[[:space:]]*//')
    word_count=$(echo "$desc" | wc -w | tr -d ' ')
    if [ "$word_count" -lt 30 ]; then
        warn "$name/SKILL.md: description is only $word_count words — add trigger phrases and context (skill-creator: descriptions should be 'pushy')"
        check22_ok=0
    fi
done
[ "$check22_ok" -eq 1 ] && pass "All description fields meet 30-word minimum"

# ---------------------------------------------------------------------------
# Check 23: description: includes trigger phrases (skill-creator: when-to-use in description)
# ---------------------------------------------------------------------------
echo ""
echo "[23 ] Description contains trigger phrases"
check23_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    desc=$(grep "^description:" "$skill_file" 2>/dev/null | head -1)
    if ! echo "$desc" | grep -qiE "use (this skill|when|whenever)|trigger (when|even)|whenever a user"; then
        warn "$name/SKILL.md: description lacks trigger phrases — add 'Use this skill when...' or 'Trigger when...' (skill-creator: all when-to-use info belongs in description)"
        check23_ok=0
    fi
done
[ "$check23_ok" -eq 1 ] && pass "All descriptions contain trigger phrases"

# ---------------------------------------------------------------------------
# Check 24: triggers: field present in frontmatter (skill-creator: required)
# ---------------------------------------------------------------------------
echo ""
echo "[24 ] triggers: field in frontmatter"
check24_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    frontmatter=$(awk '/^---/{count++; if(count==2) exit; next} count==1{print}' "$skill_file" 2>/dev/null)
    if ! echo "$frontmatter" | grep -q "^triggers:"; then
        fail "$name/SKILL.md: missing 'triggers:' field in frontmatter"
        check24_ok=0
    fi
done
[ "$check24_ok" -eq 1 ] && pass "All SKILL.md files have triggers: in frontmatter"

# ---------------------------------------------------------------------------
# Check 25: No bare ALWAYS/NEVER/MUST in body outside code blocks (skill-creator style)
# ---------------------------------------------------------------------------
echo ""
echo "[25 ] No bare ALWAYS/NEVER/MUST in body text outside code blocks (skill-creator style)"
check25_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    stripped=$(awk '/^```/{skip=!skip; next} !skip{print}' "$skill_file" 2>/dev/null)
    matches=$(echo "$stripped" | grep -E '\b(ALWAYS|NEVER|MUST)\b' | grep -v '`[^`]*\b(ALWAYS|NEVER|MUST)\b' || true)
    if [ -n "$matches" ]; then
        count=$(echo "$matches" | wc -l | tr -d ' ')
        warn "$name/SKILL.md: $count instance(s) of ALWAYS/NEVER/MUST outside code blocks — explain the why instead (skill-creator guideline)"
        check25_ok=0
    fi
done
[ "$check25_ok" -eq 1 ] && pass "No bare ALWAYS/NEVER/MUST in SKILL.md body text"

# ---------------------------------------------------------------------------
# Check 26: Per-skill check count in PERFORMANCE_TUNING_GUIDE.md Skills at a Glance
#           matches the actual count in the skill's SKILL.md
# ---------------------------------------------------------------------------
echo ""
echo "[26 ] Per-skill count in PERFORMANCE_TUNING_GUIDE.md Skills at a Glance matches SKILL.md"
check26_ok=1
while IFS= read -r skill_file; do
    name=$(basename "$(dirname "$skill_file")")
    actual=$(grep -c "^### [A-Z][0-9]" "$skill_file" 2>/dev/null || echo 0)
    # sqlplan-batch has no original checks (aggregator) — skip
    [ "$name" = "sqlplan-batch" ] && continue
    # sqlindex-advisor uses derivation rules, not ### headers — skip
    [ "$name" = "sqlindex-advisor" ] && continue
    # Look for "N checks" in the Skills at a Glance table row for this skill
    guide_count=$(awk '/^## Skills at a Glance/{f=1;next} f && /^---/{exit} f{print}' \
        PERFORMANCE_TUNING_GUIDE.md 2>/dev/null \
        | grep "$name" | grep -o '[0-9]* checks' | head -1 | grep -o '^[0-9]*')
    [ -z "$guide_count" ] && continue  # skill row has no count — skip
    if [ "$guide_count" != "$actual" ]; then
        fail "$name: PERFORMANCE_TUNING_GUIDE.md Skills at a Glance says '$guide_count checks' but SKILL.md has $actual — update the table"
        check26_ok=0
    fi
done < <(ls skills/*/SKILL.md 2>/dev/null)
[ "$check26_ok" -eq 1 ] && pass "Per-skill check counts in PERFORMANCE_TUNING_GUIDE.md Skills at a Glance match SKILL.md"

# ---------------------------------------------------------------------------
# Check 27: Every skill has references/README.md
# ---------------------------------------------------------------------------
echo ""
echo "[27 ] references/README.md per skill"
check27_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if [ ! -f "$skill_dir/references/README.md" ]; then
        fail "$name is missing references/README.md — add an index pointing readers at reference files"
        check27_ok=0
    fi
done
[ "$check27_ok" -eq 1 ] && pass "All skills have references/README.md"

# ---------------------------------------------------------------------------
# Check 28: Every skill has evals/evals.json
# ---------------------------------------------------------------------------
echo ""
echo "[28 ] evals/evals.json per skill"
check28_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if [ ! -f "$skill_dir/evals/evals.json" ]; then
        warn "$name is missing evals/evals.json — add at least 2 realistic test prompts"
        check28_ok=0
    fi
done
[ "$check28_ok" -eq 1 ] && pass "All skills have evals/evals.json"

# ---------------------------------------------------------------------------
# Check 29: TOC header in references/check-explanations.md where >300 lines
# ---------------------------------------------------------------------------
echo ""
echo "[29 ] TOC header in references/check-explanations.md (where >300 lines)"
check29_ok=1
for f in skills/*/references/check-explanations.md; do
    [ ! -f "$f" ] && continue
    name=$(basename "$(dirname "$(dirname "$f")")")
    lines=$(wc -l < "$f" | tr -d ' ')
    [ "$lines" -le 300 ] && continue
    if ! grep -q "^## Contents" "$f"; then
        warn "$name/references/check-explanations.md is $lines lines but has no '## Contents' TOC section"
        check29_ok=0
    fi
done
[ "$check29_ok" -eq 1 ] && pass "All large check-explanations.md files have a Contents TOC"

# ---------------------------------------------------------------------------
# Check 30: scripts/ directory exists and is non-empty for every skill
# ---------------------------------------------------------------------------
echo ""
echo "[30 ] scripts/ directory non-empty per skill"
check30_ok=1
for skill_dir in skills/*/; do
    name=$(basename "$skill_dir")
    if [ ! -d "$skill_dir/scripts" ]; then
        fail "$name is missing scripts/ directory"
        check30_ok=0
    elif [ -z "$(ls -A "$skill_dir/scripts" 2>/dev/null)" ]; then
        fail "$name/scripts/ is empty — add at least a .gitkeep or capture script"
        check30_ok=0
    fi
done
[ "$check30_ok" -eq 1 ] && pass "All skills have a non-empty scripts/ directory"

# ---------------------------------------------------------------------------
# Check 31: Model attribution footer present in each SKILL.md Output Format
# ---------------------------------------------------------------------------
echo ""
echo "[31 ] Model attribution footer in Output Format"
check31_ok=1
for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")
    if ! awk '/^## Output Format/{f=1} f && /^## (Notes|Companion)/{exit} f{print}' \
        "$skill_file" | grep -q "Analyzed by:"; then
        warn "$name/SKILL.md: Output Format is missing the 'Analyzed by:' attribution footer"
        check31_ok=0
    fi
done
[ "$check31_ok" -eq 1 ] && pass "All SKILL.md Output Format blocks contain the attribution footer"

# ---------------------------------------------------------------------------
# Check 32: README.md total check count matches PERFORMANCE_TUNING_GUIDE.md
# ---------------------------------------------------------------------------
echo ""
echo "[32 ] README.md total check count matches PERFORMANCE_TUNING_GUIDE.md"
guide_total=$(grep "Total:.*checks across all skills" PERFORMANCE_TUNING_GUIDE.md 2>/dev/null \
              | grep -o '[0-9]*' | head -1)
if [ -z "$guide_total" ]; then
    warn "Cannot find 'Total: N checks across all skills' in PERFORMANCE_TUNING_GUIDE.md — skipping README cross-check"
else
    check32_ok=1
    # Check intro paragraph
    intro_total=$(grep -o '[0-9]* checks across [0-9]* skills' README.md 2>/dev/null \
                  | grep -o '^[0-9]*' | head -1)
    if [ -z "$intro_total" ]; then
        fail "README.md intro paragraph has no 'N checks across M skills' — add the total"
        check32_ok=0
    elif [ "$intro_total" != "$guide_total" ]; then
        fail "README.md intro says '$intro_total checks' but PERFORMANCE_TUNING_GUIDE.md says '$guide_total' — update README intro"
        check32_ok=0
    fi
    # Check Reference table footer
    ref_total=$(grep "^\| \*\*Total\*\*" README.md 2>/dev/null \
                | grep -o '\*\*[0-9]*\*\*' | grep -o '[0-9]*' | head -1)
    if [ -z "$ref_total" ]; then
        fail "README.md Check Reference table has no **Total** row — add it"
        check32_ok=0
    elif [ "$ref_total" != "$guide_total" ]; then
        fail "README.md Check Reference table total is '$ref_total' but PERFORMANCE_TUNING_GUIDE.md says '$guide_total' — update the table"
        check32_ok=0
    fi
    [ "$check32_ok" -eq 1 ] && pass "README.md total ($intro_total) matches PERFORMANCE_TUNING_GUIDE.md ($guide_total) in both locations"
fi

# ---------------------------------------------------------------------------
# Check 33: Per-prefix check range upper bounds match reference table in PERFORMANCE_TUNING_GUIDE.md
# ---------------------------------------------------------------------------
echo ""
echo "[33 ] Per-prefix check range upper bounds match guide reference table"
check33_ok=1

for skill_file in skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill_file")")

    # Extract unique check prefixes used in this skill (e.g., V, T, S, N)
    prefixes=$(grep -oE '^### [A-Z][0-9]+' "$skill_file" | grep -oE '[A-Z]' | sort -u)
    [ -z "$prefixes" ] && continue  # dispatcher skill — skip

    while IFS= read -r prefix; do
        # Actual last check number in SKILL.md
        actual_max=$(grep -oE "^### ${prefix}[0-9]+" "$skill_file" \
                     | grep -oE '[0-9]+$' | sort -n | tail -1)
        [ -z "$actual_max" ] && continue

        # Max upper bound in guide reference table for this prefix.
        # Looks at rows like: | `V1–V18` | or | `V37–V40` |
        guide_max=$(grep "^\| \`${prefix}" PERFORMANCE_TUNING_GUIDE.md \
                    | grep -oE "${prefix}[0-9]+" \
                    | grep -oE '[0-9]+$' \
                    | sort -n | tail -1)

        if [ -z "$guide_max" ]; then
            warn "$name: prefix $prefix has checks up to ${prefix}${actual_max} — no rows in guide reference table"
            check33_ok=0
        elif [ "$guide_max" != "$actual_max" ]; then
            fail "$name: prefix $prefix — last check is ${prefix}${actual_max} but guide reference table max is ${prefix}${guide_max}"
            check33_ok=0
        fi
    done <<< "$prefixes"
done
[ "$check33_ok" -eq 1 ] && pass "All per-prefix check upper bounds match PERFORMANCE_TUNING_GUIDE.md reference table"

# ---------------------------------------------------------------------------
# Check 34: skills/VERSION_COMPATIBILITY.md catalog IDs exist in their SKILL.md
# ---------------------------------------------------------------------------
echo ""
echo "[34 ] skills/VERSION_COMPATIBILITY.md catalog IDs exist in their SKILL.md"
check34_ok=1
declare -A P2S=(
    [I]="sqlstats-review" [W]="sqlstats-review"
    [X]="sqltrace-review" [V]="sqlwait-review"
    [S]="sqlplan-review"  [N]="sqlplan-review"
    [T]="tsql-review"     [Q]="sqlquerystore-review"
    [R]="sqlprocstats-review" [H]="sqlhadr-review"
    [L]="sqlclusterlog-review" [E]="sqlerrorlog-review"
    [K]="sqlspn-review"      [C]="sqlplan-compare"
    [P]="sqldeadlock-review" [D]="sqlindex-advisor"
    [O]="sqlmemory-review"   [Z]="sqldiskio-review"
)
while IFS='|' read -r _ id _rest; do
    id="${id// /}"
    [[ "$id" =~ ^[A-Z][0-9]+$ ]] || continue
    prefix="${id:0:1}"
    skill="${P2S[$prefix]}"
    if [ -z "$skill" ]; then
        warn "34: Unknown prefix '$prefix' (check $id)"
        continue
    fi
    if ! grep -q "^### ${id} " "skills/${skill}/SKILL.md" 2>/dev/null; then
        fail "34: $id in skills/VERSION_COMPATIBILITY.md not found in skills/${skill}/SKILL.md"
        check34_ok=0
    fi
done < <(grep -E '^\| [A-Z][0-9]+' skills/VERSION_COMPATIBILITY.md)
[ "$check34_ok" -eq 1 ] && pass "All skills/VERSION_COMPATIBILITY.md catalog IDs exist in their SKILL.md"

# ---------------------------------------------------------------------------
# Check 35: Version-tagged SKILL.md checks (trigger-line version gates) appear
#           in skills/VERSION_COMPATIBILITY.md. Only looks at the Trigger: line to
#           avoid false positives from version mentions in Fix text.
# ---------------------------------------------------------------------------
echo ""
echo "[35 ] Version-tagged SKILL.md checks appear in skills/VERSION_COMPATIBILITY.md"
check35_ok=1
for skill_file in skills/*/SKILL.md; do
    current_id=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^###\ ([A-Z][0-9]+)\ — ]]; then
            current_id="${BASH_REMATCH[1]}"
        elif [ -n "$current_id" ] && [[ "$line" =~ \*\*Trigger:\*\* ]]; then
            # Only flag if the Trigger line itself carries a version gate suffix
            if echo "$line" | grep -qE '(SQL 20[0-9][0-9]\+[^;]*only|SQL 20[0-9][0-9]\+ only)'; then
                if ! grep -q "| ${current_id} |" skills/VERSION_COMPATIBILITY.md; then
                    fail "35: $current_id has SQL version gate in Trigger line but absent from skills/VERSION_COMPATIBILITY.md"
                    check35_ok=0
                fi
            fi
            current_id=""
        fi
    done < "$skill_file"
done
[ "$check35_ok" -eq 1 ] && pass "All version-tagged SKILL.md checks appear in skills/VERSION_COMPATIBILITY.md"

# ---------------------------------------------------------------------------
# Check 36: No cross-version contamination in skills/VERSION_COMPATIBILITY.md
# ---------------------------------------------------------------------------
echo ""
echo "[36 ] No cross-version contamination in skills/VERSION_COMPATIBILITY.md"
check36_ok=1
pre2016_qs=$(awk '/^### SQL Server 2016\+/,0{exit} /^\| Q[0-9]/{print}' skills/VERSION_COMPATIBILITY.md)
if [ -n "$pre2016_qs" ]; then
    fail "36: Query Store checks (Q prefix) appear before SQL 2016+ section: $pre2016_qs"
    check36_ok=0
fi
pre2012_hl=$(awk '/^### SQL Server 2012\+/,0{exit} /^\| [HL][0-9]/{print}' skills/VERSION_COMPATIBILITY.md)
if [ -n "$pre2012_hl" ]; then
    fail "36: HADR/Cluster checks appear before SQL 2012+ section: $pre2012_hl"
    check36_ok=0
fi
[ "$check36_ok" -eq 1 ] && pass "No cross-version contamination in skills/VERSION_COMPATIBILITY.md"

# ---------------------------------------------------------------------------
# Check 37: skills/VERSION_COMPATIBILITY.md total check count matches actual
# ---------------------------------------------------------------------------
echo ""
echo "[37 ] skills/VERSION_COMPATIBILITY.md total check count matches actual"
vc_total=$(grep -oE '[0-9]+ checks' skills/VERSION_COMPATIBILITY.md | head -1 | grep -oE '[0-9]+')
if [ -z "$vc_total" ]; then
    fail "37: Cannot find 'N checks' in skills/VERSION_COMPATIBILITY.md"
elif [ "$vc_total" = "$total_checks" ]; then
    pass "skills/VERSION_COMPATIBILITY.md total ($vc_total) matches actual check count"
else
    fail "skills/VERSION_COMPATIBILITY.md says $vc_total checks but actual SKILL.md count is $total_checks"
fi

# ---------------------------------------------------------------------------
# Check 38: No check prefix map in AGENTS.md
# ---------------------------------------------------------------------------
echo ""
echo "[38 ] No check prefix map in AGENTS.md"
if grep -q "^## Check prefix map" AGENTS.md 2>/dev/null; then
    fail "AGENTS.md contains a '## Check prefix map' section — remove it; detail belongs in CLAUDE.md only"
else
    pass "AGENTS.md has no check prefix map"
fi

# ---------------------------------------------------------------------------
# Check 39: No per-skill check counts in AGENTS.md
# ---------------------------------------------------------------------------
echo ""
echo "[39 ] No per-skill check counts in AGENTS.md"
check39_ok=1
# Look for skill-name followed by a number in parentheses, or "N checks" near a skill name
matches=$(grep -nE 'skills\/[a-z-]+.*\([0-9]+\)|[a-z-]+-review.*[0-9]+ checks|[0-9]+ checks.*[a-z-]+-review' AGENTS.md 2>/dev/null || true)
if [ -n "$matches" ]; then
    fail "AGENTS.md contains per-skill check counts — remove them; detail belongs in CLAUDE.md only"
    echo "$matches" | sed 's/^/    /'
    check39_ok=0
fi
# Extra: catch any line that has a skill name and a digit
extra=$(grep -nE 'sqlplan-(review|compare|batch|deadlock|index-advisor)|tsql-review|sqlstats-review|sqltrace-review|sqlwait-review|sqlquerystore-review|sqlprocstats-review|sqlclusterlog-review|sqlerrorlog-review|sqlhadr-review|spn-review|mssql-performance-review' AGENTS.md 2>/dev/null | grep -E '[0-9]{1,3}' || true)
if [ -n "$extra" ]; then
    fail "AGENTS.md contains skill names with numeric counts — remove them; detail belongs in CLAUDE.md only"
    echo "$extra" | sed 's/^/    /'
    check39_ok=0
fi
[ "$check39_ok" -eq 1 ] && pass "AGENTS.md contains no per-skill check counts"

# ---------------------------------------------------------------------------
# Check 40: AGENTS.md delegates to CLAUDE.md
# ---------------------------------------------------------------------------
echo ""
echo "[40 ] AGENTS.md delegates to CLAUDE.md"
claude_refs=$(grep -c "CLAUDE.md" AGENTS.md 2>/dev/null || echo 0)
if [ "$claude_refs" -lt 2 ]; then
    warn "AGENTS.md references CLAUDE.md only $claude_refs time(s) — add at least 2 pointers so agents know where detail lives"
else
    pass "AGENTS.md references CLAUDE.md $claude_refs times"
fi

# ---------------------------------------------------------------------------
# Check 41: No hardcoded verify-docs count in AGENTS.md
# ---------------------------------------------------------------------------
echo ""
echo "[41 ] No hardcoded verify-docs count in AGENTS.md"
if grep -qE 'Runs [0-9]+ documentation consistency checks' AGENTS.md 2>/dev/null; then
    warn "AGENTS.md hardcodes the number of documentation checks — use generic wording so it stays accurate when checks are added"
else
    pass "AGENTS.md uses generic wording for verify-docs count"
fi

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
