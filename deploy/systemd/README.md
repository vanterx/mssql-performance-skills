# systemd deployment

Always-on runner loops as systemd services (Linux, incl. WSL with
systemd enabled). Each unit reads `/etc/agentworks/aw.env` — put your
`AW_*` variables and (for the reviewer) `REVIEW_GITHUB_TOKEN` there,
`chmod 600`, owned by the runner user.

```bash
sudo mkdir -p /etc/agentworks
sudo cp aw.env.example /etc/agentworks/aw.env   # edit it
sudo cp aw-worker.service aw-reviewer.service /etc/systemd/system/
sudo cp aw-planner.service aw-planner.timer /etc/systemd/system/
# edit User=, WorkingDirectory= in each unit to your clone
sudo systemctl daemon-reload
sudo systemctl enable --now aw-worker aw-reviewer
sudo systemctl enable --now aw-planner.timer     # only if planner.enabled
```

Monitor: `journalctl -u aw-worker -f`, plus the heartbeat files
(`.aw/heartbeat-*`) per `.claude/docs/aw/OPERATIONS.md`. `Restart=on-failure` handles
crashes; a clean exit (queue drained with `AW_POLL_SECONDS=0`) is not
restarted — leave `AW_POLL_SECONDS` at its default for always-on loops.

`aw-triage.service` (agent triage tier) is only useful when
`.github/autonomy.json` has `auto_triage.agent_triage=true`.
