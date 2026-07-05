#!/usr/bin/env bash
# scripts/start_work.sh — the worker loop.
#
#   ./start_work.sh [claude|codex|hermes|opencode] [--model <name>]
#
# Picks the next issue in priority order, claims it, does the work in a
# throwaway git worktree, opens a PR, and hands off to the review loop. The
# agent is never told to touch labels or assignees — this script owns every
# state transition.
#
# Env: AW_AGENT AW_MODEL AW_MAX AW_POLL_SECONDS AW_DRY_RUN AW_AGENT_TIMEOUT
#      AW_REPO REPO_DIR
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="start_work"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

export RUNS_AGENT=1
preflight
acquire_instance_lock "$SCRIPT_NAME"
trap 'release_instance_lock' EXIT

MAX="${AW_MAX:-0}"           # 0 = unlimited
POLL_SECONDS="${AW_POLL_SECONDS:-180}"

jittered_sleep() {
  local base="$1" jitter
  [ "$base" = "0" ] && return 0
  jitter=$(( base + (RANDOM % (base / 4 + 1)) - (base / 8) ))
  [ "$jitter" -lt 1 ] && jitter=1
  sleep "$jitter"
}

# ---------------------------------------------------------------------------
# reconcile_rework — self-heal: a PR authored by me whose LATEST review is
# CHANGES_REQUESTED, with no new commits since, but whose linked issue is
# still "in-review" (missed hand-off — reviewer crash, external human
# review, etc.) gets flipped back to "changes-requested" so the rework
# queue picks it up.
# ---------------------------------------------------------------------------
reconcile_rework() {
  local prs pr issue decision
  prs="$(gh pr list --repo "$REPO" --author "@me" --state open --json number,reviewDecision --jq '.[] | select(.reviewDecision=="CHANGES_REQUESTED") | .number')"
  for pr in $prs; do
    issue="$(issue_addressed_by_pr "$pr")"
    [ -n "$issue" ] || continue
    decision="$(gh issue view "$issue" --repo "$REPO" --json labels --jq '[.labels[].name] | index("status: in-review") != null')"
    if [ "$decision" = "true" ]; then
      log "reconciling issue #$issue: PR #$pr has CHANGES_REQUESTED but issue is still in-review"
      set_status_label "$issue" "changes-requested"
    fi
  done

  reconcile_automation_failures
}

# ---------------------------------------------------------------------------
# Auto-resume (autonomy L3, owner-gated in .github/autonomy.json): my open
# PRs that failed CI or hit a merge conflict get a marker comment with the
# context and their issue routed back to the rework queue — no human nudge
# needed. Marker comments are deduped per head SHA, and the rework prompt
# picks them up via automation_feedback().
# ---------------------------------------------------------------------------
reconcile_automation_failures() {
  local do_ci do_conflict
  do_ci="$(autonomy_setting '.auto_resume.ci_failures' 'false')"
  do_conflict="$(autonomy_setting '.auto_resume.merge_conflicts' 'false')"
  [ "$do_ci" = "true" ] || [ "$do_conflict" = "true" ] || return 0

  local prs pr sha issue marker existing
  prs="$(gh pr list --repo "$REPO" --author "@me" --state open --json number --jq '.[].number')"
  for pr in $prs; do
    sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid')"

    if [ "$do_ci" = "true" ]; then
      local failed
      failed="$(gh pr view "$pr" --repo "$REPO" --json statusCheckRollup \
        --jq "[.statusCheckRollup[]? | select(.conclusion==\"FAILURE\" and .name != null and (.name | test(\"$REVIEW_CHECK_CONTEXT\") | not))] | map(.name) | unique | join(\", \")" 2>/dev/null)"
      if [ -n "$failed" ]; then
        marker="<!-- aw-ci-fail:$sha -->"
        existing="$(gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body' | grep -cF "$marker" || true)"
        if [ "$existing" = "0" ]; then
          if [ "$DRY_RUN" = "1" ]; then
            log "[dry-run] would route PR #$pr back for rework (CI failed: $failed)"
          else
            gh pr comment "$pr" --repo "$REPO" --body "$marker
🤖 Auto-resume: CI checks failed at \`${sha:0:12}\`: **$failed**. Routing back to the rework queue — fix the failures and push to this branch." >/dev/null 2>&1 || true
            issue="$(issue_addressed_by_pr "$pr")"
            [ -n "$issue" ] && set_status_label "$issue" "changes-requested"
            audit_event "auto-resume" "pr#$pr" "ci-failed" "$failed"
            log "PR #$pr routed to rework (CI failed: $failed)"
          fi
        fi
        continue   # CI failure takes precedence over conflict handling
      fi
    fi

    if [ "$do_conflict" = "true" ]; then
      local mergeable
      mergeable="$(gh pr view "$pr" --repo "$REPO" --json mergeable --jq '.mergeable')"
      if [ "$mergeable" = "CONFLICTING" ]; then
        marker="<!-- aw-conflict:$sha -->"
        existing="$(gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body' | grep -cF "$marker" || true)"
        if [ "$existing" = "0" ]; then
          if [ "$DRY_RUN" = "1" ]; then
            log "[dry-run] would route PR #$pr back for rework (merge conflict)"
          else
            gh pr comment "$pr" --repo "$REPO" --body "$marker
🤖 Auto-resume: this branch conflicts with the default branch at \`${sha:0:12}\`. Routing back to the rework queue — rebase (or merge the default branch in), resolve, and push." >/dev/null 2>&1 || true
            issue="$(issue_addressed_by_pr "$pr")"
            [ -n "$issue" ] && set_status_label "$issue" "changes-requested"
            audit_event "auto-resume" "pr#$pr" "merge-conflict" ""
            log "PR #$pr routed to rework (merge conflict)"
          fi
        fi
      fi
    fi
  done
}

# Prompt construction lives in common.sh (build_work_prompt /
# build_rework_prompt) so scripts/render_prompt.sh previews exactly what
# this loop sends.

# ---------------------------------------------------------------------------
# next_ready_issue — first fresh candidate whose "Depends-on: #N" lines
# (if any) all point at CLOSED issues. Owner-gated by dependency_gating
# in .github/autonomy.json (default on — it's pure risk reduction).
# Skipped issues keep their place in the queue; no label churn.
# ---------------------------------------------------------------------------
next_ready_issue() {  # $1 = fresh-issues json array -> issue json or empty
  local fresh="$1" item n body
  if [ "$(autonomy_setting '.dependency_gating' 'true')" != "true" ]; then
    jq -c 'if length>0 then .[0] else empty end' <<<"$fresh"
    return 0
  fi
  while read -r item; do
    [ -n "$item" ] || continue
    n="$(jq -r '.number' <<<"$item")"
    body="$(gh issue view "$n" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null)"
    if dependencies_met "$body"; then
      printf '%s' "$item"
      return 0
    fi
    log "issue #$n has unmet Depends-on references — skipping until they close"
  done < <(jq -c '.[]' <<<"$fresh")
}

claim_and_run() {  # $1 = issue json
  local n title logfile rc pr
  n="$(jq -r '.number' <<<"$1")"
  title="$(jq -r '.title' <<<"$1")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would claim and work issue #$n: $title"
    return 0
  fi
  log "claiming issue #$n: $title"
  claim_issue "$n" || { log "lost claim race on #$n, moving on"; return 0; }

  make_worktree "origin/main" || { err "could not create worktree for #$n"; set_status_label "$n" "available"; gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1; return 0; }

  local issue_json prompt
  issue_json="$(gh issue view "$n" --repo "$REPO" --json title,body)"
  if ! prompt="$(build_work_prompt "$n" "$issue_json")" || [ -z "$prompt" ]; then
    err "could not build work prompt for #$n — releasing"
    remove_worktree
    set_status_label "$n" "available"
    gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
    return 0
  fi

  logfile="$(mktemp)"
  run_agent "$prompt" "$WORKTREE" 2>&1 | head -c "$AGENT_OUTPUT_LIMIT" | tee "$logfile"
  rc="${PIPESTATUS[0]}"

  if was_interrupted "$rc"; then
    err "agent run interrupted (rc=$rc) — stopping the runner"
    remove_worktree
    rm -f "$logfile"
    exit 130
  fi

  if output_was_truncated "$logfile"; then
    err "agent output hit AW_AGENT_OUTPUT_LIMIT ($AGENT_OUTPUT_LIMIT bytes) on #$n — releasing (tooling failure, not a work verdict)"
    audit_event "work" "issue#$n" "output-limit" "capped at $AGENT_OUTPUT_LIMIT bytes"
    remove_worktree
    rm -f "$logfile"
    set_status_label "$n" "available"
    gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
    return 0
  fi

  if was_usage_limited "$logfile"; then
    log "usage-limit signal detected — releasing #$n quietly and backing off ${USAGE_LIMIT_SLEEP}s"
    remove_worktree
    rm -f "$logfile"
    set_status_label "$n" "available"
    gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
    sleep "$USAGE_LIMIT_SLEEP"
    return 0
  fi
  rm -f "$logfile"
  remove_worktree

  pr="$(pr_for_issue "$n")"
  if [ -n "$pr" ]; then
    set_status_label "$n" "in-review"
    gh pr merge "$pr" --repo "$REPO" --auto --squash >/dev/null 2>&1 || true
    gh issue comment "$n" --repo "$REPO" --body "🤖 Opened #$pr for review." >/dev/null 2>&1 || true
    audit_event "work" "issue#$n" "pr-opened" "pr#$pr"
    log "issue #$n -> in-review via PR #$pr"
  else
    set_status_label "$n" "available"
    gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
    gh issue comment "$n" --repo "$REPO" --body "🤖 Agent finished without opening a PR — releasing back to available." >/dev/null 2>&1 || true
    audit_event "work" "issue#$n" "released" "no PR opened"
    log "issue #$n -> released (no PR opened)"
  fi
}

rework_and_run() {  # $1 = issue json
  local n pr headRefName headRefOid_before headRefOid_after logfile rc
  n="$(jq -r '.number' <<<"$1")"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would rework issue #$n"
    return 0
  fi
  pr="$(pr_for_issue "$n")"
  if [ -z "$pr" ]; then
    log "no PR found for rework issue #$n — releasing to available"
    set_status_label "$n" "available"
    gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
    return 0
  fi

  headRefName="$(gh pr view "$pr" --repo "$REPO" --json headRefName,headRepositoryOwner --jq '.headRefName')"
  local head_owner
  head_owner="$(gh pr view "$pr" --repo "$REPO" --json headRepositoryOwner --jq '.headRepositoryOwner.login')"
  if [ "$head_owner" != "$OWNER" ]; then
    log "PR #$pr head lives on a fork — cannot push rework directly, skipping"
    gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
    return 0
  fi

  headRefOid_before="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid')"
  local prompt
  if ! prompt="$(build_rework_prompt "$n" "$pr")" || [ -z "$prompt" ]; then
    err "could not build rework prompt for #$n — skipping"
    return 0
  fi
  make_worktree "origin/$headRefName" || { err "could not create worktree for rework #$n"; return 0; }

  logfile="$(mktemp)"
  run_agent "$prompt" "$WORKTREE" 2>&1 | head -c "$AGENT_OUTPUT_LIMIT" | tee "$logfile"
  rc="${PIPESTATUS[0]}"

  if was_interrupted "$rc"; then
    err "agent run interrupted (rc=$rc) — stopping the runner"
    remove_worktree; rm -f "$logfile"
    exit 130
  fi
  if output_was_truncated "$logfile"; then
    err "rework output hit AW_AGENT_OUTPUT_LIMIT ($AGENT_OUTPUT_LIMIT bytes) on #$n — skipping this cycle"
    audit_event "rework" "issue#$n" "output-limit" "capped at $AGENT_OUTPUT_LIMIT bytes"
    remove_worktree; rm -f "$logfile"
    return 0
  fi
  if was_usage_limited "$logfile"; then
    log "usage-limit signal detected during rework — backing off ${USAGE_LIMIT_SLEEP}s"
    remove_worktree; rm -f "$logfile"
    sleep "$USAGE_LIMIT_SLEEP"
    return 0
  fi
  rm -f "$logfile"
  remove_worktree

  headRefOid_after="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid')"
  if [ "$headRefOid_before" != "$headRefOid_after" ]; then
    set_status_label "$n" "in-review"
    audit_event "rework" "issue#$n" "pushed" "pr#$pr"
    log "issue #$n -> in-review (rework pushed to PR #$pr)"
  else
    audit_event "rework" "issue#$n" "no-change" "pr#$pr"
    log "issue #$n: no new commits pushed, leaving as changes-requested"
  fi
}

main() {
  local count=0
  while true; do
    heartbeat
    reconcile_rework

    local snap my_rework free_rework fresh next
    snap="$(fetch_open_issues)"
    my_rework="$(rework_issues "$snap")"
    free_rework="$(unassigned_reworks "$snap")"
    fresh="$(available_issues "$snap")"

    next="$(jq -c 'if length>0 then .[0] else empty end' <<<"$my_rework")"
    if [ -n "$next" ]; then rework_and_run "$next"; count=$((count+1));
    else
      next="$(jq -c 'if length>0 then .[0] else empty end' <<<"$free_rework")"
      if [ -n "$next" ]; then
        n="$(jq -r '.number' <<<"$next")"
        gh issue edit "$n" --repo "$REPO" --add-assignee "@me" >/dev/null 2>&1 || true
        rework_and_run "$next"; count=$((count+1))
      else
        next="$(next_ready_issue "$fresh")"
        if [ -n "$next" ]; then claim_and_run "$next"; count=$((count+1)); fi
      fi
    fi

    if [ -z "$next" ]; then
      [ "$POLL_SECONDS" = "0" ] && { log "queue empty, exiting (AW_POLL_SECONDS=0)"; break; }
      log "queue empty, sleeping ~${POLL_SECONDS}s"
      jittered_sleep "$POLL_SECONDS"
    fi

    if [ "$MAX" != "0" ] && [ "$count" -ge "$MAX" ]; then
      log "reached AW_MAX=$MAX completed items, exiting"
      break
    fi
  done
}

parse_agent_args "$@"
main
