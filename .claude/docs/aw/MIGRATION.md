# Migration Guide

Upgrade notes for adopters tracking this template across releases. See
[CHANGELOG.md](../CHANGELOG.md) for the full change list per version.

## 1.1.0 → 1.2.0

**Everything is additive and off by default** — upgrading changes no
behavior until you edit `.github/autonomy.json`.

- New files to copy: `.github/autonomy.json` (stub, all off),
  `.github/workflows/triage.yml` (no-op while auto_triage disabled),
  `prompts/triage.md`, `prompts/plan.md`, `GOALS.md` (stub),
  `scripts/triage_work.sh`, `scripts/plan_work.sh`, `deploy/`,
  `AUTONOMY.md` (this repo keeps it at `.claude/docs/aw/AUTONOMY.md`), and
  optionally `.github/workflows/agent-runner.yml.disabled`.
- `dependency_gating` defaults ON: issues whose line-anchored
  `Depends-on: #N` references are still open get skipped by the worker
  loop (no label churn). If you used that exact phrase decoratively in
  issue bodies, either mean it or disable the toggle.
- Custom `prompts/review.md`: the governance-guard path list grew
  (autonomy.json, GOALS.md, prompts/, aw.conf) — re-sync your copy.
- One review-loop behavior refinement rides along: `rework` prompts now
  include automation feedback (CI-failure / conflict marker comments)
  when auto-resume posted any.

## 1.0.0 → 1.1.0

**Breaking-ish (behavioral):**

- **Review file moved out of the worktree.** The reviewer agent now
  writes to a randomized `mktemp` path passed via `{{review_file}}`
  instead of `.aw-review.md` inside the checkout (closes a forgery hole:
  a PR could commit its own review file with `VERDICT: PASS`). If you
  customized `prompts/review.md`, keep the `{{review_file}}` placeholder
  — a hardcoded path will break crash detection.
- **Verdict parsing is strict.** The verdict must be the **last
  non-empty line** of the agent's output (or of the review file). Review
  prompts that let the agent print anything after the verdict line will
  now fail closed to NEEDS_WORK. The shipped `prompts/review.md` already
  states this contract.
- **Agent output is capped** at 10 MB (`AW_AGENT_OUTPUT_LIMIT`). A run
  that hits the cap is treated as a tooling failure (issue released /
  check left unset), not as a work verdict. Raise the limit if your
  agents legitimately stream more.
- **Review queue order** changed from random to oldest-first. No action
  needed; expect older PRs to clear first.

**Additive (no action required):**

- Prompt builders moved from the loop scripts into
  `scripts/lib/common.sh` (`build_work_prompt` / `build_rework_prompt` /
  `build_review_prompt`). If you patched the old `work_prompt()` in
  `start_work.sh`, re-apply the change in common.sh — or better, move
  your customization into `prompts/*.md`.
- New tools: `scripts/render_prompt.sh` (prompt preview),
  `scripts/metrics.sh` (audit-trail stats), `tests/run.sh` (harness, new
  `tests` CI job).
- New signals: `.aw/heartbeat-<script>` liveness files; truncation
  warnings when issue/reap queries hit the 100-item cap.
- `doctor.sh` gained prompt-template, AGENTS.md-placeholder, and runtime
  checks — expect new WARNs the first run after upgrading.

## 0.1.0 → 1.0.0

- **`prompts/` directory is required** (work/rework/review templates) —
  the loops fail loudly without it. Copy it alongside `scripts/`.
- Labels and the status lifecycle are unchanged.
- All new env vars are additive with safe defaults (`AW_LOG_*`,
  `AW_AUDIT_LOG`, `AW_RETRY_*`, `AW_SINGLE_INSTANCE`,
  `AW_ENFORCE_TDD`, `AW_REVIEW_QUORUM`, `AW_PROMPTS_DIR`).
- New optional config files: `aw.conf` (committed) / `aw.conf.local`
  (gitignored). Existing env-var-only setups keep working.
- `merge_ready.sh` now warns and fails safe (empty whitelist) on
  malformed `trusted-reviewers.json` instead of misparsing it.
