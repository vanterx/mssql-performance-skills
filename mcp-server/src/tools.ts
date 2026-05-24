import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { SkillMeta } from "./skill-loader.js";
import { buildAnalysisPrompt } from "./prompt-builder.js";

const ARTIFACT_SKILL_MAP: Record<string, string[]> = {
  tsql:        ["tsql-review"],
  sqlplan:     ["sqlplan-review", "sqlplan-index-advisor"],
  deadlock:    ["sqlplan-deadlock"],
  waits:       ["sqlwait-review"],
  trace:       ["sqltrace-review"],
  stats:       ["sqlstats-review"],
  querystore:  ["query-store-review"],
  procstats:   ["procstats-review"],
  hadr:        ["hadr-health-review"],
  clusterlog:  ["clusterlog-review"],
  errorlog:    ["errorlog-review"],
  spn:         ["spn-review"],
  mixed:       ["mssql-performance-review"],
};

export function registerTools(server: McpServer, skills: SkillMeta[]): void {
  const byName = new Map(skills.map((s) => [s.name, s]));

  server.tool(
    "list_skills",
    "List all 16 available SQL Server performance tuning skills with their check counts and triggers",
    {},
    async () => ({
      content: [
        {
          type: "text",
          text: JSON.stringify(
            skills.map(({ name, description, triggers, checkCount }) => ({
              name,
              description,
              triggers,
              checkCount,
            })),
            null,
            2
          ),
        },
      ],
    })
  );

  server.tool(
    "get_skill",
    "Get the full content of a named skill (SKILL.md) including all checks, thresholds, and output format",
    { name: z.string().describe("Skill name, e.g. tsql-review or sqlplan-review") },
    async ({ name }) => {
      const skill = byName.get(name);
      if (!skill) {
        const available = skills.map((s) => s.name).join(", ");
        return {
          content: [{ type: "text", text: `Skill '${name}' not found. Available: ${available}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text", text: skill.content }] };
    }
  );

  server.tool(
    "route_artifact",
    "Given an artifact type, returns the recommended skill(s) to use for analysis",
    {
      artifact_type: z
        .enum([
          "tsql", "sqlplan", "deadlock", "waits", "trace",
          "stats", "querystore", "procstats", "hadr", "clusterlog", "errorlog", "spn",
          "mixed",
        ])
        .describe("Type of artifact to analyze. Use 'mixed' when the artifact combines multiple types or the type is unknown — routes to the mssql-performance-review orchestrator."),
    },
    async ({ artifact_type }) => {
      const skillNames = ARTIFACT_SKILL_MAP[artifact_type] ?? [];
      const matched = skillNames.map((n) => byName.get(n)).filter(Boolean) as SkillMeta[];

      const result = matched.map(({ name, description, triggers }) => ({
        name,
        description,
        primaryTrigger: triggers[0] ?? `/${name}`,
      }));

      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    }
  );

  for (const skill of skills) {
    server.tool(
      skill.name,
      `Apply ${skill.name} (${skill.checkCount} checks) to the provided artifact. ${skill.description}`,
      {
        input: z
          .string()
          .optional()
          .describe("Raw SQL, XML plan, statistics output, trace data, or other artifact to analyze. Omit to retrieve the skill content only."),
      },
      async ({ input }) => ({
        content: [
          {
            type: "text",
            text: input
              ? buildAnalysisPrompt(skill.name, skill.content, input)
              : skill.content,
          },
        ],
      })
    );
  }
}
