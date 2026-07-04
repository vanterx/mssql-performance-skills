---
name: triage-task
description: Score an issue or the whole available-work queue on priority, value, and token cost to recommend do-now/good-ROI/defer/skip. Advisory only — never claims, relabels, or reorders anything.
---

# Triage Task

An advisory rubric for deciding what's worth an agent's time. This skill
**never mutates repo state** — no labels, no assignees, no comments. It
only produces a recommendation for a human or another agent to act on.

## Inputs

```bash
gh issue list --label "status: available" --state open --json number,title,labels,body
gh issue list --label "status: changes-requested" --assignee "@me" --state open --json number,title,labels
```

## Scoring

For each issue, score three axes:

**Priority (1-5).** Read from the `priority:` label if present, otherwise
estimate from urgency described in the issue body. `priority: high` should
generally dominate the final verdict regardless of the other two axes.

**Value (composite).** Consider:
- Impact if this ships (how many users/workflows does it affect?)
- Leverage (does it unblock other queued work, or is it a dead end?)
- Novelty (is this duplicate/overlapping with another open issue or a
  recently merged PR? Check before scoring — duplicated effort is zero
  value regardless of how good the individual PR is.)
- Tractability (is the ask well-specified enough to execute without a lot
  of back-and-forth, or is it actually a research/discovery task in
  disguise?)

**Token-cost band (S/M/L/XL).** Rough estimate of how much agent context
and how many turns this will take: S = single-file, well-specified fix.
M = a few files, some design judgment. L = cross-cutting change or
non-trivial investigation. XL = probably needs to be broken into smaller
issues before anyone should pick it up — flag this in your output rather
than triaging it as-is.

## Verdict

Combine into one of:
- 🟢 **Do now** — high priority or high value, tractable, reasonable cost.
- 🔵 **Good ROI** — solid value relative to cost, not urgent.
- 🟡 **Defer** — low urgency, or value is unclear until something else
  lands first.
- 🔴 **Skip** — duplicate, out of scope, or cost (XL, ill-specified) far
  exceeds likely value as currently written — recommend the issue be
  split or clarified instead of worked on directly.

## Output format

A short table: issue number, one-line title, priority, value note, cost
band, verdict. End with your top 1-3 recommendations for what to actually
work on next, and a one-line reason for each.

## What this skill must never do

- Never call `gh issue edit`, add/remove labels, change assignees, or
  comment on issues as a side effect of triage.
- Never claim work on the triager's behalf — that's `start_work.sh`'s job,
  driven by the queue order in `AGENT_CONTRACT.md`, not by this skill's opinion.
