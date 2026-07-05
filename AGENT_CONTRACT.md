# Agent Operating Contract

This document is for any AI coding agent (Claude Code, OpenCode, Codex, or
a human following the same loop) working in this repository. If you are an
agent invoked by `scripts/start_work.sh` or `scripts/review_work.sh`, this
is your instruction set for the claim/work/review/merge loop. For what
this repository actually *is* and how to work in it day to day — file map,
skill conventions, verify-docs.sh gate, dollar-sign gotcha — see
[AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md); this file only covers
the AgentWorks orchestration layer.

## About this project

`mssql-performance-skills` is a Markdown-only skills library — no build
system, no application code, no test suite. "Doing the work" means editing
`SKILL.md` / `references/check-explanations.md` files under `skills/*/`
per the conventions in `CLAUDE.md`, and running
`bash scripts/verify-docs.sh` before opening a PR (a PostToolUse hook also
runs it after every Write/Edit — check its output). Because there is no
test suite, `AW_ENFORCE_TDD` stays `0` here; `verify-docs.sh` is the
correctness gate instead.

## The core rule

**The scripts own every status change and the merge gate. You only do the
actual work.** Never add, remove, or change a label or assignee yourself —
`start_work.sh`, `review_work.sh`, `reap.sh`, and `merge_ready.sh` do that.
If you find yourself about to run `gh issue edit --add-label` or similar,
stop — that's not your job.

## The loop

1. **Pick one unclaimed issue.** Prefer `status: available`. One issue per
   branch, one branch per PR.
   ```
   gh issue list --label "status: available" --state open --json number,title,labels
   ```

2. **Claim it before starting.**
   ```
   gh issue edit <n> --add-assignee @me --add-label "status: claimed" --remove-label "status: available"
   gh issue comment <n> --body "Claiming this — starting now."
   ```
   If you don't have write access to the repo, skip the claim and go
   straight to the fork workflow: fork the repo, push your branch there,
   then `gh pr create --repo <upstream-owner>/<upstream-repo> --head <you>:<branch>`.

3. **Read the whole chain** — the issue, any parent/linked issues, and any
   prior PRs or review comments referencing it — before writing any code.
   Avoid duplicating work that's already in flight. If your issue should
   wait for another one, say so with a line-anchored `Depends-on: #N` in
   the issue body — the worker loop skips issues whose dependencies are
   still open.

4. **Do the work.** Stay in scope: fix what the issue asks for. If you spot
   something else worth fixing, note it in the PR description or open a new
   issue — don't fold it into this PR.

5. **Open one PR per issue.**
   ```
   git checkout -b aw/issue-<n>
   git commit -m "...(Closes #<n>)"
   git push -u origin aw/issue-<n>
   gh pr create --fill --body "Closes #<n>. <summary>"
   ```

6. **Expect adversarial review.** A different identity will review your PR
   and actively try to find problems with it — that's the point, not a
   personal judgment. Respond to feedback with evidence (test output, a
   reasoned explanation, a fix) rather than defensiveness.

## Hard rules

- **One issue per PR.** Don't bundle unrelated changes.
- **Stay in scope.** Don't refactor or expand beyond what the issue asks
  for without opening a new issue first.
- **Never touch labels or assignees.** That's the orchestration scripts'
  job — see "The core rule" above.
- **Don't rework a PR you didn't author** unless you're specifically
  running the rework loop (`scripts/start_work.sh` picks up
  `status: changes-requested` issues assigned to the current identity).
- **Respect existing conventions** in this repo before introducing new
  ones. If this project has an ADR/decision-log directory, read it before
  making structural changes.
- **Changes to `scripts/`, `.github/workflows/`, `.github/autonomy.json`,
  or `GOALS.md` are governance changes**, not ordinary work items — the
  adversarial review treats them as needing explicit justification and,
  in solo-review setups, extra scrutiny. Don't casually "improve" the
  orchestration scripts while working on an unrelated issue.

## Running it on autopilot

Six scripts do all the bookkeeping — see `.claude/docs/aw/AUTOMATION.md` for the full
status lifecycle and `.claude/docs/aw/AUTONOMY.md` for the opt-in autonomy
ladder these scripts read from `.github/autonomy.json` (everything in it
is off in this repo today — L1, fully manual triage):

| Script | Role |
|---|---|
| `scripts/start_work.sh` | Worker loop: claims available work, runs the agent, opens a PR |
| `scripts/review_work.sh` | Adversarial reviewer loop: reviews open PRs, sets the merge-gate check |
| `scripts/reap.sh` | Garbage collector: frees stale claims and reworks, heals mislabeled state |
| `scripts/merge_ready.sh` | Evaluates trust-model approval and merges READY PRs |
| `scripts/triage_work.sh` | Agent-triage loop (autonomy L2, off) — inert while `auto_triage.agent_triage` is `false` |
| `scripts/plan_work.sh` | Backlog planner (autonomy L4, off) — inert while `planner.enabled` is `false` |

Every PR is adversarially reviewed before it can merge, and by default the
review must come from a **different identity** than the author (branch
protection should require a non-author approval plus a passing
`aw/merge-gate` status check). A documented solo-review fallback exists for
single-maintainer setups — see `.claude/docs/aw/AUTOMATION.md#solo-mode` — but it is
opt-in and always leaves a visible marker that identity separation was not
enforced for that review.
