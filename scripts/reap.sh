#!/usr/bin/env bash
# scripts/reap.sh — stale claim garbage collector.
#
# Pure `gh` + `jq` bookkeeping, no model calls. Safe to run on a cron
# (see .github/workflows/reap.yml). Two sweeps:
#
#   1. status: claimed, idle past AW_CLAIM_TTL, no PR opened -> released
#      back to available and unassigned.
#   2. status: changes-requested, still assigned, idle past AW_REWORK_TTL
#      -> unassigned (label stays, so it becomes an "unassigned rework"
#      anyone can pick up).
#
#   AW_DRY_RUN=1 ./scripts/reap.sh   # report only, no changes
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="reap"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

preflight

now_epoch() { date -u +%s; }
age_secs() {  # $1 = ISO8601 timestamp
  local ts="$1" then_epoch
  then_epoch="$(date -u -d "$ts" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s)"
  echo $(( $(now_epoch) - then_epoch ))
}

warn_if_capped() {  # $1 = json array, $2 = label being swept
  if [ "$(jq 'length' <<<"$1" 2>/dev/null)" = "100" ]; then
    log_warn "sweep of '$2' hit the 100-issue list cap — some stale items may be missed until the queue shrinks"
  fi
}

reap_stale_claims() {
  local issues n who updated
  issues="$(gh issue list --repo "$REPO" --state open --label "status: claimed" \
    --json number,updatedAt,assignees --limit 100)"
  warn_if_capped "$issues" "status: claimed"
  jq -c '.[]' <<<"$issues" | while read -r item; do
    n="$(jq -r '.number' <<<"$item")"
    updated="$(jq -r '.updatedAt' <<<"$item")"
    [ "$(age_secs "$updated")" -ge "$CLAIM_TTL" ] || continue
    [ -z "$(pr_for_issue "$n")" ] || continue   # already has a PR, leave it for the review loop
    who="$(jq -r '.assignees[0].login // ""' <<<"$item")"
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] would release stale claim on #$n (assignee: ${who:-none})"
      continue
    fi
    set_status_label "$n" "available"
    [ -n "$who" ] && gh issue edit "$n" --repo "$REPO" --remove-assignee "$who" >/dev/null 2>&1 || true
    gh issue comment "$n" --repo "$REPO" \
      --body "🧹 Releasing this claim — no PR opened within $((CLAIM_TTL/60)) minutes." >/dev/null 2>&1 || true
    audit_event "reap" "issue#$n" "released" "stale claim (assignee: ${who:-none})"
    log "released stale claim on #$n"
  done
}

reap_stale_reworks() {
  local issues n who updated assignee_count
  issues="$(gh issue list --repo "$REPO" --state open --label "status: changes-requested" \
    --json number,updatedAt,assignees --limit 100)"
  warn_if_capped "$issues" "status: changes-requested"
  jq -c '.[]' <<<"$issues" | while read -r item; do
    n="$(jq -r '.number' <<<"$item")"
    assignee_count="$(jq -r '.assignees | length' <<<"$item")"
    [ "$assignee_count" -gt 0 ] || continue
    updated="$(jq -r '.updatedAt' <<<"$item")"
    [ "$(age_secs "$updated")" -ge "$REWORK_TTL" ] || continue
    who="$(jq -r '.assignees[0].login' <<<"$item")"
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] would unassign stale rework on #$n (assignee: $who)"
      continue
    fi
    gh issue edit "$n" --repo "$REPO" --remove-assignee "$who" >/dev/null 2>&1 || true
    gh issue comment "$n" --repo "$REPO" \
      --body "🧹 Unassigning — no rework pushed within $((REWORK_TTL/60)) minutes. Anyone may pick this up." >/dev/null 2>&1 || true
    audit_event "reap" "issue#$n" "unassigned" "stale rework (was: $who)"
    log "unassigned stale rework on #$n (was: $who)"
  done
}

# ---------------------------------------------------------------------------
# reap_mislabeled_done — self-heal for inconsistent "done" labels. An
# issue that truly merged gets CLOSED by its PR's "Closes #n" keyword, so
# an OPEN issue carrying "status: done" is lying (historically: a merge
# blocked by branch protection while the label was written anyway).
# Route it back to the truthful state.
# ---------------------------------------------------------------------------
reap_mislabeled_done() {
  local issues n pr
  issues="$(gh issue list --repo "$REPO" --state open --label "status: done" \
    --json number --limit 100)"
  warn_if_capped "$issues" "status: done"
  jq -r '.[].number' <<<"$issues" | while read -r n; do
    [ -n "$n" ] || continue
    pr="$(pr_for_issue "$n")"
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] would relabel mislabeled-done #$n (open PR: ${pr:-none})"
      continue
    fi
    if [ -n "$pr" ]; then
      set_status_label "$n" "in-review"
      gh issue comment "$n" --repo "$REPO" \
        --body "🧹 This issue was labeled \`status: done\` but PR #$pr is still open (the merge was likely blocked by branch protection). Relabeling to \`status: in-review\` to reflect reality." >/dev/null 2>&1 || true
      audit_event "reap" "issue#$n" "relabeled" "done -> in-review (open pr#$pr)"
      log "relabeled mislabeled-done #$n -> in-review (open PR #$pr)"
    else
      set_status_label "$n" "available"
      gh issue edit "$n" --repo "$REPO" --remove-assignee "@me" >/dev/null 2>&1 || true
      gh issue comment "$n" --repo "$REPO" \
        --body "🧹 This issue was labeled \`status: done\` but is still open with no PR. Releasing back to \`status: available\`." >/dev/null 2>&1 || true
      audit_event "reap" "issue#$n" "relabeled" "done -> available (no PR)"
      log "relabeled mislabeled-done #$n -> available (no PR)"
    fi
  done
}

reap_stale_claims
reap_stale_reworks
reap_mislabeled_done
