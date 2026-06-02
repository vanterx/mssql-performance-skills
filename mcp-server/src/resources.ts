import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { SkillMeta } from "./skill-loader.js";

export function registerResources(
  server: McpServer,
  skills: SkillMeta[],
  guideContent: string,
  vcContent: string = ""
): void {
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

  if (guideContent) {
    server.resource(
      "performance-guide",
      "mssql://guide",
      {
        mimeType: "text/markdown",
        description: "Symptom-to-skill routing guide — which skill to use for each scenario",
      },
      async () => ({
        contents: [{ uri: "mssql://guide", mimeType: "text/markdown", text: guideContent }],
      })
    );
  }

  if (vcContent) {
    server.resource(
      "version-compat",
      "mssql://version-compat",
      {
        mimeType: "text/markdown",
        description: "Version-gated check catalog — which checks require SQL Server 2016, 2017, 2019, 2022+",
      },
      async () => ({
        contents: [{ uri: "mssql://version-compat", mimeType: "text/markdown", text: vcContent }],
      })
    );
  }
}
