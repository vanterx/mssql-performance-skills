You are working autonomously on issue #{{issue_number}} in this repository.

Title: {{issue_title}}

Description:
{{issue_body}}
{{skills_section}}
Instructions:
1. Read any linked/parent issues and prior related PRs before starting, to
   avoid duplicating work already done.
2. Do the smallest correct change that resolves this issue. Stay in scope —
   if you find unrelated problems, note them in the PR description instead
   of fixing them here.
{{tdd_section}}3. Commit your changes on a new branch named aw/issue-{{issue_number}}.
4. End your final commit message with "(Closes #{{issue_number}})".
5. Push the branch and open a pull request with 'gh pr create --fill --body
   "Closes #{{issue_number}}. <one paragraph summary>."'
6. Record provenance in your PR description: note the agent CLI and model
   you are running as.
7. IMPORTANT: never add, remove, or change any label or assignee on this
   issue or the PR yourself. The orchestration scripts own all status
   transitions — you own only the code and the PR content.
8. Expect an adversarial review: a different identity will try to find
   problems with this PR before it can merge. Make your case with evidence
   in the PR description, not assertions.
