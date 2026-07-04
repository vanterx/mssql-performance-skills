# Operations Runbook

Production guidance for running this workflow at team/org scale. For
first-time setup see [GETTING_STARTED.md](GETTING_STARTED.md); for the
state machine itself see [AUTOMATION.md](AUTOMATION.md).

## Deployment topologies

**Single operator.** One machine runs `start_work.sh` and (with a second
token or solo mode) `review_work.sh`. `reap.yml` handles GC in CI. This is
the starting point and needs nothing beyond `doctor.sh` passing.

**Multi-runner team.** Any number of contributors run `start_work.sh`
concurrently on their own machines with their own agent subscriptions —
the claim protocol (optimistic assign + jittered settle + deterministic
tiebreak) makes this safe with no coordination service. Run at least one
`review_work.sh` under a dedicated bot identity (`REVIEW_GITHUB_TOKEN`)
on a machine that is always on. Rules of thumb:

- Keep roughly one active reviewer loop per 3–5 worker loops.
- Stagger `AW_POLL_SECONDS` across runners (it's jittered by default, but
  don't set every runner to a very low value — API quota is shared).
- Set `AW_SINGLE_INSTANCE=1` in each machine's `aw.conf.local` to prevent
  accidental duplicate loops of the same script on that machine.

**What never runs in CI:** agent invocations. GitHub Actions here only do
deterministic bookkeeping (`issue-status.yml`, `reap.yml`, `ci.yml`,
`validate.yml`) on the ambient `GITHUB_TOKEN`. Model credentials stay on
contributor machines by design — one leaked repo secret should never be
able to spend your whole org's model budget.

## Monitoring & observability

| Signal | Where | What to watch |
|---|---|---|
| Audit trail | `.aw/audit.jsonl` on each runner | Every claim, status change, review verdict, merge-gate write, merge, reap |
| Runner logs | stderr, or `AW_LOG_FILE` per runner | `[ERROR]` lines; retry warnings clustering (API trouble) |
| Queue health | `gh issue list --label "status: claimed"` | Claims older than `AW_CLAIM_TTL` that survive a reap cycle |
| Reviewer health | PRs with `review: claimed` | Locks older than `AW_REVIEW_CLAIM_TTL` |
| Merge gate | commit statuses on PR head SHAs | `aw/merge-gate` stuck at `pending`/absent |
| GC | Actions run history for `reap` | Failures or skipped schedules |

Useful audit queries (per runner):

```bash
# everything that happened to issue 42
jq -c 'select(.target=="issue#42")' .aw/audit.jsonl

# all merges in the last day, with who/what merged them
jq -c 'select(.action=="merge")' .aw/audit.jsonl

# solo-mode reviews (should be empty in production)
jq -c 'select(.action=="review" and (.detail | contains("mode=solo")))' .aw/audit.jsonl
```

For centralized logging, set `AW_LOG_FORMAT=json` and `AW_LOG_FILE` and
ship both that file and `.aw/audit.jsonl` with your usual log forwarder.

**Aggregated stats:** `./scripts/metrics.sh` (read-only) summarizes the
local audit trail — event counts, rework rate, release-without-PR rate,
claim→PR cycle time — plus live queue depths per status label.

**Liveness:** each loop touches `.aw/heartbeat-<script>` (UTC timestamp)
once per iteration. Alert when the file goes stale longer than a few
poll intervals:

```bash
# example: warn if the worker loop hasn't iterated in 15 minutes
find .aw/heartbeat-start_work -mmin +15 | grep -q . && echo "STALE"
```

## Routine tasks

**Weekly**
- Run `./scripts/doctor.sh` on each runner machine; fix WARNs before they
  become incidents.
- Review the audit trail for solo-mode reviews and unexpected merge-gate
  writes.

**Monthly / quarterly**
- Rotate `REVIEW_GITHUB_TOKEN` (see below).
- Re-review `.github/trusted-reviewers.json` — remove departed
  maintainers promptly; this file IS your merge ACL.
- Prune old audit logs per your retention policy (they are append-only
  and grow forever otherwise).

## Token rotation

1. Generate a new PAT for the reviewer bot identity (least privilege:
   `repo` scope on the target repo only).
2. Update `aw.conf.local` / secret manager on every machine running
   `review_work.sh`.
3. Revoke the old token.
4. Verify: `REVIEW_GITHUB_TOKEN=... gh auth status` under the new token,
   then run one `AW_DRY_RUN=1 ./scripts/review_work.sh` cycle.

On suspected exposure: revoke first, then audit — every merge-gate write
made by that identity is in the commit-status history
(`gh api repos/OWNER/NAME/commits/SHA/statuses`) and in `.aw/audit.jsonl`
on the reviewer machine.

## Incident response

**A runaway agent is consuming tokens or thrashing a worktree.**
Kill the runner process (Ctrl-C is safe: SIGINT stops the loop, the EXIT
trap releases locks and worktrees). `AW_AGENT_TIMEOUT` caps any single
run. The claimed issue will be freed by `reap.sh` within `AW_CLAIM_TTL`,
or immediately via
`gh issue edit N --add-label "status: available" --remove-label "status: claimed" --remove-assignee LOGIN`.

**A bad PR merged.**
`git revert` the squash commit on the default branch (open the revert as
a normal PR so it, too, is reviewed). Then check the audit trail: was the
approval from a trusted reviewer? Was it solo mode? Adjust the whitelist
or review prompts accordingly.

**Issues stuck in `changes-requested` with nobody picking them up.**
Expected within `AW_REWORK_TTL`; after that `reap.sh` unassigns them and
any runner may adopt them. If they linger unassigned, the queue has more
rework than worker capacity — add a runner or triage with the
`triage-task` skill.

**Two reviewers reviewed the same PR.**
Harmless (the second verdict overwrites the commit status at the same
SHA) but wasteful — it means the `review: claimed` TTL is shorter than
your slowest review. Raise `AW_REVIEW_CLAIM_TTL`.

**GitHub API rate limiting.**
Runner logs show clustered retry warnings; agents may also report 429s
(handled as usage-limit backoff, `AW_USAGE_LIMIT_SLEEP`). Raise
`AW_POLL_SECONDS`, reduce concurrent runners, or spread runners across
identities.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent keeps releasing issues without opening PRs | Issue too vague/large for one PR; agent can't push (auth); or prompt templates drifted | Read the released-issue comments and the runner log; try `./scripts/render_prompt.sh work <n>` to inspect the exact prompt; split or clarify the issue |
| Review loop finds nothing but PRs are open | PRs are drafts, carry `review: human-only`, or already have a check at the head SHA | `gh pr list --json number,isDraft,labels`; use `AW_FORCE=1 AW_PR=<n>` to re-review one PR |
| Merge gate stuck at "Quorum: N/M" | Fewer distinct trusted reviewer identities than the quorum | Add reviewer identities (each needs its own token) or lower `required_approvals`; `merge_ready.sh` shows who counted |
| PASS recorded but nothing merged | `AW_AUTO_MERGE=0`, quorum pending, or branch protection blocks the bot | Check the commit-status description on the head SHA, then `AW_MERGE=1 ./scripts/merge_ready.sh` |
| "issue snapshot hit the 100-item cap" warnings | More than 100 open issues | Triage the backlog down (G0 is a queue valve, not a dumping ground); oldest issues are invisible until the queue shrinks |
| Issues stuck in `changes-requested`, nobody picks them up | Rework capacity < review strictness; or the author identity is gone | Wait for `reap.sh` to unassign (REWORK_TTL), add a runner, or reassign manually |
| Loop runs but every agent call fails instantly | Agent CLI not on PATH, expired agent subscription, or bad `AW_CLAUDE_PERMISSION_MODE` | `./scripts/doctor.sh`; check the runner log's first `[ERROR]` line |
| Heartbeat stale but process alive | A `gh` call is hung on network | Kill and restart the loop; check GitHub status; consider lowering `AW_AGENT_TIMEOUT` |

## Cost estimation

Every agent invocation spends tokens on: the rendered prompt (~1-2k
tokens) + whatever the agent reads (issue chain, code context — usually
the dominant cost) + its output. A work item typically takes one worker
run plus one review run; add one worker + one review run per rework
cycle. So a rough per-issue model is:

```
cost/issue ≈ (1 + rework_rate) × (worker_run + review_run)
```

where `rework_rate` comes from `./scripts/metrics.sh`. Measure your own
repo's real numbers early — one afternoon of `SETUP.md`-style trial
issues with your actual model gives you a per-issue baseline that no
generic table can. Levers, in order of impact:

1. **G0 gating** — nothing spends until a human labels it; triage before
   labeling (the `triage-task` skill scores value vs token cost).
2. **`AW_MODEL`** — route routine work to a cheaper model; keep the
   stronger model for review (a bad review costs a full rework cycle).
3. **Issue quality** — vague issues drive the rework rate, and rework
   multiplies cost more than any per-run setting.
4. **`AW_AGENT_TIMEOUT` / `AW_AGENT_OUTPUT_LIMIT` / `AW_MAX`** — bound
   the worst case per run and per session.

## Cost controls

- `AW_MAX=N` — hard cap on items per runner invocation; prefer finite
  batches over infinite loops for scheduled/unattended runners.
- `AW_MODEL` — route routine work to a cheaper model; keep the stronger
  model for the reviewer loop (a bad review is costlier than a bad
  draft).
- `AW_AGENT_TIMEOUT` — bounds the worst-case spend of a single run.
- `AW_POLL_SECONDS=0` — "drain the queue and exit" mode for cron-driven
  runners instead of always-on loops.
- Gate G0 is also a budget gate: nothing spends tokens until a human
  labels it `status: available`.

## Environment variable reference

All variables can also be set in `aw.conf` (committed, team defaults) or
`aw.conf.local` (gitignored, operator-local/secrets). Precedence:
environment > `aw.conf.local` > `aw.conf` > built-in default.

| Variable | Default | Purpose |
|---|---|---|
| `AW_REPO` | auto from `gh repo view` | Target repo `owner/name` |
| `AW_AGENT` | `claude` | Worker CLI: `claude` \| `codex` \| `hermes` |
| `AW_MODEL` | agent default | Model override passed to the agent CLI |
| `AW_PROVIDER` | — | Provider (hermes only) |
| `AW_HERMES_PROFILE` / `AW_HERMES_FLAGS` | — / `--yolo --source tool` | Hermes specifics |
| `AW_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Codex unattended flags |
| `AW_CLAUDE_PERMISSION_MODE` | `bypassPermissions` | Claude Code permission mode |
| `AW_AGENT_TIMEOUT` | `2400` | Max seconds per agent invocation (0 = off) |
| `AW_AGENT_OUTPUT_LIMIT` | `10485760` | Byte cap on captured agent output (disk-fill guard; hitting it = tooling failure) |
| `AW_MAX` | `0` | Items per invocation (0 = unlimited) |
| `AW_POLL_SECONDS` | `180` work / `60` review | Idle poll interval (0 = exit when idle) |
| `AW_CLAIM_TTL` | `7200` | Seconds before a claim with no PR is reaped |
| `AW_REWORK_TTL` | `7200` | Seconds before a stale rework is unassigned |
| `AW_REVIEW_CLAIM_TTL` | `1800` | Seconds before a review lock can be taken over |
| `AW_CLAIM_SETTLE` | `8` | Base jitter for claim-race settlement |
| `AW_USAGE_LIMIT_SLEEP` | `3600` | Backoff after a rate-limit/quota signal |
| `AW_DRY_RUN` | `0` | `1` = report intended actions only |
| `AW_RETRY_MAX` / `AW_RETRY_BASE` | `3` / `2` | Retry attempts / first backoff (secs) |
| `AW_LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `AW_LOG_FORMAT` | `text` | `text` \| `json` |
| `AW_LOG_FILE` | — | Also append log lines to this file |
| `AW_AUDIT_LOG` | `.aw/audit.jsonl` | Audit trail path (empty = disabled) |
| `AW_SINGLE_INSTANCE` | `0` | `1` = refuse duplicate loops per script/repo/machine |
| `AW_AUTO_MERGE` | `1` | Reviewer merges on PASS |
| `AW_MERGE` | `0` | `merge_ready.sh` actually merges READY PRs |
| `AW_PR` | — | Target a single PR (review/merge scripts) |
| `AW_FORCE` | `0` | Re-review a PR already checked at its head SHA |
| `AW_REVIEW_CHECK_CONTEXT` | `aw/merge-gate` | Commit-status context of the merge gate |
| `AW_PROMPTS_DIR` | `prompts/` in the repo | Directory of prompt template files ({{var}} placeholders) |
| `AW_ENFORCE_TDD` | `0` | `1` = inject tests-first requirements into work AND review prompts |
| `AW_REVIEW_QUORUM` | `required_approvals` from trust config | Distinct trusted approvals before the review loop auto-merges |
| `AW_TRUSTED_REVIEWERS_FILE` | `.github/trusted-reviewers.json` | Trust config path |
| `AW_TRUST_WHITELIST` / `AW_REQUIRED_APPROVALS` | from trust config | Overrides for `merge_ready.sh` |
| `AW_ALLOW_SOLO_REVIEW` | `0` | `1` = permit self-review (marked everywhere) |
| `REVIEW_GITHUB_TOKEN` | — | Second identity's token for strict review |
