# End-to-End Dry Run

A concrete walkthrough to prove the loop works before you point it at real
work. Uses `example/NOTES.md` — a plain markdown file with nothing
language- or stack-specific about it — as the target so this works
regardless of what your actual project is.

Do this in a scratch or private repo first, or accept that it will create
real issues/PRs/commits in whatever repo you run it against.

> This repo's own trial already ran once and `example/NOTES.md` was
> deleted afterward (see git history: `git log --all --diff-filter=D --
> example/NOTES.md`). Restore it first if repeating this walkthrough:
> `git show <commit>^:example/NOTES.md > example/NOTES.md` (use the commit
> that deleted it).

## 1. Create example issues

```bash
gh issue create --title "Add a 'Goals' section to example/NOTES.md" \
  --body "Add a new '## Goals' section to example/NOTES.md with 2-3 bullet points about what this template is for. Closes when the section exists with real content."

gh issue create --title "Fix the typo in example/NOTES.md's intro line" \
  --body "There's a small wording issue in the first paragraph of example/NOTES.md — reword it for clarity."

gh issue create --title "(intentionally vague) Improve example/NOTES.md" \
  --body "Make example/NOTES.md better somehow."
```

Label the first two `status: available`. Leave the third one without a
status label — it should sit invisible to the automation (this is gate
G0), proving that unlabeled issues are safe by default.

## 2. Run the worker loop once

```bash
AW_AGENT=claude AW_MAX=2 AW_POLL_SECONDS=0 ./scripts/start_work.sh
```

Watch for: the issue getting claimed (`status: claimed` + assignee), a
branch `aw/issue-<n>` pushed, a PR opened, and the issue flipping to
`status: in-review`. `AW_MAX=2` stops after two items so it doesn't run
forever; `AW_POLL_SECONDS=0` means "exit instead of waiting" once the
queue is empty.

## 3. Run the review loop

```bash
# strict mode, if you've set up a second identity:
REVIEW_GITHUB_TOKEN=<second-identity-token> AW_AGENT=claude AW_MAX=2 AW_POLL_SECONDS=0 ./scripts/review_work.sh

# solo mode otherwise:
AW_ALLOW_SOLO_REVIEW=1 AW_AGENT=claude AW_MAX=2 AW_POLL_SECONDS=0 ./scripts/review_work.sh
```

Confirm: a review comment/approval appears on each PR, the `aw/merge-gate`
commit status is set, and — if `AW_AUTO_MERGE=1` (the default) and the
review passed — the PR merges and the issue flips to `status: done`.

## 4. Exercise the rework path

Manually request changes on one of the PRs (`gh pr review <n>
--request-changes --body "please add a test"`) instead of waiting for a
NEEDS_WORK verdict, and confirm the linked issue flips to
`status: changes-requested`. Then re-run `start_work.sh` — it should pick
that issue up as rework (priority position #1, ahead of fresh
`available` work) and push a new commit to the same branch and PR rather
than opening a new one.

## 5. Confirm the garbage collector

```bash
AW_DRY_RUN=1 ./scripts/reap.sh
```

Should report no action needed (nothing is stale yet). To actually see it
fire, lower the TTLs for a test: `AW_CLAIM_TTL=5 AW_DRY_RUN=1
./scripts/reap.sh` after claiming an issue and waiting a few seconds.

## 6. Clean up

Close/delete the example issues and PRs, delete `example/` from your repo,
and you're ready to point this at real backlog per
[GETTING_STARTED.md](GETTING_STARTED.md).
