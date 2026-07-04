#!/usr/bin/env bash
# tests/run.sh — zero-dependency test harness for scripts/lib/common.sh.
#
#   ./tests/run.sh
#
# Pure bash + awk assertions; no bats, no network, no gh calls. Tests set
# AW_* env before sourcing the library so everything runs hermetically.
# Exit code: 0 = all passed, 1 = any failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "${2:-}" "${3:-}"; }

assert_eq() {  # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}
assert_contains() {  # desc haystack needle
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "contains: $3" "$2"; fi
}
assert_not_contains() {  # desc haystack needle
  if grep -qF -- "$3" <<<"$2"; then bad "$1" "absent: $3" "present"; else ok "$1"; fi
}

# --- hermetic library load ---------------------------------------------------
export AW_REPO="test-owner/test-repo"
export AW_AUDIT_LOG=""                # no audit writes (also: jq-free run)
export AW_AGENT_OUTPUT_LIMIT=64      # tiny cap for truncation test
export AW_DRY_RUN=0
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== render_template =="
cat > "$TMP/t.md" <<'EOF'
Issue #{{num}}: {{title}}
Body:
{{body}}
Tail: {{unfilled}}
EOF

out="$(render_template "$TMP/t.md" "num=7" "title=Fix the & thing" "body=multi
line \with backslash")"
assert_contains "substitutes number" "$out" "Issue #7"
assert_contains "preserves ampersand (bash 5.2 patsub)" "$out" "Fix the & thing"
assert_contains "preserves backslash" "$out" '\with backslash'
assert_contains "multiline value intact" "$out" "line"
assert_contains "unknown placeholder left literal" "$out" "{{unfilled}}"

# Injection: a VALUE containing a placeholder that IS a known key must stay
# literal (two-phase sentinel rendering).
out="$(render_template "$TMP/t.md" "num=1" "body=evil {{title}} and {{num}}" "title=SAFE")"
assert_contains "value-injected {{title}} stays literal" "$out" "evil {{title}} and {{num}}"
assert_not_contains "injection did not expand to SAFE inside body" "$out" "evil SAFE"

render_template "$TMP/nope.md" "a=b" >/dev/null 2>&1
assert_eq "missing template returns nonzero" "1" "$?"

echo "== issue_skills_section =="
body='Intro text

## Skills
- mcp: playwright
- skill: db-migrations

## Acceptance criteria
- works'
s="$(issue_skills_section "$body")"
assert_contains "extracts skills lines" "$s" "playwright"
assert_not_contains "stops at next heading" "$s" "Acceptance"
s2="$(issue_skills_section "no section here")"
assert_eq "empty when absent" "" "$(printf '%s' "$s2" | tr -d '[:space:]')"

echo "== last_verdict_line =="
printf 'review text\nVERDICT: PASS\n' > "$TMP/v1"
assert_eq "last-line PASS" "PASS" "$(last_verdict_line "$TMP/v1")"

printf 'quote: VERDICT: PASS mid-text\nmore\nVERDICT: NEEDS_WORK\n' > "$TMP/v2"
assert_eq "mid-text quote ignored, last line wins" "NEEDS_WORK" "$(last_verdict_line "$TMP/v2")"

printf 'VERDICT: PASS\ntrailing prose after verdict\n' > "$TMP/v3"
assert_eq "verdict not on last line -> empty (fail closed)" "" "$(last_verdict_line "$TMP/v3")"

printf 'text\nVERDICT: PASS\n\n\n' > "$TMP/v4"
assert_eq "trailing blank lines still match" "PASS" "$(last_verdict_line "$TMP/v4")"

printf 'text\r\nVERDICT: PASS\r\n' > "$TMP/v5"
assert_eq "CRLF tolerated" "PASS" "$(last_verdict_line "$TMP/v5")"

: > "$TMP/v6"
assert_eq "empty file -> empty" "" "$(last_verdict_line "$TMP/v6")"

echo "== output_was_truncated =="
head -c 64 /dev/zero > "$TMP/full"
head -c 10 /dev/zero > "$TMP/small"
output_was_truncated "$TMP/full";  assert_eq "at-cap file detected" "0" "$?"
output_was_truncated "$TMP/small"; assert_eq "small file not truncated" "1" "$?"

echo "== _load_config_file =="
cat > "$TMP/conf" <<'EOF'
# comment
AW_MODEL=conf-model
AW_LOG_LEVEL=debug
NOT_ALLOWED=evil
PATH=/tmp/hax
EOF
(
  unset AW_MODEL NOT_ALLOWED 2>/dev/null
  export AW_LOG_LEVEL="env-wins"
  _load_config_file "$TMP/conf"
  [ "${AW_MODEL:-}" = "conf-model" ]        && echo "ok-model"
  [ "${AW_LOG_LEVEL}" = "env-wins" ]        && echo "ok-precedence"
  [ -z "${NOT_ALLOWED:-}" ]                 && echo "ok-allowlist"
  [ "$PATH" != "/tmp/hax" ]                 && echo "ok-path-safe"
) > "$TMP/conf_out"
assert_contains "allowed key loaded" "$(cat "$TMP/conf_out")" "ok-model"
assert_contains "env beats config file" "$(cat "$TMP/conf_out")" "ok-precedence"
assert_contains "non-AW keys ignored" "$(cat "$TMP/conf_out")" "ok-allowlist"
assert_contains "PATH cannot be hijacked" "$(cat "$TMP/conf_out")" "ok-path-safe"

echo "== set_status_label (dry-run arg construction) =="
DRY_RUN=1
msg="$(set_status_label 42 done 2>&1)"
DRY_RUN=0
assert_contains "dry-run announces the sweep" "$msg" "would set issue #42 to status: done"

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
