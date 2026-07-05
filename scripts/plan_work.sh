#!/usr/bin/env bash
# scripts/plan_work.sh — the backlog planner (autonomy L4).
#
#   ./plan_work.sh [claude|codex|hermes] [--model <name>]
#
# When the work queue runs completely dry (no "status: available" issues
# AND nothing awaiting triage), asks the agent to propose the next few
# work items from GOALS.md, then files them as issues. The SCRIPT does
# the filing (state-ownership invariant) — the agent only drafts text.
#
# Filed issues carry no status label, so they flow through auto-triage
# like any other issue. If the planner's own login is in
# auto_triage.trusted_authors, they auto-label; otherwise they wait for
# agent/human triage. This layering is deliberate: proposing work and
# admitting work stay separate decisions.
#
# One pass per invocation (no loop) — run it from cron / a systemd timer.
# Requires planner.enabled=true in .github/autonomy.json and a real
# GOALS.md (refuses on the template stub).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="plan_work"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export RUNS_AGENT=1
preflight
acquire_instance_lock "$SCRIPT_NAME"
trap 'release_instance_lock' EXIT
heartbeat

if [ "$(autonomy_setting '.planner.enabled' 'false')" != "true" ]; then
  err "planner is disabled — set planner.enabled=true in $AUTONOMY_FILE to use it"
  exit 1
fi

GOALS_FILE="$REPO_DIR/$(autonomy_setting '.planner.goals_file' 'GOALS.md')"
MAX_ISSUES="${PLAN_MAX_ISSUES:-$(autonomy_setting '.planner.max_issues_per_run' '3')}"

if [ ! -f "$GOALS_FILE" ]; then
  err "goals file not found: $GOALS_FILE"
  exit 1
fi
if grep -q 'TODO(adopter)' "$GOALS_FILE"; then
  err "$GOALS_FILE is still the template stub — write real goals before enabling the planner"
  exit 1
fi

# Queue-dry trigger: only plan when there is truly nothing to do or triage.
snap="$(fetch_open_issues)"
available_count="$(available_issues "$snap" | jq 'length')"
untriaged_count="$(jq '[.[] | select(((.labels | map(.name) | map(select(startswith("status: "))) | length) == 0) and ((.labels | map(.name) | index("do-not-automate")) | not))] | length' <<<"$snap")"
if [ "$available_count" != "0" ] || [ "$untriaged_count" != "0" ]; then
  log "queue not dry (available: $available_count, awaiting triage: $untriaged_count) — nothing to plan"
  exit 0
fi

recent_closed="$(gh issue list --repo "$REPO" --state closed --limit 15 --json number,title \
  --jq '.[] | "- #\(.number): \(.title)"' 2>/dev/null || true)"

prompt="$(render_template "$PROMPTS_DIR/plan.md" \
  "max_issues=$MAX_ISSUES" \
  "goals_file=$(basename "$GOALS_FILE")" \
  "goals=$(cat "$GOALS_FILE")" \
  "recent_closed=${recent_closed:-none}")" || exit 1

if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] queue is dry — would run the planner (cap: $MAX_ISSUES issues)"
  exit 0
fi

outfile="$(mktemp)"
run_agent "$prompt" "$REPO_DIR" 2>&1 | head -c "$AGENT_OUTPUT_LIMIT" | tee "$outfile"
rc="${PIPESTATUS[0]}"
if was_interrupted "$rc"; then rm -f "$outfile"; exit 130; fi
if was_usage_limited "$outfile"; then
  log "usage limit during planning — try again next scheduled run"
  rm -f "$outfile"
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse "### ISSUE ... ### END" blocks (parse_plan_blocks in common.sh —
# malformed blocks are dropped, never guessed at) and file them, capped.
# ---------------------------------------------------------------------------
filed=0
while IFS=$'\x1f' read -r -d $'\x1e' title body; do
  [ -n "$title" ] || continue
  if [ "$filed" -ge "$MAX_ISSUES" ]; then
    log "cap ($MAX_ISSUES) reached — skipping remaining proposals"
    break
  fi
  url="$(gh issue create --repo "$REPO" --title "$title" --body "$body

---
_Filed by the AgentWorks planner from $(basename "$GOALS_FILE")._" 2>/dev/null)" || {
    err "failed to file proposed issue: $title"
    continue
  }
  filed=$((filed+1))
  audit_event "plan" "$url" "filed" "$title"
  log "filed: $title -> $url"
done < <(parse_plan_blocks "$outfile")
rm -f "$outfile"

log "planner pass complete: $filed issue(s) filed"
