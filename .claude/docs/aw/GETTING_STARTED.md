# Getting Started

This is a template. It's meant to be copied into (or added as scripts in)
**your own project**, not run as-is against this repo. Follow these steps
to adopt it.

> **Shortcut:** instead of doing this by hand, paste
> [ADOPTION_PROMPT.md](ADOPTION_PROMPT.md) into your AI coding agent
> inside your target repo — it orchestrates every step below, asks you
> the decisions that are yours, and verifies with `doctor.sh` at the end.

## 1. What to keep vs. rename

Keep as-is (these are just internal naming, no need to change them):
- The `AW_*` environment variable prefix
- Script names (`start_work.sh`, `review_work.sh`, `reap.sh`,
  `merge_ready.sh`, `validate.sh`)
- Label names (`status: *`, `review: claimed`, `review: human-only`,
  `do-not-automate`, `priority: high`)

Actually change:
- `prompts/*.md` — the agent prompts are template files with `{{var}}`
  placeholders; tune the instructions/criteria for your project here,
  never in the scripts.
- `.github/trusted-reviewers.json` — put real GitHub logins in `whitelist`
  and set `required_approvals` (values above 1 enable multi-reviewer
  quorum — see AUTOMATION.md#multi-reviewer-quorum).
- `AGENTS.md` / `README.md` — replace the placeholder description with
  your project's actual name and what "doing the work" means here.
- `.github/workflows/validate.yml`'s `CONTENT_DIRS` — point it at your
  project's real content/source directories, and replace the checks in
  `scripts/validate.sh` with whatever your project should actually enforce
  (or delete `validate.yml`/`validate.sh` entirely if you don't want a
  content-validation step).
- Delete `example/` once you've validated the loop works end-to-end (see
  `SETUP.md`).

## 2. Prerequisites

- [`gh`](https://cli.github.com/) (GitHub CLI), authenticated:
  `gh auth login`
- `jq`
- At least one of: `claude` (Claude Code), `codex` (OpenAI Codex CLI),
  `hermes` — whichever agent CLI(s) you plan to run with `AW_AGENT`.

**Windows:** the scripts are bash. Git Bash works for occasional runs
(install `jq` separately — it isn't bundled), but for always-on runner
loops prefer WSL, which behaves like the Linux CI environment the
scripts are tested against. `./scripts/doctor.sh` flags the runtime it
detects.

## 3. Create the labels

```bash
# from .github/labels.yml
while IFS= read -r name; do
  color=$(yq ".[] | select(.name == \"$name\") | .color" .github/labels.yml)
  desc=$(yq ".[] | select(.name == \"$name\") | .description" .github/labels.yml)
  gh label create "$name" --color "$color" --description "$desc" --force
done < <(yq '.[].name' .github/labels.yml)
```
(Any label-sync tool or a one-time manual pass through `gh label create`
works too — `.github/labels.yml` is just the reference list, it isn't
applied automatically.)

## 4. Set up branch protection

On your default branch, require the **`aw/merge-gate`** status check
before merging. Do **not** rely on GitHub's native "require approving
reviews" count — see `AUTOMATION.md` for why `merge_ready.sh` exists
and reads reviews independently of GitHub's own permission-gated count.

## 5. Configure review identity

Pick one:
- **Strict (recommended once you have more than one contributor):**
  create or designate a second GitHub identity (a bot account or a
  teammate) with write access, generate a personal access token for it,
  and export it as `REVIEW_GITHUB_TOKEN` wherever `review_work.sh` runs.
- **Solo:** export `AW_ALLOW_SOLO_REVIEW=1` instead. Understand the
  trade-off documented in `AUTOMATION.md#solo-mode` before doing
  this for anything beyond a personal project.

## 6. Point the scripts at your repo

The scripts auto-detect the repo from your git remote via `gh repo view`.
To target explicitly (e.g. running from a different working directory),
set `AW_REPO=owner/name` — in the environment, or declaratively:

- `aw.conf` (committed) — team-wide defaults, e.g. `AW_AGENT=claude`,
  `AW_POLL_SECONDS=300`. Never put secrets here.
- `aw.conf.local` (gitignored) — operator-local values, including
  `REVIEW_GITHUB_TOKEN` if you don't use a secret manager.

Precedence: environment > `aw.conf.local` > `aw.conf` > built-in
defaults. The full variable reference is in
[OPERATIONS.md](OPERATIONS.md).

## 6a. Verify the deployment

```bash
./scripts/doctor.sh
```

Read-only. Checks binaries, auth, repo resolution, all ten required
labels, trust config, branch protection, and review-identity setup — fix
every FAIL (and ideally every WARN) before running a loop.

## 7. Try it safely before pointing at real work

- Every script that mutates GitHub state respects `AW_DRY_RUN=1` for a
  read-only report (fully wired for `reap.sh` and `merge_ready.sh`;
  `start_work.sh`/`review_work.sh` will log what they'd claim/review
  without changing labels when set).
- Walk through `SETUP.md` against `example/NOTES.md` first — it's a
  toolchain-free target file specifically for validating the claim → work
  → review → merge loop, including one deliberately-broken example that
  exercises the rework path, before you point any of this at your real
  backlog.
