#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadSkills, resolveRepoRoot } from "./skill-loader.js";
import { registerTools } from "./tools.js";
import { registerResources } from "./resources.js";
import { registerPrompts } from "./prompts.js";

async function main() {
  const repoRoot = resolveRepoRoot();
  const skills = loadSkills(repoRoot);

  const server = new McpServer({
    name: "mssql-performance-skills",
    version: "1.0.0",
  });

  registerTools(server, skills);
  registerResources(server, skills, repoRoot);
  registerPrompts(server, skills);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(`Fatal: ${err}\n`);
  process.exit(1);
});
