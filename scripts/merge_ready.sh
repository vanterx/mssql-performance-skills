#!/usr/bin/env bash
# scripts/merge_ready.sh — trust-model-based merge automation.
#
# GitHub's native "require approving reviews" branch protection only counts
# reviewers who have WRITE access to the repo — which would deadlock any
# contributor without write access. So the merge decision does not live in
# GitHub's approval gate; it lives here. This script reads the RECORDED
# review state (regardless of the reviewer's GitHub permission level),
# applies its own whitelist trust model, and — on READY — sets the merge-gate
# commit status itself and merges. This decouples "who can review" from
# "who can merge."
#
#   ./scripts/merge_ready.sh                 # report only
#   AW_MERGE=1 ./scripts/merge_ready.sh       # merge PRs that are READY
#   AW_PR=42 AW_MERGE=1 ./scripts/merge_ready.sh   # target one PR
#
# Trust config: .github/trusted-reviewers.json
#   { "whitelist": ["login1","login2"], "required_approvals": 1 }
# Overridable via AW_TRUST_WHITELIST (comma-separated) and
# AW_REQUIRED_APPROVALS.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="merge_ready"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

preflight

MERGE="${AW_MERGE:-0}"
TARGET_PR="${AW_PR:-}"

whitelist() {
  if [ -n "${AW_TRUST_WHITELIST:-}" ]; then
    tr ',' '\n' <<<"$AW_TRUST_WHITELIST"
  else
    load_trust_config | jq -r '.whitelist[]?'
  fi
}

req_approvals() {
  echo "${AW_REQUIRED_APPROVALS:-$(required_approvals)}"
}

is_trusted() {  # $1 = login
  whitelist | grep -qxF "$1"
}

open_prs() {
  gh pr list --repo "$REPO" --state open --json number,labels,isDraft \
    --jq "[.[] | select(.isDraft|not) | select(.labels|map(.name)|index(\"review: human-only\")|not)] | .[].number"
}

evaluate_pr() {  # $1 = PR number -> prints "BLOCKED|PENDING|READY <detail>"
  local pr="$1" author reviews approvers=() blockers=() need
  author="$(gh pr view "$pr" --repo "$REPO" --json author --jq '.author.login')"
  need="$(req_approvals)"

  reviews="$(gh api graphql -f query="{repository(owner:\"$OWNER\",name:\"$NAME\"){pullRequest(number:$pr){reviews(first:100){nodes{author{login} state submittedAt}}}}}" \
    --jq '.data.repository.pullRequest.reviews.nodes | group_by(.author.login) | map(sort_by(.submittedAt) | last) | .[] | [.author.login, .state] | @tsv')"

  while IFS=$'\t' read -r login state; do
    [ -n "$login" ] || continue
    [ "$login" = "$author" ] && continue
    is_trusted "$login" || continue
    case "$state" in
      APPROVED) approvers+=("$login") ;;
      CHANGES_REQUESTED) blockers+=("$login") ;;
    esac
  done <<<"$reviews"

  if [ "${#blockers[@]}" -gt 0 ]; then
    echo "BLOCKED (changes requested by: ${blockers[*]})"
    return
  fi
  if [ "${#approvers[@]}" -lt "$need" ]; then
    echo "PENDING (${#approvers[@]}/$need trusted approvals: ${approvers[*]:-none})"
    return
  fi
  echo "READY (approved by: ${approvers[*]})"
}

merge_pr() {  # $1 = PR number
  local pr="$1" sha
  sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid')"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would merge PR #$pr"
    return 0
  fi
  gh_retry gh api -X POST "repos/$OWNER/$NAME/statuses/$sha" \
    -f state=success -f context="$REVIEW_CHECK_CONTEXT" -f description="Trust model satisfied" >/dev/null 2>&1 || true
  gh pr merge "$pr" --repo "$REPO" --squash --delete-branch >/dev/null 2>&1 || true
  audit_event "merge" "pr#$pr" "ok" "trust model satisfied"
  local iss; iss="$(issue_for_pr "$pr")"
  [ -n "$iss" ] && set_status_label "$iss" "done"
  log "merged PR #$pr"
}

main() {
  local prs pr result
  if [ -n "$TARGET_PR" ]; then prs="$TARGET_PR"; else prs="$(open_prs)"; fi

  for pr in $prs; do
    result="$(evaluate_pr "$pr")"
    log "PR #$pr: $result"
    if [ "$MERGE" = "1" ] && [[ "$result" == READY* ]]; then
      merge_pr "$pr"
    fi
  done
}

main
