# Automation & Status Lifecycle

This is the reference for how issues and PRs move through this workflow.
**The scripts own every status change and the merge gate — agents only do
the work.**

## Status labels

| Label | Applies to | Set by | Meaning |
|---|---|---|---|
| *(no status)* | new issues | issue template | Not yet triaged — invisible to every automation loop |
| `status: available` | issues | maintainer / scripts (on release) | Up for grabs — the only status `start_work.sh` picks up fresh |
| `status: claimed` | issues | `start_work.sh` | A worker is on it |
| `status: in-review` | issues | scripts + `issue-status.yml` | PR open, awaiting adversarial review |
| `status: changes-requested` | issues | `review_work.sh` | Review found problems — routed back for rework |
| `status: blocked` | issues | humans only | Waiting on something; every loop ignores this issue |
| `status: done` | issues | merge automation | Merged and complete |
| `review: claimed` | PRs | `review_work.sh` | A reviewer is holding this PR (prevents double review) |
| `review: human-only` | PRs | maintainers | Skip all review automation — a human must review and merge |
| `do-not-automate` | issues | humans only | Parking brake — excluded from every automation queue |
| `priority: high` | issues | humans | Jumps to the front of every queue |

## Lifecycle

```
(no status) ──G0──▶ available ──claim──▶ claimed ──PR opened──▶ in-review ──pass+merge──▶ done
                        ▲                     │                     │
                        │                     │ PR closed/no PR     │ NEEDS_WORK
                        └────── release ──────┘                     ▼
                                              changes-requested ──▶ rework loop
```

**G0** (the only human gate in this trimmed-down lifecycle): applying
`status: available` to a brand-new issue. Until that label exists, no
script will touch the issue — this is your review point before anything
gets worked on autonomously. Add human gates freely (an extra label, an
extra required approval) anywhere your project needs more oversight than
this baseline.

## Why `merge_ready.sh` exists

GitHub's native "require approving reviews" branch protection only counts
reviews from people with **write access** to the repo. If you want
contributors without write access to meaningfully review PRs, their
approvals would never count toward the native gate — deadlocking any
workflow that relies on outside contributors.

So the merge decision doesn't live in GitHub's built-in approval gate. It
lives in `scripts/merge_ready.sh`, which reads the recorded review state
(regardless of the reviewer's permission level), applies its own
`.github/trusted-reviewers.json` whitelist, and sets the `aw/merge-gate`
commit status itself before merging. This decouples "who is allowed to
review" from "who has write access" — configure branch protection to
require the `aw/merge-gate` status check, not GitHub's native review count.

## Solo mode

The strict adversarial-review model requires a second GitHub identity
(`REVIEW_GITHUB_TOKEN`) so the reviewer is never the PR's author. For a
single maintainer trying this workflow without provisioning a bot account,
`scripts/review_work.sh` supports an explicit opt-in fallback:

```bash
AW_ALLOW_SOLO_REVIEW=1 ./scripts/review_work.sh
```

This is **fail-closed by design**: simply forgetting to set
`REVIEW_GITHUB_TOKEN` stops the script with an error rather than silently
reviewing as the author. Solo mode must be turned on deliberately, and
every artifact it touches says so — the Action log gets a `::warning::`,
the review file gets a `[SOLO MODE]` banner, and the commit-status
description reads `solo-mode: reviewer=author`. Nothing about solo mode is
hidden from someone auditing a merged PR later.

`merge_ready.sh`'s trust check does not special-case solo mode — it
evaluates the same whitelist + required-approvals logic regardless of how
the underlying review was produced. If you're running solo, put your own
login in `.github/trusted-reviewers.json`'s whitelist.

## Customizing prompts

Every prompt the loops feed to an agent lives as a plain markdown file in
`prompts/` (`work.md`, `rework.md`, `review.md`) with `{{variable}}`
placeholders, rendered by a dependency-free bash substitution
(`render_template()` in `scripts/lib/common.sh`). Teams tune agent
behavior by editing these files — never the scripts. Point
`AW_PROMPTS_DIR` elsewhere to keep repo-specific prompt overrides outside
the template's own files.

Two optional slots are filled by the scripts:

- **Per-issue skills** — if an issue body contains a `## Skills` section,
  its content is passed to the worker as an advisory "the author requests
  these tools" block. It is untrusted author input: framed as a request,
  never as an instruction that overrides the operating contract, and only
  reachable after a human applied `status: available` (gate G0).
- **TDD enforcement** — `AW_ENFORCE_TDD=1` injects tests-first
  requirements into the work and rework prompts AND a matching
  NEEDS_WORK criterion into the review prompt, so the writer and the
  gate enforce the same policy.

## Multi-reviewer quorum

By default one PASS from the review loop merges (when `AW_AUTO_MERGE=1`).
For critical repos, set `required_approvals` in
`.github/trusted-reviewers.json` above 1 (or override with
`AW_REVIEW_QUORUM`) and run one `review_work.sh` per reviewer identity
(each with its own `REVIEW_GITHUB_TOKEN`). Each reviewer records an
independent verdict; the merge gate stays `pending` ("Quorum: N/M
trusted approvals") until enough distinct trusted reviewers' latest
reviews are APPROVED, and the reviewer that completes the quorum merges.
Any NEEDS_WORK still blocks immediately. The quorum counts exactly the
way `merge_ready.sh` counts, so the two tools never disagree.

## Observability

Every state transition the tooling performs is recorded twice:

- **Runner log** (stderr; optionally `AW_LOG_FILE`, optionally
  `AW_LOG_FORMAT=json` for log shippers) — leveled, timestamped
  operational logging.
- **Audit trail** (`.aw/audit.jsonl`, append-only JSONL, on by default) —
  one record per claim, status change, review verdict, merge-gate write,
  merge, and reap action, with actor, agent, target, outcome, and
  timestamp. Query it with `jq`; see
  [OPERATIONS.md](OPERATIONS.md#monitoring--observability) for recipes.

`./scripts/doctor.sh` gives a point-in-time health check of the whole
deployment (labels, auth, branch protection, trust config).

## Cost & safety notes

- Every agent CLI is invoked with its unattended-execution flags (`codex
  exec --dangerously-bypass-approvals-and-sandbox`, `claude -p
  --permission-mode bypassPermissions`, `hermes chat -Q --yolo`). Only run
  these scripts against a repo and issue queue you trust — an issue body
  is attacker-controllable input to whatever agent reads it.
- `AW_AGENT_TIMEOUT` (default 2400s) caps a single agent invocation so a
  runaway run doesn't block the loop forever.
- `review_work.sh` fails closed: an ambiguous or missing verdict is
  treated as `NEEDS_WORK`, never as an implicit pass.
- No GitHub Actions secret is required for `issue-status.yml` or
  `reap.yml` — both run on the ambient `GITHUB_TOKEN`. The only secret in
  this system is `REVIEW_GITHUB_TOKEN`, and it's deliberately a
  **local/contributor-supplied** credential, not a repo secret — agent
  runs happen on contributors' own machines with their own CLI
  subscriptions, not in CI.
