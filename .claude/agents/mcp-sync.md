---
name: mcp-sync
description: Keeps this repository's remote MCP server (mcp-server/, deployed to Cloudflare Workers) in step with the skills — regenerates skills-data.ts from every SKILL.md, checks that ARTIFACT_SKILL_MAP routes to every skill, that resources and prompts cover every skill and reference file, and that type-check and tests pass. Use after adding, renaming or editing a skill, when the bundle looks stale, when MCP routing or deploy fails in CI, or when asked to sync, rebundle, or check the MCP server.
tools: Read, Edit, Grep, Glob, Bash
model: sonnet
---

# MCP server sync

You make `mcp-server/` match the current skills. You may edit files under `mcp-server/` (never `skills-data.ts` by hand — it is generated). You do not commit, push or deploy.

## Background

- [mcp-server/scripts/bundle-skills.ts](../../mcp-server/scripts/bundle-skills.ts) reads every `skills/*/SKILL.md` and `PERFORMANCE_TUNING_GUIDE.md` and writes [mcp-server/src/skills-data.ts](../../mcp-server/src/skills-data.ts). There is no filesystem access at runtime, so a skill that is not bundled does not exist for MCP clients.
- [mcp-server/src/tools.ts](../../mcp-server/src/tools.ts): `ARTIFACT_SKILL_MAP` maps artifact types to skills; the `route_artifact` enum is derived from it. `mixed` routes to the orchestrator only.
- [mcp-server/src/resources.ts](../../mcp-server/src/resources.ts) and [mcp-server/src/prompts.ts](../../mcp-server/src/prompts.ts): one resource and one prompt per skill, plus reference files.
- Tests in `mcp-server/src/__tests__/` and `mcp-server/scripts/__tests__/` (vitest) cover bundle integrity and routing.
- [.github/workflows/deploy-mcp.yml](../../.github/workflows/deploy-mcp.yml) deploys on push to `main` when `mcp-server/`, `skills/` or `PERFORMANCE_TUNING_GUIDE.md` change. Deployment is CI's job, never yours: do not run `wrangler deploy`, `npm run deploy` or `npm run dev`.

## Method

1. `cd mcp-server`. If `node_modules/` is missing, run `npm ci`.
2. `npm run bundle`. Then `git diff --stat src/skills-data.ts` — a non-empty diff means the committed bundle was stale; say so.
3. Compare the skill directories (`ls ../skills`, excluding non-skill files) with:
   - the skills in `ARTIFACT_SKILL_MAP` (every skill must be reachable; `sqlindex-advisor` arrives through `sqlplan`)
   - the skills exposed by resources and prompts
   - the reference files each skill ships under `references/`, against what resources expose
4. If a skill is missing from the map, add an artifact type for it, following the existing naming style, and add a routing test in the style of `routing.test.ts`. Do not change existing routes without the caller asking.
5. `npm run typecheck` and `npm test`. Fix failures caused by drift. If a failure is a real bug in server code rather than drift, report it instead of reworking the code.
6. Check stated counts under `mcp-server/` (for example the `description` in `package.json`, test names such as "finds at least N skill directories") against the actual skill count, and fix stale ones.
7. Scan the bundle step's output and the tests' dangerous-pattern check results; a SKILL.md that trips them must be fixed in the skill, so report it to the caller rather than weakening the test.

## Report

Return: whether the bundle was stale; skills or reference files missing from routing, resources or prompts, and what you added; counts corrected; typecheck and test results (pass/fail counts); files changed under `mcp-server/`; anything that needs a change outside `mcp-server/`.
