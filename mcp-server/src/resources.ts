import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import type { SkillMeta } from "./skill-loader.js";

export function registerResources(
  server: McpServer,
  skills: SkillMeta[],
  repoRoot: string
): void {
  // mssql://skills — metadata index for all skills
  server.resource(
    "skills-index",
    "mssql://skills",
    { mimeType: "application/json", description: "Index of all 16 skills with metadata" },
    async () => ({
      contents: [
        {
          uri: "mssql://skills",
          mimeType: "application/json",
          text: JSON.stringify(
            skills.map(({ name, description, triggers, checkCount }) => ({
              name,
              description,
              triggers,
              checkCount,
              resourceUri: `mssql://skills/${name}`,
            })),
            null,
            2
          ),
        },
      ],
    })
  );

  // mssql://skills/{name} — full SKILL.md for each skill
  for (const skill of skills) {
    server.resource(
      `skill-${skill.name}`,
      `mssql://skills/${skill.name}`,
      {
        mimeType: "text/markdown",
        description: `Full SKILL.md for ${skill.name} (${skill.checkCount} checks)`,
      },
      async () => ({
        contents: [
          {
            uri: `mssql://skills/${skill.name}`,
            mimeType: "text/markdown",
            text: skill.content,
          },
        ],
      })
    );
  }

  // mssql://guide — PERFORMANCE_TUNING_GUIDE.md
  const guidePath = join(repoRoot, "PERFORMANCE_TUNING_GUIDE.md");
  if (existsSync(guidePath)) {
    const guideContent = readFileSync(guidePath, "utf-8");
    server.resource(
      "performance-guide",
      "mssql://guide",
      {
        mimeType: "text/markdown",
        description: "Symptom-to-skill routing guide — which skill to use for each scenario",
      },
      async () => ({
        contents: [
          {
            uri: "mssql://guide",
            mimeType: "text/markdown",
            text: guideContent,
          },
        ],
      })
    );
  }
}
