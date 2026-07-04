#!/usr/bin/env bash
# scripts/metrics.sh — read-only workflow metrics.
#
#   ./scripts/metrics.sh                # audit-log stats + live queue depths
#   AW_AUDIT_LOG=/path/audit.jsonl ./scripts/metrics.sh
#
# Aggregates this runner's .aw/audit.jsonl (each runner has its own — run
# this per machine, or concatenate shipped logs centrally) plus current
# queue depths from GitHub. No writes anywhere.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="metrics"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

preflight

echo "== Audit-log metrics (${AUDIT_LOG:-disabled}) =="
if [ -n "$AUDIT_LOG" ] && [ -f "$AUDIT_LOG" ]; then
  jq -s '
    def dur(a; b):
      [ group_by(.target)[]
        | {claim: ([.[] | select(.action==a)] | first),
           done:  ([.[] | select(.action==b)] | last)}
        | select(.claim and .done)
        | ((.done.ts | fromdateiso8601) - (.claim.ts | fromdateiso8601))
        | select(. >= 0) ];

    {
      events_total: length,
      by_action: (group_by(.action) | map({(.[0].action): length}) | add // {}),
      review_pass: ([.[] | select(.action=="review" and .outcome=="pass")] | length),
      review_needs_work: ([.[] | select(.action=="review" and .outcome=="needs-work")] | length),
      work_released_no_pr: ([.[] | select(.action=="work" and .outcome=="released")] | length),
      work_pr_opened: ([.[] | select(.action=="work" and .outcome=="pr-opened")] | length),
      merges: ([.[] | select(.action=="merge")] | length)
    }
    | . + {
        rework_rate_pct: (if (.review_pass + .review_needs_work) > 0
          then (.review_needs_work * 100 / (.review_pass + .review_needs_work) | floor)
          else null end),
        release_rate_pct: (if (.work_pr_opened + .work_released_no_pr) > 0
          then (.work_released_no_pr * 100 / (.work_pr_opened + .work_released_no_pr) | floor)
          else null end)
      }
    | . + {
        claim_to_pr_secs: (dur("claim"; "work") | if length > 0
          then {count: length, avg: (add/length | floor), max: max}
          else null end)
      }
  ' "$AUDIT_LOG"
else
  echo "  (no audit log found — nothing recorded on this runner yet)"
fi

echo
echo "== Live queue depths ($REPO) =="
for status in available claimed in-review changes-requested blocked; do
  count="$(gh issue list --repo "$REPO" --state open --label "status: $status" --limit 100 --json number --jq 'length' 2>/dev/null || echo '?')"
  printf '  %-20s %s\n' "status: $status" "$count"
done
prs="$(gh pr list --repo "$REPO" --state open --json number --jq 'length' 2>/dev/null || echo '?')"
printf '  %-20s %s\n' "open PRs" "$prs"
