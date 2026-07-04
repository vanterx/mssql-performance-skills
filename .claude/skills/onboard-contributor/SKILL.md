---
name: onboard-contributor
description: Get a new contributor (human or agent) from zero to a running start_work.sh loop against this repo.
---

# Onboard Contributor

Paste this whole skill to a new contributor's agent, or read it yourself,
to get running against this repo's issue queue in a few minutes.

## Which path applies to you?

| You have... | Do this |
|---|---|
| Write access + an agent CLI (Claude Code/OpenCode/Codex) | **Autopilot**: run `./scripts/start_work.sh` and let it claim, work, and open PRs for you. |
| Write access, no agent CLI | **Manual**: pick an issue labeled `status: available`, claim it by hand (see `AGENT_CONTRACT.md` step 2), do the work yourself, open a PR the same way. |
| No write access | **Fork**: fork the repo, comment on the issue you're picking up, push your branch to your fork, then `gh pr create --repo <upstream>:<upstream-branch> --head <you>:<branch>`. |

## Autopilot quickstart

```bash
gh auth login                 # once, if not already authenticated
export AW_AGENT=claude        # or opencode / codex
./scripts/start_work.sh
```

The loop will:
1. Fetch open issues, prefer your own `status: changes-requested` rework,
   then freed rework, then fresh `status: available` work.
2. Claim the issue, spin up a throwaway git worktree, run your agent CLI
   against a generated prompt.
3. Open a PR if the agent succeeded, or release the issue back to
   `available` if it didn't.

You never need to touch labels yourself — the script does it. See
`AGENT_CONTRACT.md` for the full contract and `.claude/docs/aw/AUTOMATION.md` for the status
lifecycle this loop drives.

## Before you start

- Read this project's own README/CONTRIBUTING (if present) for
  project-specific conventions — this skill only covers the generic
  claim/work/PR loop, not what "good work" looks like here.
- Check for a `do-not-automate` label on any issue before claiming it —
  that's a human-only parking brake.
- If you're setting this workflow up for the first time in a repo, see
  `.claude/docs/aw/GETTING_STARTED.md` instead of this skill.
