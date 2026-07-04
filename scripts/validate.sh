#!/usr/bin/env bash
# scripts/validate.sh — deterministic content validator, run by
# .github/workflows/validate.yml over an untrusted PR's content overlay.
#
# This template ships with a minimal, format-agnostic check (no broken
# markdown links, no obviously-empty files) since it has no fixed content
# type. Replace the checks below with whatever your project actually
# needs to enforce (schema validation, required frontmatter, lint rules...).
#
# SECURITY NOTE: this script is always run from the BASE branch's version,
# never the PR's own copy — see .github/workflows/validate.yml. A PR can
# never smuggle in a malicious validator or silence its own check.
#
# HARDENING RULE for anyone extending this file: the directories passed in
# contain ATTACKER-CONTROLLED content overlaid from the PR head. Only ever
# READ that content (grep, parse, lint-as-data). Never execute it, source
# it, install from it, or pass it to a tool that runs code from its input
# (e.g. `npm install` on an overlaid package.json, `python` on an overlaid
# file, `make` on an overlaid Makefile). If your language's linter/test
# runner executes project code, run it in the PR's own CI (`pull_request`
# trigger, no secrets) instead of here.
#
# Example project-specific validators (safe: run against YOUR base-branch
# code in a `pull_request`-triggered workflow, not this overlay):
#   npm run lint && npm test
#   python -m pytest
#   cargo check && cargo clippy -- -D warnings
#
#   ./scripts/validate.sh <dir> [<dir> ...]
set -uo pipefail

fail=0

check_dir() {
  local dir="$1" f
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    if [ ! -s "$f" ]; then
      echo "::error file=$f::file is empty"
      fail=1
    fi
  done < <(find "$dir" -type f -name '*.md' -print0)
}

if [ "$#" -eq 0 ]; then
  echo "usage: validate.sh <dir> [<dir> ...]" >&2
  exit 2
fi

for d in "$@"; do
  check_dir "$d"
done

if [ "$fail" -eq 0 ]; then
  echo "validate.sh: OK"
else
  echo "validate.sh: FAILED"
fi
exit "$fail"
