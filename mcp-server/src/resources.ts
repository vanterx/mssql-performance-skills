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
    { mimeType: "application/json", description: `Index of all ${skills.length} skills with metadata` },
    async () => ({
      contents: [
        {
          uri: "mssql://skills",
          mimeType: "application/json",
          text: JSON.stringify(
            skills.map(({ name, description, triggers, checkCount, references }) => ({
              name,
              description,
              triggers,
              checkCount,
              resourceUri: `mssql://skills/${name}`,
              referenceFiles: Object.keys(references),
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

    const refEntries = Object.entries(skill.references);
    if (refEntries.length > 0) {
      server.resource(
        `skill-${skill.name}-references`,
        `mssql://skills/${skill.name}/references`,
        {
          mimeType: "application/json",
          description: `Available reference files for ${skill.name} (check explanations, how-to guides, concepts)`,
        },
        async () => ({
          contents: [
            {
              uri: `mssql://skills/${skill.name}/references`,
              mimeType: "application/json",
              text: JSON.stringify(
                refEntries.map(([filename]) => ({
                  filename,
                  uri: `mssql://skills/${skill.name}/references/${filename}`,
                })),
                null,
                2
              ),
            },
          ],
        })
      );

      for (const [filename, content] of refEntries) {
        server.resource(
          `skill-${skill.name}-ref-${filename}`,
          `mssql://skills/${skill.name}/references/${filename}`,
          {
            mimeType: "text/markdown",
            description: `${filename} — reference material for ${skill.name}`,
          },
          async () => ({
            contents: [
              {
                uri: `mssql://skills/${skill.name}/references/${filename}`,
                mimeType: "text/markdown",
                text: content,
              },
            ],
          })
        );
      }
    }
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
