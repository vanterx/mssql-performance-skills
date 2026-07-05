#!/usr/bin/env bash
# scripts/triage_work.sh — the agent-triage loop (autonomy L2).
#
#   ./triage_work.sh [claude|codex|hermes] [--model <name>]
#
# Polls open issues that have NO status label and were NOT opened by a
# trusted author (those are auto-labeled by .github/workflows/triage.yml
# without any model call), and asks the agent for a triage decision:
#
#   TRIAGE: ACCEPT  -> status: available (+ audit)
#   TRIAGE: DEFER   -> comment why, leave unlabeled for human triage
#   TRIAGE: REJECT  -> comment why + do-not-automate label
#
# Fails closed: no/ambiguous decision leaves the issue for a human.
# Requires auto_triage.enabled AND auto_triage.agent_triage in
# .github/autonomy.json. The daily cap applies across both tiers.
#
# SECURITY: this loop feeds untrusted issue text to a model in exchange
# for a label that later feeds that same text to a coding agent with
# shell access. Read .claude/docs/aw/AUTONOMY.md ("What each rung costs
# you") before enabling.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="triage_work"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export RUNS_AGENT=1
preflight
acquire_instance_lock "$SCRIPT_NAME"
trap 'release_instance_lock' EXIT

if [ "$(autonomy_setting '.auto_triage.enabled' 'false')" != "true" ]; then
  err "auto-triage is disabled — set auto_triage.enabled=true in $AUTONOMY_FILE to use this loop"
  exit 1
fi
if [ "$(autonomy_setting '.auto_triage.agent_triage' 'false')" != "true" ]; then
  err "agent triage is disabled — this loop needs auto_triage.agent_triage=true (trusted-author triage runs in CI without it)"
  exit 1
fi

MAX="${AW_MAX:-0}"
POLL_SECONDS="${TRIAGE_POLL_SECONDS}"
DAILY_CAP="$(autonomy_setting '.auto_triage.max_auto_available_per_day' '20')"

trusted_author() {  # $1 = login
  autonomy_setting '.auto_triage.trusted_authors' '[]' | jq -e --arg l "$1" 'index($l) != null' >/dev/null 2>&1
}

# Count issues auto-labeled available today (both tiers comment with a
# marker) to enforce the daily budget valve that G0 used to provide.
auto_labeled_today() {
  gh search issues --repo "$REPO" "\"aw-auto-triage\" in:comments created:>=$(date -u +%Y-%m-%d)" \
    --json number --jq 'length' 2>/dev/null || echo 0
}

untriaged_issues() {  # snapshot -> issues with NO status label, not do-not-automate
  local snap="$1"
  jq '[.[] | select(
        ((.labels | map(.name) | map(select(startswith("status: "))) | length) == 0)
        and ((.labels | map(.name) | index("do-not-automate")) | not)
      )] | sort_by(.createdAt)' <<<"$snap"
}

triage_one() {  # $1 = issue json
  local n author issue_json prompt outfile decision
  n="$(jq -r '.number' <<<"$1")"

  author="$(gh issue view "$n" --repo "$REPO" --json author --jq '.author.login')"
  if trusted_author "$author"; then
    # trusted authors are handled by the zero-token CI tier
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would agent-triage issue #$n (author: @$author)"
    return 0
  fi

  if [ "$(auto_labeled_today)" -ge "$DAILY_CAP" ]; then
    log "daily auto-triage cap ($DAILY_CAP) reached — leaving #$n for tomorrow/human"
    return 1
  fi

  issue_json="$(gh issue view "$n" --repo "$REPO" --json title,body)"
  if ! prompt="$(build_triage_prompt "$n" "$issue_json")" || [ -z "$prompt" ]; then
    err "could not build triage prompt for #$n — skipping"
    return 0
  fi

  outfile="$(mktemp)"
  run_agent "$prompt" "$REPO_DIR" 2>&1 | head -c "$AGENT_OUTPUT_LIMIT" | tee "$outfile"
  local rc="${PIPESTATUS[0]}"
  if was_interrupted "$rc"; then
    err "triage run interrupted — stopping"
    rm -f "$outfile"
    exit 130
  fi
  if was_usage_limited "$outfile"; then
    log "usage limit during triage — backing off ${USAGE_LIMIT_SLEEP}s"
    rm -f "$outfile"
    sleep "$USAGE_LIMIT_SLEEP"
    return 0
  fi

  decision="$(last_triage_line "$outfile")"
  local reasoning
  reasoning="$(grep -v '^TRIAGE:' "$outfile" | tail -n 8)"
  rm -f "$outfile"

  case "$decision" in
    ACCEPT)
      set_status_label "$n" "available"
      gh issue comment "$n" --repo "$REPO" --body "<!-- aw-auto-triage -->
🤖 Auto-triage: **accepted** into the work queue.

$reasoning" >/dev/null 2>&1 || true
      audit_event "triage" "issue#$n" "accept" "author=$author"
      log "issue #$n -> available (agent triage accept)"
      ;;
    DEFER)
      gh issue comment "$n" --repo "$REPO" --body "<!-- aw-auto-triage -->
🤖 Auto-triage: **deferred** for human triage.

$reasoning" >/dev/null 2>&1 || true
      audit_event "triage" "issue#$n" "defer" "author=$author"
      log "issue #$n -> deferred (left for human)"
      ;;
    REJECT)
      gh issue edit "$n" --repo "$REPO" --add-label "do-not-automate" >/dev/null 2>&1 || true
      gh issue comment "$n" --repo "$REPO" --body "<!-- aw-auto-triage -->
🤖 Auto-triage: **rejected** for automation (a human can override by removing the \`do-not-automate\` label).

$reasoning" >/dev/null 2>&1 || true
      audit_event "triage" "issue#$n" "reject" "author=$author"
      log "issue #$n -> do-not-automate (agent triage reject)"
      ;;
    *)
      # fail closed: no state change, a human will look at it
      audit_event "triage" "issue#$n" "no-verdict" "author=$author"
      log "issue #$n: no/ambiguous triage decision — leaving for human"
      ;;
  esac
}

main() {
  local count=0
  while true; do
    heartbeat
    local snap queue n acted=0
    snap="$(fetch_open_issues)"
    queue="$(untriaged_issues "$snap")"
    for n in $(jq -c '.[]' <<<"$queue"); do
      triage_one "$n" || break   # cap reached — stop this pass
      acted=1
      count=$((count+1))
      [ "$MAX" != "0" ] && [ "$count" -ge "$MAX" ] && { log "reached AW_MAX=$MAX, exiting"; return; }
    done
    if [ "$acted" = "0" ]; then
      [ "$POLL_SECONDS" = "0" ] && { log "nothing to triage, exiting"; break; }
      log "nothing to triage, sleeping ${POLL_SECONDS}s"
      sleep "$POLL_SECONDS"
    fi
  done
}

parse_agent_args "$@"
main
