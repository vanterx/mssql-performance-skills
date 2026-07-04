#!/usr/bin/env bash
# scripts/review_work.sh — the adversarial review loop.
#
#   REVIEW_GITHUB_TOKEN=<second-identity-pat> ./review_work.sh [claude|codex|hermes|opencode] [--model <name>]
#
# Every PR is reviewed by an identity that MUST differ from its author
# (strict mode). If no second identity is configured, the loop refuses to
# run unless the operator explicitly opts into solo mode — self-review with
# a visible, auditable warning at every layer. See .claude/docs/aw/AUTOMATION.md#solo-mode.
#
# Env: REVIEW_GITHUB_TOKEN AW_ALLOW_SOLO_REVIEW AW_AGENT AW_MODEL AW_AUTO_MERGE
#      AW_PR AW_MAX AW_POLL_SECONDS AW_REVIEW_CLAIM_TTL AW_FORCE AW_REPO REPO_DIR
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="review_work"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REVIEW_CLAIMING_LABEL="review: claimed"
HUMAN_ONLY_LABEL="review: human-only"
AUTO_MERGE="${AW_AUTO_MERGE:-1}"
TARGET_PR="${AW_PR:-}"
MAX="${AW_MAX:-0}"
POLL_SECONDS="${AW_POLL_SECONDS:-60}"
FORCE="${AW_FORCE:-0}"
# Review quorum: distinct trusted approvals needed before this loop
# auto-merges a PASS. Defaults to required_approvals from
# .github/trusted-reviewers.json (1 = today's single-reviewer behavior).
# Set >1 for multi-agent review: run one review_work.sh per reviewer
# identity; each records its verdict, the last one to complete the
# quorum merges. A NEEDS_WORK from any reviewer still blocks immediately.
REVIEW_QUORUM=""   # resolved after preflight (needs the trust config)

# ---------------------------------------------------------------------------
# Identity separation — the core integrity mechanic.
#
# Strict mode (default): REVIEW_GITHUB_TOKEN swaps GH_TOKEN to a second
# identity's token, so all `gh` calls in this script act as a distinct
# reviewer. Self-authored PRs are skipped outright.
#
# Solo mode (opt-in only, never a silent default): if no second token is
# configured, the operator must explicitly set AW_ALLOW_SOLO_REVIEW=1 to
# proceed with self-review. This is fail-closed by design — simply
# forgetting to configure a reviewer token stops the script with an error
# rather than quietly downgrading safety.
# ---------------------------------------------------------------------------
REVIEW_MODE="strict"
if [ -n "${REVIEW_GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="$REVIEW_GITHUB_TOKEN"
elif [ "${AW_ALLOW_SOLO_REVIEW:-0}" = "1" ]; then
  REVIEW_MODE="solo"
else
  err "no REVIEW_GITHUB_TOKEN configured, and AW_ALLOW_SOLO_REVIEW is not set."
  err "  Set REVIEW_GITHUB_TOKEN to a second identity's token for adversarial review, OR"
  err "  set AW_ALLOW_SOLO_REVIEW=1 to explicitly accept single-maintainer self-review (reduced safety guarantee)."
  exit 1
fi

export RUNS_AGENT=1
preflight
acquire_instance_lock "$SCRIPT_NAME"

REVIEW_QUORUM="${AW_REVIEW_QUORUM:-$(required_approvals)}"
[ "$REVIEW_QUORUM" -gt 1 ] 2>/dev/null && log "review quorum: $REVIEW_QUORUM distinct trusted approvals required before auto-merge"

if [ "$REVIEW_MODE" = "solo" ]; then
  log_warn "::warning:: SOLO MODE — reviewer will equal author. Adversarial identity separation is NOT enforced."
fi

REVIEW_FILE=""

cleanup() {
  [ -n "${CLAIMED_PR:-}" ] && release_pr "$CLAIMED_PR"
  [ -n "$REVIEW_FILE" ] && rm -f "$REVIEW_FILE" 2>/dev/null
  remove_worktree
  release_instance_lock
}
trap cleanup EXIT
trap 'exit 130' INT TERM

claim_pr() {  # $1 = PR number -> 0 if claimed
  local pr="$1" labels claimed_at now age
  labels="$(gh pr view "$pr" --repo "$REPO" --json labels --jq '[.labels[].name]')"
  if ! jq -e --arg l "$REVIEW_CLAIMING_LABEL" 'index($l) == null' <<<"$labels" >/dev/null; then
    claimed_at="$(gh api "repos/$OWNER/$NAME/issues/$pr/timeline" --paginate \
      --jq "[.[] | select(.event==\"labeled\" and .label.name==\"$REVIEW_CLAIMING_LABEL\")] | last | .created_at // empty")"
    if [ -n "$claimed_at" ]; then
      now="$(date -u +%s)"
      age=$(( now - $(date -u -d "$claimed_at" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$claimed_at" +%s) ))
      if [ "$age" -lt "$REVIEW_CLAIM_TTL" ]; then
        return 1
      fi
    fi
  fi
  gh pr edit "$pr" --repo "$REPO" --add-label "$REVIEW_CLAIMING_LABEL" >/dev/null 2>&1
  CLAIMED_PR="$pr"
  return 0
}

release_pr() { gh pr edit "$1" --repo "$REPO" --remove-label "$REVIEW_CLAIMING_LABEL" >/dev/null 2>&1 || true; }

open_prs_needing_review() {
  # Oldest first: deterministic and cuts the PR latency tail. Concurrent
  # reviewer loops are already de-conflicted by the review-claim lock, so
  # randomization isn't needed to avoid stampedes.
  gh pr list --repo "$REPO" --state open --json number,createdAt,isDraft,labels \
    --jq "[.[] | select(.isDraft|not) | select(.labels|map(.name)|index(\"$HUMAN_ONLY_LABEL\")|not)] | sort_by(.createdAt) | .[].number"
}

check_state() {  # $1 = sha -> success|failure|pending|none
  gh api "repos/$OWNER/$NAME/commits/$1/statuses" \
    --jq "[.[] | select(.context==\"$REVIEW_CHECK_CONTEXT\")][0].state // \"none\""
}

set_check() {  # $1 sha $2 state $3 description
  # The merge gate is the one write that must not be lost to a transient
  # API failure — retry it.
  gh_retry gh api -X POST "repos/$OWNER/$NAME/statuses/$1" \
    -f state="$2" -f context="$REVIEW_CHECK_CONTEXT" -f description="$3" >/dev/null 2>&1 || true
  audit_event "merge-gate" "sha:${1:0:12}" "$2" "$3"
}

# Prompt construction lives in common.sh (build_review_prompt) so
# scripts/render_prompt.sh previews exactly what this loop sends.
# Verdict parsing is last_verdict_line() from common.sh: the verdict must
# be the LAST non-empty line — quoted examples mid-text can't false-match.

review_one() {  # $1 = PR number
  local pr="$1" author sha logfile verdict body_file
  author="$(gh pr view "$pr" --repo "$REPO" --json author --jq '.author.login')"

  if [ "$REVIEW_MODE" = "strict" ] && [ "$author" = "$ME" ]; then
    log "skip PR #$pr: reviewer identity (@$ME) == author under strict mode"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would claim and review PR #$pr (author: @$author, mode: $REVIEW_MODE)"
    return 0
  fi

  sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid')"
  if [ "$FORCE" != "1" ]; then
    local state; state="$(check_state "$sha")"
    case "$state" in
      none) ;;
      pending)
        # In quorum mode "pending" means "some approvals recorded, quorum
        # not yet met" — another reviewer identity should proceed, but the
        # same identity must not double-review.
        if [ "$REVIEW_QUORUM" -gt 1 ] 2>/dev/null; then
          local mine
          mine="$(gh api graphql -f query="{repository(owner:\"$OWNER\",name:\"$NAME\"){pullRequest(number:$pr){reviews(first:100){nodes{author{login} state submittedAt}}}}}" \
            --jq ".data.repository.pullRequest.reviews.nodes | group_by(.author.login) | map(sort_by(.submittedAt) | last) | .[] | select(.author.login==\"$ME\") | .state" 2>/dev/null)"
          if [ "$mine" = "APPROVED" ]; then
            log "PR #$pr: quorum pending but @$ME already approved — skipping"
            return 0
          fi
        else
          log "PR #$pr @$sha already checked ($state), skipping"
          return 0
        fi
        ;;
      *) log "PR #$pr @$sha already checked ($state), skipping"; return 0 ;;
    esac
  fi

  claim_pr "$pr" || { log "PR #$pr already claimed by another reviewer, skipping"; return 0; }

  git -C "$REPO_DIR" fetch origin --quiet "+pull/$pr/head:refs/aw/pr-$pr"
  make_worktree "refs/aw/pr-$pr" || { err "could not create review worktree for PR #$pr"; return 0; }

  # The review file lives OUTSIDE the worktree at a randomized path. The
  # worktree is a checkout of the (untrusted) PR head — a PR that commits
  # its own ".aw-review.md" containing "VERDICT: PASS" must never be
  # mistaken for reviewer output.
  REVIEW_FILE="$(mktemp "${TMPDIR:-/tmp}/aw-review-XXXXXX.md")"

  local prompt
  if ! prompt="$(build_review_prompt "$pr" "$REVIEW_FILE")" || [ -z "$prompt" ]; then
    err "could not build review prompt for PR #$pr — skipping (check unset, will retry)"
    rm -f "$REVIEW_FILE"; REVIEW_FILE=""
    return 0
  fi

  logfile="$(mktemp)"
  run_agent "$prompt" "$WORKTREE" 2>&1 | head -c "$AGENT_OUTPUT_LIMIT" | tee "$logfile"
  local rc="${PIPESTATUS[0]}"

  if was_interrupted "$rc"; then
    err "review run interrupted (rc=$rc) — stopping the runner"
    exit 130
  fi

  if output_was_truncated "$logfile"; then
    err "reviewer output hit AW_AGENT_OUTPUT_LIMIT ($AGENT_OUTPUT_LIMIT bytes) on PR #$pr — treating as tooling failure, leaving check unset for retry"
    audit_event "review" "pr#$pr" "output-limit" "capped at $AGENT_OUTPUT_LIMIT bytes"
    rm -f "$logfile" "$REVIEW_FILE"; REVIEW_FILE=""
    return 0
  fi

  # Crash detection: the file was created empty by mktemp; the agent must
  # have written actual review content into it.
  if [ ! -s "$REVIEW_FILE" ] && was_usage_limited "$logfile"; then
    log "reviewer tooling failure/usage-limit on PR #$pr — leaving check unset for retry"
    rm -f "$logfile" "$REVIEW_FILE"; REVIEW_FILE=""
    return 0
  fi

  # Verdict: last non-empty line of the agent's stdout (the contract),
  # falling back to the last non-empty line of the review file.
  verdict="$(last_verdict_line "$logfile")"
  [ -z "$verdict" ] && verdict="$(last_verdict_line "$REVIEW_FILE")"
  rm -f "$logfile"

  if [ -z "$verdict" ]; then
    if [ ! -s "$REVIEW_FILE" ]; then
      local marker="<!-- aw-review-crash:$sha -->"
      if ! gh pr view "$pr" --repo "$REPO" --json comments --jq '.comments[].body' | grep -qF "$marker"; then
        gh pr comment "$pr" --repo "$REPO" --body "$marker
🤖 Review tooling crashed without producing a review — will retry next loop, this is not a verdict on the PR." >/dev/null 2>&1 || true
      fi
      rm -f "$REVIEW_FILE"; REVIEW_FILE=""
      return 0
    fi
    log "PR #$pr: ambiguous/missing verdict — failing closed to NEEDS_WORK"
    verdict="NEEDS_WORK"
  fi

  # Solo-mode banner is prepended AFTER crash detection so an empty file
  # still reads as "agent wrote nothing".
  if [ "$REVIEW_MODE" = "solo" ]; then
    local banner_tmp
    banner_tmp="$(mktemp)"
    printf '> [SOLO MODE] Reviewer (@%s) is the same identity as the PR author. Adversarial identity separation was not enforced for this review.\n\n' "$ME" > "$banner_tmp"
    cat "$REVIEW_FILE" >> "$banner_tmp"
    mv "$banner_tmp" "$REVIEW_FILE"
  fi

  body_file="$REVIEW_FILE"

  if [ "$verdict" = "PASS" ]; then
    gh pr review "$pr" --repo "$REPO" --approve --body-file "$body_file" >/dev/null 2>&1 || true
    audit_event "review" "pr#$pr" "pass" "mode=$REVIEW_MODE author=$author"
    local desc="Adversarial review passed"
    [ "$REVIEW_MODE" = "solo" ] && desc="solo-mode: reviewer=author; review passed"

    if [ "$REVIEW_QUORUM" -gt 1 ] 2>/dev/null; then
      # Multi-reviewer quorum: the merge gate stays PENDING (so nobody —
      # human or script — can merge early) until enough DISTINCT trusted
      # reviewers' latest reviews are APPROVED. Same counting rule as
      # merge_ready.sh, so the two tools always agree.
      local approvals
      approvals="$(count_trusted_approvals "$pr" "$author")"
      if [ "$approvals" -lt "$REVIEW_QUORUM" ]; then
        set_check "$sha" pending "Quorum: $approvals/$REVIEW_QUORUM trusted approvals"
        audit_event "review" "pr#$pr" "quorum-pending" "$approvals/$REVIEW_QUORUM trusted approvals"
        log "PR #$pr -> PASS ($approvals/$REVIEW_QUORUM trusted approvals — awaiting quorum, not merging)"
        rm -f "$REVIEW_FILE"; REVIEW_FILE=""
        return 0
      fi
      desc="$desc (quorum $approvals/$REVIEW_QUORUM)"
      log "PR #$pr: quorum met ($approvals/$REVIEW_QUORUM)"
    fi

    set_check "$sha" success "$desc"
    if [ "$AUTO_MERGE" = "1" ]; then
      # Don't trust `gh pr merge`'s exit code alone (branch protection can
      # reject it in ways that still return misleadingly, and `|| true`
      # patterns elsewhere in this codebase mask failures on purpose for
      # best-effort calls) — re-query the PR's actual state afterward and
      # only record success / flip the issue to "done" if it truly merged.
      gh pr merge "$pr" --repo "$REPO" --squash --delete-branch >/dev/null 2>&1 || true
      local merged_state
      merged_state="$(gh pr view "$pr" --repo "$REPO" --json state --jq .state 2>/dev/null || echo "")"
      local iss; iss="$(issue_for_pr "$pr")"
      if [ "$merged_state" = "MERGED" ]; then
        audit_event "merge" "pr#$pr" "ok" "auto-merge after review pass"
        [ -n "$iss" ] && set_status_label "$iss" "done"
      else
        audit_event "merge" "pr#$pr" "blocked" "gh pr merge did not result in a merged PR (branch protection or other gate) — issue left in-review for manual merge"
        log_warn "PR #$pr: PASS but auto-merge did not complete (PR still $merged_state) — merge manually once branch protection allows it: gh pr merge $pr --squash --delete-branch"
      fi
    fi
    log "PR #$pr -> PASS"
  else
    gh pr review "$pr" --repo "$REPO" --request-changes --body-file "$body_file" >/dev/null 2>&1 || true
    local desc="Adversarial review found problems"
    [ "$REVIEW_MODE" = "solo" ] && desc="solo-mode: reviewer=author; review found problems"
    set_check "$sha" failure "$desc"
    audit_event "review" "pr#$pr" "needs-work" "mode=$REVIEW_MODE author=$author"
    local iss; iss="$(issue_addressed_by_pr "$pr")"
    if [ -n "$iss" ]; then
      set_status_label "$iss" "changes-requested"
      gh issue comment "$iss" --repo "$REPO" --body "🔁 Sending PR #$pr back to @$author for rework — see review comments." >/dev/null 2>&1 || true
    fi
    log "PR #$pr -> NEEDS_WORK"
  fi

  rm -f "$REVIEW_FILE"; REVIEW_FILE=""
}

main() {
  local count=0
  if [ -n "$TARGET_PR" ]; then
    review_one "$TARGET_PR"
    return
  fi
  while true; do
    heartbeat
    local prs pr acted=0
    prs="$(open_prs_needing_review)"
    for pr in $prs; do
      review_one "$pr"
      acted=1
      count=$((count+1))
      [ "$MAX" != "0" ] && [ "$count" -ge "$MAX" ] && { log "reached AW_MAX=$MAX, exiting"; return; }
    done
    if [ "$acted" = "0" ]; then
      [ "$POLL_SECONDS" = "0" ] && { log "no PRs to review, exiting"; break; }
      log "no PRs to review, sleeping ${POLL_SECONDS}s"
      sleep "$POLL_SECONDS"
    fi
  done
}

parse_agent_args "$@"
main
