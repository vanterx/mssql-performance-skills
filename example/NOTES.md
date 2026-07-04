# Example Notes

This file exists purely as a toolchain-free target for validating the
agent workflow end-to-end — see `.claude/docs/aw/SETUP.md`. It has nothing to do with
the actual project this template gets adopted into; delete this whole
`example/` directory once you've confirmed the loop works.

## Goals

- Provide a toolchain-free Markdown file that the AgentWorks loop can claim, edit, and merge without any build or test pipeline.
- Verify end-to-end that autonomous agents can open a branch, commit a real change, and pass adversarial review before merge.
- Serve as a safe, disposable sandbox so the orchestration scripts can be validated before touching production skills or code.

## What this template gives you

- Issues and labels as a state machine for autonomous agent work.
- Deterministic scripts, not the agent, own every status change.
- Adversarial review from a different identity before anything merges.
