#!/usr/bin/env bash
# scripts/render_prompt.sh — preview the exact prompt a loop would send.
#
#   ./scripts/render_prompt.sh work   <issue-number>
#   ./scripts/render_prompt.sh rework <issue-number>
#   ./scripts/render_prompt.sh review <pr-number>
#
# Read-only: fetches the live issue/PR data and prints the rendered prompt
# to stdout, using the same build_* functions the loops use — so what you
# see is byte-for-byte what the agent would receive. Use this to iterate
# on prompts/*.md without burning agent runs.
#
# Honors the same env/config as the loops (AW_ENFORCE_TDD, AW_PROMPTS_DIR,
# AW_REPO, ...). For "review", the review-file path is shown as a
# placeholder since the real path is a per-run mktemp.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_NAME="render_prompt"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

preflight

kind="${1:-}"
number="${2:-}"

usage() {
  echo "usage: render_prompt.sh work|rework|review <issue-or-pr-number>" >&2
  exit 2
}

[ -n "$kind" ] && [ -n "$number" ] || usage
case "$number" in *[!0-9]*) usage ;; esac

case "$kind" in
  work)
    issue_json="$(gh issue view "$number" --repo "$REPO" --json title,body)" \
      || { err "could not fetch issue #$number"; exit 1; }
    build_work_prompt "$number" "$issue_json"
    ;;
  rework)
    pr="$(pr_for_issue "$number")"
    if [ -z "$pr" ]; then
      err "no open PR found for issue #$number — rework prompt needs one"
      exit 1
    fi
    build_rework_prompt "$number" "$pr"
    ;;
  review)
    build_review_prompt "$number" "<mktemp: /tmp/aw-review-XXXXXX.md>"
    ;;
  *)
    usage
    ;;
esac
echo
