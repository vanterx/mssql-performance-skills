#!/usr/bin/env bash
# generate-inventory.sh — Generate a fresh skill-inventory.md from all SKILL.md files.
# Output goes to skill-inventory.md in the repo root (gitignored).
# Usage: bash scripts/generate-inventory.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

OUT="skill-inventory.md"
DATE=$(date +%Y-%m-%d)
SKILLS="skills/*/SKILL.md"

echo "Generating $OUT ..."

{
  echo "# MSSQL Performance Skills — Comprehensive SKILL.md Inventory"
  echo ""
  echo "Generated: $DATE"
  echo ""
  echo "> Generated file — do not edit. Regenerate: \`bash scripts/generate-inventory.sh\`"
  echo ""
  echo "---"
  echo ""

  # ---- 1. DMV / catalog view references --------------------------------
  echo "## 1. DMV / Catalog View References"
  echo ""
  echo "| DMV / View | Skills:Lines |"
  echo "|---|---|"

  grep -rh "sys\." $SKILLS 2>/dev/null \
    | grep -o 'sys\.[a-z_]*' \
    | grep -v 'sys\.$' \
    | sort -u \
    | while read -r dmv; do
        refs=$(grep -rn "\b${dmv}\b" $SKILLS 2>/dev/null \
          | sed 's|skills/\([^/]*\)/SKILL\.md:\([0-9]*\):.*|\1:\2|' \
          | head -6 | tr '\n' ', ' | sed 's/, $//') || true
        [ -n "$refs" ] && echo "| \`${dmv}\` | ${refs} |"
      done

  echo ""
  echo "---"
  echo ""

  # ---- 2. Version-specific claims (SQL Server 20xx+) ------------------
  echo "## 2. Version-Specific Claims"
  echo ""
  echo "| Version mentioned | File:Line |"
  echo "|---|---|"

  grep -rn "SQL Server 20[0-9][0-9]" $SKILLS 2>/dev/null \
    | sed 's|skills/\([^/]*\)/SKILL\.md:\([0-9]*\):\(.*\)|\1:\2\t\3|' \
    | while IFS=$'\t' read -r ref content; do
        version=$(echo "$content" | grep -o 'SQL Server 20[0-9][0-9][^|;`,)]*' | head -1 | sed 's/[[:space:]]*$//')
        [ -n "$version" ] && echo "| ${version} | ${ref} |"
      done \
    | sort -u \
    | head -100

  echo ""
  echo "---"
  echo ""

  # ---- 3. Wait types ---------------------------------------------------
  echo "## 3. Wait Types Referenced"
  echo ""
  echo "| Wait Type | Skills:Lines |"
  echo "|---|---|"

  for wt in PAGEIOLATCH_SH PAGEIOLATCH_EX PAGEIOLATCH_UP \
             LCK_M_S LCK_M_IX LCK_M_U LCK_M_X \
             CXPACKET CXCONSUMER CXSYNC_PORT CXSYNC_CONSUMER \
             RESOURCE_SEMAPHORE RESOURCE_SEMAPHORE_QUERY_COMPILE \
             WRITELOG LOGBUFFER ASYNC_NETWORK_IO SOS_SCHEDULER_YIELD \
             THREADPOOL PAGELATCH_EX PAGELATCH_SH LATCH_EX LATCH_SH \
             LOGMGR_RESERVE_APPEND HADR_SYNC_COMMIT HADR_WORK_QUEUE \
             HADR_LOGCAPTURE_WAIT IO_QUEUE_LIMIT IO_RETRY \
             LOG_RATE_GOVERNOR POOL_LOG_RATE_GOVERNOR INSTANCE_LOG_RATE_GOVERNOR \
             SE_REPL_CATCHUP_THROTTLE HTBUILD HTDELETE HTMEMO HTREINIT HTREPARTITION \
             CMEMTHREAD OLEDB PREEMPTIVE_OS_WRITEFILEGATHERER; do
    refs=$(grep -rn "\b${wt}\b" $SKILLS 2>/dev/null \
      | sed 's|skills/\([^/]*\)/SKILL\.md:\([0-9]*\):.*|\1:\2|' \
      | head -5 | tr '\n' ', ' | sed 's/, $//') || true
    [ -n "$refs" ] && echo "| \`${wt}\` | ${refs} |"
  done

  echo ""
  echo "---"
  echo ""

  # ---- 4. T-SQL functions / commands -----------------------------------
  echo "## 4. T-SQL Functions / Commands Referenced"
  echo ""
  echo "| Function / Command | Skills:Lines |"
  echo "|---|---|"

  for fn in "CERTPROPERTY" "STRING_SPLIT" "STRING_AGG" "APPROX_COUNT_DISTINCT" \
            "JSON_OBJECT" "JSON_ARRAY" "JSON_VALUE" "JSON_QUERY" \
            "IS DISTINCT FROM" "TRIM" "TRY_CAST" "TRY_CONVERT" \
            "sp_executesql" "sp_query_store_force_plan" "sp_query_store_set_hints" \
            "sp_control_dbmasterkey_password" "sp_server_diagnostics" \
            "xp_readerrorlog" "xp_cmdshell" \
            "DBCC CHECKDB" "DBCC FREEPROCCACHE" "DBCC LOGINFO" \
            "ENCRYPTBYKEY" "DECRYPTBYKEY" "OPEN SYMMETRIC KEY" \
            "BACKUP CERTIFICATE" "BACKUP MASTER KEY" "BACKUP SERVICE MASTER KEY"; do
    refs=$(grep -rn "${fn}" $SKILLS 2>/dev/null \
      | sed 's|skills/\([^/]*\)/SKILL\.md:\([0-9]*\):.*|\1:\2|' \
      | head -5 | tr '\n' ', ' | sed 's/, $//') || true
    [ -n "$refs" ] && echo "| \`${fn}\` | ${refs} |"
  done

  echo ""
  echo "---"
  echo ""
  echo "*Regenerate: \`bash scripts/generate-inventory.sh\`*"

} > "$OUT"

echo "Done -> $OUT  ($(wc -l < "$OUT") lines)"
