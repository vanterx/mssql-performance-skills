#!/usr/bin/env bash
# scripts/doctor.sh — deployment health check.
#
# Verifies everything the workflow needs before you run a single loop:
# binaries, auth, repo resolution, labels, trust config, branch protection.
# Read-only — makes no changes anywhere. Run this after initial setup and
# whenever something behaves oddly.
#
#   ./scripts/doctor.sh
#
# Exit code: 0 = all checks passed (warnings allowed), 1 = at least one
# hard failure.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="doctor"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() { printf '  ✅ PASS  %s\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
warn() { printf '  ⚠️  WARN  %s\n' "$*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { printf '  ❌ FAIL  %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

REQUIRED_LABELS=(
  "status: available" "status: claimed" "status: in-review"
  "status: changes-requested" "status: blocked" "status: done"
  "review: claimed" "review: human-only" "do-not-automate" "priority: high"
)

echo "== Binaries =="
for bin in git gh jq; do
  if command -v "$bin" >/dev/null 2>&1; then pass "$bin on PATH"; else fail "$bin missing from PATH"; fi
done
for cli in claude codex hermes opencode; do
  if command -v "$cli" >/dev/null 2>&1; then pass "agent CLI '$cli' on PATH"; fi
done
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1 && ! command -v hermes >/dev/null 2>&1 && ! command -v opencode >/dev/null 2>&1; then
  warn "no agent CLI (claude/codex/hermes/opencode) on PATH — worker/review loops can't run on this machine"
fi

echo "== Authentication =="
if gh auth status >/dev/null 2>&1; then
  pass "gh authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
  fail "gh is not authenticated — run 'gh auth login'"
fi
if [ -n "${REVIEW_GITHUB_TOKEN:-}" ]; then
  pass "REVIEW_GITHUB_TOKEN is set (strict two-identity review available)"
elif [ "${AW_ALLOW_SOLO_REVIEW:-0}" = "1" ]; then
  warn "solo review mode enabled (AW_ALLOW_SOLO_REVIEW=1) — identity separation not enforced"
else
  warn "no REVIEW_GITHUB_TOKEN and no AW_ALLOW_SOLO_REVIEW — review_work.sh will refuse to start"
fi

echo "== Repository =="
if [ -n "$REPO" ] && [ "$REPO" != "/" ]; then
  pass "target repo resolves to $REPO"
else
  fail "cannot resolve target repo — set AW_REPO=owner/name"
fi

echo "== Labels =="
if [ -n "$REPO" ] && gh auth status >/dev/null 2>&1; then
  existing="$(gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  if [ -z "$existing" ]; then
    warn "could not list labels for $REPO (missing permissions or empty repo)"
  else
    missing=0
    for l in "${REQUIRED_LABELS[@]}"; do
      if ! grep -qxF "$l" <<<"$existing"; then
        fail "label missing: '$l' (create it from .github/labels.yml — see .claude/docs/aw/OPERATIONS.md)"
        missing=1
      fi
    done
    [ "$missing" = "0" ] && pass "all ${#REQUIRED_LABELS[@]} required labels exist"
  fi
fi

echo "== Trust config =="
if [ -f "$TRUSTED_REVIEWERS_FILE" ]; then
  if jq -e . "$TRUSTED_REVIEWERS_FILE" >/dev/null 2>&1; then
    wl_count="$(jq '.whitelist | length' "$TRUSTED_REVIEWERS_FILE")"
    if [ "$wl_count" -gt 0 ]; then
      pass "trusted-reviewers.json valid ($wl_count whitelisted, $(required_approvals) approval(s) required)"
    else
      warn "trusted-reviewers.json whitelist is empty — merge_ready.sh will never find a trusted approval"
    fi
  else
    fail "trusted-reviewers.json is not valid JSON"
  fi
else
  warn "no $TRUSTED_REVIEWERS_FILE — merge_ready.sh falls back to an empty whitelist"
fi

echo "== Branch protection =="
if [ -n "$REPO" ] && gh auth status >/dev/null 2>&1; then
  default_branch="$(gh api "repos/$OWNER/$NAME" --jq .default_branch 2>/dev/null || echo main)"
  contexts="$(gh api "repos/$OWNER/$NAME/branches/$default_branch/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null || true)"
  if [ -z "$contexts" ]; then
    warn "no required status checks on '$default_branch' — the $REVIEW_CHECK_CONTEXT gate is not enforced by GitHub"
  elif grep -qxF "$REVIEW_CHECK_CONTEXT" <<<"$contexts"; then
    pass "branch protection on '$default_branch' requires $REVIEW_CHECK_CONTEXT"
  else
    warn "branch protection exists but does not require $REVIEW_CHECK_CONTEXT"
  fi
fi

echo "== Autonomy configuration =="
if [ -f "$AUTONOMY_FILE" ]; then
  if jq -e . "$AUTONOMY_FILE" >/dev/null 2>&1; then
    at_enabled="$(autonomy_setting '.auto_triage.enabled' 'false')"
    at_agent="$(autonomy_setting '.auto_triage.agent_triage' 'false')"
    ar_ci="$(autonomy_setting '.auto_resume.ci_failures' 'false')"
    ar_conf="$(autonomy_setting '.auto_resume.merge_conflicts' 'false')"
    dep_gate="$(autonomy_setting '.dependency_gating' 'true')"
    planner="$(autonomy_setting '.planner.enabled' 'false')"

    level="L1 (loops only — humans triage every issue)"
    [ "$at_enabled" = "true" ] && level="L2 (auto-triage)"
    { [ "$ar_ci" = "true" ] || [ "$ar_conf" = "true" ]; } && level="L3 (auto-triage + auto-resume)"
    [ "$planner" = "true" ] && level="L4 (fully autonomous — planner generates backlog)"
    pass "autonomy.json valid — effective level: $level"
    pass "toggles: auto_triage=$at_enabled (agent=$at_agent) auto_resume(ci=$ar_ci, conflicts=$ar_conf) dep_gating=$dep_gate planner=$planner"

    if [ "$at_agent" = "true" ]; then
      visibility="$(gh api "repos/$OWNER/$NAME" --jq .visibility 2>/dev/null || echo unknown)"
      if [ "$visibility" = "public" ]; then
        warn "agent_triage is enabled on a PUBLIC repo — any issue author can reach your triage agent; see .claude/docs/aw/AUTONOMY.md#what-each-rung-costs-you-read-before-climbing"
      fi
    fi
    if [ "$planner" = "true" ]; then
      goals="$REPO_DIR/$(autonomy_setting '.planner.goals_file' 'GOALS.md')"
      if [ ! -f "$goals" ]; then
        fail "planner enabled but goals file missing: $goals"
      elif grep -q 'TODO(adopter)' "$goals"; then
        warn "planner enabled but $goals is still the template stub — plan_work.sh will refuse to run"
      else
        pass "planner goals file present and customized"
      fi
    fi
  else
    fail "$AUTONOMY_FILE is not valid JSON — all autonomy features fail safe to OFF"
  fi
else
  pass "no autonomy.json — all autonomy features off (level L1)"
fi

echo "== Prompt templates =="
declare -A TEMPLATE_VARS=(
  [work.md]="issue_number issue_title issue_body skills_section tdd_section"
  [rework.md]="issue_number pr_number feedback tdd_section"
  [review.md]="pr_number title body diff history tdd_criterion review_file"
  [triage.md]="issue_number issue_title issue_body"
  [plan.md]="max_issues goals_file goals recent_closed"
)
for tpl in work.md rework.md review.md triage.md plan.md; do
  path="$PROMPTS_DIR/$tpl"
  if [ ! -f "$path" ]; then
    fail "prompt template missing: $path (the loops cannot run without it)"
    continue
  fi
  open_count="$(grep -o '{{' "$path" | wc -l)"
  close_count="$(grep -o '}}' "$path" | wc -l)"
  if [ "$open_count" != "$close_count" ]; then
    warn "$tpl has unbalanced {{ }} ($open_count opening vs $close_count closing)"
  fi
  unknown=""
  for ph in $(grep -o '{{[a-z_]*}}' "$path" | sort -u | tr -d '{}'); do
    case " ${TEMPLATE_VARS[$tpl]} " in
      *" $ph "*) ;;
      *) unknown="$unknown $ph" ;;
    esac
  done
  if [ -n "$unknown" ]; then
    warn "$tpl contains placeholders the scripts never fill:$unknown (they will be sent to the agent literally)"
  else
    pass "$tpl present, placeholders all recognized"
  fi
done

echo "== Adopter customization =="
if [ -f "$REPO_DIR/AGENT_CONTRACT.md" ] && grep -q 'TODO(adopter)' "$REPO_DIR/AGENT_CONTRACT.md"; then
  warn "AGENT_CONTRACT.md still contains the TODO(adopter) placeholder — agents are working without project-specific context"
elif [ -f "$REPO_DIR/AGENT_CONTRACT.md" ]; then
  pass "AGENT_CONTRACT.md has no template placeholder markers"
else
  fail "AGENT_CONTRACT.md missing — this repo keeps AGENTS.md for repo gotchas and AGENT_CONTRACT.md for the workflow operating contract"
fi

echo "== Runtime environment =="
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    warn "running under Git Bash/MSYS on Windows — usable, but ensure 'jq' is installed and prefer WSL for always-on runner loops"
    ;;
  *)
    pass "POSIX runtime: $(uname -s 2>/dev/null || echo unknown)"
    ;;
esac

echo "== Observability =="
if [ -n "$AUDIT_LOG" ]; then
  pass "audit trail enabled -> $AUDIT_LOG"
else
  warn "audit trail disabled (AW_AUDIT_LOG is empty)"
fi

echo
echo "doctor: $PASS_COUNT passed, $WARN_COUNT warnings, $FAIL_COUNT failures"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
