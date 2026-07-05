# AgentWorks runner image — worker, reviewer, or triage loop in a container.
#
#   docker build -t agentworks-runner --build-arg AGENT_CLI=claude .
#
# AGENT_CLI: claude (default) | codex | none (bring your own via volume)
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq curl ca-certificates gnupg nodejs npm \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

ARG AGENT_CLI=claude
RUN case "$AGENT_CLI" in \
      claude) npm install -g @anthropic-ai/claude-code ;; \
      codex)  npm install -g @openai/codex ;; \
      none)   echo "no agent CLI baked in" ;; \
      *)      echo "unknown AGENT_CLI '$AGENT_CLI'" && exit 1 ;; \
    esac

RUN useradd -m -u 1000 agentworks
USER agentworks
WORKDIR /work/repo

# The repo is expected as a volume/clone at /work/repo (see compose.yml).
# gh auth: mount a token via GH_TOKEN env or a gh config volume.
ENTRYPOINT ["/bin/bash"]
CMD ["scripts/start_work.sh"]
