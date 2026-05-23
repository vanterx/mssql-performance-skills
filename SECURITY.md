# Security Policy

## Supported Versions

This repository contains Markdown skill files and a Cloudflare Workers MCP server.
Only the latest commit on `main` is actively maintained.

| Component | Supported |
|-----------|-----------|
| Skills (`skills/*/SKILL.md`) | Latest on `main` |
| MCP server (`mcp-server/`) | Latest on `main` |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities privately via [GitHub Security Advisories](https://github.com/vanterx/mssql-performance-skills/security/advisories/new).

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (optional)

You will receive a response within 7 days. If the vulnerability is confirmed, a fix will be
shipped and a public advisory published after the patch is live.

## Security Architecture

### MCP Server

- **No authentication** — the server is a public read-only knowledge base. All 16 skills are
  public Markdown. No user data, credentials, or sensitive information is stored or transmitted.
- **No database** — all content is bundled as static TypeScript constants at build time.
  There is no SQL, no ORM, no dynamic queries.
- **Input validation** — all MCP tool inputs are validated with Zod schemas before any handler
  logic runs. `artifact_type` uses an exhaustive enum; unrecognised values are rejected at the
  SDK level.
- **Prompt injection boundary** — user-supplied artifact content in MCP prompts is wrapped in
  `<artifact>` tags with an explicit instruction to treat the content as data, not instructions.
- **Stateless** — each HTTP request creates a fresh server instance with no shared state.
  No session tokens, no cookies, no persistent memory.

### GitHub Actions

- Actions are pinned to full SHA digests (not mutable version tags) to prevent supply chain
  attacks via tag mutation.
- `GITHUB_TOKEN` is scoped to `contents: read` — the minimum required for checkout.
- Cloudflare credentials are stored as GitHub secrets and injected only at deploy time.
  They never appear in logs or build artifacts.

### Claude Code Hooks

- `pre-tool-security.js` — blocks destructive Bash commands (`git push --force`,
  `git push --force-with-lease`, `git reset --hard`, `git clean -f`, `DROP TABLE`,
  `DROP DATABASE`) before execution. Case-insensitive matching. Hard-exits on malformed input.
- `stop-secret-scan.js` — recursively scans `.env*` files at session end for secret patterns.
  Exits non-zero if findings are detected, surfacing them before the session closes.
- Bash permissions use an explicit allow-list. The `gh` CLI is scoped to specific subcommands
  (`pr`, `issue`, `release`, `repo view`, `repo clone`, `search`, `api`).

## Known Limitations

- The prompt injection boundary (`<artifact>` tags) is a defence-in-depth measure, not a
  guarantee. A sufficiently crafted artifact could still influence model behaviour.
- The secret scanner checks only known `.env*` filenames and a fixed set of key patterns.
  It does not scan arbitrary source files for accidentally inlined credentials.
- The pre-commit hook (`scripts/install-hooks.sh`) is opt-in — contributors who skip
  installation will not have automatic `skills-data.ts` regeneration on commit.

## Dependency Security

The MCP server has one runtime dependency (`@modelcontextprotocol/sdk`). Run `npm audit`
inside `mcp-server/` to check for known vulnerabilities in the dependency tree.

```bash
cd mcp-server && npm audit
```
